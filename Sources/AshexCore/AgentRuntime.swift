import Foundation

public struct RunRequest: Sendable {
    public let prompt: String
    public let maxIterations: Int
    public let executionControl: ExecutionControl?

    public init(prompt: String, maxIterations: Int = 8, executionControl: ExecutionControl? = nil) {
        self.prompt = prompt
        self.maxIterations = maxIterations
        self.executionControl = executionControl
    }
}

public protocol RuntimeStreaming: Sendable {
    func run(_ request: RunRequest) -> AsyncStream<RuntimeEvent>
}

public final class AgentRuntime: RuntimeStreaming, Sendable {
    private let modelAdapter: any ModelAdapter
    private let toolRegistry: ToolRegistry
    private let persistence: PersistenceStore
    private let approvalPolicy: any ApprovalPolicy
    private let clock: @Sendable () -> Date
    private let toolExecutor: ToolExecutor
    private let workspaceSnapshot: WorkspaceSnapshot?

    public init(
        modelAdapter: any ModelAdapter,
        toolRegistry: ToolRegistry,
        persistence: PersistenceStore,
        approvalPolicy: any ApprovalPolicy = TrustedApprovalPolicy(),
        workspaceSnapshot: WorkspaceSnapshot? = nil,
        clock: @escaping @Sendable () -> Date = Date.init
    ) throws {
        self.modelAdapter = modelAdapter
        self.toolRegistry = toolRegistry
        self.persistence = persistence
        self.approvalPolicy = approvalPolicy
        self.workspaceSnapshot = workspaceSnapshot
        self.clock = clock
        self.toolExecutor = ToolExecutor(
            toolRegistry: toolRegistry,
            persistence: persistence,
            approvalPolicy: approvalPolicy,
            clock: clock
        )
        try persistence.initialize()
        try persistence.normalizeInterruptedRuns(now: clock())
    }

    public func run(_ request: RunRequest) -> AsyncStream<RuntimeEvent> {
        AsyncStream { continuation in
            let cancellation = CancellationToken()
            let emitter = EventEmitter(persistence: persistence, continuation: continuation)

            let task = Task {
                await execute(request: request, cancellation: cancellation, emitter: emitter)
                continuation.finish()
            }

            continuation.onTermination = { _ in
                Task {
                    await cancellation.cancel()
                    task.cancel()
                }
            }
        }
    }

