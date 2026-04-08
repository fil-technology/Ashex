import Foundation

public typealias JSONObject = [String: JSONValue]

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object(JSONObject)
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: JSONObject? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case tool
    case system
}

public struct ThreadRecord: Codable, Sendable {
    public let id: UUID
    public let createdAt: Date

    public init(id: UUID, createdAt: Date) {
        self.id = id
        self.createdAt = createdAt
    }
}

public struct ThreadSummary: Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let updatedAt: Date
    public let latestRunID: UUID?
    public let latestRunState: RunState?
    public let messageCount: Int

    public init(id: UUID, createdAt: Date, updatedAt: Date, latestRunID: UUID?, latestRunState: RunState?, messageCount: Int) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.latestRunID = latestRunID
        self.latestRunState = latestRunState
        self.messageCount = messageCount
    }
}

public struct PersistedSetting: Codable, Sendable, Equatable {
    public let namespace: String
    public let key: String
    public let value: JSONValue
    public let updatedAt: Date

    public init(namespace: String, key: String, value: JSONValue, updatedAt: Date) {
        self.namespace = namespace
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
    }
}

public struct MessageRecord: Codable, Sendable {
    public let id: UUID
    public let threadID: UUID
    public let runID: UUID?
    public let role: MessageRole
    public let content: String
    public let createdAt: Date

    public init(id: UUID, threadID: UUID, runID: UUID?, role: MessageRole, content: String, createdAt: Date) {
        self.id = id
        self.threadID = threadID
        self.runID = runID
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

public enum RunState: String, Codable, Sendable {
    case pending
    case running
    case completed
    case failed
    case interrupted
    case cancelled
}

public struct RunRecord: Codable, Sendable {
    public let id: UUID
    public let threadID: UUID
    public let state: RunState
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: UUID, threadID: UUID, state: RunState, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.threadID = threadID
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum RunStepState: String, Codable, Sendable {
    case pending
    case running
    case completed
    case skipped
    case failed
}

public struct RunStepRecord: Codable, Sendable {
    public let id: UUID
    public let runID: UUID
    public let index: Int
    public let title: String
    public let state: RunStepState
    public let summary: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: UUID, runID: UUID, index: Int, title: String, state: RunStepState, summary: String?, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.runID = runID
        self.index = index
        self.title = title
        self.state = state
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ContextCompactionRecord: Codable, Sendable {
    public let id: UUID
    public let runID: UUID
    public let droppedMessageCount: Int
    public let retainedMessageCount: Int
    public let estimatedTokenCount: Int
    public let estimatedContextWindow: Int
    public let summary: String
    public let createdAt: Date

    public init(
        id: UUID,
        runID: UUID,
        droppedMessageCount: Int,
        retainedMessageCount: Int,
        estimatedTokenCount: Int,
        estimatedContextWindow: Int,
        summary: String,
        createdAt: Date
    ) {
        self.id = id
        self.runID = runID
        self.droppedMessageCount = droppedMessageCount
        self.retainedMessageCount = retainedMessageCount
        self.estimatedTokenCount = estimatedTokenCount
        self.estimatedContextWindow = estimatedContextWindow
        self.summary = summary
        self.createdAt = createdAt
    }
}

public struct WorkspaceSnapshotRecord: Codable, Sendable, Equatable {
    public let id: UUID
    public let runID: UUID
    public let workspaceRootPath: String
    public let topLevelEntries: [String]
    public let instructionFiles: [String]
    public let gitBranch: String?
    public let gitStatusSummary: String?
    public let createdAt: Date

    public init(
        id: UUID,
        runID: UUID,
        workspaceRootPath: String,
        topLevelEntries: [String],
        instructionFiles: [String],
        gitBranch: String?,
        gitStatusSummary: String?,
        createdAt: Date
    ) {
        self.id = id
        self.runID = runID
        self.workspaceRootPath = workspaceRootPath
        self.topLevelEntries = topLevelEntries
        self.instructionFiles = instructionFiles
        self.gitBranch = gitBranch
        self.gitStatusSummary = gitStatusSummary
        self.createdAt = createdAt
    }
}

public struct WorkingMemoryRecord: Codable, Sendable, Equatable {
    public let id: UUID
    public let runID: UUID
    public let currentTask: String
    public let currentPhase: String?
    public let explorationTargets: [String]
    public let pendingExplorationTargets: [String]
    public let inspectedPaths: [String]
    public let changedPaths: [String]
    public let recentFindings: [String]
    public let completedStepSummaries: [String]
    public let unresolvedItems: [String]
    public let validationSuggestions: [String]
    public let summary: String
    public let updatedAt: Date

    public init(
        id: UUID,
        runID: UUID,
        currentTask: String,
        currentPhase: String?,
        explorationTargets: [String],
        pendingExplorationTargets: [String],
        inspectedPaths: [String],
        changedPaths: [String],
        recentFindings: [String],
        completedStepSummaries: [String],
        unresolvedItems: [String],
        validationSuggestions: [String],
        summary: String,
        updatedAt: Date
    ) {
        self.id = id
        self.runID = runID
        self.currentTask = currentTask
        self.currentPhase = currentPhase
        self.explorationTargets = explorationTargets
        self.pendingExplorationTargets = pendingExplorationTargets
        self.inspectedPaths = inspectedPaths
        self.changedPaths = changedPaths
        self.recentFindings = recentFindings
        self.completedStepSummaries = completedStepSummaries
        self.unresolvedItems = unresolvedItems
        self.validationSuggestions = validationSuggestions
        self.summary = summary
        self.updatedAt = updatedAt
    }
}

public struct ToolCallRecord: Codable, Sendable {
    public let id: UUID
    public let runID: UUID
    public let toolName: String
    public let arguments: JSONObject
    public let startedAt: Date
    public let finishedAt: Date?
    public let status: String
    public let output: String?

    public init(id: UUID, runID: UUID, toolName: String, arguments: JSONObject, startedAt: Date, finishedAt: Date?, status: String, output: String?) {
        self.id = id
        self.runID = runID
        self.toolName = toolName
        self.arguments = arguments
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.output = output
    }
}

public enum ToolContent: Codable, Sendable, Equatable {
    case text(String)
    case structured(JSONValue)

    public var displayText: String {
        switch self {
        case .text(let value):
            return value
        case .structured(let value):
            return value.prettyPrinted
        }
    }
}

public extension JSONValue {
    var prettyPrinted: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "\(self)"
    }
}
