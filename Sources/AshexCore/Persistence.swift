import Foundation

public protocol PersistenceStore: Sendable {
    func initialize() throws
    func normalizeInterruptedRuns(now: Date) throws
    func createThread(now: Date) throws -> ThreadRecord
    func createRun(threadID: UUID, state: RunState, now: Date) throws -> RunRecord
    func transitionRun(runID: UUID, to state: RunState, reason: String?, now: Date) throws
    func createRunSteps(runID: UUID, steps: [String], now: Date) throws -> [RunStepRecord]
    func transitionRunStep(stepID: UUID, to state: RunStepState, summary: String?, now: Date) throws
    func fetchRunSteps(runID: UUID) throws -> [RunStepRecord]
    func recordWorkspaceSnapshot(runID: UUID, workspaceRootPath: String, topLevelEntries: [String], instructionFiles: [String], projectMarkers: [String], sourceRoots: [String], testRoots: [String], gitBranch: String?, gitStatusSummary: String?, now: Date) throws -> WorkspaceSnapshotRecord
    func fetchWorkspaceSnapshot(runID: UUID) throws -> WorkspaceSnapshotRecord?
    func upsertWorkingMemory(runID: UUID, currentTask: String, currentPhase: String?, explorationTargets: [String], pendingExplorationTargets: [String], inspectedPaths: [String], changedPaths: [String], recentFindings: [String], completedStepSummaries: [String], unresolvedItems: [String], validationSuggestions: [String], plannedChangeSet: [String], patchObjectives: [String], carryForwardNotes: [String], summary: String, now: Date) throws -> WorkingMemoryRecord
    func fetchWorkingMemory(runID: UUID) throws -> WorkingMemoryRecord?
    func recordContextCompaction(runID: UUID, droppedMessageCount: Int, retainedMessageCount: Int, estimatedTokenCount: Int, estimatedContextWindow: Int, summary: String, now: Date) throws -> ContextCompactionRecord
    func fetchContextCompactions(runID: UUID) throws -> [ContextCompactionRecord]
    func appendMessage(threadID: UUID, runID: UUID?, role: MessageRole, content: String, now: Date) throws -> MessageRecord
    func fetchMessages(threadID: UUID) throws -> [MessageRecord]
    func recordToolCall(runID: UUID, toolName: String, arguments: JSONObject, now: Date) throws -> ToolCallRecord
    func finishToolCall(toolCallID: UUID, status: String, output: String, finishedAt: Date) throws
    func appendEvent(_ event: RuntimeEvent, runID: UUID?) throws
    func listThreads(limit: Int) throws -> [ThreadSummary]
    func fetchRuns(threadID: UUID) throws -> [RunRecord]
    func fetchEvents(runID: UUID) throws -> [RuntimeEvent]
    func upsertSetting(namespace: String, key: String, value: JSONValue, now: Date) throws
    func fetchSetting(namespace: String, key: String) throws -> PersistedSetting?
    func listSettings(namespace: String) throws -> [PersistedSetting]
    func fetchRun(runID: UUID) throws -> RunRecord?
}
