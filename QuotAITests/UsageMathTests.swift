import XCTest
@testable import QuotAI

final class UsageMathTests: XCTestCase {
    func testPercentBasic() {
        XCTAssertEqual(UsageMath.percent(used: 25, limit: 100), 25)
        XCTAssertEqual(UsageMath.percent(used: 1, limit: 3)!, 33.333, accuracy: 0.01)
        XCTAssertEqual(UsageMath.percent(used: 0, limit: 50), 0)
    }

    func testPercentIsNotClampedWhenOverLimit() {
        XCTAssertEqual(UsageMath.percent(used: 150, limit: 100), 150)
    }

    func testPercentRejectsInvalidInput() {
        XCTAssertNil(UsageMath.percent(used: 10, limit: nil))
        XCTAssertNil(UsageMath.percent(used: 10, limit: 0))
        XCTAssertNil(UsageMath.percent(used: 10, limit: -5))
        XCTAssertNil(UsageMath.percent(used: -1, limit: 100))
        XCTAssertNil(UsageMath.percent(used: .nan, limit: 100))
        XCTAssertNil(UsageMath.percent(used: 10, limit: .infinity))
    }

    func testRemaining() {
        XCTAssertEqual(UsageMath.remaining(used: 30, limit: 100), 70)
        XCTAssertEqual(UsageMath.remaining(used: 130, limit: 100), 0)
        XCTAssertNil(UsageMath.remaining(used: 30, limit: nil))
    }

    func testGaugeFractionIsClamped() {
        XCTAssertEqual(UsageMath.gaugeFraction(percent: 150), 1)
        XCTAssertEqual(UsageMath.gaugeFraction(percent: -10), 0)
        XCTAssertEqual(UsageMath.gaugeFraction(percent: nil), 0)
        XCTAssertEqual(UsageMath.gaugeFraction(percent: 50), 0.5)
    }

    func testMonthBoundsAreUTC() {
        let start = UsageMath.startOfMonthUTC(containing: Fixtures.now)
        XCTAssertEqual(ISO8601.string(start), "2026-09-01T00:00:00Z")
        XCTAssertEqual(ISO8601.string(UsageMath.startOfNextMonthUTC(after: Fixtures.now)), "2026-10-01T00:00:00Z")
        // December rolls over to January of the next year.
        let december = Date(timeIntervalSince1970: 1_798_000_000) // 2026-12-…
        XCTAssertEqual(ISO8601.string(UsageMath.startOfNextMonthUTC(after: december)), "2027-01-01T00:00:00Z")
    }

    func testAnthropicCentsToDollars() {
        XCTAssertEqual(UsageMath.dollars(fromCentsString: "123.45")!, 1.2345, accuracy: 1e-9)
        XCTAssertEqual(UsageMath.dollars(fromCentsString: "0")!, 0)
        XCTAssertNil(UsageMath.dollars(fromCentsString: "abc"))
    }

    func testMetricPercentUsedByFormat() {
        let percent = UsageMetric(id: "a", label: "a", value: 23.5, limit: nil, format: .percent, resetsAt: nil, source: .official)
        XCTAssertEqual(percent.percentUsed, 23.5)
        XCTAssertEqual(percent.remaining!, 76.5, accuracy: 1e-9)
        let usd = UsageMetric(id: "b", label: "b", value: 50, limit: 200, format: .usd, resetsAt: nil, source: .official)
        XCTAssertEqual(usd.percentUsed, 25)
        let noLimit = UsageMetric(id: "c", label: "c", value: 50, limit: nil, format: .usd, resetsAt: nil, source: .official)
        XCTAssertNil(noLimit.percentUsed)
    }

    func testPrimaryMetricSelection() {
        let cost = UsageMetric(id: "cost", label: "Cost", value: 5, limit: nil, format: .usd, resetsAt: nil, source: .official)
        let pct = UsageMetric(id: "pct", label: "Pct", value: 10, limit: nil, format: .percent, resetsAt: nil, source: .derived)
        let snapshot = UsageSnapshot(fetchedAt: Fixtures.now, metrics: [cost, pct])
        XCTAssertEqual(snapshot.primaryMetric(preferred: nil)?.id, "pct", "prefers a metric that has a percentage")
        XCTAssertEqual(snapshot.primaryMetric(preferred: "cost")?.id, "cost")
        XCTAssertEqual(snapshot.primaryMetric(preferred: "missing")?.id, "pct")
    }
}
