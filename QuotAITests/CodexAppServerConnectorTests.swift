import XCTest
@testable import QuotAI

/// Scripted session: lets the connector's decoding/fallback logic be tested deterministically,
/// without spawning the real `codex` binary. The real process-based implementation (wire format,
/// handshake, the `account/rateLimits/read` method itself) was verified separately with a live
/// call against the installed CLI; see `ProviderDescriptor.codex`.
final class ScriptedCodexSession: CodexAppServerSession, @unchecked Sendable {
    enum Outcome {
        case success(Data)
        case failure(ProviderError)
    }
    private let outcome: Outcome
    private(set) var callCount = 0
    private(set) var lastTimeout: TimeInterval?

    init(_ outcome: Outcome) { self.outcome = outcome }

    static func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    func fetchRateLimits(timeout: TimeInterval) async throws -> Data {
        callCount += 1
        lastTimeout = timeout
        switch outcome {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }
}

final class CodexAppServerConnectorTests: XCTestCase {
    private func context(manual: ManualQuota? = nil) -> FetchContext {
        FetchContext(connection: Connection(kind: .codex, manual: manual), secret: nil, now: Fixtures.now)
    }

    private func rateLimitsPayload(primaryPercent: Int = 0, primaryMins: Int = 300,
                                   secondaryPercent: Int = 16, secondaryMins: Int = 10_080,
                                   plan: String = "plus", resetsAt: Int = 1_790_295_854) -> Data {
        ScriptedCodexSession.json([
            "rateLimits": [
                "planType": plan,
                "primary": ["usedPercent": primaryPercent, "windowDurationMins": primaryMins, "resetsAt": resetsAt],
                "secondary": ["usedPercent": secondaryPercent, "windowDurationMins": secondaryMins, "resetsAt": resetsAt + 500_000],
                "credits": ["hasCredits": true, "unlimited": false, "balance": "473.23"]
            ]
        ])
    }

    // MARK: - Happy path (mirrors the real payload verified live against codex-cli 0.156.1)

    func testDecodesRealShapedPayloadIntoOfficialMetrics() async throws {
        let session = ScriptedCodexSession(.success(rateLimitsPayload()))
        let connector = CodexAppServerConnector(makeSession: { _ in session }, locate: { URL(fileURLWithPath: "/opt/homebrew/bin/codex") })

        let snapshot = try await connector.fetch(context())

        XCTAssertEqual(snapshot.metrics.map(\.id), ["primary", "secondary", "credits"])
        XCTAssertEqual(snapshot.metrics[0].label, "5-hour limit")
        XCTAssertEqual(snapshot.metrics[0].value, 0)
        XCTAssertEqual(snapshot.metrics[0].source, .official)
        XCTAssertEqual(snapshot.metrics[1].label, "Weekly limit")
        XCTAssertEqual(snapshot.metrics[1].value, 16)
        XCTAssertEqual(snapshot.metrics[2].label, "Credit balance")
        XCTAssertEqual(snapshot.metrics[2].value, 473.23, accuracy: 1e-9)
        XCTAssertEqual(snapshot.metrics[2].format, .count)
        XCTAssertNil(snapshot.metrics[2].percentUsed, "a credit balance is not a percentage of anything")
        XCTAssertTrue(snapshot.notes.contains("Plan: plus."))
        XCTAssertEqual(session.callCount, 1)
    }

    // MARK: - Extra per-model reserves (e.g. "Luna Reserve" as shown by /status)

    func testExtraLimitBucketsBecomeTheirOwnMetrics() async throws {
        let data = ScriptedCodexSession.json([
            "rateLimits": [
                "planType": "plus",
                "primary": ["usedPercent": 0, "windowDurationMins": 300],
                "secondary": ["usedPercent": 16, "windowDurationMins": 10_080]
            ],
            "rateLimitsByLimitId": [
                "codex": ["primary": ["usedPercent": 0, "windowDurationMins": 300]],  // already covered above, must be skipped
                "base_model_inference": [
                    "limitName": "gpt-reserve",
                    "normalModelSlug": "gpt-5.6-luna",
                    "primary": ["usedPercent": 100, "windowDurationMins": 10_080, "resetsAt": 1_790_871_880]
                ]
            ]
        ])
        let connector = CodexAppServerConnector(makeSession: { _ in ScriptedCodexSession(.success(data)) },
                                                locate: { URL(fileURLWithPath: "/opt/homebrew/bin/codex") })

        let snapshot = try await connector.fetch(context())

        XCTAssertEqual(snapshot.metrics.map(\.id), ["primary", "secondary", "extra_base_model_inference"])
        let extra = snapshot.metrics[2]
        XCTAssertEqual(extra.label, "Weekly limit (gpt-5.6-luna)")
        XCTAssertEqual(extra.value, 100)
        XCTAssertEqual(extra.source, .official)
        XCTAssertEqual(extra.resetsAt, Date(timeIntervalSince1970: 1_790_871_880))
    }

