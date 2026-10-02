import Foundation

/// Network-free connector for providers whose subscription quotas are exposed by no official API
/// (Codex). Only shows what the user typed in, labelled as such.
struct ManualConnector: UsageConnector {
    let kind: ProviderKind

    func fetch(_ context: FetchContext) async throws -> UsageSnapshot {
        let (metrics, notes) = ManualMetrics.metrics(from: context.connection.manual)
        guard !metrics.isEmpty || !notes.isEmpty else {
            throw ProviderError.unavailableOfficially(reason: ProviderDescriptor.unavailableMessage)
        }
        return UsageSnapshot(fetchedAt: context.now,
                             dataAsOf: context.connection.manual?.enteredAt,
                             metrics: metrics,
                             notes: notes)
    }
}