    private func execute(request: RunRequest, cancellation: CancellationToken, emitter: EventEmitter) async {
        let now = clock()

        do {
            let thread = try persistence.createThread(now: now)
            let run = try persistence.createRun(threadID: thread.id, state: .pending, now: now)
            try persistence.transitionRun(runID: run.id, to: .running, reason: nil, now: clock())

            try emitter.emit(.runStarted(threadID: thread.id, runID: run.id), runID: run.id)
            try emitter.emit(.runStateChanged(runID: run.id, state: .running, reason: nil), runID: run.id)

            if let workspaceSnapshot {
                _ = try persistence.recordWorkspaceSnapshot(
                    runID: run.id,
                    workspaceRootPath: workspaceSnapshot.rootURL.path,
                    topLevelEntries: workspaceSnapshot.topLevelEntries,
                    instructionFiles: workspaceSnapshot.instructionFiles,
                    gitBranch: workspaceSnapshot.gitBranch,
                    gitStatusSummary: workspaceSnapshot.gitStatusSummary,
                    now: clock()
                )
            }

            let userMessage = try persistence.appendMessage(threadID: thread.id, runID: run.id, role: .user, content: request.prompt, now: clock())
            try emitter.emit(.messageAppended(runID: run.id, messageID: userMessage.id, role: .user), runID: run.id)
            _ = try persistence.upsertWorkingMemory(
                runID: run.id,
                currentTask: request.prompt,
                currentPhase: nil,
                inspectedPaths: [],
                changedPaths: [],
                validationSuggestions: Self.validationSuggestions(for: request.prompt),
                summary: "Run created and waiting for planning/execution.",
                now: clock()
            )
            let plan = TaskPlanner.plan(for: request.prompt)
            var stepSummaries: [String] = []
            var changedFiles: [ChangedArtifact] = []

            if let plan, plan.steps.count > 1 {
                let planText = plan.steps.enumerated()
                    .map { "\($0.offset + 1). \($0.element.title)" }
                    .joined(separator: "\n")
                let planMessage = try persistence.appendMessage(threadID: thread.id, runID: run.id, role: .assistant, content: "Plan:\n\(planText)", now: clock())
                try emitter.emit(.messageAppended(runID: run.id, messageID: planMessage.id, role: .assistant), runID: run.id)
                try emitter.emit(.taskPlanCreated(runID: run.id, steps: plan.steps.map(\.title)), runID: run.id)
            }

            let steps = plan?.steps ?? [PlannedStep(title: "Complete the user request")]
            let stepRecords = try persistence.createRunSteps(runID: run.id, steps: steps.map(\.title), now: clock())
            for (index, step) in steps.enumerated() {
                try await cancellation.checkCancellation()

                if let control = request.executionControl,
                   await control.consumeSkipCurrentStep() {
                    try persistence.transitionRunStep(stepID: stepRecords[index].id, to: .skipped, summary: "Skipped: \(step.title)", now: clock())
                    try emitter.emit(.taskStepFinished(runID: run.id, index: index + 1, total: steps.count, title: step.title, outcome: "skipped"), runID: run.id)
                    stepSummaries.append("Skipped: \(step.title)")
                    continue
                }

                try persistence.transitionRunStep(stepID: stepRecords[index].id, to: .running, summary: nil, now: clock())
                try emitter.emit(.workflowPhaseChanged(runID: run.id, phase: step.phase.rawValue, title: step.title), runID: run.id)
                try persistWorkingMemory(
                    runID: run.id,
                    currentTask: request.prompt,
                    currentPhase: step.phase,
                    workflowState: nil,
                    changedFiles: changedFiles,
                    summary: "Current step \(index + 1)/\(steps.count): \(step.title)",
                    overrideSuggestions: Self.validationSuggestions(for: request.prompt, phase: step.phase)
                )
                try emitter.emit(.taskStepStarted(runID: run.id, index: index + 1, total: steps.count, title: step.title), runID: run.id)
                let stepMessage = steps.count > 1
                    ? """
                    Work on only this step of the larger task.
                    Step \(index + 1) of \(steps.count): \(step.title)
                    Overall user request: \(request.prompt)
                    """
                    : request.prompt

                if steps.count > 1 {
                    let systemMessage = try persistence.appendMessage(threadID: thread.id, runID: run.id, role: .system, content: stepMessage, now: clock())
                    try emitter.emit(.messageAppended(runID: run.id, messageID: systemMessage.id, role: .system), runID: run.id)
                }

                let outcome = try await executeStep(
                    thread: thread,
                    run: run,
                    stepPrompt: stepMessage,
                    stepTitle: step.title,
                    stepPhase: step.phase,
                    maxIterations: request.maxIterations,
                    cancellation: cancellation,
                    executionControl: request.executionControl,
                    emitter: emitter
                )
                stepSummaries.append(outcome.summary)
                changedFiles.append(contentsOf: outcome.changedFiles)
                try persistence.transitionRunStep(stepID: stepRecords[index].id, to: .completed, summary: outcome.summary, now: clock())
                if steps.count > 1 {
                    let stepSummaryMessage = try persistence.appendMessage(
                        threadID: thread.id,
                        runID: run.id,
                        role: .assistant,
                        content: "Step \(index + 1) result:\n\(outcome.summary)",
                        now: clock()
                    )
                    try emitter.emit(.messageAppended(runID: run.id, messageID: stepSummaryMessage.id, role: .assistant), runID: run.id)
                }
                try emitter.emit(.taskStepFinished(runID: run.id, index: index + 1, total: steps.count, title: step.title, outcome: "completed"), runID: run.id)
            }

            let finalAnswerText: String
            if steps.count == 1 {
                finalAnswerText = Self.decorateFinalSummary(
                    base: stepSummaries.last ?? "Task finished.",
                    request: request.prompt,
                    changedFiles: changedFiles,
                    remainingItems: []
                )
            } else {
                finalAnswerText = Self.decorateFinalSummary(
                    base: Self.compilePlannedRunSummary(request: request.prompt, steps: steps, summaries: stepSummaries),
                    request: request.prompt,
                    changedFiles: changedFiles,
                    remainingItems: stepSummaries.filter { $0.hasPrefix("Skipped:") }
                )
            }
            try persistWorkingMemory(
                runID: run.id,
                currentTask: request.prompt,
                currentPhase: .validation,
                workflowState: nil,
                changedFiles: changedFiles,
                summary: finalAnswerText,
                overrideSuggestions: []
            )

            let assistantMessage = try persistence.appendMessage(threadID: thread.id, runID: run.id, role: .assistant, content: finalAnswerText, now: clock())
            try emitter.emit(.messageAppended(runID: run.id, messageID: assistantMessage.id, role: .assistant), runID: run.id)
            try emitter.emit(.finalAnswer(runID: run.id, messageID: assistantMessage.id, text: finalAnswerText), runID: run.id)
            try persistence.transitionRun(runID: run.id, to: .completed, reason: nil, now: clock())
            try emitter.emit(.runStateChanged(runID: run.id, state: .completed, reason: nil), runID: run.id)
            try emitter.emit(.runFinished(runID: run.id, state: .completed), runID: run.id)
            return
        } catch {
            await finalizeFailure(error: error, emitter: emitter)
        }
    }

