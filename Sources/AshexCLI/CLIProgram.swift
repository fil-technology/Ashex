import AshexCore
import Darwin
import Foundation

struct AshexCLI {
    static func main() async {
        do {
            let configuration = try CLIConfiguration(arguments: CommandLine.arguments)
            try configuration.persistSessionSettings()

            if let prompt = configuration.prompt {
                try await configuration.validateModelGuardrails()
                let runtime = try configuration.makeRuntime()
                let stream = runtime.run(.init(prompt: prompt, maxIterations: configuration.maxIterations))
                for await event in stream {
                    render(event)
                }
            } else {
                let app = try await MainActor.run {
                    try TUIApp(configuration: configuration)
                }
                try await app.run()
            }
        } catch {
            fputs("ashex error: \(error.localizedDescription)\n", stderr)
            if let recovery = startupRecoveryMessage(for: error) {
                fputs("\(recovery)\n", stderr)
            }
            Darwin.exit(1)
        }
    }

    private static func startupRecoveryMessage(for error: Error) -> String? {
        let message = error.localizedDescription.lowercased()
        if message.contains("openai_api_key") {
            return "Action: set OPENAI_API_KEY, or run `swift run ashex --provider mock` to open the TUI without a remote provider."
        }
        if message.contains("anthropic_api_key") {
            return "Action: set ANTHROPIC_API_KEY, or run `swift run ashex --provider mock` to open the TUI without a remote provider."
        }
        if message.contains("could not connect to the server") || message.contains("failed to connect") || message.contains("connection") {
            return "Action: start Ollama with `ollama serve`, switch to `mock` in Provider Settings after launch, or run `swift run ashex --provider mock`."
        }
        if message.contains("guardrail") || message.contains("local model") {
            return "Action: choose a smaller model in Provider Settings, or set ASHEX_ALLOW_LARGE_MODELS=1 if you really want to override the memory guardrail."
        }
        return "Action: launch with `swift run ashex --provider mock` to recover into the TUI and then adjust Provider Settings."
    }

    private static func render(_ event: RuntimeEvent) {
        switch event.payload {
        case .runStarted(_, let runID):
            print("[run] started \(runID.uuidString)")
        case .runStateChanged(_, let state, let reason):
            print("[state] \(state.rawValue)\(reason.map { " - \($0)" } ?? "")")
        case .taskPlanCreated(_, let steps):
            print("[plan] created \(steps.count) steps")
            for (index, step) in steps.enumerated() {
                print("[plan] \(index + 1). \(step)")
            }
        case .taskStepStarted(_, let index, let total, let title):
            print("[plan] step \(index)/\(total) started - \(title)")
        case .taskStepFinished(_, let index, let total, let title, let outcome):
            print("[plan] step \(index)/\(total) \(outcome) - \(title)")
        case .status(_, let message):
            print("[status] \(message)")
        case .messageAppended(_, _, let role):
            print("[message] appended \(role.rawValue)")
        case .approvalRequested(_, let toolName, let summary, let reason, let risk):
            print("[approval] \(toolName) \(summary) (\(risk.rawValue)) - \(reason)")
        case .approvalResolved(_, let toolName, let allowed, let reason):
            print("[approval] \(toolName) \(allowed ? "approved" : "denied") - \(reason)")
        case .toolCallStarted(_, _, let toolName, let arguments):
            print("[tool] \(toolName) started \(JSONValue.object(arguments).prettyPrinted)")
        case .toolOutput(_, _, let stream, let chunk):
            let prefix = stream == .stderr ? "stderr" : "stdout"
            for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
                if !line.isEmpty {
                    print("[\(prefix)] \(line)")
                }
            }
        case .toolCallFinished(_, _, let success, let summary):
            print("[tool] \(success ? "completed" : "failed") \(summary)")
        case .finalAnswer(_, _, let text):
            print("\nFinal answer:\n\(text)")
        case .error(_, let message):
            fputs("[error] \(message)\n", stderr)
        case .runFinished(_, let state):
            print("[run] finished \(state.rawValue)")
        }
    }
}

struct CLIConfiguration {
    private enum SessionSetting {
        static let namespace = "ui.session"
        static let provider = "default_provider"
        static let model = "default_model"
        static let credentialsNamespace = "provider.credentials"
    }

    let prompt: String?
    let workspaceRoot: URL
    let storageRoot: URL
    let maxIterations: Int
    let provider: String
    let model: String
    let approvalMode: ApprovalMode
    let userConfig: AshexUserConfig
    let userConfigFile: URL
    let shouldPersistSessionDefaults: Bool

