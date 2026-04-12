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
}
