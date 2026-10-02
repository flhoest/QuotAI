import XCTest
@testable import QuotAI

final class ConnectorTests: XCTestCase {
    private let key = "sk-ant-admin01-SUPER-SECRET-123456"

    private func context(kind: ProviderKind, secret: String?, budget: Double? = nil, manual: ManualQuota? = nil) -> FetchContext {
        FetchContext(connection: Connection(kind: kind, monthlyBudgetUSD: budget, manual: manual), secret: secret, now: Fixtures.now)
    }

    // MARK: - Anthropic Admin API

    private func anthropicHandler(costPages: [[String: Any]], usageStatus: Int = 200) -> StubHTTPClient.Handler {
        let pageIndex = Locked(0)
        return { request in
            let path = request.url!.path
            if path.hasSuffix("cost_report") {
                let index = pageIndex.increment()
                return StubHTTPClient.json(costPages[min(index, costPages.count - 1)])
            }
            if usageStatus != 200 { return HTTPResponse(status: usageStatus, data: Data(), headers: [:]) }
            return StubHTTPClient.json([
                "data": [["starting_at": "2026-09-01T00:00:00Z", "ending_at": "2026-09-02T00:00:00Z", "results": [[
                    "uncached_input_tokens": 1000, "cache_read_input_tokens": 200, "output_tokens": 500,
                    "cache_creation": ["ephemeral_1h_input_tokens": 50, "ephemeral_5m_input_tokens": 50]
                ]]]],
                "has_more": false, "next_page": NSNull()
            ])
        }
    }

    func testAnthropicSumsCentsAcrossPagesAndComputesBudgetPercent() async throws {
        let pages: [[String: Any]] = [
            ["data": [["results": [["amount": "1500.5", "currency": "USD"]]]], "has_more": true, "next_page": "page_2"],
            ["data": [["results": [["amount": "500", "currency": "USD"]]]], "has_more": false, "next_page": NSNull()]
        ]
        let http = StubHTTPClient(anthropicHandler(costPages: pages))
        let snapshot = try await AnthropicAdminConnector(http: http).fetch(context(kind: .anthropicAPI, secret: key, budget: 40))

        let cost = snapshot.metrics.first { $0.id == "cost_month" }
        XCTAssertEqual(cost?.value ?? 0, 20.005, accuracy: 1e-9, "(1500.5 + 500) cents = $20.005")
        let budget = snapshot.metrics.first { $0.id == "budget_percent" }
        XCTAssertEqual(budget?.value ?? 0, 50.0125, accuracy: 1e-6)
        XCTAssertEqual(budget?.source, .derived)
        XCTAssertEqual(snapshot.metrics.first { $0.id == "tokens_input" }?.value, 1300)
        XCTAssertEqual(snapshot.metrics.first { $0.id == "tokens_output" }?.value, 500)

        let costRequests = http.requests.filter { $0.url!.path.hasSuffix("cost_report") }
        XCTAssertEqual(costRequests.count, 2)
        XCTAssertTrue(costRequests[1].url!.absoluteString.contains("page=page_2"))
        XCTAssertEqual(costRequests[0].value(forHTTPHeaderField: "x-api-key"), key)
        XCTAssertEqual(costRequests[0].value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertTrue(costRequests[0].url!.absoluteString.contains("starting_at=2026-09-01T00:00:00Z"))
        XCTAssertFalse(costRequests[0].url!.absoluteString.contains(key), "the key must never be in the URL")
    }

    func testAnthropicNoBudgetMeansNoPercentAndAnExplanatoryNote() async throws {
        let pages: [[String: Any]] = [["data": [["results": [["amount": "100"]]]], "has_more": false, "next_page": NSNull()]]
        let snapshot = try await AnthropicAdminConnector(http: StubHTTPClient(anthropicHandler(costPages: pages)))
            .fetch(context(kind: .anthropicAPI, secret: key))
        XCTAssertNil(snapshot.metrics.first { $0.id == "budget_percent" })
        XCTAssertTrue(snapshot.notes.contains { $0.contains("budget") })
    }

    func testAnthropicTokenFailureDoesNotDiscardCost() async throws {
        let pages: [[String: Any]] = [["data": [["results": [["amount": "250"]]]], "has_more": false, "next_page": NSNull()]]
        let snapshot = try await AnthropicAdminConnector(http: StubHTTPClient(anthropicHandler(costPages: pages, usageStatus: 500)))
            .fetch(context(kind: .anthropicAPI, secret: key))
        XCTAssertEqual(snapshot.metrics.first { $0.id == "cost_month" }?.value ?? 0, 2.5, accuracy: 1e-9)
        XCTAssertNil(snapshot.metrics.first { $0.id == "tokens_input" })
        XCTAssertTrue(snapshot.notes.contains { $0.hasPrefix("Tokens unavailable") })
    }

    func testAnthropicMissingKeyMakesNoRequest() async {
        let http = StubHTTPClient { _ in XCTFail("no request expected"); return StubHTTPClient.json([:]) }
        do {
            _ = try await AnthropicAdminConnector(http: http).fetch(context(kind: .anthropicAPI, secret: nil))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .missingCredential)
        }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testAnthropicMalformedAmountIsAnUnexpectedResponse() async {
        let pages: [[String: Any]] = [["data": [["results": [["amount": "not-a-number"]]]], "has_more": false, "next_page": NSNull()]]
        do {
            _ = try await AnthropicAdminConnector(http: StubHTTPClient(anthropicHandler(costPages: pages)))
                .fetch(context(kind: .anthropicAPI, secret: key))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unexpectedResponse)
        }
    }

    // MARK: - HTTP status handling (network errors)

