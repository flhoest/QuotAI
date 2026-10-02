import Foundation

enum ConnectionStatus: Equatable, Sendable {
    case disabled
    case notConfigured(String)
    case idle
    case loading
    case connected
    /// The last attempt failed, but an older snapshot is kept.
    case stale(ProviderError)
    case failed(ProviderError)
    /// Data not available officially (a normal state, not an outage).
    case unavailable(String)

    var label: String {
        switch self {
        case .disabled: return "Disabled"
        case .notConfigured: return "Setup needed"
        case .idle: return "Waiting"
        case .loading: return "Refreshing…"
        case .connected: return "Connected"
        case .stale: return "Outdated data"
        case .failed: return "Error"
        case .unavailable: return "Not available"
        }
    }
}

/// Observable state of a connection, for the UI.
struct ConnectionRuntime: Equatable, Sendable {
    var status: ConnectionStatus = .idle
    var snapshot: UsageSnapshot?
    var lastAttempt: Date?
    var nextAttempt: Date?
}
