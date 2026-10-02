import Foundation

/// Values typed in by the user when no official API exists.
/// Never presented as official data.
struct ManualQuota: Codable, Equatable, Sendable {
    var usedPercent: Double?
    var remainingText: String?
    var resetsAt: Date?
    var enteredAt: Date

    var isEmpty: Bool {
        usedPercent == nil && (remainingText?.isEmpty ?? true) && resetsAt == nil
    }
}

/// A user-configured connection. Contains NO secret: any key is in the Keychain,
/// under the account `id.uuidString`.
struct Connection: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var kind: ProviderKind
    var name: String
    var isEnabled: Bool
    /// Refresh interval in seconds.
    var refreshInterval: TimeInterval
    /// Monthly budget (USD) entered by the user, used to compute a percentage for API providers.
    var monthlyBudgetUSD: Double?
    /// ID of the metric shown as primary (the compact view gauge).
    var primaryMetricID: String?
    var manual: ManualQuota?

    init(id: UUID = UUID(),
         kind: ProviderKind,
         name: String? = nil,
         isEnabled: Bool = true,
         refreshInterval: TimeInterval? = nil,
         monthlyBudgetUSD: Double? = nil,
         primaryMetricID: String? = nil,
         manual: ManualQuota? = nil) {
        let descriptor = ProviderDescriptor.descriptor(for: kind)
        self.id = id
        self.kind = kind
        self.name = name ?? descriptor.shortName
        self.isEnabled = isEnabled
        self.refreshInterval = refreshInterval ?? descriptor.defaultRefreshInterval
        self.monthlyBudgetUSD = monthlyBudgetUSD
        self.primaryMetricID = primaryMetricID
        self.manual = manual
    }

    var descriptor: ProviderDescriptor { ProviderDescriptor.descriptor(for: kind) }

    /// Effective interval, clamped to the minimum the provider tolerates.
    var effectiveRefreshInterval: TimeInterval {
        max(refreshInterval, descriptor.minimumRefreshInterval)
    }

    /// Keychain account tied to this connection.
    var keychainAccount: String { id.uuidString }
}
