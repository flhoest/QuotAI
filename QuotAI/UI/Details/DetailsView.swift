import SwiftUI

/// Details panel: every metric with its source, status, notes and errors.
struct DetailsView: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject private var store: UsageStore
    @ObservedObject var focus: DetailsFocus

    init(environment: AppEnvironment, focus: DetailsFocus) {
        self.environment = environment
        self.store = environment.store
        self.focus = focus
    }

    /// The single connection a row click asked to see, if it still exists. Clicking a provider
    /// in the panel means "show me that provider" — not a scroll position in a list of everyone
    /// else's data too.
    private var focusedConnection: Connection? {
        focus.id.flatMap { id in store.connections.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let connection = focusedConnection {
                HStack {
                    Button {
                        focus.id = nil
                    } label: {
                        Label("All Connections", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.top, 12)

                ScrollView {
                    ConnectionCard(connection: connection,
                                   runtime: store.runtime(for: connection.id),
                                   onRefresh: { store.refresh(connection.id) },
                                   warningThreshold: environment.settings.warningThreshold,
                                   criticalThreshold: environment.settings.criticalThreshold)
                        .padding(16)
                }
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        if store.connections.isEmpty {
                            Text("No connections configured.").foregroundStyle(.secondary).padding(.top, 40)
                        }
                        ForEach(store.connections) { connection in
                            ConnectionCard(connection: connection,
                                           runtime: store.runtime(for: connection.id),
                                           onRefresh: { store.refresh(connection.id) },
                                           warningThreshold: environment.settings.warningThreshold,
                                           criticalThreshold: environment.settings.criticalThreshold)
                                .onTapGesture { focus.id = connection.id }
                        }
                    }
                    .padding(16)
                }
            }
            Divider()
            HStack {
                Button("Refresh All") { environment.refreshAll() }
                Spacer()
                Button("Settings…") { environment.showSettings() }
            }
            .padding(10)
        }
        .frame(minWidth: 380, minHeight: 220)
        .animation(.easeOut(duration: 0.15), value: focus.id)
    }
}

/// Mirrors `DetailsView`'s content but with a plain `VStack` where the real view uses a
/// `ScrollView`, used only to measure the Details window's ideal height. A `ScrollView`'s
/// preferred size, when asked via `NSHostingController.sizeThatFits(in:)`, is just whatever
/// height it was proposed — that's what lets it scroll — never the actual height its content
/// needs, so measuring the real, scrollable `DetailsView` this way always reported back the
/// full proposed height instead of shrinking to fit. A plain `VStack`'s height genuinely is
/// the sum of its content, so this is measured instead; the on-screen window still shows the
/// real `DetailsView`, scrolling remaining a safety net for the rare case content is taller
/// than the screen itself.
struct DetailsMeasurementView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var focus: DetailsFocus

    private var focusedConnection: Connection? {
        focus.id.flatMap { id in store.connections.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let connection = focusedConnection {
                HStack {
                    Label("All Connections", systemImage: "chevron.left")
                        .font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.top, 12)
                ConnectionCard(connection: connection, runtime: store.runtime(for: connection.id), onRefresh: {})
                    .padding(16)
            } else {
                VStack(spacing: 12) {
                    if store.connections.isEmpty {
                        Text("No connections configured.").foregroundStyle(.secondary).padding(.top, 40)
                    }
                    ForEach(store.connections) { connection in
                        ConnectionCard(connection: connection, runtime: store.runtime(for: connection.id), onRefresh: {})
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                Button("Refresh All") {}
                Spacer()
                Button("Settings…") {}
            }
            .padding(10)
        }
        .frame(minWidth: 380)
    }
}

struct ConnectionCard: View {
    let connection: Connection
    let runtime: ConnectionRuntime
    let onRefresh: () -> Void
    var warningThreshold: Double = 60
    var criticalThreshold: Double = 80

    var body: some View {
        let descriptor = connection.descriptor
        let now = Date()
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Group {
                    if let brandLogo = connection.kind.brandLogo {
                        brandLogo.resizable().scaledToFit().frame(width: 15, height: 15)
                    } else {
                        Image(systemName: descriptor.symbol)
                    }
                }
                .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(connection.name).font(.headline)
                    if connection.name != descriptor.displayName {
                        Text(descriptor.displayName).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                StatusBadge(status: runtime.status)
            }

            if let snapshot = runtime.snapshot {
                VStack(spacing: 6) {
                    ForEach(snapshot.metrics) { metric in
                        MetricRow(metric: metric, now: now,
                                  warningThreshold: warningThreshold, criticalThreshold: criticalThreshold)
                    }
                }
                ForEach(snapshot.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Text("Fetched \(Formatters.clock(snapshot.fetchedAt))")
                    if let asOf = snapshot.dataAsOf {
                        Text("Source data from \(Formatters.clock(asOf)) (\(Formatters.ago(asOf, now: now)))")
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }

            switch runtime.status {
            case .failed(let error), .stale(let error):
                Label(error.userMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case .unavailable(let message), .notConfigured(let message):
                Label(message, systemImage: "minus.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }

            HStack {
                Button("Refresh", action: onRefresh)
                    .controlSize(.small)
                    .disabled(!connection.isEnabled)
                Link(descriptor.accountLinkTitle, destination: descriptor.accountURL)
                    .font(.caption)
                Spacer()
                Text("Method verified \(descriptor.verifiedOn)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct StatusBadge: View {
    let status: ConnectionStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(status.label).font(.caption)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.15)))
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch status {
        case .connected: return .green
        case .stale: return .orange
        case .failed: return .red
        case .loading: return .blue
        case .disabled, .notConfigured, .idle, .unavailable: return .secondary
        }
    }
}

struct MetricRow: View {
    let metric: UsageMetric
    let now: Date
    var warningThreshold: Double = 60
    var criticalThreshold: Double = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(metric.label).font(.subheadline)
                Spacer()
                Text(Formatters.value(of: metric)).font(.subheadline.monospacedDigit().weight(.semibold))
            }
            if let percent = metric.percentUsed {
                LinearGauge(fraction: UsageMath.gaugeFraction(percent: percent),
                            tone: Tone.forPercent(percent, warningThreshold: warningThreshold, criticalThreshold: criticalThreshold))
            }
            HStack(spacing: 8) {
                Text(Formatters.sourceLabel(metric.source))
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                if let reset = metric.resetsAt, reset > now {
                    Text("Resets in \(Formatters.timeUntil(reset, now: now)) (\(Formatters.clock(reset)))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
