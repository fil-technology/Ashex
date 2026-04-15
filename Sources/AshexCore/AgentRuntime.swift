import Foundation

public struct RunRequest: Sendable {
    public enum Mode: Sendable {
        case agent
        case directChat
    }

    public let prompt: String
    public let maxIterations: Int
    public let threadID: UUID?
    public let mode: Mode
    public let executionControl: ExecutionControl?
    public let cancellationToken: CancellationToken?

    public init(
        prompt: String,
        maxIterations: Int = 8,
        threadID: UUID? = nil,
        mode: Mode = .agent,
        executionControl: ExecutionControl? = nil,
        cancellationToken: CancellationToken? = nil
    ) {
        self.prompt = prompt
        self.maxIterations = maxIterations
        self.threadID = threadID
        self.mode = mode
        self.executionControl = executionControl
        self.cancellationToken = cancellationToken
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
        shellExecutionPolicy: ShellExecutionPolicy? = nil,
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
            shellExecutionPolicy: shellExecutionPolicy,
            clock: clock
        )
        try persistence.initialize()
        try persistence.normalizeInterruptedRuns(now: clock())
    }

    public func run(_ request: RunRequest) -> AsyncStream<RuntimeEvent> {
        AsyncStream { continuation in
            let cancellation = request.cancellationToken ?? CancellationToken()
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
            let thread: ThreadRecord
            if let threadID = request.threadID {
                guard let existingThread = try persistence.fetchThread(threadID: threadID) else {
                    throw AshexError.persistence("Requested thread \(threadID.uuidString) does not exist")
                }
                thread = existingThread
            } else {
                thread = try persistence.createThread(now: now)
            }
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
                    projectMarkers: workspaceSnapshot.projectMarkers,
                    sourceRoots: workspaceSnapshot.sourceRoots,
                    testRoots: workspaceSnapshot.testRoots,
                    gitBranch: workspaceSnapshot.gitBranch,
                    gitStatusSummary: workspaceSnapshot.gitStatusSummary,
                    now: clock()
                )
            }

            let userMessage = try persistence.appendMessage(threadID: thread.id, runID: run.id, role: .user, content: request.prompt, now: clock())
            try emitter.emit(.messageAppended(runID: run.id, messageID: userMessage.id, role: .user), runID: run.id)

            if request.mode == .directChat {
                try await executeDirectChatRun(thread: thread, run: run, request: request, emitter: emitter)
                return
            }

            let taskKind = TaskPlanner.classify(prompt: request.prompt)
            let initialWorkspaceSnapshotRecord = try persistence.fetchWorkspaceSnapshot(runID: run.id)
            let initialExplorationPlan = ExplorationStrategy.recommend(
                taskKind: taskKind,
                prompt: request.prompt,
                workspaceSnapshot: initialWorkspaceSnapshotRecord
            )
            _ = try persistence.upsertWorkingMemory(
                runID: run.id,
                currentTask: request.prompt,
                currentPhase: nil,
                explorationTargets: initialExplorationPlan.targetPaths,
                pendingExplorationTargets: initialExplorationPlan.targetPaths,
                inspectedPaths: [],
                changedPaths: [],
                recentFindings: [],
                completedStepSummaries: [],
                unresolvedItems: [],
                validationSuggestions: Self.validationSuggestions(for: request.prompt, taskKind: taskKind),
                plannedChangeSet: initialExplorationPlan.targetPaths,
                patchObjectives: PatchPlanningStrategy.build(
                    taskKind: taskKind,
                    prompt: request.prompt,
                    explorationTargets: initialExplorationPlan.targetPaths,
                    pendingExplorationTargets: initialExplorationPlan.targetPaths,
                    inspectedPaths: [],
                    changedPaths: [],
                    recentFindings: [],
                    workspaceSnapshot: initialWorkspaceSnapshotRecord
                ).objectives,
                carryForwardNotes: [],
                summary: "Run created and waiting for planning/execution.",
                now: clock()
            )
            let plan = await resolveTaskPlan(for: request.prompt, taskKind: taskKind)
            var stepSummaries: [String] = []
            var validationNotes: [String] = []
            var remainingItems: [String] = []
            var changedFiles: [ChangedArtifact] = []

            if let plan, plan.steps.count > 1 {
                let planText = plan.steps.enumerated()
                    .map { "\($0.offset + 1). \($0.element.title)" }
                    .joined(separator: "\n")
                let planMessage = try persistence.appendMessage(threadID: thread.id, runID: run.id, role: .assistant, content: "Plan:\n\(planText)", now: clock())
                try emitter.emit(.messageAppended(runID: run.id, messageID: planMessage.id, role: .assistant), runID: run.id)
                try emitter.emit(.taskPlanCreated(runID: run.id, steps: plan.steps.map(\.title)), runID: run.id)
            }

            let steps = plan?.steps ?? [TaskPlanner.defaultSingleStep(for: request.prompt, taskKind: taskKind)]
            let stepRecords = try persistence.createRunSteps(runID: run.id, steps: steps.map(\.title), now: clock())
            for (index, step) in steps.enumerated() {
                try await cancellation.checkCancellation()
                let workspaceSnapshotRecord = try persistence.fetchWorkspaceSnapshot(runID: run.id)
                let explorationPlan = ExplorationStrategy.recommend(
                    taskKind: taskKind,
                    prompt: request.prompt,
                    workspaceSnapshot: workspaceSnapshotRecord
                )

                if let control = request.executionControl,
                   await control.consumeSkipCurrentStep() {
                    try persistence.transitionRunStep(stepID: stepRecords[index].id, to: .skipped, summary: "Skipped: \(step.title)", now: clock())
                    try emitter.emit(.taskStepFinished(runID: run.id, index: index + 1, total: steps.count, title: step.title, outcome: "skipped"), runID: run.id)
                    stepSummaries.append("Skipped: \(step.title)")
                    continue
                }
                if let control = request.executionControl,
                   await control.consumeCancellationRequest() {
                    await cancellation.cancel()
                }

                try persistence.transitionRunStep(stepID: stepRecords[index].id, to: .running, summary: nil, now: clock())
                try emitter.emit(.workflowPhaseChanged(runID: run.id, phase: step.phase.rawValue, title: step.title), runID: run.id)
                if step.phase == .exploration {
                    try emitter.emit(.status(runID: run.id, message: "Exploration plan: \(explorationPlan.recommendations.first ?? explorationPlan.summary)"), runID: run.id)
                }
                try persistWorkingMemory(
                    runID: run.id,
                    currentTask: request.prompt,
                    currentPhase: step.phase,
                    explorationPlan: explorationPlan,
                    workflowState: nil,
                    changedFiles: changedFiles,
                    summary: "Current step \(index + 1)/\(steps.count): \(step.title)",
                    completedStepSummaries: stepSummaries,
                    unresolvedItems: stepSummaries.filter { $0.hasPrefix("Skipped:") },
                    overrideSuggestions: Self.validationSuggestions(for: request.prompt, taskKind: taskKind, phase: step.phase)
                )
                try emitPatchPlan(
                    runID: run.id,
                    taskKind: taskKind,
                    prompt: request.prompt,
                    explorationPlan: explorationPlan,
                    workflowState: nil,
                    changedFiles: changedFiles,
                    recentFindings: [],
                    emitter: emitter
                )
                try emitter.emit(.taskStepStarted(runID: run.id, index: index + 1, total: steps.count, title: step.title), runID: run.id)
                let stepMessage = steps.count > 1
                    ? """
                    Work on only this step of the larger task.
                    Step \(index + 1) of \(steps.count): \(step.title)
                    Task kind: \(taskKind.rawValue)
                    Phase guidance: \(Self.phaseGuidance(for: taskKind, phase: step.phase))
                    \(Self.phaseStrategyBlock(
                        prompt: request.prompt,
                        taskKind: taskKind,
                        phase: step.phase,
                        workspaceSnapshot: workspaceSnapshotRecord
                    ))
                    Overall user request: \(request.prompt)
                    """
                    : request.prompt

                if steps.count > 1 {
                    let systemMessage = try persistence.appendMessage(threadID: thread.id, runID: run.id, role: .system, content: stepMessage, now: clock())
                    try emitter.emit(.messageAppended(runID: run.id, messageID: systemMessage.id, role: .system), runID: run.id)
                }

                let outcome: StepExecutionOutcome
                if Self.shouldDelegateStep(
                    phase: step.phase,
                    taskKind: taskKind,
                    totalSteps: steps.count,
                    maxIterations: request.maxIterations
                ) {
                    outcome = try await executeDelegatedStep(
                        thread: thread,
                        run: run,
                        stepPrompt: stepMessage,
                        stepTitle: step.title,
                        taskKind: taskKind,
                        stepPhase: step.phase,
                        explorationPlan: explorationPlan,
                        existingChangedFiles: changedFiles,
                        maxIterations: min(max(request.maxIterations / 2, 2), 4),
                        cancellation: cancellation,
                        emitter: emitter
                    )
                } else {
                    outcome = try await executeStep(
                        thread: thread,
                        run: run,
                        stepPrompt: stepMessage,
                        stepTitle: step.title,
                        taskKind: taskKind,
                        stepPhase: step.phase,
                        explorationPlan: explorationPlan,
                        existingChangedFiles: changedFiles,
                        maxIterations: request.maxIterations,
                        cancellation: cancellation,
                        executionControl: request.executionControl,
                        emitter: emitter
                    )
                }
                stepSummaries.append(outcome.summary)
                validationNotes.append(contentsOf: outcome.validationNotes)
                remainingItems.append(contentsOf: outcome.remainingItems)
                changedFiles = Self.mergeChangedArtifacts(changedFiles, outcome.changedFiles)
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
                    validationNotes: validationNotes,
                    remainingItems: remainingItems
                )
            } else {
                finalAnswerText = Self.decorateFinalSummary(
                    base: Self.compilePlannedRunSummary(request: request.prompt, steps: steps, summaries: stepSummaries),
                    request: request.prompt,
                    changedFiles: changedFiles,
                    validationNotes: validationNotes,
                    remainingItems: remainingItems + stepSummaries.filter { $0.hasPrefix("Skipped:") }
                )
            }
            try persistWorkingMemory(
                runID: run.id,
                currentTask: request.prompt,
                currentPhase: .validation,
                explorationPlan: initialExplorationPlan,
                workflowState: nil,
                changedFiles: changedFiles,
                summary: finalAnswerText,
                completedStepSummaries: stepSummaries,
                unresolvedItems: stepSummaries.filter { $0.hasPrefix("Skipped:") },
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

    private func resolveTaskPlan(for prompt: String, taskKind: TaskKind) async -> TaskPlan? {
        guard TaskPlanner.shouldAttemptModelPlanning(for: prompt) else {
            return TaskPlanner.plan(for: prompt)
        }

        if let planningAdapter = modelAdapter as? any TaskPlanningModelAdapter {
            do {
                if let generatedPlan = try await planningAdapter.taskPlan(for: prompt, taskKind: taskKind) {
                    return generatedPlan
                }
            } catch {
                // Fall back to the existing heuristic planner when structured planning is unavailable.
            }
        }

        return TaskPlanner.plan(for: prompt)
    }

    private func executeDirectChatRun(
        thread: ThreadRecord,
        run: RunRecord,
        request: RunRequest,
        emitter: EventEmitter
    ) async throws {
        guard let adapter = modelAdapter as? any DirectChatModelAdapter else {
            throw AshexError.model("Selected provider does not support direct chat mode")
        }

        let history = try persistence.fetchMessages(threadID: thread.id)
        let systemPrompt = """
        You are Ash, a helpful local-first assistant replying in a Telegram chat.
        Answer naturally and conversationally.
        Do not inspect the workspace, do not call tools, and do not mention internal runtime mechanics unless the user asks.
        Keep answers concise unless the user asks for more detail.
        """
        let reply = try await adapter.directReply(history: history, systemPrompt: systemPrompt)
        let assistantMessage = try persistence.appendMessage(threadID: thread.id, runID: run.id, role: .assistant, content: reply, now: clock())
        try emitter.emit(.messageAppended(runID: run.id, messageID: assistantMessage.id, role: .assistant), runID: run.id)
        try emitter.emit(.finalAnswer(runID: run.id, messageID: assistantMessage.id, text: reply), runID: run.id)
        try persistence.transitionRun(runID: run.id, to: .completed, reason: nil, now: clock())
        try emitter.emit(.runStateChanged(runID: run.id, state: .completed, reason: nil), runID: run.id)
        try emitter.emit(.runFinished(runID: run.id, state: .completed), runID: run.id)
    }

    private static func shouldDelegateStep(
        phase: PlannedStepPhase,
        taskKind: TaskKind,
        totalSteps: Int,
        maxIterations: Int
    ) -> Bool {
        guard totalSteps >= 4, maxIterations >= 4 else { return false }
        guard phase == .exploration || phase == .planning || phase == .validation else { return false }

        switch taskKind {
        case .bugFix, .feature, .refactor, .analysis, .general:
            return true
        case .docs, .git, .shell:
            return phase == .exploration || phase == .validation
        }
    }

    private func executeDelegatedStep(
        thread: ThreadRecord,
        run: RunRecord,
        stepPrompt: String,
        stepTitle: String,
        taskKind: TaskKind,
        stepPhase: PlannedStepPhase,
        explorationPlan: ExplorationPlan,
        existingChangedFiles: [ChangedArtifact],
        maxIterations: Int,
        cancellation: CancellationToken,
        emitter: EventEmitter
    ) async throws -> StepExecutionOutcome {
        let parallelItems = DelegationStrategy.parallelWorkItems(
            phase: stepPhase,
            taskKind: taskKind,
            stepTitle: stepTitle,
            stepPrompt: stepPrompt,
            explorationPlan: explorationPlan,
            changedPaths: existingChangedFiles.map(\.path)
        )
        if parallelItems.count > 1 {
            return try await executeParallelDelegatedStep(
                thread: thread,
                run: run,
                stepPrompt: stepPrompt,
                stepTitle: stepTitle,
                taskKind: taskKind,
                stepPhase: stepPhase,
                explorationPlan: explorationPlan,
                existingChangedFiles: existingChangedFiles,
                workItems: parallelItems,
                maxIterations: maxIterations,
                cancellation: cancellation,
                emitter: emitter
            )
        }

        let brief = DelegationStrategy.brief(
            phase: stepPhase,
            taskKind: taskKind,
            stepTitle: stepTitle,
            explorationPlan: explorationPlan
        )
        try emitter.emit(.subagentAssigned(runID: run.id, title: stepTitle, role: brief.role, goal: brief.goal), runID: run.id)
        try emitter.emit(.subagentStarted(runID: run.id, title: stepTitle, maxIterations: maxIterations), runID: run.id)
        let outcome = try await executeSubagentLoop(
            thread: thread,
            run: run,
            stepPrompt: stepPrompt,
            stepTitle: stepTitle,
            delegationBrief: brief,
            taskKind: taskKind,
            stepPhase: stepPhase,
            explorationPlan: explorationPlan,
            existingChangedFiles: existingChangedFiles,
            maxIterations: maxIterations,
            cancellation: cancellation,
            emitter: emitter
        )
        let handoff = DelegationStrategy.parseHandoff(outcome.summary)
        let mergedRemainingItems = Self.orderedUniqueStrings(from: handoff.remainingItems + outcome.remainingItems)
        try persistWorkingMemory(
            runID: run.id,
            currentTask: stepPrompt,
            currentPhase: stepPhase,
            explorationPlan: explorationPlan,
            workflowState: nil,
            changedFiles: outcome.changedFiles,
            summary: handoff.summary,
            completedStepSummaries: [],
            unresolvedItems: mergedRemainingItems,
            overrideSuggestions: Self.validationSuggestions(for: stepPrompt, taskKind: taskKind, phase: stepPhase, changedFiles: outcome.changedFiles.map(\.path)),
            carryForwardNotes: handoff.findings + mergedRemainingItems
        )
        try emitter.emit(
            .patchPlanUpdated(
                runID: run.id,
                paths: handoff.recommendedPaths.isEmpty ? outcome.changedFiles.map(\.path) : handoff.recommendedPaths,
                objectives: handoff.findings.isEmpty ? brief.deliverables : handoff.findings
            ),
            runID: run.id
        )
        try emitter.emit(
            .subagentHandoff(
                runID: run.id,
                title: stepTitle,
                role: brief.role,
                summary: handoff.summary,
                remainingItems: mergedRemainingItems
            ),
            runID: run.id
        )
        try emitter.emit(.subagentFinished(runID: run.id, title: stepTitle, summary: handoff.summary), runID: run.id)
        return .init(summary: handoff.summary, changedFiles: outcome.changedFiles, validationNotes: outcome.validationNotes, remainingItems: mergedRemainingItems)
    }

    private func executeParallelDelegatedStep(
        thread: ThreadRecord,
        run: RunRecord,
        stepPrompt: String,
        stepTitle: String,
        taskKind: TaskKind,
        stepPhase: PlannedStepPhase,
        explorationPlan: ExplorationPlan,
        existingChangedFiles: [ChangedArtifact],
        workItems: [DelegatedWorkItem],
        maxIterations: Int,
        cancellation: CancellationToken,
        emitter: EventEmitter
    ) async throws -> StepExecutionOutcome {
        try emitter.emit(.status(runID: run.id, message: "Launching \(workItems.count) bounded read-only subagents for \(stepPhase.rawValue)."), runID: run.id)

        struct FinishedDelegatedWork: Sendable {
            let item: DelegatedWorkItem
            let outcome: StepExecutionOutcome
            let handoff: DelegationHandoff
        }

        var finishedWork: [FinishedDelegatedWork] = []
        try await withThrowingTaskGroup(of: FinishedDelegatedWork.self) { group in
            for item in workItems {
                try emitter.emit(.subagentAssigned(runID: run.id, title: item.title, role: item.brief.role, goal: item.brief.goal), runID: run.id)
                try emitter.emit(.subagentStarted(runID: run.id, title: item.title, maxIterations: maxIterations), runID: run.id)
                group.addTask { [self] in
                    let outcome = try await executeSubagentLoop(
                        thread: thread,
                        run: run,
                        stepPrompt: item.scopedPrompt,
                        stepTitle: item.title,
                        delegationBrief: item.brief,
                        taskKind: taskKind,
                        stepPhase: stepPhase,
                        explorationPlan: explorationPlan,
                        existingChangedFiles: existingChangedFiles,
                        maxIterations: max(2, min(maxIterations, 3)),
                        cancellation: cancellation,
                        allowedToolNames: item.allowedToolNames,
                        emitter: emitter
                    )
                    return FinishedDelegatedWork(
                        item: item,
                        outcome: outcome,
                        handoff: DelegationStrategy.parseHandoff(outcome.summary)
                    )
                }
            }

            for try await finished in group {
                finishedWork.append(finished)
            }
        }

        var mergedSummarySections: [String] = []
        var mergedChangedFiles: [ChangedArtifact] = existingChangedFiles
        var mergedValidationNotes: [String] = []
        var mergedRemainingItems: [String] = []
        var mergedPaths: [String] = []
        var mergedObjectives: [String] = []
        var carryForwardNotes: [String] = []

        for finished in finishedWork.sorted(by: { $0.item.title < $1.item.title }) {
            let remainingItems = Self.orderedUniqueStrings(from: finished.handoff.remainingItems + finished.outcome.remainingItems)
            try emitter.emit(
                .subagentHandoff(
                    runID: run.id,
                    title: finished.item.title,
                    role: finished.item.brief.role,
                    summary: finished.handoff.summary,
                    remainingItems: remainingItems
                ),
                runID: run.id
            )
            try emitter.emit(.subagentFinished(runID: run.id, title: finished.item.title, summary: finished.handoff.summary), runID: run.id)

            mergedSummarySections.append("\(finished.item.title): \(finished.handoff.summary)")
            mergedChangedFiles = Self.mergeChangedArtifacts(mergedChangedFiles, finished.outcome.changedFiles)
            mergedValidationNotes.append(contentsOf: finished.outcome.validationNotes)
            mergedRemainingItems.append(contentsOf: remainingItems)
            mergedPaths.append(contentsOf: finished.handoff.recommendedPaths)
            mergedObjectives.append(contentsOf: finished.handoff.findings.isEmpty ? finished.item.brief.deliverables : finished.handoff.findings)
            carryForwardNotes.append(contentsOf: finished.handoff.findings + remainingItems)
        }

        let mergedRemaining = Self.orderedUniqueStrings(from: mergedRemainingItems)
        let mergedObjectiveList = Self.orderedUniqueStrings(from: mergedObjectives)
        let mergedPathList = Self.orderedUniqueStrings(from: mergedPaths)
        let mergedSummary = mergedSummarySections.joined(separator: "\n\n")

        try persistWorkingMemory(
            runID: run.id,
            currentTask: stepPrompt,
            currentPhase: stepPhase,
            explorationPlan: explorationPlan,
            workflowState: nil,
            changedFiles: mergedChangedFiles,
            summary: mergedSummary,
            completedStepSummaries: [],
            unresolvedItems: mergedRemaining,
            overrideSuggestions: Self.validationSuggestions(for: stepPrompt, taskKind: taskKind, phase: stepPhase, changedFiles: mergedChangedFiles.map(\.path)),
            carryForwardNotes: carryForwardNotes
        )
        try emitter.emit(
            .patchPlanUpdated(
                runID: run.id,
                paths: mergedPathList,
                objectives: mergedObjectiveList
            ),
            runID: run.id
        )

        return .init(
            summary: mergedSummary,
            changedFiles: mergedChangedFiles,
            validationNotes: Self.orderedUniqueStrings(from: mergedValidationNotes),
            remainingItems: mergedRemaining
        )
    }

    private func executeStep(
        thread: ThreadRecord,
        run: RunRecord,
        stepPrompt: String,
        stepTitle: String,
        taskKind: TaskKind,
        stepPhase: PlannedStepPhase,
        explorationPlan: ExplorationPlan,
        existingChangedFiles: [ChangedArtifact],
        maxIterations: Int,
        cancellation: CancellationToken,
        executionControl: ExecutionControl?,
        emitter: EventEmitter
    ) async throws -> StepExecutionOutcome {
        var repeatedToolCallSignature: String?
        var repeatedToolCallCount = 0
        var lastSafeToolResult: String?
        var noProgressIterations = 0
        var validationBlocks = 0
        var automaticValidationAttempted = false
        var workflowState = StepWorkflowState(targetArtifacts: explorationPlan.targetPaths)
        var changedFiles: [ChangedArtifact] = existingChangedFiles

        for iteration in 0..<maxIterations {
            try await cancellation.checkCancellation()
            if let executionControl, await executionControl.consumeSkipCurrentStep() {
                return .init(summary: "Skipped current step", changedFiles: [], validationNotes: [], remainingItems: [])
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
                    clippedMessages: preparedContext.clippedMessageCount,
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
                        estimatedSavedTokenCount: compaction.estimatedSavedTokenCount,
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
                if stepPhase == .validation,
                   !changedFiles.isEmpty,
                   !workflowState.hasValidationEvidence(for: changedFiles.map(\.path)) {
                    if !automaticValidationAttempted {
                        automaticValidationAttempted = true
                        let automaticNotes = try await executeAutomaticValidation(
                            thread: thread,
                            run: run,
                            request: stepPrompt,
                            taskKind: taskKind,
                            changedFiles: changedFiles.map(\.path),
                            workflowState: &workflowState,
                            emitter: emitter,
                            cancellation: cancellation
                        )
                        try persistWorkingMemory(
                            runID: run.id,
                            currentTask: stepPrompt,
                            currentPhase: stepPhase,
                            explorationPlan: explorationPlan,
                            workflowState: workflowState,
                            changedFiles: changedFiles,
                            summary: automaticNotes.last ?? "Ran automatic validation checks.",
                            completedStepSummaries: [],
                            unresolvedItems: [],
                            overrideSuggestions: Self.validationSuggestions(for: stepPrompt, taskKind: taskKind, phase: stepPhase, changedFiles: changedFiles.map(\.path))
                        )
                        continue
                    }
                    validationBlocks += 1
                    let validationReminder = "Validation is incomplete: inspect changed files, git diffs, or run a relevant check before concluding."
                    let toolMessage = try persistence.appendMessage(threadID: thread.id, runID: run.id, role: .tool, content: validationReminder, now: clock())
                    try emitter.emit(.messageAppended(runID: run.id, messageID: toolMessage.id, role: .tool), runID: run.id)
                    try emitter.emit(.status(runID: run.id, message: "Validation gate blocked completion. Asking the model to produce concrete verification first."), runID: run.id)
                    if validationBlocks >= 3 {
                        let note = "Validation did not produce enough concrete verification before the step ended."
                        return .init(
                            summary: "Stopped validation early after repeated attempts without concrete verification.",
                            changedFiles: changedFiles,
                            validationNotes: [],
                            remainingItems: [note]
                        )
                    }
                    continue
                }
                let finalValidationNotes = stepPhase == .validation && !changedFiles.isEmpty
                    ? (workflowState.validationNotes.isEmpty
                        ? ["Validation completed with concrete verification for the changed files."]
                        : workflowState.validationNotes)
                    : []
                return .init(summary: answer, changedFiles: changedFiles, validationNotes: finalValidationNotes, remainingItems: [])

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
                    return .init(
                        summary: "Using the latest tool result because the model repeated the same read-only call.\n\n\(lastSafeToolResult)",
                        changedFiles: changedFiles,
                        validationNotes: [],
                        remainingItems: []
                    )
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
                    noProgressIterations += 1
                    if noProgressIterations >= 3 {
                        try emitter.emit(.status(runID: run.id, message: "Detected repeated unproductive retries. Ending the current step with a recoverable summary."), runID: run.id)
                        return .init(
                            summary: "Stopped the current step after repeated unproductive retries.",
                            changedFiles: changedFiles,
                            validationNotes: [],
                            remainingItems: ["Revisit step: \(stepTitle)"]
                        )
                    }
                    continue
                case .completed(let text, let safeToReuse, let metadata):
                    lastSafeToolResult = safeToReuse ? text : nil
                    workflowState.record(metadata: metadata)
                    noProgressIterations = metadata.representsProgress ? 0 : (noProgressIterations + 1)
                    let newChanges = metadata.changedPaths.map { ChangedArtifact(path: $0, reason: stepTitle) }
                    changedFiles.append(contentsOf: newChanges)
                    try persistWorkingMemory(
                        runID: run.id,
                        currentTask: stepPrompt,
                        currentPhase: stepPhase,
                        explorationPlan: explorationPlan,
                        workflowState: workflowState,
                        changedFiles: changedFiles,
                        summary: metadata.summary.isEmpty ? text : metadata.summary,
                        completedStepSummaries: [],
                        unresolvedItems: [],
                        overrideSuggestions: Self.validationSuggestions(for: stepPrompt, taskKind: taskKind, phase: stepPhase, changedFiles: changedFiles.map(\.path))
                    )
                    try emitPatchPlan(
                        runID: run.id,
                        taskKind: taskKind,
                        prompt: stepPrompt,
                        explorationPlan: explorationPlan,
                        workflowState: workflowState,
                        changedFiles: changedFiles,
                        recentFindings: workflowState.recentFindings,
                        emitter: emitter
                    )
                    if !newChanges.isEmpty {
                        try emitter.emit(.changedFilesTracked(runID: run.id, paths: newChanges.map(\.path)), runID: run.id)
                    }
                    if noProgressIterations >= 3 {
                        try emitter.emit(.status(runID: run.id, message: "Tool activity is no longer making useful progress. Ending the step with a recoverable summary."), runID: run.id)
                        return .init(
                            summary: "Stopped the current step because recent tool activity was no longer making useful progress.",
                            changedFiles: changedFiles,
                            validationNotes: [],
                            remainingItems: ["Revisit step: \(stepTitle)"]
                        )
                    }
                }
            }
        }

        return .init(
            summary: "Stopped after reaching the iteration budget for this step.",
            changedFiles: changedFiles,
            validationNotes: [],
            remainingItems: ["Iteration budget reached for step: \(stepTitle)"]
        )
    }

    private func executeSubagentLoop(
        thread: ThreadRecord,
        run: RunRecord,
        stepPrompt: String,
        stepTitle: String,
        delegationBrief: DelegationBrief,
        taskKind: TaskKind,
        stepPhase: PlannedStepPhase,
        explorationPlan: ExplorationPlan,
        existingChangedFiles: [ChangedArtifact],
        maxIterations: Int,
        cancellation: CancellationToken,
        allowedToolNames: Set<String>? = nil,
        emitter: EventEmitter
    ) async throws -> StepExecutionOutcome {
        var localMessages: [MessageRecord] = [
            MessageRecord(
                id: UUID(),
                threadID: thread.id,
                runID: run.id,
                role: .user,
                content: """
                Delegated subtask:
                \(stepPrompt)

                Delegation role: \(delegationBrief.role)
                Goal: \(delegationBrief.goal)
                Deliverables:
                \(delegationBrief.deliverables.map { "- \($0)" }.joined(separator: "\n"))

                You are a bounded subagent. Stay within this step only, do not expand scope, and finish with a concise handoff using:
                SUMMARY:
                FINDINGS:
                REMAINING:
                FILES:
                """,
                createdAt: clock()
            )
        ]
        var repeatedToolCallSignature: String?
        var repeatedToolCallCount = 0
        var lastSafeToolResult: String?
        var noProgressIterations = 0
        var validationBlocks = 0
        var automaticValidationAttempted = false
        var workflowState = StepWorkflowState(targetArtifacts: explorationPlan.targetPaths)
        var changedFiles: [ChangedArtifact] = existingChangedFiles

        for iteration in 0..<maxIterations {
            try await cancellation.checkCancellation()
            try emitter.emit(.status(runID: run.id, message: "Subagent iteration \(iteration + 1): working on \(stepTitle)"), runID: run.id)

            let refreshedRun = try persistence.fetchRun(runID: run.id) ?? run
            let workspaceSnapshotRecord = try persistence.fetchWorkspaceSnapshot(runID: run.id)
            let workingMemoryRecord = try persistence.fetchWorkingMemory(runID: run.id)
            let preparedContext = ContextManager.prepare(
                context: .init(
                    thread: thread,
                    run: refreshedRun,
                    messages: localMessages,
                    availableTools: toolRegistry.schema().filter { allowedToolNames?.contains($0.name) ?? true },
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
                    clippedMessages: preparedContext.clippedMessageCount,
                    estimatedTokens: preparedContext.estimatedTokenCount,
                    estimatedContextWindow: preparedContext.estimatedContextWindow
                ),
                runID: run.id
            )

            let action = try await modelAdapter.nextAction(for: .init(
                thread: thread,
                run: refreshedRun,
                messages: localMessages,
                availableTools: toolRegistry.schema().filter { allowedToolNames?.contains($0.name) ?? true },
                workspaceSnapshot: workspaceSnapshotRecord,
                workingMemory: workingMemoryRecord
            ))

            switch action {
            case .finalAnswer(let answer):
                if stepPhase == .validation,
                   !changedFiles.isEmpty,
                   !workflowState.hasValidationEvidence(for: changedFiles.map(\.path)) {
                    if !automaticValidationAttempted {
                        automaticValidationAttempted = true
                        _ = try await executeAutomaticValidation(
                            thread: thread,
                            run: run,
                            request: stepPrompt,
                            taskKind: taskKind,
                            changedFiles: changedFiles.map(\.path),
                            workflowState: &workflowState,
                            emitter: emitter,
                            cancellation: cancellation
                        )
                        continue
                    }
                    validationBlocks += 1
                    let validationReminder = "Validation is incomplete: inspect changed files, git diffs, or run a relevant check before concluding."
                    localMessages.append(MessageRecord(
                        id: UUID(),
                        threadID: thread.id,
                        runID: run.id,
                        role: .tool,
                        content: validationReminder,
                        createdAt: clock()
                    ))
                    try emitter.emit(.status(runID: run.id, message: "Subagent validation gate blocked completion. Asking for concrete verification first."), runID: run.id)
                    if validationBlocks >= 2 {
                        return .init(
                            summary: "Subagent stopped validation early after repeated attempts without concrete verification.",
                            changedFiles: changedFiles,
                            validationNotes: [],
                            remainingItems: ["Revisit delegated validation: \(stepTitle)"]
                        )
                    }
                    continue
                }
                let finalValidationNotes = stepPhase == .validation && !changedFiles.isEmpty
                    ? (workflowState.validationNotes.isEmpty
                        ? ["Validation completed with concrete verification for the changed files."]
                        : workflowState.validationNotes)
                    : []
                return .init(summary: answer, changedFiles: changedFiles, validationNotes: finalValidationNotes, remainingItems: [])

            case .toolCall(let call):
                if let allowedToolNames, !allowedToolNames.contains(call.toolName) {
                    localMessages.append(MessageRecord(
                        id: UUID(),
                        threadID: thread.id,
                        runID: run.id,
                        role: .tool,
                        content: "Tool \(call.toolName) is not available inside this delegated scope. Stay within the allowed read-only tools.",
                        createdAt: clock()
                    ))
                    continue
                }
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
                    return .init(
                        summary: "Subagent reused the latest safe tool result after repeated identical read-only calls.\n\n\(lastSafeToolResult)",
                        changedFiles: changedFiles,
                        validationNotes: [],
                        remainingItems: []
                    )
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
                    noProgressIterations += 1
                    localMessages.append(MessageRecord(
                        id: UUID(),
                        threadID: thread.id,
                        runID: run.id,
                        role: .tool,
                        content: "Tool error: bounded subagent requested a retry.",
                        createdAt: clock()
                    ))
                    if noProgressIterations >= 2 {
                        return .init(
                            summary: "Subagent stopped after repeated unproductive retries.",
                            changedFiles: changedFiles,
                            validationNotes: [],
                            remainingItems: ["Revisit delegated step: \(stepTitle)"]
                        )
                    }
                case .completed(let text, let safeToReuse, let metadata):
                    lastSafeToolResult = safeToReuse ? text : nil
                    workflowState.record(metadata: metadata)
                    noProgressIterations = metadata.representsProgress ? 0 : (noProgressIterations + 1)
                    let newChanges = metadata.changedPaths.map { ChangedArtifact(path: $0, reason: stepTitle) }
                    changedFiles.append(contentsOf: newChanges)
                    localMessages.append(MessageRecord(
                        id: UUID(),
                        threadID: thread.id,
                        runID: run.id,
                        role: .tool,
                        content: text,
                        createdAt: clock()
                    ))
                    if noProgressIterations >= 2 {
                        return .init(
                            summary: "Subagent stopped because recent tool activity was no longer making useful progress.",
                            changedFiles: changedFiles,
                            validationNotes: [],
                            remainingItems: ["Revisit delegated step: \(stepTitle)"]
                        )
                    }
                }
            }
        }

        return .init(
            summary: "Subagent stopped after reaching its bounded iteration budget for this step.",
            changedFiles: changedFiles,
            validationNotes: [],
            remainingItems: ["Delegated step hit its iteration budget: \(stepTitle)"]
        )
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
        validationNotes: [String],
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
        lines.append("Validation:")
        if validationNotes.isEmpty {
            lines.append("- No explicit validation note recorded in this run.")
        } else {
            lines.append(contentsOf: orderedUniqueStrings(from: validationNotes).map { "- \($0)" })
        }

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

    private static func orderedUniqueStrings(from values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private func executeAutomaticValidation(
        thread: ThreadRecord,
        run: RunRecord,
        request: String,
        taskKind: TaskKind,
        changedFiles: [String],
        workflowState: inout StepWorkflowState,
        emitter: EventEmitter,
        cancellation: CancellationToken
    ) async throws -> [String] {
        let workspaceSnapshotRecord = try persistence.fetchWorkspaceSnapshot(runID: run.id)
        let availableToolNames = Set(toolRegistry.schema().map(\.name))
        let actions = ValidationStrategy.plan(
            request: request,
            taskKind: taskKind,
            changedFiles: changedFiles,
            workspaceSnapshot: workspaceSnapshotRecord,
            availableToolNames: availableToolNames
        )

        guard !actions.isEmpty else {
            return []
        }

        var notes: [String] = []
        for action in actions {
            try await cancellation.checkCancellation()
            try emitter.emit(.status(runID: run.id, message: "Automatic validation: \(action.summary)"), runID: run.id)
            do {
                let result = try await toolExecutor.execute(
                    call: action.call,
                    threadID: thread.id,
                    runID: run.id,
                    preconditions: .init(hasPriorInspection: true, phase: .validation),
                    cancellation: cancellation,
                    emitter: emitter
                )

                switch result {
                case .retryableFailure:
                    notes.append("Automatic validation requested a retry for \(action.call.toolName).")
                case .completed(let output, _, let metadata):
                    workflowState.record(metadata: metadata)
                    let note = metadata.summary.isEmpty ? "Validated with \(action.call.toolName)." : metadata.summary
                    notes.append(note)
                    if metadata.validationArtifacts.isEmpty, !output.isEmpty {
                        notes.append("Captured validation output from \(action.call.toolName).")
                    }
                }
            } catch {
                notes.append("Validation check failed: \(action.summary)")
            }
        }

        return Self.orderedUniqueStrings(from: notes)
    }

    private func persistWorkingMemory(
        runID: UUID,
        currentTask: String,
        currentPhase: PlannedStepPhase?,
        explorationPlan: ExplorationPlan?,
        workflowState: StepWorkflowState?,
        changedFiles: [ChangedArtifact],
        summary: String,
        completedStepSummaries: [String] = [],
        unresolvedItems: [String] = [],
        overrideSuggestions: [String]? = nil,
        carryForwardNotes: [String] = []
    ) throws {
        let explorationTargets = explorationPlan?.targetPaths ?? workflowState?.explorationTargets ?? []
        let pendingExplorationTargets = workflowState?.pendingExplorationTargets ?? explorationTargets
        let inspectedPaths = workflowState.map { Array($0.inspectedArtifacts).sorted() } ?? []
        let changedPaths = Self.orderedUniqueChanges(from: changedFiles).map(\.path)
        let recentFindings = workflowState?.recentFindings ?? []
        let suggestions = overrideSuggestions ?? Self.validationSuggestions(for: currentTask, taskKind: TaskPlanner.classify(prompt: currentTask), phase: currentPhase, changedFiles: changedPaths)
        let patchPlan = PatchPlanningStrategy.build(
            taskKind: TaskPlanner.classify(prompt: currentTask),
            prompt: currentTask,
            explorationTargets: explorationTargets,
            pendingExplorationTargets: pendingExplorationTargets,
            inspectedPaths: inspectedPaths,
            changedPaths: changedPaths,
            recentFindings: recentFindings,
            workspaceSnapshot: try persistence.fetchWorkspaceSnapshot(runID: runID)
        )
        let carryForward = Self.orderedUniqueStrings(from:
            carryForwardNotes
            + (workflowState?.validationNotes ?? [])
            + Array(recentFindings.suffix(3))
            + Array(completedStepSummaries.suffix(3))
        )
        _ = try persistence.upsertWorkingMemory(
            runID: runID,
            currentTask: currentTask,
            currentPhase: currentPhase?.rawValue,
            explorationTargets: explorationTargets,
            pendingExplorationTargets: pendingExplorationTargets,
            inspectedPaths: inspectedPaths,
            changedPaths: changedPaths,
            recentFindings: recentFindings,
            completedStepSummaries: completedStepSummaries.suffix(6).map { $0 },
            unresolvedItems: unresolvedItems,
            validationSuggestions: suggestions,
            plannedChangeSet: patchPlan.targetPaths,
            patchObjectives: patchPlan.objectives,
            carryForwardNotes: Array(carryForward.suffix(8)),
            summary: summary,
            now: clock()
        )
    }

    private func emitPatchPlan(
        runID: UUID,
        taskKind: TaskKind,
        prompt: String,
        explorationPlan: ExplorationPlan?,
        workflowState: StepWorkflowState?,
        changedFiles: [ChangedArtifact],
        recentFindings: [String],
        emitter: EventEmitter
    ) throws {
        let workingMemory = try persistence.fetchWorkingMemory(runID: runID)
        let patchPlan = PatchPlanningStrategy.build(
            taskKind: taskKind,
            prompt: prompt,
            explorationTargets: explorationPlan?.targetPaths ?? workflowState?.explorationTargets ?? workingMemory?.explorationTargets ?? [],
            pendingExplorationTargets: workflowState?.pendingExplorationTargets ?? workingMemory?.pendingExplorationTargets ?? [],
            inspectedPaths: workflowState.map { Array($0.inspectedArtifacts) } ?? workingMemory?.inspectedPaths ?? [],
            changedPaths: Self.orderedUniqueChanges(from: changedFiles).map(\.path),
            recentFindings: recentFindings + (workflowState?.recentFindings ?? []) + (workingMemory?.recentFindings ?? []),
            workspaceSnapshot: try persistence.fetchWorkspaceSnapshot(runID: runID)
        )
        try emitter.emit(.patchPlanUpdated(runID: runID, paths: patchPlan.targetPaths, objectives: patchPlan.objectives), runID: runID)
    }

    private static func validationSuggestions(
        for request: String,
        taskKind: TaskKind,
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
            suggestions.insert(explorationSuggestion(for: taskKind), at: 0)
        } else if phase == .validation {
            suggestions.insert(validationHeadline(for: taskKind), at: 0)
        }

        if suggestions.isEmpty {
            suggestions = ["inspect changed files", "git diff", "summarize remaining risks"]
        }

        var seen: Set<String> = []
        return suggestions.filter { seen.insert($0).inserted }
    }

    private static func phaseGuidance(for taskKind: TaskKind, phase: PlannedStepPhase) -> String {
        switch phase {
        case .exploration:
            return explorationSuggestion(for: taskKind)
        case .planning:
            switch taskKind {
            case .bugFix:
                return "prefer the smallest safe fix and identify the exact validation path before editing"
            case .feature:
                return "identify the minimal file set, expected behavior, and validation checks before implementing"
            case .refactor:
                return "define safe refactor boundaries and preserve behavior"
            case .docs:
                return "identify the exact docs to update and the intended wording changes"
            case .git:
                return "decide the exact git inspection or repo operation outcome needed"
            case .shell:
                return "choose the smallest command sequence that proves the result"
            case .analysis, .general:
                return "plan the smallest effective sequence of reads, changes, and checks"
            }
        case .mutation:
            return "apply only the changes justified by the inspection and plan"
        case .validation:
            return validationHeadline(for: taskKind)
        }
    }

    private static func phaseStrategyBlock(
        prompt: String,
        taskKind: TaskKind,
        phase: PlannedStepPhase,
        workspaceSnapshot: WorkspaceSnapshotRecord?
    ) -> String {
        switch phase {
        case .exploration:
            let plan = ExplorationStrategy.recommend(
                taskKind: taskKind,
                prompt: prompt,
                workspaceSnapshot: workspaceSnapshot
            )
            let planningBrief = workspaceSnapshot
                .flatMap { snapshot in
                    let workspaceRootURL = URL(fileURLWithPath: snapshot.workspaceRootPath, isDirectory: true)
                    return ContextPlanningService().makeBrief(task: prompt, workspaceRootURL: workspaceRootURL)
                }
                .map { $0.formatted }
            return """
            Recommended exploration sequence:
            \(plan.formatted)
            \(planningBrief.map { "\n\nRepo-aware context brief:\n\($0)" } ?? "")
            """
        case .planning:
            guard let workspaceSnapshot else { return "" }
            let workspaceRootURL = URL(fileURLWithPath: workspaceSnapshot.workspaceRootPath, isDirectory: true)
            let planningBrief = ContextPlanningService().makeBrief(task: prompt, workspaceRootURL: workspaceRootURL)
            return """
            Repo-aware planning brief:
            \(planningBrief.formatted)
            """
        case .validation:
            return """
            Suggested validation focus:
            \(validationSuggestions(for: prompt, taskKind: taskKind, phase: phase).joined(separator: "\n"))
            """
        case .mutation:
            return ""
        }
    }

    private static func explorationSuggestion(for taskKind: TaskKind) -> String {
        switch taskKind {
        case .bugFix:
            return "prefer search_text, find_files, git diff/status, and focused reads around the failing area"
        case .feature:
            return "prefer find_files, search_text, list_directory, and read_text_file to locate the implementation surface"
        case .refactor:
            return "prefer search_text, file_info, and focused reads to understand dependencies before changing structure"
        case .docs:
            return "prefer read_text_file and find_files for README, docs, changelog, and instruction files"
        case .git:
            return "prefer git status, diff, log, and show_commit before taking repo actions"
        case .shell:
            return "prefer list_directory, file_info, and minimal shell inspection before mutating commands"
        case .analysis, .general:
            return "prefer find_files, search_text, read_text_file, and read-only git inspection before mutation"
        }
    }

    private static func validationHeadline(for taskKind: TaskKind) -> String {
        switch taskKind {
        case .bugFix:
            return "confirm the fix with targeted reads, diffs, and the most relevant test or repro check"
        case .feature:
            return "confirm the changed files, expected behavior, and relevant build or test checks"
        case .refactor:
            return "confirm behavior preservation with diffs, targeted reads, and available checks"
        case .docs:
            return "confirm wording and file diffs match the requested documentation update"
        case .git:
            return "confirm repository state, branch, and diffs match the intended result"
        case .shell:
            return "confirm command outputs, exit codes, and resulting artifacts match the goal"
        case .analysis, .general:
            return "confirm changed files match intent before concluding"
        }
    }

    private static func mergeChangedArtifacts(_ lhs: [ChangedArtifact], _ rhs: [ChangedArtifact]) -> [ChangedArtifact] {
        var seen: Set<String> = []
        return (lhs + rhs).filter { seen.insert($0.path + "|" + $0.reason).inserted }
    }
}

