import Foundation

public enum AgentProcessStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case registered
    case running
    case exited
    case killed
    case failed
}

public enum AgentProcessDriverResult: Equatable, Sendable {
    case running
    case exited(exitCode: Int)
    case killed
    case failed(reason: String)
}

public struct AgentProcessDriver: Sendable {
    public var poll: @Sendable (AgentManagedProcess) throws -> AgentProcessDriverResult
    public var kill: @Sendable (AgentManagedProcess) throws -> AgentProcessDriverResult

    public init(
        poll: @escaping @Sendable (AgentManagedProcess) throws -> AgentProcessDriverResult = { _ in .running },
        kill: @escaping @Sendable (AgentManagedProcess) throws -> AgentProcessDriverResult = { _ in .killed }
    ) {
        self.poll = poll
        self.kill = kill
    }
}

public struct AgentManagedProcess: Codable, Equatable, Sendable {
    public var id: String
    public var command: [String]
    public var workingDirectory: String
    public var status: AgentProcessStatus
    public var exitCode: Int?
    public var failureReason: String?
    public var pollCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        command: [String],
        workingDirectory: String,
        status: AgentProcessStatus = .registered,
        exitCode: Int? = nil,
        failureReason: String? = nil,
        pollCount: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.command = command
        self.workingDirectory = workingDirectory
        self.status = status
        self.exitCode = exitCode
        self.failureReason = failureReason
        self.pollCount = pollCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum AgentProcessLogStream: String, Codable, Equatable, Sendable {
    case stdout
    case stderr
}

public struct AgentProcessLogEntry: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var stream: AgentProcessLogStream
    public var text: String

    public init(timestamp: Date = Date(), stream: AgentProcessLogStream, text: String) {
        self.timestamp = timestamp
        self.stream = stream
        self.text = text
    }
}

public struct AgentProcessWriteEntry: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var text: String

    public init(timestamp: Date = Date(), text: String) {
        self.timestamp = timestamp
        self.text = text
    }
}

public enum AgentProcessManagerError: Error, Equatable {
    case processAlreadyExists(String)
    case processNotFound(String)
    case waitLimitExceeded(String)
}

public struct AgentProcessManager: @unchecked Sendable {
    public let storageRoot: URL

    private let driver: AgentProcessDriver
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    private var processesDirectory: URL {
        storageRoot.appendingPathComponent("processes", isDirectory: true)
    }

