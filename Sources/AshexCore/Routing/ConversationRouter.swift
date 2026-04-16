import Foundation

public actor ConversationRouter {
    private let mappingStore: ConnectorConversationMappingStore

    public init(mappingStore: ConnectorConversationMappingStore) {
        self.mappingStore = mappingStore
    }

    public func resolveConversation(
        for reference: ConnectorConversationReference,
        externalUserID: String?,
        createThread: @escaping @Sendable () throws -> ThreadRecord
    ) async throws -> ConnectorConversationMapping {
        try await mappingStore.resolveOrCreate(
            reference: reference,
            externalUserID: externalUserID,
            createThread: createThread
        )
    }

    public func resetConversation(for reference: ConnectorConversationReference) async throws -> ConnectorConversationMapping {
        try await mappingStore.reset(reference: reference)
    }

    public func listThreadIDs(for reference: ConnectorConversationReference) async throws -> [UUID] {
        try await mappingStore.listThreadIDs(for: reference)
    }

    public func switchConversation(
        for reference: ConnectorConversationReference,
        to threadID: UUID,
        externalUserID: String?
    ) async throws -> ConnectorConversationMapping {
        try await mappingStore.switchToThread(threadID, for: reference, externalUserID: externalUserID)
    }

    public func listConversations(connectorKind: String? = nil) async throws -> [ConnectorConversationMapping] {
        try await mappingStore.listMappings(connectorKind: connectorKind)
    }
}
