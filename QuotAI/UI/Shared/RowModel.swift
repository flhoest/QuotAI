import SwiftUI

/// Visual tone of a connection (dot color, gauge color).
enum Tone: Equatable {
    case ok, warning, critical, neutral, error

    var color: Color {
        switch self {
        case .ok: return .green
        case .warning: return .orange
        case .critical, .error: return .red
        case .neutral: return .secondary
        }
    }

    static func forPercent(_ percent: Double?, warningThreshold: Double = 60, criticalThreshold: Double = 80) -> Tone {
        guard let percent else { return .neutral }
        if percent > criticalThreshold { return .critical }
        if percent > warningThreshold { return .warning }
        return .ok
    }
}

/// Everything the compact view needs for one connection. Pure data: unit-testable.
struct RowModel: Identifiable, Equatable {
    let id: UUID
    let title: String
    let symbol: String
    let kind: ProviderKind
    let tone: Tone
    /// Gauge fraction in 0...1, nil when no percentage is available.
    let fraction: Double?
    let valueText: String
    let subtitle: String?
    let statusText: String
    let isStale: Bool

    static func make(connection: Connection,
                     runtime: ConnectionRuntime,
                     showReset: Bool,
                     showRemaining: Bool,
                     now: Date,
                     warningThreshold: Double = 60,
                     criticalThreshold: Double = 80) -> RowModel {
        let descriptor = connection.descriptor
        let snapshot = runtime.snapshot
        let primary = snapshot?.primaryMetric(preferred: connection.primaryMetricID)
        let percent = primary?.percentUsed
        let fraction = percent.map { UsageMath.gaugeFraction(percent: $0) }

        var tone = Tone.forPercent(percent, warningThreshold: warningThreshold, criticalThreshold: criticalThreshold)
        var isStale = false
        var subtitle: String?

        switch runtime.status {
        case .failed(let error):
            tone = .error
            subtitle = error.userMessage
        case .stale(let error):
            tone = .warning
            isStale = true
            subtitle = "Outdated — \(error.userMessage)"
        case .notConfigured(let message), .unavailable(let message):
            tone = .neutral
            subtitle = message
        case .disabled:
            tone = .neutral
            subtitle = "Disabled"
        case .idle, .loading, .connected:
            var parts: [String] = []
            if let primary {
                if showReset, let reset = primary.resetsAt ?? snapshot?.nextReset(after: now), reset > now {
                    parts.append("resets in \(Formatters.timeUntil(reset, now: now))")
                }
                if showRemaining, primary.format == .percent, let remaining = primary.remaining {
                    parts.append("\(Formatters.percent(remaining)) remaining")
                }
                if primary.source == .userProvided { parts.append("entered by you") }
            } else if let snapshot, let note = snapshot.notes.first {
                subtitle = note
            } else if case .connected = runtime.status {
                subtitle = ProviderDescriptor.unavailableMessage
            }
            if subtitle == nil, !parts.isEmpty { subtitle = parts.joined(separator: " · ") }
            if subtitle == nil, case .loading = runtime.status { subtitle = "Refreshing…" }
        }

        let valueText: String
        if let primary {
            valueText = Formatters.value(of: primary)
        } else {
            valueText = "—"
        }

        return RowModel(id: connection.id,
                        title: connection.name,
                        symbol: descriptor.symbol,
                        kind: connection.kind,
                        tone: tone,
                        fraction: fraction,
                        valueText: valueText,
                        subtitle: subtitle,
                        statusText: runtime.status.label,
                        isStale: isStale)
    }
}
