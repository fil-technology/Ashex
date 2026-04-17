import Foundation

public struct RunDispatchResult: Sendable, Equatable {
    public let runID: UUID?
    public let finalText: String

    public init(runID: UUID?, finalText: String) {
        self.runID = runID
        self.finalText = finalText
    }
}

public actor RunDispatcher {
    private var runtime: RuntimeStreaming
    private let logger: DaemonLogger?

    public init(runtime: RuntimeStreaming, logger: DaemonLogger? = nil) {
        self.runtime = runtime
        self.logger = logger
    }

    public func replaceRuntime(_ runtime: RuntimeStreaming) {
        self.runtime = runtime
    }

    public func dispatch(prompt: String, threadID: UUID, maxIterations: Int, attachments: [InputAttachment] = []) async throws -> RunDispatchResult {
        try await dispatch(prompt: prompt, threadID: threadID, maxIterations: maxIterations, mode: .agent, attachments: attachments)
    }

    public func dispatch(
        prompt: String,
        threadID: UUID,
        maxIterations: Int,
        mode: RunRequest.Mode,
        attachments: [InputAttachment] = [],
        cancellationToken: CancellationToken? = nil,
        onEvent: (@Sendable (RuntimeEvent) async -> Void)? = nil
    ) async throws -> RunDispatchResult {
        var finalAnswer: String?
        var runID: UUID?
        var latestError: String?

        for await event in runtime.run(.init(
            prompt: prompt,
            maxIterations: maxIterations,
            threadID: threadID,
            mode: mode,
            attachments: attachments,
            cancellationToken: cancellationToken
        )) {
            if let onEvent {
                await onEvent(event)
            }
            switch event.payload {
            case .runStarted(_, let startedRunID):
                runID = startedRunID
                await logger?.log(.info, subsystem: "dispatcher", message: "Run started", metadata: [
                    "thread_id": .string(threadID.uuidString),
                    "run_id": .string(startedRunID.uuidString),
                ])
            case .finalAnswer(let completedRunID, _, let text):
                runID = completedRunID
                finalAnswer = text
            case .error(_, let message):
                latestError = message
            default:
                continue
            }
        }

        if let finalAnswer {
            return RunDispatchResult(runID: runID, finalText: finalAnswer)
        }

        throw AshexError.model(latestError ?? "Run finished without a final answer")
    }
}
