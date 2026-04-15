import Foundation

public struct DaemonSupervisorConfig: Sendable {
    public let maxIterations: Int
    public let connectorLabel: String
    public let provider: String
    public let model: String

    public init(maxIterations: Int = 8, connectorLabel: String = "connector", provider: String = "mock", model: String = "mock") {
        self.maxIterations = maxIterations
        self.connectorLabel = connectorLabel
        self.provider = provider
        self.model = model
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
            /stats [on|off] - show or toggle token/savings stats for this chat
            /statson - enable token/savings stats for this chat
            /statsoff - disable token/savings stats for this chat
            /stop - stop the current reply or pending run
            """, for: event)
            return
        case .status:
            try await send(text: await statusMessage(for: event.conversation), for: event)
            return
        case .stats:
            try await handleStatsCommand(for: event)
            return
        case .statsOn:
            try await handleStatsCommand(for: event, forcedState: true)
            return
        case .statsOff:
            try await handleStatsCommand(for: event, forcedState: false)
            return
        case .model, .models:
            try await handleModelCommand(for: event)
            return
        case .chunks:
            try await send(
                text: "Chunked Telegram replies are not available in this build yet. Responses are still split only when they exceed Telegram's message length limit.",
                for: event
            )
            return
        case .chunksOn, .chunksOff:
            try await send(
                text: "Chunked Telegram streaming is not wired up yet, so this toggle does not have an effect yet.",
                for: event
            )
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
                let replyText = try await self.decorateReplyIfNeeded(result.finalText, runID: result.runID, conversation: event.conversation)
                try await self.send(text: replyText, for: event)
            } catch is CancellationError {
                try? await self.send(text: "Stopped the current run.", for: event)
            } catch {
                try? await self.send(text: DaemonTelegramFailureFormatter.message(for: error), for: event)
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
        let statsState = statsEnabled(for: conversation) ? "enabled" : "disabled"
        return """
        \(stateLine)
        Thread: \(status.threadID.uuidString)
        Prompt: \(status.prompt)
        Stats: \(statsState)

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

    private func handleStatsCommand(for event: InboundConnectorEvent, forcedState: Bool? = nil) async throws {
        let desiredState: Bool?
        if let forcedState {
            desiredState = forcedState
        } else {
            let lowered = event.text.lowercased()
            if lowered.contains(" on") || lowered.contains(" enable") {
                desiredState = true
            } else if lowered.contains(" off") || lowered.contains(" disable") {
                desiredState = false
            } else {
                desiredState = nil
            }
        }

        if let desiredState {
            try persistence.upsertSetting(
                namespace: statsNamespace(for: event.conversation),
                key: "enabled",
                value: .bool(desiredState),
                now: Date()
            )
        }

        let enabled = statsEnabled(for: event.conversation)
        let stateLabel = enabled ? "enabled" : "disabled"
        try await send(
            text: "Token stats are \(stateLabel) for this chat. Use `/stats on` or `/stats off` any time.",
            for: event
        )
    }

    private func handleModelCommand(for event: InboundConnectorEvent) async throws {
        let parts = event.text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if parts.count == 1 {
            try await send(
                text: "Current model: `\(config.model)` via `\(config.provider)`. Telegram-side model switching is not wired up yet in this build.",
                for: event
            )
            return
        }

        let requestedModel = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        try await send(
            text: "Requested model: `\(requestedModel)`. Telegram-side model switching is not wired up yet in this build, so the daemon is still using `\(config.model)` via `\(config.provider)`.",
            for: event
        )
    }

    private func decorateReplyIfNeeded(
        _ reply: String,
        runID: UUID?,
        conversation: ConnectorConversationReference
    ) async throws -> String {
        guard statsEnabled(for: conversation), let runID else {
            return reply
        }
        let inspector = SessionInspector(persistence: persistence)
        switch TokenSavingsEstimator.costPresentationMode(provider: config.provider) {
        case .savings:
            guard let usage = try inspector.loadTokenUsage(runID: runID) else {
                return reply
            }
            let statsBlock = "\n\nSaved: run \(formatTokenCount(usage.currentRun.usedTokenCount))/\(formatSavedMoney(usage.currentRun.usedTokenCount)) • today \(formatTokenCount(usage.today.usedTokenCount)) • session \(formatTokenCount(usage.session.usedTokenCount)) • total \(formatTokenCount(usage.total.usedTokenCount))"
            return reply + statsBlock
        case .usage:
            guard let usage = try inspector.loadTokenUsage(runID: runID) else {
                return reply
            }
            let statsBlock = "\n\nUsed: run \(formatTokenCount(usage.currentRun.usedTokenCount))/\(formatUsedMoney(usage.currentRun.usedTokenCount)) • today \(formatTokenCount(usage.today.usedTokenCount)) • session \(formatTokenCount(usage.session.usedTokenCount)) • total \(formatTokenCount(usage.total.usedTokenCount))"
            return reply + statsBlock
        }
    }

    private func statsEnabled(for conversation: ConnectorConversationReference) -> Bool {
        let setting = try? persistence.fetchSetting(namespace: statsNamespace(for: conversation), key: "enabled")
        return setting?.value.boolValue ?? true
    }

    private func statsNamespace(for conversation: ConnectorConversationReference) -> String {
        "connectors.telegram.stats.\(conversation.connectorID).\(conversation.externalConversationID)"
    }

    private func formatTokenCount(_ count: Int) -> String {
        let value = Double(max(count, 0))
        switch value {
        case 1_000_000...:
            return String(format: "%.1fM", value / 1_000_000)
        case 1_000...:
            return String(format: "%.1fk", value / 1_000)
        default:
            return String(Int(value))
        }
    }

    private func formatSavedMoney(_ savedTokens: Int) -> String {
        let dollars = TokenSavingsEstimator.estimatedSavedMoneyUSD(for: savedTokens, provider: config.provider, model: config.model)
        return TokenSavingsEstimator.formatUSD(dollars)
    }

    private func formatUsedMoney(_ usedTokens: Int) -> String {
        let dollars = TokenSavingsEstimator.estimatedUsageMoneyUSD(for: usedTokens, provider: config.provider, model: config.model)
        return TokenSavingsEstimator.formatUSD(dollars)
    }
}

enum DaemonTelegramFailureFormatter {
    static func message(for error: Error) -> String {
        if isCancellation(error) {
            return "Stopped the current run."
        }

        let description = normalizedDescription(for: error)
        if isApprovalDenied(description) {
            return "The pending tool request was denied."
        }

        if isTimeout(error, description: description) {
            if isToolTimeout(description) {
                return """
                Run failed: a tool run timed out.

                Try the request again with a narrower scope, or raise that tool's timeout if the command is expected to run longer.
                Details: \(description)
                """
            }

            if isConnectorTimeout(description) {
                return """
                Run failed: the Telegram connector timed out while talking to an external service.

                The daemon is still running. Try the request again in a moment.
                Details: \(description)
                """
            }

            return """
            Run failed: the model or provider request timed out.

            If you're using Ollama, try a smaller prompt or raise `ollama.requestTimeoutSeconds`.
            Details: \(description)
            """
        }

        return "Run failed: \(description)"
    }

    private static func normalizedDescription(for error: Error) -> String {
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? "Unknown error" : description
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let ashexError = error as? AshexError, case .cancelled = ashexError {
            return true
        }
        return normalizedDescription(for: error).localizedCaseInsensitiveContains("cancel")
    }

    private static func isApprovalDenied(_ description: String) -> Bool {
        description.localizedCaseInsensitiveContains("approval denied")
    }

    private static func isTimeout(_ error: Error, description: String) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
            return true
        }

        let lowered = description.lowercased()
        return lowered.contains("timed out") || lowered.contains("timeout")
    }

    private static func isToolTimeout(_ description: String) -> Bool {
        let lowered = description.lowercased()
        let markers = [
            "command timed out",
            "git command timed out",
            "build command timed out",
            "installable tool",
            "tool error: command timed out",
        ]
        return markers.contains(where: lowered.contains)
    }

    private static func isConnectorTimeout(_ description: String) -> Bool {
        let lowered = description.lowercased()
        let markers = [
            "telegram",
            "getupdates",
            "sendmessage",
            "chat action",
            "connector",
            "polling",
            "bot api",
        ]
        return markers.contains(where: lowered.contains)
    }
}
