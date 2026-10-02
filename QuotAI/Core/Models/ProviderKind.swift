import Foundation

/// Kind of provider / access method. One AI vendor may have several distinct connectors
/// (e.g. Claude subscription vs. Claude API) because the officially accessible data differs.
enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case anthropicAPI
    case openAIAPI
    case codex

    var id: String { rawValue }
}

/// How the user grants access (never an account password, browser cookie or session token).
enum AuthMethod: Equatable, Sendable {
    /// Reads a local file written by the vendor's own official tool.
    case localBridge
    /// Talks to a local process of the vendor's own CLI, already authenticated by the user
    /// (e.g. `codex login`). QuotAI never sees or stores the underlying credential.
    case localProcess(description: String)
    /// Admin key (official API), stored in the Keychain.
    case adminKey(placeholder: String)
    /// Standard API key, stored in the Keychain.
    case apiKey(placeholder: String)
    /// No official API: optional manual entry.
    case manualOnly

    var needsSecret: Bool {
        switch self {
        case .adminKey, .apiKey: return true
        case .localBridge, .localProcess, .manualOnly: return false
        }
    }
}

enum Availability: Equatable, Sendable {
    case official
    case userProvided
    case unavailable
}

struct Capability: Equatable, Identifiable, Sendable {
    var id: String { title }
    let title: String
    let availability: Availability
    let detail: String
}

struct SourceReference: Equatable, Identifiable, Sendable {
    var id: String { url.absoluteString }
    let title: String
    let url: URL
}

/// Static provider metadata: real capabilities, permissions, sources.
struct ProviderDescriptor: Sendable {
    let kind: ProviderKind
    let displayName: String
    let shortName: String
    let symbol: String
    let authMethod: AuthMethod
    let summary: String
    let requiredPermissions: [String]
    let capabilities: [Capability]
    let sources: [SourceReference]
    /// Date on which the chosen method was checked against the official documentation.
    let verifiedOn: String
    let accountURL: URL
    let accountLinkTitle: String
    /// Minimum refresh interval (seconds) that respects the API's limits.
    let minimumRefreshInterval: TimeInterval
    let defaultRefreshInterval: TimeInterval
    let supportsBudget: Bool
    let supportsManualEntry: Bool

    static let unavailableMessage = "Not available via an official API"

    static func descriptor(for kind: ProviderKind) -> ProviderDescriptor {
        switch kind {
        case .claudeCode: return claudeCode
        case .anthropicAPI: return anthropicAPI
        case .openAIAPI: return openAIAPI
        case .codex: return codex
        }
    }

    static let verificationDate = "2026-09-24"

    static let claudeCode = ProviderDescriptor(
        kind: .claudeCode,
        displayName: "Claude (Pro/Max subscription)",
        shortName: "Claude",
        symbol: "sparkle",
        authMethod: .localBridge,
        summary: "Claude subscription limits, read from the \"statusLine\" JSON that Claude Code hands to a local script.",
        requiredPermissions: [
            "No account credentials, cookies or tokens.",
            "A local script (installed only with your consent) saves Claude Code's statusLine output to ~/Library/Application Support/QuotAI.",
            "A Claude Pro or Max subscription, and Claude Code run at least once (limits only appear after the first response of a session)."
        ],
        capabilities: [
            Capability(title: "% of the session limit (5 h)", availability: .official,
                       detail: "rate_limits.five_hour.used_percentage"),
            Capability(title: "% of the weekly limit", availability: .official,
                       detail: "rate_limits.seven_day.used_percentage"),
            Capability(title: "Reset time", availability: .official,
                       detail: "resets_at (Unix seconds)"),
            Capability(title: "Continuous updates", availability: .unavailable,
                       detail: "Data is only refreshed while Claude Code is running.")
        ],
        sources: [
            SourceReference(title: "Claude Code — Status line (rate_limits field)",
                            url: URL(string: "https://code.claude.com/docs/en/statusline")!),
            SourceReference(title: "Claude Help Center — Usage limits",
                            url: URL(string: "https://support.claude.com/en/articles/11647753-how-do-usage-and-length-limits-work")!)
        ],
        verifiedOn: verificationDate,
        accountURL: URL(string: "https://claude.ai/settings/usage")!,
        accountLinkTitle: "Open usage on claude.ai",
        minimumRefreshInterval: 5,
        defaultRefreshInterval: 30,
        supportsBudget: false,
        supportsManualEntry: false
    )

