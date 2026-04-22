import Foundation

public struct DaemonSupervisorConfig: Sendable {
    public let maxIterations: Int
    public let connectorLabel: String
    public let provider: String
    public let model: String
    public let workspaceRootPath: String
    public let sandbox: SandboxPolicyConfig
    public let executionPolicy: ConnectorExecutionPolicyMode

    public init(
        maxIterations: Int = 8,
        connectorLabel: String = "connector",
        provider: String = "mock",
        model: String = "mock",
        workspaceRootPath: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Ashex", isDirectory: true)
            .appendingPathComponent("DefaultWorkspace", isDirectory: true)
            .path,
        sandbox: SandboxPolicyConfig = .default,
        executionPolicy: ConnectorExecutionPolicyMode = .assistantOnly
    ) {
        self.maxIterations = maxIterations
        self.connectorLabel = connectorLabel
        self.provider = provider
        self.model = model
        self.workspaceRootPath = workspaceRootPath
        self.sandbox = sandbox
        self.executionPolicy = executionPolicy
    }
}

public struct DaemonModelControl: Sendable {
    public let listModels: (@Sendable () async throws -> [String])?
    public let switchModel: @Sendable (String) async throws -> Void

    public init(
        listModels: (@Sendable () async throws -> [String])? = nil,
        switchModel: @escaping @Sendable (String) async throws -> Void
    ) {
        self.listModels = listModels
        self.switchModel = switchModel
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
    private let modelControl: DaemonModelControl?
    private var activeTasks: [ConnectorConversationReference: Task<Void, Never>] = [:]
    private var latestReasoningSummaryByConversation: [ConnectorConversationReference: String] = [:]
    private var activeProvider: String
    private var activeModel: String

    public init(
        registry: ConnectorRegistry,
        router: ConversationRouter,
        dispatcher: RunDispatcher,
        persistence: PersistenceStore,
        logger: DaemonLogger,
        runStore: DaemonConversationRunStore,
        remoteApprovalInbox: RemoteApprovalInbox,
        modelControl: DaemonModelControl? = nil,
        config: DaemonSupervisorConfig = .init()
    ) {
        self.registry = registry
        self.router = router
        self.dispatcher = dispatcher
        self.persistence = persistence
        self.logger = logger
        self.runStore = runStore
        self.remoteApprovalInbox = remoteApprovalInbox
        self.modelControl = modelControl
        self.config = config
        self.activeProvider = config.provider
        self.activeModel = config.model
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
            /whoami - show your Telegram user ID and current chat ID
            /tasks - list active tasks across Telegram chats
            /chats - list known Telegram chats and their current thread info
            /last - summarize the latest persisted run in this workspace
            /reset - start a fresh Ash conversation for this chat
            /new - start a fresh thread in this Telegram chat
            /threads - list threads in this Telegram chat
            /thread N - switch to thread number N from `/threads`
            /pwd - show the active workspace root
            /workspace - show workspace help and the daemon restart command for another root
            /ls [path] - list files in the active workspace
            /mkdir path - create a folder when Telegram execution is trusted
            /status - show whether Ash is running or waiting for approval
            /pending - show the current pending approval request
            /approve - allow the pending tool request in this chat
            /deny [reason] - deny the pending tool request
            /stats [on|off] - show or toggle token/savings stats for this chat
            /statson - enable token/savings stats for this chat
            /statsoff - disable token/savings stats for this chat
            /reasoning [on|off] - show or toggle safe reasoning summaries for this chat
            /reasoningon - enable safe reasoning summaries for this chat
            /reasoningoff - disable safe reasoning summaries for this chat
            /model [name] - show or switch the active daemon model
            /models - list available models for the active provider
            /progress [quiet|normal|verbose] - control live run progress updates in this chat
            /stop - stop the current reply or pending run
            """, for: event)
            return
        case .status:
            try await send(text: await statusMessage(for: event.conversation), for: event)
            return
        case .pwd:
            try await send(text: workspaceStatusMessage(), for: event)
            return
        case .workspace:
            try await send(text: workspaceHelpMessage(), for: event)
            return
        case .ls:
            try await send(text: try listWorkspaceDirectory(path: commandArgument(from: event.text) ?? "."), for: event)
            return
        case .mkdir:
            try await send(text: try createWorkspaceDirectory(path: commandArgument(from: event.text)), for: event)
            return
        case .whoami:
            try await send(text: identityMessage(for: event), for: event)
            return
        case .tasks:
            try await handleTasksCommand(for: event)
            return
        case .chats:
            try await handleChatsCommand(for: event)
            return
        case .last:
            try await handleLastRunCommand(for: event)
            return
        case .thread:
            try await handleThreadCommand(for: event)
            return
        case .threads:
            try await handleThreadsCommand(for: event)
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
        case .reasoning:
            try await handleReasoningCommand(for: event)
            return
        case .reasoningOn:
            try await handleReasoningCommand(for: event, forcedState: true)
            return
        case .reasoningOff:
            try await handleReasoningCommand(for: event, forcedState: false)
            return
        case .model:
            try await handleModelCommand(for: event)
            return
        case .models:
            try await handleModelsCommand(for: event)
            return
        case .progress:
            try await handleProgressCommand(for: event)
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
            latestReasoningSummaryByConversation[event.conversation] = nil
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

        if let shortcut = SimpleWorkspaceCommand.parse(event.text) {
            try await send(text: try executeSimpleWorkspaceCommand(shortcut), for: event)
            return
        }

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
            let progressTask = Task { [weak self] in
                await self?.sendProgressReplies(for: event)
            }
            defer {
                progressTask.cancel()
            }
            do {
                try await self.registry.beginActivity(.typing, for: event.conversation, connectorID: event.connectorID)
                let result = try await self.dispatcher.dispatch(
                    prompt: event.text,
                    threadID: mapping.threadID,
                    maxIterations: self.config.maxIterations,
                    mode: intent == .directChat ? .directChat : .agent,
                    attachments: event.attachments,
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
            await self.clearReasoningSummary(for: event.conversation)
            await self.clearActiveTask(for: event.conversation)
        }
        activeTasks[event.conversation] = task
    }

    private func sendProgressReplies(for event: InboundConnectorEvent) async {
        let checkpoints: [(UInt64, String)] = [
            (15_000_000_000, "Still working on this. I will send the result here when the run finishes."),
            (45_000_000_000, longRunningHintMessage()),
        ]

        for (delay, message) in checkpoints {
            do {
                try await Task.sleep(nanoseconds: delay)
                try Task.checkCancellation()
                try await send(text: message, for: event)
            } catch {
                return
            }
        }
    }

    private func longRunningHintMessage() -> String {
        if activeProvider == "ollama" {
            return """
            This is still running through Ollama.

            If it times out, try a smaller model, restart unused Ollama models with `ollama stop <model>`, or raise `ollama.requestTimeoutSeconds`.
            """
        }
        return "Still running. Larger workspace tasks can take a little longer."
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
            latestReasoningSummaryByConversation[conversation] = nil
        case .status(_, let message):
            if let summary = extractReasoningSummary(from: message) {
                latestReasoningSummaryByConversation[conversation] = summary
            } else if progressMode(for: conversation) == .verbose,
                      !message.localizedCaseInsensitiveContains("thinking") {
                try? await registry.send(.init(
                    connectorID: connectorID,
                    conversation: conversation,
                    text: "Status: \(message)"
                ))
            }
        case .taskPlanCreated(_, let steps):
            guard progressMode(for: conversation).showsStructuredProgress else { break }
            try? await registry.send(.init(
                connectorID: connectorID,
                conversation: conversation,
                text: TelegramRunProgressFormatter.taskPlan(steps)
            ))
        case .todoListUpdated(_, let items):
            guard progressMode(for: conversation).showsStructuredProgress else { break }
            guard items.contains(where: { $0.status == .inProgress || $0.status == .completed || $0.status == .skipped }) else {
                break
            }
            try? await registry.send(.init(
                connectorID: connectorID,
                conversation: conversation,
                text: TelegramRunProgressFormatter.todoList(items)
            ))
        case .taskStepStarted(_, let index, let total, let title):
            guard progressMode(for: conversation).showsStructuredProgress else { break }
            try? await registry.send(.init(
                connectorID: connectorID,
                conversation: conversation,
                text: "Step \(index)/\(total) started: \(title)"
            ))
        case .taskStepFinished(_, let index, let total, let title, let outcome):
            guard progressMode(for: conversation).showsStructuredProgress else { break }
            try? await registry.send(.init(
                connectorID: connectorID,
                conversation: conversation,
                text: "Step \(index)/\(total) \(outcome): \(title)"
            ))
        case .changedFilesTracked(_, let paths):
            guard progressMode(for: conversation).showsStructuredProgress else { break }
            guard !paths.isEmpty else { break }
            try? await registry.send(.init(
                connectorID: connectorID,
                conversation: conversation,
                text: "Changed files:\n\(paths.map { "- \($0)" }.joined(separator: "\n"))"
            ))
        case .patchPlanUpdated(_, let paths, let objectives):
            guard progressMode(for: conversation).showsStructuredProgress else { break }
            guard !paths.isEmpty || !objectives.isEmpty else { break }
            try? await registry.send(.init(
                connectorID: connectorID,
                conversation: conversation,
                text: TelegramRunProgressFormatter.patchPlan(paths: paths, objectives: objectives)
            ))
        case .subagentAssigned(_, let title, let role, let goal):
            guard progressMode(for: conversation).showsStructuredProgress else { break }
            try? await registry.send(.init(
                connectorID: connectorID,
                conversation: conversation,
                text: """
                Subagent assigned: \(role)
                Task: \(title)
                Goal: \(goal)
                """
            ))
        case .subagentHandoff(_, let title, let role, let summary, let remainingItems):
            guard progressMode(for: conversation).showsStructuredProgress else { break }
            try? await registry.send(.init(
                connectorID: connectorID,
                conversation: conversation,
                text: TelegramRunProgressFormatter.subagentHandoff(
                    title: title,
                    role: role,
                    summary: summary,
                    remainingItems: remainingItems
                )
            ))
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

    private enum TelegramProgressMode: String {
        case quiet
        case normal
        case verbose

        var showsStructuredProgress: Bool {
            self != .quiet
        }
    }

    private func handleProgressCommand(for event: InboundConnectorEvent) async throws {
        let parts = event.text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if parts.count == 2 {
            let requested = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let mode = TelegramProgressMode(rawValue: requested) else {
                try await send(text: "Usage: `/progress quiet`, `/progress normal`, or `/progress verbose`.", for: event)
                return
            }
            try persistence.upsertSetting(
                namespace: progressNamespace(for: event.conversation),
                key: "mode",
                value: .string(mode.rawValue),
                now: Date()
            )
        }

        let mode = progressMode(for: event.conversation)
        let description: String
        switch mode {
        case .quiet:
            description = "Only final replies and approval prompts are sent."
        case .normal:
            description = "Plans, steps, changed files, and subagent handoffs are sent."
        case .verbose:
            description = "Normal progress plus selected status updates are sent."
        }
        try await send(text: "Progress updates are \(mode.rawValue).\n\(description)", for: event)
    }

    private func handleLastRunCommand(for event: InboundConnectorEvent) async throws {
        let inspector = SessionInspector(persistence: persistence)
        guard let summary = try inspector.summarizeLatestRun(recentEventLimit: 500) else {
            try await send(text: "No persisted runs were found for this workspace yet.", for: event)
            return
        }
        try await send(text: SessionInspector.format(summary: summary), for: event)
    }

    private func progressMode(for conversation: ConnectorConversationReference) -> TelegramProgressMode {
        let raw = (try? persistence.fetchSetting(namespace: progressNamespace(for: conversation), key: "mode")?.value.stringValue) ?? TelegramProgressMode.normal.rawValue
        return TelegramProgressMode(rawValue: raw) ?? .normal
    }

    private func progressNamespace(for conversation: ConnectorConversationReference) -> String {
        "connectors.telegram.progress.\(conversation.connectorID).\(conversation.externalConversationID)"
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
        Approval card
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
            return """
            Ash is idle in this chat.
            Model: \(activeModel) via \(activeProvider)
            Workspace: \(config.workspaceRootPath)
            Progress: \(progressMode(for: conversation).rawValue)

            Use `/last` to inspect the most recent run.
            """
        }

        let stateLine = status.awaitingApproval
            ? "Ash is waiting for approval on run \(status.runID?.uuidString ?? "<pending>")"
            : "Ash is running \(status.runID?.uuidString ?? "<starting>")"
        let statsState = statsEnabled(for: conversation) ? "enabled" : "disabled"
        let reasoningState = reasoningEnabled(for: conversation) ? "enabled" : "disabled"
        let progress = progressMode(for: conversation)
        return """
        Status card
        \(stateLine)
        Thread: \(status.threadID.uuidString)
        Prompt: \(status.prompt)
        Model: \(activeModel) via \(activeProvider)
        Workspace: \(config.workspaceRootPath)
        Stats: \(statsState)
        Reasoning summaries: \(reasoningState)
        Progress: \(progress.rawValue)

        Use `/stop` to cancel the run\(status.awaitingApproval ? ", `/approve`, or `/deny`." : ".")
        """
    }

    private func workspaceStatusMessage() -> String {
        SimpleWorkspaceCommandExecutor.workspaceStatus(workspaceRoot: workspaceRootURL)
    }

    private func workspaceHelpMessage() -> String {
        SimpleWorkspaceCommandExecutor.workspaceHelp(
            workspaceRoot: workspaceRootURL,
            startupCommand: daemonWorkspaceStartupCommand()
        )
    }

    private func executeSimpleWorkspaceCommand(_ command: SimpleWorkspaceCommand) throws -> String {
        try SimpleWorkspaceCommandExecutor.execute(
            command,
            workspaceRoot: workspaceRootURL,
            sandbox: config.sandbox,
            mutationDeniedReason: mutationDeniedReason(for: command)
        )
    }

    private func listWorkspaceDirectory(path: String) throws -> String {
        try SimpleWorkspaceCommandExecutor.execute(
            .listDirectory(path: path),
            workspaceRoot: workspaceRootURL,
            sandbox: config.sandbox
        )
    }

    private func createWorkspaceDirectory(path rawPath: String?) throws -> String {
        try SimpleWorkspaceCommandExecutor.execute(
            .createDirectory(path: rawPath ?? ""),
            workspaceRoot: workspaceRootURL,
            sandbox: config.sandbox,
            mutationDeniedReason: mutationDeniedReason(for: .createDirectory(path: rawPath ?? ""))
        )
    }

    private var workspaceRootURL: URL {
        URL(fileURLWithPath: config.workspaceRootPath, isDirectory: true)
    }

    private func mutationDeniedReason(for command: SimpleWorkspaceCommand) -> String? {
        guard case .createDirectory = command,
              config.executionPolicy != .trustedFullAccess else {
            return nil
        }
        return """
        Folder creation is blocked because Telegram is configured as \(config.executionPolicy.rawValue).

        Current workspace:
        \(config.workspaceRootPath)
        """
    }

    private func daemonWorkspaceStartupCommand() -> String {
        "ashex daemon run --workspace \(config.workspaceRootPath) --provider \(activeProvider) --model \(activeModel)"
    }

    private func commandArgument(from text: String) -> String? {
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        return String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func handleReasoningCommand(for event: InboundConnectorEvent, forcedState: Bool? = nil) async throws {
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
                namespace: reasoningNamespace(for: event.conversation),
                key: "enabled",
                value: .bool(desiredState),
                now: Date()
            )
        }

        let enabled = reasoningEnabled(for: event.conversation)
        let stateLabel = enabled ? "enabled" : "disabled"
        try await send(
            text: "Safe reasoning summaries are \(stateLabel) for this chat. Use `/reasoning on` or `/reasoning off` any time.",
            for: event
        )
    }

    private func handleModelCommand(for event: InboundConnectorEvent) async throws {
        let parts = event.text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if parts.count == 1 {
            try await send(
                text: "Current model: `\(activeModel)` via `\(activeProvider)`. Use `/models` to browse available models or `/model gemma4:latest` to switch.",
                for: event
            )
            return
        }

        let requestedModel = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedModel.isEmpty else {
            try await send(text: "Usage: `/model gemma4:latest`", for: event)
            return
        }
        guard let modelControl else {
            try await send(text: "Live model switching is not available in this daemon build.", for: event)
            return
        }
        let hasActiveRuns = await runStore.hasActiveRuns()
        guard !hasActiveRuns else {
            try await send(text: "Ash is busy right now. Use `/stop` and wait for the run to finish before switching the model.", for: event)
            return
        }

        do {
            try await modelControl.switchModel(requestedModel)
            activeModel = requestedModel
            try await send(
                text: "Switched model to `\(activeModel)` via `\(activeProvider)`.",
                for: event
            )
        } catch {
            try await send(
                text: "Failed to switch model to `\(requestedModel)`: \(error.localizedDescription)",
                for: event
            )
        }
    }

    private func handleThreadsCommand(for event: InboundConnectorEvent) async throws {
        let threadIDs = try await router.listThreadIDs(for: event.conversation)
        guard !threadIDs.isEmpty else {
            try await send(text: "No threads yet in this chat. Use `/new` to start one.", for: event)
            return
        }

        let summaries = try persistence.listThreads(limit: 500)
        let summaryByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        let activeThreadID = try await router.resolveConversation(
            for: event.conversation,
            externalUserID: event.externalUserID,
            createThread: { [persistence] in try persistence.createThread(now: Date()) }
        ).threadID

        let lines = threadIDs.prefix(12).enumerated().map { index, threadID in
            let summary = summaryByID[threadID]
            let suffix = threadID == activeThreadID ? " ← current" : ""
            let state = summary?.latestRunState?.rawValue ?? "idle"
            let count = summary?.messageCount ?? 0
            return "\(index + 1). `\(threadID.uuidString.prefix(8))` • \(state) • \(count) msg\(suffix)"
        }

        try await send(
            text: """
            Threads in this chat:
            \(lines.joined(separator: "\n"))

            Use `/thread N` to switch or `/new` for a fresh chat.
            """,
            for: event
        )
    }

    private func handleThreadCommand(for event: InboundConnectorEvent) async throws {
        let parts = event.text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let index = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)), index > 0 else {
            try await send(text: "Usage: `/thread 2`", for: event)
            return
        }

        let hasActiveRuns = await runStore.hasActiveRuns()
        guard !hasActiveRuns else {
            try await send(text: "Ash is busy right now. Use `/stop` before switching threads.", for: event)
            return
        }

        let threadIDs = try await router.listThreadIDs(for: event.conversation)
        guard threadIDs.indices.contains(index - 1) else {
            try await send(text: "Thread `\(index)` does not exist in this chat. Use `/threads` first.", for: event)
            return
        }

        let mapping = try await router.switchConversation(
            for: event.conversation,
            to: threadIDs[index - 1],
            externalUserID: event.externalUserID
        )
        try await send(
            text: "Switched to thread `\(index)` (`\(mapping.threadID.uuidString.prefix(8))`).",
            for: event
        )
    }

    private func handleTasksCommand(for event: InboundConnectorEvent) async throws {
        let activeRuns = await runStore.listActiveRuns()
            .filter { $0.conversation.connectorKind == event.conversation.connectorKind }

        guard !activeRuns.isEmpty else {
            try await send(text: "There are no active tasks right now.", for: event)
            return
        }

        let lines = activeRuns.prefix(12).enumerated().map { index, snapshot in
            let status = snapshot.status.awaitingApproval ? "awaiting approval" : "running"
            let prompt = compactPrompt(snapshot.status.prompt)
            return "\(index + 1). chat `\(snapshot.conversation.externalConversationID)` • \(status) • thread `\(snapshot.status.threadID.uuidString.prefix(8))` • \(prompt)"
        }

        try await send(
            text: """
            Active tasks:
            \(lines.joined(separator: "\n"))

            Use `/status` inside a chat for full detail, or `/stop` in that same chat to cancel it.
            """,
            for: event
        )
    }

    private func handleChatsCommand(for event: InboundConnectorEvent) async throws {
        let mappings = try await router.listConversations(connectorKind: event.conversation.connectorKind)
        guard !mappings.isEmpty else {
            try await send(text: "No Telegram chats are known yet.", for: event)
            return
        }

        let activeByConversation = Dictionary(
            uniqueKeysWithValues: await runStore.listActiveRuns().map { ($0.conversation, $0.status) }
        )
        let threadSummaries = try persistence.listThreads(limit: 500)
        let summaryByID = Dictionary(uniqueKeysWithValues: threadSummaries.map { ($0.id, $0) })

        let lines = mappings.prefix(12).enumerated().map { index, mapping in
            let reference = ConnectorConversationReference(
                connectorKind: mapping.connectorKind,
                connectorID: mapping.connectorID,
                externalConversationID: mapping.externalConversationID
            )
            let active = activeByConversation[reference]
            let runState = active?.awaitingApproval == true
                ? "awaiting approval"
                : active != nil
                    ? "running"
                    : summaryByID[mapping.threadID]?.latestRunState?.rawValue ?? "idle"
            let current = mapping.externalConversationID == event.conversation.externalConversationID ? " ← current chat" : ""
            return "\(index + 1). chat `\(mapping.externalConversationID)` • user `\(mapping.externalUserID ?? "?")` • \(runState) • thread `\(mapping.threadID.uuidString.prefix(8))`\((current))"
        }

        try await send(
            text: """
            Known chats:
            \(lines.joined(separator: "\n"))

            Open that Telegram chat to continue there. In the current chat, use `/threads` and `/thread N` to switch threads.
            """,
            for: event
        )
    }

    private func handleModelsCommand(for event: InboundConnectorEvent) async throws {
        guard let modelControl else {
            try await send(text: "Model listing is not available in this daemon build.", for: event)
            return
        }
        guard let listModels = modelControl.listModels else {
            try await send(
                text: "Model listing is not available for `\(activeProvider)` yet. Current model: `\(activeModel)`.",
                for: event
            )
            return
        }

        do {
            let models = try await listModels()
            guard !models.isEmpty else {
                try await send(text: "No models were returned for `\(activeProvider)`.", for: event)
                return
            }
            let rendered = models.prefix(12).map { model in
                model == activeModel ? "• `\(model)` ← current" : "• `\(model)`"
            }.joined(separator: "\n")
            try await send(
                text: """
                Available models for `\(activeProvider)`:
                \(rendered)

                Switch with `/model your-model-name`.
                """,
                for: event
            )
        } catch {
            try await send(
                text: "Failed to fetch models for `\(activeProvider)`: \(error.localizedDescription)",
                for: event
            )
        }
    }

    private func identityMessage(for event: InboundConnectorEvent) -> String {
        let userID = event.externalUserID ?? "<unknown>"
        return """
        Telegram IDs for this chat:
        Chat ID: `\(event.conversation.externalConversationID)`
        User ID: `\(userID)`
        """
    }

    private func compactPrompt(_ prompt: String, limit: Int = 60) -> String {
        let normalized = prompt.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private func decorateReplyIfNeeded(
        _ reply: String,
        runID: UUID?,
        conversation: ConnectorConversationReference
    ) async throws -> String {
        var decorated = reply

        if reasoningEnabled(for: conversation), let summary = latestReasoningSummaryByConversation[conversation], !summary.isEmpty {
            decorated += "\n\nReasoning: \(summary)"
        }

        guard statsEnabled(for: conversation), let runID else {
            return decorated
        }
        let inspector = SessionInspector(persistence: persistence)
        switch TokenSavingsEstimator.costPresentationMode(provider: activeProvider) {
        case .savings:
            guard let usage = try inspector.loadTokenUsage(runID: runID) else {
                return decorated
            }
            let statsBlock = "\n\nSaved: run \(formatTokenCount(usage.currentRun.usedTokenCount))/\(formatSavedMoney(usage.currentRun.usedTokenCount)) • today \(formatTokenCount(usage.today.usedTokenCount)) • session \(formatTokenCount(usage.session.usedTokenCount)) • total \(formatTokenCount(usage.total.usedTokenCount))"
            return decorated + statsBlock
        case .usage:
            guard let usage = try inspector.loadTokenUsage(runID: runID) else {
                return decorated
            }
            let statsBlock = "\n\nUsed: run \(formatTokenCount(usage.currentRun.usedTokenCount))/\(formatUsedMoney(usage.currentRun.usedTokenCount)) • today \(formatTokenCount(usage.today.usedTokenCount)) • session \(formatTokenCount(usage.session.usedTokenCount)) • total \(formatTokenCount(usage.total.usedTokenCount))"
            return decorated + statsBlock
        }
    }

    private func statsEnabled(for conversation: ConnectorConversationReference) -> Bool {
        let setting = try? persistence.fetchSetting(namespace: statsNamespace(for: conversation), key: "enabled")
        return setting?.value.boolValue ?? true
    }

    private func statsNamespace(for conversation: ConnectorConversationReference) -> String {
        "connectors.telegram.stats.\(conversation.connectorID).\(conversation.externalConversationID)"
    }

    private func reasoningEnabled(for conversation: ConnectorConversationReference) -> Bool {
        let setting = try? persistence.fetchSetting(namespace: reasoningNamespace(for: conversation), key: "enabled")
        return setting?.value.boolValue ?? false
    }

    private func reasoningNamespace(for conversation: ConnectorConversationReference) -> String {
        "connectors.telegram.reasoning.\(conversation.connectorID).\(conversation.externalConversationID)"
    }

    private func extractReasoningSummary(from message: String) -> String? {
        let prefix = "Reasoning summary:"
        guard message.hasPrefix(prefix) else { return nil }
        let summary = message.replacingOccurrences(of: prefix, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? nil : summary
    }

    private func clearReasoningSummary(for conversation: ConnectorConversationReference) {
        latestReasoningSummaryByConversation[conversation] = nil
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
        let dollars = TokenSavingsEstimator.estimatedSavedMoneyUSD(for: savedTokens, provider: activeProvider, model: activeModel)
        return TokenSavingsEstimator.formatUSD(dollars)
    }

    private func formatUsedMoney(_ usedTokens: Int) -> String {
        let dollars = TokenSavingsEstimator.estimatedUsageMoneyUSD(for: usedTokens, provider: activeProvider, model: activeModel)
        return TokenSavingsEstimator.formatUSD(dollars)
    }
}

enum TelegramRunProgressFormatter {
    static func taskPlan(_ steps: [String]) -> String {
        guard !steps.isEmpty else {
            return "Plan created."
        }
        return (["Plan created:"] + steps.enumerated().map { index, step in
            "\(index + 1). \(step)"
        }).joined(separator: "\n")
    }

    static func todoList(_ items: [RunTodoItem]) -> String {
        let lines = items.map { item in
            let marker: String
            switch item.status {
            case .pending:
                marker = "[ ]"
            case .inProgress:
                marker = "[>]"
            case .completed:
                marker = "[x]"
            case .skipped:
                marker = "[-]"
            }
            return "\(marker) \(item.index). \(item.title)"
        }
        return (["Current plan:"] + lines).joined(separator: "\n")
    }

    static func patchPlan(paths: [String], objectives: [String]) -> String {
        var lines = ["Patch plan updated:"]
        if !paths.isEmpty {
            lines.append("Files:")
            lines.append(contentsOf: paths.map { "- \($0)" })
        }
        if !objectives.isEmpty {
            lines.append("Goals:")
            lines.append(contentsOf: objectives.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    static func subagentHandoff(title: String, role: String, summary: String, remainingItems: [String]) -> String {
        var lines = [
            "Subagent handoff: \(role)",
            "Task: \(title)",
            "",
            summary
        ]
        if !remainingItems.isEmpty {
            lines.append("")
            lines.append("Remaining:")
            lines.append(contentsOf: remainingItems.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
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
