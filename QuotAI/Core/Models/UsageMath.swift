import Foundation

enum UsageMath {
    /// Percent used = used / limit × 100. Returns nil if the limit is missing, zero, negative,
    /// or if a value is not finite. The result is not clamped (overshoot is possible).
    static func percent(used: Double, limit: Double?) -> Double? {
        guard let limit, limit > 0, limit.isFinite, used.isFinite, used >= 0 else { return nil }
        return used / limit * 100
    }

    static func remaining(used: Double, limit: Double?) -> Double? {
        guard let limit, limit > 0, limit.isFinite, used.isFinite else { return nil }
        return max(0, limit - used)
    }

    /// Value clamped to [0, 1] for a gauge.
    static func gaugeFraction(percent: Double?) -> Double {
        guard let percent, percent.isFinite else { return 0 }
        return min(max(percent / 100, 0), 1)
    }

    /// Start of the current month in UTC (the Admin APIs' daily buckets are UTC).
    static func startOfMonthUTC(containing date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let comps = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: comps)!
    }

    /// Start of next month in UTC: when a monthly budget resets.
    static func startOfNextMonthUTC(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(byAdding: .month, value: 1, to: startOfMonthUTC(containing: date))!
    }

    /// Anthropic's Admin APIs express amounts in the smallest unit (cents) as a decimal string.
    static func dollars(fromCentsString string: String) -> Double? {
        guard let cents = Double(string), cents.isFinite else { return nil }
        return cents / 100
    }
}
