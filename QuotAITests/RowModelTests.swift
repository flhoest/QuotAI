import XCTest
@testable import QuotAI

final class RowModelTests: XCTestCase {
    private func make(_ connection: Connection, _ runtime: ConnectionRuntime,
                      reset: Bool = true, remaining: Bool = true) -> RowModel {
        RowModel.make(connection: connection, runtime: runtime, showReset: reset, showRemaining: remaining, now: Fixtures.now)
    }

    func testConnectedRowShowsPercentResetAndRemaining() {
        let runtime = ConnectionRuntime(status: .connected, snapshot: Fixtures.snapshot(percent: 62))
        let row = make(Connection(kind: .claudeCode), runtime)
        XCTAssertEqual(row.valueText, "62%")
        XCTAssertEqual(row.fraction ?? 0, 0.62, accuracy: 1e-9)
        XCTAssertEqual(row.tone, .warning)
        XCTAssertEqual(row.subtitle, "resets in 1h 0m · 38% remaining")
    }

    func testDisplayOptionsHideResetAndRemaining() {
        let runtime = ConnectionRuntime(status: .connected, snapshot: Fixtures.snapshot(percent: 10))
        let row = make(Connection(kind: .claudeCode), runtime, reset: false, remaining: false)
        XCTAssertNil(row.subtitle)
        XCTAssertEqual(row.tone, .ok)
    }

    func testTonesFollowThresholds() {
        XCTAssertEqual(Tone.forPercent(60), .ok)
        XCTAssertEqual(Tone.forPercent(60.1), .warning)
        XCTAssertEqual(Tone.forPercent(80), .warning)
        XCTAssertEqual(Tone.forPercent(80.1), .critical)
        XCTAssertEqual(Tone.forPercent(100), .critical)
        XCTAssertEqual(Tone.forPercent(nil), .neutral)
    }

    func testOverLimitGaugeIsClampedButTextIsNot() {
        let runtime = ConnectionRuntime(status: .connected, snapshot: Fixtures.snapshot(percent: 130))
        let row = make(Connection(kind: .claudeCode), runtime)
        XCTAssertEqual(row.fraction, 1)
        XCTAssertEqual(row.valueText, "130%")
    }

    func testUnavailableOfficiallyIsShownVerbatim() {
        let runtime = ConnectionRuntime(status: .unavailable(ProviderDescriptor.unavailableMessage), snapshot: nil)
        let row = make(Connection(kind: .codex), runtime)
        XCTAssertEqual(row.subtitle, "Not available via an official API")
        XCTAssertEqual(row.valueText, "—")
        XCTAssertNil(row.fraction)
        XCTAssertEqual(row.tone, .neutral)
    }

    func testErrorAndStaleStates() {
        let failed = make(Connection(kind: .openAIAPI), ConnectionRuntime(status: .failed(.offline), snapshot: nil))
        XCTAssertEqual(failed.tone, .error)
        XCTAssertEqual(failed.subtitle, "No network connection.")

        let stale = make(Connection(kind: .claudeCode), ConnectionRuntime(status: .stale(.timeout), snapshot: Fixtures.snapshot(percent: 20)))
        XCTAssertTrue(stale.isStale)
        XCTAssertEqual(stale.valueText, "20%", "the last known value remains visible")
        XCTAssertTrue(stale.subtitle?.hasPrefix("Outdated") == true)
    }

    func testCostOnlyProviderShowsDollarsWithoutGauge() {
        let snapshot = UsageSnapshot(fetchedAt: Fixtures.now, metrics: [
            UsageMetric(id: "cost_month", label: "Cost this month", value: 12.5, limit: nil, format: .usd,
                        resetsAt: Fixtures.now.addingTimeInterval(86_400), source: .official)])
        let row = make(Connection(kind: .anthropicAPI), ConnectionRuntime(status: .connected, snapshot: snapshot))
        XCTAssertEqual(row.valueText, "$12.50")
        XCTAssertNil(row.fraction)
    }

    func testFormatters() {
        XCTAssertEqual(Formatters.percent(23.4), "23%")
        XCTAssertEqual(Formatters.percent(0.3), "<1%")
        XCTAssertEqual(Formatters.tokens(1_500), "1.5K")
        XCTAssertEqual(Formatters.tokens(2_340_000), "2.34M")
        XCTAssertEqual(Formatters.timeUntil(Fixtures.now.addingTimeInterval(2 * 86_400 + 4 * 3600), now: Fixtures.now), "2d 4h")
        XCTAssertEqual(Formatters.timeUntil(Fixtures.now.addingTimeInterval(45), now: Fixtures.now), "<1m")
        XCTAssertEqual(Formatters.timeUntil(Fixtures.now.addingTimeInterval(-5), now: Fixtures.now), "now")
    }
}
