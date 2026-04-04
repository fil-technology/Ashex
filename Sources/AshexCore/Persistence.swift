import Foundation

public protocol PersistenceStore: Sendable {
    func initialize() throws
    func normalizeInterruptedRuns(now: Date) throws
    func createThread(now: Date) throws -> ThreadRecord
    func createRun(threadID: UUID, state: RunState, now: Date) throws -> RunRecord
    func transitionRun(runID: UUID, to state: RunState, reason: String?, now: Date) throws
    func appendMessage(threadID: UUID, runID: UUID?, role: MessageRole, content: String, now: Date) throws -> MessageRecord
    func fetchMessages(threadID: UUID) throws -> [MessageRecord]
    func recordToolCall(runID: UUID, toolName: String, arguments: JSONObject, now: Date) throws -> ToolCallRecord
    func finishToolCall(toolCallID: UUID, status: String, output: String, finishedAt: Date) throws
    func appendEvent(_ event: RuntimeEvent, runID: UUID?) throws
    func fetchRun(runID: UUID) throws -> RunRecord?
}
