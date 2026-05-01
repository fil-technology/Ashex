import Foundation

public struct AgentHeartbeatConfig: Codable, Equatable, Sendable {
    public var staleAfter: TimeInterval

    public init(staleAfter: TimeInterval = 120) {
        self.staleAfter = staleAfter
    }
}

public enum AgentHeartbeatState: String, Codable, Equatable, Sendable {
    case running
    case paused
    case done
    case failed
    case cancelled
}

public struct AgentHeartbeatStatus: Codable, Equatable, Sendable {
    public var taskID: String
    public var state: AgentHeartbeatState
    public var updatedAt: Date
    public var detail: String?

    public init(taskID: String, state: AgentHeartbeatState, updatedAt: Date = Date(), detail: String? = nil) {
        self.taskID = taskID
        self.state = state
        self.updatedAt = updatedAt
        self.detail = detail
    }
}

public enum AgentHeartbeatAction: Equatable, Sendable {
    case markTaskStale(taskID: String, lastHeartbeatAt: Date?, staleAfter: TimeInterval)
}

public struct AgentHeartbeatStore: @unchecked Sendable {
    public let storageRoot: URL
    public let config: AgentHeartbeatConfig

    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    public init(
        storageRoot: URL,
        config: AgentHeartbeatConfig = AgentHeartbeatConfig(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storageRoot = storageRoot
        self.config = config
        self.fileManager = fileManager
        self.now = now
    }

    public func write(_ status: AgentHeartbeatStatus) throws {
        let directory = taskDirectory(id: status.taskID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.agentHeartbeatEncoder.encode(status)
        try data.write(to: heartbeatURL(taskID: status.taskID), options: .atomic)
    }

    public func status(taskID: String) throws -> AgentHeartbeatStatus? {
        let url = heartbeatURL(taskID: taskID)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder.agentHeartbeatDecoder.decode(AgentHeartbeatStatus.self, from: data)
    }

    public func actions(for tasks: [AgentTask], now: Date? = nil) throws -> [AgentHeartbeatAction] {
        let referenceDate = now ?? self.now()
        return try tasks
            .filter { $0.status == .running }
            .sorted { $0.id < $1.id }
            .compactMap { task -> AgentHeartbeatAction? in
                let heartbeat = try status(taskID: task.id)
                guard let heartbeat else {
                    return .markTaskStale(
                        taskID: task.id,
                        lastHeartbeatAt: Date?.none,
                        staleAfter: config.staleAfter
                    )
                }

                guard referenceDate.timeIntervalSince(heartbeat.updatedAt) > config.staleAfter else {
                    return nil
                }

                return .markTaskStale(
                    taskID: task.id,
                    lastHeartbeatAt: heartbeat.updatedAt,
                    staleAfter: config.staleAfter
                )
            }
    }

    @discardableResult
    public func requeueStaleRunningTasks(in queue: AgentTaskQueue) throws -> [AgentTask] {
        try actions(for: queue.list()).map { action in
            switch action {
            case let .markTaskStale(taskID, lastHeartbeatAt, _):
                let reason = staleRequeueMessage(lastHeartbeatAt: lastHeartbeatAt)
                return try queue.requeue(id: taskID, reason: reason)
            }
        }
    }

    private func taskDirectory(id: String) -> URL {
        storageRoot
            .appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    private func heartbeatURL(taskID: String) -> URL {
        taskDirectory(id: taskID).appendingPathComponent("heartbeat.json")
    }

    private func staleRequeueMessage(lastHeartbeatAt: Date?) -> String {
        guard let lastHeartbeatAt else {
            return "Requeued stale running task after heartbeat timeout (missing heartbeat)."
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return "Requeued stale running task after heartbeat timeout (last heartbeat: \(formatter.string(from: lastHeartbeatAt)))."
    }
}

extension JSONEncoder {
    fileprivate static var agentHeartbeatEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var agentHeartbeatDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
