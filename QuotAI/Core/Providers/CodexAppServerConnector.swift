import Foundation

/// Codex (ChatGPT subscription) usage, read from the `codex` CLI's own local JSON-RPC protocol
/// (`codex app-server`, method `account/rateLimits/read`) — the same source `/status` uses in the
/// interactive CLI. QuotAI briefly spawns `codex app-server` as a subprocess and talks to it only
/// over stdio; the codex process handles its own authentication (`codex login`), so QuotAI never
/// sees or stores any Codex credential.
///
/// This protocol has no public documentation page. Its shape was captured directly from the
/// installed CLI (`codex app-server generate-json-schema`) and confirmed with a live call; see
/// `ProviderDescriptor.codex` for the full caveat. If the live call fails for any reason — the
/// CLI is missing, not logged in, or the protocol changed on an update — this connector falls
/// back to whatever the user entered manually, clearly labelled as such.
struct CodexAppServerConnector: UsageConnector {
    let kind: ProviderKind = .codex
    var timeout: TimeInterval = 12
    var makeSession: @Sendable (URL) -> CodexAppServerSession
    var locate: @Sendable () -> URL?

    init(timeout: TimeInterval = 12,
        makeSession: @escaping @Sendable (URL) -> CodexAppServerSession = { ProcessCodexAppServerSession(executableURL: $0) },
        locate: @escaping @Sendable () -> URL? = { CodexCLILocator.locate() }) {
        self.timeout = timeout
        self.makeSession = makeSession
        self.locate = locate
    }

    func fetch(_ context: FetchContext) async throws -> UsageSnapshot {
        do {
            guard let executable = locate() else {
                throw ProviderError.noData(reason: "The codex CLI was not found. Install it (github.com/openai/codex) and run `codex login`, then refresh.")
            }
            let data = try await makeSession(executable).fetchRateLimits(timeout: timeout)
            return try Self.buildSnapshot(from: data, now: context.now)
        } catch {
            let providerError = (error as? ProviderError) ?? .unexpectedResponse
            let (manualMetrics, manualNotes) = ManualMetrics.metrics(from: context.connection.manual)
            guard !manualMetrics.isEmpty else { throw providerError }
            var notes = manualNotes
            notes.append("Live Codex data unavailable (\(providerError.userMessage)) — showing the value you entered manually instead.")
            return UsageSnapshot(fetchedAt: context.now, dataAsOf: context.connection.manual?.enteredAt,
                                 metrics: manualMetrics, notes: notes)
        }
    }

    // MARK: - Response decoding

    struct RateLimitsResult: Decodable {
        let rateLimits: Snapshot
        /// Extra, per-limit-id buckets (for example a specific model's own reserve). `"codex"` is
        /// the same bucket as `rateLimits` above (the CLI calls it "the backward-compatible
        /// single-bucket view"), so it is skipped when building extra metrics.
        let rateLimitsByLimitId: [String: Snapshot]?

        struct Snapshot: Decodable {
            let limitName: String?
            let normalModelSlug: String?
            let planType: String?
            let primary: Window?
            let secondary: Window?
            let credits: Credits?
        }
        struct Window: Decodable {
            let usedPercent: Double
            let resetsAt: Double?
            let windowDurationMins: Double?
        }
        struct Credits: Decodable {
            let hasCredits: Bool
            let unlimited: Bool
            let balance: String?
        }
    }

    static let mainLimitId = "codex"

    static func buildSnapshot(from data: Data, now: Date) throws -> UsageSnapshot {
        guard let decoded = try? JSONDecoder().decode(RateLimitsResult.self, from: data) else {
            throw ProviderError.unexpectedResponse
        }
        let snapshot = decoded.rateLimits

        var metrics: [UsageMetric] = []
        if let primary = snapshot.primary {
            metrics.append(UsageMetric(id: "primary", label: windowLabel(primary.windowDurationMins),
                                       value: primary.usedPercent, limit: nil, format: .percent,
                                       resetsAt: primary.resetsAt.map { Date(timeIntervalSince1970: $0) }, source: .official))
        }
        if let secondary = snapshot.secondary {
            metrics.append(UsageMetric(id: "secondary", label: windowLabel(secondary.windowDurationMins),
                                       value: secondary.usedPercent, limit: nil, format: .percent,
                                       resetsAt: secondary.resetsAt.map { Date(timeIntervalSince1970: $0) }, source: .official))
        }
        guard !metrics.isEmpty else {
            throw ProviderError.noData(reason: "Codex reported no active rate-limit window.")
        }

        // Extra per-model / per-feature reserves (e.g. a specific model's own weekly allowance),
        // shown by `/status` as their own rows. Each is keyed by its `limitId`; the main one
        // ("codex") is already covered by `primary`/`secondary` above.
        for (limitId, extra) in (decoded.rateLimitsByLimitId ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard limitId != mainLimitId, let window = extra.primary else { continue }
            let name = extra.normalModelSlug ?? extra.limitName ?? limitId
            metrics.append(UsageMetric(id: "extra_\(limitId)", label: "\(windowLabel(window.windowDurationMins)) (\(name))",
                                       value: window.usedPercent, limit: nil, format: .percent,
                                       resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) }, source: .official))
        }

        var notes: [String] = []
        if let plan = snapshot.planType { notes.append("Plan: \(plan).") }
        if let credits = snapshot.credits {
            if credits.unlimited {
                notes.append("Credits: unlimited.")
            } else if let balanceValue = credits.balance.flatMap(Double.init) {
                metrics.append(UsageMetric(id: "credits", label: "Credit balance", value: balanceValue,
                                           limit: nil, format: .count, resetsAt: nil, source: .official))
            }
        }
        return UsageSnapshot(fetchedAt: now, metrics: metrics, notes: notes)
    }

    /// Codex does not name its windows (only a duration in minutes), so the label is derived
    /// rather than assumed to always be "5 hours" / "weekly".
    static func windowLabel(_ minutes: Double?) -> String {
        guard let minutes, minutes.isFinite, minutes > 0 else { return "Usage limit" }
        let mins = Int64(minutes.rounded())
        if mins % 1_440 == 0 {
            let days = mins / 1_440
            return days == 7 ? "Weekly limit" : "\(days)-day limit"
        }
        if mins % 60 == 0 {
            return "\(mins / 60)-hour limit"
        }
        return "\(mins)-minute limit"
    }
}
