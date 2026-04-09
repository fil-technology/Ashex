import Foundation

public enum OutputStreamKind: String, Codable, Sendable {
    case stdout
    case stderr
    case log
}

public enum RuntimeEventPayload: Codable, Sendable {
    case runStarted(threadID: UUID, runID: UUID)
    case runStateChanged(runID: UUID, state: RunState, reason: String?)
    case workflowPhaseChanged(runID: UUID, phase: String, title: String)
    case contextPrepared(runID: UUID, retainedMessages: Int, droppedMessages: Int, clippedMessages: Int, estimatedTokens: Int, estimatedContextWindow: Int)
    case contextCompacted(runID: UUID, droppedMessages: Int, summary: String)
    case taskPlanCreated(runID: UUID, steps: [String])
    case taskStepStarted(runID: UUID, index: Int, total: Int, title: String)
    case taskStepFinished(runID: UUID, index: Int, total: Int, title: String, outcome: String)
    case subagentAssigned(runID: UUID, title: String, role: String, goal: String)
    case subagentStarted(runID: UUID, title: String, maxIterations: Int)
    case subagentHandoff(runID: UUID, title: String, role: String, summary: String, remainingItems: [String])
    case subagentFinished(runID: UUID, title: String, summary: String)
    case changedFilesTracked(runID: UUID, paths: [String])
    case patchPlanUpdated(runID: UUID, paths: [String], objectives: [String])
    case status(runID: UUID, message: String)
    case messageAppended(runID: UUID, messageID: UUID, role: MessageRole)
    case approvalRequested(runID: UUID, toolName: String, summary: String, reason: String, risk: ApprovalRisk)
    case approvalResolved(runID: UUID, toolName: String, allowed: Bool, reason: String)
    case toolCallStarted(runID: UUID, toolCallID: UUID, toolName: String, arguments: JSONObject)
    case toolOutput(runID: UUID, toolCallID: UUID, stream: OutputStreamKind, chunk: String)
    case toolCallFinished(runID: UUID, toolCallID: UUID, success: Bool, summary: String)
    case finalAnswer(runID: UUID, messageID: UUID, text: String)
    case error(runID: UUID?, message: String)
    case runFinished(runID: UUID, state: RunState)
}

public struct RuntimeEvent: Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let payload: RuntimeEventPayload

    public init(id: UUID = UUID(), timestamp: Date = Date(), payload: RuntimeEventPayload) {
        self.id = id
        self.timestamp = timestamp
        self.payload = payload
    }
}

public typealias RuntimeEventHandler = @Sendable (RuntimeEvent) -> Void
