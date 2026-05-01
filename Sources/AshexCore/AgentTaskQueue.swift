import Foundation

public enum AgentTaskStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case queued
    case running
    case paused
    case done
    case failed
    case cancelled
}

public struct AgentTask: Codable, Equatable, Sendable {
    public var id: String
    public var prompt: String
    public var status: AgentTaskStatus
    public var attempt: Int
    public var claimedBy: String?
    public var failureReason: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        prompt: String,
        status: AgentTaskStatus = .queued,
        attempt: Int = 1,
        claimedBy: String? = nil,
        failureReason: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.prompt = prompt
        self.status = status
        self.attempt = attempt
        self.claimedBy = claimedBy
        self.failureReason = failureReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum AgentTaskLogLevel: String, Codable, Equatable, Sendable {
    case debug
    case info
    case warning
    case error
}

public struct AgentTaskLogEntry: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var level: AgentTaskLogLevel
    public var message: String

    public init(timestamp: Date = Date(), level: AgentTaskLogLevel, message: String) {
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}

public enum AgentTaskQueueError: Error, Equatable {
    case taskNotFound(String)
    case taskAlreadyExists(String)
}

public struct AgentTaskQueue: @unchecked Sendable {
    public let storageRoot: URL

    private var tasksDirectory: URL {
        storageRoot.appendingPathComponent("tasks", isDirectory: true)
    }

    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    public init(
        storageRoot: URL,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storageRoot = storageRoot
        self.fileManager = fileManager
        self.now = now
    }

    @discardableResult
    public func new(prompt: String, plan: String = "", id: String = UUID().uuidString) throws -> AgentTask {
        let directory = taskDirectory(id: id)
        if fileManager.fileExists(atPath: directory.path) {
            throw AgentTaskQueueError.taskAlreadyExists(id)
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = now()
        let task = AgentTask(id: id, prompt: prompt, createdAt: timestamp, updatedAt: timestamp)
        try write(task)
        try plan.write(to: planURL(id: id), atomically: true, encoding: .utf8)
        fileManager.createFile(atPath: logsURL(id: id).path, contents: Data())
        try "".write(to: resultURL(id: id), atomically: true, encoding: .utf8)
        return task
    }

    public func list() throws -> [AgentTask] {
        guard fileManager.fileExists(atPath: tasksDirectory.path) else {
            return []
        }

        let taskDirectories = try fileManager.contentsOfDirectory(
            at: tasksDirectory,
            includingPropertiesForKeys: nil
        )

        return try taskDirectories
            .filter { $0.hasDirectoryPath }
            .map { try readTask(at: $0.appendingPathComponent("task.json")) }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id < rhs.id
                }
                return lhs.createdAt < rhs.createdAt
            }
    }

    public func task(id: String) throws -> AgentTask {
        let url = taskURL(id: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw AgentTaskQueueError.taskNotFound(id)
        }
        return try readTask(at: url)
    }

    @discardableResult
    public func claimNext(workerID: String) throws -> AgentTask? {
        guard var task = try list().first(where: { $0.status == .queued }) else {
            return nil
        }

        task.status = .running
        task.claimedBy = workerID
        task.failureReason = nil
        task.updatedAt = now()
        try write(task)
        return task
    }

    @discardableResult
    public func markRunning(id: String) throws -> AgentTask {
        try updateStatus(id: id, status: .running)
    }

    @discardableResult
    public func pause(id: String) throws -> AgentTask {
        try updateStatus(id: id, status: .paused)
    }

    @discardableResult
    public func resume(id: String) throws -> AgentTask {
        try updateStatus(id: id, status: .queued)
    }

    @discardableResult
    public func cancel(id: String) throws -> AgentTask {
        try updateStatus(id: id, status: .cancelled)
    }

    @discardableResult
    public func fail(id: String) throws -> AgentTask {
        try fail(id: id, reason: nil)
    }

