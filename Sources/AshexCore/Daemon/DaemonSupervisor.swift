import Foundation

public struct DaemonSupervisorConfig: Sendable {
    public let maxIterations: Int
    public let connectorLabel: String

    public init(maxIterations: Int = 8, connectorLabel: String = "connector") {
        self.maxIterations = maxIterations
        self.connectorLabel = connectorLabel
    }
}

public actor DaemonSupervisor {
    private let registry: ConnectorRegistry
    private let router: ConversationRouter
    private let dispatcher: RunDispatcher
    private let persistence: PersistenceStore
    private let logger: DaemonLogger
    private let config: DaemonSupervisorConfig

    public init(
        registry: ConnectorRegistry,
        router: ConversationRouter,
        dispatcher: RunDispatcher,
        persistence: PersistenceStore,
        logger: DaemonLogger,
        config: DaemonSupervisorConfig = .init()
    ) {
        self.registry = registry
        self.router = router
        self.dispatcher = dispatcher
        self.persistence = persistence
        self.logger = logger
        self.config = config
    }

    public func start() async throws {
        await logger.log(.info, subsystem: "daemon", message: "Starting connectors")
        try await registry.startAll { [weak self] event in
            guard let self else { return }
            try await self.handle(event)
        }
    }

    public func stop() async {
        await logger.log(.info, subsystem: "daemon", message: "Stopping connectors")
        await registry.stopAll()
    }

    public func handle(_ event: InboundConnectorEvent) async throws {
        await logger.log(.info, subsystem: "daemon.inbound", message: "Inbound event received", metadata: [
            "connector_id": .string(event.connectorID),
            "conversation_id": .string(event.conversation.externalConversationID),
            "message_id": .string(event.messageID),
        ])

        switch event.command {
        case .start:
            try await send(text: """
            Ash is connected.

            Send a message to continue this conversation.
            Use /help for commands and /reset to start a fresh conversation.
            """, for: event)
            return
        case .help:
            try await send(text: """
            Send a text message and Ash will reply in this chat.

            Commands:
            /start - confirm the bot is connected
            /help - show this help
            /reset - start a fresh Ash conversation for this chat
            """, for: event)
            return
        case .reset, .newConversation:
            let mapping = try await router.resetConversation(for: event.conversation)
            await logger.log(.info, subsystem: "daemon.router", message: "Conversation reset", metadata: [
                "thread_id": .string(mapping.threadID.uuidString),
                "conversation_id": .string(event.conversation.externalConversationID),
            ])
            try await send(text: "Started a fresh Ash conversation for this chat.", for: event)
            return
        case nil:
            break
        }

        let mapping = try await router.resolveConversation(
            for: event.conversation,
            externalUserID: event.externalUserID,
            createThread: { [persistence] in
                try persistence.createThread(now: Date())
            }
        )

        await logger.log(.info, subsystem: "daemon.router", message: "Resolved conversation mapping", metadata: [
            "thread_id": .string(mapping.threadID.uuidString),
            "conversation_id": .string(mapping.externalConversationID),
        ])

        let result = try await dispatcher.dispatch(
            prompt: event.text,
            threadID: mapping.threadID,
            maxIterations: config.maxIterations
        )

        await logger.log(.info, subsystem: "daemon.outbound", message: "Sending reply", metadata: [
            "connector_id": .string(event.connectorID),
            "conversation_id": .string(event.conversation.externalConversationID),
            "run_id": .string(result.runID?.uuidString ?? ""),
        ])
        try await send(text: result.finalText, for: event)
    }

    private func send(text: String, for event: InboundConnectorEvent) async throws {
        try await registry.send(.init(connectorID: event.connectorID, conversation: event.conversation, text: text))
    }
}
