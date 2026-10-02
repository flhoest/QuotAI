import Foundation

/// Connector errors. Messages are intentionally generic: they never contain a key,
/// an authorization header or a raw response body.
enum ProviderError: Error, Equatable, Sendable {
    case missingCredential
    case unauthorized(hint: String)
    case forbidden(hint: String)
    case rateLimited(retryAfter: TimeInterval?)
    case timeout
    case offline
    case network(code: Int)
    case server(status: Int)
    case unexpectedResponse
    case bridgeNotInstalled
    case noData(reason: String)
    case unavailableOfficially(reason: String)

    var userMessage: String {
        switch self {
        case .missingCredential:
            return "No key saved for this connection."
        case .unauthorized(let hint):
            return "Key rejected by the provider. \(hint)"
        case .forbidden(let hint):
            return "Access denied by the provider. \(hint)"
        case .rateLimited(let retryAfter):
            if let retryAfter { return "Rate limit reached. Retrying in \(Int(retryAfter)) s." }
            return "Rate limit reached. Will retry later."
        case .timeout:
            return "The provider did not respond in time."
        case .offline:
            return "No network connection."
        case .network(let code):
            return "Network error (code \(code))."
        case .server(let status):
            return "Provider-side error (HTTP \(status))."
        case .unexpectedResponse:
            return "Unexpected response from the provider (unrecognized format)."
        case .bridgeNotInstalled:
            return "The Claude Code bridge is not installed yet."
        case .noData(let reason):
            return reason
        case .unavailableOfficially(let reason):
            return reason
        }
    }

    /// A "normal" condition (data absent by nature) rather than a failure.
    var isInformational: Bool {
        switch self {
        case .unavailableOfficially, .noData, .bridgeNotInstalled, .missingCredential: return true
        default: return false
        }
    }

    /// Errors that will not fix themselves: no automatic retry until the user changes something.
    var isPermanentUntilEdited: Bool {
        switch self {
        case .unauthorized, .forbidden, .missingCredential: return true
        default: return false
        }
    }

    /// Minimum delay before retrying (to respect API limits).
    var suggestedBackoff: TimeInterval? {
        switch self {
        case .rateLimited(let retryAfter): return retryAfter ?? 120
        case .server: return 120
        case .timeout, .offline, .network: return 30
        default: return nil
        }
    }
}
