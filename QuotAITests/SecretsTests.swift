import XCTest
@testable import QuotAI

final class SecretsTests: XCTestCase {
    private var account: String!
    private var keychain: KeychainSecretStore!

    override func setUp() {
        super.setUp()
        // Unique service per test run so we never touch real credentials.
        keychain = KeychainSecretStore(service: "com.quotai.tests.\(UUID().uuidString)")
        account = UUID().uuidString
    }

    override func tearDown() {
        try? keychain.delete(account: account)
        super.tearDown()
    }

    func testKeychainRoundTrip() throws {
        XCTAssertNil(try keychain.read(account: account))
        try keychain.write("sk-ant-admin01-SECRET-VALUE", account: account)
        XCTAssertEqual(try keychain.read(account: account), "sk-ant-admin01-SECRET-VALUE")
        XCTAssertTrue(keychain.contains(account: account))
    }

    func testKeychainOverwriteReplacesValue() throws {
        try keychain.write("first-value-1234", account: account)
        try keychain.write("second-value-5678", account: account)
        XCTAssertEqual(try keychain.read(account: account), "second-value-5678")
    }

    func testKeychainDelete() throws {
        try keychain.write("value-to-delete", account: account)
        try keychain.delete(account: account)
        XCTAssertNil(try keychain.read(account: account))
        XCTAssertNoThrow(try keychain.delete(account: account), "deleting a missing item is not an error")
    }

    func testSecretsNeverAppearInPersistedConnectionsOrCache() async throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = "sk-ant-admin01-TOP-SECRET-KEY-123456"

        let secrets = InMemorySecretStore()
        let connector = FakeConnector(kind: .anthropicAPI, results: [.success(Fixtures.snapshot())])
        let store = await UsageStore(repository: FileConnectionRepository(directory: directory),
                                     secrets: secrets,
                                     cache: FileSnapshotCache(directory: directory),
                                     connectorProvider: { _ in connector })
        await store.load()
        let connection = Connection(kind: .anthropicAPI, name: "Org", isEnabled: true)
        await store.add(connection)
        try await store.setSecret(secret, for: connection.id)
        if let saved = await store.connections.first(where: { $0.id == connection.id }) {
            await store.performRefresh(saved)
        }

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains(secret), "\(file.lastPathComponent) must not contain the secret")
        }
        XCTAssertEqual(try secrets.read(account: connection.keychainAccount), secret)
    }

    func testRemovingConnectionDeletesItsSecret() async throws {
        let secrets = InMemorySecretStore()
        let store = await UsageStore(repository: InMemoryConnectionRepository([]),
                                     secrets: secrets, cache: InMemorySnapshotCache(),
                                     connectorProvider: { FakeConnector(kind: $0, results: [.success(Fixtures.snapshot())]) })
        await store.load()
        let connection = Connection(kind: .openAIAPI, isEnabled: false)
        await store.add(connection)
        try await store.setSecret("AIzaSyFAKEKEY1234567890", for: connection.id)
        XCTAssertNotNil(try secrets.read(account: connection.keychainAccount))
        await store.remove(connection.id)
        XCTAssertNil(try secrets.read(account: connection.keychainAccount))
    }

    func testRedactorMasksKnownSecretShapes() {
        let text = "Failed with key sk-ant-admin01-abcdef123456 and AIzaSyA1B2C3D4E5F6G7H8 header Authorization: Bearer abc.def.ghi x-api-key: hunter22"
        let redacted = Redactor.redact(text)
        XCTAssertFalse(redacted.contains("abcdef123456"))
        XCTAssertFalse(redacted.contains("AIzaSyA1B2C3D4E5F6G7H8"))
        XCTAssertFalse(redacted.contains("abc.def.ghi"))
        XCTAssertFalse(redacted.contains("hunter22"))
        XCTAssertTrue(redacted.contains(Redactor.mask))
    }

    func testRedactorMasksExplicitSecrets() {
        XCTAssertEqual(Redactor.redact("token=custom-secret-value", knownSecrets: ["custom-secret-value"]), "token=\(Redactor.mask)")
    }

    func testProviderErrorMessagesNeverContainSecrets() {
        let errors: [ProviderError] = [
            .missingCredential, .unauthorized(hint: "Check the key."), .forbidden(hint: "No access."),
            .rateLimited(retryAfter: 30), .timeout, .offline, .network(code: -1), .server(status: 500),
            .unexpectedResponse, .bridgeNotInstalled, .noData(reason: "none"), .unavailableOfficially(reason: "n/a")
        ]
        for error in errors {
            XCTAssertEqual(Redactor.redact(error.userMessage), error.userMessage, "message is already free of secret-like text")
        }
    }
}
