import Foundation
import Combine

/// Owns the connections and their live state. Each connection refreshes independently: a failing
/// or slow provider never blocks the others.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var connections: [Connection] = []
    @Published private(set) var runtimes: [UUID: ConnectionRuntime] = [:]
    @Published private(set) var secretPresence: [UUID: Bool] = [:]
    @Published private(set) var lastRefreshCompleted: Date?

    private let repository: ConnectionRepository
    private let secrets: SecretStore
    private let cache: SnapshotCache
    private let connectorProvider: (ProviderKind) -> UsageConnector
    private let clock: () -> Date
    private let fetchTimeout: TimeInterval

    private var inFlight: Set<UUID> = []
    private var failureCounts: [UUID: Int] = [:]
    private var tickTask: Task<Void, Never>?

    init(repository: ConnectionRepository,
         secrets: SecretStore,
         cache: SnapshotCache,
         connectorProvider: @escaping (ProviderKind) -> UsageConnector,
         clock: @escaping () -> Date = Date.init,
         fetchTimeout: TimeInterval = 45) {
        self.repository = repository
        self.secrets = secrets
        self.cache = cache
        self.connectorProvider = connectorProvider
        self.clock = clock
        self.fetchTimeout = fetchTimeout
    }

    // MARK: - Lifecycle

    func load() {
        if let stored = repository.load() {
            connections = stored
        } else {
            connections = Self.defaultConnections()
            repository.save(connections)
        }
        let cached = cache.load()
        for connection in connections {
            var runtime = ConnectionRuntime()
            runtime.snapshot = cached[connection.id]
            runtime.status = initialStatus(for: connection, hasSnapshot: runtime.snapshot != nil)
            runtimes[connection.id] = runtime
            secretPresence[connection.id] = connection.descriptor.authMethod.needsSecret ? secrets.contains(account: connection.keychainAccount) : false
        }
    }

    /// Default connections. Those that need a key start disabled, so nothing fails before setup.
    static func defaultConnections() -> [Connection] {
        [
            Connection(kind: .claudeCode, isEnabled: true),
            Connection(kind: .anthropicAPI, isEnabled: false),
            Connection(kind: .openAIAPI, isEnabled: false),
            Connection(kind: .codex, isEnabled: true)
        ]
    }

    /// Starts the scheduler: a light tick decides which connections are due.
    func startScheduling(tickInterval: TimeInterval = 5) {
        tickTask?.cancel()
        tick()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(tickInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    func stopScheduling() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// Starts a refresh for every enabled connection that is due (and not already running).
    func tick() {
        let now = clock()
        for connection in connections where connection.isEnabled {
            let runtime = runtimes[connection.id] ?? ConnectionRuntime()
            if let next = runtime.nextAttempt {
                if next <= now { startRefresh(connection.id) }
            } else if runtime.lastAttempt == nil {
                startRefresh(connection.id)
            }
        }
    }

    // MARK: - Refresh

    /// User-initiated refresh (menu / button). Respects each provider's minimum interval so the
    /// APIs are not hammered; errors that require user action are retried immediately.
    func refreshAll() {
        let now = clock()
        for connection in connections where connection.isEnabled {
            let runtime = runtimes[connection.id] ?? ConnectionRuntime()
            if let last = runtime.lastAttempt, now.timeIntervalSince(last) < connection.descriptor.minimumRefreshInterval,
               case .connected = runtime.status { continue }
            startRefresh(connection.id)
        }
    }

    func refresh(_ id: UUID) {
        startRefresh(id)
    }

    private func startRefresh(_ id: UUID) {
        guard !inFlight.contains(id), let connection = connections.first(where: { $0.id == id }), connection.isEnabled else { return }
        inFlight.insert(id)
        var runtime = runtimes[id] ?? ConnectionRuntime()
        runtime.status = .loading
        runtimes[id] = runtime
        Task { [weak self] in
            await self?.performRefresh(connection)
        }
    }

    /// Awaitable refresh of one connection (used by `startRefresh` and by tests).
    func performRefresh(_ connection: Connection) async {
        inFlight.insert(connection.id)
        defer { inFlight.remove(connection.id) }

        let now = clock()
        var runtime = runtimes[connection.id] ?? ConnectionRuntime()
        runtime.lastAttempt = now

        let secret = readSecret(for: connection)
        if connection.descriptor.authMethod.needsSecret && secret == nil {
            runtime.status = .notConfigured("No key saved for this connection.")
            runtime.nextAttempt = nil
            runtimes[connection.id] = runtime
            return
        }

        do {
            let snapshot = try await fetch(connection: connection, secret: secret, now: now)
            failureCounts[connection.id] = 0
            runtime.snapshot = snapshot
            runtime.status = .connected
            runtime.nextAttempt = now.addingTimeInterval(connection.effectiveRefreshInterval)
            lastRefreshCompleted = clock()
        } catch is CancellationError {
            return
        } catch let error as ProviderError {
            apply(error, to: &runtime, connection: connection, now: now)
        } catch {
            apply(.unexpectedResponse, to: &runtime, connection: connection, now: now)
        }
        runtimes[connection.id] = runtime
        persistCache()
    }

    private func apply(_ error: ProviderError, to runtime: inout ConnectionRuntime, connection: Connection, now: Date) {
        if error.isInformational {
            // Data absent by nature (not an outage). An old value would be misleading, so drop it.
            runtime.snapshot = nil
            if case .missingCredential = error {
                runtime.status = .notConfigured(error.userMessage)
            } else {
                runtime.status = .unavailable(error.userMessage)
            }
            runtime.nextAttempt = now.addingTimeInterval(connection.effectiveRefreshInterval)
            return
        }
        let count = (failureCounts[connection.id] ?? 0) + 1
        failureCounts[connection.id] = count
        runtime.status = runtime.snapshot != nil ? .stale(error) : .failed(error)
        if error.isPermanentUntilEdited {
            runtime.nextAttempt = nil   // Retry only after the user changes the key or refreshes manually.
        } else {
            let base = connection.effectiveRefreshInterval
            let exponential = min(base * pow(2, Double(count - 1)), 30 * 60)
            runtime.nextAttempt = now.addingTimeInterval(max(exponential, error.suggestedBackoff ?? 0))
        }
    }

    private func fetch(connection: Connection, secret: String?, now: Date) async throws -> UsageSnapshot {
        let connector = connectorProvider(connection.kind)
        let context = FetchContext(connection: connection, secret: secret, now: now)
        let timeout = fetchTimeout
        return try await withThrowingTaskGroup(of: UsageSnapshot.self) { group in
            group.addTask { try await connector.fetch(context) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ProviderError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ProviderError.unexpectedResponse }
            return first
        }
    }

    // MARK: - Connection test (does not touch the stored state)

    /// Tests a connection with values that may not be saved yet (e.g. a key just typed in the form).
    func test(_ connection: Connection, secret: String?) async -> Result<UsageSnapshot, ProviderError> {
        // Prefer the key typed in the form; otherwise fall back to the one saved in the Keychain.
        let effective = (secret?.isEmpty == false) ? secret : readSecret(for: connection)
        if connection.descriptor.authMethod.needsSecret && (effective ?? "").isEmpty {
            return .failure(.missingCredential)
        }
        do {
            return .success(try await fetch(connection: connection, secret: effective, now: clock()))
        } catch let error as ProviderError {
            return .failure(error)
        } catch {
            return .failure(.unexpectedResponse)
        }
    }

    // MARK: - CRUD

    func add(_ connection: Connection) {
        connections.append(connection)
        runtimes[connection.id] = ConnectionRuntime(status: initialStatus(for: connection, hasSnapshot: false))
        secretPresence[connection.id] = false
        persistConnections()
        if connection.isEnabled { startRefresh(connection.id) }
    }

    func update(_ connection: Connection) {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        let old = connections[index]
        connections[index] = connection
        persistConnections()

        var runtime = runtimes[connection.id] ?? ConnectionRuntime()
        if !connection.isEnabled {
            runtime.status = .disabled
            runtime.nextAttempt = nil
            runtimes[connection.id] = runtime
            return
        }
        // Cosmetic edits (name, main value) must not trigger a network call.
        let needsRefresh = !old.isEnabled
            || old.manual != connection.manual
            || old.monthlyBudgetUSD != connection.monthlyBudgetUSD
            || old.refreshInterval != connection.refreshInterval
        guard needsRefresh else { return }
        failureCounts[connection.id] = 0
        runtime.nextAttempt = nil
        runtime.lastAttempt = nil
        if case .disabled = runtime.status { runtime.status = .idle }
        runtimes[connection.id] = runtime
        startRefresh(connection.id)
    }

    /// Reorders connections. Display order everywhere (panel, Details, this sidebar) is simply
    /// array order, so this is the only piece needed to let the user choose it.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        connections.move(fromOffsets: source, toOffset: destination)
        persistConnections()
    }

    func remove(_ id: UUID) {
        guard let connection = connections.first(where: { $0.id == id }) else { return }
        try? secrets.delete(account: connection.keychainAccount)
        connections.removeAll { $0.id == id }
        runtimes[id] = nil
        secretPresence[id] = nil
        failureCounts[id] = nil
        persistConnections()
        persistCache()
    }

    func setSecret(_ secret: String, for id: UUID) throws {
        guard let connection = connections.first(where: { $0.id == id }) else { return }
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try secrets.write(trimmed, account: connection.keychainAccount)
        secretPresence[id] = true
        failureCounts[id] = 0
        if connection.isEnabled { startRefresh(id) }
    }

    func removeSecret(for id: UUID) throws {
        guard let connection = connections.first(where: { $0.id == id }) else { return }
        try secrets.delete(account: connection.keychainAccount)
        secretPresence[id] = false
        var runtime = runtimes[id] ?? ConnectionRuntime()
        runtime.snapshot = nil
        runtime.status = connection.isEnabled ? .notConfigured("No key saved for this connection.") : .disabled
        runtime.nextAttempt = nil
        runtimes[id] = runtime
        persistCache()
    }

    func hasSecret(for id: UUID) -> Bool { secretPresence[id] ?? false }

    // MARK: - Queries

    func runtime(for id: UUID) -> ConnectionRuntime { runtimes[id] ?? ConnectionRuntime() }

    var enabledConnections: [Connection] { connections.filter(\.isEnabled) }

    // MARK: - Private

    private func readSecret(for connection: Connection) -> String? {
        guard connection.descriptor.authMethod.needsSecret else { return nil }
        // A Keychain read error (locked keychain, denied access) is treated like a missing key,
        // without ever logging the reason's payload.
        return (try? secrets.read(account: connection.keychainAccount)) ?? nil
    }

    private func initialStatus(for connection: Connection, hasSnapshot: Bool) -> ConnectionStatus {
        if !connection.isEnabled { return .disabled }
        if connection.descriptor.authMethod.needsSecret && !secrets.contains(account: connection.keychainAccount) {
            return .notConfigured("No key saved for this connection.")
        }
        return .idle
    }

    private func persistConnections() { repository.save(connections) }

    private func persistCache() {
        var snapshots: [UUID: UsageSnapshot] = [:]
        for (id, runtime) in runtimes { if let snapshot = runtime.snapshot { snapshots[id] = snapshot } }
        cache.save(snapshots)
    }
}
