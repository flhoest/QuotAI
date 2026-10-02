import Foundation

enum Formatters {
    static let locale = Locale(identifier: "en_US")

    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value > 0 && value < 1 { return "<1%" }
        return "\(Int(value.rounded()))%"
    }

    static func usd(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").locale(locale))
    }

    static func tokens(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        switch abs(value) {
        case 1_000_000_000...: return String(format: "%.2fB", value / 1_000_000_000)
        case 1_000_000...: return String(format: "%.2fM", value / 1_000_000)
        case 1_000...: return String(format: "%.1fK", value / 1_000)
        default: return String(Int(value.rounded()))
        }
    }

    static func count(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number.locale(locale))
    }

    static func value(of metric: UsageMetric) -> String {
        switch metric.format {
        case .percent: return percent(metric.value)
        case .usd: return usd(metric.value)
        case .tokens: return tokens(metric.value)
        case .count: return count(metric.value)
        }
    }

    /// "2h 15m", "3d 4h", "12m", "<1m".
    static func timeUntil(_ date: Date, now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return "now" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(locale))
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(seconds / 60) min ago" }
        if seconds < 86_400 { return "\(seconds / 3_600) h ago" }
        return "\(seconds / 86_400) d ago"
    }

    static func sourceLabel(_ source: UsageMetric.Source) -> String {
        switch source {
        case .official: return "Official"
        case .derived: return "Computed from your budget"
        case .userProvided: return "Entered by you"
        }
    }
}
