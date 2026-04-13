import Foundation

public struct ConnectorConversationReference: Sendable, Codable, Hashable {
    public let connectorKind: String
    public let connectorID: String
    public let externalConversationID: String

    public init(connectorKind: String, connectorID: String, externalConversationID: String) {
        self.connectorKind = connectorKind
        self.connectorID = connectorID
        self.externalConversationID = externalConversationID
    }
}

public enum ConnectorCommand: String, Sendable, Codable {
    case start
    case help
    case reset
    case newConversation = "new"
}

public struct InboundConnectorEvent: Sendable, Codable {
    public let connectorKind: String
    public let connectorID: String
    public let messageID: String
    public let conversation: ConnectorConversationReference
    public let externalUserID: String?
    public let text: String
    public let command: ConnectorCommand?
    public let metadata: JSONObject

    public init(
        connectorKind: String,
        connectorID: String,
        messageID: String,
        conversation: ConnectorConversationReference,
        externalUserID: String?,
        text: String,
        command: ConnectorCommand?,
        metadata: JSONObject = [:]
    ) {
        self.connectorKind = connectorKind
        self.connectorID = connectorID
        self.messageID = messageID
        self.conversation = conversation
        self.externalUserID = externalUserID
        self.text = text
        self.command = command
        self.metadata = metadata
    }
}

public struct OutboundConnectorMessage: Sendable, Codable {
    public let connectorID: String
    public let conversation: ConnectorConversationReference
    public let text: String

    public init(connectorID: String, conversation: ConnectorConversationReference, text: String) {
        self.connectorID = connectorID
        self.conversation = conversation
        self.text = text
    }
}

public enum ConnectorActivity: String, Sendable, Codable {
    case typing
}

public protocol ConnectorActivityControlling: Sendable {
    func beginActivity(_ activity: ConnectorActivity, for conversation: ConnectorConversationReference) async throws
    func endActivity(_ activity: ConnectorActivity, for conversation: ConnectorConversationReference) async
}

public protocol Connector: Sendable {
    var id: String { get }
    var kind: String { get }
    func start(handler: @escaping @Sendable (InboundConnectorEvent) async throws -> Void) async throws
    func stop() async
    func send(_ message: OutboundConnectorMessage) async throws
}

public actor ConnectorRegistry {
    private var connectors: [String: any Connector]

    public init(connectors: [any Connector]) {
        self.connectors = Dictionary(uniqueKeysWithValues: connectors.map { ($0.id, $0) })
    }

    public func startAll(handler: @escaping @Sendable (InboundConnectorEvent) async throws -> Void) async throws {
        for connector in connectors.values {
            try await connector.start(handler: handler)
        }
    }

    public func stopAll() async {
        for connector in connectors.values {
            await connector.stop()
        }
    }

    public func send(_ message: OutboundConnectorMessage) async throws {
        guard let connector = connectors[message.connectorID] else {
            throw AshexError.model("No connector registered with id \(message.connectorID)")
        }
        try await connector.send(message)
    }

    public func beginActivity(_ activity: ConnectorActivity, for conversation: ConnectorConversationReference, connectorID: String) async throws {
        guard let connector = connectors[connectorID] else {
            throw AshexError.model("No connector registered with id \(connectorID)")
        }
        guard let activityConnector = connector as? any ConnectorActivityControlling else {
            return
        }
        try await activityConnector.beginActivity(activity, for: conversation)
    }

    public func endActivity(_ activity: ConnectorActivity, for conversation: ConnectorConversationReference, connectorID: String) async {
        guard let connector = connectors[connectorID] else {
            return
        }
        guard let activityConnector = connector as? any ConnectorActivityControlling else {
            return
        }
        await activityConnector.endActivity(activity, for: conversation)
    }
}