    func testHTTPStatusesMapToProviderErrorsWithoutLeakingTheBody() async {
        let cases: [(Int, [String: String], ProviderError)] = [
            (401, [:], .unauthorized(hint: "Check the Admin key (sk-ant-admin01-…).")),
            (403, [:], .forbidden(hint: "The Admin API requires an organization Admin key; workspace keys and individual accounts are excluded.")),
            (429, ["retry-after": "42"], .rateLimited(retryAfter: 42)),
            (429, [:], .rateLimited(retryAfter: nil)),
            (503, [:], .server(status: 503)),
            (418, [:], .unexpectedResponse)
        ]
        for (status, headers, expected) in cases {
            let body = Data("{\"error\":\"leaked \(key)\"}".utf8)
            let http = StubHTTPClient { _ in HTTPResponse(status: status, data: body, headers: headers) }
            do {
                _ = try await AnthropicAdminConnector(http: http).fetch(context(kind: .anthropicAPI, secret: key))
                XCTFail("expected an error for \(status)")
            } catch let error as ProviderError {
                XCTAssertEqual(error, expected, "status \(status)")
                XCTAssertFalse(error.userMessage.contains(key), "error text must not contain the key")
            } catch {
                XCTFail("unexpected error type")
            }
        }
    }

    func testTransportErrorsPropagateAsProviderErrors() async {
        for expected in [ProviderError.timeout, .offline, .network(code: -1004)] {
            let http = StubHTTPClient { _ in throw expected }
            do {
                _ = try await OpenAIAdminConnector(http: http).fetch(context(kind: .openAIAPI, secret: "sk-admin-abc123456"))
                XCTFail("expected an error")
            } catch {
                XCTAssertEqual(error as? ProviderError, expected)
            }
        }
    }

    func testURLErrorMapping() {
        XCTAssertEqual(URLSessionHTTPClient.map(URLError(.timedOut)), .timeout)
        XCTAssertEqual(URLSessionHTTPClient.map(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(URLSessionHTTPClient.map(URLError(.networkConnectionLost)), .offline)
        XCTAssertEqual(URLSessionHTTPClient.map(URLError(.cannotFindHost)), .network(code: URLError.cannotFindHost.rawValue))
    }

    func testErrorClassification() {
        XCTAssertTrue(ProviderError.unauthorized(hint: "").isPermanentUntilEdited)
        XCTAssertFalse(ProviderError.timeout.isPermanentUntilEdited)
        XCTAssertTrue(ProviderError.unavailableOfficially(reason: "x").isInformational)
        XCTAssertFalse(ProviderError.server(status: 500).isInformational)
        XCTAssertEqual(ProviderError.rateLimited(retryAfter: 90).suggestedBackoff, 90)
    }

    // MARK: - OpenAI

    func testOpenAISumsCostsAndSendsBearerHeader() async throws {
        let http = StubHTTPClient { request in
            if request.url!.path.hasSuffix("costs") {
                return StubHTTPClient.json(["data": [
                    ["results": [["amount": ["value": 1.25, "currency": "usd"]]]],
                    ["results": [["amount": ["value": 2.0, "currency": "usd"]]]]
                ], "has_more": false, "next_page": NSNull()])
            }
            return StubHTTPClient.json(["data": [["results": [["input_tokens": 1000, "output_tokens": 250, "num_model_requests": 7]]]],
                                        "has_more": false, "next_page": NSNull()])
        }
        let snapshot = try await OpenAIAdminConnector(http: http).fetch(context(kind: .openAIAPI, secret: "sk-admin-abc123456", budget: 13))
        XCTAssertEqual(snapshot.metrics.first { $0.id == "cost_month" }?.value ?? 0, 3.25, accuracy: 1e-9)
        XCTAssertEqual(snapshot.metrics.first { $0.id == "budget_percent" }?.value ?? 0, 25, accuracy: 1e-9)
        XCTAssertEqual(snapshot.metrics.first { $0.id == "requests" }?.value, 7)
        let costRequest = http.requests.first { $0.url!.path.hasSuffix("costs") }!
        XCTAssertEqual(costRequest.value(forHTTPHeaderField: "Authorization"), "Bearer sk-admin-abc123456")
        XCTAssertTrue(costRequest.url!.absoluteString.contains("start_time=1788220800"), "2026-09-01T00:00:00Z as Unix seconds")
    }

    func testOpenAIRejectsNonUSDCurrency() async {
        let http = StubHTTPClient { _ in
            StubHTTPClient.json(["data": [["results": [["amount": ["value": 1.0, "currency": "eur"]]]]], "has_more": false, "next_page": NSNull()])
        }
        do {
            _ = try await OpenAIAdminConnector(http: http).fetch(context(kind: .openAIAPI, secret: "sk-admin-abc123456"))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unexpectedResponse)
        }
    }

    // MARK: - Manual entry (Codex)

    func testCodexWithoutManualValuesIsReportedAsUnavailableOfficially() async {
        do {
            _ = try await ManualConnector(kind: .codex).fetch(context(kind: .codex, secret: nil))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unavailableOfficially(reason: "Not available via an official API"))
        }
    }

    func testCodexManualValuesAreShownAsUserProvided() async throws {
        let manual = ManualQuota(usedPercent: 55, remainingText: nil, resetsAt: Fixtures.now.addingTimeInterval(7200), enteredAt: Fixtures.now)
        let snapshot = try await ManualConnector(kind: .codex).fetch(context(kind: .codex, secret: nil, manual: manual))
        XCTAssertEqual(snapshot.metrics.count, 1)
        XCTAssertEqual(snapshot.metrics[0].source, .userProvided)
        XCTAssertEqual(snapshot.metrics[0].percentUsed, 55)
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int
    init(_ value: Int) where Value == Int { self.value = value }
    /// Returns the previous value, then increments.
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; let old = value; value += 1; return old }
}