    func testExtraLimitFallsBackToLimitIdWhenNoFriendlyNameIsGiven() async throws {
        let data = ScriptedCodexSession.json([
            "rateLimits": ["primary": ["usedPercent": 5, "windowDurationMins": 300]],
            "rateLimitsByLimitId": ["mystery_bucket": ["primary": ["usedPercent": 9, "windowDurationMins": 60]]]
        ])
        let connector = CodexAppServerConnector(makeSession: { _ in ScriptedCodexSession(.success(data)) },
                                                locate: { URL(fileURLWithPath: "/opt/homebrew/bin/codex") })
        let snapshot = try await connector.fetch(context())
        XCTAssertEqual(snapshot.metrics.last?.label, "1-hour limit (mystery_bucket)")
    }

    func testUnlimitedCreditsProduceANoteNotAMetric() async throws {
        let data = ScriptedCodexSession.json([
            "rateLimits": [
                "primary": ["usedPercent": 0, "windowDurationMins": 300],
                "credits": ["hasCredits": true, "unlimited": true]
            ]
        ])
        let connector = CodexAppServerConnector(makeSession: { _ in ScriptedCodexSession(.success(data)) },
                                                locate: { URL(fileURLWithPath: "/opt/homebrew/bin/codex") })
        let snapshot = try await connector.fetch(context())
        XCTAssertFalse(snapshot.metrics.contains { $0.id == "credits" })
        XCTAssertTrue(snapshot.notes.contains("Credits: unlimited."))
    }

    func testNoCreditsMeansNoCreditMetricOrNote() async throws {
        let data = ScriptedCodexSession.json([
            "rateLimits": [
                "primary": ["usedPercent": 0, "windowDurationMins": 300],
                "credits": ["hasCredits": false, "unlimited": false]
            ]
        ])
        let connector = CodexAppServerConnector(makeSession: { _ in ScriptedCodexSession(.success(data)) },
                                                locate: { URL(fileURLWithPath: "/opt/homebrew/bin/codex") })
        let snapshot = try await connector.fetch(context())
        XCTAssertFalse(snapshot.metrics.contains { $0.id == "credits" })
        XCTAssertFalse(snapshot.notes.contains { $0.contains("Credits") })
    }

    func testWindowLabelsAreDerivedFromDuration() {
        XCTAssertEqual(CodexAppServerConnector.windowLabel(300), "5-hour limit")
        XCTAssertEqual(CodexAppServerConnector.windowLabel(60), "1-hour limit")
        XCTAssertEqual(CodexAppServerConnector.windowLabel(10_080), "Weekly limit")
        XCTAssertEqual(CodexAppServerConnector.windowLabel(2_880), "2-day limit")
        XCTAssertEqual(CodexAppServerConnector.windowLabel(90), "90-minute limit")
        XCTAssertEqual(CodexAppServerConnector.windowLabel(nil), "Usage limit")
        XCTAssertEqual(CodexAppServerConnector.windowLabel(0), "Usage limit")
    }

    func testMissingSecondaryWindowStillProducesASnapshot() async throws {
        let data = ScriptedCodexSession.json([
            "rateLimits": ["planType": "free", "primary": ["usedPercent": 42, "windowDurationMins": 300]]
        ])
        let connector = CodexAppServerConnector(makeSession: { _ in ScriptedCodexSession(.success(data)) },
                                                locate: { URL(fileURLWithPath: "/opt/homebrew/bin/codex") })
        let snapshot = try await connector.fetch(context())
        XCTAssertEqual(snapshot.metrics.map(\.id), ["primary"])
        XCTAssertNil(snapshot.metrics[0].resetsAt, "resetsAt is optional and was omitted here")
    }

    func testEmptyRateLimitsIsReportedAsNoData() async {
        let data = ScriptedCodexSession.json(["rateLimits": ["planType": "free"]])
        let connector = CodexAppServerConnector(makeSession: { _ in ScriptedCodexSession(.success(data)) },
                                                locate: { URL(fileURLWithPath: "/opt/homebrew/bin/codex") })
        do {
            _ = try await connector.fetch(context())
            XCTFail("expected an error")
        } catch {
            guard case .noData = error as? ProviderError else { return XCTFail("got \(error)") }
        }
    }

