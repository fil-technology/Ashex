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
    private let runStore: DaemonConversationRunStore
    private let remoteApprovalInbox: RemoteApprovalInbox
    private var activeTasks: [ConnectorConversationReference: Task<Void, Never>] = [:]

    public init(
        registry: ConnectorRegistry,
        router: ConversationRouter,
        dispatcher: RunDispatcher,
        persistence: PersistenceStore,
        logger: DaemonLogger,
        runStore: DaemonConversationRunStore,
        remoteApprovalInbox: RemoteApprovalInbox,
        config: DaemonSupervisorConfig = .init()
    ) {
        self.registry = registry
        self.router = router
        self.dispatcher = dispatcher
        self.persistence = persistence
        self.logger = logger
        self.runStore = runStore
        self.remoteApprovalInbox = remoteApprovalInbox
        self.config = config
    }

    public func start() async throws {
        await logger.log(.info, subsystem: "daemon", message: "Starting connectors")
        try await registry.startAll { [weak self] event in
            guard let self else { return }
            Task {
                do {
                    try await self.handle(event)
                } catch {
                    await self.logger.log(.error, subsystem: "daemon", message: "Failed to handle connector event", metadata: [
                        "connector_id": .string(event.connectorID),
                        "conversation_id": .string(event.conversation.externalConversationID),
                        "error": .string(error.localizedDescription),
                    ])
                }
            }
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
            /status - show whether Ash is running or waiting for approval
            /pending - show the current pending approval request
            /approve - allow the pending tool request in this chat
            /deny [reason] - deny the pending tool request
            /stop - stop the current reply or pending run
            """, for: event)
            return
        case .status:
            try await send(text: await statusMessage(for: event.conversation), for: event)
            return
        case .pending:
            try await send(text: await pendingApprovalMessage(for: event.conversation), for: event)
            return
        case .approve:
            try await handleApprovalDecision(
                for: event,
                allowed: true,
                fallbackReason: "Approved from Telegram.",
                defaultSuccessText: "Approved. Continuing the run."
            )
            return
        case .deny:
            try await handleApprovalDecision(
                for: event,
                allowed: false,
                fallbackReason: denialReason(from: event.text) ?? "Denied from Telegram.",
                defaultSuccessText: "Denied the pending tool request."
            )
            return
        case .stop, .cancel:
            try await stopActiveRun(for: event)
            return
        case .reset, .newConversation:
            _ = await remoteApprovalInbox.resolvePendingApproval(
                for: event.conversation,
                allowed: false,
                reason: "Denied because the conversation was reset."
            )
            _ = await runStore.cancelRun(for: event.conversation)
            activeTasks[event.conversation]?.cancel()
            activeTasks[event.conversation] = nil
            await runStore.clearRun(for: event.conversation)
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

        guard await runStore.status(for: event.conversation) == nil else {
            try await send(text: await busyMessage(for: event.conversation), for: event)
            return
        }

        let intent = ConnectorMessageIntentClassifier.classify(event.text)
        await logger.log(.info, subsystem: "daemon.intent", message: "Resolved connector message intent", metadata: [
            "intent": .string(intent.rawValue),
            "conversation_id": .string(event.conversation.externalConversationID),
        ])

        let cancellationToken = CancellationToken()
        guard await runStore.beginRun(
            for: event.conversation,
            threadID: mapping.threadID,
            prompt: event.text,
            cancellationToken: cancellationToken
        ) else {
            try await send(text: await busyMessage(for: event.conversation), for: event)
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.registry.beginActivity(.typing, for: event.conversation, connectorID: event.connectorID)
                let result = try await self.dispatcher.dispatch(
                    prompt: event.text,
                    threadID: mapping.threadID,
                    maxIterations: self.config.maxIterations,
                    mode: intent == .directChat ? .directChat : .agent,
                    cancellationToken: cancellationToken,
                    onEvent: { [weak self] runtimeEvent in
                        guard let self else { return }
                        await self.handleRuntimeEvent(runtimeEvent, for: event.conversation, connectorID: event.connectorID)
                    }
                )

                await self.logger.log(.info, subsystem: "daemon.outbound", message: "Sending reply", metadata: [
                    "connector_id": .string(event.connectorID),
                    "conversation_id": .string(event.conversation.externalConversationID),
                    "run_id": .string(result.runID?.uuidString ?? ""),
                ])
                try await self.send(text: result.finalText, for: event)
            } catch is CancellationError {
                try? await self.send(text: "Stopped the current run.", for: event)
            } catch {
                let message = error.localizedDescription
                if message.localizedCaseInsensitiveContains("cancel") {
                    try? await self.send(text: "Stopped the current run.", for: event)
                } else if message.localizedCaseInsensitiveContains("approval denied") {
                    try? await self.send(text: "The pending tool request was denied.", for: event)
                } else {
                    try? await self.send(text: "Run failed: \(message)", for: event)
                }
            }

            await self.registry.endActivity(.typing, for: event.conversation, connectorID: event.connectorID)
            await self.runStore.clearRun(for: event.conversation)
            await self.clearActiveTask(for: event.conversation)
        }
        activeTasks[event.conversation] = task
    }

    private func send(text: String, for event: InboundConnectorEvent) async throws {
        try await registry.send(.init(connectorID: event.connectorID, conversation: event.conversation, text: text))
    }

    private func handleRuntimeEvent(
        _ event: RuntimeEvent,
        for conversation: ConnectorConversationReference,
        connectorID: String
    ) async {
        switch event.payload {
        case .runStarted(_, let runID):
            await runStore.bind(runID: runID, to: conversation)
        case .approvalRequested(let runID, let toolName, let summary, let reason, let risk):
            await runStore.setAwaitingApproval(true, for: runID)
            await registry.endActivity(.typing, for: conversation, connectorID: connectorID)
            try? await registry.send(.init(
                connectorID: connectorID,
                conversation: conversation,
                text: """
                Approval required for `\(toolName)`.

                Summary: \(summary)
                Reason: \(reason)
                Risk: \(risk.rawValue)

                Reply with `/approve` to continue, `/deny optional reason` to block it, or `/stop` to cancel the whole run.
                """
            ))
        case .approvalResolved(let runID, _, let allowed, _):
            await runStore.setAwaitingApproval(false, for: runID)
            if allowed {
                try? await registry.beginActivity(.typing, for: conversation, connectorID: connectorID)
            }
        default:
            break
        }
    }

    private func handleApprovalDecision(
        for event: InboundConnectorEvent,
        allowed: Bool,
        fallbackReason: String,
        defaultSuccessText: String
    ) async throws {
        guard let pending = await remoteApprovalInbox.resolvePendingApproval(
            for: event.conversation,
            allowed: allowed,
            reason: fallbackReason
        ) else {
            try await send(text: "There is no pending approval request in this chat.", for: event)
            return
        }
        await logger.log(.info, subsystem: "daemon.approval", message: allowed ? "Approval granted remotely" : "Approval denied remotely", metadata: [
            "conversation_id": .string(event.conversation.externalConversationID),
            "run_id": .string(pending.runID.uuidString),
            "tool_name": .string(pending.toolName),
        ])
        try await send(text: defaultSuccessText, for: event)
    }

    private func stopActiveRun(for event: InboundConnectorEvent) async throws {
        let deniedPending = await remoteApprovalInbox.resolvePendingApproval(
            for: event.conversation,
            allowed: false,
            reason: "Denied because the run was stopped from Telegram."
        )
        let cancelled = await runStore.cancelRun(for: event.conversation)
        activeTasks[event.conversation]?.cancel()
        if cancelled || deniedPending != nil {
            try await send(text: "Stopping the current run.", for: event)
        } else {
            try await send(text: "There is no active run to stop in this chat.", for: event)
        }
    }

    private func pendingApprovalMessage(for conversation: ConnectorConversationReference) async -> String {
        guard let pending = await remoteApprovalInbox.pendingApproval(for: conversation) else {
            return "There is no pending approval request in this chat."
        }
        return """
        Pending approval:
        Tool: \(pending.toolName)
        Summary: \(pending.summary)
        Reason: \(pending.reason)
        Risk: \(pending.risk.rawValue)

        Reply with `/approve`, `/deny optional reason`, or `/stop`.
        """
    }

    private func statusMessage(for conversation: ConnectorConversationReference) async -> String {
        let pending = await remoteApprovalInbox.pendingApproval(for: conversation)
        guard let status = await runStore.status(for: conversation) else {
            if pending != nil {
                return await pendingApprovalMessage(for: conversation)
            }
            return "Ash is idle in this chat."
        }

        let stateLine = status.awaitingApproval
            ? "Ash is waiting for approval on run \(status.runID?.uuidString ?? "<pending>")"
            : "Ash is running \(status.runID?.uuidString ?? "<starting>")"
        return """
        \(stateLine)
        Thread: \(status.threadID.uuidString)
        Prompt: \(status.prompt)

        Use `/stop` to cancel the run\(status.awaitingApproval ? ", `/approve`, or `/deny`." : ".")
        """
    }

    private func busyMessage(for conversation: ConnectorConversationReference) async -> String {
        let status = await runStore.status(for: conversation)
        if status?.awaitingApproval == true {
            return "Ash is waiting for approval in this chat. Use `/approve`, `/deny`, `/pending`, or `/stop`."
        }
        return "Ash is already working on a reply in this chat. Use `/status` to inspect it or `/stop` to cancel it."
    }

    private func denialReason(from text: String) -> String? {
        let components = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard components.count == 2 else { return nil }
        let reason = String(components[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? nil : reason
    }

    private func clearActiveTask(for conversation: ConnectorConversationReference) {
        activeTasks[conversation] = nil
    }
}