    private func executeStep(
        thread: ThreadRecord,
        run: RunRecord,
        stepPrompt: String,
        stepTitle: String,
        stepPhase: PlannedStepPhase,
        maxIterations: Int,
        cancellation: CancellationToken,
        executionControl: ExecutionControl?,
        emitter: EventEmitter
    ) async throws -> StepExecutionOutcome {
        var repeatedToolCallSignature: String?
        var repeatedToolCallCount = 0
        var lastSafeToolResult: String?
        var workflowState = StepWorkflowState()
        var changedFiles: [ChangedArtifact] = []

        for iteration in 0..<maxIterations {
            try await cancellation.checkCancellation()
            if let executionControl, await executionControl.consumeSkipCurrentStep() {
                return .init(summary: "Skipped current step", changedFiles: [])
            }

            try emitter.emit(.status(runID: run.id, message: "Iteration \(iteration + 1): requesting next model action"), runID: run.id)

            let messages = try persistence.fetchMessages(threadID: thread.id)
            let refreshedRun = try persistence.fetchRun(runID: run.id) ?? run
            let workspaceSnapshotRecord = try persistence.fetchWorkspaceSnapshot(runID: run.id)
            let workingMemoryRecord = try persistence.fetchWorkingMemory(runID: run.id)
            let preparedContext = ContextManager.prepare(
                context: .init(
                    thread: thread,
                    run: refreshedRun,
                    messages: messages,
                    availableTools: toolRegistry.schema(),
                    workspaceSnapshot: workspaceSnapshotRecord,
                    workingMemory: workingMemoryRecord
                ),
                provider: modelAdapter.providerID,
                model: modelAdapter.modelID
            )
            try emitter.emit(
                .contextPrepared(
                    runID: run.id,
                    retainedMessages: preparedContext.retainedMessages.count,
                    droppedMessages: preparedContext.droppedMessageCount,
                    estimatedTokens: preparedContext.estimatedTokenCount,
                    estimatedContextWindow: preparedContext.estimatedContextWindow
                ),
                runID: run.id
            )
            if let compaction = preparedContext.compaction {
                let existingCompactions = try persistence.fetchContextCompactions(runID: run.id)
                let latestCompaction = existingCompactions.last
                let isDuplicateCompaction =
                    latestCompaction?.summary == compaction.summary &&
                    latestCompaction?.droppedMessageCount == preparedContext.droppedMessageCount &&
                    latestCompaction?.retainedMessageCount == preparedContext.retainedMessages.count

                if !isDuplicateCompaction {
                    _ = try persistence.recordContextCompaction(
                        runID: run.id,
                        droppedMessageCount: preparedContext.droppedMessageCount,
                        retainedMessageCount: preparedContext.retainedMessages.count,
                        estimatedTokenCount: preparedContext.estimatedTokenCount,
                        estimatedContextWindow: preparedContext.estimatedContextWindow,
                        summary: compaction.summary,
                        now: clock()
                    )
                    try emitter.emit(
                        .contextCompacted(
                            runID: run.id,
                            droppedMessages: preparedContext.droppedMessageCount,
                            summary: compaction.summary
                        ),
                        runID: run.id
                    )
                }
            }
            let action = try await modelAdapter.nextAction(for: .init(
                thread: thread,
                run: refreshedRun,
                messages: messages,
                availableTools: toolRegistry.schema(),
                workspaceSnapshot: workspaceSnapshotRecord,
                workingMemory: workingMemoryRecord
            ))

            switch action {
            case .finalAnswer(let answer):
                return .init(summary: answer, changedFiles: changedFiles)

            case .toolCall(let call):
                let callSignature = Self.toolCallSignature(toolName: call.toolName, arguments: call.arguments)
                if callSignature == repeatedToolCallSignature {
                    repeatedToolCallCount += 1
                } else {
                    repeatedToolCallSignature = callSignature
                    repeatedToolCallCount = 1
                }

                if repeatedToolCallCount >= 2,
                   let lastSafeToolResult,
                   Self.isSafeRepeatedToolCall(toolName: call.toolName, arguments: call.arguments) {
                    try emitter.emit(.status(runID: run.id, message: "Detected a repeated identical read-only tool call. Returning the previous result."), runID: run.id)
                    return .init(summary: "Using the latest tool result because the model repeated the same read-only call.\n\n\(lastSafeToolResult)", changedFiles: changedFiles)
                }

                let execution = try await toolExecutor.execute(
                    call: call,
                    threadID: thread.id,
                    runID: run.id,
                    preconditions: .init(hasPriorInspection: workflowState.hasPriorInspection, phase: stepPhase),
                    cancellation: cancellation,
                    emitter: emitter
                )
                switch execution {
                case .retryableFailure:
                    lastSafeToolResult = nil
                    continue
                case .completed(let text, let safeToReuse, let metadata):
                    lastSafeToolResult = safeToReuse ? text : nil
                    workflowState.record(metadata: metadata)
                    let newChanges = metadata.changedPaths.map { ChangedArtifact(path: $0, reason: stepTitle) }
                    changedFiles.append(contentsOf: newChanges)
                    try persistWorkingMemory(
                        runID: run.id,
                        currentTask: stepPrompt,
                        currentPhase: stepPhase,
                        workflowState: workflowState,
                        changedFiles: changedFiles,
                        summary: metadata.summary.isEmpty ? text : metadata.summary,
                        overrideSuggestions: Self.validationSuggestions(for: stepPrompt, phase: stepPhase, changedFiles: changedFiles.map(\.path))
                    )
                    if !newChanges.isEmpty {
                        try emitter.emit(.changedFilesTracked(runID: run.id, paths: newChanges.map(\.path)), runID: run.id)
                    }
                }
            }
        }

        throw AshexError.maxIterationsReached(maxIterations)
    }

