import Foundation

public protocol SecretStore: Sendable {
    func readSecret(namespace: String, key: String) throws -> String?
    func containsSecret(namespace: String, key: String) throws -> Bool
    func writeSecret(namespace: String, key: String, value: String) throws
    func deleteSecret(namespace: String, key: String) throws
}

public final class LocalJSONSecretStore: SecretStore, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL = LocalJSONSecretStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public func readSecret(namespace: String, key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return try load()[namespacedKey(namespace: namespace, key: key)]
    }

    public func containsSecret(namespace: String, key: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return try load()[namespacedKey(namespace: namespace, key: key)] != nil
    }

    public func writeSecret(namespace: String, key: String, value: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var secrets = try load()
        secrets[namespacedKey(namespace: namespace, key: key)] = value
        try save(secrets)
    }

    public func deleteSecret(namespace: String, key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var secrets = try load()
        secrets.removeValue(forKey: namespacedKey(namespace: namespace, key: key))
        try save(secrets)
    }

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".ashex", isDirectory: true)
            .appendingPathComponent("secrets.json")
    }

    private func load() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        if data.isEmpty {
            return [:]
        }
        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw AshexError.persistence("Failed to decode local secrets JSON at \(fileURL.path): \(error.localizedDescription)")
        }
    }

    private func save(_ secrets: [String: String]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(secrets)
        try data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: fileURL.path)
    }

    private func namespacedKey(namespace: String, key: String) -> String {
        "\(namespace).\(key)"
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
