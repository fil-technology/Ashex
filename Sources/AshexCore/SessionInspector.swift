import Foundation

public struct SessionRunSnapshot: Sendable {
    public let run: RunRecord
    public let steps: [RunStepRecord]
    public let compactions: [ContextCompactionRecord]
    public let workspaceSnapshot: WorkspaceSnapshotRecord?
    public let workingMemory: WorkingMemoryRecord?
    public let events: [RuntimeEvent]
}

public struct RunInspectionSummary: Sendable, Equatable {
    public let runID: UUID
    public let threadID: UUID
    public let state: RunState
    public let updatedAt: Date
    public let task: String?
    public let stepSummaries: [String]
    public let changedFiles: [String]
    public let pendingFiles: [String]
    public let validationConfidence: String
    public let validationNotes: [String]
    public let remainingItems: [String]
    public let subagentAudit: [String]

    public init(
        runID: UUID,
        threadID: UUID,
        state: RunState,
        updatedAt: Date,
        task: String?,
        stepSummaries: [String],
        changedFiles: [String],
        pendingFiles: [String],
        validationConfidence: String,
        validationNotes: [String],
        remainingItems: [String],
        subagentAudit: [String]
    ) {
        self.runID = runID
        self.threadID = threadID
        self.state = state
        self.updatedAt = updatedAt
        self.task = task
        self.stepSummaries = stepSummaries
        self.changedFiles = changedFiles
        self.pendingFiles = pendingFiles
        self.validationConfidence = validationConfidence
        self.validationNotes = validationNotes
        self.remainingItems = remainingItems
        self.subagentAudit = subagentAudit
    }
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

    public func loadLatestRunSnapshot(recentEventLimit: Int? = nil) throws -> SessionRunSnapshot? {
        guard let latestRunID = try persistence.listThreads(limit: 1_000).compactMap(\.latestRunID).first else {
            return nil
        }
        return try loadRunSnapshot(runID: latestRunID, recentEventLimit: recentEventLimit)
    }

    public func summarizeLatestRun(recentEventLimit: Int? = nil) throws -> RunInspectionSummary? {
        guard let snapshot = try loadLatestRunSnapshot(recentEventLimit: recentEventLimit) else {
            return nil
        }
        return summarize(snapshot: snapshot)
    }

    public func summarize(snapshot: SessionRunSnapshot) -> RunInspectionSummary {
        let memory = snapshot.workingMemory
        let changedFromEvents = snapshot.events.flatMap { event -> [String] in
            if case .changedFilesTracked(_, let paths) = event.payload {
                return paths
            }
            return []
        }
        let changedFiles = orderedUnique((memory?.changedPaths ?? []) + changedFromEvents)
        let plannedFiles = orderedUnique((memory?.plannedChangeSet ?? []) + patchPlanPaths(from: snapshot.events))
        let pendingFiles = plannedFiles.filter { !changedFiles.contains($0) }
        let validationNotes = orderedUnique(validationNotes(from: snapshot, changedFiles: changedFiles))
        let remainingItems = orderedUnique((memory?.unresolvedItems ?? []) + remainingItems(from: snapshot.events))

        return RunInspectionSummary(
            runID: snapshot.run.id,
            threadID: snapshot.run.threadID,
            state: snapshot.run.state,
            updatedAt: snapshot.run.updatedAt,
            task: memory?.currentTask,
            stepSummaries: snapshot.steps.map { step in
                "\(step.index). \(step.title) - \(step.state.rawValue)\(step.summary.map { ": \($0)" } ?? "")"
            },
            changedFiles: changedFiles,
            pendingFiles: pendingFiles,
            validationConfidence: validationConfidence(
                runState: snapshot.run.state,
                changedFiles: changedFiles,
                validationNotes: validationNotes,
                remainingItems: remainingItems
            ),
            validationNotes: validationNotes,
            remainingItems: remainingItems,
            subagentAudit: subagentAudit(from: snapshot.events)
        )
    }