    func testMalformedPayloadIsUnexpectedResponse() async {
        let data = Data(#"{"not":"the expected shape"}"#.utf8)
        let connector = CodexAppServerConnector(makeSession: { _ in ScriptedCodexSession(.success(data)) },
                                                locate: { URL(fileURLWithPath: "/opt/homebrew/bin/codex") })
        do {
            _ = try await connector.fetch(context())
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unexpectedResponse)
        }
    }

    // MARK: - CLI not found

    func testCLINotFoundFailsWithoutSpawningASession() async {
        var sessionCreated = false
        let connector = CodexAppServerConnector(makeSession: { _ in sessionCreated = true; return ScriptedCodexSession(.success(Data())) },
                                                locate: { nil })
        do {
            _ = try await connector.fetch(context())
            XCTFail("expected an error")
        } catch {
            guard case .noData = error as? ProviderError else { return XCTFail("got \(error)") }
            XCTAssertTrue((error as! ProviderError).isInformational)
        }
        XCTAssertFalse(sessionCreated)
    }

    // MARK: - Fallback to manual entry

    func testFallsBackToManualEntryWhenCLIMissing() async throws {
        let manual = ManualQuota(usedPercent: 40, remainingText: "about half a session", resetsAt: nil, enteredAt: Fixtures.now)
        let connector = CodexAppServerConnector(makeSession: { _ in ScriptedCodexSession(.success(Data())) }, locate: { nil })

        let snapshot = try await connector.fetch(context(manual: manual))
        XCTAssertEqual(snapshot.metrics.count, 1)
        XCTAssertEqual(snapshot.metrics[0].source, .userProvided)
        XCTAssertEqual(snapshot.metrics[0].value, 40)
        XCTAssertTrue(snapshot.notes.contains { $0.contains("Live Codex data unavailable") })
        XCTAssertTrue(snapshot.notes.contains { $0.contains("about half a session") })
    }

    func testFallsBackToManualEntryOnRPCFailure() async throws {
        let manual = ManualQuota(usedPercent: 70, remainingText: nil, resetsAt: nil, enteredAt: Fixtures.now)
        let session = ScriptedCodexSession(.failure(.unauthorized(hint: "Run `codex login`.")))
        let connector = CodexAppServerConnector(makeSession: { _ in session }, locate: { URL(fileURLWithPath: "/opt/homebrew/bin/codex") })

        let snapshot = try await connector.fetch(context(manual: manual))
        XCTAssertEqual(snapshot.metrics[0].value, 70)
        XCTAssertTrue(snapshot.notes.contains { $0.contains("Run `codex login`") })
    }

    func testNoManualEntryMeansTheOriginalErrorPropagates() async {
        let session = ScriptedCodexSession(.failure(.timeout))
        let connector = CodexAppServerConnector(makeSession: { _ in session }, locate: { URL(fileURLWithPath: "/opt/homebrew/bin/codex") })
        do {
            _ = try await connector.fetch(context())
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .timeout)
        }
    }

    func testNonProviderErrorIsNormalizedToUnexpectedResponse() async {
        struct OtherError: Error {}
        final class ThrowingSession: CodexAppServerSession, @unchecked Sendable {
            func fetchRateLimits(timeout: TimeInterval) async throws -> Data { throw OtherError() }
        }
        let connector = CodexAppServerConnector(makeSession: { _ in ThrowingSession() }, locate: { URL(fileURLWithPath: "/opt/homebrew/bin/codex") })
        do {
            _ = try await connector.fetch(context())
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unexpectedResponse)
        }
    }
}

final class CodexCLILocatorTests: XCTestCase {
    func testFindsExecutableOnPATH() {
        let found = CodexCLILocator.locate(environment: ["PATH": "/nowhere:/opt/homebrew/bin:/usr/bin"],
                                           fileExists: { $0 == "/opt/homebrew/bin/codex" })
        XCTAssertEqual(found?.path, "/opt/homebrew/bin/codex")
    }

    func testFallsBackToCommonInstallLocations() {
        let found = CodexCLILocator.locate(environment: [:],
                                           fileExists: { $0 == "/usr/local/bin/codex" })
        XCTAssertEqual(found?.path, "/usr/local/bin/codex")
    }

    func testReturnsNilWhenNotFoundAnywhere() {
        XCTAssertNil(CodexCLILocator.locate(environment: ["PATH": "/nowhere"], fileExists: { _ in false }))
    }

    func testEmptyPathComponentsAreSkippedWithoutCrashing() {
        XCTAssertNil(CodexCLILocator.locate(environment: ["PATH": "::"], fileExists: { _ in false }))
    }
}
