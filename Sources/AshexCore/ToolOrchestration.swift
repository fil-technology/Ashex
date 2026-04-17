import Foundation

public enum ToolIdempotencyHint: String, Codable, Sendable, Equatable {
    case readOnly
    case idempotentWrite
    case sideEffecting
}

public struct ToolSafetyMetadata: Codable, Sendable, Equatable {
    public let requiresApproval: Bool
    public let isReadOnly: Bool
    public let requiresNetwork: Bool
    public let risk: ApprovalRisk?

    public init(
        requiresApproval: Bool,
        isReadOnly: Bool,
        requiresNetwork: Bool,
        risk: ApprovalRisk?
    ) {
        self.requiresApproval = requiresApproval
        self.isReadOnly = isReadOnly
        self.requiresNetwork = requiresNetwork
        self.risk = risk
    }
}

public struct ToolOperationSpec: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public let outputSchema: JSONValue?
    public let safety: ToolSafetyMetadata
    public let timeoutMs: Int?
    public let idempotency: ToolIdempotencyHint
    public let tags: [String]

    public init(
        name: String,
        description: String,
        inputSchema: JSONValue,
        outputSchema: JSONValue? = nil,
        safety: ToolSafetyMetadata,
        timeoutMs: Int? = nil,
        idempotency: ToolIdempotencyHint,
        tags: [String] = []
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.safety = safety
        self.timeoutMs = timeoutMs
        self.idempotency = idempotency
        self.tags = tags
    }
}

public struct ToolSpec: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let kind: ToolKind
    public let category: String
    public let inputSchema: JSONValue
    public let outputSchema: JSONValue?
    public let safety: ToolSafetyMetadata
    public let timeoutMs: Int?
    public let idempotency: ToolIdempotencyHint
    public let tags: [String]
    public let operationArgumentKey: String?
    public let defaultOperationName: String?
    public let operations: [ToolOperationSpec]

    public init(
        name: String,
        description: String,
        kind: ToolKind = .embedded,
        category: String = "general",
        inputSchema: JSONValue,
        outputSchema: JSONValue? = nil,
        safety: ToolSafetyMetadata,
        timeoutMs: Int? = nil,
        idempotency: ToolIdempotencyHint,
        tags: [String] = [],
        operationArgumentKey: String? = "operation",
        defaultOperationName: String? = nil,
        operations: [ToolOperationSpec] = []
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.category = category
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.safety = safety
        self.timeoutMs = timeoutMs
        self.idempotency = idempotency
        self.tags = tags
        self.operationArgumentKey = operationArgumentKey
        self.defaultOperationName = defaultOperationName
        self.operations = operations
    }
}

public struct ProviderToolSchema: Sendable, Equatable {
    public let providerID: String
    public let toolName: String
    public let payload: JSONValue

    public init(providerID: String, toolName: String, payload: JSONValue) {
        self.providerID = providerID
        self.toolName = toolName
        self.payload = payload
    }
}

public protocol ProviderToolSchemaAdapter: Sendable {
    var providerID: String { get }
    func schema(for tool: ToolSpec) -> ProviderToolSchema
}

public enum ToolSchemaAdapterFactory {
    public static func adapter(for providerID: String) -> any ProviderToolSchemaAdapter {
        switch providerID {
        case "openai":
            return OpenAIToolSchemaAdapter()
        case "anthropic":
            return AnthropicToolSchemaAdapter()
        case "ollama":
            return OllamaToolSchemaAdapter()
        default:
            return GenericToolSchemaAdapter(providerID: providerID)
        }
    }
}

private struct GenericToolSchemaAdapter: ProviderToolSchemaAdapter {
    let providerID: String

    func schema(for tool: ToolSpec) -> ProviderToolSchema {
        ProviderToolSchema(
            providerID: providerID,
            toolName: tool.name,
            payload: .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "input_schema": tool.inputSchema,
                "output_schema": tool.outputSchema ?? .null,
                "tags": .array(tool.tags.map(JSONValue.string)),
            ])
        )
    }
}

private struct OpenAIToolSchemaAdapter: ProviderToolSchemaAdapter {
    let providerID = "openai"