    private func finalizeFailure(error: Error, emitter: EventEmitter) async {
        let runID = emitter.currentRunID
        let description = error.localizedDescription
        do {
            if let runID {
                let state: RunState
                if error is CancellationError {
                    state = .cancelled
                } else if case AshexError.cancelled = error {
                    state = .cancelled
                } else {
                    state = .failed
                }
                try persistence.transitionRun(runID: runID, to: state, reason: description, now: clock())
                try emitter.emit(.runStateChanged(runID: runID, state: state, reason: description), runID: runID)
                try emitter.emit(.error(runID: runID, message: description), runID: runID)
                try emitter.emit(.runFinished(runID: runID, state: state), runID: runID)
            } else {
                try emitter.emit(.error(runID: nil, message: description), runID: nil)
            }
        } catch {
            let fallback = RuntimeEvent(payload: .error(runID: runID, message: "Failed to finalize run: \(error.localizedDescription)"))
            emitter.continuation.yield(fallback)
        }
    }

    static func shouldRetryToolRequest(after error: Error) -> Bool {
        guard let error = error as? AshexError else { return false }
        switch error {
        case .invalidToolArguments, .toolNotFound:
            return true
        default:
            return false
        }
    }

    private static func toolCallSignature(toolName: String, arguments: JSONObject) -> String {
        "\(toolName):\(JSONValue.object(arguments).prettyPrinted)"
    }

    static func isSafeRepeatedToolCall(toolName: String, arguments: JSONObject) -> Bool {
        guard toolName == "filesystem" else { return false }
        guard let operation = arguments["operation"]?.stringValue else { return false }
        return operation == "read_text_file" || operation == "list_directory" || operation == "find_files" || operation == "search_text" || operation == "file_info"
    }

