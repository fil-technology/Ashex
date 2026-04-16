import Foundation

public struct ActiveConversationRunStatus: Sendable, Equatable {
    public let threadID: UUID
    public let runID: UUID?
    public let startedAt: Date
    public let prompt: String
    public let awaitingApproval: Bool
}

public struct ActiveConversationRunSnapshot: Sendable, Equatable {
    public let conversation: ConnectorConversationReference
    public let status: ActiveConversationRunStatus
}

public actor DaemonConversationRunStore {
    private struct ActiveConversationRun {
        let threadID: UUID
        let startedAt: Date
        let prompt: String
        let cancellationToken: CancellationToken
        var runID: UUID?
        var awaitingApproval = false
    }

    private var activeRuns: [ConnectorConversationReference: ActiveConversationRun] = [:]
    private var conversationByRunID: [UUID: ConnectorConversationReference] = [:]

    public init() {}

    @discardableResult
    public func beginRun(
        for conversation: ConnectorConversationReference,
        threadID: UUID,
        prompt: String,
        cancellationToken: CancellationToken,
        now: Date = Date()
    ) -> Bool {
        guard activeRuns[conversation] == nil else { return false }
        activeRuns[conversation] = ActiveConversationRun(
            threadID: threadID,
            startedAt: now,
            prompt: prompt,
            cancellationToken: cancellationToken
        )
        return true
    }

    public func bind(runID: UUID, to conversation: ConnectorConversationReference) {
        guard var active = activeRuns[conversation] else { return }
        active.runID = runID
        activeRuns[conversation] = active
        conversationByRunID[runID] = conversation
    }

    public func conversation(for runID: UUID) -> ConnectorConversationReference? {
        conversationByRunID[runID]
    }

    public func setAwaitingApproval(_ awaitingApproval: Bool, for runID: UUID) {
        guard let conversation = conversationByRunID[runID],
              var active = activeRuns[conversation] else {
            return
        }
        active.awaitingApproval = awaitingApproval
        activeRuns[conversation] = active
    }

    public func status(for conversation: ConnectorConversationReference) -> ActiveConversationRunStatus? {
        guard let active = activeRuns[conversation] else { return nil }
        return ActiveConversationRunStatus(
            threadID: active.threadID,
            runID: active.runID,
            startedAt: active.startedAt,
            prompt: active.prompt,
            awaitingApproval: active.awaitingApproval
        )
    }

    @discardableResult
    public func cancelRun(for conversation: ConnectorConversationReference) async -> Bool {
        guard let active = activeRuns[conversation] else { return false }
        await active.cancellationToken.cancel()
        return true
    }

    public func clearRun(for conversation: ConnectorConversationReference) {
        guard let active = activeRuns.removeValue(forKey: conversation) else { return }
        if let runID = active.runID {
            conversationByRunID.removeValue(forKey: runID)
        }
    }

    public func hasActiveRuns() -> Bool {
        !activeRuns.isEmpty
    }

    public func listActiveRuns() -> [ActiveConversationRunSnapshot] {
        activeRuns.map { conversation, active in
            ActiveConversationRunSnapshot(
                conversation: conversation,
                status: ActiveConversationRunStatus(
                    threadID: active.threadID,
                    runID: active.runID,
                    startedAt: active.startedAt,
                    prompt: active.prompt,
                    awaitingApproval: active.awaitingApproval
                )
            )
        }
        .sorted { $0.status.startedAt < $1.status.startedAt }
    }
}
