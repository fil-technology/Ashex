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

private enum ModelPromptRenderer {
    static func renderPrompt(for context: ModelContext) -> String {
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
        - Do not call tools for greetings, casual chat, or questions that can be answered without workspace state.
        - Only call filesystem, git, or shell when the user is asking about files, wants you to inspect project state, or explicitly asks you to run something.
        - If a tool result already contains the needed information, prefer answering directly.
        - Keep final answers concise and useful.
        - Tool arguments must be valid JSON objects.
        - When returning a tool_call, include every argument key from the schema and use null for unused keys.
        - For filesystem tool calls, always use the `operation` field with one of:
          `read_text_file`, `write_text_file`, `replace_in_file`, `list_directory`, `create_directory`, `delete_path`, `move_path`, `copy_path`, `file_info`, `find_files`, `search_text`.
        - For git tool calls, always use the `operation` field with one of:
          `status`, `current_branch`, `diff_unstaged`, `diff_staged`, `log`, `show_commit`.
        - For shell tool calls, always send `command` and optional `timeout_seconds`.

        Canonical tool-call examples:
        {"type":"tool_call","final_answer":null,"tool_name":"filesystem","arguments":{"operation":"list_directory","path":"."}}
        {"type":"tool_call","final_answer":null,"tool_name":"filesystem","arguments":{"operation":"read_text_file","path":"README.md"}}
        {"type":"tool_call","final_answer":null,"tool_name":"filesystem","arguments":{"operation":"search_text","path":"Sources","query":"ApprovalPolicy","max_results":20}}
        {"type":"tool_call","final_answer":null,"tool_name":"git","arguments":{"operation":"status","limit":null,"commit":null}}
        {"type":"tool_call","final_answer":null,"tool_name":"shell","arguments":{"command":"ls -la","timeout_seconds":30}}

        Available tools:
        \(toolBlock)

        Conversation transcript:
        \(transcript)
        """
    }

    static let responseSchema: JSONObject = [
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
                "type": .string("object"),
                "properties": .object([
                    "operation": .object([
                        "type": .array([.string("string"), .string("null")]),
                    ]),
                    "path": .object([
                        "type": .array([.string("string"), .string("null")]),
                    ]),
                    "content": .object([
                        "type": .array([.string("string"), .string("null")]),
                    ]),
                    "source_path": .object([
                        "type": .array([.string("string"), .string("null")]),
                    ]),
                    "destination_path": .object([
                        "type": .array([.string("string"), .string("null")]),
                    ]),
                    "query": .object([
                        "type": .array([.string("string"), .string("null")]),
                    ]),
                    "max_results": .object([
                        "type": .array([.string("number"), .string("null")]),
                    ]),
                    "old_text": .object([
                        "type": .array([.string("string"), .string("null")]),
                    ]),
                    "new_text": .object([
                        "type": .array([.string("string"), .string("null")]),
                    ]),
                    "replace_all": .object([
                        "type": .array([.string("boolean"), .string("null")]),
                    ]),
                    "limit": .object([
                        "type": .array([.string("number"), .string("null")]),
                    ]),
                    "commit": .object([
                        "type": .array([.string("string"), .string("null")]),
                    ]),
                    "create_directories": .object([
                        "type": .array([.string("boolean"), .string("null")]),
                    ]),
                    "command": .object([
                        "type": .array([.string("string"), .string("null")]),
                    ]),
                    "timeout_seconds": .object([
                        "type": .array([.string("number"), .string("null")]),
                    ]),
                ]),
                "required": .array([
                    .string("operation"),
                    .string("path"),
                    .string("content"),
                    .string("source_path"),
                    .string("destination_path"),
                    .string("query"),
                    .string("max_results"),
                    .string("old_text"),
                    .string("new_text"),
                    .string("replace_all"),
                    .string("limit"),
                    .string("commit"),
                    .string("create_directories"),
                    .string("command"),
                    .string("timeout_seconds"),
                ]),
                "additionalProperties": .bool(false),
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
            input: ModelPromptRenderer.renderPrompt(for: context),
            store: false,
            text: .init(format: .init(
                type: "json_schema",
                name: "ashex_model_action",
                strict: true,
                schema: ModelPromptRenderer.responseSchema
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
}

public struct OllamaModelConfiguration: Sendable {
    public let model: String
    public let baseURL: URL

    public init(
        model: String = "llama3.2",
        baseURL: URL = URL(string: "http://localhost:11434/api/chat")!
    ) {
        self.model = model
        self.baseURL = baseURL
    }
}

public struct AnthropicModelConfiguration: Sendable {
    public let apiKey: String
    public let model: String
    public let baseURL: URL

    public init(
        apiKey: String,
        model: String = "claude-sonnet-4-20250514",
        baseURL: URL = URL(string: "https://api.anthropic.com/v1/messages")!
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
    }
}

public struct OllamaChatModelAdapter: ModelAdapter {
    public let name: String

    private let configuration: OllamaModelConfiguration
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        configuration: OllamaModelConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
        self.name = "ollama-chat:\(configuration.model)"
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func nextAction(for context: ModelContext) async throws -> ModelAction {
        let requestBody = OllamaChatRequest(
            model: configuration.model,
            messages: [
                .init(role: "user", content: ModelPromptRenderer.renderPrompt(for: context)),
            ],
            format: ModelPromptRenderer.responseSchema,
            options: [
                "temperature": .number(0),
            ],
            stream: false
        )

        var request = URLRequest(url: configuration.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(requestBody)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AshexError.model("Ollama request did not return an HTTP response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = try? decoder.decode(OllamaErrorEnvelope.self, from: data)
            throw AshexError.model(apiError?.error ?? "Ollama request failed with status \(httpResponse.statusCode)")
        }

        let envelope = try decoder.decode(OllamaChatResponseEnvelope.self, from: data)
        let content = envelope.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw AshexError.model("Ollama response did not include structured output content")
        }

        let parsed = try decoder.decode(ModelActionEnvelope.self, from: Data(content.utf8))
        return try parsed.toModelAction()
    }
}

public struct AnthropicMessagesModelAdapter: ModelAdapter {
    public let name: String

    private let configuration: AnthropicModelConfiguration
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        configuration: AnthropicModelConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
        self.name = "anthropic-messages:\(configuration.model)"
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func nextAction(for context: ModelContext) async throws -> ModelAction {
        let requestBody = AnthropicMessagesRequest(
            model: configuration.model,
            maxTokens: 1200,
            system: "You are Ashex, a local single-agent runtime. Reply with exactly one JSON object matching the requested schema and nothing else.",
            messages: [
                .init(role: "user", content: ModelPromptRenderer.renderPrompt(for: context))
            ]
        )

        var request = URLRequest(url: configuration.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try encoder.encode(requestBody)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AshexError.model("Anthropic request did not return an HTTP response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = try? decoder.decode(AnthropicErrorEnvelope.self, from: data)
            throw AshexError.model(apiError?.error.message ?? "Anthropic request failed with status \(httpResponse.statusCode)")
        }

        let envelope = try decoder.decode(AnthropicMessagesResponseEnvelope.self, from: data)
        let content = envelope.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw AshexError.model("Anthropic response did not include structured output text")
        }

        let parsed = try decoder.decode(ModelActionEnvelope.self, from: Data(content.utf8))
        return try parsed.toModelAction()
    }
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

        if prompt.contains("git status") || prompt.contains("repo status") {
            return .toolCall(.init(toolName: "git", arguments: [
                "operation": .string("status"),
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

private struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [Message]
    let format: JSONObject
    let options: JSONObject?
    let stream: Bool

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct AnthropicMessagesRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
    }

    struct Message: Encodable {
        let role: String
        let content: String
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

private struct OllamaChatResponseEnvelope: Decodable {
    let message: Message

    struct Message: Decodable {
        let content: String
    }
}

private struct AnthropicMessagesResponseEnvelope: Decodable {
    let content: [ContentItem]

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

private struct OllamaErrorEnvelope: Decodable {
    let error: String
}

private struct AnthropicErrorEnvelope: Decodable {
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
            return .toolCall(.init(
                toolName: ToolCallArgumentNormalizer.canonicalToolName(for: toolName),
                arguments: ToolCallArgumentNormalizer.normalize(arguments: arguments, for: toolName)
            ))
        default:
            throw AshexError.model("Unsupported model action type: \(type)")
        }
    }
}

private enum ToolCallArgumentNormalizer {
    static func canonicalToolName(for toolName: String) -> String {
        switch toolName.lowercased() {
        case "filesystem", "file_system", "files", "file":
            return "filesystem"
        case "git", "repo", "repository":
            return "git"
        case "shell", "terminal", "command":
            return "shell"
        default:
            return toolName
        }
    }

    static func normalize(arguments: JSONObject, for toolName: String) -> JSONObject {
        switch canonicalToolName(for: toolName) {
        case "filesystem":
            return normalizeFilesystem(arguments: arguments)
        case "git":
            return normalizeGit(arguments: arguments)
        case "shell":
            return normalizeShell(arguments: arguments)
        default:
            return arguments
        }
    }

    private static func normalizeFilesystem(arguments: JSONObject) -> JSONObject {
        var normalized = arguments
        if normalized["operation"] == nil,
           let action = string(in: arguments, keys: ["action", "mode", "intent"])?.lowercased() {
            switch action {
            case "list", "ls", "list_files", "list_directory", "list_dir":
                normalized["operation"] = .string("list_directory")
            case "read", "read_file", "read_text", "cat":
                normalized["operation"] = .string("read_text_file")
            case "write", "write_file", "write_text":
                normalized["operation"] = .string("write_text_file")
            case "replace", "replace_text", "replace_in_file", "edit":
                normalized["operation"] = .string("replace_in_file")
            case "mkdir", "create_directory", "create_dir":
                normalized["operation"] = .string("create_directory")
            case "delete", "remove", "delete_path", "rm":
                normalized["operation"] = .string("delete_path")
            case "move", "rename", "move_path", "mv":
                normalized["operation"] = .string("move_path")
            case "copy", "copy_path", "cp":
                normalized["operation"] = .string("copy_path")
            case "info", "stat", "file_info":
                normalized["operation"] = .string("file_info")
            case "find", "find_files":
                normalized["operation"] = .string("find_files")
            case "search", "search_text", "grep":
                normalized["operation"] = .string("search_text")
            default:
                break
            }
        }
        normalized.removeValue(forKey: "action")
        normalized.removeValue(forKey: "mode")
        normalized.removeValue(forKey: "intent")

        if normalized["path"] == nil,
           let path = string(in: arguments, keys: ["file", "filepath", "directory", "dir", "target"]) {
            normalized["path"] = .string(path)
        }
        normalized.removeValue(forKey: "file")
        normalized.removeValue(forKey: "filepath")
        normalized.removeValue(forKey: "directory")
        normalized.removeValue(forKey: "dir")
        normalized.removeValue(forKey: "target")

        if normalized["source_path"] == nil,
           let sourcePath = string(in: arguments, keys: ["source", "from", "old_path"]) {
            normalized["source_path"] = .string(sourcePath)
        }
        normalized.removeValue(forKey: "source")
        normalized.removeValue(forKey: "from")
        normalized.removeValue(forKey: "old_path")

        if normalized["destination_path"] == nil,
           let destinationPath = string(in: arguments, keys: ["destination", "dest", "to", "new_path"]) {
            normalized["destination_path"] = .string(destinationPath)
        }
        normalized.removeValue(forKey: "destination")
        normalized.removeValue(forKey: "dest")
        normalized.removeValue(forKey: "to")
        normalized.removeValue(forKey: "new_path")

        if normalized["operation"]?.stringValue == "list_directory", normalized["path"] == nil {
            normalized["path"] = .string(".")
        }

        if normalized["content"] == nil,
           let content = string(in: arguments, keys: ["text", "body", "data", "contents"]) {
            normalized["content"] = .string(content)
        }
        normalized.removeValue(forKey: "text")
        normalized.removeValue(forKey: "body")
        normalized.removeValue(forKey: "data")
        normalized.removeValue(forKey: "contents")

        if normalized["old_text"] == nil,
           let oldText = string(in: arguments, keys: ["old", "find", "search"]) {
            normalized["old_text"] = .string(oldText)
        }
        normalized.removeValue(forKey: "old")

        if normalized["new_text"] == nil,
           let newText = string(in: arguments, keys: ["new", "replace", "replacement"]) {
            normalized["new_text"] = .string(newText)
        }
        normalized.removeValue(forKey: "new")
        normalized.removeValue(forKey: "replace")
        normalized.removeValue(forKey: "replacement")

        if normalized["query"] == nil,
           let query = string(in: arguments, keys: ["needle", "pattern", "name"]) {
            normalized["query"] = .string(query)
        }
        normalized.removeValue(forKey: "needle")
        normalized.removeValue(forKey: "pattern")
        normalized.removeValue(forKey: "name")

        if normalized["max_results"] == nil,
           let limit = arguments["limit"]?.intValue ?? arguments["max"]?.intValue {
            normalized["max_results"] = .number(Double(limit))
        }
        normalized.removeValue(forKey: "max")

        if normalized["replace_all"] == nil,
           let replaceAll = arguments["all"] {
            normalized["replace_all"] = replaceAll
        }
        normalized.removeValue(forKey: "all")

        if normalized["operation"]?.stringValue == "write_text_file",
           normalized["create_directories"] == nil {
            normalized["create_directories"] = .bool(true)
        }

        return normalized
    }

    private static func normalizeGit(arguments: JSONObject) -> JSONObject {
        var normalized = arguments
        if normalized["operation"] == nil,
           let action = string(in: arguments, keys: ["action", "mode", "intent"])?.lowercased() {
            switch action {
            case "status":
                normalized["operation"] = .string("status")
            case "branch", "current_branch", "head":
                normalized["operation"] = .string("current_branch")
            case "diff", "diff_unstaged", "unstaged_diff":
                normalized["operation"] = .string("diff_unstaged")
            case "diff_staged", "staged_diff", "cached_diff":
                normalized["operation"] = .string("diff_staged")
            case "log", "history":
                normalized["operation"] = .string("log")
            case "show", "show_commit":
                normalized["operation"] = .string("show_commit")
            default:
                break
            }
        }
        normalized.removeValue(forKey: "action")
        normalized.removeValue(forKey: "mode")
        normalized.removeValue(forKey: "intent")

        if normalized["commit"] == nil,
           let commit = string(in: arguments, keys: ["sha", "hash", "revision", "ref"]) {
            normalized["commit"] = .string(commit)
        }
        normalized.removeValue(forKey: "sha")
        normalized.removeValue(forKey: "hash")
        normalized.removeValue(forKey: "revision")
        normalized.removeValue(forKey: "ref")

        if normalized["limit"] == nil,
           let limit = arguments["count"]?.intValue ?? arguments["max_results"]?.intValue ?? arguments["max"]?.intValue {
            normalized["limit"] = .number(Double(limit))
        }
        normalized.removeValue(forKey: "count")
        normalized.removeValue(forKey: "max_results")
        normalized.removeValue(forKey: "max")
        return normalized
    }

    private static func normalizeShell(arguments: JSONObject) -> JSONObject {
        var normalized = arguments
        if normalized["command"] == nil,
           let command = string(in: arguments, keys: ["cmd", "script", "input"]) {
            normalized["command"] = .string(command)
        }
        normalized.removeValue(forKey: "cmd")
        normalized.removeValue(forKey: "script")
        normalized.removeValue(forKey: "input")
        if normalized["timeout_seconds"] == nil,
           let timeout = arguments["timeout"]?.intValue ?? arguments["timeoutSecs"]?.intValue {
            normalized["timeout_seconds"] = .number(Double(timeout))
        }
        normalized.removeValue(forKey: "timeout")
        normalized.removeValue(forKey: "timeoutSecs")
        return normalized
    }

    private static func string(in arguments: JSONObject, keys: [String]) -> String? {
        for key in keys {
            if let value = arguments[key]?.stringValue, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