    static let anthropicAPI = ProviderDescriptor(
        kind: .anthropicAPI,
        displayName: "Claude API (Console)",
        shortName: "Claude API",
        symbol: "chevron.left.forwardslash.chevron.right",
        authMethod: .adminKey(placeholder: "sk-ant-admin01-…"),
        summary: "Month-to-date cost (USD) and tokens from the \"Usage & Cost\" Admin API. Does not cover the Claude subscription.",
        requiredPermissions: [
            "An Admin API key (sk-ant-admin01-…) created in the Claude Console, or an OAuth token with the org:admin scope.",
            "Workspace API keys do not work.",
            "Organizations only: the Admin API is unavailable for individual accounts."
        ],
        capabilities: [
            Capability(title: "Month-to-date cost (USD)", availability: .official,
                       detail: "GET /v1/organizations/cost_report"),
            Capability(title: "Month-to-date tokens (input, output, cache)", availability: .official,
                       detail: "GET /v1/organizations/usage_report/messages"),
            Capability(title: "% of monthly budget", availability: .userProvided,
                       detail: "Computed by QuotAI from the budget you enter; no API returns your spending cap."),
            Capability(title: "Claude subscription quota", availability: .unavailable,
                       detail: "Not covered by the Admin API (see the \"Claude subscription\" connector).")
        ],
        sources: [
            SourceReference(title: "Usage and Cost API",
                            url: URL(string: "https://platform.claude.com/docs/en/manage-claude/usage-cost-api")!),
            SourceReference(title: "Reference — Get Cost Report",
                            url: URL(string: "https://platform.claude.com/docs/en/api/admin-api/usage-cost/get-cost-report")!),
            SourceReference(title: "Reference — Get Messages Usage Report",
                            url: URL(string: "https://platform.claude.com/docs/en/api/admin-api/usage-cost/get-messages-usage-report")!)
        ],
        verifiedOn: verificationDate,
        accountURL: URL(string: "https://platform.claude.com/usage")!,
        accountLinkTitle: "Open Usage in the Claude Console",
        minimumRefreshInterval: 60,
        defaultRefreshInterval: 300,
        supportsBudget: true,
        supportsManualEntry: false
    )

    static let openAIAPI = ProviderDescriptor(
        kind: .openAIAPI,
        displayName: "OpenAI API (platform)",
        shortName: "OpenAI API",
        symbol: "cpu",
        authMethod: .adminKey(placeholder: "sk-admin-…"),
        summary: "Month-to-date cost (USD) and tokens from the organization \"Usage\" and \"Costs\" endpoints. Does not cover the ChatGPT/Codex subscription.",
        requiredPermissions: [
            "An OpenAI Admin API key, distinct from regular API keys.",
            "Created by an organization owner in the OpenAI platform settings."
        ],
        capabilities: [
            Capability(title: "Month-to-date cost (USD)", availability: .official,
                       detail: "GET /v1/organization/costs"),
            Capability(title: "Month-to-date tokens and requests", availability: .official,
                       detail: "GET /v1/organization/usage/completions"),
            Capability(title: "% of monthly budget", availability: .userProvided,
                       detail: "Computed by QuotAI from the budget you enter."),
            Capability(title: "ChatGPT / Codex subscription quota", availability: .unavailable,
                       detail: "Not covered by these endpoints (see the \"Codex\" connector).")
        ],
        sources: [
            SourceReference(title: "API reference — Costs",
                            url: URL(string: "https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage/methods/costs")!),
            SourceReference(title: "Cookbook — Usage API and Costs API",
                            url: URL(string: "https://developers.openai.com/cookbook/examples/completions_usage_api")!)
        ],
        verifiedOn: verificationDate,
        accountURL: URL(string: "https://platform.openai.com/usage")!,
        accountLinkTitle: "Open Usage on platform.openai.com",
        minimumRefreshInterval: 60,
        defaultRefreshInterval: 300,
        supportsBudget: true,
        supportsManualEntry: false
    )

    static let codex = ProviderDescriptor(
        kind: .codex,
        displayName: "Codex (ChatGPT subscription)",
        shortName: "Codex",
        symbol: "terminal",
        authMethod: .localProcess(description: "Runs `codex app-server` locally and calls its `account/rateLimits/read` method, using your existing `codex login` session."),
        summary: "No public API or CLI flag documents Codex subscription quotas (OpenAI's own docs point only to /status or the dashboard). QuotAI instead calls the same internal method the codex CLI itself uses for that, by briefly running `codex app-server` locally and speaking its JSON-RPC protocol over stdio. This protocol has no published documentation page: its shape was captured directly from your installed CLI (`codex app-server generate-json-schema`) and verified with a real, live call. It may change without notice on a codex CLI update — if it ever stops working, QuotAI falls back to whatever you entered manually below.",
        requiredPermissions: [
            "The `codex` CLI installed and already signed in (`codex login`); QuotAI does not read or store its credentials — the codex process handles its own authentication.",
            "QuotAI launches `codex app-server` as a short-lived local subprocess for each refresh and talks to it only over stdio (no separate network call from QuotAI itself; the codex process makes its own call to OpenAI, exactly as `/status` would)."
        ],
        capabilities: [
            Capability(title: "% of the current usage window used", availability: .official,
                       detail: "account/rateLimits/read → rateLimits.primary.usedPercent (undocumented but verified live protocol; typically the 5-hour window)"),
            Capability(title: "% of the secondary window used", availability: .official,
                       detail: "account/rateLimits/read → rateLimits.secondary.usedPercent (typically the weekly window)"),
            Capability(title: "Reset time for each window", availability: .official,
                       detail: "rateLimits.primary/secondary.resetsAt (Unix seconds)"),
            Capability(title: "Optional manual entry", availability: .userProvided,
                       detail: "Used automatically as a fallback if the live call fails (CLI missing, not logged in, or protocol changed), always labelled as entered by you.")
        ],
        sources: [
            SourceReference(title: "OpenAI Codex CLI (source of the `codex` command)",
                            url: URL(string: "https://github.com/openai/codex")!),
            SourceReference(title: "OpenAI Help — Using Codex with your ChatGPT plan",
                            url: URL(string: "https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan")!)
        ],
        verifiedOn: verificationDate,
        accountURL: URL(string: "https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan")!,
        accountLinkTitle: "Where to see my Codex usage (OpenAI Help)",
        minimumRefreshInterval: 20,
        defaultRefreshInterval: 90,
        supportsBudget: false,
        supportsManualEntry: true
    )

}