private struct StepWorkflowState {
    private let targetArtifacts: [String]
    private(set) var inspectedArtifacts: Set<String> = []
    private(set) var validationArtifacts: Set<String> = []
    private(set) var recentFindings: [String] = []
    private(set) var validationNotes: [String] = []

    init(targetArtifacts: [String] = []) {
        self.targetArtifacts = targetArtifacts
    }

    var hasPriorInspection: Bool {
        !inspectedArtifacts.isEmpty
    }

    var explorationTargets: [String] {
        targetArtifacts
    }

    var pendingExplorationTargets: [String] {
        targetArtifacts.filter { target in
            !inspectedArtifacts.contains { inspected in
                let normalizedTarget = normalizePath(target)
                let normalizedInspected = normalizePath(inspected)
                guard !normalizedTarget.isEmpty, !normalizedInspected.isEmpty else { return false }
                return normalizedInspected == normalizedTarget
                    || normalizedInspected.hasPrefix(normalizedTarget + "/")
                    || normalizedTarget.hasPrefix(normalizedInspected + "/")
            }
        }
    }

    func hasValidationEvidence(for changedPaths: [String]) -> Bool {
        guard !validationArtifacts.isEmpty else { return false }
        if validationArtifacts.contains("<git>") || validationArtifacts.contains("<check>") {
            return true
        }

        let normalizedChangedPaths = Set(changedPaths.map(normalizePath))
        let normalizedValidatedPaths = Set(validationArtifacts.map(normalizePath))
        return !normalizedChangedPaths.isDisjoint(with: normalizedValidatedPaths)
    }

    mutating func record(metadata: ToolExecutionMetadata) {
        inspectedArtifacts.formUnion(metadata.inspectedPaths)
        validationArtifacts.formUnion(metadata.validationArtifacts)
        if !metadata.summary.isEmpty {
            recentFindings.append(metadata.summary)
            if recentFindings.count > 6 {
                recentFindings.removeFirst(recentFindings.count - 6)
            }
        }
        if !metadata.validationArtifacts.isEmpty {
            validationNotes.append(metadata.summary.isEmpty ? "Validation evidence recorded." : metadata.summary)
            if validationNotes.count > 6 {
                validationNotes.removeFirst(validationNotes.count - 6)
            }
        }
    }

    private func normalizePath(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct StepExecutionOutcome {
    let summary: String
    let changedFiles: [ChangedArtifact]
    let validationNotes: [String]
    let remainingItems: [String]
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