    @discardableResult
    public func fail(id: String, reason: String?) throws -> AgentTask {
        var task = try task(id: id)
        task.status = .failed
        task.claimedBy = nil
        task.failureReason = reason
        task.updatedAt = now()
        try write(task)
        return task
    }

    @discardableResult
    public func complete(id: String) throws -> AgentTask {
        try done(id: id)
    }

    @discardableResult
    public func done(id: String, result: String? = nil) throws -> AgentTask {
        var task = try task(id: id)
        task.status = .done
        task.claimedBy = nil
        task.failureReason = nil
        task.updatedAt = now()
        try write(task)
        if let result {
            try writeResult(taskID: id, markdown: result)
        }
        return task
    }

    @discardableResult
    public func retry(id: String) throws -> AgentTask {
        var task = try task(id: id)
        task.status = .queued
        task.claimedBy = nil
        task.failureReason = nil
        task.attempt += 1
        task.updatedAt = now()
        try write(task)
        return task
    }

    @discardableResult
    public func requeue(id: String, reason: String? = nil) throws -> AgentTask {
        var task = try retry(id: id)
        if let reason {
            try appendLog(taskID: id, level: .warning, message: reason, timestamp: task.updatedAt)
        }
        task = try self.task(id: id)
        return task
    }

    public func appendLog(taskID: String, level: AgentTaskLogLevel, message: String, timestamp: Date = Date()) throws {
        _ = try task(id: taskID)
        let entry = AgentTaskLogEntry(timestamp: timestamp, level: level, message: message)
        let data = try JSONEncoder.agentQueueEncoder.encode(entry)
        guard let line = String(data: data, encoding: .utf8) else { return }

        let url = logsURL(id: taskID)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    public func logs(taskID: String) throws -> [AgentTaskLogEntry] {
        _ = try task(id: taskID)
        let url = logsURL(id: taskID)
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }

        let content = try String(contentsOf: url, encoding: .utf8)
        return try content
            .split(separator: "\n")
            .map { line in
                try JSONDecoder.agentQueueDecoder.decode(AgentTaskLogEntry.self, from: Data(line.utf8))
            }
    }

    public func writeResult(taskID: String, markdown: String) throws {
        _ = try task(id: taskID)
        try markdown.write(to: resultURL(id: taskID), atomically: true, encoding: .utf8)
    }

    public func result(taskID: String) throws -> String {
        _ = try task(id: taskID)
        return try String(contentsOf: resultURL(id: taskID), encoding: .utf8)
    }

    private func updateStatus(id: String, status: AgentTaskStatus) throws -> AgentTask {
        var task = try task(id: id)
        task.status = status
        if status != .running {
            task.claimedBy = nil
        }
        if status == .queued || status == .done || status == .cancelled {
            task.failureReason = nil
        }
        task.updatedAt = now()
        try write(task)
        return task
    }

    private func write(_ task: AgentTask) throws {
        try fileManager.createDirectory(at: taskDirectory(id: task.id), withIntermediateDirectories: true)
        let data = try JSONEncoder.agentQueueEncoder.encode(task)
        try data.write(to: taskURL(id: task.id), options: .atomic)
    }

    private func readTask(at url: URL) throws -> AgentTask {
        let data = try Data(contentsOf: url)
        return try JSONDecoder.agentQueueDecoder.decode(AgentTask.self, from: data)
    }

    private func taskDirectory(id: String) -> URL {
        tasksDirectory.appendingPathComponent(id, isDirectory: true)
    }

    private func taskURL(id: String) -> URL {
        taskDirectory(id: id).appendingPathComponent("task.json")
    }

    private func planURL(id: String) -> URL {
        taskDirectory(id: id).appendingPathComponent("plan.md")
    }

    private func logsURL(id: String) -> URL {
        taskDirectory(id: id).appendingPathComponent("logs.jsonl")
    }

    private func resultURL(id: String) -> URL {
        taskDirectory(id: id).appendingPathComponent("result.md")
    }
}

extension JSONEncoder {
    fileprivate static var agentQueueEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var agentQueueDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
