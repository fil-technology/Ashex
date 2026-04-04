import Foundation

public struct ToolSchema: Sendable {
    public let name: String
    public let description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

public struct ModelContext: Sendable {
    public let thread: ThreadRecord
    public let run: RunRecord
    public let messages: [MessageRecord]
    public let availableTools: [ToolSchema]

    public init(thread: ThreadRecord, run: RunRecord, messages: [MessageRecord], availableTools: [ToolSchema]) {
        self.thread = thread
        self.run = run
        self.messages = messages
        self.availableTools = availableTools
    }
}

public struct ToolCallRequest: Codable, Sendable, Equatable {
    public let toolName: String
    public let arguments: JSONObject

    public init(toolName: String, arguments: JSONObject) {
        self.toolName = toolName
        self.arguments = arguments
    }
}

public enum ModelAction: Codable, Sendable, Equatable {
    case finalAnswer(String)
    case toolCall(ToolCallRequest)
}

public protocol ModelAdapter: Sendable {
    var name: String { get }
    func nextAction(for context: ModelContext) async throws -> ModelAction
}

public struct OpenAIModelConfiguration: Sendable {
    public let apiKey: String
    public let model: String
    public let baseURL: URL

    public init(
        apiKey: String,
        model: String = "gpt-5.4-mini",
        baseURL: URL = URL(string: "https://api.openai.com/v1/responses")!
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
    }
}

public struct OpenAIResponsesModelAdapter: ModelAdapter {
    public let name: String

    private let configuration: OpenAIModelConfiguration
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        configuration: OpenAIModelConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
        self.name = "openai-responses:\(configuration.model)"
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func nextAction(for context: ModelContext) async throws -> ModelAction {
        let requestBody = OpenAIResponsesRequest(
            model: configuration.model,
            input: Self.renderPrompt(for: context),
            store: false,
            text: .init(format: .init(
                type: "json_schema",
                name: "ashex_model_action",
                strict: true,
                schema: Self.responseSchema
            ))
        )

        var request = URLRequest(url: configuration.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encoder.encode(requestBody)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AshexError.model("OpenAI request did not return an HTTP response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = try? decoder.decode(OpenAIErrorEnvelope.self, from: data)
            throw AshexError.model(apiError?.error.message ?? "OpenAI request failed with status \(httpResponse.statusCode)")
        }

        let envelope = try decoder.decode(OpenAIResponseEnvelope.self, from: data)
        guard let outputText = envelope.outputText, !outputText.isEmpty else {
            throw AshexError.model("OpenAI response did not include structured output text")
        }

        let parsed = try decoder.decode(ModelActionEnvelope.self, from: Data(outputText.utf8))
        return try parsed.toModelAction()
    }

    private static func renderPrompt(for context: ModelContext) -> String {
        let toolBlock = context.availableTools
            .map { "- \($0.name): \($0.description)" }
            .joined(separator: "\n")

        let transcript = context.messages.map { message in
            let role = message.role.rawValue.uppercased()
            return "[\(role)]\n\(message.content)"
        }.joined(separator: "\n\n")

        return """
        You are Ashex, a local single-agent runtime.

        Decide the next action for the current loop iteration.

        You must return exactly one JSON object matching the provided schema:
        - If the task is complete, return `type = "final_answer"` and fill `final_answer`.
        - If a tool is needed, return `type = "tool_call"` and fill `tool_name` and `arguments`.

        Rules:
        - Use only the tools listed below.
        - Never invent tools.
        - If a tool result already contains the needed information, prefer answering directly.
        - Keep final answers concise and useful.
        - Tool arguments must be valid JSON objects.

        Available tools:
        \(toolBlock)

        Conversation transcript:
        \(transcript)
        """
    }

    private static let responseSchema: JSONObject = [
        "type": .string("object"),
        "properties": .object([
            "type": .object([
                "type": .string("string"),
                "enum": .array([.string("final_answer"), .string("tool_call")]),
            ]),
            "final_answer": .object([
                "type": .array([.string("string"), .string("null")]),
            ]),
            "tool_name": .object([
                "type": .array([.string("string"), .string("null")]),
            ]),
            "arguments": .object([
                "type": .array([.string("object"), .string("null")]),
                "additionalProperties": .bool(true),
            ]),
        ]),
        "required": .array([
            .string("type"),
            .string("final_answer"),
            .string("tool_name"),
            .string("arguments"),
        ]),
        "additionalProperties": .bool(false),
    ]
}

public struct MockModelAdapter: ModelAdapter {
    public let name = "mock-rule-based"

