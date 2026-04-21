import Foundation

public struct ToolSchema: Sendable {
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
}

public struct ModelContext: Sendable {
    public let thread: ThreadRecord
    public let run: RunRecord
    public let messages: [MessageRecord]
    public let availableTools: [ToolSchema]
    public let workspaceSnapshot: WorkspaceSnapshotRecord?
    public let workingMemory: WorkingMemoryRecord?

    public init(
        thread: ThreadRecord,
        run: RunRecord,
        messages: [MessageRecord],
        availableTools: [ToolSchema],
        workspaceSnapshot: WorkspaceSnapshotRecord? = nil,
        workingMemory: WorkingMemoryRecord? = nil
    ) {
        self.thread = thread
        self.run = run
        self.messages = messages
        self.availableTools = availableTools
        self.workspaceSnapshot = workspaceSnapshot
        self.workingMemory = workingMemory
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

public struct DirectChatReplyEnvelope: Sendable, Equatable {
    public let text: String
    public let reasoningSummary: String?

    public init(text: String, reasoningSummary: String? = nil) {
        self.text = text
        self.reasoningSummary = reasoningSummary
    }
}

public protocol ModelAdapter: Sendable {
    var name: String { get }
    var providerID: String { get }
    var modelID: String { get }
    func nextAction(for context: ModelContext) async throws -> ModelAction
}

public protocol DirectChatModelAdapter: ModelAdapter {
    func directReply(history: [MessageRecord], systemPrompt: String) async throws -> String
    func directReply(history: [MessageRecord], systemPrompt: String, attachments: [InputAttachment]) async throws -> String
    func directReplyEnvelope(history: [MessageRecord], systemPrompt: String, attachments: [InputAttachment]) async throws -> DirectChatReplyEnvelope
}

public extension DirectChatModelAdapter {
    func directReply(history: [MessageRecord], systemPrompt: String, attachments: [InputAttachment]) async throws -> String {
        try await directReply(history: history, systemPrompt: systemPrompt)
    }

    func directReplyEnvelope(history: [MessageRecord], systemPrompt: String, attachments: [InputAttachment]) async throws -> DirectChatReplyEnvelope {
        let reply = try await directReply(history: history, systemPrompt: systemPrompt, attachments: attachments)
        return .init(text: reply, reasoningSummary: nil)
    }
}

public protocol AudioTranscriber: Sendable {
    func transcribeAudio(fileURL: URL) async throws -> String
}

public protocol TaskPlanningModelAdapter: ModelAdapter {
    func taskPlan(for prompt: String, taskKind: TaskKind) async throws -> TaskPlan?
}

private enum ModelPromptRenderer {
    static func responseSchema(for tools: [ToolSchema]) -> JSONObject {
        let argumentNames = Set(defaultArgumentSchemas.keys)
            .union(tools.flatMap { tool in
                tool.operations.flatMap { operation in
                    operation.arguments.map(\.name)
                }
            })
            .sorted()

        let properties = Dictionary(uniqueKeysWithValues: argumentNames.map { argumentName in
            let schema = defaultArgumentSchemas[argumentName] ?? fallbackSchema(for: argumentName)
            return (argumentName, JSONValue.object(schema))
        })

        return [
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
                    "properties": .object(properties),
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

    static func taskPlanSchema() -> JSONObject {
        [
            "type": .string("object"),
            "properties": .object([
                "steps": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "title": .object([
                                "type": .string("string"),
                            ]),
                            "phase": .object([
                                "type": .string("string"),
                                "enum": .array([
                                    .string("exploration"),
                                    .string("planning"),
                                    .string("mutation"),
                                    .string("validation"),
                                ]),
                            ]),
                        ]),
                        "required": .array([
                            .string("title"),
                            .string("phase"),
                        ]),
                        "additionalProperties": .bool(false),
                    ]),
                ]),
            ]),
            "required": .array([.string("steps")]),
            "additionalProperties": .bool(false),
        ]
    }

    private static let defaultArgumentSchemas: [String: JSONObject] = [
        "operation": nullableScalar(.string("string")),
        "path": nullableScalar(.string("string")),
        "content": nullableScalar(.string("string")),
        "message": nullableScalar(.string("string")),
        "source_path": nullableScalar(.string("string")),
        "destination_path": nullableScalar(.string("string")),
        "query": nullableScalar(.string("string")),
        "max_results": nullableScalar(.string("number")),
        "old_text": nullableScalar(.string("string")),
        "new_text": nullableScalar(.string("string")),
        "replace_all": nullableScalar(.string("boolean")),
        "limit": nullableScalar(.string("number")),
        "commit": nullableScalar(.string("string")),
        "create_directories": nullableScalar(.string("boolean")),
        "command": nullableScalar(.string("string")),
        "branch_name": nullableScalar(.string("string")),
        "start_point": nullableScalar(.string("string")),
        "initial_branch": nullableScalar(.string("string")),
        "source": nullableScalar(.string("string")),
        "remote": nullableScalar(.string("string")),
        "name": nullableScalar(.string("string")),
        "workspace": nullableScalar(.string("string")),
        "project": nullableScalar(.string("string")),
        "scheme": nullableScalar(.string("string")),
        "configuration": nullableScalar(.string("string")),
        "destination": nullableScalar(.string("string")),
        "sdk": nullableScalar(.string("string")),
        "derived_data_path": nullableScalar(.string("string")),
        "timeout_seconds": nullableScalar(.string("number")),
        "amend": nullableScalar(.string("boolean")),
        "allow_empty": nullableScalar(.string("boolean")),
        "set_upstream": nullableScalar(.string("boolean")),
        "force_with_lease": nullableScalar(.string("boolean")),
        "no_ff": nullableScalar(.string("boolean")),
        "rebase": nullableScalar(.string("boolean")),
        "directories": nullableScalar(.string("boolean")),
        "ignored": nullableScalar(.string("boolean")),
        "module": nullableScalar(.string("string")),
        "package_path": nullableScalar(.string("string")),
        "package_name": nullableScalar(.string("string")),
        "script": nullableScalar(.string("string")),
        "venv_path": nullableScalar(.string("string")),
        "test_path": nullableScalar(.string("string")),
        "python_version": nullableScalar(.string("string")),
        "package_manager": nullableScalar(.string("string")),
        "paths": [
            "type": .array([
                .string("array"),
                .string("null"),
            ]),
            "items": .object([
                "type": .string("string"),
            ]),
        ],
        "edits": [
            "type": .array([
                .string("array"),
                .string("null"),
            ]),
            "items": .object([
                "type": .string("object"),
                "properties": .object([
                    "old_text": .object(nullableScalar(.string("string"))),
                    "new_text": .object(nullableScalar(.string("string"))),
                    "replace_all": .object(nullableScalar(.string("boolean"))),
                ]),
                "required": .array([
                    .string("old_text"),
                    .string("new_text"),
                    .string("replace_all"),
                ]),
                "additionalProperties": .bool(false),
            ]),
        ],
        "args": [
            "type": .array([
                .string("array"),
                .string("null"),
            ]),
            "items": .object([
                "type": .string("string"),
            ]),
        ],
    ]

    private static func nullableScalar(_ type: JSONValue) -> JSONObject {
        [
            "type": .array([type, .string("null")]),
        ]
    }

    private static func fallbackSchema(for argumentName: String) -> JSONObject {
        if argumentName.hasSuffix("_path") || argumentName == "path" {
            return nullableScalar(.string("string"))
        }
        return nullableScalar(.string("string"))
    }
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
    public let providerID = "openai"
    public var modelID: String { configuration.model }

    private let configuration: OpenAIModelConfiguration
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let audioTranscriber: (any AudioTranscriber)?

    public init(
        configuration: OpenAIModelConfiguration,
        session: URLSession = .shared,
        audioTranscriber: (any AudioTranscriber)? = nil
    ) {
        self.configuration = configuration
        self.session = session
        self.name = "openai-responses:\(configuration.model)"
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.audioTranscriber = audioTranscriber
    }

    fileprivate static func directChatTranscript(from history: [MessageRecord]) -> String {
        history.suffix(12).map { message in
            "\(message.role.rawValue): \(message.content)"
        }.joined(separator: "\n")
    }

    public func nextAction(for context: ModelContext) async throws -> ModelAction {
        let assembly = PromptBuilder.build(for: context, provider: "openai", model: configuration.model)
        let responseSchema = ModelPromptRenderer.responseSchema(for: context.availableTools)
        let requestBody = OpenAIResponsesRequest(
            model: configuration.model,
            input: .string(assembly.combinedPrompt),
            store: false,
            text: .init(format: .init(
                type: "json_schema",
                name: "ashex_model_action",
                strict: true,
                schema: responseSchema
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

        return try ToolInvocationParser.parseAction(from: outputText)
    }
}

extension OpenAIResponsesModelAdapter: DirectChatModelAdapter {
    public func directReply(history: [MessageRecord], systemPrompt: String) async throws -> String {
        try await directReplyEnvelope(history: history, systemPrompt: systemPrompt, attachments: []).text
    }

    public func directReply(history: [MessageRecord], systemPrompt: String, attachments: [InputAttachment]) async throws -> String {
        try await directReplyEnvelope(history: history, systemPrompt: systemPrompt, attachments: attachments).text
    }

    public func directReplyEnvelope(history: [MessageRecord], systemPrompt: String, attachments: [InputAttachment]) async throws -> DirectChatReplyEnvelope {
        let multimodalInput = try await DirectChatMultimodalBuilder.openAIInput(
            history: history,
            systemPrompt: systemPrompt,
            model: configuration.model,
            attachments: attachments,
            audioTranscriber: audioTranscriber
        )
        do {
            return try await requestDirectReply(input: multimodalInput, repair: false)
        } catch let error as AshexError {
            let message = error.localizedDescription.lowercased()
            guard message.contains("did not return a reply") else { throw error }
            return try await requestDirectReply(input: multimodalInput, repair: true)
        }
    }

    private func requestDirectReply(
        input: JSONValue,
        repair: Bool
    ) async throws -> DirectChatReplyEnvelope {
        let repairSuffix = repair
            ? "\n\nYour previous reply was empty. Reply again with a non-empty `reply` string."
            : ""
        let requestBody = OpenAIResponsesRequest(
            model: configuration.model,
            input: DirectChatMultimodalBuilder.openAIRepairAdjustedInput(input, repairSuffix: repairSuffix),
            store: false,
            text: .init(format: .init(
                type: "json_schema",
                name: "direct_chat",
                strict: true,
                schema: [
                    "type": .string("object"),
                    "properties": .object([
                        "reply": .object([
                            "type": .string("string")
                        ])
                    ]),
                    "required": .array([.string("reply")]),
                    "additionalProperties": .bool(false),
                ]
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
        guard
            let outputText = try decoder.decode(OpenAIResponseEnvelope.self, from: data).outputText,
            let reply = DirectChatReplyParser.parseReply(from: outputText)
        else {
            throw AshexError.model("OpenAI direct chat did not return a reply")
        }
        return .init(text: reply, reasoningSummary: ReasoningSummaryExtractor.summary(fromExposedThinkingIn: outputText))
    }
}

extension OpenAIResponsesModelAdapter: TaskPlanningModelAdapter {
    public func taskPlan(for prompt: String, taskKind: TaskKind) async throws -> TaskPlan? {
        let requestBody = OpenAIResponsesRequest(
            model: configuration.model,
            input: .string("""
            You are planning a software task for an agent.
            Break the request into a short, concrete ordered task list.
            Return 2 to 6 steps only when the work is genuinely multi-step.
            Use phases from: exploration, planning, mutation, validation.
            Keep each title concise and action-oriented.
            Task kind: \(taskKind.rawValue)

            User request:
            \(prompt)
            """),
            store: false,
            text: .init(format: .init(
                type: "json_schema",
                name: "ashex_task_plan",
                strict: true,
                schema: ModelPromptRenderer.taskPlanSchema()
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
        guard let outputText = try decoder.decode(OpenAIResponseEnvelope.self, from: data).outputText, !outputText.isEmpty else {
            throw AshexError.model("OpenAI planning response did not include structured output text")
        }
        return try TaskPlanParser.parsePlan(from: outputText, fallbackTaskKind: taskKind)
    }
}

public struct OllamaModelConfiguration: Sendable {
    public let model: String
    public let baseURL: URL
    public let requestTimeoutSeconds: Int

    public init(
        model: String = "llama3.2",
        baseURL: URL = URL(string: "http://localhost:11434/api/chat")!,
        requestTimeoutSeconds: Int = 180
    ) {
        self.model = model
        self.baseURL = baseURL
        self.requestTimeoutSeconds = requestTimeoutSeconds
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

public struct DFlashServerModelConfiguration: Sendable {
    public let model: String
    public let baseURL: URL
    public let requestTimeoutSeconds: Int
    public let draftModel: String?

    public init(
        model: String,
        baseURL: URL = URL(string: "http://127.0.0.1:8000")!,
        requestTimeoutSeconds: Int = 120,
        draftModel: String? = nil
    ) {
        self.model = model
        self.baseURL = baseURL
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.draftModel = draftModel
    }

    var chatCompletionsURL: URL {
        baseURL.appending(path: "v1/chat/completions")
    }
}

public struct DFlashServerModelAdapter: ModelAdapter {
    public let name: String
    public let providerID = "dflash"
    public var modelID: String { configuration.model }

    private let configuration: DFlashServerModelConfiguration
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        configuration: DFlashServerModelConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
        self.name = "dflash-server:\(configuration.model)"
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    fileprivate static func directChatMessages(from history: [MessageRecord], systemPrompt: String) -> [DFlashChatCompletionsRequest.Message] {
        let conversation = history.suffix(12).map { message in
            DFlashChatCompletionsRequest.Message(
                role: message.role == .assistant ? "assistant" : "user",
                content: message.content
            )
        }
        return [.init(role: "system", content: systemPrompt)] + conversation
    }

    public func nextAction(for context: ModelContext) async throws -> ModelAction {
        throw AshexError.model("DFlash currently supports direct chat only in Ashex. Use Ollama, OpenAI, or Anthropic for tool-driven agent runs.")
    }
}

extension DFlashServerModelAdapter: DirectChatModelAdapter {
    public func directReply(history: [MessageRecord], systemPrompt: String) async throws -> String {
        try await directReplyEnvelope(history: history, systemPrompt: systemPrompt, attachments: []).text
    }

    public func directReplyEnvelope(history: [MessageRecord], systemPrompt: String, attachments _: [InputAttachment]) async throws -> DirectChatReplyEnvelope {
        do {
            return try await requestDirectReply(history: history, systemPrompt: systemPrompt, repair: false)
        } catch let error as AshexError {
            let message = error.localizedDescription.lowercased()
            guard message.contains("did not return a reply") else { throw error }
            return try await requestDirectReply(history: history, systemPrompt: systemPrompt, repair: true)
        }
    }

    private func requestDirectReply(
        history: [MessageRecord],
        systemPrompt: String,
        repair: Bool
    ) async throws -> DirectChatReplyEnvelope {
        let repairInstruction = repair
            ? "\n\nYour previous reply was empty or included internal reasoning. Reply again with only the final user-facing answer."
            : ""
        var request = URLRequest(url: configuration.chatCompletionsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(configuration.requestTimeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(DFlashChatCompletionsRequest(
            model: configuration.model,
            messages: Self.directChatMessages(from: history, systemPrompt: systemPrompt + repairInstruction),
            temperature: 0.2,
            stream: false
        ))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AshexError.model("DFlash request did not return an HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = try? decoder.decode(DFlashErrorEnvelope.self, from: data)
            throw AshexError.model(apiError?.error.message ?? "DFlash request failed with status \(httpResponse.statusCode)")
        }

        let envelope = try decoder.decode(DFlashChatCompletionsResponseEnvelope.self, from: data)
        guard
            let content = envelope.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
            let reply = DirectChatReplyParser.parseReply(from: content)
        else {
            throw AshexError.model("DFlash direct chat did not return a reply")
        }
        return .init(text: reply, reasoningSummary: ReasoningSummaryExtractor.summary(fromExposedThinkingIn: content))
    }
}

public struct OllamaChatModelAdapter: ModelAdapter {
    public let name: String
    public let providerID = "ollama"
    public var modelID: String { configuration.model }

    private let configuration: OllamaModelConfiguration
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let audioTranscriber: (any AudioTranscriber)?

    public init(
        configuration: OllamaModelConfiguration,
        session: URLSession = .shared,
        audioTranscriber: (any AudioTranscriber)? = nil
    ) {
        self.configuration = configuration
        self.session = session
        self.name = "ollama-chat:\(configuration.model)"
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.audioTranscriber = audioTranscriber
    }

    fileprivate static func directChatMessages(from history: [MessageRecord], systemPrompt: String) -> [OllamaChatRequest.Message] {
        let conversation = history.suffix(12).map { message in
            OllamaChatRequest.Message(
                role: message.role == .assistant ? "assistant" : "user",
                content: message.content
            )
        }
        return [.init(role: "system", content: systemPrompt)] + conversation
    }

    public func nextAction(for context: ModelContext) async throws -> ModelAction {
        let assembly = PromptBuilder.build(for: context, provider: "ollama", model: configuration.model)
        let responseSchema = ModelPromptRenderer.responseSchema(for: context.availableTools)
        let baseMessages: [OllamaChatRequest.Message] = [
            .init(role: "system", content: assembly.systemPrompt),
            .init(role: "user", content: assembly.userPrompt),
        ]

        do {
            return try await requestStructuredAction(messages: baseMessages, schema: responseSchema)
        } catch let error as AshexError {
            guard shouldRetryStructuredOutput(for: error) else { throw error }
            let repairMessages = baseMessages + [
                .init(role: "user", content: """
                Your previous response was empty or did not match the required JSON schema.
                Reply again with exactly one JSON object matching the requested schema and no surrounding prose or markdown fences.
                """)
            ]
            return try await requestStructuredAction(messages: repairMessages, schema: responseSchema)
        }
    }

    private func requestStructuredAction(
        messages: [OllamaChatRequest.Message],
        schema: JSONObject
    ) async throws -> ModelAction {
        let requestBody = OllamaChatRequest(
            model: configuration.model,
            messages: messages,
            format: schema,
            options: [
                "temperature": .number(0),
            ],
            stream: false
        )

        var request = URLRequest(url: configuration.baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(configuration.requestTimeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(requestBody)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AshexError.model("Ollama request did not return an HTTP response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = try? decoder.decode(OllamaErrorEnvelope.self, from: data)
            throw AshexError.model(ollamaErrorMessage(statusCode: httpResponse.statusCode, apiError: apiError?.error))
        }

        let envelope = try decoder.decode(OllamaChatResponseEnvelope.self, from: data)
        let content = envelope.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw AshexError.model("Ollama response did not include structured output content")
        }

        let candidate = DirectChatReplyParser.extractJSONObjectString(from: content) ?? content
        do {
            return try ToolInvocationParser.parseAction(from: candidate)
        } catch {
            throw AshexError.model("Ollama response did not decode into the expected structured output")
        }
    }

    private func shouldRetryStructuredOutput(for error: AshexError) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("structured output content")
            || message.contains("structured output")
            || message.contains("did not decode")
    }
}

extension OllamaChatModelAdapter: DirectChatModelAdapter {
    public func directReply(history: [MessageRecord], systemPrompt: String) async throws -> String {
        try await directReplyEnvelope(history: history, systemPrompt: systemPrompt, attachments: []).text
    }

    public func directReply(history: [MessageRecord], systemPrompt: String, attachments: [InputAttachment]) async throws -> String {
        try await directReplyEnvelope(history: history, systemPrompt: systemPrompt, attachments: attachments).text
    }

    public func directReplyEnvelope(history: [MessageRecord], systemPrompt: String, attachments: [InputAttachment]) async throws -> DirectChatReplyEnvelope {
        do {
            return try await requestDirectReply(history: history, systemPrompt: systemPrompt, attachments: attachments, repair: false)
        } catch let error as AshexError {
            guard shouldRetryStructuredOutput(for: error) || error.localizedDescription.lowercased().contains("did not return a reply") else {
                throw error
            }
            return try await requestDirectReply(history: history, systemPrompt: systemPrompt, attachments: attachments, repair: true)
        }
    }

    private func requestDirectReply(
        history: [MessageRecord],
        systemPrompt: String,
        attachments: [InputAttachment],
        repair: Bool
    ) async throws -> DirectChatReplyEnvelope {
        let repairInstruction = repair
            ? " Your previous reply was empty. Reply again with a non-empty `reply` string."
            : ""
        let requestBody = OllamaChatRequest(
            model: configuration.model,
            messages: try await DirectChatMultimodalBuilder.ollamaMessages(
                from: history,
                systemPrompt: systemPrompt + repairInstruction,
                model: configuration.model,
                attachments: attachments,
                audioTranscriber: audioTranscriber
            ),
            format: [
                "type": .string("object"),
                "properties": .object([
                    "reply": .object([
                        "type": .string("string")
                    ])
                ]),
                "required": .array([.string("reply")]),
                "additionalProperties": .bool(false),
            ],
            options: [
                "temperature": .number(0.2),
            ],
            stream: false
        )

        var request = URLRequest(url: configuration.baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(configuration.requestTimeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(requestBody)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AshexError.model("Ollama request did not return an HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = try? decoder.decode(OllamaErrorEnvelope.self, from: data)
            throw AshexError.model(ollamaErrorMessage(statusCode: httpResponse.statusCode, apiError: apiError?.error))
        }
        let envelope = try decoder.decode(OllamaChatResponseEnvelope.self, from: data)
        let content = envelope.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let reply = DirectChatReplyParser.parseReply(from: content) else {
            throw AshexError.model("Ollama direct chat did not return a reply")
        }
        return .init(text: reply, reasoningSummary: ReasoningSummaryExtractor.summary(fromExposedThinkingIn: content))
    }
}

extension OllamaChatModelAdapter: TaskPlanningModelAdapter {
    public func taskPlan(for prompt: String, taskKind: TaskKind) async throws -> TaskPlan? {
        let requestBody = OllamaChatRequest(
            model: configuration.model,
            messages: [
                .init(role: "system", content: """
                You are planning a software task for an agent.
                Break the request into a short, concrete ordered task list.
                Return 2 to 6 steps only when the work is genuinely multi-step.
                Use phases from: exploration, planning, mutation, validation.
                Keep each title concise and action-oriented.
                """),
                .init(role: "user", content: "Task kind: \(taskKind.rawValue)\n\nUser request:\n\(prompt)")
            ],
            format: ModelPromptRenderer.taskPlanSchema(),
            options: [
                "temperature": .number(0),
            ],
            stream: false
        )

        var request = URLRequest(url: configuration.baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(configuration.requestTimeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(requestBody)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AshexError.model("Ollama request did not return an HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = try? decoder.decode(OllamaErrorEnvelope.self, from: data)
            throw AshexError.model(ollamaErrorMessage(statusCode: httpResponse.statusCode, apiError: apiError?.error))
        }

        let envelope = try decoder.decode(OllamaChatResponseEnvelope.self, from: data)
        let content = envelope.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw AshexError.model("Ollama planning response did not include structured output content")
        }
        let candidate = DirectChatReplyParser.extractJSONObjectString(from: content) ?? content
        return try TaskPlanParser.parsePlan(from: candidate, fallbackTaskKind: taskKind)
    }
}

private extension OllamaChatModelAdapter {
    func ollamaErrorMessage(statusCode: Int, apiError: String?) -> String {
        let rawError = apiError?.trimmingCharacters(in: .whitespacesAndNewlines)
        var message = "Ollama request for model '\(configuration.model)' failed with HTTP \(statusCode)"
        if let rawError, !rawError.isEmpty {
            message += ": \(rawError)"
            if rawError.localizedCaseInsensitiveContains("out of memory") {
                message += ". This is the Ollama backend failing to allocate the requested model/context, not Ashex's local guardrail."
                message += " Stop other Ollama models with `ollama stop <model>`, restart Ollama, or choose a smaller/currently installed model from Assistant Setup."
            }
        }
        return message
    }
}

public struct AnthropicMessagesModelAdapter: ModelAdapter {
    public let name: String
    public let providerID = "anthropic"
    public var modelID: String { configuration.model }

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

    fileprivate static func directChatAnthropicMessages(from history: [MessageRecord]) -> [AnthropicMessagesRequest.Message] {
        history.suffix(12).map { message in
            AnthropicMessagesRequest.Message(
                role: message.role == .assistant ? "assistant" : "user",
                content: message.content
            )
        }
    }

    public func nextAction(for context: ModelContext) async throws -> ModelAction {
        let assembly = PromptBuilder.build(for: context, provider: "anthropic", model: configuration.model)
        let requestBody = AnthropicMessagesRequest(
            model: configuration.model,
            maxTokens: 1200,
            system: assembly.systemPrompt + "\n\nReply with exactly one JSON object matching the requested schema and nothing else.",
            messages: [
                .init(role: "user", content: assembly.userPrompt)
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

        return try ToolInvocationParser.parseAction(from: content)
    }
}

extension AnthropicMessagesModelAdapter: DirectChatModelAdapter {
    public func directReply(history: [MessageRecord], systemPrompt: String) async throws -> String {
        try await directReplyEnvelope(history: history, systemPrompt: systemPrompt, attachments: []).text
    }

    public func directReplyEnvelope(history: [MessageRecord], systemPrompt: String, attachments _: [InputAttachment]) async throws -> DirectChatReplyEnvelope {
        do {
            return try await requestDirectReply(history: history, systemPrompt: systemPrompt, repair: false)
        } catch let error as AshexError {
            let message = error.localizedDescription.lowercased()
            guard message.contains("did not return a reply") else { throw error }
            return try await requestDirectReply(history: history, systemPrompt: systemPrompt, repair: true)
        }
    }

    private func requestDirectReply(
        history: [MessageRecord],
        systemPrompt: String,
        repair: Bool
    ) async throws -> DirectChatReplyEnvelope {
        let repairInstruction = repair
            ? "\n\nYour previous reply was empty. Reply again with a non-empty `reply` string."
            : ""
        let requestBody = AnthropicMessagesRequest(
            model: configuration.model,
            maxTokens: 600,
            system: systemPrompt + "\n\nReply naturally to the latest user message. Do not call tools. Return only a JSON object with a single `reply` string field." + repairInstruction,
            messages: Self.directChatAnthropicMessages(from: history)
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
        guard let reply = DirectChatReplyParser.parseReply(from: content) else {
            throw AshexError.model("Anthropic direct chat did not return a reply")
        }
        return .init(text: reply, reasoningSummary: ReasoningSummaryExtractor.summary(fromExposedThinkingIn: content))
    }
}

extension AnthropicMessagesModelAdapter: TaskPlanningModelAdapter {
    public func taskPlan(for prompt: String, taskKind: TaskKind) async throws -> TaskPlan? {
        let requestBody = AnthropicMessagesRequest(
            model: configuration.model,
            maxTokens: 900,
            system: """
            You are planning a software task for an agent.
            Break the request into a short, concrete ordered task list.
            Return 2 to 6 steps only when the work is genuinely multi-step.
            Use phases from: exploration, planning, mutation, validation.
            Keep each title concise and action-oriented.
            Return only a JSON object with a `steps` array of `{title, phase}` items.
            """,
            messages: [
                .init(role: "user", content: "Task kind: \(taskKind.rawValue)\n\nUser request:\n\(prompt)")
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
            throw AshexError.model("Anthropic planning response did not include structured output text")
        }
        return try TaskPlanParser.parsePlan(from: content, fallbackTaskKind: taskKind)
    }
}

public struct MockModelAdapter: ModelAdapter {
    public let name = "mock-rule-based"
    public let providerID = "mock"
    public let modelID = "mock-rule-based"

    public init() {}

    public func nextAction(for context: ModelContext) async throws -> ModelAction {
        guard let lastMessage = context.messages.last else {
            throw AshexError.model("Conversation is empty")
        }

        if lastMessage.role == .tool {
            return .finalAnswer(Self.summarizeToolMessage(lastMessage.content))
        }

        let prompt = lastMessage.content.lowercased()

        if (prompt.contains("what do you think") || prompt.contains("what is this repo about") || prompt.contains("this repo")),
           let lastToolMessage = context.messages.reversed().first(where: { $0.role == .tool && $0.content.contains("tool github_repo") }) {
            return .finalAnswer(Self.summarizeToolMessage(lastToolMessage.content))
        }

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

        if prompt.contains("github.com"), let repositoryURL = Self.firstURL(in: lastMessage.content) {
            return .toolCall(.init(toolName: "github_repo", arguments: [
                "operation": .string("inspect_repository"),
                "repository_url": .string(repositoryURL),
            ]))
        }

        if prompt.contains("swift build") {
            return .toolCall(.init(toolName: "build", arguments: [
                "operation": .string("swift_build"),
            ]))
        }

        if prompt.contains("swift test") {
            return .toolCall(.init(toolName: "build", arguments: [
                "operation": .string("swift_test"),
            ]))
        }

        if prompt.contains("xcodebuild") && prompt.contains("list") {
            return .toolCall(.init(toolName: "build", arguments: [
                "operation": .string("xcodebuild_list"),
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
        - swift build
        - swift test
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

    private static func firstURL(in input: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return detector.firstMatch(in: input, options: [], range: range)?.url?.absoluteString
    }

    private static func summarizeToolMessage(_ content: String) -> String {
        let toolName = field(named: "tool", in: content) ?? "tool"
        let operation = field(named: "operation", in: content)

        if let payload = structuredOutput(in: content)?.objectValue {
            if toolName == "github_repo", operation == "inspect_repository" {
                let repoURL = payload["repository_url"]?.stringValue ?? "the repository"
                let excerpt = payload["readme_excerpt"]?.stringValue?
                    .components(separatedBy: "\n\n")
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let entries = payload["top_level_entries"]?.arrayValue?
                    .compactMap(\.stringValue)
                    .prefix(5)
                    .joined(separator: ", ")
                let latestCommit = payload["latest_commit"]?.objectValue?["subject"]?.stringValue

                var lines: [String] = []
                if let excerpt, !excerpt.isEmpty {
                    lines.append(excerpt)
                } else {
                    lines.append("I inspected \(repoURL).")
                }
                if let entries, !entries.isEmpty {
                    lines.append("Top-level files: \(entries).")
                }
                if let latestCommit, !latestCommit.isEmpty {
                    lines.append("Latest commit: \(latestCommit)")
                }
                return lines.joined(separator: " ")
            }

            if toolName == "filesystem", operation == "list_directory",
               let entries = payload["entries"]?.arrayValue?.compactMap(\.stringValue),
               !entries.isEmpty {
                return "Files: \(entries.joined(separator: ", "))"
            }

            if toolName == "filesystem", operation == "read_text_file",
               let content = payload["content"]?.stringValue,
               !content.isEmpty {
                return content
            }

            if toolName == "git", operation == "status",
               let stdout = payload["stdout"]?.stringValue,
               !stdout.isEmpty {
                return "Git status:\n\(stdout)"
            }
        }

        if let output = section(named: "output:", in: content), !output.isEmpty {
            return output
        }

        return "I completed the tool step, but I need a more specific follow-up prompt to summarize it cleanly."
    }

    private static func field(named name: String, in content: String) -> String? {
        let prefix = "\(name) "
        for line in content.components(separatedBy: .newlines) {
            if line.hasPrefix(prefix) {
                let value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private static func section(named marker: String, in content: String) -> String? {
        guard let range = content.range(of: marker) else { return nil }
        let tail = content[range.upperBound...]
        let stopMarkers = ["structured_output:", "error:"]
        let nextStop = stopMarkers.compactMap { stopMarker in
            tail.range(of: stopMarker).map(\.lowerBound)
        }.min() ?? tail.endIndex
        let value = tail[..<nextStop].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value)
    }

    private static func structuredOutput(in content: String) -> JSONValue? {
        guard let range = content.range(of: "structured_output:") else { return nil }
        let tail = content[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(tail.utf8))
    }
}

extension MockModelAdapter: DirectChatModelAdapter {
    public func directReply(history: [MessageRecord], systemPrompt: String) async throws -> String {
        guard let lastUserMessage = history.last(where: { $0.role == .user })?.content else {
            return "Hello. How can I help?"
        }
        return "I'm doing well and ready to help. You said: \(lastUserMessage)"
    }
}

extension MockModelAdapter: TaskPlanningModelAdapter {
    public func taskPlan(for prompt: String, taskKind: TaskKind) async throws -> TaskPlan? {
        TaskPlanner.plan(for: prompt)
    }
}

public struct OpenAIAudioTranscriber: AudioTranscriber {
    private let apiKey: String
    private let session: URLSession
    private let endpoint: URL
    private let model: String

    public init(
        apiKey: String,
        model: String = "gpt-4o-mini-transcribe",
        endpoint: URL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.session = session
        self.endpoint = endpoint
        self.model = model
    }

    public func transcribeAudio(fileURL: URL) async throws -> String {
        let boundary = "AshexBoundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try multipartBody(fileURL: fileURL, boundary: boundary)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AshexError.model("OpenAI transcription request did not return an HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data)
            throw AshexError.model(apiError?.error.message ?? "OpenAI transcription failed with status \(httpResponse.statusCode)")
        }
        let envelope = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data)
        return envelope.text
    }

    private func multipartBody(fileURL: URL, boundary: String) throws -> Data {
        var data = Data()
        let filename = fileURL.lastPathComponent
        let mimeType = OpenAITranscriptionResponse.mimeType(for: fileURL)
        let fileData = try Data(contentsOf: fileURL)

        func append(_ string: String) {
            data.append(Data(string.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        data.append(fileData)
        append("\r\n")

        append("--\(boundary)--\r\n")
        return data
    }
}

private enum DirectChatMultimodalBuilder {
    static func openAIInput(
        history: [MessageRecord],
        systemPrompt: String,
        model: String,
        attachments: [InputAttachment],
        audioTranscriber: (any AudioTranscriber)?
    ) async throws -> JSONValue {
        let latestAttachment = AttachmentContext.extract(from: attachments, history: history)
        let transcript = OpenAIResponsesModelAdapter.directChatTranscript(from: history)
        let conversationText = "\(systemPrompt)\n\nConversation:\n\(transcript)\n\nReply naturally to the latest user message. Do not call tools or emit JSON."

        guard let attachment = latestAttachment else {
            return .string(conversationText)
        }

        var content: [JSONValue] = [
            .object([
                "type": .string("input_text"),
                "text": .string(conversationText + "\n\n" + attachment.modelFacingInstruction),
            ])
        ]

        switch attachment.kind {
        case .image:
            guard AttachmentCapability.supportsImages(provider: "openai", model: model),
                  let dataURL = try attachment.dataURL() else {
                return .string(conversationText + "\n\n" + attachment.fallbackInstruction)
            }
            content.append(.object([
                "type": .string("input_image"),
                "image_url": .string(dataURL),
                "detail": .string("auto"),
            ]))
        case .audio:
            if let audioTranscriber,
               let transcription = try await transcribedText(for: attachment, transcriber: audioTranscriber) {
                content[0] = .object([
                    "type": .string("input_text"),
                    "text": .string(conversationText + "\n\nAudio transcription:\n\(transcription)")
                ])
            } else {
                return .string(conversationText + "\n\n" + attachment.fallbackInstruction)
            }
        }

        return .array([
            .object([
                "role": .string("user"),
                "content": .array(content),
            ])
        ])
    }

    static func openAIRepairAdjustedInput(_ input: JSONValue, repairSuffix: String) -> JSONValue {
        guard !repairSuffix.isEmpty else { return input }
        switch input {
        case .string(let text):
            return .string(text + repairSuffix)
        case .array(var items):
            if let lastIndex = items.indices.last,
               case .object(var message) = items[lastIndex],
               case .array(var content) = message["content"] {
                if let textIndex = content.firstIndex(where: { item in
                    guard case .object(let object) = item else { return false }
                    return object["type"]?.stringValue == "input_text"
                }),
                   case .object(var textItem) = content[textIndex],
                   let text = textItem["text"]?.stringValue {
                    textItem["text"] = .string(text + repairSuffix)
                    content[textIndex] = .object(textItem)
                    message["content"] = .array(content)
                    items[lastIndex] = .object(message)
                    return .array(items)
                }
            }
            return input
        default:
            return input
        }
    }

    static func ollamaMessages(
        from history: [MessageRecord],
        systemPrompt: String,
        model: String,
        attachments: [InputAttachment],
        audioTranscriber: (any AudioTranscriber)?
    ) async throws -> [OllamaChatRequest.Message] {
        let attachment = AttachmentContext.extract(from: attachments, history: history)
        let baseMessages: [OllamaChatRequest.Message] = [
            .init(role: "system", content: systemPrompt)
        ] + history.suffix(12).map { message in
            .init(
                role: message.role == .assistant ? "assistant" : "user",
                content: message.content
            )
        }

        guard let attachment,
              let lastUserIndex = baseMessages.lastIndex(where: { $0.role == "user" }) else {
            return baseMessages
        }

        var messages = baseMessages
        switch attachment.kind {
        case .image:
            guard AttachmentCapability.supportsImages(provider: "ollama", model: model),
                  let base64 = try attachment.base64EncodedData() else {
                messages[lastUserIndex] = .init(role: "user", content: attachment.cleanedPromptWithFallback, images: nil)
                return messages
            }
            messages[lastUserIndex] = .init(role: "user", content: attachment.cleanedPrompt, images: [base64])
        case .audio:
            if let audioTranscriber,
               let transcription = try await transcribedText(for: attachment, transcriber: audioTranscriber) {
                messages[lastUserIndex] = .init(
                    role: "user",
                    content: attachment.cleanedPrompt + "\n\nAudio transcription:\n\(transcription)",
                    images: nil
                )
            } else {
                messages[lastUserIndex] = .init(role: "user", content: attachment.cleanedPromptWithFallback, images: nil)
            }
        }
        return messages
    }

    private static func transcribedText(
        for attachment: AttachmentContext,
        transcriber: any AudioTranscriber
    ) async throws -> String? {
        guard attachment.kind == .audio, let fileURL = attachment.fileURL else { return nil }
        let text = try await transcriber.transcribeAudio(fileURL: fileURL).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

private enum AttachmentCapability {
    static func supportsImages(provider: String, model: String) -> Bool {
        let loweredProvider = provider.lowercased()
        let loweredModel = model.lowercased()
        switch loweredProvider {
        case "openai":
            return true
        case "ollama":
            let markers = ["vision", "llava", "gemma3", "gemma4", "minicpm-v", "qwen2.5vl", "qwen2-vl", "bakllava", "moondream"]
            return markers.contains { loweredModel.contains($0) }
        default:
            return false
        }
    }
}

private struct AttachmentContext {
    enum Kind {
        case image
        case audio
    }

    let kind: Kind
    let fileURL: URL?
    let originalMessage: String

    var cleanedPrompt: String {
        let lines = originalMessage.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.hasPrefix("Local file:") && !trimmed.hasPrefix("Use the attachment context")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var modelFacingInstruction: String {
        switch kind {
        case .image:
            return "An image attachment is included with the latest user message. Use it to answer the user."
        case .audio:
            return "An audio attachment was provided. Use any supplied transcription to answer the user."
        }
    }

    var fallbackInstruction: String {
        switch kind {
        case .image:
            return cleanedPrompt + "\n\nThe current provider/model cannot inspect image attachments directly. Tell the user that clearly and ask for a text description if needed."
        case .audio:
            return cleanedPrompt + "\n\nThe current provider/model cannot inspect audio attachments directly and no transcription backend is configured. Tell the user that clearly and ask for text or enable transcription."
        }
    }

    var cleanedPromptWithFallback: String {
        fallbackInstruction
    }

    func base64EncodedData() throws -> String? {
        guard let fileURL else { return nil }
        let data = try Data(contentsOf: fileURL)
        return data.base64EncodedString()
    }

    func dataURL() throws -> String? {
        guard let fileURL else { return nil }
        let data = try Data(contentsOf: fileURL)
        let mimeType = Self.mimeType(for: fileURL)
        return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    static func extract(from attachments: [InputAttachment], history: [MessageRecord]) -> AttachmentContext? {
        if let latest = attachments.last {
            let prompt = latest.caption?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? latest.kind.defaultPrompt
            return .init(
                kind: latest.kind == .image ? .image : .audio,
                fileURL: URL(fileURLWithPath: latest.localPath),
                originalMessage: prompt
            )
        }

        guard let latestUser = history.last(where: { $0.role == .user }) else { return nil }
        let lowered = latestUser.content.lowercased()
        let kind: Kind?
        if lowered.contains("telegram image attachment") {
            kind = .image
        } else if lowered.contains("telegram audio attachment") {
            kind = .audio
        } else {
            kind = nil
        }
        guard let kind else { return nil }
        let fileURL = latestUser.content
            .components(separatedBy: .newlines)
            .compactMap { line -> URL? in
                let prefix = "Local file:"
                guard line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix) else { return nil }
                let path = line.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                return path.isEmpty ? nil : URL(fileURLWithPath: path)
            }
            .first
        return .init(kind: kind, fileURL: fileURL, originalMessage: latestUser.content)
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png":
            return "image/png"
        case "webp":
            return "image/webp"
        case "gif":
            return "image/gif"
        default:
            return "image/jpeg"
        }
    }
}

private extension InputAttachmentKind {
    var defaultPrompt: String {
        switch self {
        case .image:
            return "Please inspect the attached image and answer the user's request."
        case .audio:
            return "Please use the attached audio and answer the user's request."
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private struct OpenAIResponsesRequest: Encodable {
    let model: String
    let input: JSONValue
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
        let images: [String]?

        init(role: String, content: String, images: [String]? = nil) {
            self.role = role
            self.content = content
            self.images = images
        }
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

private struct DFlashChatCompletionsRequest: Encodable {
    let model: String
    let messages: [Message]
    let temperature: Double?
    let stream: Bool

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct OpenAITranscriptionResponse: Decodable {
    let text: String

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3":
            return "audio/mpeg"
        case "wav":
            return "audio/wav"
        case "m4a":
            return "audio/mp4"
        case "ogg", "oga":
            return "audio/ogg"
        default:
            return "application/octet-stream"
        }
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

private struct DFlashChatCompletionsResponseEnvelope: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
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

private struct DFlashErrorEnvelope: Decodable {
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

private enum DirectChatReplyParser {
    static func parseReply(from content: String) -> String? {
        let trimmed = stripThinkingBlocks(from: content).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let candidate = extractJSONObjectString(from: trimmed),
           let payload = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)) as? [String: Any] {
            if let reply = payload["reply"] as? String {
                let normalized = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty, !looksLikeInternalReasoning(normalized) else { return nil }
                return normalized
            }
            return nil
        }

        guard !looksLikeInternalReasoning(trimmed) else { return nil }
        return trimmed
    }

    private static func looksLikeInternalReasoning(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let markers = [
            "the user is asking",
            "i need to analyze",
            "i need to",
            "i should provide",
            "i should",
            "let me think",
            "i can infer",
            "based on the context",
            "or simulate the analysis",
            "common github repo structures",
            "the name gives a strong hint",
        ]
        let matches = markers.reduce(into: 0) { partial, marker in
            if lowered.contains(marker) {
                partial += 1
            }
        }
        return matches >= 2
    }

    static func extractJSONObjectString(from content: String) -> String? {
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

enum ReasoningSummaryExtractor {
    static func summary(fromExposedThinkingIn content: String) -> String? {
        let blocks = thinkBlocks(in: content)
        guard !blocks.isEmpty else { return nil }
        let combined = blocks.joined(separator: "\n").lowercased()

        var fragments: [String] = ["analyzed the request"]
        if containsAny(of: ["tool", "inspect", "search", "browse", "read"], in: combined) {
            fragments.append("considered what to inspect or use")
        }
        if containsAny(of: ["image", "audio", "attachment", "photo", "voice"], in: combined) {
            fragments.append("accounted for attachment context")
        }
        if containsAny(of: ["plan", "step", "approach", "first", "next"], in: combined) {
            fragments.append("formed a short approach")
        }
        if containsAny(of: ["validate", "test", "correct", "error", "bug", "fix"], in: combined) {
            fragments.append("checked for correctness")
        }
        if containsAny(of: ["repo", "github", "readme", "file", "directory"], in: combined) {
            fragments.append("reviewed repository context")
        }

        var seen: Set<String> = []
        let unique = fragments.filter { seen.insert($0).inserted }
        let limited = Array(unique.prefix(3))
        guard !limited.isEmpty else { return nil }

        if limited.count == 1 {
            return sentenceCase(limited[0]) + "."
        }
        if limited.count == 2 {
            return sentenceCase(limited[0]) + ", " + limited[1] + ", and prepared the reply."
        }
        return sentenceCase(limited[0]) + ", " + limited[1] + ", and " + limited[2] + "."
    }

    private static func thinkBlocks(in content: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"<think>([\s\S]*?)</think>"#) else {
            return []
        }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        return regex.matches(in: content, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: content) else { return nil }
            let text = String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    private static func containsAny(of markers: [String], in content: String) -> Bool {
        markers.contains { content.contains($0) }
    }

    private static func sentenceCase(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }
}

private struct TaskPlanEnvelope: Codable {
    struct Step: Codable {
        let title: String
        let phase: PlannedStepPhase
    }

    let steps: [Step]
}

private enum TaskPlanParser {
    static func parsePlan(from content: String, fallbackTaskKind: TaskKind) throws -> TaskPlan? {
        let trimmed = content
            .replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = DirectChatReplyParser.extractJSONObjectString(from: trimmed) ?? trimmed
        let envelope = try JSONDecoder().decode(TaskPlanEnvelope.self, from: Data(candidate.utf8))
        let plan = TaskPlan(
            steps: envelope.steps.map { PlannedStep(title: $0.title, phase: $0.phase) },
            taskKind: fallbackTaskKind
        )
        return TaskPlanner.normalize(plan: plan, fallbackTaskKind: fallbackTaskKind)
    }
}

enum ToolCallArgumentNormalizer {
    static func canonicalToolName(for toolName: String) -> String {
        switch toolName.lowercased() {
        case "filesystem", "file_system", "files", "file":
            return "filesystem"
        case "git", "repo", "repository":
            return "git"
        case "shell", "terminal", "command":
            return "shell"
        case "build", "builder", "swiftpm", "xcode", "xcodebuild":
            return "build"
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
        case "build":
            return normalizeBuild(arguments: arguments)
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
            case "patch", "apply_patch", "multi_replace":
                normalized["operation"] = .string("apply_patch")
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

        if normalized["edits"] == nil,
           let patches = arguments["patches"]?.arrayValue ?? arguments["changes"]?.arrayValue {
            normalized["edits"] = .array(patches)
        }
        normalized.removeValue(forKey: "patches")
        normalized.removeValue(forKey: "changes")

        if normalized["operation"]?.stringValue == "write_text_file",
           normalized["create_directories"] == nil {
            normalized["create_directories"] = .bool(true)
        }

        if normalized["operation"]?.stringValue == "apply_patch",
           normalized["edits"] == nil,
           let oldText = normalized["old_text"]?.stringValue {
            normalized["edits"] = .array([
                .object([
                    "old_text": .string(oldText),
                    "new_text": normalized["new_text"] ?? .string(""),
                    "replace_all": normalized["replace_all"] ?? .bool(false),
                ])
            ])
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

    private static func normalizeBuild(arguments: JSONObject) -> JSONObject {
        var normalized = arguments
        if normalized["operation"] == nil,
           let action = string(in: arguments, keys: ["action", "mode", "intent"])?.lowercased() {
            switch action {
            case "swift_build", "build_swift", "package_build", "spm_build", "build":
                normalized["operation"] = .string("swift_build")
            case "swift_test", "test_swift", "package_test", "spm_test", "test":
                normalized["operation"] = .string("swift_test")
            case "xcodebuild_list", "list", "xcode_list":
                normalized["operation"] = .string("xcodebuild_list")
            case "xcodebuild_build", "xcode_build":
                normalized["operation"] = .string("xcodebuild_build")
            case "xcodebuild_test", "xcode_test":
                normalized["operation"] = .string("xcodebuild_test")
            default:
                break
            }
        }
        normalized.removeValue(forKey: "action")
        normalized.removeValue(forKey: "mode")
        normalized.removeValue(forKey: "intent")

        if normalized["workspace"] == nil,
           let workspace = string(in: arguments, keys: ["workspace_path", "xcworkspace"]) {
            normalized["workspace"] = .string(workspace)
        }
        normalized.removeValue(forKey: "workspace_path")
        normalized.removeValue(forKey: "xcworkspace")

        if normalized["project"] == nil,
           let project = string(in: arguments, keys: ["project_path", "xcodeproj"]) {
            normalized["project"] = .string(project)
        }
        normalized.removeValue(forKey: "project_path")
        normalized.removeValue(forKey: "xcodeproj")

        if normalized["scheme"] == nil,
           let scheme = string(in: arguments, keys: ["target"]) {
            normalized["scheme"] = .string(scheme)
        }
        normalized.removeValue(forKey: "target")

        if normalized["derived_data_path"] == nil,
           let derivedDataPath = string(in: arguments, keys: ["derivedDataPath", "derived_data"]) {
            normalized["derived_data_path"] = .string(derivedDataPath)
        }
        normalized.removeValue(forKey: "derivedDataPath")
        normalized.removeValue(forKey: "derived_data")

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
