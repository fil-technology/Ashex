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
