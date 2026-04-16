import Foundation

public struct ConnectorConversationMapping: Sendable, Codable, Equatable {
    public let connectorKind: String
    public let connectorID: String
    public let externalConversationID: String
    public let externalUserID: String?
    public let threadID: UUID
    public let createdAt: Date
    public let updatedAt: Date
    public let status: String

    public init(
        connectorKind: String,
        connectorID: String,
        externalConversationID: String,
        externalUserID: String?,
        threadID: UUID,
        createdAt: Date,
        updatedAt: Date,
        status: String = "active"
    ) {
        self.connectorKind = connectorKind
        self.connectorID = connectorID
        self.externalConversationID = externalConversationID
        self.externalUserID = externalUserID
        self.threadID = threadID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
    }
}

public actor ConnectorConversationMappingStore {
    public static let namespace = "connectors.conversations"
    public static let threadNamespace = "connectors.conversation_threads"

    private let persistence: PersistenceStore
    private let clock: @Sendable () -> Date

    public init(persistence: PersistenceStore, clock: @escaping @Sendable () -> Date = Date.init) {
        self.persistence = persistence
        self.clock = clock
    }

    public func fetch(reference: ConnectorConversationReference) throws -> ConnectorConversationMapping? {
        guard let setting = try persistence.fetchSetting(namespace: Self.namespace, key: key(for: reference)) else {
            return nil
        }
        return try decodeMapping(from: setting.value)
    }

    public func resolveOrCreate(
        reference: ConnectorConversationReference,
        externalUserID: String?,
        createThread: @escaping @Sendable () throws -> ThreadRecord
    ) throws -> ConnectorConversationMapping {
        if let existing = try fetch(reference: reference) {
            let updated = ConnectorConversationMapping(
                connectorKind: existing.connectorKind,
                connectorID: existing.connectorID,
                externalConversationID: existing.externalConversationID,
                externalUserID: externalUserID ?? existing.externalUserID,
                threadID: existing.threadID,
                createdAt: existing.createdAt,
                updatedAt: clock(),
                status: existing.status
            )
            try save(updated)
            try recordThread(updated.threadID, for: reference)
            return updated
        }

        let now = clock()
        let thread = try createThread()
        let mapping = ConnectorConversationMapping(
            connectorKind: reference.connectorKind,
            connectorID: reference.connectorID,
            externalConversationID: reference.externalConversationID,
            externalUserID: externalUserID,
            threadID: thread.id,
            createdAt: now,
            updatedAt: now
        )
        try save(mapping)
        try recordThread(mapping.threadID, for: reference)
        return mapping
    }

    @discardableResult
    public func reset(reference: ConnectorConversationReference) throws -> ConnectorConversationMapping {
        let now = clock()
        let thread = try persistence.createThread(now: now)
        let mapping = ConnectorConversationMapping(
            connectorKind: reference.connectorKind,
            connectorID: reference.connectorID,
            externalConversationID: reference.externalConversationID,
            externalUserID: nil,
            threadID: thread.id,
            createdAt: now,
            updatedAt: now
        )
        try save(mapping)
        try recordThread(mapping.threadID, for: reference)
        return mapping
    }

    public func listThreadIDs(for reference: ConnectorConversationReference) throws -> [UUID] {
        guard let setting = try persistence.fetchSetting(namespace: Self.threadNamespace, key: threadKey(for: reference)) else {
            if let mapping = try fetch(reference: reference) {
                return [mapping.threadID]
            }
            return []
        }
        let ids = setting.value.arrayValue?.compactMap { UUID(uuidString: $0.stringValue ?? "") } ?? []
        if ids.isEmpty, let mapping = try fetch(reference: reference) {
            return [mapping.threadID]
        }
        return ids
    }

    public func switchToThread(_ threadID: UUID, for reference: ConnectorConversationReference, externalUserID: String?) throws -> ConnectorConversationMapping {
        let now = clock()
        let existing = try fetch(reference: reference)
        let mapping = ConnectorConversationMapping(
            connectorKind: reference.connectorKind,
            connectorID: reference.connectorID,
            externalConversationID: reference.externalConversationID,
            externalUserID: externalUserID ?? existing?.externalUserID,
            threadID: threadID,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            status: existing?.status ?? "active"
        )
        try save(mapping)
        try recordThread(threadID, for: reference)
        return mapping
    }

    public func listMappings(connectorKind: String? = nil) throws -> [ConnectorConversationMapping] {
        try persistence.listSettings(namespace: Self.namespace)
            .compactMap { setting in
                try? decodeMapping(from: setting.value)
            }
            .filter { mapping in
                connectorKind.map { mapping.connectorKind == $0 } ?? true
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func save(_ mapping: ConnectorConversationMapping) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(mapping)
        let object = try JSONDecoder().decode(JSONValue.self, from: data)
        try persistence.upsertSetting(namespace: Self.namespace, key: key(for: mapping), value: object, now: clock())
    }

    private func recordThread(_ threadID: UUID, for reference: ConnectorConversationReference) throws {
        let key = threadKey(for: reference)
        var existing = try persistence.fetchSetting(namespace: Self.threadNamespace, key: key)?.value.arrayValue?.compactMap {
            UUID(uuidString: $0.stringValue ?? "")
        } ?? []
        existing.removeAll { $0 == threadID }
        existing.insert(threadID, at: 0)
        try persistence.upsertSetting(
            namespace: Self.threadNamespace,
            key: key,
            value: .array(existing.map { .string($0.uuidString) }),
            now: clock()
        )
    }

    private func decodeMapping(from value: JSONValue) throws -> ConnectorConversationMapping {
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(ConnectorConversationMapping.self, from: data)
    }

    private func key(for reference: ConnectorConversationReference) -> String {
        "\(reference.connectorKind)|\(reference.connectorID)|\(reference.externalConversationID)"
    }

    private func key(for mapping: ConnectorConversationMapping) -> String {
        "\(mapping.connectorKind)|\(mapping.connectorID)|\(mapping.externalConversationID)"
    }

    private func threadKey(for reference: ConnectorConversationReference) -> String {
        "\(reference.connectorKind)|\(reference.connectorID)|\(reference.externalConversationID)"
    }
}
