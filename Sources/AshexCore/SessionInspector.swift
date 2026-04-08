import Foundation

public struct SessionRunSnapshot: Sendable {
    public let run: RunRecord
    public let steps: [RunStepRecord]
    public let compactions: [ContextCompactionRecord]
    public let workspaceSnapshot: WorkspaceSnapshotRecord?
    public let workingMemory: WorkingMemoryRecord?
    public let events: [RuntimeEvent]
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
}