    func schema(for tool: ToolSpec) -> ProviderToolSchema {
        ProviderToolSchema(
            providerID: providerID,
            toolName: tool.name,
            payload: .object([
                "type": .string("function"),
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parameters": tool.inputSchema,
                "strict": .bool(false),
            ])
        )
    }
}

private struct AnthropicToolSchemaAdapter: ProviderToolSchemaAdapter {
    let providerID = "anthropic"

    func schema(for tool: ToolSpec) -> ProviderToolSchema {
        ProviderToolSchema(
            providerID: providerID,
            toolName: tool.name,
            payload: .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "input_schema": tool.inputSchema,
            ])
        )
    }
}

private struct OllamaToolSchemaAdapter: ProviderToolSchemaAdapter {
    let providerID = "ollama"

    func schema(for tool: ToolSpec) -> ProviderToolSchema {
        ProviderToolSchema(
            providerID: providerID,
            toolName: tool.name,
            payload: .object([
                "type": .string("function"),
                "function": .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "parameters": tool.inputSchema,
                ]),
            ])
        )
    }
}

enum ToolInvocationParser {
    static func parseAction(from content: String) throws -> ModelAction {
        let normalized = stripThinkingBlocks(from: content).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw AshexError.model("Model returned an empty action payload")
        }

        let candidate = extractJSONObjectString(from: normalized) ?? normalized
        let envelope = try JSONDecoder().decode(ToolActionEnvelope.self, from: Data(candidate.utf8))
        return try envelope.toModelAction()
    }

    private static func extractJSONObjectString(from content: String) -> String? {
        let trimmed = stripThinkingBlocks(from: content).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            return trimmed
        }

        if let fencedRange = trimmed.range(of: "```") {
            let afterFence = trimmed[fencedRange.upperBound...]
            let withoutLanguage = afterFence.hasPrefix("json")
                ? afterFence.dropFirst(4)
                : afterFence
            if let closingFence = withoutLanguage.range(of: "```") {
                let inner = withoutLanguage[..<closingFence.lowerBound]
                let candidate = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.hasPrefix("{"), candidate.hasSuffix("}") {
                    return candidate
                }
            }
        }

        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start < end else {
            return nil
        }
        let candidate = String(trimmed[start...end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.hasPrefix("{") && candidate.hasSuffix("}") ? candidate : nil
    }

    private static func stripThinkingBlocks(from content: String) -> String {
        content.replacingOccurrences(
            of: #"<think>[\s\S]*?</think>"#,
            with: "",
            options: .regularExpression
        )
    }
}

enum ToolResultMessageFormatter {
    static func completed(call: ToolCallRequest, result: ToolContent) -> String {
        render(
            call: call,
            status: "completed",
            output: result.displayText,
            structuredOutput: structuredOutputValue(for: result),
            error: nil
        )
    }

    static func failure(call: ToolCallRequest, error: String) -> String {
        render(call: call, status: "failed", output: nil, structuredOutput: nil, error: error)
    }

    static func denied(call: ToolCallRequest, reason: String) -> String {
        render(call: call, status: "denied", output: nil, structuredOutput: nil, error: reason)
    }

    static func blocked(call: ToolCallRequest, reason: String) -> String {
        render(call: call, status: "blocked", output: nil, structuredOutput: nil, error: reason)
    }

    private static func render(
        call: ToolCallRequest,
        status: String,
        output: String?,
        structuredOutput: JSONValue?,
        error: String?
    ) -> String {
        let prettyStructuredOutput = structuredOutput?.prettyPrinted
        var lines = [
            "[tool_result]",
            "tool \(call.toolName)",
            "status \(status)",
        ]

        if let operation = call.arguments["operation"]?.stringValue, !operation.isEmpty {
            lines.append("operation \(operation)")
        }

        if let output,
           !output.isEmpty,
           prettyStructuredOutput?.trimmingCharacters(in: .whitespacesAndNewlines) != output.trimmingCharacters(in: .whitespacesAndNewlines) {
            lines.append("output:")
            lines.append(output)
        }

        if let prettyStructuredOutput {
            lines.append("structured_output:")
            lines.append(prettyStructuredOutput)
        }

        if let error, !error.isEmpty {
            lines.append("error:")
            lines.append(error)
        }

        return lines.joined(separator: "\n")
    }