    init(arguments: [String]) throws {
        var promptParts: [String] = []
        var workspaceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var storageRoot: URL?
        var maxIterations = 8
        var providerOverride: String?
        var modelOverride: String?
        var approvalMode = ApprovalMode(rawValue: ProcessInfo.processInfo.environment["ASHEX_APPROVAL_MODE"] ?? "trusted") ?? .trusted

        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--workspace":
                guard let value = iterator.next() else { throw AshexError.model("Missing value for --workspace") }
                workspaceRoot = URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            case "--storage":
                guard let value = iterator.next() else { throw AshexError.model("Missing value for --storage") }
                storageRoot = URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            case "--max-iterations":
                guard let value = iterator.next(), let parsed = Int(value), parsed > 0 else {
                    throw AshexError.model("Invalid value for --max-iterations")
                }
                maxIterations = parsed
            case "--provider":
                guard let value = iterator.next(), !value.isEmpty else {
                    throw AshexError.model("Missing value for --provider")
                }
                providerOverride = value
            case "--model":
                guard let value = iterator.next(), !value.isEmpty else {
                    throw AshexError.model("Missing value for --model")
                }
                modelOverride = value
            case "--approval-mode":
                guard let value = iterator.next(), let parsed = ApprovalMode(rawValue: value) else {
                    throw AshexError.model("Invalid value for --approval-mode. Supported: trusted, guarded")
                }
                approvalMode = parsed
            default:
                promptParts.append(argument)
            }
        }

        let promptText = promptParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = promptText.isEmpty ? nil : promptText

        self.prompt = prompt
        self.workspaceRoot = workspaceRoot.standardizedFileURL
        self.storageRoot = storageRoot?.standardizedFileURL ?? workspaceRoot.appendingPathComponent(".ashex")
        self.maxIterations = maxIterations
        self.userConfigFile = self.workspaceRoot.appendingPathComponent(UserConfigStore.fileName)
        self.userConfig = try UserConfigStore.ensure(at: self.userConfigFile)
        let settingsStore = try Self.makeSettingsStore(storageRoot: self.storageRoot)
        let persistedProvider = try settingsStore.fetchSetting(namespace: SessionSetting.namespace, key: SessionSetting.provider)?.value.stringValue
        let persistedModel = try settingsStore.fetchSetting(namespace: SessionSetting.namespace, key: SessionSetting.model)?.value.stringValue
        let environmentProvider = ProcessInfo.processInfo.environment["ASHEX_PROVIDER"]

        let inferredPersistedProvider: String?
        if providerOverride == nil, environmentProvider == nil, persistedProvider == "mock" {
            inferredPersistedProvider = try Self.inferProviderFromPersistedState(
                persistedModel: persistedModel,
                store: settingsStore
            )
        } else {
            inferredPersistedProvider = nil
        }

        let resolvedProvider = providerOverride ?? environmentProvider ?? inferredPersistedProvider ?? persistedProvider ?? "mock"
        let environmentModel = Self.environmentModel(for: resolvedProvider)

        self.provider = resolvedProvider
        self.model = modelOverride ?? environmentModel ?? persistedModel ?? Self.defaultModel(for: resolvedProvider)
        self.approvalMode = approvalMode
        self.shouldPersistSessionDefaults = providerOverride == nil && modelOverride == nil && environmentProvider == nil && environmentModel == nil
    }

    func makeModelAdapter() throws -> any ModelAdapter {
        try makeModelAdapter(provider: provider, model: model)
    }

    func makeModelAdapter(provider: String, model: String) throws -> any ModelAdapter {
        switch provider {
        case "mock":
            return MockModelAdapter()
        case "openai":
            guard let apiKey = try resolvedAPIKey(for: "openai"), !apiKey.isEmpty else {
                throw AshexError.model("OPENAI_API_KEY is required when --provider openai is used")
            }
            return OpenAIResponsesModelAdapter(
                configuration: .init(apiKey: apiKey, model: model)
            )
        case "anthropic":
            guard let apiKey = try resolvedAPIKey(for: "anthropic"), !apiKey.isEmpty else {
                throw AshexError.model("ANTHROPIC_API_KEY is required when --provider anthropic is used")
            }
            return AnthropicMessagesModelAdapter(
                configuration: .init(apiKey: apiKey, model: model)
            )
        case "ollama":
            return OllamaChatModelAdapter(
                configuration: .init(
                    model: model,
                    baseURL: URL(string: ProcessInfo.processInfo.environment["OLLAMA_BASE_URL"] ?? "http://localhost:11434/api/chat")!
                )
            )
        default:
            throw AshexError.model("Unsupported provider '\(provider)'. Supported: mock, openai, ollama")
        }
    }

    func makeRuntime() throws -> AgentRuntime {
        try makeRuntime(provider: provider, model: model, approvalPolicy: makeApprovalPolicy())
    }

    func makeRuntime(approvalPolicy: any ApprovalPolicy) throws -> AgentRuntime {
        try makeRuntime(provider: provider, model: model, approvalPolicy: approvalPolicy)
    }

    func makeRuntime(provider: String, model: String, approvalPolicy: any ApprovalPolicy) throws -> AgentRuntime {
        let workspaceURL = workspaceRoot.standardizedFileURL
        let persistence = SQLitePersistenceStore(databaseURL: storageRoot.appendingPathComponent("ashex.sqlite"))
        return try AgentRuntime(
            modelAdapter: makeModelAdapter(provider: provider, model: model),
            toolRegistry: ToolRegistry(tools: [
                FileSystemTool(workspaceGuard: WorkspaceGuard(rootURL: workspaceURL)),
                GitTool(
                    executionRuntime: ProcessExecutionRuntime(),
                    workspaceURL: workspaceURL
                ),
                ShellTool(
                    executionRuntime: ProcessExecutionRuntime(),
                    workspaceURL: workspaceURL,
                    commandPolicy: ShellCommandPolicy(config: userConfig.shell)
                ),
            ]),
            persistence: persistence,
            approvalPolicy: approvalPolicy
        )
    }

    func makeApprovalPolicy() -> any ApprovalPolicy {
        switch approvalMode {
        case .trusted:
            return TrustedApprovalPolicy()
        case .guarded:
            return ConsoleApprovalPolicy()
        }
    }

    func persistSessionSettings() throws {
        guard shouldPersistSessionDefaults else { return }
        let store = try Self.makeSettingsStore(storageRoot: storageRoot)
        let now = Date()
        try store.upsertSetting(namespace: SessionSetting.namespace, key: SessionSetting.provider, value: .string(provider), now: now)
        try store.upsertSetting(namespace: SessionSetting.namespace, key: SessionSetting.model, value: .string(model), now: now)
    }

    func validateModelGuardrails() async throws {
        guard provider == "ollama" else { return }
        if ProcessInfo.processInfo.environment["ASHEX_ALLOW_LARGE_MODELS"] == "1" { return }

        let catalog = try await OllamaCatalogClient().fetchModels(baseURL: Self.ollamaBaseURL())
        let assessment = LocalModelGuardrails.assessOllamaModel(model: model, installedModels: catalog)
        guard assessment.severity != .blocked else {
            let details = ([assessment.headline] + assessment.details).joined(separator: " ")
            throw AshexError.model(details + " Set ASHEX_ALLOW_LARGE_MODELS=1 to override this guardrail.")
        }
    }

    static func defaultModel(for provider: String) -> String {
        switch provider {
        case "openai":
            return ProcessInfo.processInfo.environment["OPENAI_MODEL"] ?? "gpt-5.4-mini"
        case "anthropic":
            return ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"] ?? "claude-sonnet-4-20250514"
        case "ollama":
            return ProcessInfo.processInfo.environment["OLLAMA_MODEL"] ?? "llama3.2"
        default:
            return "mock"
        }
    }

    static func environmentModel(for provider: String) -> String? {
        switch provider {
        case "openai":
            return ProcessInfo.processInfo.environment["OPENAI_MODEL"]
        case "anthropic":
            return ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"]
        case "ollama":
            return ProcessInfo.processInfo.environment["OLLAMA_MODEL"]
        default:
            return nil
        }
    }

    func resolvedAPIKey(for provider: String) throws -> String? {
        if let envKey = ProcessInfo.processInfo.environment[Self.environmentAPIKeyName(for: provider)], !envKey.isEmpty {
            return envKey
        }

        let store = try Self.makeSettingsStore(storageRoot: storageRoot)
        return try store.fetchSetting(namespace: SessionSetting.credentialsNamespace, key: Self.apiKeySettingKey(for: provider))?.value.stringValue
    }

    static func environmentAPIKeyName(for provider: String) -> String {
        switch provider {
        case "openai":
            return "OPENAI_API_KEY"
        case "anthropic":
            return "ANTHROPIC_API_KEY"
        default:
            return ""
        }
    }

    static func apiKeySettingKey(for provider: String) -> String {
        "\(provider)_api_key"
    }

    private static func inferProviderFromPersistedState(
        persistedModel: String?,
        store: SQLitePersistenceStore
    ) throws -> String? {
        guard let persistedModel, persistedModel != "mock" else { return nil }

        if persistedModel.hasPrefix("gpt-"),
           try store.fetchSetting(namespace: SessionSetting.credentialsNamespace, key: apiKeySettingKey(for: "openai"))?.value.stringValue?.isEmpty == false {
            return "openai"
        }

        if persistedModel.hasPrefix("claude"),
           try store.fetchSetting(namespace: SessionSetting.credentialsNamespace, key: apiKeySettingKey(for: "anthropic"))?.value.stringValue?.isEmpty == false {
            return "anthropic"
        }

        return nil
    }

    private static func makeSettingsStore(storageRoot: URL) throws -> SQLitePersistenceStore {
        let store = SQLitePersistenceStore(databaseURL: storageRoot.appendingPathComponent("ashex.sqlite"))
        try store.initialize()
        return store
    }

    static func ollamaBaseURL() -> URL {
        URL(string: ProcessInfo.processInfo.environment["OLLAMA_BASE_URL"] ?? "http://localhost:11434/api/chat")!
    }
}