    public init() {}

    public func nextAction(for context: ModelContext) async throws -> ModelAction {
        guard let lastMessage = context.messages.last else {
            throw AshexError.model("Conversation is empty")
        }

        if lastMessage.role == .tool {
            return .finalAnswer("Tool execution finished.\n\n\(lastMessage.content)")
        }

        let prompt = lastMessage.content.lowercased()

        if prompt.contains("list") && prompt.contains("file") {
            return .toolCall(.init(toolName: "filesystem", arguments: [
                "operation": .string("list_directory"),
                "path": .string("."),
            ]))
        }

        if let command = Self.extractPrefixedValue(from: lastMessage.content, prefixes: ["shell:", "run:"]) {
            return .toolCall(.init(toolName: "shell", arguments: [
                "command": .string(command),
                "timeout_seconds": .number(30),
            ]))
        }

        if let path = Self.extractPath(after: "read", in: lastMessage.content) {
            return .toolCall(.init(toolName: "filesystem", arguments: [
                "operation": .string("read_text_file"),
                "path": .string(path),
            ]))
        }

        if let (path, content) = Self.extractWriteInstruction(from: lastMessage.content) {
            return .toolCall(.init(toolName: "filesystem", arguments: [
                "operation": .string("write_text_file"),
                "path": .string(path),
                "content": .string(content),
                "create_directories": .bool(true),
            ]))
        }

        if let path = Self.extractPath(after: "mkdir", in: lastMessage.content) {
            return .toolCall(.init(toolName: "filesystem", arguments: [
                "operation": .string("create_directory"),
                "path": .string(path),
            ]))
        }

        return .finalAnswer("""
        Mock adapter is active. Try prompts like:
        - list files
        - read path/to/file.txt
        - write notes/todo.txt :: buy milk
        - mkdir notes/archive
        - shell: ls -la
        """)
    }

    private static func extractPrefixedValue(from input: String, prefixes: [String]) -> String? {
        for prefix in prefixes {
            if input.lowercased().hasPrefix(prefix),
               let range = input.range(of: prefix, options: [.caseInsensitive, .anchored]) {
                let value = input[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static func extractPath(after keyword: String, in input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(keyword.lowercased()) else { return nil }
        let remainder = trimmed.dropFirst(keyword.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? nil : remainder
    }

    private static func extractWriteInstruction(from input: String) -> (String, String)? {
        let marker = "::"
        let lowercased = input.lowercased()
        guard lowercased.hasPrefix("write "), let range = input.range(of: marker) else { return nil }
        let path = input[input.index(input.startIndex, offsetBy: 6)..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let content = input[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return (path, content)
    }
}

private struct OpenAIResponsesRequest: Encodable {
    let model: String
    let input: String
    let store: Bool
    let text: TextConfiguration

    struct TextConfiguration: Encodable {
        let format: JSONSchemaFormat
    }

    struct JSONSchemaFormat: Encodable {
        let type: String
        let name: String
        let strict: Bool
        let schema: JSONObject
    }
}

private struct OpenAIResponseEnvelope: Decodable {
    let output: [OutputItem]

    var outputText: String? {
        let chunks = output
            .flatMap(\.content)
            .compactMap { item -> String? in
                guard item.type == "output_text" else { return nil }
                return item.text
            }
        return chunks.isEmpty ? nil : chunks.joined(separator: "\n")
    }

    struct OutputItem: Decodable {
        let content: [ContentItem]
    }

    struct ContentItem: Decodable {
        let type: String
        let text: String?
    }
}

private struct OpenAIErrorEnvelope: Decodable {
    let error: APIError

    struct APIError: Decodable {
        let message: String
    }
}

private struct ModelActionEnvelope: Codable {
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
            return .toolCall(.init(toolName: toolName, arguments: arguments))
        default:
            throw AshexError.model("Unsupported model action type: \(type)")
        }
    }
}
