import Foundation

public struct RunRequest: Sendable {
    public let prompt: String
    public let maxIterations: Int

    public init(prompt: String, maxIterations: Int = 8) {
        self.prompt = prompt
        self.maxIterations = maxIterations
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

    public init(
        modelAdapter: any ModelAdapter,
        toolRegistry: ToolRegistry,
        persistence: PersistenceStore,
        approvalPolicy: any ApprovalPolicy = TrustedApprovalPolicy(),
        clock: @escaping @Sendable () -> Date = Date.init
    ) throws {
        self.modelAdapter = modelAdapter
        self.toolRegistry = toolRegistry
        self.persistence = persistence
        self.approvalPolicy = approvalPolicy
        self.clock = clock
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

            let userMessage = try persistence.appendMessage(threadID: thread.id, runID: run.id, role: .user, content: request.prompt, now: clock())
            try emitter.emit(.messageAppended(runID: run.id, messageID: userMessage.id, role: .user), runID: run.id)

            for iteration in 0..<request.maxIterations {
                try await cancellation.checkCancellation()
                try emitter.emit(.status(runID: run.id, message: "Iteration \(iteration + 1): requesting next model action"), runID: run.id)

                let messages = try persistence.fetchMessages(threadID: thread.id)
                let refreshedRun = try persistence.fetchRun(runID: run.id) ?? run
                let action = try await modelAdapter.nextAction(for: .init(
                    thread: thread,
                    run: refreshedRun,
                    messages: messages,
                    availableTools: toolRegistry.schema()
                ))

                switch action {
                case .finalAnswer(let answer):
                    let assistantMessage = try persistence.appendMessage(threadID: thread.id, runID: run.id, role: .assistant, content: answer, now: clock())
                    try emitter.emit(.messageAppended(runID: run.id, messageID: assistantMessage.id, role: .assistant), runID: run.id)
                    try emitter.emit(.finalAnswer(runID: run.id, messageID: assistantMessage.id, text: answer), runID: run.id)
                    try persistence.transitionRun(runID: run.id, to: .completed, reason: nil, now: clock())
                    try emitter.emit(.runStateChanged(runID: run.id, state: .completed, reason: nil), runID: run.id)
                    try emitter.emit(.runFinished(runID: run.id, state: .completed), runID: run.id)
                    return

                case .toolCall(let call):
                    let tool = try toolRegistry.tool(named: call.toolName)
                    let toolCall = try persistence.recordToolCall(runID: run.id, toolName: tool.name, arguments: call.arguments, now: clock())

                    if let approvalRequest = ApprovalClassifier.requestForTool(runID: run.id, toolName: tool.name, arguments: call.arguments),
                       approvalPolicy.mode == .guarded {
                        try emitter.emit(.approvalRequested(
                            runID: run.id,
                            toolName: tool.name,
                            summary: approvalRequest.summary,
                            reason: approvalRequest.reason,
                            risk: approvalRequest.risk
                        ), runID: run.id)

                        let decision = await approvalPolicy.evaluate(approvalRequest)
                        try emitter.emit(.approvalResolved(
                            runID: run.id,
                            toolName: tool.name,
                            allowed: decision.allowed,
                            reason: decision.reason
                        ), runID: run.id)

                        guard decision.allowed else {
                            try persistence.finishToolCall(toolCallID: toolCall.id, status: "denied", output: decision.reason, finishedAt: clock())
                            let toolMessage = try persistence.appendMessage(threadID: thread.id, runID: run.id, role: .tool, content: "Tool denied: \(decision.reason)", now: clock())
                            try emitter.emit(.messageAppended(runID: run.id, messageID: toolMessage.id, role: .tool), runID: run.id)
                            throw AshexError.approvalDenied("Execution denied for \(tool.name): \(decision.reason)")
                        }
                    }

                    try emitter.emit(.toolCallStarted(runID: run.id, toolCallID: toolCall.id, toolName: tool.name, arguments: call.arguments), runID: run.id)

                    let toolContext = ToolContext(
                        runID: run.id,
                        emit: { event in
                            var payload = event.payload
                            if case .toolOutput(_, _, let stream, let chunk) = payload {
                                payload = .toolOutput(runID: run.id, toolCallID: toolCall.id, stream: stream, chunk: chunk)
                            }
                            try? emitter.emit(payload, runID: run.id)
                        },
                        cancellation: cancellation
                    )

                    do {
                        let result = try await tool.execute(arguments: call.arguments, context: toolContext)
                        let text = result.displayText
                        let toolMessage = try persistence.appendMessage(threadID: thread.id, runID: run.id, role: .tool, content: text, now: clock())
                        try emitter.emit(.messageAppended(runID: run.id, messageID: toolMessage.id, role: .tool), runID: run.id)
                        try persistence.finishToolCall(toolCallID: toolCall.id, status: "completed", output: text, finishedAt: clock())
                        try emitter.emit(.toolCallFinished(runID: run.id, toolCallID: toolCall.id, success: true, summary: summarizeToolResult(text)), runID: run.id)
                    } catch {
                        let message = error.localizedDescription
                        let toolMessage = try persistence.appendMessage(threadID: thread.id, runID: run.id, role: .tool, content: "Tool error: \(message)", now: clock())
                        try emitter.emit(.messageAppended(runID: run.id, messageID: toolMessage.id, role: .tool), runID: run.id)
                        try persistence.finishToolCall(toolCallID: toolCall.id, status: "failed", output: message, finishedAt: clock())
                        try emitter.emit(.toolCallFinished(runID: run.id, toolCallID: toolCall.id, success: false, summary: message), runID: run.id)
                        throw error
                    }
                }
            }

            throw AshexError.maxIterationsReached(request.maxIterations)
        } catch {
            await finalizeFailure(error: error, emitter: emitter)
        }
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

    private func summarizeToolResult(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 160 {
            return trimmed
        }
        return String(trimmed.prefix(157)) + "..."
    }
}

private final class EventEmitter: @unchecked Sendable {
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
