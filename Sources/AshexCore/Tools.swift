import Foundation

public struct ToolContext: Sendable {
    public let runID: UUID
    public let attachments: [InputAttachment]
    public let emit: RuntimeEventHandler
    public let cancellation: CancellationToken
    public let approvalGranted: Bool

    public init(
        runID: UUID,
        attachments: [InputAttachment] = [],
        emit: @escaping RuntimeEventHandler,
        cancellation: CancellationToken,
        approvalGranted: Bool = false
    ) {
        self.runID = runID
        self.attachments = attachments
        self.emit = emit
        self.cancellation = cancellation
        self.approvalGranted = approvalGranted
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
        specs().map { ToolSchema(spec: $0) }
    }

    public func specs() -> [ToolSpec] {
        tools.values
            .map { $0.contract.toolSpec() }
            .sorted { $0.name < $1.name }
    }

    public func providerSchemas(for providerID: String) -> [ProviderToolSchema] {
        let adapter = ToolSchemaAdapterFactory.adapter(for: providerID)
        return specs().map(adapter.schema(for:))
    }

    public func tool(named name: String) throws -> any Tool {
        guard let tool = tools[name] else {
            throw AshexError.toolNotFound(name)
        }
        return tool
    }
}

public extension ToolContract {
    func toolSpec() -> ToolSpec {
        let operationSpecs = operations.map { $0.toSpec(tags: tags) }
        let requiresApproval = operations.contains { $0.approval != nil }
        let hasMutatingOperation = operations.contains { $0.mutatesWorkspace }
        let requiresNetwork = operations.contains { $0.requiresNetwork }
        let strongestRisk = operations.compactMap(\.approval?.risk).max(by: { $0.sortRank < $1.sortRank })

        return ToolSpec(
            name: name,
            description: description,
            kind: kind,
            category: category,
            inputSchema: ToolSpecSchemaBuilder.makeInputSchema(
                arguments: mergedArguments(),
                operationArgumentKey: nil,
                operationName: nil
            ),
            safety: .init(
                requiresApproval: requiresApproval,
                isReadOnly: !hasMutatingOperation,
                requiresNetwork: requiresNetwork,
                risk: strongestRisk
            ),
            timeoutMs: nil,
            idempotency: hasMutatingOperation ? .sideEffecting : .readOnly,
            tags: tags,
            operationArgumentKey: operationArgumentKey,
            defaultOperationName: defaultOperationName,
            operations: operationSpecs
        )
    }

    private func mergedArguments() -> [ToolArgumentContract] {
        var seen: Set<String> = []
        var merged: [ToolArgumentContract] = []

        if let operationArgumentKey {
            merged.append(.init(
                name: operationArgumentKey,
                description: "Operation selector",
                type: .string,
                required: defaultOperationName == nil,
                enumValues: operations.map(\.name)
            ))
            seen.insert(operationArgumentKey)
        }

        for operation in operations {
            for argument in operation.arguments where !seen.contains(argument.name) {
                merged.append(argument)
                seen.insert(argument.name)
            }
        }

        return merged
    }
}

private extension ApprovalRisk {
    var sortRank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }
}
