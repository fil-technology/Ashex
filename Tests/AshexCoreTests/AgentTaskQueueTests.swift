import AshexCore
import Foundation
import Testing

final class ManualClock: @unchecked Sendable {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }

    func callAsFunction() -> Date {
        now
    }
}

@Test func taskQueueCreatesReservedTaskLayoutAndListsNewestTask() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let queue = AgentTaskQueue(storageRoot: root)

    let task = try queue.new(prompt: "Ship the background queue", plan: "1. Inspect\n2. Implement", id: "task-001")

    #expect(task.id == "task-001")
    #expect(task.status == .queued)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("tasks/task-001/task.json").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("tasks/task-001/plan.md").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("tasks/task-001/logs.jsonl").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("tasks/task-001/result.md").path))
    #expect(try queue.list().map(\.id) == ["task-001"])
}

@Test func taskQueueSupportsLifecycleOperationsAndLogs() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let queue = AgentTaskQueue(storageRoot: root)
    _ = try queue.new(prompt: "Exercise lifecycle", id: "task-life")

    try queue.markRunning(id: "task-life")
    try queue.pause(id: "task-life")
    #expect(try queue.task(id: "task-life").status == .paused)

    try queue.resume(id: "task-life")
    #expect(try queue.task(id: "task-life").status == .queued)

    try queue.appendLog(taskID: "task-life", level: .info, message: "started")
    try queue.cancel(id: "task-life")
    try queue.retry(id: "task-life")
    try queue.writeResult(taskID: "task-life", markdown: "Recovered")

    let refreshed = try queue.task(id: "task-life")
    #expect(refreshed.status == .queued)
    #expect(refreshed.attempt == 2)
    #expect(try queue.logs(taskID: "task-life").map(\.message) == ["started"])
    #expect(try queue.result(taskID: "task-life") == "Recovered")
}

@Test func taskQueueClaimsOldestQueuedTaskAndPersistsWorkerMetadataDeterministically() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let clock = ManualClock(Date(timeIntervalSince1970: 1_000))
    let queue = AgentTaskQueue(storageRoot: root, now: clock.callAsFunction)

    _ = try queue.new(prompt: "older", id: "task-old")
    clock.now = Date(timeIntervalSince1970: 1_010)
    _ = try queue.new(prompt: "newer", id: "task-new")

    clock.now = Date(timeIntervalSince1970: 1_020)
    let claimed = try #require(try queue.claimNext(workerID: "worker-a"))

    #expect(claimed.id == "task-old")
    #expect(claimed.status == .running)
    #expect(claimed.claimedBy == "worker-a")
    #expect(claimed.updatedAt == Date(timeIntervalSince1970: 1_020))
    #expect(try queue.task(id: "task-old").claimedBy == "worker-a")
    #expect(try queue.claimNext(workerID: "worker-a")?.id == "task-new")
}

@Test func taskQueueCompletesFailsAndRetriesWithDurableAttemptState() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let clock = ManualClock(Date(timeIntervalSince1970: 2_000))
    let queue = AgentTaskQueue(storageRoot: root, now: clock.callAsFunction)
    _ = try queue.new(prompt: "retry me", id: "task-retry")
    _ = try queue.claimNext(workerID: "worker-a")

    clock.now = Date(timeIntervalSince1970: 2_010)
    let failed = try queue.fail(id: "task-retry", reason: "transient model outage")

    #expect(failed.status == .failed)
    #expect(failed.claimedBy == nil)
    #expect(failed.failureReason == "transient model outage")

    clock.now = Date(timeIntervalSince1970: 2_020)
    let retried = try queue.retry(id: "task-retry")

    #expect(retried.status == .queued)
    #expect(retried.attempt == 2)
    #expect(retried.failureReason == nil)

    _ = try queue.claimNext(workerID: "worker-b")
    clock.now = Date(timeIntervalSince1970: 2_030)
    let done = try queue.done(id: "task-retry", result: "All good")

    #expect(done.status == .done)
    #expect(done.claimedBy == nil)
    #expect(try queue.result(taskID: "task-retry") == "All good")

    let reopened = AgentTaskQueue(storageRoot: root, now: clock.callAsFunction)
    #expect(try reopened.task(id: "task-retry").status == .done)
    #expect(try reopened.task(id: "task-retry").attempt == 2)
}
