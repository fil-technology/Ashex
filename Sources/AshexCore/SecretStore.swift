import Foundation
import Security

public protocol SecretStore: Sendable {
    func readSecret(namespace: String, key: String) throws -> String?
    func containsSecret(namespace: String, key: String) throws -> Bool
    func writeSecret(namespace: String, key: String, value: String) throws
    func deleteSecret(namespace: String, key: String) throws
}

public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let serviceName: String

    public init(serviceName: String = "com.fil-technology.ashex") {
        self.serviceName = serviceName
    }

    public func readSecret(namespace: String, key: String) throws -> String? {
        var query = baseQuery(namespace: namespace, key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw AshexError.persistence("Failed to decode secret for \(namespace).\(key)")
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw AshexError.persistence("Keychain read failed for \(namespace).\(key) (status \(status))")
        }
    }

    public func containsSecret(namespace: String, key: String) throws -> Bool {
        var query = baseQuery(namespace: namespace, key: key)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess, errSecInteractionNotAllowed:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw AshexError.persistence("Keychain lookup failed for \(namespace).\(key) (status \(status))")
        }
    }

    public func writeSecret(namespace: String, key: String, value: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(namespace: namespace, key: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AshexError.persistence("Keychain write failed for \(namespace).\(key) (status \(addStatus))")
            }
        default:
            throw AshexError.persistence("Keychain update failed for \(namespace).\(key) (status \(updateStatus))")
        }
    }

    public func deleteSecret(namespace: String, key: String) throws {
        let status = SecItemDelete(baseQuery(namespace: namespace, key: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AshexError.persistence("Keychain delete failed for \(namespace).\(key) (status \(status))")
        }
    }

    private func baseQuery(namespace: String, key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: "\(namespace).\(key)",
        ]
    }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init() {}

    public func readSecret(namespace: String, key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[namespacedKey(namespace: namespace, key: key)]
    }

    public func containsSecret(namespace: String, key: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage[namespacedKey(namespace: namespace, key: key)] != nil
    }

    public func writeSecret(namespace: String, key: String, value: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[namespacedKey(namespace: namespace, key: key)] = value
    }

    public func deleteSecret(namespace: String, key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: namespacedKey(namespace: namespace, key: key))
    }

    private func namespacedKey(namespace: String, key: String) -> String {
        "\(namespace).\(key)"
    }
}
