import XCTest
@testable import QuotAI

final class ClaudeBridgeTests: XCTestCase {
    private var directory: URL!
    private var file: URL!

    override func setUp() {
        super.setUp()
        directory = Fixtures.temporaryDirectory()
        file = directory.appendingPathComponent("claude-code-status.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func fetch() async throws -> UsageSnapshot {
        try await ClaudeCodeBridgeConnector(fileURL: file)
            .fetch(FetchContext(connection: Connection(kind: .claudeCode), secret: nil, now: Fixtures.now))
    }

    private func write(_ json: String) throws { try json.write(to: file, atomically: true, encoding: .utf8) }

    func testParsesOfficialStatusLineRateLimits() async throws {
        let five = Int(Fixtures.now.timeIntervalSince1970) + 3 * 3600
        let seven = Int(Fixtures.now.timeIntervalSince1970) + 2 * 86400
        try write("""
        {"model":{"display_name":"Opus"},"rate_limits":{
          "five_hour":{"used_percentage":23.5,"resets_at":\(five)},
          "seven_day":{"used_percentage":41.2,"resets_at":\(seven)}}}
        """)
        let snapshot = try await fetch()
        XCTAssertEqual(snapshot.metrics.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(snapshot.metrics[0].percentUsed, 23.5)
        XCTAssertEqual(snapshot.metrics[0].resetsAt, Date(timeIntervalSince1970: TimeInterval(five)))
        XCTAssertEqual(snapshot.metrics[1].percentUsed, 41.2)
        XCTAssertTrue(snapshot.metrics.allSatisfy { $0.source == .official })
        XCTAssertNotNil(snapshot.dataAsOf)
    }

    func testMissingFileMeansBridgeNotInstalled() async {
        do { _ = try await fetch(); XCTFail("expected an error") }
        catch { XCTAssertEqual(error as? ProviderError, .bridgeNotInstalled) }
    }

    func testNoRateLimitsFieldIsInformationalNoData() async throws {
        try write(#"{"model":{"display_name":"Opus"}}"#)
        do { _ = try await fetch(); XCTFail("expected an error") }
        catch {
            guard case .noData = error as? ProviderError else { return XCTFail("got \(error)") }
            XCTAssertTrue((error as! ProviderError).isInformational)
        }
    }

    func testExpiredWindowsAreNotShownAsCurrentValues() async throws {
        let past = Int(Fixtures.now.timeIntervalSince1970) - 60
        let future = Int(Fixtures.now.timeIntervalSince1970) + 3600
        try write(#"{"rate_limits":{"five_hour":{"used_percentage":90,"resets_at":\#(past)},"seven_day":{"used_percentage":10,"resets_at":\#(future)}}}"#)
        let snapshot = try await fetch()
        XCTAssertEqual(snapshot.metrics.map(\.id), ["seven_day"], "a window that already reset must not show its old percentage")
        XCTAssertTrue(snapshot.notes.contains { $0.contains("reset") })

        try write(#"{"rate_limits":{"five_hour":{"used_percentage":90,"resets_at":\#(past)}}}"#)
        do { _ = try await fetch(); XCTFail("expected an error") }
        catch { guard case .noData = error as? ProviderError else { return XCTFail("got \(error)") } }
    }

    func testMalformedJSONIsAnUnexpectedResponse() async throws {
        try write("{not json")
        do { _ = try await fetch(); XCTFail("expected an error") }
        catch { XCTAssertEqual(error as? ProviderError, .unexpectedResponse) }
    }

    func testHelperScriptQuotesPathsAndSnippetIsValidJSON() throws {
        let spaced = directory.appendingPathComponent("Application Support/QuotAI", isDirectory: true)
        let data = spaced.appendingPathComponent("claude-code-status.json")
        let script = ClaudeBridge.scriptContents(dataFile: data)
        XCTAssertTrue(script.hasPrefix("#!/bin/sh"))
        XCTAssertTrue(script.contains("'\(data.path)'"))

        let scriptURL = try ClaudeBridge.installScript(scriptURL: spaced.appendingPathComponent("s.sh"), dataFile: data)
        XCTAssertTrue(ClaudeBridge.isScriptInstalled(scriptURL: scriptURL))

        let snippet = ClaudeBridge.settingsSnippet(scriptURL: scriptURL)
        let object = try JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: Any]
        let statusLine = object?["statusLine"] as? [String: String]
        XCTAssertEqual(statusLine?["type"], "command")
        XCTAssertEqual(statusLine?["command"], "'\(scriptURL.path)'")
    }

    func testInstalledScriptActuallyWritesStdinToTheDataFile() throws {
        let data = directory.appendingPathComponent("out dir/claude-code-status.json")
        let scriptURL = try ClaudeBridge.installScript(scriptURL: directory.appendingPathComponent("bridge.sh"), dataFile: data)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "'\(scriptURL.path)'"]
        let input = Pipe(); let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":4102444800}}}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty, "the script prints nothing")
        let written = try String(contentsOf: data, encoding: .utf8)
        XCTAssertTrue(written.contains("used_percentage"))
        let attributes = try FileManager.default.attributesOfItem(atPath: data.path)
        XCTAssertEqual((attributes[.posixPermissions] as? Int) ?? 0, 0o600, "owner-only permissions")
    }
}
