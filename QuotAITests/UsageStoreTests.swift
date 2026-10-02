import XCTest
@testable import QuotAI

@MainActor
final class UsageStoreTests: XCTestCase {
    private var clock: Date = Fixtures.now
    private var secrets = InMemorySecretStore()

    private func makeStore(_ connectors: [ProviderKind: FakeConnector],
                           connections: [Connection],
                           timeout: TimeInterval = 5) -> UsageStore {
        let store = UsageStore(repository: InMemoryConnectionRepository(connections),
                               secrets: secrets,
                               cache: InMemorySnapshotCache(),
                               connectorProvider: { connectors[$0] ?? FakeConnector(kind: $0, results: [.failure(.unexpectedResponse)]) },
                               clock: { [unowned self] in self.clock },
                               fetchTimeout: timeout)
        store.load()
        return store
    }

    private func settle(_ store: UsageStore) async {
        // Let any Task started by `startRefresh` finish.
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            if store.connections.allSatisfy({ if case .loading = store.runtime(for: $0.id).status { return false } else { return true } }) { return }
        }
    }

    func testSuccessfulRefreshStoresSnapshotAndSchedulesNextAttempt() async {
        let connection = Connection(kind: .claudeCode, refreshInterval: 60)
        let connector = FakeConnector(kind: .claudeCode, results: [.success(Fixtures.snapshot(percent: 30))])
        let store = makeStore([.claudeCode: connector], connections: [connection])

        await store.performRefresh(connection)

        let runtime = store.runtime(for: connection.id)
        XCTAssertEqual(runtime.status, .connected)
        XCTAssertEqual(runtime.snapshot?.metrics.first?.value, 30)
        XCTAssertEqual(runtime.nextAttempt, clock.addingTimeInterval(60))
    }

    func testRefreshIntervalIsClampedToTheProviderMinimum() async {
        var connection = Connection(kind: .anthropicAPI)
        connection.refreshInterval = 5      // below the 60 s minimum of the Admin API
        try? secrets.write("sk-ant-admin01-abcdef123456", account: connection.keychainAccount)
        let connector = FakeConnector(kind: .anthropicAPI, results: [.success(Fixtures.snapshot())])
        let store = makeStore([.anthropicAPI: connector], connections: [connection])

        await store.performRefresh(connection)
        XCTAssertEqual(store.runtime(for: connection.id).nextAttempt, clock.addingTimeInterval(60))
    }

    func testOneFailingProviderDoesNotAffectTheOthers() async {
        let good = Connection(kind: .claudeCode)
        let bad = Connection(kind: .codex)
        let goodConnector = FakeConnector(kind: .claudeCode, results: [.success(Fixtures.snapshot(percent: 12))])
        let badConnector = FakeConnector(kind: .codex, results: [.failure(.server(status: 500))])
        let store = makeStore([.claudeCode: goodConnector, .codex: badConnector], connections: [good, bad])

        store.tick()
        await settle(store)

        XCTAssertEqual(store.runtime(for: good.id).status, .connected)
        XCTAssertEqual(store.runtime(for: good.id).snapshot?.metrics.first?.value, 12)
        XCTAssertEqual(store.runtime(for: bad.id).status, .failed(.server(status: 500)))
    }

    func testFailureAfterSuccessKeepsTheOldSnapshotAsStale() async {
        let connection = Connection(kind: .claudeCode, refreshInterval: 30)
        let connector = FakeConnector(kind: .claudeCode, results: [.success(Fixtures.snapshot(percent: 50)), .failure(.offline)])
        let store = makeStore([.claudeCode: connector], connections: [connection])

        await store.performRefresh(connection)
        clock = clock.addingTimeInterval(31)
        await store.performRefresh(connection)

        let runtime = store.runtime(for: connection.id)
        XCTAssertEqual(runtime.status, .stale(.offline))
        XCTAssertEqual(runtime.snapshot?.metrics.first?.value, 50, "cached value stays visible, flagged as outdated")
    }

    func testNetworkFailuresBackOffExponentially() async {
        let connection = Connection(kind: .claudeCode, refreshInterval: 30)
        let connector = FakeConnector(kind: .claudeCode, results: [.failure(.timeout)])
        let store = makeStore([.claudeCode: connector], connections: [connection])

        await store.performRefresh(connection)
        XCTAssertEqual(store.runtime(for: connection.id).nextAttempt, clock.addingTimeInterval(30))
        await store.performRefresh(connection)
        XCTAssertEqual(store.runtime(for: connection.id).nextAttempt, clock.addingTimeInterval(60))
        await store.performRefresh(connection)
        XCTAssertEqual(store.runtime(for: connection.id).nextAttempt, clock.addingTimeInterval(120))
    }

    func testRateLimitedHonorsRetryAfter() async {
        let connection = Connection(kind: .claudeCode, refreshInterval: 30)
        let connector = FakeConnector(kind: .claudeCode, results: [.failure(.rateLimited(retryAfter: 600))])
        let store = makeStore([.claudeCode: connector], connections: [connection])

        await store.performRefresh(connection)
        XCTAssertEqual(store.runtime(for: connection.id).nextAttempt, clock.addingTimeInterval(600))
    }

    func testAuthErrorsStopAutomaticRetries() async {
        let connection = Connection(kind: .claudeCode)
        let connector = FakeConnector(kind: .claudeCode, results: [.failure(.unauthorized(hint: "Check the key."))])
        let store = makeStore([.claudeCode: connector], connections: [connection])

        await store.performRefresh(connection)
        XCTAssertNil(store.runtime(for: connection.id).nextAttempt)
        clock = clock.addingTimeInterval(86_400)
        store.tick()
        await settle(store)
        XCTAssertEqual(connector.callCount, 1, "a rejected key is not retried until the user acts")
    }

    func testMissingKeyDoesNotCallTheConnector() async {
        let connection = Connection(kind: .openAIAPI)
        let connector = FakeConnector(kind: .openAIAPI, results: [.success(Fixtures.snapshot())])
        let store = makeStore([.openAIAPI: connector], connections: [connection])

        await store.performRefresh(connection)
        XCTAssertEqual(connector.callCount, 0)
        guard case .notConfigured = store.runtime(for: connection.id).status else { return XCTFail("expected notConfigured") }
    }

    func testStoredKeyIsPassedToTheConnector() async throws {
        let connection = Connection(kind: .openAIAPI)
        try secrets.write("sk-admin-abc123456", account: connection.keychainAccount)
        let connector = FakeConnector(kind: .openAIAPI, results: [.success(Fixtures.snapshot())])
        let store = makeStore([.openAIAPI: connector], connections: [connection])

        await store.performRefresh(connection)
        XCTAssertEqual(connector.lastSecret, "sk-admin-abc123456")
    }

    func testInformationalErrorDropsThePreviousValue() async {
        let connection = Connection(kind: .claudeCode, refreshInterval: 30)
        let connector = FakeConnector(kind: .claudeCode, results: [
            .success(Fixtures.snapshot(percent: 80)),
            .failure(.noData(reason: "Limits have reset."))
        ])
        let store = makeStore([.claudeCode: connector], connections: [connection])

        await store.performRefresh(connection)
        await store.performRefresh(connection)
        XCTAssertNil(store.runtime(for: connection.id).snapshot, "an outdated percentage would be misleading")
        XCTAssertEqual(store.runtime(for: connection.id).status, .unavailable("Limits have reset."))
    }

    func testTickOnlyRefreshesDueConnections() async {
        let connection = Connection(kind: .claudeCode, refreshInterval: 60)
        let connector = FakeConnector(kind: .claudeCode, results: [.success(Fixtures.snapshot())])
        let store = makeStore([.claudeCode: connector], connections: [connection])

        store.tick(); await settle(store)
        XCTAssertEqual(connector.callCount, 1)
        clock = clock.addingTimeInterval(30)
        store.tick(); await settle(store)
        XCTAssertEqual(connector.callCount, 1, "not due yet")
        clock = clock.addingTimeInterval(31)
        store.tick(); await settle(store)
        XCTAssertEqual(connector.callCount, 2)
    }

    func testManualRefreshRespectsTheProviderMinimumInterval() async {
        var connection = Connection(kind: .anthropicAPI)
        connection.refreshInterval = 300
        try? secrets.write("sk-ant-admin01-abcdef123456", account: connection.keychainAccount)
        let connector = FakeConnector(kind: .anthropicAPI, results: [.success(Fixtures.snapshot())])
        let store = makeStore([.anthropicAPI: connector], connections: [connection])

        await store.performRefresh(connection)
        store.refreshAll(); await settle(store)
        XCTAssertEqual(connector.callCount, 1, "hammering the refresh button must not hit the API again within 60 s")
        clock = clock.addingTimeInterval(61)
        store.refreshAll(); await settle(store)
        XCTAssertEqual(connector.callCount, 2)
    }

    func testSlowConnectorTimesOut() async {
        let connection = Connection(kind: .claudeCode)
        let connector = FakeConnector(kind: .claudeCode, results: [.success(Fixtures.snapshot())])
        connector.delay = 2
        let store = makeStore([.claudeCode: connector], connections: [connection], timeout: 0.05)

        await store.performRefresh(connection)
        XCTAssertEqual(store.runtime(for: connection.id).status, .failed(.timeout))
    }

    func testCosmeticEditDoesNotRefetchButBudgetChangeDoes() async {
        var connection = Connection(kind: .anthropicAPI)
        try? secrets.write("sk-ant-admin01-abcdef123456", account: connection.keychainAccount)
        let connector = FakeConnector(kind: .anthropicAPI, results: [.success(Fixtures.snapshot())])
        let store = makeStore([.anthropicAPI: connector], connections: [connection])
        await store.performRefresh(connection)
        XCTAssertEqual(connector.callCount, 1)

        connection.name = "Renamed"
        store.update(connection); await settle(store)
        XCTAssertEqual(connector.callCount, 1, "renaming must not trigger a network call")

        connection.monthlyBudgetUSD = 100
        store.update(connection); await settle(store)
        XCTAssertEqual(connector.callCount, 2)
    }

    func testDisablingAConnectionStopsItsRefreshes() async {
        var connection = Connection(kind: .claudeCode)
        let connector = FakeConnector(kind: .claudeCode, results: [.success(Fixtures.snapshot())])
        let store = makeStore([.claudeCode: connector], connections: [connection])
        connection.isEnabled = false
        store.update(connection)
        clock = clock.addingTimeInterval(3600)
        store.tick(); await settle(store)
        XCTAssertEqual(connector.callCount, 0)
        XCTAssertEqual(store.runtime(for: connection.id).status, .disabled)
    }

    func testMoveReordersConnectionsAndPersists() async {
        let claude = Connection(kind: .claudeCode)
        let codex = Connection(kind: .codex)
        let openAI = Connection(kind: .openAIAPI)
        let repository = InMemoryConnectionRepository([claude, codex, openAI])
        let store = UsageStore(repository: repository, secrets: InMemorySecretStore(),
                               cache: InMemorySnapshotCache(),
                               connectorProvider: { FakeConnector(kind: $0, results: [.success(Fixtures.snapshot())]) },
                               clock: { self.clock })
        store.load()

        // Drag the last item (OpenAI API, index 2) to the front.
        store.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        XCTAssertEqual(store.connections.map(\.id), [openAI.id, claude.id, codex.id])
        XCTAssertEqual(repository.load()?.map(\.id), [openAI.id, claude.id, codex.id],
                       "the new order must be persisted, not just held in memory")
    }

    func testConnectionTestUsesTheTypedKeyWithoutTouchingStoredState() async {
        let connection = Connection(kind: .openAIAPI)
        let connector = FakeConnector(kind: .openAIAPI, results: [.success(Fixtures.snapshot())])
        let store = makeStore([.openAIAPI: connector], connections: [connection])

        let result = await store.test(connection, secret: "sk-admin-typed-key-1234")
        XCTAssertNotNil(try? result.get())
        XCTAssertEqual(connector.lastSecret, "sk-admin-typed-key-1234")
        XCTAssertNil(store.runtime(for: connection.id).snapshot)
        XCTAssertFalse(store.hasSecret(for: connection.id), "testing does not save the key")

        let missing = await store.test(connection, secret: nil)
        if case .failure(let error) = missing { XCTAssertEqual(error, .missingCredential) } else { XCTFail("expected failure") }
    }
}