    private static func structuredOutputValue(for content: ToolContent) -> JSONValue? {
        if case .structured(let value) = content {
            return value
        }
        return nil
    }
}

extension ToolArgumentContract {
    fileprivate func jsonSchema() -> JSONValue {
        var schema: JSONObject = [
            "type": .string(type.rawValue),
            "description": .string(description),
        ]
        if !enumValues.isEmpty {
            schema["enum"] = .array(enumValues.map(JSONValue.string))
        }
        return .object(schema)
    }
}

extension ToolOperationContract {
    func toSpec(tags: [String]) -> ToolOperationSpec {
        let requiresApproval = approval != nil
        return ToolOperationSpec(
            name: name,
            description: description,
            inputSchema: ToolSpecSchemaBuilder.makeInputSchema(
                arguments: arguments,
                operationArgumentKey: nil,
                operationName: nil
            ),
            safety: .init(
                requiresApproval: requiresApproval,
                isReadOnly: !mutatesWorkspace,
                requiresNetwork: requiresNetwork,
                risk: approval?.risk
            ),
            timeoutMs: nil,
            idempotency: mutatesWorkspace ? .sideEffecting : .readOnly,
            tags: tags
        )
    }
}

enum ToolSpecSchemaBuilder {
    static func makeInputSchema(
        arguments: [ToolArgumentContract],
        operationArgumentKey: String?,
        operationName: String?
    ) -> JSONValue {
        var properties: JSONObject = [:]
        var required: [JSONValue] = []

        if let operationArgumentKey, let operationName {
            properties[operationArgumentKey] = .object([
                "type": .string("string"),
                "enum": .array([.string(operationName)]),
                "description": .string("Operation selector"),
            ])
            required.append(.string(operationArgumentKey))
        }

        for argument in arguments {
            properties[argument.name] = argument.jsonSchema()
            if argument.required {
                required.append(.string(argument.name))
            }
        }

        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required),
            "additionalProperties": .bool(false),
        ])
    }
}

extension ToolSchema {
    init(spec: ToolSpec) {
        self.init(
            name: spec.name,
            description: spec.description,
            kind: spec.kind,
            category: spec.category,
            operationArgumentKey: spec.operationArgumentKey,
            defaultOperationName: spec.defaultOperationName,
            operations: spec.operations.map {
                ToolOperationContract(
                    name: $0.name,
                    description: $0.description,
                    mutatesWorkspace: !$0.safety.isReadOnly,
                    requiresNetwork: $0.safety.requiresNetwork,
                    progressSummary: nil,
                    approval: $0.safety.requiresApproval && $0.safety.risk != nil
                        ? .init(risk: $0.safety.risk ?? .medium, summary: $0.description)
                        : nil,
                    arguments: []
                )
            },
            tags: spec.tags
        )
    }
}

private struct ToolActionEnvelope: Codable {
    let type: String
    let finalAnswer: String?
    let toolName: String?
    let arguments: JSONObject?

    enum CodingKeys: String, CodingKey {
        case type
        case finalAnswer = "final_answer"
        case toolName = "tool_name"
        case arguments
    }

    func toModelAction() throws -> ModelAction {
        switch type {
        case "final_answer":
            guard let finalAnswer else {
                throw AshexError.model("Model returned final_answer without final_answer text")
            }
            return .finalAnswer(finalAnswer)
        case "tool_call":
            guard let toolName, let arguments else {
                throw AshexError.model("Model returned tool_call without tool_name and arguments")
            }
            return .toolCall(.init(
                toolName: ToolCallArgumentNormalizer.canonicalToolName(for: toolName),
                arguments: ToolCallArgumentNormalizer.normalize(arguments: arguments, for: toolName)
            ))
        default:
            throw AshexError.model("Unsupported model action type: \(type)")
        }
    }
}