    public init(
        storageRoot: URL,
        driver: AgentProcessDriver = AgentProcessDriver(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storageRoot = storageRoot
        self.driver = driver
        self.fileManager = fileManager
        self.now = now
    }

    @discardableResult
    public func register(command: [String], workingDirectory: String, id: String = UUID().uuidString) throws -> AgentManagedProcess {
        let directory = processDirectory(id: id)
        if fileManager.fileExists(atPath: directory.path) {
            throw AgentProcessManagerError.processAlreadyExists(id)
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = now()
        let process = AgentManagedProcess(
            id: id,
            command: command,
            workingDirectory: workingDirectory,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        try write(process)
        fileManager.createFile(atPath: logURL(id: id).path, contents: Data())
        fileManager.createFile(atPath: writesURL(id: id).path, contents: Data())
        return process
    }

    public func list() throws -> [AgentManagedProcess] {
        guard fileManager.fileExists(atPath: processesDirectory.path) else {
            return []
        }

        return try fileManager
            .contentsOfDirectory(at: processesDirectory, includingPropertiesForKeys: nil)
            .filter(\.hasDirectoryPath)
            .map { try readProcess(at: $0.appendingPathComponent("process.json")) }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id < rhs.id
                }
                return lhs.createdAt < rhs.createdAt
            }
    }

    public func process(id: String) throws -> AgentManagedProcess {
        let url = processURL(id: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw AgentProcessManagerError.processNotFound(id)
        }
        return try readProcess(at: url)
    }

    @discardableResult
    public func poll(processID: String) throws -> AgentManagedProcess {
        var process = try process(id: processID)
        let result = try driver.poll(process)
        process.pollCount += 1
        process.apply(driverResult: result, updatedAt: now())
        try write(process)
        return process
    }

    @discardableResult
    public func wait(processID: String, maxPolls: Int = 60) throws -> AgentManagedProcess {
        var latest = try process(id: processID)
        for _ in 0..<max(maxPolls, 0) {
            latest = try poll(processID: processID)
            if latest.status != .running {
                return latest
            }
        }
        throw AgentProcessManagerError.waitLimitExceeded(processID)
    }

    @discardableResult
    public func kill(processID: String) throws -> AgentManagedProcess {
        var process = try process(id: processID)
        let result = try driver.kill(process)
        process.apply(driverResult: result, updatedAt: now())
        try write(process)
        return process
    }

    public func appendLog(processID: String, stream: AgentProcessLogStream, text: String, timestamp: Date = Date()) throws {
        _ = try process(id: processID)
        let entry = AgentProcessLogEntry(timestamp: timestamp, stream: stream, text: text)
        try appendJSONLine(entry, to: logURL(id: processID))
    }

    public func log(processID: String) throws -> [AgentProcessLogEntry] {
        _ = try process(id: processID)
        return try readJSONLines(AgentProcessLogEntry.self, from: logURL(id: processID))
    }

    public func write(processID: String, text: String, timestamp: Date = Date()) throws {
        _ = try process(id: processID)
        let entry = AgentProcessWriteEntry(timestamp: timestamp, text: text)
        try appendJSONLine(entry, to: writesURL(id: processID))
    }

    public func writes(processID: String) throws -> [AgentProcessWriteEntry] {
        _ = try process(id: processID)
        return try readJSONLines(AgentProcessWriteEntry.self, from: writesURL(id: processID))
    }

    private func write(_ process: AgentManagedProcess) throws {
        try fileManager.createDirectory(at: processDirectory(id: process.id), withIntermediateDirectories: true)
        let data = try JSONEncoder.agentProcessEncoder.encode(process)
        try data.write(to: processURL(id: process.id), options: .atomic)
    }

    private func readProcess(at url: URL) throws -> AgentManagedProcess {
        let data = try Data(contentsOf: url)
        return try JSONDecoder.agentProcessDecoder.decode(AgentManagedProcess.self, from: data)
    }

    private func appendJSONLine<T: Encodable>(_ value: T, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: Data())
        }
        let data = try JSONEncoder.agentProcessEncoder.encode(value)
        guard let line = String(data: data, encoding: .utf8) else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private func readJSONLines<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }
        let content = try String(contentsOf: url, encoding: .utf8)
        return try content
            .split(separator: "\n")
            .map { line in
                try JSONDecoder.agentProcessDecoder.decode(T.self, from: Data(line.utf8))
            }
    }

    private func processDirectory(id: String) -> URL {
        processesDirectory.appendingPathComponent(id, isDirectory: true)
    }

    private func processURL(id: String) -> URL {
        processDirectory(id: id).appendingPathComponent("process.json")
    }

    private func logURL(id: String) -> URL {
        processDirectory(id: id).appendingPathComponent("logs.jsonl")
    }

    private func writesURL(id: String) -> URL {
        processDirectory(id: id).appendingPathComponent("writes.jsonl")
    }
}

private extension AgentManagedProcess {
    mutating func apply(driverResult: AgentProcessDriverResult, updatedAt: Date) {
        switch driverResult {
        case .running:
            status = .running
            exitCode = nil
            failureReason = nil
        case let .exited(code):
            status = .exited
            exitCode = code
            failureReason = nil
        case .killed:
            status = .killed
            failureReason = nil
        case let .failed(reason):
            status = .failed
            failureReason = reason
        }
        self.updatedAt = updatedAt
    }
}

private extension JSONEncoder {
    static var agentProcessEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var agentProcessDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
