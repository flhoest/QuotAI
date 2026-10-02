import Foundation

struct UsageMetric: Codable, Identifiable, Equatable, Sendable {
    enum Format: String, Codable, Sendable {
        case percent   // `value` is already a 0–100 percentage
        case usd
        case tokens
        case count
    }

    /// Where the value comes from, shown to the user.
    enum Source: String, Codable, Sendable {
        case official      // returned as-is by the official API / tool
        case derived       // computed by QuotAI from official data + a budget you entered
        case userProvided  // saisie manuellement
    }

    var id: String
    var label: String
    var value: Double
    /// Associated limit (same unit as `value`), if known.
    var limit: Double?
    var format: Format
    var resetsAt: Date?
    var source: Source

    /// Percent used (not clamped: may exceed 100).
    var percentUsed: Double? {
        switch format {
        case .percent: return value.isFinite ? value : nil
        default: return UsageMath.percent(used: value, limit: limit)
        }
    }

    var remaining: Double? {
        switch format {
        case .percent: return value.isFinite ? max(0, 100 - value) : nil
        default: return UsageMath.remaining(used: value, limit: limit)
        }
    }
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    /// When QuotAI obtained this data.
    var fetchedAt: Date
    /// When the source data dates from, if different (e.g. the Claude Code bridge file).
    var dataAsOf: Date?
    var metrics: [UsageMetric]
    var notes: [String]

    init(fetchedAt: Date, dataAsOf: Date? = nil, metrics: [UsageMetric], notes: [String] = []) {
        self.fetchedAt = fetchedAt
        self.dataAsOf = dataAsOf
        self.metrics = metrics
        self.notes = notes
    }

    /// Primary metric: the requested one, else the first with a percentage, else the first.
    func primaryMetric(preferred id: String?) -> UsageMetric? {
        if let id, let match = metrics.first(where: { $0.id == id }) { return match }
        return metrics.first(where: { $0.percentUsed != nil }) ?? metrics.first
    }

    /// Next known reset (the nearest one in the future).
    func nextReset(after now: Date) -> Date? {
        metrics.compactMap(\.resetsAt).filter { $0 > now }.min()
    }
}
