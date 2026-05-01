import AshexCore
import Foundation
import Testing

@Test func heartbeatWritesStatusAndDetectsStaleRunningTasksDeterministically() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let queue = AgentTaskQueue(storageRoot: root)
    _ = try queue.new(prompt: "first", id: "b-task")
    _ = try queue.new(prompt: "second", id: "a-task")
    try queue.markRunning(id: "b-task")
    try queue.markRunning(id: "a-task")

    let heartbeat = AgentHeartbeatStore(
        storageRoot: root,
        config: AgentHeartbeatConfig(staleAfter: 30)
    )
    let oldDate = Date(timeIntervalSince1970: 100)
    let freshDate = Date(timeIntervalSince1970: 125)
    try heartbeat.write(.init(taskID: "b-task", state: .running, updatedAt: oldDate, detail: "still working"))
    try heartbeat.write(.init(taskID: "a-task", state: .running, updatedAt: freshDate, detail: "busy"))

    let actions = try heartbeat.actions(for: queue.list(), now: Date(timeIntervalSince1970: 140))

    #expect(actions == [
        .markTaskStale(taskID: "b-task", lastHeartbeatAt: oldDate, staleAfter: 30),
    ])
    #expect(try heartbeat.status(taskID: "b-task")?.detail == "still working")
}

@Test func heartbeatTreatsMissingRunningHeartbeatAsStale() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let queue = AgentTaskQueue(storageRoot: root)
    _ = try queue.new(prompt: "lost worker", id: "lost-task")
    try queue.markRunning(id: "lost-task")

    let heartbeat = AgentHeartbeatStore(storageRoot: root)

    #expect(try heartbeat.actions(for: queue.list(), now: Date(timeIntervalSince1970: 500)) == [
        .markTaskStale(taskID: "lost-task", lastHeartbeatAt: nil, staleAfter: 120),
    ])
}

@Test func heartbeatCanRequeueStaleRunningTasksForRetry() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let clock = ManualClock(Date(timeIntervalSince1970: 3_000))
    let queue = AgentTaskQueue(storageRoot: root, now: clock.callAsFunction)
    _ = try queue.new(prompt: "stale", id: "stale-task")
    _ = try queue.claimNext(workerID: "worker-a")

    let heartbeat = AgentHeartbeatStore(
        storageRoot: root,
        config: AgentHeartbeatConfig(staleAfter: 30),
        now: clock.callAsFunction
    )
    try heartbeat.write(.init(taskID: "stale-task", state: .running, updatedAt: Date(timeIntervalSince1970: 3_000)))

    clock.now = Date(timeIntervalSince1970: 3_040)
    let requeued = try heartbeat.requeueStaleRunningTasks(in: queue)

    #expect(requeued.map(\.id) == ["stale-task"])
    #expect(requeued.first?.status == .queued)
    #expect(requeued.first?.attempt == 2)
    #expect(requeued.first?.claimedBy == nil)
    #expect(try queue.logs(taskID: "stale-task").map(\.message) == [
        "Requeued stale running task after heartbeat timeout (last heartbeat: 1970-01-01T00:50:00Z).",
    ])
}
