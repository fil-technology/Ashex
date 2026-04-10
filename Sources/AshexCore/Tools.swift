import Foundation

public struct ToolContext: Sendable {
    public let runID: UUID
    public let emit: RuntimeEventHandler
    public let cancellation: CancellationToken

    public init(runID: UUID, emit: @escaping RuntimeEventHandler, cancellation: CancellationToken) {
        self.runID = runID
        self.emit = emit
        self.cancellation = cancellation
    }
}

public enum ToolKind: String, Codable, Sendable {
    case embedded
    case installable
}

public enum ToolArgumentType: String, Codable, Sendable {
    case string
    case number
    case bool
    case object
    case array
}

public struct ToolArgumentContract: Codable, Sendable {
    public let name: String
    public let description: String
    public let type: ToolArgumentType
    public let required: Bool
    public let enumValues: [String]

    public init(
        name: String,
        description: String,
        type: ToolArgumentType,
        required: Bool,
        enumValues: [String] = []
    ) {
        self.name = name
        self.description = description
        self.type = type
        self.required = required
        self.enumValues = enumValues
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case type
        case required
        case enumValues
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        type = try container.decode(ToolArgumentType.self, forKey: .type)
        required = try container.decode(Bool.self, forKey: .required)
        enumValues = try container.decodeIfPresent([String].self, forKey: .enumValues) ?? []
    }
}

public struct ToolApprovalContract: Codable, Sendable {
    public let risk: ApprovalRisk
    public let summary: String
    public let reasonTemplate: String?

    public init(risk: ApprovalRisk, summary: String, reasonTemplate: String? = nil) {
        self.risk = risk
        self.summary = summary
        self.reasonTemplate = reasonTemplate
    }
}

public struct ToolOperationContract: Codable, Sendable {
    public let name: String
    public let description: String
    public let mutatesWorkspace: Bool
    public let requiresNetwork: Bool
    public let validationArtifacts: [String]
    public let inspectedPathArguments: [String]
    public let changedPathArguments: [String]
    public let progressSummary: String?
    public let approval: ToolApprovalContract?
    public let arguments: [ToolArgumentContract]

    public init(
        name: String,
        description: String,
        mutatesWorkspace: Bool,
        requiresNetwork: Bool = false,
        validationArtifacts: [String] = [],
        inspectedPathArguments: [String] = [],
        changedPathArguments: [String] = [],
        progressSummary: String? = nil,
        approval: ToolApprovalContract? = nil,
        arguments: [ToolArgumentContract] = []
    ) {
        self.name = name
        self.description = description
        self.mutatesWorkspace = mutatesWorkspace
        self.requiresNetwork = requiresNetwork
        self.validationArtifacts = validationArtifacts
        self.inspectedPathArguments = inspectedPathArguments
        self.changedPathArguments = changedPathArguments
        self.progressSummary = progressSummary
        self.approval = approval
        self.arguments = arguments
    }
}

public struct ToolContract: Codable, Sendable {
    public let name: String
    public let description: String
    public let kind: ToolKind
    public let category: String
    public let operationArgumentKey: String?
    public let defaultOperationName: String?
    public let operations: [ToolOperationContract]
    public let tags: [String]

    public init(
        name: String,
        description: String,
        kind: ToolKind = .embedded,
        category: String = "general",
        operationArgumentKey: String? = "operation",
        defaultOperationName: String? = nil,
        operations: [ToolOperationContract] = [],
        tags: [String] = []
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.category = category
        self.operationArgumentKey = operationArgumentKey
        self.defaultOperationName = defaultOperationName
        self.operations = operations
        self.tags = tags
    }

    public func operation(for arguments: JSONObject) -> ToolOperationContract? {
        if let operationArgumentKey,
           let operationName = arguments[operationArgumentKey]?.stringValue {
            return operations.first { $0.name == operationName }
        }

        if let defaultOperationName {
            return operations.first { $0.name == defaultOperationName }
        }

        return operations.count == 1 ? operations.first : nil
    }
}

public protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var contract: ToolContract { get }
    func execute(arguments: JSONObject, context: ToolContext) async throws -> ToolContent
}

public extension Tool {
    var contract: ToolContract {
        ToolContract(name: name, description: description)
    }
}

public final class ToolRegistry: Sendable {
    private let tools: [String: any Tool]

    public init(tools: [any Tool]) {
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
    }

    public func schema() -> [ToolSchema] {
        tools.values
            .map {
                ToolSchema(
                    name: $0.contract.name,
                    description: $0.contract.description,
                    kind: $0.contract.kind,
                    category: $0.contract.category,
                    operationArgumentKey: $0.contract.operationArgumentKey,
                    defaultOperationName: $0.contract.defaultOperationName,
                    operations: $0.contract.operations,
                    tags: $0.contract.tags
                )
            }
            .sorted { $0.name < $1.name }
    }

    public func tool(named name: String) throws -> any Tool {
        guard let tool = tools[name] else {
            throw AshexError.toolNotFound(name)
        }
        return tool
    }
}