    private static func compilePlannedRunSummary(request: String, steps: [PlannedStep], summaries: [String]) -> String {
        var lines = ["Completed planned task for: \(request)", ""]
        for (index, step) in steps.enumerated() {
            let summary = index < summaries.count ? summaries[index] : "No summary recorded"
            lines.append("\(index + 1). \(step.title)")
            lines.append(summary)
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decorateFinalSummary(
        base: String,
        request: String,
        changedFiles: [ChangedArtifact],
        remainingItems: [String]
    ) -> String {
        let uniqueChanges = orderedUniqueChanges(from: changedFiles)
        if uniqueChanges.isEmpty && remainingItems.isEmpty {
            return base
        }

        var lines = [base]

        if !uniqueChanges.isEmpty {
            lines.append("")
            lines.append("Changed files:")
            for change in uniqueChanges {
                lines.append("- \(change.path): \(change.reason)")
            }
        }

        lines.append("")
        lines.append("Why:")
        lines.append("- To fulfill: \(request)")

        lines.append("")
        lines.append("What remains:")
        if remainingItems.isEmpty {
            lines.append("- No unresolved follow-up recorded in this run.")
        } else {
            lines.append(contentsOf: remainingItems.map { "- \($0)" })
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func orderedUniqueChanges(from changes: [ChangedArtifact]) -> [ChangedArtifact] {
        var seen: Set<String> = []
        var result: [ChangedArtifact] = []
        for change in changes where !seen.contains(change.path) {
            seen.insert(change.path)
            result.append(change)
        }
        return result
    }

    private func persistWorkingMemory(
        runID: UUID,
        currentTask: String,
        currentPhase: PlannedStepPhase?,
        workflowState: StepWorkflowState?,
        changedFiles: [ChangedArtifact],
        summary: String,
        overrideSuggestions: [String]? = nil
    ) throws {
        let inspectedPaths = workflowState.map { Array($0.inspectedArtifacts).sorted() } ?? []
        let changedPaths = Self.orderedUniqueChanges(from: changedFiles).map(\.path)
        let suggestions = overrideSuggestions ?? Self.validationSuggestions(for: currentTask, phase: currentPhase, changedFiles: changedPaths)
        _ = try persistence.upsertWorkingMemory(
            runID: runID,
            currentTask: currentTask,
            currentPhase: currentPhase?.rawValue,
            inspectedPaths: inspectedPaths,
            changedPaths: changedPaths,
            validationSuggestions: suggestions,
            summary: summary,
            now: clock()
        )
    }

    private static func validationSuggestions(
        for request: String,
        phase: PlannedStepPhase? = nil,
        changedFiles: [String] = []
    ) -> [String] {
        let lowered = request.lowercased()
        var suggestions: [String] = []

        if !changedFiles.isEmpty {
            suggestions.append("git diff")
            suggestions.append("read changed files")
        }
        if lowered.contains("test") || lowered.contains("fix") || lowered.contains("bug") || lowered.contains("refactor") {
            suggestions.append("run targeted tests")
        }
        if lowered.contains("build") || lowered.contains("compile") || lowered.contains("swift") || lowered.contains("package") {
            suggestions.append("run build validation")
        }
        if lowered.contains("git") || lowered.contains("repo") {
            suggestions.append("inspect git status")
        }
        if phase == .exploration {
            suggestions.insert("find_files/search_text/read_text_file", at: 0)
        } else if phase == .validation {
            suggestions.insert("confirm changed files match intent", at: 0)
        }

        if suggestions.isEmpty {
            suggestions = ["inspect changed files", "git diff", "summarize remaining risks"]
        }

        var seen: Set<String> = []
        return suggestions.filter { seen.insert($0).inserted }
    }
}

private struct StepWorkflowState {
    private(set) var inspectedArtifacts: Set<String> = []

    var hasPriorInspection: Bool {
        !inspectedArtifacts.isEmpty
    }

    mutating func record(metadata: ToolExecutionMetadata) {
        inspectedArtifacts.formUnion(metadata.inspectedPaths)
    }
}

private struct StepExecutionOutcome {
    let summary: String
    let changedFiles: [ChangedArtifact]
}

private struct ChangedArtifact {
    let path: String
    let reason: String
}

final class EventEmitter: @unchecked Sendable {
    let persistence: PersistenceStore
    let continuation: AsyncStream<RuntimeEvent>.Continuation
    private let lock = NSLock()
    private(set) var currentRunID: UUID?

    init(persistence: PersistenceStore, continuation: AsyncStream<RuntimeEvent>.Continuation) {
        self.persistence = persistence
        self.continuation = continuation
    }

    func emit(_ payload: RuntimeEventPayload, runID: UUID?) throws {
        let event = RuntimeEvent(payload: payload)
        lock.lock()
        if case .runStarted(_, let id) = payload {
            currentRunID = id
        }
        lock.unlock()
        try persistence.appendEvent(event, runID: runID)
        continuation.yield(event)
    }
}
