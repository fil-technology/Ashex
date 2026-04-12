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
        return mapping
    }

    private func save(_ mapping: ConnectorConversationMapping) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(mapping)
        let object = try JSONDecoder().decode(JSONValue.self, from: data)
        try persistence.upsertSetting(namespace: Self.namespace, key: key(for: mapping), value: object, now: clock())
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
}