    public static func format(summary: RunInspectionSummary) -> String {
        var lines = [
            "Last run",
            "Run: \(summary.runID.uuidString)",
            "Thread: \(summary.threadID.uuidString)",
            "State: \(summary.state.rawValue)",
        ]
        if let task = summary.task, !task.isEmpty {
            lines.append("Task: \(task)")
        }
        lines.append("Validation confidence: \(summary.validationConfidence)")

        if !summary.stepSummaries.isEmpty {
            lines.append("")
            lines.append("Steps:")
            lines.append(contentsOf: summary.stepSummaries.prefix(8).map { "- \($0)" })
        }

        if !summary.changedFiles.isEmpty || !summary.pendingFiles.isEmpty {
            lines.append("")
            lines.append("Patch status:")
            lines.append(contentsOf: summary.changedFiles.prefix(12).map { "- done: \($0)" })
            lines.append(contentsOf: summary.pendingFiles.prefix(12).map { "- pending: \($0)" })
        }

        if !summary.validationNotes.isEmpty {
            lines.append("")
            lines.append("Validation:")
            lines.append(contentsOf: summary.validationNotes.prefix(8).map { "- \($0)" })
        }

        if !summary.remainingItems.isEmpty {
            lines.append("")
            lines.append("Remaining:")
            lines.append(contentsOf: summary.remainingItems.prefix(8).map { "- \($0)" })
        }

        if !summary.subagentAudit.isEmpty {
            lines.append("")
            lines.append("Subagents:")
            lines.append(contentsOf: summary.subagentAudit.prefix(8).map { "- \($0)" })
        }

        return lines.joined(separator: "\n")
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

    private func patchPlanPaths(from events: [RuntimeEvent]) -> [String] {
        events.flatMap { event -> [String] in
            if case .patchPlanUpdated(_, let paths, _) = event.payload {
                return paths
            }
            return []
        }
    }

    private func validationNotes(from snapshot: SessionRunSnapshot, changedFiles: [String]) -> [String] {
        var notes = snapshot.workingMemory?.validationSuggestions ?? []
        for event in snapshot.events {
            switch event.payload {
            case .toolCallFinished(_, _, let success, let summary):
                let lowered = summary.lowercased()
                if success,
                   lowered.contains("validat") || lowered.contains("test") || lowered.contains("build") || lowered.contains("git") {
                    notes.append(summary)
                }
            case .status(_, let message):
                if message.localizedCaseInsensitiveContains("Automatic validation") ||
                    message.localizedCaseInsensitiveContains("validation gate") {
                    notes.append(message)
                }
            default:
                continue
            }
        }
        if changedFiles.isEmpty {
            notes.append("No changed files were tracked for this run.")
        }
        return notes
    }

    private func validationConfidence(
        runState: RunState,
        changedFiles: [String],
        validationNotes: [String],
        remainingItems: [String]
    ) -> String {
        guard runState == .completed else {
            return "incomplete"
        }
        guard !changedFiles.isEmpty else {
            return "not applicable"
        }
        if validationNotes.contains(where: { note in
            let lowered = note.lowercased()
            return lowered.contains("failed") || lowered.contains("blocked") || lowered.contains("incomplete")
        }) {
            return "needs attention"
        }
        let passedValidation = validationNotes.contains { note in
            let lowered = note.lowercased()
            return lowered.contains("validation passed")
                || lowered.contains("validated with")
                || lowered.contains("validation completed")
                || lowered.contains("validated")
                || lowered.contains("build succeeded")
                || lowered.contains("tests passed")
        }
        let attemptedValidation = validationNotes.contains { note in
            let lowered = note.lowercased()
            return lowered.contains("validation attempted")
                || lowered.contains("automatic validation")
                || lowered.contains("captured validation output")
                || lowered.contains("git diff")
                || lowered.contains("read-back")
        }
        if passedValidation && remainingItems.isEmpty {
            return "verified"
        }
        if passedValidation || attemptedValidation || !validationNotes.isEmpty {
            return "partially verified"
        }
        return "unverified"
    }

    private func remainingItems(from events: [RuntimeEvent]) -> [String] {
        events.flatMap { event -> [String] in
            if case .subagentHandoff(_, _, _, _, let remainingItems) = event.payload {
                return remainingItems
            }
            return []
        }
    }

    private func subagentAudit(from events: [RuntimeEvent]) -> [String] {
        events.compactMap { event -> String? in
            switch event.payload {
            case .subagentAssigned(_, let title, let role, _):
                return "assigned \(role): \(title)"
            case .subagentHandoff(_, let title, let role, let summary, _):
                return "handoff \(role): \(title) - \(summary)"
            case .subagentFinished(_, let title, let summary):
                return "finished: \(title) - \(summary)"
            default:
                return nil
            }
        }
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return false }
            return seen.insert(normalized).inserted
        }
    }
}
