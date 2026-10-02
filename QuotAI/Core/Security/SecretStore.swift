import Foundation
import Security

enum SecretStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidData
}

/// Secret storage (API keys, tokens). Never put a secret in preferences, files or logs.
protocol SecretStore: Sendable {
    func read(account: String) throws -> String?
    func write(_ secret: String, account: String) throws
    func delete(account: String) throws
}

extension SecretStore {
    func contains(account: String) -> Bool {
        ((try? read(account: account)) ?? nil) != nil
    }
}

/// macOS Keychain, generic-password class.
/// Accessible only while the device is unlocked, not synced to iCloud.
struct KeychainSecretStore: SecretStore {
    let service: String

    init(service: String = "com.quotai.QuotAI.credentials") {
        self.service = service
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
                throw SecretStoreError.invalidData
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.unexpectedStatus(status)
        }
    }

    func write(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(account: account) as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = baseQuery(account: account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SecretStoreError.unexpectedStatus(addStatus) }
        default:
            throw SecretStoreError.unexpectedStatus(status)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.unexpectedStatus(status)
        }
    }
}

/// In-memory implementation, for tests.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func read(account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[account]
    }

    func write(_ secret: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[account] = secret
    }

    func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[account] = nil
    }
}
