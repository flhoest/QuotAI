import Foundation

struct FetchContext: Sendable {
    let connection: Connection
    let secret: String?
    let now: Date
}

/// Common protocol: each provider is an independent connector.
/// A connector only throws `ProviderError` (messages free of secrets).
protocol UsageConnector: Sendable {
    var kind: ProviderKind { get }
    func fetch(_ context: FetchContext) async throws -> UsageSnapshot
}

enum ConnectorFactory {
    static func make(kind: ProviderKind,
                     http: HTTPClient,
                     bridgeFile: URL = ClaudeBridge.defaultDataFileURL) -> UsageConnector {
        switch kind {
        case .claudeCode: return ClaudeCodeBridgeConnector(fileURL: bridgeFile)
        case .anthropicAPI: return AnthropicAdminConnector(http: http)
        case .openAIAPI: return OpenAIAdminConnector(http: http)
        case .codex: return CodexAppServerConnector()
        }
    }
}

enum ISO8601 {
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

/// Metrics coming from manual entry (always marked `userProvided`).
enum ManualMetrics {
    static func metrics(from manual: ManualQuota?) -> (metrics: [UsageMetric], notes: [String]) {
        guard let manual, !manual.isEmpty else { return ([], []) }
        var metrics: [UsageMetric] = []
        var notes: [String] = []
        if let percent = manual.usedPercent {
            metrics.append(UsageMetric(id: "manual_percent", label: "Quota used (entered by you)", value: percent,
                                       limit: nil, format: .percent, resetsAt: manual.resetsAt, source: .userProvided))
        }
        if let text = manual.remainingText, !text.isEmpty {
            notes.append("Remaining (entered by you): \(text)")
        }
        return (metrics, notes)
    }
}
