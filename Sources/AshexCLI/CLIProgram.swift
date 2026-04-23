import AshexCore
import Darwin
import Foundation

struct AshexCLI {
    static func main() async {
        do {
            if isHelpRequested(arguments: CommandLine.arguments) {
                print(helpText)
                return
            }
            if isVersionRequested(arguments: CommandLine.arguments) {
                print("ashex \(AppBuildInfo.current.displayLabel)")
                return
            }

            if try await DaemonCLI.handle(arguments: CommandLine.arguments) {
                return
            }
            if try OptimizationCLI.handle(arguments: CommandLine.arguments) {
                return
            }

            let configuration = try CLIConfiguration(arguments: CommandLine.arguments)

            if let prompt = configuration.prompt {
                if try handleLocalPromptCommand(prompt, configuration: configuration) {
                    return
                }
                try configuration.persistSessionSettings()
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

    static func handleLocalPromptCommand(_ prompt: String, configuration: CLIConfiguration) throws -> Bool {
        guard let command = LocalPromptCommand.parse(prompt) else {
            return false
        }

        switch command {
        case .showWorkspace:
            print(SimpleWorkspaceCommandExecutor.workspaceStatus(workspaceRoot: configuration.workspaceRoot))
        case .showWorkspaceHelp:
            print(SimpleWorkspaceCommandExecutor.workspaceHelp(
                workspaceRoot: configuration.workspaceRoot,
                startupCommand: "ashex daemon run --workspace \(configuration.workspaceRoot.path) --provider \(configuration.provider) --model \(configuration.model)"
            ))
        case .showLastRun:
            let inspector = SessionInspector(persistence: try configuration.makePersistenceStore())
            if let summary = try inspector.summarizeLatestRun(recentEventLimit: 500) {
                print(SessionInspector.format(summary: summary))
            } else {
                print("No persisted runs were found for this workspace yet.")
            }
        case .simpleWorkspace(let workspaceCommand):
            print(try SimpleWorkspaceCommandExecutor.execute(
                workspaceCommand,
                workspaceRoot: configuration.workspaceRoot,
                sandbox: configuration.userConfig.sandbox
            ))
        case .showSandbox:
            print("""
            Sandbox policy
            Mode: \(configuration.userConfig.sandbox.mode.rawValue)
            Network mode: \(configuration.userConfig.network.mode.rawValue)
            Protected paths: \(configuration.userConfig.sandbox.protectedPaths.isEmpty ? "none" : configuration.userConfig.sandbox.protectedPaths.joined(separator: ", "))
            Unknown commands require approval: \(configuration.userConfig.shell.requireApprovalForUnknownCommands ? "yes" : "no")
            Workspace config: \(configuration.userConfigFile.path)
            Global config: \(configuration.globalUserConfigFile?.path ?? "<none>")
            """)
        case .showToolPacks:
            let availablePacks = (try? ToolPackManager.availableBundledPacks()) ?? []
            let enabledIDs = (try? ToolPackManager.enabledBundledPackIDs(persistence: configuration.makePersistenceStore())) ?? ToolPackSettings.defaultBundledPackIDs
            if availablePacks.isEmpty {
                print("No bundled tool packs found.")
            } else {
                for pack in availablePacks {
                    print("\(pack.id): \(enabledIDs.contains(pack.id) ? "enabled" : "disabled")")
                }
            }
        case .installToolPack, .uninstallToolPack, .openWorkspaces, .switchWorkspace, .showHelp:
            print(LocalPromptCommand.helpLines.joined(separator: "\n"))
        }
        return true
    }

    static func isHelpRequested(arguments: [String]) -> Bool {
        arguments.dropFirst().contains { $0 == "--help" || $0 == "-h" }
    }

    static func isVersionRequested(arguments: [String]) -> Bool {
        arguments.dropFirst().contains { $0 == "--version" || $0 == "-v" }
    }

    static let helpText = """
    Usage:
      ashex [options] [prompt]
      ashex onboard [options]
      ashex daemon <run|start|stop|status> [options]
      ashex telegram test [options]
      ashex cron <list|add|remove> [options]

    Options:
      --workspace PATH          Workspace root to use
      --storage PATH            Storage root for Ashex state
      --provider NAME           Provider: mock, openai, anthropic, ollama, dflash
      --model NAME              Provider model name
      --max-iterations N        Maximum agent loop iterations
      --approval-mode MODE      trusted or guarded
      --onboarding              Open first-run setup
      -v, --version             Show installed version and commit
      -h, --help                Show this help
    """

    private static func startupRecoveryMessage(for error: Error) -> String? {
        let message = error.localizedDescription.lowercased()
        if message.contains("\naction:") || message.hasPrefix("action:") {
            return nil
        }
        if message.contains("openai_api_key") {
            return "Action: set OPENAI_API_KEY, or run `ashex --provider mock` to open the TUI without a remote provider."
        }
        if message.contains("anthropic_api_key") {
            return "Action: set ANTHROPIC_API_KEY, or run `ashex --provider mock` to open the TUI without a remote provider."
        }
        if message.contains("telegram") && message.contains("bot token") {
            return "Action: save a Telegram bot token in Assistant Setup, set ASHEX_TELEGRAM_BOT_TOKEN, or add an enabled cron job."
        }
        if message.contains("dflash") {
            return "Action: start `dflash-serve`, choose `dflash` in Provider Settings, or run `ashex --provider mock` until the local DFlash server is available."
        }
        if message.contains("could not connect to the server") || message.contains("failed to connect") || message.contains("connection") {
            return "Action: start Ollama with `ollama serve`, switch to `mock` in Provider Settings after launch, or run `ashex --provider mock`."
        }
        if message.contains("guardrail") || message.contains("local model") {
            return "Action: choose a smaller model in Provider Settings, or set ASHEX_ALLOW_LARGE_MODELS=1 if you really want to override the memory guardrail."
        }
        return "Action: launch with `ashex --provider mock` to recover into the TUI and then adjust Provider Settings."
    }

    private static func render(_ event: RuntimeEvent) {
        switch event.payload {
        case .runStarted(_, let runID):
            print("[run] started \(runID.uuidString)")
        case .runStateChanged(_, let state, let reason):
            print("[state] \(state.rawValue)\(reason.map { " - \($0)" } ?? "")")
        case .workflowPhaseChanged(_, let phase, let title):
            print("[phase] \(phase) - \(title)")
        case .contextPrepared(_, let retainedMessages, let droppedMessages, let clippedMessages, let estimatedTokens, let estimatedContextWindow):
            print("[context] retained \(retainedMessages), dropped \(droppedMessages), clipped \(clippedMessages), tok~ \(estimatedTokens), ctx~ \(estimatedTokens)/\(estimatedContextWindow)")
        case .contextCompacted(_, let droppedMessages, let summary):
            print("[context] compacted \(droppedMessages) earlier messages")
            print(summary)
        case .taskPlanCreated(_, let steps):
            print("[plan] created \(steps.count) steps")
            for (index, step) in steps.enumerated() {
                print("[plan] \(index + 1). \(step)")
            }
        case .todoListUpdated(_, let items):
            let summary = items.map { item in
                let marker: String
                switch item.status {
                case .pending: marker = "todo"
                case .inProgress: marker = "doing"
                case .completed: marker = "done"
                case .skipped: marker = "skip"
                }
                return "\(item.index):\(marker)"
            }.joined(separator: ", ")
            print("[todo] \(summary)")
        case .taskStepStarted(_, let index, let total, let title):
            print("[plan] step \(index)/\(total) started - \(title)")
        case .taskStepFinished(_, let index, let total, let title, let outcome):
            print("[plan] step \(index)/\(total) \(outcome) - \(title)")
        case .explorationPlanUpdated(_, let targets, let pendingTargets, let rejectedTargets, let suggestedQueries):
            if !targets.isEmpty {
                print("[explore] targets: \(targets.joined(separator: ", "))")
            }
            if !pendingTargets.isEmpty {
                print("[explore] next: \(pendingTargets.joined(separator: ", "))")
            }
            if !rejectedTargets.isEmpty {
                print("[explore] deprioritized: \(rejectedTargets.joined(separator: ", "))")
            }
            if !suggestedQueries.isEmpty {
                print("[explore] queries: \(suggestedQueries.joined(separator: ", "))")
            }
        case .subagentAssigned(_, let title, let role, let goal):
            print("[subagent] assigned \(role) - \(title)")
            print(goal)
        case .subagentStarted(_, let title, let maxIterations):
            print("[subagent] started - \(title) (max \(maxIterations) iterations)")
        case .subagentHandoff(_, let title, let role, let summary, let remainingItems):
            print("[subagent] handoff \(role) - \(title)")
            print(summary)
            if !remainingItems.isEmpty {
                print("[subagent] remaining: \(remainingItems.joined(separator: ", "))")
            }
        case .subagentFinished(_, let title, let summary):
            print("[subagent] finished - \(title)")
            print(summary)
        case .changedFilesTracked(_, let paths):
            print("[change] \(paths.joined(separator: ", "))")
        case .patchPlanUpdated(_, let paths, let objectives):
            print("[patch-plan] \(paths.isEmpty ? "forming" : paths.joined(separator: ", "))")
            if !objectives.isEmpty {
                print("[patch-plan] goals: \(objectives.joined(separator: " | "))")
            }
        case .status(_, let message):
            if message.lowercased().contains("thinking") {
                print("[thinking] \(message)")
            } else if message.lowercased().hasPrefix("reasoning summary:") {
                print("[reasoning] \(message)")
            } else {
                print("[status] \(message)")
            }
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
    let globalUserConfigFile: URL?
    let shouldPersistSessionDefaults: Bool
    let forceOnboarding: Bool

    init(arguments: [String]) throws {
        var promptParts: [String] = []
        var workspaceRoot = Self.defaultWorkspaceRoot()
        var storageRoot: URL?
        var maxIterations = 8
        var providerOverride: String?
        var modelOverride: String?
        var approvalMode = ApprovalMode(rawValue: ProcessInfo.processInfo.environment["ASHEX_APPROVAL_MODE"] ?? "trusted") ?? .trusted
        var forceOnboarding = false

        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "onboard", "--onboarding":
                forceOnboarding = true
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
        let prompt = forceOnboarding || promptText.isEmpty ? nil : promptText

        self.prompt = prompt
        self.workspaceRoot = workspaceRoot.standardizedFileURL
        self.storageRoot = storageRoot?.standardizedFileURL ?? workspaceRoot.appendingPathComponent(".ashex")
        self.maxIterations = maxIterations
        let loadedConfig = try UserConfigStore.loadMerged(for: self.workspaceRoot)
        self.userConfigFile = loadedConfig.workspaceFileURL
        self.globalUserConfigFile = loadedConfig.globalFileURL
        self.userConfig = loadedConfig.effectiveConfig
        let settingsStore = try Self.makeSettingsStore(storageRoot: self.storageRoot)
        let persistedProvider = try settingsStore.fetchSetting(namespace: SessionSetting.namespace, key: SessionSetting.provider)?.value.stringValue
        let persistedModel = try settingsStore.fetchSetting(namespace: SessionSetting.namespace, key: SessionSetting.model)?.value.stringValue
        let environmentProvider = ProcessInfo.processInfo.environment["ASHEX_PROVIDER"]

        let inferredPersistedProvider: String?
        if providerOverride == nil, environmentProvider == nil, persistedProvider == "mock" {
            inferredPersistedProvider = try Self.inferProviderFromPersistedState(
                persistedModel: persistedModel,
                store: settingsStore,
                secretStore: LocalJSONSecretStore(fileURL: self.storageRoot.appendingPathComponent("secrets.json"))
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
        self.forceOnboarding = forceOnboarding
    }

    static func defaultWorkspaceRoot(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Ashex", isDirectory: true)
            .appendingPathComponent("DefaultWorkspace", isDirectory: true)
    }

    func makeModelAdapter() throws -> any ModelAdapter {
        try makeModelAdapter(provider: provider, model: model)
    }

    func makeModelAdapter(provider: String, model: String) throws -> any ModelAdapter {
        let audioTranscriber = makeAudioTranscriberIfAvailable(for: provider)
        let baseAdapter: any ModelAdapter
        switch provider {
        case "mock":
            baseAdapter = MockModelAdapter()
        case "openai":
            guard let apiKey = try resolvedAPIKey(for: "openai"), !apiKey.isEmpty else {
                throw AshexError.model("OPENAI_API_KEY is required when --provider openai is used")
            }
            baseAdapter = OpenAIResponsesModelAdapter(
                configuration: .init(apiKey: apiKey, model: model),
                audioTranscriber: audioTranscriber
            )
        case "anthropic":
            guard let apiKey = try resolvedAPIKey(for: "anthropic"), !apiKey.isEmpty else {
                throw AshexError.model("ANTHROPIC_API_KEY is required when --provider anthropic is used")
            }
            baseAdapter = AnthropicMessagesModelAdapter(
                configuration: .init(apiKey: apiKey, model: model)
            )
        case "dflash":
            try Self.validateDFlashSupport()
            baseAdapter = DFlashServerModelAdapter(
                configuration: .init(
                    model: model,
                    baseURL: Self.dflashBaseURL(config: userConfig.dflash),
                    requestTimeoutSeconds: userConfig.dflash.requestTimeoutSeconds,
                    draftModel: userConfig.dflash.draftModel
                )
            )
        case "ollama":
            baseAdapter = OllamaChatModelAdapter(
                configuration: .init(
                    model: model,
                    baseURL: URL(string: ProcessInfo.processInfo.environment["OLLAMA_BASE_URL"] ?? "http://localhost:11434/api/chat")!,
                    requestTimeoutSeconds: Self.ollamaRequestTimeoutSeconds(config: userConfig.ollama),
                    contextWindowTokens: Self.ollamaContextWindowTokens(config: userConfig.ollama)
                ),
                audioTranscriber: audioTranscriber
            )
        default:
            throw AshexError.model("Unsupported provider '\(provider)'. Supported: mock, openai, anthropic, ollama, dflash")
        }

        return makeOptimizedAdapterIfNeeded(baseAdapter: baseAdapter, provider: provider, model: model)
    }

    func makeRuntime() throws -> AgentRuntime {
        try makeRuntime(provider: provider, model: model, approvalPolicy: makeApprovalPolicy())
    }

    func makeRuntime(approvalPolicy: any ApprovalPolicy) throws -> AgentRuntime {
        try makeRuntime(provider: provider, model: model, approvalPolicy: approvalPolicy)
    }

    func makeRuntime(provider: String, model: String, approvalPolicy: any ApprovalPolicy) throws -> AgentRuntime {
        let persistence = try makePersistenceStore()
        return try makeRuntime(
            persistence: persistence,
            provider: provider,
            model: model,
            approvalPolicy: approvalPolicy
        )
    }

    func makePersistenceStore() throws -> SQLitePersistenceStore {
        let store = SQLitePersistenceStore(databaseURL: storageRoot.appendingPathComponent("ashex.sqlite"))
        try store.initialize()
        return store
    }

    func makeRuntime(
        persistence: SQLitePersistenceStore,
        provider: String,
        model: String,
        approvalPolicy: any ApprovalPolicy
    ) throws -> AgentRuntime {
        let workspaceURL = workspaceRoot.standardizedFileURL
        let workspaceSnapshot = WorkspaceSnapshotBuilder.capture(workspaceRoot: workspaceURL)
        let shellExecutionPolicy = makeShellExecutionPolicy()
        let tools = try RuntimeToolFactory.makeTools(
            workspaceURL: workspaceURL,
            persistence: persistence,
            sandbox: userConfig.sandbox,
            shellExecutionPolicy: shellExecutionPolicy
        )
        return try AgentRuntime(
            modelAdapter: makeModelAdapter(provider: provider, model: model),
            toolRegistry: ToolRegistry(tools: tools),
            persistence: persistence,
            approvalPolicy: approvalPolicy,
            shellExecutionPolicy: shellExecutionPolicy,
            workspaceSnapshot: workspaceSnapshot,
            reasoningSummaryDebugEnabled: userConfig.debug.reasoningSummaries
        )
    }

    func makeShellExecutionPolicy() -> ShellExecutionPolicy {
        let shellPolicy = ShellCommandPolicy(config: userConfig.shell)
        return ShellExecutionPolicy(
            sandbox: userConfig.sandbox,
            network: userConfig.network,
            shell: shellPolicy
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
        if shouldUseEshBridge(provider: provider) { return }

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
        case "dflash":
            return ProcessInfo.processInfo.environment["DFLASH_MODEL"] ?? "Qwen/Qwen3.5-4B"
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
        case "dflash":
            return ProcessInfo.processInfo.environment["DFLASH_MODEL"]
        case "ollama":
            return ProcessInfo.processInfo.environment["OLLAMA_MODEL"]
        default:
            return nil
        }
    }

    static func ollamaRequestTimeoutSeconds(config: OllamaConfig) -> Int {
        if let raw = ProcessInfo.processInfo.environment["OLLAMA_REQUEST_TIMEOUT_SECONDS"],
           let parsed = Int(raw),
           parsed >= 15 {
            return parsed
        }
        return max(config.requestTimeoutSeconds, OllamaConfig.default.requestTimeoutSeconds)
    }

    static func ollamaContextWindowTokens(config: OllamaConfig) -> Int {
        if let raw = ProcessInfo.processInfo.environment["OLLAMA_CONTEXT_WINDOW_TOKENS"],
           let parsed = Int(raw),
           parsed >= 512 {
            return parsed
        }
        return config.contextWindowTokens
    }

    private func makeOptimizedAdapterIfNeeded(
        baseAdapter: any ModelAdapter,
        provider: String,
        model: String
    ) -> any ModelAdapter {
        guard let executablePath = resolvedEshExecutablePathIfEnabled(for: provider) else {
            return baseAdapter
        }

        let optimization = userConfig.optimization
        let inspector = EshOptimizationInspector()
        guard FileManager.default.fileExists(atPath: executablePath) else {
            return baseAdapter
        }
        let homePath = inspector.resolveHomePath(config: optimization.esh)
        let repoRootPath = optimization.esh.repoRootPath ?? workspaceRoot.path

        return EshBackedModelAdapter(
            configuration: .init(
                executablePath: executablePath,
                homePath: homePath,
                repoRootPath: repoRootPath,
                model: model,
                providerID: provider,
                optimization: optimization,
                requestTimeoutSeconds: Self.ollamaRequestTimeoutSeconds(config: userConfig.ollama)
            ),
            fallback: baseAdapter
        )
    }

    private func shouldUseEshBridge(provider: String) -> Bool {
        resolvedEshExecutablePathIfEnabled(for: provider) != nil
    }

    private func resolvedEshExecutablePathIfEnabled(for provider: String) -> String? {
        guard provider == "ollama" else { return nil }
        let optimization = userConfig.optimization
        guard optimization.enabled, optimization.backend == .esh else { return nil }

        let inspector = EshOptimizationInspector()
        guard let executablePath = inspector.resolveExecutablePath(config: optimization.esh),
              FileManager.default.fileExists(atPath: executablePath) else {
            return nil
        }
        return executablePath
    }

    func resolvedAPIKey(for provider: String) throws -> String? {
        if let envKey = ProcessInfo.processInfo.environment[Self.environmentAPIKeyName(for: provider)], !envKey.isEmpty {
            return envKey
        }

        let secretStore = makeSecretStore()
        if let stored = try secretStore.readSecret(namespace: SessionSetting.credentialsNamespace, key: Self.apiKeySettingKey(for: provider)),
           !stored.isEmpty {
            return stored
        }

        let store = try Self.makeSettingsStore(storageRoot: storageRoot)
        if let legacy = try store.fetchSetting(namespace: SessionSetting.credentialsNamespace, key: Self.apiKeySettingKey(for: provider))?.value.stringValue,
           !legacy.isEmpty {
            try? secretStore.writeSecret(namespace: SessionSetting.credentialsNamespace, key: Self.apiKeySettingKey(for: provider), value: legacy)
            return legacy
        }

        return nil
    }

    private func makeAudioTranscriberIfAvailable(for provider: String) -> (any AudioTranscriber)? {
        guard provider == "openai" || provider == "ollama" else {
            return nil
        }

        guard let apiKey = try? resolvedAPIKey(for: "openai"), !apiKey.isEmpty else {
            return nil
        }

        return OpenAIAudioTranscriber(apiKey: apiKey)
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
        store: SQLitePersistenceStore,
        secretStore: any SecretStore
    ) throws -> String? {
        guard let persistedModel, persistedModel != "mock" else { return nil }

        let hasOpenAISecret = (try secretStore.readSecret(
            namespace: SessionSetting.credentialsNamespace,
            key: apiKeySettingKey(for: "openai")
        ))?.isEmpty == false
        let hasLegacyOpenAISecret = try store.fetchSetting(
            namespace: SessionSetting.credentialsNamespace,
            key: apiKeySettingKey(for: "openai")
        )?.value.stringValue?.isEmpty == false

        if persistedModel.hasPrefix("gpt-"),
           hasOpenAISecret || hasLegacyOpenAISecret {
            return "openai"
        }

        let hasAnthropicSecret = (try secretStore.readSecret(
            namespace: SessionSetting.credentialsNamespace,
            key: apiKeySettingKey(for: "anthropic")
        ))?.isEmpty == false
        let hasLegacyAnthropicSecret = try store.fetchSetting(
            namespace: SessionSetting.credentialsNamespace,
            key: apiKeySettingKey(for: "anthropic")
        )?.value.stringValue?.isEmpty == false

        if persistedModel.hasPrefix("claude"),
           hasAnthropicSecret || hasLegacyAnthropicSecret {
            return "anthropic"
        }

        return nil
    }

    func makeSecretStore() -> any SecretStore {
        LocalJSONSecretStore(fileURL: storageRoot.appendingPathComponent("secrets.json"))
    }

    private static func makeSettingsStore(storageRoot: URL) throws -> SQLitePersistenceStore {
        let store = SQLitePersistenceStore(databaseURL: storageRoot.appendingPathComponent("ashex.sqlite"))
        try store.initialize()
        return store
    }

    static func ollamaBaseURL() -> URL {
        URL(string: ProcessInfo.processInfo.environment["OLLAMA_BASE_URL"] ?? "http://localhost:11434/api/chat")!
    }

    static func dflashBaseURL(config: DFlashConfig) -> URL {
        URL(string: ProcessInfo.processInfo.environment["DFLASH_BASE_URL"] ?? config.baseURL)!
    }

    static func validateDFlashSupport() throws {
#if arch(arm64)
        return
#else
        throw AshexError.model("DFlash is currently supported only on Apple Silicon builds of Ashex.")
#endif
    }
}
