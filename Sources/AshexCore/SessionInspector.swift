import Foundation

public struct SessionRunSnapshot: Sendable {
    public let run: RunRecord
    public let steps: [RunStepRecord]
    public let compactions: [ContextCompactionRecord]
    public let workspaceSnapshot: WorkspaceSnapshotRecord?
    public let workingMemory: WorkingMemoryRecord?
    public let events: [RuntimeEvent]
}

public struct TokenSavingsSummary: Sendable, Equatable {
    public let compactionCount: Int
    public let savedTokenCount: Int

    public init(compactionCount: Int, savedTokenCount: Int) {
        self.compactionCount = compactionCount
        self.savedTokenCount = savedTokenCount
    }
}

public struct TokenSavingsSnapshot: Sendable, Equatable {
    public let currentRun: TokenSavingsSummary
    public let today: TokenSavingsSummary
    public let session: TokenSavingsSummary
    public let total: TokenSavingsSummary

    public init(
        currentRun: TokenSavingsSummary,
        today: TokenSavingsSummary,
        session: TokenSavingsSummary,
        total: TokenSavingsSummary
    ) {
        self.currentRun = currentRun
        self.today = today
        self.session = session
        self.total = total
    }
}

public struct TokenUsageSummary: Sendable, Equatable {
    public let runCount: Int
    public let usedTokenCount: Int

    public init(runCount: Int, usedTokenCount: Int) {
        self.runCount = runCount
        self.usedTokenCount = usedTokenCount
    }
}

public struct TokenUsageSnapshot: Sendable, Equatable {
    public let currentRun: TokenUsageSummary
    public let today: TokenUsageSummary
    public let session: TokenUsageSummary
    public let total: TokenUsageSummary

    public init(
        currentRun: TokenUsageSummary,
        today: TokenUsageSummary,
        session: TokenUsageSummary,
        total: TokenUsageSummary
    ) {
        self.currentRun = currentRun
        self.today = today
        self.session = session
        self.total = total
    }
}

public struct SessionInspector: Sendable {
    private let persistence: PersistenceStore

    public init(persistence: PersistenceStore) {
        self.persistence = persistence
    }

    public func loadRunSnapshot(runID: UUID, recentEventLimit: Int? = nil) throws -> SessionRunSnapshot? {
        guard let run = try persistence.fetchRun(runID: runID) else {
            return nil
        }

        let events = try persistence.fetchEvents(runID: runID)
        let slicedEvents: [RuntimeEvent]
        if let recentEventLimit, recentEventLimit > 0 {
            slicedEvents = Array(events.suffix(recentEventLimit))
        } else {
            slicedEvents = events
        }

        return SessionRunSnapshot(
            run: run,
            steps: try persistence.fetchRunSteps(runID: runID),
            compactions: try persistence.fetchContextCompactions(runID: runID),
            workspaceSnapshot: try persistence.fetchWorkspaceSnapshot(runID: runID),
            workingMemory: try persistence.fetchWorkingMemory(runID: runID),
            events: slicedEvents
        )
    }

    public func loadTokenSavings(runID: UUID, now: Date = Date(), calendar: Calendar = .current) throws -> TokenSavingsSnapshot? {
        guard let run = try persistence.fetchRun(runID: runID) else {
            return nil
        }

        let currentRunCompactions = try persistence.fetchContextCompactions(runID: runID)
        let sessionRuns = try persistence.fetchRuns(threadID: run.threadID)
        let allRuns = try persistence.listThreads(limit: 1_000).flatMap { thread in
            (try? persistence.fetchRuns(threadID: thread.id)) ?? []
        }
        let allCompactions = allRuns.flatMap { run in
            (try? persistence.fetchContextCompactions(runID: run.id)) ?? []
        }
        let sessionCompactions = sessionRuns.flatMap { run in
            (try? persistence.fetchContextCompactions(runID: run.id)) ?? []
        }

        let todayStart = calendar.startOfDay(for: now)
        return TokenSavingsSnapshot(
            currentRun: summarize(compactions: currentRunCompactions),
            today: summarize(compactions: allCompactions.filter { $0.createdAt >= todayStart }),
            session: summarize(compactions: sessionCompactions),
            total: summarize(compactions: allCompactions)
        )
    }

    public func loadTokenUsage(runID: UUID, now: Date = Date(), calendar: Calendar = .current) throws -> TokenUsageSnapshot? {
        guard let run = try persistence.fetchRun(runID: runID) else {
            return nil
        }

        let sessionRuns = try persistence.fetchRuns(threadID: run.threadID)
        let allRuns = try persistence.listThreads(limit: 1_000).flatMap { thread in
            (try? persistence.fetchRuns(threadID: thread.id)) ?? []
        }

        let todayStart = calendar.startOfDay(for: now)
        return TokenUsageSnapshot(
            currentRun: usageSummary(for: [run]),
            today: usageSummary(for: allRuns.filter { $0.updatedAt >= todayStart }),
            session: usageSummary(for: sessionRuns),
            total: usageSummary(for: allRuns)
        )
    }

    private func summarize(compactions: [ContextCompactionRecord]) -> TokenSavingsSummary {
        TokenSavingsSummary(
            compactionCount: compactions.count,
            savedTokenCount: compactions.reduce(0) { $0 + $1.estimatedSavedTokenCount }
        )
    }

    private func usageSummary(for runs: [RunRecord]) -> TokenUsageSummary {
        let usedTokens = runs.reduce(into: 0) { partial, run in
            partial += (try? estimatedUsageTokens(for: run.id)) ?? 0
        }
        return TokenUsageSummary(runCount: runs.count, usedTokenCount: usedTokens)
    }

    private func estimatedUsageTokens(for runID: UUID) throws -> Int {
        try persistence.fetchEvents(runID: runID).reduce(into: 0) { partial, event in
            if case .contextPrepared(_, _, _, _, let estimatedTokens, _) = event.payload {
                partial = max(partial, estimatedTokens)
            }
        }
    }
}
