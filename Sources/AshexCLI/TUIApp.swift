import AshexCore
import Darwin
import Foundation

@MainActor
final class TUIApp {
    private enum InputMode {
        case prompt
        case model
        case apiKey
        case workspacePath
        case terminalCommand
    }

    private struct MenuItem {
        let title: String
        let subtitle: String
        let action: Action
    }

    private enum Action {
        case compose
        case commands
        case terminal
        case workspaces
        case history
        case settings
        case help
        case quit
    }

    private enum FocusArea {
        case launcher
        case workspaces
        case history
        case settings
        case transcript
        case terminal
        case input
        case approval
    }

    private enum SettingsAction: String, CaseIterable {
        case workspace = "Workspace"
        case provider = "Provider"
        case model = "Model"
        case apiKey = "API Key"
        case refresh = "Refresh Status"
        case back = "Back"
    }

    struct ProviderStatusSnapshot {
        let headline: String
        let details: [String]
        let availableModels: [String]
        let guardrailAssessment: ModelGuardrailAssessment?

        static let idle = Self(
            headline: "Status not checked yet",
            details: ["Open settings and choose Refresh Status to verify the active provider."],
            availableModels: [],
            guardrailAssessment: nil
        )
    }

    private let configuration: CLIConfiguration
    private var runtime: AgentRuntime
    private var historyStore: SQLitePersistenceStore
    private let secretStore: any SecretStore
    private let terminal = TerminalController()
    private let surface = TerminalSurface()
    private let approvalCoordinator: TUIApprovalCoordinator
    private let menuItems: [MenuItem] = [
        .init(title: "New Prompt", subtitle: "Write your own instruction", action: .compose),
        .init(title: "Commands", subtitle: "See available tools, operations, and config policy", action: .commands),
        .init(title: "Terminal", subtitle: "Toggle the side shell pane for quick workspace commands", action: .terminal),
        .init(title: "Workspaces", subtitle: "Switch between recent project roots and inspect their latest history", action: .workspaces),
        .init(title: "History", subtitle: "Browse persisted threads and run transcripts", action: .history),
        .init(title: "Provider Settings", subtitle: "Switch backend and edit the active model", action: .settings),
        .init(title: "Help", subtitle: "Show keyboard shortcuts and behavior", action: .help),
        .init(title: "Quit", subtitle: "Exit Ashex", action: .quit),
    ]

    private var focus: FocusArea = .launcher
    private var selectedIndex = 0
    private var settingsSelection = 0
    private var promptText = ""
    private var modelInput = ""
    private var apiKeyInput = ""
    private var workspacePathInput = ""
    private var terminalCommandInput = ""
    private var inputMode: InputMode = .prompt
    private var showHelp = false
    private var showCommands = false
    private var showWorkspaces = false
    private var showHistory = false
    private var showSettings = false
    private var showTerminalPane = false
    private var statusLine = "Ready"
    private var runLines: [String] = []
    private var runFinished = true
    private var runTask: Task<Void, Never>?
    private var runExecutionControl: ExecutionControl?
    private var workingIndicatorTask: Task<Void, Never>?
    private var runStartedAt: Date?
    private var workingFrameIndex = 0
    private var transcriptScrollOffset = 0
    private var terminalScrollOffset = 0
    private var showToolDetails = false
    private var providerStatus = ProviderStatusSnapshot.idle
    private var shouldQuit = false
    private var pendingApproval: PendingApproval?
    private var sessionWorkspaceRoot: URL
    private var sessionStorageRoot: URL
    private var sessionUserConfig: AshexUserConfig
    private var sessionUserConfigFile: URL
    private var sessionGlobalUserConfigFile: URL?
    private var sessionProvider: String
    private var sessionModel: String
    private var providerStartupIssue: String?
    private var historyThreads: [ThreadSummary] = []
    private var historyRuns: [UUID: [RunRecord]] = [:]
    private var historySelection = 0
    private var historyPreviewLines: [String] = []
    private var recentWorkspaces: [RecentWorkspaceRecord] = []
    private var workspaceSelection = 0
    private var workspacePreviewLines: [String] = []
    private var terminalLines: [String] = ["No terminal commands yet. Open the pane and run one from the input bar."]
    private var terminalTask: Task<Void, Never>?
    private var terminalCancellation = CancellationToken()
    private var currentRunPhase: String?
    private var currentChangedFiles: [String] = []
    private var currentPlannedFiles: [String] = []
    private var currentPatchObjectives: [String] = []
    private var sessionInspector: SessionInspector

    init(configuration: CLIConfiguration) throws {
        let approvalCoordinator = TUIApprovalCoordinator()
        let historyStore = SQLitePersistenceStore(databaseURL: configuration.storageRoot.appendingPathComponent("ashex.sqlite"))
        self.configuration = configuration
        self.historyStore = historyStore
        self.secretStore = configuration.makeSecretStore()
        self.approvalCoordinator = approvalCoordinator
        self.sessionWorkspaceRoot = configuration.workspaceRoot
        self.sessionStorageRoot = configuration.storageRoot
        self.sessionUserConfig = configuration.userConfig
        self.sessionUserConfigFile = configuration.userConfigFile
        self.sessionGlobalUserConfigFile = configuration.globalUserConfigFile
        self.sessionProvider = configuration.provider
        self.sessionModel = configuration.model
        let approvalPolicy: any ApprovalPolicy = configuration.approvalMode == .guarded
            ? TUIApprovalPolicy(coordinator: approvalCoordinator)
            : TrustedApprovalPolicy()
        do {
            self.runtime = try configuration.makeRuntime(
                provider: configuration.provider,
                model: configuration.model,
                approvalPolicy: approvalPolicy
            )
        } catch {
            self.runtime = try configuration.makeRuntime(
                provider: "mock",
                model: CLIConfiguration.defaultModel(for: "mock"),
                approvalPolicy: approvalPolicy
            )
            self.providerStartupIssue = error.localizedDescription
            self.providerStatus = .init(
                headline: "Provider needs attention",
                details: [
                    error.localizedDescription,
                    "The TUI is running with a safe mock fallback so you can still browse history and adjust Provider Settings.",
                    Self.recoveryHint(for: configuration.provider)
                ],
                availableModels: [],
                guardrailAssessment: nil
            )
        }
        self.sessionInspector = SessionInspector(persistence: historyStore)
        approvalCoordinator.handler = { [weak self] request in
            guard let self else { return .deny("TUI is unavailable") }
            return await self.requestApproval(request)
        }
        try historyStore.initialize()
        try? RecentWorkspaceStore.record(workspaceURL: configuration.workspaceRoot)
        loadRecentWorkspaces()
        Task { [weak self] in
            await self?.refreshProviderStatus()
        }
    }

    private static func recoveryHint(for provider: String) -> String {
        switch provider {
        case "openai":
            return "Set OPENAI_API_KEY, then open Provider Settings and refresh or keep using mock."
        case "anthropic":
            return "Add ANTHROPIC_API_KEY in Provider Settings or the environment, then refresh or keep using mock."
        case "ollama":
            return "Start Ollama with `ollama serve`, then open Provider Settings and refresh or switch to mock."
        default:
            return "Open Provider Settings to choose a working provider."
        }
    }

    func run() async throws {
        try terminal.enterRawMode()
        defer { terminal.leaveRawMode() }

        let keyStream = terminal.makeKeyStream()
        render()

        for await key in keyStream {
            handle(key: key)
            render()
            if shouldQuit { break }
        }
    }

    private func handle(key: TerminalKey) {
        if pendingApproval != nil {
            focus = .approval
            handleApproval(key: key)
            return
        }

        switch key {
        case .tab:
            cycleFocus()
        case .up:
            handleUp()
        case .down:
            handleDown()
        case .pageUp:
            handlePageUp()
        case .pageDown:
            handlePageDown()
        case .home:
            handleHome()
        case .end:
            handleEnd()
        case .enter:
            handleEnter()
        case .backspace:
            handleBackspace()
        case .escape, .left:
            handleBack()
        case .character("k") where focus == .launcher:
            moveSelection(-1)
        case .character("j") where focus == .launcher:
            moveSelection(1)
        case .character("k") where focus == .transcript:
            scrollTranscript(by: 1)
        case .character("j") where focus == .transcript:
            scrollTranscript(by: -1)
        case .character("K") where focus == .transcript:
            scrollTranscriptPage(direction: .older)
        case .character("J") where focus == .transcript:
            scrollTranscriptPage(direction: .newer)
        case .character("g") where focus == .transcript:
            jumpTranscriptToTop()
        case .character("G") where focus == .transcript:
            jumpTranscriptToBottom()
        case .character("k") where focus == .terminal:
            scrollTerminal(by: 1)
        case .character("j") where focus == .terminal:
            scrollTerminal(by: -1)
        case .character("K") where focus == .terminal:
            scrollTerminalPage(direction: .older)
        case .character("J") where focus == .terminal:
            scrollTerminalPage(direction: .newer)
        case .character("g") where focus == .terminal:
            jumpTerminalToTop()
        case .character("G") where focus == .terminal:
            jumpTerminalToBottom()
        case .character("t") where focus != .input:
            toggleTerminalPane()
        case .character("T") where focus != .input:
            toggleTerminalPane()
        case .character("e") where focus == .transcript:
            showToolDetails.toggle()
            statusLine = showToolDetails ? "Expanded tool details" : "Collapsed tool details"
        case .character("x") where !runFinished:
            requestSkipCurrentStep()
        case .character("X") where !runFinished:
            requestSkipCurrentStep()
        case .character("E") where focus == .transcript:
            showToolDetails.toggle()
            statusLine = showToolDetails ? "Expanded tool details" : "Collapsed tool details"
        case .character(let character):
            handleCharacter(character)
        case .space:
            handleCharacter(" ")
        default:
            break
        }
    }

    private func cycleFocus() {
        if showSettings {
            switch focus {
            case .launcher:
                focus = .settings
            case .workspaces:
                focus = .settings
            case .history:
                focus = .settings
            case .settings:
                focus = .transcript
            case .transcript:
                focus = showTerminalPane ? .terminal : .input
            case .terminal:
                focus = .input
            case .input:
                focus = .launcher
            case .approval:
                break
            }
            statusLine = "Focus: \(focusLabel)"
            return
        }

        if showHistory {
            switch focus {
            case .launcher:
                focus = .history
            case .workspaces:
                focus = .history
            case .history:
                focus = .transcript
            case .transcript:
                focus = showTerminalPane ? .terminal : .input
            case .terminal:
                focus = .input
            case .settings:
                focus = .input
            case .input:
                focus = .launcher
            case .approval:
                break
            }
            statusLine = "Focus: \(focusLabel)"
            return
        }

        if showWorkspaces {
            switch focus {
            case .launcher:
                focus = .workspaces
            case .workspaces:
                focus = .transcript
            case .history:
                focus = .transcript
            case .settings:
                focus = .transcript
            case .transcript:
                focus = showTerminalPane ? .terminal : .input
            case .terminal:
                focus = .input
            case .input:
                focus = .launcher
            case .approval:
                break
            }
            statusLine = "Focus: \(focusLabel)"
            return
        }

        switch focus {
        case .launcher:
            focus = .transcript
        case .transcript:
            focus = showTerminalPane ? .terminal : .input
        case .terminal:
            focus = .input
        case .workspaces:
            focus = .input
        case .history:
            focus = .input
        case .settings:
            focus = .input
        case .input:
            focus = .launcher
        case .approval:
            break
        }
        statusLine = "Focus: \(focusLabel)"
    }

    private func handleUp() {
        switch focus {
        case .launcher:
            moveSelection(-1)
        case .workspaces:
            workspaceSelection = max(workspaceSelection - 1, 0)
            refreshWorkspacePreview()
        case .history:
            historySelection = max(historySelection - 1, 0)
            refreshHistoryPreview()
        case .settings:
            settingsSelection = max(settingsSelection - 1, 0)
        case .transcript:
            scrollTranscript(by: 1)
        case .terminal:
            scrollTerminal(by: 1)
        case .input, .approval:
            break
        }
    }

    private func handleDown() {
        switch focus {
        case .launcher:
            moveSelection(1)
        case .workspaces:
            workspaceSelection = min(workspaceSelection + 1, max(recentWorkspaces.count - 1, 0))
            refreshWorkspacePreview()
        case .history:
            historySelection = min(historySelection + 1, max(historyThreads.count - 1, 0))
            refreshHistoryPreview()
        case .settings:
            settingsSelection = min(settingsSelection + 1, SettingsAction.allCases.count - 1)
        case .transcript:
            scrollTranscript(by: -1)
        case .terminal:
            scrollTerminal(by: -1)
        case .input, .approval:
            break
        }
    }

    private func handlePageUp() {
        switch focus {
        case .transcript:
            scrollTranscriptPage(direction: .older)
        case .terminal:
            scrollTerminalPage(direction: .older)
        default:
            return
        }
    }

    private func handlePageDown() {
        switch focus {
        case .transcript:
            scrollTranscriptPage(direction: .newer)
        case .terminal:
            scrollTerminalPage(direction: .newer)
        default:
            return
        }
    }

    private func handleHome() {
        switch focus {
        case .transcript:
            jumpTranscriptToTop()
        case .terminal:
            jumpTerminalToTop()
        default:
            return
        }
    }

    private func handleEnd() {
        switch focus {
        case .transcript:
            jumpTranscriptToBottom()
        case .terminal:
            jumpTerminalToBottom()
        default:
            return
        }
    }

    private func handleEnter() {
        if pendingApproval != nil {
            handleApproval(key: .enter)
            return
        }

        switch inputMode {
        case .prompt:
            let prompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prompt.isEmpty {
                if handleLocalPromptCommand(prompt) {
                    return
                }
                startRun(prompt: prompt)
                return
            }
        case .model:
            commitModelInput()
            return
        case .apiKey:
            commitAPIKeyInput()
            return
        case .workspacePath:
            commitWorkspacePathInput()
            return
        case .terminalCommand:
            commitTerminalCommand()
            return
        }

        if focus == .launcher {
            activate(menuItems[selectedIndex].action)
        } else if focus == .workspaces {
            openSelectedWorkspace()
        } else if focus == .history {
            openSelectedHistoryRun()
        } else if focus == .settings {
            activate(settingsAction: SettingsAction.allCases[settingsSelection])
        } else if focus == .input {
            statusLine = inputMode == .prompt ? "Prompt is empty" : "Model name is empty"
        }
    }

    private func handleBackspace() {
        switch inputMode {
        case .prompt:
            guard !promptText.isEmpty else { return }
            promptText.removeLast()
            focus = .input
            statusLine = "Editing prompt"
        case .model:
            guard !modelInput.isEmpty else { return }
            modelInput.removeLast()
            focus = .input
            statusLine = "Editing model"
        case .apiKey:
            guard !apiKeyInput.isEmpty else { return }
            apiKeyInput.removeLast()
            focus = .input
            statusLine = "Editing API key"
        case .workspacePath:
            guard !workspacePathInput.isEmpty else { return }
            workspacePathInput.removeLast()
            focus = .input
            statusLine = "Editing workspace"
        case .terminalCommand:
            guard !terminalCommandInput.isEmpty else { return }
            terminalCommandInput.removeLast()
            focus = .input
            statusLine = "Editing terminal command"
        }
    }

    private func handleBack() {
        if pendingApproval != nil {
            handleApproval(key: .escape)
            return
        }

        if focus == .input {
            switch inputMode {
            case .prompt where !promptText.isEmpty:
                promptText = ""
                statusLine = "Cleared prompt"
                return
            case .model where !modelInput.isEmpty:
                modelInput = ""
                statusLine = "Cleared model input"
                return
            case .apiKey where !apiKeyInput.isEmpty:
                apiKeyInput = ""
                statusLine = "Cleared API key input"
                return
            case .workspacePath where !workspacePathInput.isEmpty:
                workspacePathInput = ""
                statusLine = "Cleared workspace input"
                return
            case .terminalCommand where !terminalCommandInput.isEmpty:
                terminalCommandInput = ""
                statusLine = "Cleared terminal input"
                return
            case .model:
                inputMode = .prompt
                focus = showSettings ? .settings : .launcher
                statusLine = "Back to settings"
                return
            case .apiKey:
                inputMode = .prompt
                focus = showSettings ? .settings : .launcher
                statusLine = "Back to settings"
                return
            case .workspacePath:
                inputMode = .prompt
                focus = showSettings ? .settings : .launcher
                statusLine = "Back to settings"
                return
            case .terminalCommand:
                inputMode = .prompt
                showTerminalPane = false
                focus = .launcher
                statusLine = "Back to launcher"
                return
            default:
                break
            }
        }

        if showTerminalPane && focus == .terminal {
            showTerminalPane = false
            inputMode = .prompt
            focus = .launcher
            statusLine = "Back to launcher"
            return
        }

        if showSettings {
            showSettings = false
            inputMode = .prompt
            focus = .launcher
            statusLine = "Back to launcher"
            return
        }

        if showCommands {
            showCommands = false
            focus = .launcher
            statusLine = "Back to launcher"
            return
        }

        if showHistory {
            showHistory = false
            focus = .launcher
            statusLine = "Back to launcher"
            return
        }

        if showWorkspaces {
            showWorkspaces = false
            focus = .launcher
            statusLine = "Back to launcher"
            return
        }

        if showHelp {
            showHelp = false
            focus = .launcher
            statusLine = "Back to launcher"
            return
        }

        if !runFinished && !runLines.isEmpty {
            runExecutionControl = nil
            runTask?.cancel()
            runTask = nil
            stopWorkingIndicator()
            runFinished = true
            runLines.append("[local] Run cancelled from TUI")
            statusLine = "Run cancelled"
            return
        }

        shouldQuit = true
    }

    private func handleCharacter(_ character: Character) {
        switch inputMode {
        case .prompt:
            promptText.append(character)
            statusLine = "Editing prompt"
        case .model:
            modelInput.append(character)
            statusLine = "Editing model"
        case .apiKey:
            apiKeyInput.append(character)
            statusLine = "Editing API key"
        case .workspacePath:
            workspacePathInput.append(character)
            statusLine = "Editing workspace"
        case .terminalCommand:
            terminalCommandInput.append(character)
            statusLine = "Editing terminal command"
        }
        focus = .input
        if inputMode == .prompt {
            showHelp = false
            showSettings = false
            showCommands = false
        }
    }

    private func moveSelection(_ delta: Int) {
        selectedIndex = min(max(selectedIndex + delta, 0), menuItems.count - 1)
    }

    private func handleApproval(key: TerminalKey) {
        guard let pendingApproval else { return }
        switch key {
        case .character("y"), .character("Y"), .enter:
            pendingApproval.resume(.allow("Approved from TUI"))
            self.pendingApproval = nil
            focus = .launcher
            statusLine = "Approval granted"
        case .character("n"), .character("N"), .escape, .left:
            pendingApproval.resume(.deny("Denied from TUI"))
            self.pendingApproval = nil
            focus = .launcher
            statusLine = "Approval denied"
        default:
            break
        }
    }

    private func activate(_ action: Action) {
        switch action {
        case .compose:
            inputMode = .prompt
            showHistory = false
            showWorkspaces = false
            showSettings = false
            showCommands = false
            focus = .input
            showHelp = false
            statusLine = "Write a prompt below and press Enter"
        case .commands:
            showCommands = true
            showHistory = false
            showWorkspaces = false
            showSettings = false
            showHelp = false
            focus = .launcher
            statusLine = "Commands"
        case .terminal:
            toggleTerminalPane()
        case .workspaces:
            showWorkspaces = true
            showHistory = false
            showSettings = false
            showCommands = false
            showHelp = false
            loadRecentWorkspaces()
            focus = .workspaces
            statusLine = recentWorkspaces.isEmpty ? "No recent workspaces yet" : "Workspaces"
        case .history:
            showHistory = true
            showWorkspaces = false
            showSettings = false
            showCommands = false
            showHelp = false
            focus = .history
            loadHistory()
            statusLine = historyThreads.isEmpty ? "No stored history yet" : "History"
        case .settings:
            showSettings = true
            showHistory = false
            showWorkspaces = false
            showCommands = false
            showHelp = false
            focus = .settings
            statusLine = "Provider settings"
        case .help:
            showHelp = true
            showHistory = false
            showWorkspaces = false
            showSettings = false
            showCommands = false
            focus = .launcher
            statusLine = "Help"
        case .quit:
            shouldQuit = true
        }
    }

    private func activate(settingsAction: SettingsAction) {
        switch settingsAction {
        case .workspace:
            inputMode = .workspacePath
            workspacePathInput = sessionWorkspaceRoot.path
            focus = .input
            statusLine = "Enter a project directory and press Enter"
        case .provider:
            cycleProvider()
        case .model:
            inputMode = .model
            modelInput = sessionModel
            focus = .input
            statusLine = "Edit model and press Enter to apply"
        case .apiKey:
            inputMode = .apiKey
            apiKeyInput = ""
            focus = .input
            statusLine = "Enter API key and press Enter to save"
        case .refresh:
            statusLine = "Refreshing provider status"
            Task { [weak self] in
                await self?.refreshProviderStatus()
            }
        case .back:
            showSettings = false
            inputMode = .prompt
            focus = .launcher
            statusLine = "Back to launcher"
        }
    }

    private func cycleProvider() {
        let providers = ["mock", "ollama", "openai", "anthropic"]
        let currentIndex = providers.firstIndex(of: sessionProvider) ?? 0
        let nextProvider = providers[(currentIndex + 1) % providers.count]

        sessionProvider = nextProvider
        sessionModel = CLIConfiguration.defaultModel(for: nextProvider)
        refreshSessionRuntime()
        persistSessionSettings()
        statusLine = "Provider switched to \(sessionProvider)"

        Task { [weak self] in
            await self?.refreshProviderStatus()
        }
    }

    private func toggleTerminalPane() {
        showTerminalPane.toggle()
        if showTerminalPane {
            focus = .terminal
            inputMode = .terminalCommand
            statusLine = "Terminal pane opened"
        } else {
            if focus == .terminal {
                focus = .launcher
            }
            if inputMode == .terminalCommand {
                inputMode = .prompt
            }
            statusLine = "Terminal pane hidden"
        }
    }

    private func commitModelInput() {
        let trimmed = modelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusLine = "Model name is empty"
            return
        }

        sessionModel = trimmed
        inputMode = .prompt
        focus = showSettings ? .settings : .launcher

        refreshSessionRuntime()
        persistSessionSettings()
        statusLine = "Model updated to \(sessionModel)"

        Task { [weak self] in
            await self?.refreshProviderStatus()
        }
    }

    private func commitWorkspacePathInput() {
        let trimmed = workspacePathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusLine = "Workspace path is empty"
            return
        }

        let proposed = URL(
            fileURLWithPath: trimmed,
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ).standardizedFileURL

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: proposed.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            statusLine = "Workspace directory not found"
            return
        }

        do {
            let loadedConfig = try UserConfigStore.loadMerged(for: proposed)
            let storageRoot = proposed.appendingPathComponent(".ashex")
            let store = SQLitePersistenceStore(databaseURL: storageRoot.appendingPathComponent("ashex.sqlite"))
            try store.initialize()

            sessionWorkspaceRoot = proposed
            sessionStorageRoot = storageRoot
            sessionUserConfig = loadedConfig.effectiveConfig
            sessionUserConfigFile = loadedConfig.workspaceFileURL
            sessionGlobalUserConfigFile = loadedConfig.globalFileURL
            historyStore = store
            sessionInspector = SessionInspector(persistence: store)
            inputMode = .prompt
            workspacePathInput = ""
            focus = .transcript
            showSettings = false
            showWorkspaces = false
            runLines = ["[local] Switched workspace to \(proposed.path)"]
            runFinished = true
            transcriptScrollOffset = 0
            try? RecentWorkspaceStore.record(workspaceURL: proposed)
            loadRecentWorkspaces()
            refreshSessionRuntime()
            loadHistory()
            statusLine = "Workspace updated"
        } catch {
            statusLine = "Failed to switch workspace"
        }
    }

    private func commitTerminalCommand() {
        let command = terminalCommandInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            statusLine = "Terminal command is empty"
            return
        }

        terminalTask?.cancel()
        let cancellation = CancellationToken()
        terminalCancellation = cancellation
        terminalCommandInput = ""
        terminalScrollOffset = 0
        showTerminalPane = true
        focus = .terminal
        inputMode = .terminalCommand
        statusLine = "Running terminal command"
        terminalLines.append("[command] \(command)")

        let runtime = ProcessExecutionRuntime()
        let shellPolicy = ShellCommandPolicy(config: sessionUserConfig.shell)
        let executionPolicy = ShellExecutionPolicy(
            sandbox: sessionUserConfig.sandbox,
            network: sessionUserConfig.network,
            shell: shellPolicy
        )
        switch executionPolicy.assess(command: command) {
        case .allow:
            break
        case .deny(let message):
            terminalLines.append("[error] \(message)")
            statusLine = "Terminal command blocked"
            render()
            return
        case .requireApproval(let message):
            guard configuration.approvalMode == .guarded else {
                terminalLines.append("[error] \(message)")
                statusLine = "Terminal command requires guarded approval mode"
                render()
                return
            }

            Task { [weak self] in
                guard let self else { return }
                let decision = await self.requestApproval(
                    ApprovalRequest(
                        runID: UUID(),
                        toolName: "shell",
                        arguments: ["command": .string(command)],
                        summary: "Terminal command requires approval",
                        reason: "\(command)\n\(message)",
                        risk: ShellExecutionPolicy.isNetworkCommand(command.lowercased()) ? .high : .medium
                    )
                )

                await MainActor.run {
                    guard decision.allowed else {
                        self.terminalLines.append("[approval] denied - \(decision.reason)")
                        self.statusLine = "Terminal command denied"
                        self.render()
                        return
                    }
                    self.runApprovedTerminalCommand(command: command, runtime: runtime, executionPolicy: executionPolicy, cancellation: cancellation)
                }
            }
            return
        }

        runApprovedTerminalCommand(command: command, runtime: runtime, executionPolicy: executionPolicy, cancellation: cancellation)
    }

    private func runApprovedTerminalCommand(
        command: String,
        runtime: ProcessExecutionRuntime,
        executionPolicy: ShellExecutionPolicy,
        cancellation: CancellationToken
    ) {
        let request = ShellExecutionRequest(
            command: command,
            workspaceURL: sessionWorkspaceRoot,
            timeout: 30,
            executionPolicy: executionPolicy
        )

        terminalTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await runtime.execute(
                    request,
                    cancellationToken: cancellation,
                    onStdout: { [weak self] chunk in
                        Task { @MainActor [weak self] in
                            self?.appendTerminalChunks(prefix: "[stdout]", chunk: chunk)
                        }
                    },
                    onStderr: { [weak self] chunk in
                        Task { @MainActor [weak self] in
                            self?.appendTerminalChunks(prefix: "[stderr]", chunk: chunk)
                        }
                    }
                )

                await MainActor.run {
                    self.terminalLines.append("[exit] code \(result.exitCode)\(result.timedOut ? " (timed out)" : "")")
                    self.terminalTask = nil
                    self.statusLine = "Terminal command finished"
                    self.render()
                }
            } catch {
                await MainActor.run {
                    self.terminalLines.append("[error] \(error.localizedDescription)")
                    self.terminalTask = nil
                    self.statusLine = "Terminal command failed"
                    self.render()
                }
            }
        }
    }

    private func commitAPIKeyInput() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusLine = "API key is empty"
            return
        }

        let normalized = normalizeAPIKeyInput(trimmed, for: sessionProvider)
        guard !normalized.isEmpty else {
            statusLine = "Could not detect a valid API key in the pasted text"
            return
        }

        do {
            let keyName = CLIConfiguration.apiKeySettingKey(for: sessionProvider)
            try secretStore.writeSecret(namespace: "provider.credentials", key: keyName, value: normalized)
            apiKeyInput = ""
            inputMode = .prompt
            focus = .settings
            refreshSessionRuntime()
            statusLine = normalized == trimmed
                ? "API key saved for \(sessionProvider)"
                : "API key extracted and saved for \(sessionProvider)"
        } catch {
            statusLine = "Failed to save API key"
        }

        Task { [weak self] in
            await self?.refreshProviderStatus()
        }
    }

    private func refreshSessionRuntime() {
        do {
            runtime = try makeSessionRuntime()
        } catch {
            runtime = try! makeSessionRuntime(provider: "mock", model: CLIConfiguration.defaultModel(for: "mock"))
            providerStatus = .init(
                headline: "Provider needs attention",
                details: [
                    error.localizedDescription,
                    "Ashex kept the TUI running with a safe mock fallback.",
                    Self.recoveryHint(for: sessionProvider)
                ],
                availableModels: [],
                guardrailAssessment: nil
            )
            statusLine = "Provider needs attention"
        }
    }

    @discardableResult
    private func handleLocalPromptCommand(_ prompt: String) -> Bool {
        guard let command = LocalPromptCommand.parse(prompt) else {
            return false
        }

        switch command {
        case .showWorkspace:
            runTask?.cancel()
            runExecutionControl = nil
            stopWorkingIndicator()
            runLines = [
                "Prompt: /pwd",
                "",
                "[local] Current workspace",
                sessionWorkspaceRoot.path
            ]
            transcriptScrollOffset = 0
            runFinished = true
            runStartedAt = nil
            promptText = ""
            inputMode = .prompt
            showSettings = false
            showHelp = false
            showHistory = false
            focus = .transcript
            statusLine = "Workspace shown"
            return true
        case .showSandbox:
            runTask?.cancel()
            runExecutionControl = nil
            stopWorkingIndicator()
            let globalConfigLine = sessionGlobalUserConfigFile?.path ?? "<none>"
            let rules = sessionUserConfig.shell.rules.isEmpty
                ? "none"
                : sessionUserConfig.shell.rules.map { "\($0.action.rawValue): \($0.prefix)" }.joined(separator: ", ")
            runLines = [
                "Prompt: /sandbox",
                "",
                "[local] Sandbox policy",
                "Mode: \(sessionUserConfig.sandbox.mode.rawValue)",
                "Network mode: \(sessionUserConfig.network.mode.rawValue)",
                "Protected paths: \(sessionUserConfig.sandbox.protectedPaths.isEmpty ? "none" : sessionUserConfig.sandbox.protectedPaths.joined(separator: ", "))",
                "Unknown commands require approval: \(sessionUserConfig.shell.requireApprovalForUnknownCommands ? "yes" : "no")",
                "Rule actions: \(rules)",
                "Network rules: \(sessionUserConfig.network.rules.isEmpty ? "none" : sessionUserConfig.network.rules.map { "\($0.action.rawValue): \($0.prefix)" }.joined(separator: ", "))",
                "Workspace config: \(sessionUserConfigFile.path)",
                "Global config: \(globalConfigLine)",
            ]
            transcriptScrollOffset = 0
            runFinished = true
            runStartedAt = nil
            promptText = ""
            inputMode = .prompt
            showSettings = false
            showHelp = false
            showHistory = false
            focus = .transcript
            statusLine = "Sandbox policy shown"
            return true
        case .openWorkspaces:
            runLines = [
                "Prompt: /workspaces",
                "",
                "[local] Workspaces",
                "Open the Workspaces view to preview and switch recent project roots."
            ]
            transcriptScrollOffset = 0
            runFinished = true
            runStartedAt = nil
            promptText = ""
            inputMode = .prompt
            showHistory = false
            showHelp = false
            showCommands = false
            showSettings = false
            showWorkspaces = true
            loadRecentWorkspaces()
            focus = .workspaces
            statusLine = recentWorkspaces.isEmpty ? "No recent workspaces yet" : "Workspaces"
            return true
        case .showHelp:
            runLines = ["Prompt: \(prompt.trimmingCharacters(in: .whitespacesAndNewlines))", ""] + LocalPromptCommand.helpLines
            transcriptScrollOffset = 0
            runFinished = true
            runStartedAt = nil
            promptText = ""
            inputMode = .prompt
            focus = .transcript
            statusLine = "Workspace command help"
            return true
        case .switchWorkspace(let workspacePath):
            promptText = ""
            workspacePathInput = workspacePath
            commitWorkspacePathInput()
            return true
        }
    }

    private func startRun(prompt: String) {
        runTask?.cancel()
        let executionControl = ExecutionControl()
        runExecutionControl = executionControl
        runLines = [
            "Prompt: \(prompt)",
            ""
        ]
        transcriptScrollOffset = 0
        runFinished = false
        runStartedAt = Date()
        workingFrameIndex = 0
        currentRunPhase = nil
        currentChangedFiles = []
        promptText = ""
        inputMode = .prompt
        showSettings = false
        showHelp = false
        showHistory = false
        focus = .transcript
        statusLine = "Checking model guardrails"
        startWorkingIndicator()
        runTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await self.validateRunGuardrails()
                await MainActor.run {
                    self.statusLine = "Running"
                }

                let stream = self.runtime.run(.init(
                    prompt: prompt,
                    maxIterations: self.configuration.maxIterations,
                    executionControl: executionControl
                ))
                for await event in stream {
                    await MainActor.run {
                        self.append(event: event)
                    }
                }
                await MainActor.run {
                    self.runExecutionControl = nil
                    self.finishRun()
                }
            } catch {
                await MainActor.run {
                    self.runExecutionControl = nil
                    self.stopWorkingIndicator()
                    self.runLines.append("[error] \(error.localizedDescription)")
                    self.runFinished = true
                    self.runStartedAt = nil
                    self.statusLine = "Run blocked"
                    self.render()
                }
            }
        }
    }

    private func append(event: RuntimeEvent) {
        let shouldFollowTail = isTranscriptNearBottom()
        updateLiveRunState(from: event.payload)
        runLines.append(contentsOf: renderLines(for: event.payload))
        if shouldFollowTail {
            transcriptScrollOffset = 0
        }

        render()
    }

    private func finishRun() {
        stopWorkingIndicator()
        runExecutionControl = nil
        runFinished = true
        runStartedAt = nil
        if statusLine == "Running" {
            statusLine = "Run finished"
        }
        render()
    }

    private func updateLiveRunState(from payload: RuntimeEventPayload) {
        switch payload {
        case .workflowPhaseChanged(_, let phase, _):
            currentRunPhase = phase
        case .changedFilesTracked(_, let paths):
            for path in paths where !currentChangedFiles.contains(path) {
                currentChangedFiles.append(path)
            }
        case .patchPlanUpdated(_, let paths, let objectives):
            currentPlannedFiles = paths
            currentPatchObjectives = objectives
        case .runStarted:
            currentRunPhase = nil
            currentChangedFiles = []
            currentPlannedFiles = []
            currentPatchObjectives = []
        default:
            break
        }
    }

    private func requestSkipCurrentStep() {
        guard let runExecutionControl else { return }
        Task {
            await runExecutionControl.requestSkipCurrentStep()
        }
        runLines.append("[local] Requested skip for the current step")
        statusLine = "Skipping current step"
    }

    private func renderLines(for payload: RuntimeEventPayload) -> [String] {
        switch payload {
        case .runStarted(_, let runID):
            return ["[run] started \(runID.uuidString)"]
        case .runStateChanged(_, let state, let reason):
            return ["[state] \(state.rawValue)\(reason.map { " - \($0)" } ?? "")"]
        case .workflowPhaseChanged(_, let phase, let title):
            return ["[phase] \(phase) - \(title)"]
        case .contextPrepared(_, let retainedMessages, let droppedMessages, let clippedMessages, let estimatedTokens, let estimatedContextWindow):
            return ["[context] retained \(retainedMessages), dropped \(droppedMessages), clipped \(clippedMessages), tok~ \(estimatedTokens), ctx~ \(estimatedTokens)/\(estimatedContextWindow)"]
        case .contextCompacted(_, let droppedMessages, let summary):
            var lines = ["[context] compacted \(droppedMessages) earlier messages"]
            if showToolDetails {
                lines.append(contentsOf: summary.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
            }
            return lines
        case .taskPlanCreated(_, let steps):
            var lines = ["[plan] created \(steps.count) steps"]
            lines.append(contentsOf: steps.enumerated().map { "[plan] \($0.offset + 1). \($0.element)" })
            return lines
        case .taskStepStarted(_, let index, let total, let title):
            return ["[plan] step \(index)/\(total) started - \(title)"]
        case .taskStepFinished(_, let index, let total, let title, let outcome):
            return ["[plan] step \(index)/\(total) \(outcome) - \(title)"]
        case .subagentAssigned(_, let title, let role, let goal):
            return ["[subagent] assigned \(role) - \(title)"] + goal.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        case .subagentStarted(_, let title, let maxIterations):
            return ["[subagent] started - \(title) (max \(maxIterations) iterations)"]
        case .subagentHandoff(_, let title, let role, let summary, let remainingItems):
            var lines = ["[subagent] handoff \(role) - \(title)"] + summary.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if !remainingItems.isEmpty {
                lines.append("[subagent] remaining \(remainingItems.joined(separator: ", "))")
            }
            return lines
        case .subagentFinished(_, let title, let summary):
            return ["[subagent] finished - \(title)"] + summary.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        case .changedFilesTracked(_, let paths):
            return ["[change] " + paths.joined(separator: ", ")]
        case .patchPlanUpdated(_, let paths, let objectives):
            var lines = ["[patch-plan] " + (paths.isEmpty ? "forming" : paths.joined(separator: ", "))]
            if !objectives.isEmpty {
                lines.append("[patch-plan] goals " + objectives.joined(separator: " | "))
            }
            return lines
        case .status(_, let message):
            return ["[status] \(message)"]
        case .messageAppended(_, _, let role):
            return ["[message] appended \(role.rawValue)"]
        case .approvalRequested(_, let toolName, let summary, let reason, let risk):
            return ["[approval] request \(toolName) \(summary) (\(risk.rawValue)) - \(reason)"]
        case .approvalResolved(_, let toolName, let allowed, let reason):
            return ["[approval] \(toolName) \(allowed ? "approved" : "denied") - \(reason)"]
        case .toolCallStarted(_, _, let toolName, let arguments):
            var lines = [summarizeToolStart(toolName: toolName, arguments: arguments)]
            if showToolDetails {
                lines.append(contentsOf: JSONValue.object(arguments).prettyPrinted.split(separator: "\n").map(String.init))
            }
            return lines
        case .toolOutput(_, _, let stream, let chunk):
            let prefix = stream == .stderr ? "stderr" : "stdout"
            let normalizedChunk = normalizeStoredTranscriptText(chunk)
            return normalizedChunk
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.isEmpty }
                .map { "[\(prefix)] \($0)" }
        case .toolCallFinished(_, _, let success, let summary):
            let normalizedSummary = normalizeStoredTranscriptText(summary)
            if let data = normalizedSummary.data(using: .utf8),
               let structured = try? JSONDecoder().decode(JSONValue.self, from: data) {
                var lines = [summarizeStructuredCompletion(success: success, value: structured)]
                if showToolDetails {
                    lines.append(contentsOf: renderStructuredValue(structured))
                }
                return lines
            }
            return ["[tool] \(success ? "completed" : "failed") \(normalizedSummary)"]
        case .finalAnswer(_, _, let text):
            let normalizedText = normalizeStoredTranscriptText(text)
            if let structured = formattedStructuredLines(from: normalizedText) {
                return ["", "Final answer:"] + structured
            }
            return ["", "Final answer:"] + normalizedText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        case .error(_, let message):
            return ["[error] \(normalizeStoredTranscriptText(message))"]
        case .runFinished(_, let state):
            return ["[run] finished \(state.rawValue)"]
        }
    }

    private func normalizeStoredTranscriptText(_ text: String) -> String {
        guard !text.contains("\n"), text.contains("\\") else { return text }

        var output = ""
        var iterator = text.makeIterator()

        while let character = iterator.next() {
            guard character == "\\" else {
                output.append(character)
                continue
            }

            guard let next = iterator.next() else {
                output.append(character)
                break
            }

            switch next {
            case "n":
                output.append("\n")
            case "r":
                output.append("\r")
            case "t":
                output.append("\t")
            case "\\":
                output.append("\\")
            case "\"":
                output.append("\"")
            default:
                output.append("\\")
                output.append(next)
            }
        }

        return output
    }

    private func render() {
        let size = terminal.terminalSize()
        let width = max(size.columns, 72)
        var lines = renderHeader(width: width)
        lines.append(TerminalUIStyle.rule(width: width))
        lines.append(contentsOf: renderBody(width: width, height: size.rows))
        lines.append(TerminalUIStyle.rule(width: width))
        lines.append(contentsOf: renderInputBar(width: width))
        lines.append(renderFooter(width: width))
        surface.render(lines: lines, size: size)
    }

    private func renderHeader(width: Int) -> [String] {
        let innerWidth = max(width - 4, 20)
        let title = "\(TerminalUIStyle.bold)\(gradientTitle())\(TerminalUIStyle.reset)"
        let mode = "\(TerminalUIStyle.faint)mode\(TerminalUIStyle.reset) \(TerminalUIStyle.ink)\(screenLabel)\(TerminalUIStyle.reset)"
        let left = "\(title)  \(mode)"
        let purpose = "\(TerminalUIStyle.faint)local agent for workspace tasks: chat, inspect files, run shell, and keep history\(TerminalUIStyle.reset)"

        let provider = "\(TerminalUIStyle.faint)provider\(TerminalUIStyle.reset) \(TerminalUIStyle.blue)\(sessionProvider)\(TerminalUIStyle.reset)"
        let model = "\(TerminalUIStyle.faint)model\(TerminalUIStyle.reset) \(TerminalUIStyle.ink)\(sessionModel)\(TerminalUIStyle.reset)"
        let sandbox = "\(TerminalUIStyle.faint)sandbox\(TerminalUIStyle.reset) \(TerminalUIStyle.cyan)\(sessionUserConfig.sandbox.mode.rawValue)\(TerminalUIStyle.reset)"
        let usage = "\(TerminalUIStyle.faint)tok~\(TerminalUIStyle.reset) \(TerminalUIStyle.ink)\(formattedEstimatedTokens)\(TerminalUIStyle.reset)"
        let context = "\(TerminalUIStyle.faint)ctx~\(TerminalUIStyle.reset) \(TerminalUIStyle.ink)\(formattedContextUsage)\(TerminalUIStyle.reset)"
        let status = "\(statusColor)\(displayStatusLine)\(TerminalUIStyle.reset)"
        let right = "\(provider)  \(TerminalUIStyle.faint)•\(TerminalUIStyle.reset)  \(model)  \(TerminalUIStyle.faint)•\(TerminalUIStyle.reset)  \(sandbox)  \(TerminalUIStyle.faint)•\(TerminalUIStyle.reset)  \(usage)  \(TerminalUIStyle.faint)•\(TerminalUIStyle.reset)  \(context)  \(TerminalUIStyle.faint)•\(TerminalUIStyle.reset)  \(status)"

        let topLine = join(left: left, right: right, width: innerWidth)
        let workspace = "\(TerminalUIStyle.faint)workspace\(TerminalUIStyle.reset) \(TerminalUIStyle.truncateVisible(sessionWorkspaceRoot.path, limit: innerWidth))"
        let workflow = workflowStrip(width: innerWidth)

        return [
            TerminalUIStyle.border + "╭" + String(repeating: "─", count: innerWidth + 2) + "╮" + TerminalUIStyle.reset,
            "\(TerminalUIStyle.border)│ \(TerminalUIStyle.reset)\(TerminalUIStyle.padVisible(topLine, to: innerWidth))\(TerminalUIStyle.border) │\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.border)│ \(TerminalUIStyle.reset)\(TerminalUIStyle.padVisible(TerminalUIStyle.truncateVisible(purpose, limit: innerWidth), to: innerWidth))\(TerminalUIStyle.border) │\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.border)│ \(TerminalUIStyle.reset)\(TerminalUIStyle.padVisible(workspace, to: innerWidth))\(TerminalUIStyle.border) │\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.border)│ \(TerminalUIStyle.reset)\(TerminalUIStyle.padVisible(workflow, to: innerWidth))\(TerminalUIStyle.border) │\(TerminalUIStyle.reset)",
            TerminalUIStyle.border + "╰" + String(repeating: "─", count: innerWidth + 2) + "╯" + TerminalUIStyle.reset
        ]
    }

    private func workflowStrip(width: Int) -> String {
        let phaseLabel = currentRunPhase.map { "\($0)" } ?? (runFinished ? "idle" : "starting")
        let phase = "\(TerminalUIStyle.faint)phase\(TerminalUIStyle.reset) \(TerminalUIStyle.cyan)\(phaseLabel)\(TerminalUIStyle.reset)"
        let rightSummary: String
        if !currentPlannedFiles.isEmpty {
            let preview = currentPlannedFiles.prefix(3).joined(separator: ", ")
            let suffix = currentPlannedFiles.count > 3 ? " +\(currentPlannedFiles.count - 3)" : ""
            rightSummary = "\(TerminalUIStyle.faint)plan\(TerminalUIStyle.reset) \(TerminalUIStyle.amber)\(preview)\(suffix)\(TerminalUIStyle.reset)"
        } else if currentChangedFiles.isEmpty {
            rightSummary = "\(TerminalUIStyle.faint)changed\(TerminalUIStyle.reset) \(TerminalUIStyle.slate)none\(TerminalUIStyle.reset)"
        } else {
            let preview = currentChangedFiles.prefix(3).joined(separator: ", ")
            let suffix = currentChangedFiles.count > 3 ? " +\(currentChangedFiles.count - 3)" : ""
            rightSummary = "\(TerminalUIStyle.faint)changed\(TerminalUIStyle.reset) \(TerminalUIStyle.green)\(preview)\(suffix)\(TerminalUIStyle.reset)"
        }
        return join(left: phase, right: TerminalUIStyle.truncateVisible(rightSummary, limit: max(width / 2, 20)), width: width)
    }

    private func renderBody(width: Int, height: Int) -> [String] {
        let chromeHeight = 12
        let bodyHeight = max(height - chromeHeight, 10)
        let gap = 1
        let leftWidth = max(min(width / 3, 40), 30)
        let availableRightWidth = max(width - leftWidth - gap, 38)
        let terminalWidth = showTerminalPane ? max(min(availableRightWidth / 3, 48), 32) : 0
        let rightWidth = showTerminalPane ? max(availableRightWidth - terminalWidth - gap, 38) : availableRightWidth

        let leftPanel = panel(
            title: "Launcher",
            lines: renderHomeLines(width: leftWidth - 4),
            width: leftWidth,
            maxBodyHeight: bodyHeight
        )

        let rightTitle: String
        let rightLines: [String]
        if let pendingApproval {
            rightTitle = "Approval Required"
            rightLines = renderApprovalLines(request: pendingApproval.request, width: rightWidth - 4)
        } else if showWorkspaces {
            rightTitle = "Workspaces"
            rightLines = renderWorkspaceLines(width: rightWidth - 4)
        } else if showHistory {
            rightTitle = "History"
            rightLines = renderHistoryLines(width: rightWidth - 4)
        } else if showSettings {
            rightTitle = "Provider Settings"
            rightLines = renderSettingsLines(width: rightWidth - 4)
        } else if showCommands {
            rightTitle = "Commands"
            rightLines = renderCommandCatalogLines(width: rightWidth - 4)
        } else if showHelp {
            rightTitle = "Controls"
            rightLines = renderHelpLines(width: rightWidth - 4)
        } else {
            rightTitle = runFinished ? "Run Transcript" : "Live Run"
            rightLines = renderRunLines(width: rightWidth - 4, maxBodyHeight: bodyHeight)
        }

        let rightPanel = panel(
            title: rightTitle,
            lines: rightLines,
            width: rightWidth,
            maxBodyHeight: bodyHeight
        )

        if showTerminalPane {
            let terminalPanel = panel(
                title: "Terminal",
                lines: renderTerminalLines(width: terminalWidth - 4, maxBodyHeight: bodyHeight),
                width: terminalWidth,
                maxBodyHeight: bodyHeight
            )
            return zip(zip(leftPanel, rightPanel), terminalPanel).map { pair, terminal in
                pair.0 + String(repeating: " ", count: gap) + pair.1 + String(repeating: " ", count: gap) + terminal
            }
        } else {
            return zip(leftPanel, rightPanel).map { left, right in
                left + String(repeating: " ", count: gap) + right
            }
        }
    }

    private func renderHomeLines(width: Int) -> [String] {
        var lines: [String] = [
            "\(TerminalUIStyle.faint)\(focus == .launcher ? "Launcher focused" : "Press Tab to focus launcher")\(TerminalUIStyle.reset)",
            ""
        ]

        for (index, item) in menuItems.enumerated() {
            let selected = index == selectedIndex
            let marker = selected ? "\(TerminalUIStyle.selection) \(TerminalUIStyle.reset)" : " "
            let titleColor = selected ? TerminalUIStyle.cyan : TerminalUIStyle.ink
            lines.append("\(marker) \(TerminalUIStyle.bold)\(titleColor)\(item.title)\(TerminalUIStyle.reset)")
            lines.append("   \(TerminalUIStyle.slate)\(TerminalUIStyle.truncateVisible(item.subtitle, limit: max(width - 3, 10)))\(TerminalUIStyle.reset)")
            if index != menuItems.count - 1 { lines.append("") }
        }
        return lines
    }

    private func renderRunLines(width: Int, maxBodyHeight: Int) -> [String] {
        let bodyLimit = max(maxBodyHeight - 3, 1)
        let expanded = wrappedRunLines(width: width)
        let maxOffset = max(expanded.count - bodyLimit, 0)
        transcriptScrollOffset = min(max(transcriptScrollOffset, 0), maxOffset)
        let endIndex = max(expanded.count - transcriptScrollOffset, 0)
        let startIndex = max(endIndex - bodyLimit, 0)
        let viewport = Array(expanded[startIndex..<endIndex])

        var output = [transcriptHeader(width: width, totalLines: expanded.count, visibleLines: bodyLimit), ""]
        output.append(contentsOf: viewport)
        return output
    }

    private func renderHelpLines(width: Int) -> [String] {
        [
            "\(TerminalUIStyle.ink)Navigation\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.slate)Tab\(TerminalUIStyle.reset) Switch between launcher, transcript, settings/history, and input",
            "\(TerminalUIStyle.slate)Up/Down or j/k\(TerminalUIStyle.reset) Move through launcher items or scroll the transcript",
            "\(TerminalUIStyle.slate)Page Up/Down or Shift+j/Shift+k\(TerminalUIStyle.reset) Scroll the transcript faster",
            "\(TerminalUIStyle.slate)Home/End or g/G\(TerminalUIStyle.reset) Jump to the oldest output or back to the live tail",
            "\(TerminalUIStyle.slate)t\(TerminalUIStyle.reset) Toggle the side terminal pane",
            "\(TerminalUIStyle.slate)e\(TerminalUIStyle.reset) Expand or collapse tool details in the transcript",
            "\(TerminalUIStyle.slate)x\(TerminalUIStyle.reset) Skip the current planned step and continue",
            "\(TerminalUIStyle.slate)Enter\(TerminalUIStyle.reset) Open launcher item or submit prompt",
            "\(TerminalUIStyle.slate)Esc or Left\(TerminalUIStyle.reset) Back out, cancel a run, or quit",
            "\(TerminalUIStyle.slate)Backspace\(TerminalUIStyle.reset) Delete text in the input bar",
            "",
            "\(TerminalUIStyle.ink)Provider Controls\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.slate)Provider Settings\(TerminalUIStyle.reset) Switch backend and model without restarting",
            "\(TerminalUIStyle.slate)Refresh Status\(TerminalUIStyle.reset) Re-check environment and local models",
            "",
            "\(TerminalUIStyle.ink)Workspace Controls\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.slate)Workspaces\(TerminalUIStyle.reset) Open recent project roots and switch sessions quickly",
            "\(TerminalUIStyle.slate)/workspace /path\(TerminalUIStyle.reset) Switch the current session to a new project root",
            "\(TerminalUIStyle.slate)/workspaces\(TerminalUIStyle.reset) Open recent workspaces from the input bar",
            "\(TerminalUIStyle.slate)/pwd\(TerminalUIStyle.reset) Show the current active workspace",
            "",
            "\(TerminalUIStyle.ink)Commands Screen\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.slate)Open Commands to see the currently available tools, operations, and config policy file.\(TerminalUIStyle.reset)",
            "",
            "\(TerminalUIStyle.faint)The TUI is a client over the same runtime used by one-shot mode and future app integrations.\(TerminalUIStyle.reset)"
        ]
    }

    private func renderCommandCatalogLines(width: Int) -> [String] {
        let shellPolicy = sessionUserConfig.shell
        var lines: [String] = [
            "\(TerminalUIStyle.ink)Available Commands\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.slate)This screen is meant to grow as Ashex gains more tools.\(TerminalUIStyle.reset)",
            "",
            "\(TerminalUIStyle.ink)Prompt Patterns\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.blue)\(TerminalUIStyle.truncateVisible("Ask normally: summarize this project", limit: width))\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.blue)\(TerminalUIStyle.truncateVisible("Read a file: read README.md", limit: width))\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.blue)\(TerminalUIStyle.truncateVisible("List a directory: list files", limit: width))\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.blue)\(TerminalUIStyle.truncateVisible("Run shell: shell: git status", limit: width))\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.blue)\(TerminalUIStyle.truncateVisible("Run Swift build: swift build", limit: width))\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.blue)\(TerminalUIStyle.truncateVisible("Run Swift tests: swift test", limit: width))\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.blue)\(TerminalUIStyle.truncateVisible("Switch workspace live: /workspace /full/path/to/project", limit: width))\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.blue)\(TerminalUIStyle.truncateVisible("Aliases: :workspace /path, workspace /path, cd /path, /cd /path", limit: width))\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.blue)\(TerminalUIStyle.truncateVisible("Show current workspace: /pwd", limit: width))\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.blue)\(TerminalUIStyle.truncateVisible("Show sandbox policy: /sandbox", limit: width))\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.blue)\(TerminalUIStyle.truncateVisible("Open recent workspaces: /workspaces", limit: width))\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.blue)\(TerminalUIStyle.truncateVisible("Open side terminal: press t or choose Terminal in the launcher", limit: width))\(TerminalUIStyle.reset)",
            "",
            "\(TerminalUIStyle.ink)Filesystem Tool\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.slate)read_text_file\(TerminalUIStyle.reset) Read UTF-8 text files inside the workspace",
            "\(TerminalUIStyle.slate)write_text_file\(TerminalUIStyle.reset) Write text files and show diffs in the transcript",
            "\(TerminalUIStyle.slate)replace_in_file\(TerminalUIStyle.reset) Replace text in a file and show the exact diff",
            "\(TerminalUIStyle.slate)apply_patch\(TerminalUIStyle.reset) Apply multiple targeted edits to one file and show a combined diff",
            "\(TerminalUIStyle.slate)list_directory\(TerminalUIStyle.reset) Explore a directory and render a tree",
            "\(TerminalUIStyle.slate)create_directory\(TerminalUIStyle.reset) Create folders inside the workspace",
            "\(TerminalUIStyle.slate)delete_path\(TerminalUIStyle.reset) Delete files or folders in the workspace",
            "\(TerminalUIStyle.slate)move_path\(TerminalUIStyle.reset) Move or rename files and folders",
            "\(TerminalUIStyle.slate)copy_path\(TerminalUIStyle.reset) Copy files or folders",
            "\(TerminalUIStyle.slate)file_info\(TerminalUIStyle.reset) Inspect type, size, and modification time",
            "\(TerminalUIStyle.slate)find_files\(TerminalUIStyle.reset) Find paths by name fragment",
            "\(TerminalUIStyle.slate)search_text\(TerminalUIStyle.reset) Search text across UTF-8 files",
            "",
            "\(TerminalUIStyle.ink)Git Tool\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.slate)status\(TerminalUIStyle.reset) Show git status with branch and changed files",
            "\(TerminalUIStyle.slate)current_branch\(TerminalUIStyle.reset) Show the current checked out branch",
            "\(TerminalUIStyle.slate)diff_unstaged\(TerminalUIStyle.reset) Inspect unstaged changes",
            "\(TerminalUIStyle.slate)diff_staged\(TerminalUIStyle.reset) Inspect staged changes",
            "\(TerminalUIStyle.slate)log\(TerminalUIStyle.reset) Show recent commit history",
            "\(TerminalUIStyle.slate)show_commit\(TerminalUIStyle.reset) Inspect one commit with patch and stats",
            "",
            "\(TerminalUIStyle.ink)Build Tool\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.slate)swift_build\(TerminalUIStyle.reset) Run SwiftPM build in the workspace",
            "\(TerminalUIStyle.slate)swift_test\(TerminalUIStyle.reset) Run SwiftPM tests in the workspace",
            "\(TerminalUIStyle.slate)xcodebuild_list\(TerminalUIStyle.reset) List Xcode schemes and targets",
            "\(TerminalUIStyle.slate)xcodebuild_build\(TerminalUIStyle.reset) Run xcodebuild build with typed options",
            "\(TerminalUIStyle.slate)xcodebuild_test\(TerminalUIStyle.reset) Run xcodebuild test with typed options",
            "",
            "\(TerminalUIStyle.ink)Shell Tool\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.slate)command\(TerminalUIStyle.reset) Execute a shell command from the workspace root",
            "\(TerminalUIStyle.slate)timeout_seconds\(TerminalUIStyle.reset) Optional timeout for long-running commands",
            "",
            "\(TerminalUIStyle.ink)User Config\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.slate)\(TerminalUIStyle.truncateVisible(sessionUserConfigFile.path, limit: width))\(TerminalUIStyle.reset)"
        ]

        if let globalConfigFile = sessionGlobalUserConfigFile {
            lines.append("\(TerminalUIStyle.slate)\(TerminalUIStyle.truncateVisible("Global config: " + globalConfigFile.path, limit: width))\(TerminalUIStyle.reset)")
        } else {
            lines.append("\(TerminalUIStyle.slate)Global config: none\(TerminalUIStyle.reset)")
        }

        if shellPolicy.allowList.isEmpty {
            lines.append("\(TerminalUIStyle.slate)Allow list: empty (commands are allowed unless denied)\(TerminalUIStyle.reset)")
        } else {
            lines.append("\(TerminalUIStyle.slate)\(TerminalUIStyle.truncateVisible("Allow list prefixes: " + shellPolicy.allowList.joined(separator: ", "), limit: width))\(TerminalUIStyle.reset)")
        }

        if shellPolicy.denyList.isEmpty {
            lines.append("\(TerminalUIStyle.slate)Deny list: empty\(TerminalUIStyle.reset)")
        } else {
            lines.append("\(TerminalUIStyle.slate)\(TerminalUIStyle.truncateVisible("Deny list prefixes: " + shellPolicy.denyList.joined(separator: ", "), limit: width))\(TerminalUIStyle.reset)")
        }

        lines.append(
            "\(TerminalUIStyle.slate)Unknown commands require approval: \(shellPolicy.requireApprovalForUnknownCommands ? "yes" : "no")\(TerminalUIStyle.reset)"
        )
        lines.append(
            "\(TerminalUIStyle.slate)Sandbox mode: \(sessionUserConfig.sandbox.mode.rawValue)\(TerminalUIStyle.reset)"
        )

        if sessionUserConfig.sandbox.protectedPaths.isEmpty {
            lines.append("\(TerminalUIStyle.slate)Protected paths: none\(TerminalUIStyle.reset)")
        } else {
            lines.append("\(TerminalUIStyle.slate)\(TerminalUIStyle.truncateVisible("Protected paths: " + sessionUserConfig.sandbox.protectedPaths.joined(separator: ", "), limit: width))\(TerminalUIStyle.reset)")
        }

        if shellPolicy.rules.isEmpty {
            lines.append("\(TerminalUIStyle.slate)Command rules: none\(TerminalUIStyle.reset)")
        } else {
            let renderedRules = shellPolicy.rules.map { "\($0.action.rawValue):\($0.prefix)" }.joined(separator: ", ")
            lines.append("\(TerminalUIStyle.slate)\(TerminalUIStyle.truncateVisible("Command rules: " + renderedRules, limit: width))\(TerminalUIStyle.reset)")
        }
        lines.append(
            "\(TerminalUIStyle.slate)Network mode: \(sessionUserConfig.network.mode.rawValue)\(TerminalUIStyle.reset)"
        )
        if sessionUserConfig.network.rules.isEmpty {
            lines.append("\(TerminalUIStyle.slate)Network rules: none\(TerminalUIStyle.reset)")
        } else {
            let renderedNetworkRules = sessionUserConfig.network.rules.map { "\($0.action.rawValue):\($0.prefix)" }.joined(separator: ", ")
            lines.append("\(TerminalUIStyle.slate)\(TerminalUIStyle.truncateVisible("Network rules: " + renderedNetworkRules, limit: width))\(TerminalUIStyle.reset)")
        }

        lines.append("")
        lines.append("\(TerminalUIStyle.faint)Ashex creates this config file on first run if it does not exist.\(TerminalUIStyle.reset)")
        return lines
    }

    private func renderSettingsLines(width: Int) -> [String] {
        var lines: [String] = [
            "\(TerminalUIStyle.faint)\(focus == .settings ? "Settings focused" : "Press Tab to focus settings")\(TerminalUIStyle.reset)",
            ""
        ]

        for (index, action) in SettingsAction.allCases.enumerated() {
            let selected = focus == .settings && index == settingsSelection
            let marker = selected ? "\(TerminalUIStyle.selection) \(TerminalUIStyle.reset)" : " "
            let color = selected ? TerminalUIStyle.cyan : TerminalUIStyle.ink
            let value: String
            switch action {
            case .workspace:
                value = sessionWorkspaceRoot.path
            case .provider:
                value = sessionProvider
            case .model:
                value = sessionModel
            case .apiKey:
                value = apiKeyStatusLabel(for: sessionProvider)
            case .refresh:
                value = providerStatus.headline
            case .back:
                value = "Return to launcher"
            }

            lines.append("\(marker) \(TerminalUIStyle.bold)\(color)\(action.rawValue)\(TerminalUIStyle.reset)")
            lines.append("   \(TerminalUIStyle.slate)\(TerminalUIStyle.truncateVisible(value, limit: max(width - 3, 10)))\(TerminalUIStyle.reset)")
            if index != SettingsAction.allCases.count - 1 {
                lines.append("")
            }
        }

        lines.append("")
        lines.append("\(TerminalUIStyle.ink)Status\(TerminalUIStyle.reset)")
        for detail in providerStatus.details.prefix(4) {
            lines.append("\(TerminalUIStyle.slate)\(TerminalUIStyle.truncateVisible(detail, limit: width))\(TerminalUIStyle.reset)")
        }

        if !providerStatus.availableModels.isEmpty {
            lines.append("")
            lines.append("\(TerminalUIStyle.ink)Available Models\(TerminalUIStyle.reset)")
            for model in providerStatus.availableModels.prefix(6) {
                lines.append("\(TerminalUIStyle.blue)\(TerminalUIStyle.truncateVisible(model, limit: width))\(TerminalUIStyle.reset)")
            }
        }

        if let assessment = providerStatus.guardrailAssessment {
            lines.append("")
            lines.append("\(TerminalUIStyle.ink)Memory Guardrail\(TerminalUIStyle.reset)")
            let severityColor: String
            switch assessment.severity {
            case .ok:
                severityColor = TerminalUIStyle.green
            case .warning:
                severityColor = TerminalUIStyle.amber
            case .blocked:
                severityColor = TerminalUIStyle.red
            }
            lines.append("\(severityColor)\(assessment.headline)\(TerminalUIStyle.reset)")
            for detail in assessment.details.prefix(3) {
                lines.append("\(TerminalUIStyle.slate)\(TerminalUIStyle.truncateVisible(detail, limit: width))\(TerminalUIStyle.reset)")
            }
        }

        if inputMode == .model {
            lines.append("")
            lines.append("\(TerminalUIStyle.amber)Model edit mode is active in the input bar below.\(TerminalUIStyle.reset)")
        } else if inputMode == .apiKey {
            lines.append("")
            lines.append("\(TerminalUIStyle.amber)API key edit mode is active in the input bar below.\(TerminalUIStyle.reset)")
        }

        return lines
    }

    private func apiKeyStatusLabel(for provider: String) -> String {
        guard provider == "openai" || provider == "anthropic" else {
            return "Not required"
        }

        let envName = CLIConfiguration.environmentAPIKeyName(for: provider)
        if let envValue = ProcessInfo.processInfo.environment[envName], !envValue.isEmpty {
            return "Loaded from environment (\(maskSecret(envValue)))"
        }

        do {
            if let persisted = try secretStore.readSecret(namespace: "provider.credentials", key: CLIConfiguration.apiKeySettingKey(for: provider)),
               !persisted.isEmpty {
                return "Saved in Keychain (\(maskSecret(persisted)))"
            }
        } catch {
            return "Lookup failed"
        }

        return "Missing"
    }

    private func normalizeAPIKeyInput(_ input: String, for provider: String) -> String {
        let cleaned = input
            .replacingOccurrences(of: "\u{001B}[200~", with: "")
            .replacingOccurrences(of: "\u{001B}[201~", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let strippedQuotes = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        if looksLikeAPIKey(strippedQuotes, for: provider) {
            return strippedQuotes
        }

        let tokens = strippedQuotes
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters.subtracting(CharacterSet(charactersIn: "-_"))))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`")) }
            .filter { !$0.isEmpty }

        if let token = tokens.first(where: { looksLikeAPIKey($0, for: provider) }) {
            return token
        }

        return strippedQuotes
    }

    private func looksLikeAPIKey(_ value: String, for provider: String) -> Bool {
        switch provider {
        case "openai":
            return value.hasPrefix("sk-")
        case "anthropic":
            return value.hasPrefix("sk-ant-") || value.hasPrefix("sk_live_")
        default:
            return !value.isEmpty
        }
    }

    private func renderHistoryLines(width: Int) -> [String] {
        var lines: [String] = [
            "\(TerminalUIStyle.faint)\(focus == .history ? "History focused" : "Press Tab to focus history")\(TerminalUIStyle.reset)",
            ""
        ]

        if historyThreads.isEmpty {
            lines.append("\(TerminalUIStyle.slate)No persisted threads yet. Run a prompt to create history.\(TerminalUIStyle.reset)")
            return lines
        }

        lines.append("\(TerminalUIStyle.ink)Threads\(TerminalUIStyle.reset)")
        for (index, thread) in historyThreads.enumerated().prefix(6) {
            let selected = focus == .history && index == historySelection
            let marker = selected ? "\(TerminalUIStyle.selection) \(TerminalUIStyle.reset)" : " "
            let state = thread.latestRunState?.rawValue ?? "no-runs"
            let title = "Thread \(thread.id.uuidString.prefix(8)) • \(state) • \(thread.messageCount) msg"
            lines.append("\(marker) \(TerminalUIStyle.bold)\(selected ? TerminalUIStyle.cyan : TerminalUIStyle.ink)\(TerminalUIStyle.truncateVisible(title, limit: width - 2))\(TerminalUIStyle.reset)")
        }

        if let selectedThread = selectedHistoryThread {
            lines.append("")
            lines.append("\(TerminalUIStyle.ink)Runs\(TerminalUIStyle.reset)")
            let runs = historyRuns[selectedThread.id] ?? []
            if runs.isEmpty {
                lines.append("\(TerminalUIStyle.slate)No runs stored for this thread.\(TerminalUIStyle.reset)")
            } else {
                for run in runs.prefix(3) {
                    let stepCount = (try? historyStore.fetchRunSteps(runID: run.id).count) ?? 0
                    let compactionCount = (try? historyStore.fetchContextCompactions(runID: run.id).count) ?? 0
                    let line = "\(run.id.uuidString.prefix(8)) • \(run.state.rawValue) • \(Self.timeString(run.updatedAt)) • \(stepCount) steps • \(compactionCount) compact"
                    lines.append("\(TerminalUIStyle.slate)\(TerminalUIStyle.truncateVisible(line, limit: width))\(TerminalUIStyle.reset)")
                }
            }
        }

        if !historyPreviewLines.isEmpty {
            lines.append("")
            lines.append("\(TerminalUIStyle.ink)Preview\(TerminalUIStyle.reset)")
            lines.append(contentsOf: historyPreviewLines.prefix(8).map { TerminalUIStyle.truncateVisible($0, limit: width) })
            lines.append("")
            lines.append("\(TerminalUIStyle.faint)Press Enter to load the selected run into the transcript pane.\(TerminalUIStyle.reset)")
        }

        return lines
    }

    private func renderWorkspaceLines(width: Int) -> [String] {
        var lines: [String] = [
            "\(TerminalUIStyle.faint)\(focus == .workspaces ? "Workspaces focused" : "Press Tab to focus workspaces")\(TerminalUIStyle.reset)",
            ""
        ]

        if recentWorkspaces.isEmpty {
            lines.append("\(TerminalUIStyle.slate)No recent workspaces yet. Switch to another project to populate this list.\(TerminalUIStyle.reset)")
            return lines
        }

        lines.append("\(TerminalUIStyle.ink)Recent Workspaces\(TerminalUIStyle.reset)")
        for (index, workspace) in recentWorkspaces.enumerated().prefix(8) {
            let selected = focus == .workspaces && index == workspaceSelection
            let marker = selected ? "\(TerminalUIStyle.selection) \(TerminalUIStyle.reset)" : " "
            let color = selected ? TerminalUIStyle.cyan : TerminalUIStyle.ink
            let pathURL = URL(fileURLWithPath: workspace.path)
            let title = pathURL.lastPathComponent + (workspace.path == sessionWorkspaceRoot.path ? " • current" : "")
            let subtitle = "\(workspace.path) • \(Self.timeString(workspace.lastUsedAt))"
            lines.append("\(marker) \(TerminalUIStyle.bold)\(color)\(TerminalUIStyle.truncateVisible(title, limit: width - 2))\(TerminalUIStyle.reset)")
            lines.append("   \(TerminalUIStyle.slate)\(TerminalUIStyle.truncateVisible(subtitle, limit: max(width - 3, 10)))\(TerminalUIStyle.reset)")
            if index != min(recentWorkspaces.count, 8) - 1 {
                lines.append("")
            }
        }

        if !workspacePreviewLines.isEmpty {
            lines.append("")
            lines.append("\(TerminalUIStyle.ink)Latest Session Preview\(TerminalUIStyle.reset)")
            lines.append(contentsOf: workspacePreviewLines.map {
                "\(TerminalUIStyle.slate)\(TerminalUIStyle.truncateVisible($0, limit: width))\(TerminalUIStyle.reset)"
            })
        }

        return lines
    }

    private func renderApprovalLines(request: ApprovalRequest, width: Int) -> [String] {
        var lines: [String] = [
            "\(TerminalUIStyle.amber)Guarded mode requires approval before this tool can run.\(TerminalUIStyle.reset)",
            "",
            "\(TerminalUIStyle.ink)Tool\(TerminalUIStyle.reset): \(TerminalUIStyle.violet)\(request.toolName)\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.ink)Summary\(TerminalUIStyle.reset): \(TerminalUIStyle.truncateVisible(request.summary, limit: max(width - 10, 8)))",
            "\(TerminalUIStyle.ink)Target\(TerminalUIStyle.reset): \(TerminalUIStyle.truncateVisible(request.reason, limit: max(width - 10, 8)))",
            "\(TerminalUIStyle.ink)Risk\(TerminalUIStyle.reset): \(riskColor(for: request.risk))\(request.risk.rawValue.uppercased())\(TerminalUIStyle.reset)",
            ""
        ]

        lines.append(contentsOf: renderApprovalPreview(request: request, width: width))
        lines.append("")
        lines.append("\(TerminalUIStyle.faint)Press y or Enter to approve. Press n, Esc, or Left to deny.\(TerminalUIStyle.reset)")
        return lines
    }

    private func renderApprovalPreview(request: ApprovalRequest, width: Int) -> [String] {
        switch request.toolName {
        case "shell":
            let command = request.arguments["command"]?.stringValue ?? request.reason
            var lines = ["\(TerminalUIStyle.ink)Command Preview\(TerminalUIStyle.reset)"]
            lines.append(contentsOf: wrapText(command, width: width).map { "\(TerminalUIStyle.blue)\($0)\(TerminalUIStyle.reset)" })
            if request.risk == .high {
                lines.append("\(TerminalUIStyle.red)This command matches a higher-risk shell pattern.\(TerminalUIStyle.reset)")
            }
            return lines
        case "filesystem":
            let operation = request.arguments["operation"]?.stringValue ?? request.summary
            let path = request.arguments["path"]?.stringValue ?? request.reason
            var lines = [
                "\(TerminalUIStyle.ink)Filesystem Preview\(TerminalUIStyle.reset)",
                "\(TerminalUIStyle.slate)\(operation) → \(path)\(TerminalUIStyle.reset)"
            ]
            if operation == "write_text_file" {
                let content = request.arguments["content"]?.stringValue ?? ""
                let previewLines = content.split(separator: "\n", omittingEmptySubsequences: false).prefix(6).map(String.init)
                lines.append("\(TerminalUIStyle.ink)Content Preview\(TerminalUIStyle.reset)")
                if previewLines.isEmpty {
                    lines.append("\(TerminalUIStyle.slate)<empty file>\(TerminalUIStyle.reset)")
                } else {
                    lines.append(contentsOf: previewLines.flatMap { wrapText($0, width: width).map { "\(TerminalUIStyle.blue)\($0)\(TerminalUIStyle.reset)" } })
                }
            } else if operation == "replace_in_file" {
                let oldText = request.arguments["old_text"]?.stringValue ?? ""
                let newText = request.arguments["new_text"]?.stringValue ?? ""
                lines.append("\(TerminalUIStyle.ink)Replace Preview\(TerminalUIStyle.reset)")
                lines.append(contentsOf: wrapText("old: \(oldText)", width: width).map { "\(TerminalUIStyle.blue)\($0)\(TerminalUIStyle.reset)" })
                lines.append(contentsOf: wrapText("new: \(newText)", width: width).map { "\(TerminalUIStyle.green)\($0)\(TerminalUIStyle.reset)" })
            }
            return lines
        case "git":
            let operation = request.arguments["operation"]?.stringValue ?? request.summary
            return [
                "\(TerminalUIStyle.ink)Git Preview\(TerminalUIStyle.reset)",
                "\(TerminalUIStyle.slate)\(operation)\(TerminalUIStyle.reset)"
            ]
        default:
            return [
                "\(TerminalUIStyle.ink)Arguments\(TerminalUIStyle.reset)",
                "\(TerminalUIStyle.slate)\(TerminalUIStyle.truncateVisible(JSONValue.object(request.arguments).prettyPrinted, limit: width))\(TerminalUIStyle.reset)"
            ]
        }
    }

    private func renderInputBar(width: Int) -> [String] {
        let innerWidth = max(width - 4, 20)
        let actualLabelText: String
        switch inputMode {
        case .prompt: actualLabelText = "Input"
        case .model: actualLabelText = "Model"
        case .apiKey: actualLabelText = "API Key"
        case .workspacePath: actualLabelText = "Workspace"
        case .terminalCommand: actualLabelText = "Terminal"
        }
        let title = focus == .input ? "\(TerminalUIStyle.cyan)\(actualLabelText)\(TerminalUIStyle.reset)" : "\(TerminalUIStyle.faint)\(actualLabelText)\(TerminalUIStyle.reset)"
        let currentText: String
        switch inputMode {
        case .prompt: currentText = promptText
        case .model: currentText = modelInput
        case .apiKey: currentText = String(repeating: "•", count: apiKeyInput.count)
        case .workspacePath: currentText = workspacePathInput
        case .terminalCommand: currentText = terminalCommandInput
        }
        let placeholder = inputMode == .model
            ? "Type a model name, then press Enter to apply…"
            : inputMode == .apiKey
                ? "Paste an API key, then press Enter to save…"
                : inputMode == .workspacePath
                    ? "Type a project directory path, then press Enter to switch…"
                : inputMode == .terminalCommand
                    ? "Type a shell command for the side terminal, then press Enter…"
                : "Type a prompt here, then press Enter to run…"
        let prompt = currentText.isEmpty
            ? "\(TerminalUIStyle.faint)\(placeholder)\(TerminalUIStyle.reset)"
            : "\(TerminalUIStyle.ink)\(currentText)\(TerminalUIStyle.reset)"
        let line = "\(TerminalUIStyle.blue)›\(TerminalUIStyle.reset) \(prompt)"

        return [
            "\(TerminalUIStyle.border)┌─ \(title) \(TerminalUIStyle.border)" + String(repeating: "─", count: max(innerWidth - 7, 0)) + "┐\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.border)│ \(TerminalUIStyle.reset)\(TerminalUIStyle.padVisible(TerminalUIStyle.truncateVisible(line, limit: innerWidth), to: innerWidth))\(TerminalUIStyle.border) │\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.border)└" + String(repeating: "─", count: innerWidth + 2) + "┘\(TerminalUIStyle.reset)"
        ]
    }

    private func maskSecret(_ value: String) -> String {
        guard value.count > 8 else { return String(repeating: "•", count: max(value.count, 4)) }
        return String(value.prefix(4)) + String(repeating: "•", count: max(value.count - 8, 4)) + String(value.suffix(4))
    }

    private func renderFooter(width: Int) -> String {
        let hint = pendingApproval == nil
            ? "\(TerminalUIStyle.faint)tab\(TerminalUIStyle.reset) focus  \(TerminalUIStyle.faint)PgUp/PgDn\(TerminalUIStyle.reset) fast scroll  \(TerminalUIStyle.faint)g/G\(TerminalUIStyle.reset) top/end  \(TerminalUIStyle.faint)e\(TerminalUIStyle.reset) details  \(TerminalUIStyle.faint)x\(TerminalUIStyle.reset) skip  \(TerminalUIStyle.faint)esc\(TerminalUIStyle.reset) cancel"
            : "\(TerminalUIStyle.faint)y\(TerminalUIStyle.reset) approve  \(TerminalUIStyle.faint)n\(TerminalUIStyle.reset) deny"
        let value = "\(TerminalUIStyle.faint)Ashex local agent runtime\(TerminalUIStyle.reset)  \(TerminalUIStyle.faint)•\(TerminalUIStyle.reset)  \(TerminalUIStyle.faint)focus\(TerminalUIStyle.reset) \(focusLabel)  \(TerminalUIStyle.faint)•\(TerminalUIStyle.reset)  \(hint)"
        return TerminalUIStyle.padVisible(TerminalUIStyle.truncateVisible(value, limit: width), to: width)
    }

    private func panel(title: String, lines: [String], width: Int, maxBodyHeight: Int) -> [String] {
        let innerWidth = max(width - 4, 20)
        let body = Array(lines.prefix(maxBodyHeight))
        var rendered: [String] = []
        rendered.append("\(TerminalUIStyle.border)┌─ \(TerminalUIStyle.bold)\(TerminalUIStyle.cyan)\(title)\(TerminalUIStyle.reset) \(TerminalUIStyle.border)" + String(repeating: "─", count: max(innerWidth - TerminalUIStyle.visibleWidth(of: title) - 3, 0)) + "┐\(TerminalUIStyle.reset)")
        for line in body {
            rendered.append("\(TerminalUIStyle.border)│ \(TerminalUIStyle.reset)\(TerminalUIStyle.padVisible(TerminalUIStyle.truncateVisible(line, limit: innerWidth), to: innerWidth))\(TerminalUIStyle.border) │\(TerminalUIStyle.reset)")
        }
        if body.count < maxBodyHeight {
            rendered.append(contentsOf: Array(repeating: "\(TerminalUIStyle.border)│ \(TerminalUIStyle.reset)\(String(repeating: " ", count: innerWidth))\(TerminalUIStyle.border) │\(TerminalUIStyle.reset)", count: maxBodyHeight - body.count))
        }
        rendered.append("\(TerminalUIStyle.border)└" + String(repeating: "─", count: innerWidth + 2) + "┘\(TerminalUIStyle.reset)")
        return rendered
    }

    private func stylizeRunLine(_ line: String, width: Int) -> String {
        let colored: String
        if line.hasPrefix("[error]") {
            colored = "\(TerminalUIStyle.red)\(line)\(TerminalUIStyle.reset)"
        } else if line.hasPrefix("[plan]") {
            colored = "\(TerminalUIStyle.cyan)\(line)\(TerminalUIStyle.reset)"
        } else if line.hasPrefix("[approval]") {
            colored = "\(TerminalUIStyle.amber)\(line)\(TerminalUIStyle.reset)"
        } else if line.hasPrefix("[tool]") {
            colored = "\(TerminalUIStyle.violet)\(line)\(TerminalUIStyle.reset)"
        } else if line.hasPrefix("[stdout]") {
            colored = "\(TerminalUIStyle.green)\(line)\(TerminalUIStyle.reset)"
        } else if line.hasPrefix("[stderr]") {
            colored = "\(TerminalUIStyle.red)\(line)\(TerminalUIStyle.reset)"
        } else if line.hasPrefix("[status]") {
            colored = "\(TerminalUIStyle.amber)\(line)\(TerminalUIStyle.reset)"
        } else if line.hasPrefix("[run]") || line.hasPrefix("[state]") {
            colored = "\(TerminalUIStyle.blue)\(line)\(TerminalUIStyle.reset)"
        } else if line == "Final answer:" {
            colored = "\(TerminalUIStyle.bold)\(TerminalUIStyle.pink)\(line)\(TerminalUIStyle.reset)"
        } else {
            colored = "\(TerminalUIStyle.ink)\(line)\(TerminalUIStyle.reset)"
        }
        return TerminalUIStyle.truncateVisible(colored, limit: width)
    }

    private func wrapRunLine(_ line: String, width: Int) -> [String] {
        let baseColor: String
        let diffCandidate = normalizeDiffCandidate(from: line)
        if diffCandidate.hasPrefix("@@") {
            baseColor = TerminalUIStyle.amber
        } else if diffCandidate.hasPrefix("diff --git")
                    || diffCandidate.hasPrefix("index ")
                    || diffCandidate.hasPrefix("--- ")
                    || diffCandidate.hasPrefix("+++ ") {
            baseColor = TerminalUIStyle.blue
        } else if diffCandidate.hasPrefix("+") && !diffCandidate.hasPrefix("+++") {
            baseColor = TerminalUIStyle.green
        } else if diffCandidate.hasPrefix("-") && !diffCandidate.hasPrefix("---") {
            baseColor = TerminalUIStyle.red
        } else if line.hasPrefix("[error]") {
            baseColor = TerminalUIStyle.red
        } else if line.hasPrefix("[plan]") {
            baseColor = TerminalUIStyle.cyan
        } else if line.hasPrefix("[approval]") {
            baseColor = TerminalUIStyle.amber
        } else if line.hasPrefix("[tool]") {
            baseColor = TerminalUIStyle.violet
        } else if line.hasPrefix("[stdout]") {
            baseColor = TerminalUIStyle.green
        } else if line.hasPrefix("[stderr]") {
            baseColor = TerminalUIStyle.red
        } else if line.hasPrefix("[status]") {
            baseColor = TerminalUIStyle.amber
        } else if line.hasPrefix("[run]") || line.hasPrefix("[state]") {
            baseColor = TerminalUIStyle.blue
        } else if line == "Final answer:" {
            baseColor = TerminalUIStyle.pink + TerminalUIStyle.bold
        } else {
            baseColor = TerminalUIStyle.ink
        }

        let plain = line.isEmpty ? " " : line
        return wrapText(plain, width: max(width, 10)).map { "\(baseColor)\($0)\(TerminalUIStyle.reset)" }
    }

    private func normalizeDiffCandidate(from line: String) -> String {
        if line.hasPrefix("[stdout] ") || line.hasPrefix("[stderr] ") {
            return String(line.dropFirst(9))
        }
        return line
    }

    private func join(left: String, right: String, width: Int) -> String {
        let leftWidth = TerminalUIStyle.visibleWidth(of: left)
        let rightWidth = TerminalUIStyle.visibleWidth(of: right)
        if leftWidth + rightWidth + 2 <= width {
            return left + String(repeating: " ", count: width - leftWidth - rightWidth) + right
        }
        let minGap = 2
        let preservedLeftWidth = min(leftWidth, max(width / 2, 20))
        let leftPart = TerminalUIStyle.truncateVisible(left, limit: preservedLeftWidth)
        let remaining = max(width - TerminalUIStyle.visibleWidth(of: leftPart) - minGap, 0)
        if remaining == 0 {
            return leftPart
        }
        let rightPart = TerminalUIStyle.truncateVisible(right, limit: remaining)
        return leftPart + String(repeating: " ", count: minGap) + rightPart
    }

    private var screenLabel: String {
        if pendingApproval != nil { return "approval" }
        if showWorkspaces { return "workspaces" }
        if showHistory { return "history" }
        if showSettings { return "settings" }
        if showCommands { return "commands" }
        if showHelp { return "help" }
        return runFinished ? "workspace" : "live run"
    }

    private var focusLabel: String {
        switch focus {
        case .launcher: return "launcher"
        case .workspaces: return "workspaces"
        case .history: return "history"
        case .settings: return "settings"
        case .transcript: return "transcript"
        case .terminal: return "terminal"
        case .input: return "input"
        case .approval: return "approval"
        }
    }

    private var statusColor: String {
        let lowered = statusLine.lowercased()
        if lowered.contains("fail") || lowered.contains("error") || lowered.contains("denied") {
            return TerminalUIStyle.red
        }
        if lowered.contains("running") || lowered.contains("stream") || lowered.contains("approval") {
            return TerminalUIStyle.amber
        }
        return TerminalUIStyle.green
    }

    private var displayStatusLine: String {
        guard !runFinished else {
            return statusLine.uppercased()
        }

        let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        let frame = frames[workingFrameIndex % frames.count]
        let elapsedText = formattedElapsed
        return "\(frame) Working\(elapsedText.map { " (\($0))" } ?? "")"
    }

    private var formattedElapsed: String? {
        guard let runStartedAt else { return nil }
        let elapsed = max(Int(Date().timeIntervalSince(runStartedAt)), 0)
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }

    private var estimatedConversationTokens: Int {
        let source = runLines.isEmpty ? promptText : runLines.joined(separator: "\n")
        let characters = source.count
        return max(Int(ceil(Double(characters) / 4.0)), 0)
    }

    private var formattedEstimatedTokens: String {
        Self.formatTokenCount(estimatedConversationTokens)
    }

    private var formattedContextUsage: String {
        let maxTokens = Self.estimatedContextWindow(for: sessionProvider, model: sessionModel)
        let usedTokens = estimatedConversationTokens
        return "\(Self.formatTokenCount(usedTokens))/\(Self.formatTokenCount(maxTokens))"
    }

    private func riskColor(for risk: ApprovalRisk) -> String {
        switch risk {
        case .low:
            return TerminalUIStyle.green
        case .medium:
            return TerminalUIStyle.amber
        case .high:
            return TerminalUIStyle.red
        }
    }

    private static func estimatedContextWindow(for provider: String, model: String) -> Int {
        let lowered = model.lowercased()
        switch provider {
        case "openai":
            if lowered.contains("gpt-5") { return 400_000 }
            if lowered.contains("gpt-4.1") { return 1_000_000 }
            if lowered.contains("gpt-4o") { return 128_000 }
            return 128_000
        case "anthropic":
            if lowered.contains("claude") { return 200_000 }
            return 200_000
        case "ollama":
            if lowered.contains("llama3") || lowered.contains("qwen") || lowered.contains("mistral") || lowered.contains("gemma") {
                return 128_000
            }
            return 32_000
        default:
            return 8_000
        }
    }

    private static func formatTokenCount(_ count: Int) -> String {
        switch count {
        case 1_000_000...:
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        case 10_000...:
            return String(format: "%.0fk", Double(count) / 1_000.0)
        case 1_000...:
            return String(format: "%.1fk", Double(count) / 1_000.0)
        default:
            return "\(count)"
        }
    }

    private func gradientTitle() -> String {
        let letters = Array("ASHEX")
        let colors = [
            TerminalUIStyle.cyan,
            TerminalUIStyle.blue,
            TerminalUIStyle.violet,
            TerminalUIStyle.pink,
            TerminalUIStyle.amber,
        ]

        return zip(letters, colors)
            .map { "\(String($0.1))\($0.0)" }
            .joined()
    }

    private func transcriptHeader(width: Int, totalLines: Int, visibleLines: Int) -> String {
        let state = runLines.isEmpty ? "empty" : (runFinished ? "idle" : "streaming")
        let focusInfo = focus == .transcript
            ? "\(TerminalUIStyle.cyan)\(transcriptScrollOffset == 0 ? "live tail" : "scroll +\(transcriptScrollOffset)")\(TerminalUIStyle.reset)"
            : "\(TerminalUIStyle.faint)tab to scroll\(TerminalUIStyle.reset)"
        let left = "\(TerminalUIStyle.faint)state\(TerminalUIStyle.reset) \(state)"
        let detailMode = showToolDetails ? "\(TerminalUIStyle.amber)details\(TerminalUIStyle.reset)" : "\(TerminalUIStyle.faint)summary\(TerminalUIStyle.reset)"
        let right = "\(TerminalUIStyle.faint)\(totalLines) lines / \(visibleLines) view\(TerminalUIStyle.reset)  \(detailMode)  \(focusInfo)"
        return join(left: left, right: right, width: width)
    }

    private func wrappedRunLines(width: Int) -> [String] {
        let source = runLines.isEmpty ? ["No run yet. Choose an example or type a prompt below."] : runLines
        var expanded: [String] = []
        for line in source {
            expanded.append(contentsOf: wrapRunLine(line, width: width))
        }
        return expanded
    }

    private func scrollTranscript(by delta: Int) {
        let metrics = transcriptMetrics()
        let maxOffset = max(metrics.totalLines - metrics.bodyLimit, 0)
        transcriptScrollOffset = min(max(transcriptScrollOffset + delta, 0), maxOffset)
        statusLine = transcriptScrollOffset == 0 ? "Transcript at live tail" : "Transcript scroll +\(transcriptScrollOffset)"
    }

    private enum TranscriptPageDirection {
        case older
        case newer
    }

    private func scrollTranscriptPage(direction: TranscriptPageDirection) {
        let metrics = transcriptMetrics()
        let step = max(metrics.bodyLimit - 2, 8)
        switch direction {
        case .older:
            scrollTranscript(by: step)
        case .newer:
            scrollTranscript(by: -step)
        }
    }

    private func jumpTranscriptToTop() {
        let metrics = transcriptMetrics()
        transcriptScrollOffset = max(metrics.totalLines - metrics.bodyLimit, 0)
        statusLine = transcriptScrollOffset == 0 ? "Transcript at live tail" : "Transcript at top"
    }

    private func jumpTranscriptToBottom() {
        transcriptScrollOffset = 0
        statusLine = "Transcript at live tail"
    }

    private func scrollTerminal(by delta: Int) {
        let metrics = terminalMetrics()
        let maxOffset = max(metrics.totalLines - metrics.bodyLimit, 0)
        terminalScrollOffset = min(max(terminalScrollOffset + delta, 0), maxOffset)
        statusLine = terminalScrollOffset == 0 ? "Terminal at live tail" : "Terminal scroll +\(terminalScrollOffset)"
    }

    private func scrollTerminalPage(direction: TranscriptPageDirection) {
        let metrics = terminalMetrics()
        let step = max(metrics.bodyLimit - 2, 8)
        switch direction {
        case .older:
            scrollTerminal(by: step)
        case .newer:
            scrollTerminal(by: -step)
        }
    }

    private func jumpTerminalToTop() {
        let metrics = terminalMetrics()
        terminalScrollOffset = max(metrics.totalLines - metrics.bodyLimit, 0)
        statusLine = terminalScrollOffset == 0 ? "Terminal at live tail" : "Terminal at top"
    }

    private func jumpTerminalToBottom() {
        terminalScrollOffset = 0
        statusLine = "Terminal at live tail"
    }

    private func isTranscriptNearBottom() -> Bool {
        transcriptScrollOffset <= 1
    }

    private func startWorkingIndicator() {
        workingIndicatorTask?.cancel()
        workingIndicatorTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                await MainActor.run {
                    guard !self.runFinished else { return }
                    self.workingFrameIndex = (self.workingFrameIndex + 1) % 10
                    self.render()
                }
            }
        }
    }

    private func stopWorkingIndicator() {
        workingIndicatorTask?.cancel()
        workingIndicatorTask = nil
    }

    private func formattedStructuredLines(from text: String) -> [String]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else {
            return nil
        }

        guard let data = trimmed.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return nil
        }

        return renderStructuredValue(value)
    }

    private func renderStructuredValue(_ value: JSONValue) -> [String] {
        if let directoryTree = renderDirectoryTree(from: value) {
            return directoryTree
        }

        if let fileWriteDetails = renderFileWriteDetails(from: value) {
            return fileWriteDetails
        }

        if let fileMutationDetails = renderFilesystemMutationDetails(from: value) {
            return fileMutationDetails
        }

        if let fileSearchDetails = renderFilesystemSearchDetails(from: value) {
            return fileSearchDetails
        }

        if let gitDetails = renderGitDetails(from: value) {
            return gitDetails
        }

        return value.prettyPrinted.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private func summarizeToolStart(toolName: String, arguments: JSONObject) -> String {
        if toolName == "filesystem" {
            let operation = arguments["operation"]?.stringValue ?? "unknown"
            let path = arguments["path"]?.stringValue ?? "."
            switch operation {
            case "list_directory":
                return "[tool] exploring \(path)"
            case "read_text_file":
                return "[tool] reading \(path)"
            case "write_text_file":
                return "[tool] editing \(path)"
            case "replace_in_file":
                return "[tool] replacing text in \(path)"
            case "apply_patch":
                return "[tool] patching \(path)"
            case "create_directory":
                return "[tool] creating directory \(path)"
            case "delete_path":
                return "[tool] deleting \(path)"
            case "move_path":
                let sourcePath = arguments["source_path"]?.stringValue ?? path
                let destinationPath = arguments["destination_path"]?.stringValue ?? "."
                return "[tool] moving \(sourcePath) → \(destinationPath)"
            case "copy_path":
                let sourcePath = arguments["source_path"]?.stringValue ?? path
                let destinationPath = arguments["destination_path"]?.stringValue ?? "."
                return "[tool] copying \(sourcePath) → \(destinationPath)"
            case "file_info":
                return "[tool] inspecting \(path)"
            case "find_files":
                let query = arguments["query"]?.stringValue ?? ""
                return "[tool] finding files in \(path) matching \(query)"
            case "search_text":
                let query = arguments["query"]?.stringValue ?? ""
                return "[tool] searching text in \(path) for \(query)"
            default:
                return "[tool] filesystem \(operation)"
            }
        }

        if toolName == "git" {
            let operation = arguments["operation"]?.stringValue ?? "status"
            return "[tool] git \(operation)"
        }

        if toolName == "shell" {
            let command = arguments["command"]?.stringValue ?? "<unknown>"
            return "[tool] executing shell \(command)"
        }

        return "[tool] \(toolName) started"
    }

    private func summarizeStructuredCompletion(success: Bool, value: JSONValue) -> String {
        guard case .object(let object) = value else {
            return "[tool] \(success ? "completed" : "failed")"
        }

        if let operation = object["operation"]?.stringValue {
            switch operation {
            case "list_directory":
                let path = object["path"]?.stringValue ?? "."
                let childCount = (object["children"]?.arrayValue?.count) ?? (object["entries"]?.arrayValue?.count) ?? 0
                return "[tool] explored \(path) (\(childCount) entries)"
            case "write_text_file":
                let path = object["path"]?.stringValue ?? "<unknown>"
                let bytesWritten = object["bytes_written"]?.intValue ?? 0
                return "[tool] edited \(path) (\(bytesWritten) chars)"
            case "replace_in_file":
                let path = object["path"]?.stringValue ?? "<unknown>"
                return "[tool] replaced text in \(path)"
            case "apply_patch":
                let path = object["path"]?.stringValue ?? "<unknown>"
                let editCount = object["edit_count"]?.intValue ?? object["applied_edits"]?.arrayValue?.count ?? 0
                return "[tool] patched \(path) (\(editCount) edits)"
            case "delete_path":
                let path = object["path"]?.stringValue ?? "<unknown>"
                return "[tool] deleted \(path)"
            case "move_path":
                let sourcePath = object["source_path"]?.stringValue ?? "<unknown>"
                let destinationPath = object["destination_path"]?.stringValue ?? "<unknown>"
                return "[tool] moved \(sourcePath) → \(destinationPath)"
            case "copy_path":
                let sourcePath = object["source_path"]?.stringValue ?? "<unknown>"
                let destinationPath = object["destination_path"]?.stringValue ?? "<unknown>"
                return "[tool] copied \(sourcePath) → \(destinationPath)"
            case "file_info":
                let path = object["path"]?.stringValue ?? "<unknown>"
                return "[tool] inspected \(path)"
            case "find_files":
                let path = object["path"]?.stringValue ?? "."
                let count = object["matches"]?.arrayValue?.count ?? 0
                return "[tool] found \(count) matching paths in \(path)"
            case "search_text":
                let path = object["path"]?.stringValue ?? "."
                let count = object["matches"]?.arrayValue?.count ?? 0
                return "[tool] found \(count) text matches in \(path)"
            case "status", "current_branch", "diff_unstaged", "diff_staged", "log", "show_commit":
                return "[tool] git \(operation)"
            default:
                break
            }
        }

        if let command = object["command"]?.stringValue,
           let exitCode = object["exit_code"]?.intValue {
            return "[tool] shell finished exit \(exitCode) for \(command)"
        }

        return "[tool] \(success ? "completed" : "failed")"
    }

    private func renderDirectoryTree(from value: JSONValue) -> [String]? {
        guard case .object(let object) = value,
              let path = object["path"]?.stringValue else {
            return nil
        }

        let childObjects: [JSONObject]
        if case .array(let rawChildren)? = object["children"] {
            childObjects = rawChildren.compactMap {
                guard case .object(let child) = $0 else { return nil }
                return child
            }
        } else if case .array(let rawEntries)? = object["entries"] {
            childObjects = rawEntries.compactMap { entry in
                guard let name = entry.stringValue else { return nil }
                return ["name": .string(name), "kind": .string("file")]
            }
        } else {
            return nil
        }

        guard !childObjects.isEmpty else {
            return ["Directory \(path)", "`-- <empty>"]
        }

        let sortedChildren = childObjects.sorted { lhs, rhs in
            let lhsIsDirectory = lhs["kind"]?.stringValue == "directory"
            let rhsIsDirectory = rhs["kind"]?.stringValue == "directory"
            if lhsIsDirectory != rhsIsDirectory {
                return lhsIsDirectory && !rhsIsDirectory
            }
            return (lhs["name"]?.stringValue ?? "") < (rhs["name"]?.stringValue ?? "")
        }

        var lines = ["Directory \(path)"]
        for (index, child) in sortedChildren.enumerated() {
            let connector = index == sortedChildren.count - 1 ? "`--" : "|--"
            let name = child["name"]?.stringValue ?? "<unknown>"
            let isDirectory = child["kind"]?.stringValue == "directory"
            lines.append("\(connector) \(name)\(isDirectory ? "/" : "")")
        }
        return lines
    }

    private func renderFileWriteDetails(from value: JSONValue) -> [String]? {
        guard case .object(let object) = value,
              object["operation"]?.stringValue == "write_text_file" else {
            return nil
        }

        let path = object["path"]?.stringValue ?? "<unknown>"
        let bytesWritten = object["bytes_written"]?.intValue ?? 0
        let previousExists = object["previous_exists"] == .bool(true)
        let diffLines = object["diff"]?.arrayValue?.compactMap(\.stringValue) ?? []

        var lines = [
            "Edited \(path)",
            previousExists ? "Previous file existed" : "Created new file",
            "Wrote \(bytesWritten) characters"
        ]
        if !diffLines.isEmpty {
            lines.append("")
            lines.append("Diff")
            lines.append(contentsOf: diffLines)
        }
        return lines
    }

    private func renderFilesystemMutationDetails(from value: JSONValue) -> [String]? {
        guard case .object(let object) = value,
              let operation = object["operation"]?.stringValue else {
            return nil
        }

        switch operation {
        case "replace_in_file":
            let path = object["path"]?.stringValue ?? "<unknown>"
            let diffLines = object["diff"]?.arrayValue?.compactMap(\.stringValue) ?? []
            var lines = ["Updated \(path)"]
            if !diffLines.isEmpty {
                lines.append("")
                lines.append("Diff")
                lines.append(contentsOf: diffLines)
            }
            return lines
        case "apply_patch":
            let path = object["path"]?.stringValue ?? "<unknown>"
            let editCount = object["edit_count"]?.intValue ?? object["applied_edits"]?.arrayValue?.count ?? 0
            let diffLines = object["diff"]?.arrayValue?.compactMap(\.stringValue) ?? []
            var lines = ["Patched \(path)", "Applied \(editCount) edit\(editCount == 1 ? "" : "s")"]
            if !diffLines.isEmpty {
                lines.append("")
                lines.append("Diff")
                lines.append(contentsOf: diffLines)
            }
            return lines
        case "delete_path":
            return ["Deleted \(object["path"]?.stringValue ?? "<unknown>")"]
        case "move_path":
            return [
                "Moved \(object["source_path"]?.stringValue ?? "<unknown>")",
                "To \(object["destination_path"]?.stringValue ?? "<unknown>")"
            ]
        case "copy_path":
            return [
                "Copied \(object["source_path"]?.stringValue ?? "<unknown>")",
                "To \(object["destination_path"]?.stringValue ?? "<unknown>")"
            ]
        case "file_info":
            let path = object["path"]?.stringValue ?? "<unknown>"
            let isDirectory = object["is_directory"] == .bool(true)
            let size = object["size_bytes"]?.intValue ?? 0
            let modifiedAt = object["modified_at"]?.stringValue ?? ""
            return [
                "Path \(path)",
                isDirectory ? "Directory" : "File",
                "Size \(size) bytes",
                modifiedAt.isEmpty ? "Modified time unavailable" : "Modified \(modifiedAt)"
            ]
        default:
            return nil
        }
    }

    private func renderFilesystemSearchDetails(from value: JSONValue) -> [String]? {
        guard case .object(let object) = value,
              let operation = object["operation"]?.stringValue else {
            return nil
        }

        switch operation {
        case "find_files":
            let path = object["path"]?.stringValue ?? "."
            let query = object["query"]?.stringValue ?? ""
            let matches = object["matches"]?.arrayValue?.compactMap(\.stringValue) ?? []
            var lines = ["Find files in \(path)", "Query \(query)"]
            if matches.isEmpty {
                lines.append("No matches")
            } else {
                lines.append("")
                lines.append(contentsOf: matches.map { "- \($0)" })
            }
            return lines
        case "search_text":
            let path = object["path"]?.stringValue ?? "."
            let query = object["query"]?.stringValue ?? ""
            let matches = object["matches"]?.arrayValue ?? []
            var lines = ["Search text in \(path)", "Query \(query)"]
            if matches.isEmpty {
                lines.append("No matches")
            } else {
                lines.append("")
                for match in matches {
                    guard case .object(let object) = match else { continue }
                    let filePath = object["path"]?.stringValue ?? "<unknown>"
                    let line = object["line"]?.intValue ?? 0
                    let text = object["text"]?.stringValue ?? ""
                    lines.append("- \(filePath):\(line) \(text)")
                }
            }
            return lines
        default:
            return nil
        }
    }

    private func renderGitDetails(from value: JSONValue) -> [String]? {
        guard case .object(let object) = value,
              let operation = object["operation"]?.stringValue,
              let stdout = object["stdout"]?.stringValue else {
            return nil
        }

        var lines = ["Git \(operation)"]
        let body = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            lines.append("")
            lines.append(contentsOf: body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        }

        let stderr = object["stderr"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stderr.isEmpty {
            lines.append("")
            lines.append("stderr")
            lines.append(contentsOf: stderr.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        }

        return lines
    }

    private func renderTerminalLines(width: Int, maxBodyHeight: Int) -> [String] {
        let bodyLimit = max(maxBodyHeight - 3, 1)
        let expanded = wrappedTerminalLines(width: width)
        let maxOffset = max(expanded.count - bodyLimit, 0)
        terminalScrollOffset = min(max(terminalScrollOffset, 0), maxOffset)
        let endIndex = max(expanded.count - terminalScrollOffset, 0)
        let startIndex = max(endIndex - bodyLimit, 0)
        let viewport = Array(expanded[startIndex..<endIndex])

        var output = [terminalHeader(width: width, totalLines: expanded.count, visibleLines: bodyLimit), ""]
        output.append(contentsOf: viewport)
        return output
    }

    private func terminalHeader(width: Int, totalLines: Int, visibleLines: Int) -> String {
        let state = terminalTask == nil ? "idle" : "running"
        let focusInfo = focus == .terminal
            ? "\(TerminalUIStyle.cyan)\(terminalScrollOffset == 0 ? "live tail" : "scroll +\(terminalScrollOffset)")\(TerminalUIStyle.reset)"
            : "\(TerminalUIStyle.faint)tab to focus\(TerminalUIStyle.reset)"
        let left = "\(TerminalUIStyle.faint)state\(TerminalUIStyle.reset) \(state)"
        let right = "\(TerminalUIStyle.faint)\(totalLines) lines / \(visibleLines) view\(TerminalUIStyle.reset)  \(focusInfo)"
        return join(left: left, right: right, width: width)
    }

    private func wrappedTerminalLines(width: Int) -> [String] {
        let source = terminalLines.isEmpty ? ["No terminal commands yet."] : terminalLines
        var expanded: [String] = []
        for line in source {
            expanded.append(contentsOf: wrapRunLine(line, width: width))
        }
        return expanded
    }

    private func transcriptMetrics() -> (bodyLimit: Int, totalLines: Int) {
        let size = terminal.terminalSize()
        let chromeHeight = 11
        let bodyHeight = max(size.rows - chromeHeight, 10)
        let leftWidth = max(min(size.columns / 3, 40), 30)
        let rightWidth = max(size.columns - leftWidth - 1, 38)
        let bodyLimit = max(bodyHeight - 3, 1)
        let totalLines = wrappedRunLines(width: rightWidth - 4).count
        return (bodyLimit, totalLines)
    }

    private func terminalMetrics() -> (bodyLimit: Int, totalLines: Int) {
        let size = terminal.terminalSize()
        let chromeHeight = 11
        let bodyHeight = max(size.rows - chromeHeight, 10)
        let availableRightWidth = max(size.columns - max(min(size.columns / 3, 40), 30) - 1, 38)
        let terminalWidth = max(min(availableRightWidth / 3, 48), 32)
        let bodyLimit = max(bodyHeight - 3, 1)
        let totalLines = wrappedTerminalLines(width: terminalWidth - 4).count
        return (bodyLimit, totalLines)
    }

    private func appendTerminalChunks(prefix: String, chunk: String) {
        let pieces = chunk.split(separator: "\n", omittingEmptySubsequences: false)
        let shouldFollowTail = terminalScrollOffset <= 1
        terminalLines.append(contentsOf: pieces.map { "\(prefix) \($0)" })
        if shouldFollowTail {
            terminalScrollOffset = 0
        }
        render()
    }

    private func wrapText(_ text: String, width: Int) -> [String] {
        let limit = max(width, 10)
        if text.count <= limit {
            return [text]
        }

        var lines: [String] = []
        var current = ""

        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if candidate.count <= limit {
                current = candidate
                continue
            }

            if !current.isEmpty {
                lines.append(current)
            }

            if word.count <= limit {
                current = String(word)
                continue
            }

            var remainder = String(word)
            while remainder.count > limit {
                let index = remainder.index(remainder.startIndex, offsetBy: limit)
                lines.append(String(remainder[..<index]))
                remainder = String(remainder[index...])
            }
            current = remainder
        }

        if !current.isEmpty {
            lines.append(current)
        }

        return lines.isEmpty ? [""] : lines
    }

    private var selectedHistoryThread: ThreadSummary? {
        guard historyThreads.indices.contains(historySelection) else { return nil }
        return historyThreads[historySelection]
    }

    private var selectedWorkspace: RecentWorkspaceRecord? {
        guard recentWorkspaces.indices.contains(workspaceSelection) else { return nil }
        return recentWorkspaces[workspaceSelection]
    }

    private func loadRecentWorkspaces() {
        do {
            recentWorkspaces = try RecentWorkspaceStore.load()
            workspaceSelection = min(workspaceSelection, max(recentWorkspaces.count - 1, 0))
            refreshWorkspacePreview()
        } catch {
            recentWorkspaces = []
            workspacePreviewLines = ["[error] \(error.localizedDescription)"]
        }
    }

    private func refreshWorkspacePreview() {
        guard let workspace = selectedWorkspace else {
            workspacePreviewLines = []
            return
        }

        let rootURL = URL(fileURLWithPath: workspace.path)
        let databaseURL = rootURL.appendingPathComponent(".ashex/ashex.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            workspacePreviewLines = ["No persisted Ashex history yet for this workspace."]
            return
        }

        do {
            let store = SQLitePersistenceStore(databaseURL: databaseURL)
            try store.initialize()
            let threads = try store.listThreads(limit: 1)
            guard let thread = threads.first else {
                workspacePreviewLines = ["No persisted threads yet for this workspace."]
                return
            }
            let runs = try store.fetchRuns(threadID: thread.id)
            let latestRun = runs.first
            workspacePreviewLines = [
                "path \(workspace.path)",
                "last used \(Self.timeString(workspace.lastUsedAt))",
                "latest run \(latestRun?.state.rawValue ?? "none")",
                "messages \(thread.messageCount)"
            ]
        } catch {
            workspacePreviewLines = ["[error] \(error.localizedDescription)"]
        }
    }

    private func loadHistory() {
        do {
            historyThreads = try historyStore.listThreads(limit: 20)
            historyRuns = [:]
            for thread in historyThreads {
                historyRuns[thread.id] = try historyStore.fetchRuns(threadID: thread.id)
            }
            historySelection = min(historySelection, max(historyThreads.count - 1, 0))
            refreshHistoryPreview()
        } catch {
            historyThreads = []
            historyRuns = [:]
            historyPreviewLines = ["[error] \(error.localizedDescription)"]
        }
    }

    private func persistSessionSettings() {
        do {
            try historyStore.upsertSetting(namespace: "ui.session", key: "default_provider", value: .string(sessionProvider), now: Date())
            try historyStore.upsertSetting(namespace: "ui.session", key: "default_model", value: .string(sessionModel), now: Date())
        } catch {
            statusLine = "Failed to save settings"
        }
    }

    private func refreshHistoryPreview() {
        guard let thread = selectedHistoryThread,
              let runID = historyRuns[thread.id]?.first?.id ?? thread.latestRunID else {
            historyPreviewLines = []
            return
        }

        do {
            guard let snapshotBundle = try sessionInspector.loadRunSnapshot(runID: runID, recentEventLimit: 8) else {
                historyPreviewLines = ["[error] Run not found"]
                return
            }
            let events = snapshotBundle.events
            let steps = snapshotBundle.steps
            let compactions = snapshotBundle.compactions
            let snapshot = snapshotBundle.workspaceSnapshot
            let memory = snapshotBundle.workingMemory
            var lines: [String] = []
            if let snapshot {
                lines.append("[history] snapshot \(URL(fileURLWithPath: snapshot.workspaceRootPath).lastPathComponent)")
            }
            if let memory, let phase = memory.currentPhase {
                lines.append("[history] memory phase \(phase) • \(memory.changedPaths.count) changed")
            }
            if let memory, !memory.pendingExplorationTargets.isEmpty {
                lines.append("[history] pending exploration \(memory.pendingExplorationTargets.count)")
            }
            if let memory, !memory.unresolvedItems.isEmpty {
                lines.append("[history] unresolved \(memory.unresolvedItems.count)")
            }
            if !steps.isEmpty {
                lines.append("[history] \(steps.count) persisted steps")
                lines.append(contentsOf: steps.suffix(2).map { "[history] step \($0.index) \($0.state.rawValue) - \($0.title)" })
            }
            if !compactions.isEmpty {
                lines.append("[history] \(compactions.count) compaction record(s)")
                if let latest = compactions.last {
                    lines.append("[history] latest compaction dropped \(latest.droppedMessageCount) messages")
                }
            }
            lines.append(contentsOf: events.flatMap { renderLines(for: $0.payload) })
            historyPreviewLines = Array(lines.suffix(8))
        } catch {
            historyPreviewLines = ["[error] \(error.localizedDescription)"]
        }
    }

    private func openSelectedHistoryRun() {
        guard let thread = selectedHistoryThread,
              let runID = historyRuns[thread.id]?.first?.id ?? thread.latestRunID else {
            statusLine = "No stored run to load"
            return
        }

        do {
            guard let snapshotBundle = try sessionInspector.loadRunSnapshot(runID: runID) else {
                statusLine = "Failed to load history"
                runLines = ["[error] Run not found"]
                return
            }
            let events = snapshotBundle.events
            let steps = snapshotBundle.steps
            let compactions = snapshotBundle.compactions
            let snapshot = snapshotBundle.workspaceSnapshot
            let memory = snapshotBundle.workingMemory
            runLines = ["History: thread \(thread.id.uuidString.prefix(8))", ""]
            if let snapshot {
                runLines.append("Workspace snapshot:")
                runLines.append("  root \(snapshot.workspaceRootPath)")
                if !snapshot.topLevelEntries.isEmpty {
                    runLines.append("  top level \(snapshot.topLevelEntries.joined(separator: ", "))")
                }
                if !snapshot.instructionFiles.isEmpty {
                    runLines.append("  instructions \(snapshot.instructionFiles.joined(separator: ", "))")
                }
                if !snapshot.projectMarkers.isEmpty {
                    runLines.append("  markers \(snapshot.projectMarkers.joined(separator: ", "))")
                }
                if !snapshot.sourceRoots.isEmpty {
                    runLines.append("  source roots \(snapshot.sourceRoots.joined(separator: ", "))")
                }
                if !snapshot.testRoots.isEmpty {
                    runLines.append("  test roots \(snapshot.testRoots.joined(separator: ", "))")
                }
                if let branch = snapshot.gitBranch {
                    runLines.append("  branch \(branch)")
                }
                runLines.append("")
            }
            if let memory {
                runLines.append("Working memory:")
                runLines.append("  task \(memory.currentTask)")
                if let phase = memory.currentPhase {
                    runLines.append("  phase \(phase)")
                }
                if !memory.explorationTargets.isEmpty {
                    runLines.append("  targets \(memory.explorationTargets.joined(separator: ", "))")
                }
                if !memory.pendingExplorationTargets.isEmpty {
                    runLines.append("  pending \(memory.pendingExplorationTargets.joined(separator: ", "))")
                }
                if !memory.inspectedPaths.isEmpty {
                    runLines.append("  inspected \(memory.inspectedPaths.joined(separator: ", "))")
                }
                if !memory.changedPaths.isEmpty {
                    runLines.append("  changed \(memory.changedPaths.joined(separator: ", "))")
                }
                if !memory.plannedChangeSet.isEmpty {
                    runLines.append("  patch set \(memory.plannedChangeSet.joined(separator: ", "))")
                }
                if !memory.patchObjectives.isEmpty {
                    runLines.append("  patch goals \(memory.patchObjectives.joined(separator: " | "))")
                }
                if !memory.recentFindings.isEmpty {
                    runLines.append("  findings \(memory.recentFindings.joined(separator: " | "))")
                }
                if !memory.carryForwardNotes.isEmpty {
                    runLines.append("  carry \(memory.carryForwardNotes.joined(separator: " | "))")
                }
                if !memory.completedStepSummaries.isEmpty {
                    runLines.append("  completed \(memory.completedStepSummaries.joined(separator: " | "))")
                }
                if !memory.unresolvedItems.isEmpty {
                    runLines.append("  unresolved \(memory.unresolvedItems.joined(separator: " | "))")
                }
                if !memory.validationSuggestions.isEmpty {
                    runLines.append("  validate \(memory.validationSuggestions.joined(separator: ", "))")
                }
                runLines.append("  summary \(normalizeStoredTranscriptText(memory.summary))")
                runLines.append("")
            }
            if !steps.isEmpty {
                runLines.append("Persisted steps:")
                runLines.append(contentsOf: steps.map { "  \($0.index). [\($0.state.rawValue)] \($0.title)\($0.summary.map { " — " + normalizeStoredTranscriptText($0) } ?? "")" })
                runLines.append("")
            }
            if !compactions.isEmpty {
                runLines.append("Context compactions:")
                for compaction in compactions {
                    runLines.append("  - dropped \(compaction.droppedMessageCount), retained \(compaction.retainedMessageCount), tok~ \(compaction.estimatedTokenCount)/\(compaction.estimatedContextWindow)")
                    runLines.append(contentsOf: compaction.summary.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + String($0) })
                }
                runLines.append("")
            }
            runLines.append(contentsOf: events.flatMap { renderLines(for: $0.payload) })
            currentRunPhase = memory?.currentPhase
            currentChangedFiles = memory?.changedPaths ?? []
            currentPlannedFiles = memory?.plannedChangeSet ?? []
            currentPatchObjectives = memory?.patchObjectives ?? []
            transcriptScrollOffset = 0
            runFinished = true
            showHistory = false
            focus = .transcript
            statusLine = "Loaded history transcript"
        } catch {
            statusLine = "Failed to load history"
            runLines = ["[error] \(error.localizedDescription)"]
        }
    }

    private func openSelectedWorkspace() {
        guard let workspace = selectedWorkspace else {
            statusLine = "No workspace selected"
            return
        }

        workspacePathInput = workspace.path
        commitWorkspacePathInput()
        showWorkspaces = false
        focus = .launcher
    }

    private func makeSessionRuntime() throws -> AgentRuntime {
        try makeSessionRuntime(provider: sessionProvider, model: sessionModel)
    }

    private func makeSessionRuntime(provider: String, model: String) throws -> AgentRuntime {
        let approvalPolicy: any ApprovalPolicy = configuration.approvalMode == .guarded
            ? TUIApprovalPolicy(coordinator: approvalCoordinator)
            : TrustedApprovalPolicy()

        let modelAdapter = try configuration.makeModelAdapter(provider: provider, model: model)
        let persistence = SQLitePersistenceStore(databaseURL: sessionStorageRoot.appendingPathComponent("ashex.sqlite"))
        let shellPolicy = ShellCommandPolicy(config: sessionUserConfig.shell)
        let shellExecutionPolicy = ShellExecutionPolicy(
            sandbox: sessionUserConfig.sandbox,
            network: sessionUserConfig.network,
            shell: shellPolicy
        )
        let workspaceGuard = WorkspaceGuard(rootURL: sessionWorkspaceRoot, sandbox: sessionUserConfig.sandbox)
        return try AgentRuntime(
            modelAdapter: modelAdapter,
            toolRegistry: ToolRegistry(tools: [
                FileSystemTool(workspaceGuard: workspaceGuard),
                GitTool(
                    executionRuntime: ProcessExecutionRuntime(),
                    workspaceURL: sessionWorkspaceRoot
                ),
                BuildTool(
                    executionRuntime: ProcessExecutionRuntime(),
                    workspaceURL: sessionWorkspaceRoot
                ),
                ShellTool(
                    executionRuntime: ProcessExecutionRuntime(),
                    workspaceURL: sessionWorkspaceRoot,
                    executionPolicy: shellExecutionPolicy
                ),
            ]),
            persistence: persistence,
            approvalPolicy: approvalPolicy,
            shellExecutionPolicy: shellExecutionPolicy,
            workspaceSnapshot: WorkspaceSnapshotBuilder.capture(workspaceRoot: sessionWorkspaceRoot)
        )
    }

    private func refreshProviderStatus() async {
        let apiKey = try? configuration.resolvedAPIKey(for: sessionProvider)
        let snapshot = await ProviderInspector.inspect(provider: sessionProvider, model: sessionModel, apiKey: apiKey ?? nil)
        providerStatus = snapshot
        if let providerStartupIssue {
            statusLine = "Provider needs attention"
            runLines = [
                "[startup] Provider '\(sessionProvider)' is unavailable",
                providerStartupIssue,
                Self.recoveryHint(for: sessionProvider)
            ]
            runFinished = true
            transcriptScrollOffset = 0
            self.providerStartupIssue = nil
            render()
            return
        }
        if showSettings || statusLine == "Ready" {
            statusLine = snapshot.headline
        }
        render()
    }

    private func validateRunGuardrails() async throws {
        guard sessionProvider == "ollama" else { return }
        if ProcessInfo.processInfo.environment["ASHEX_ALLOW_LARGE_MODELS"] == "1" { return }

        let snapshot = await ProviderInspector.inspect(provider: sessionProvider, model: sessionModel)
        providerStatus = snapshot
        if let assessment = snapshot.guardrailAssessment, assessment.severity == .blocked {
            let details = ([assessment.headline] + assessment.details).joined(separator: " ")
            throw AshexError.model(details + " Set ASHEX_ALLOW_LARGE_MODELS=1 to override this guardrail.")
        }
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        await withCheckedContinuation { continuation in
            pendingApproval = PendingApproval(request: request) { decision in
                continuation.resume(returning: decision)
            }
            focus = .approval
            statusLine = "Waiting for approval"
            render()
        }
    }
}

private enum TerminalKey {
    case up
    case down
    case left
    case right
    case pageUp
    case pageDown
    case home
    case end
    case enter
    case backspace
    case escape
    case tab
    case space
    case character(Character)
    case unknown
}

private final class TerminalController {
    private var originalTermios = termios()
    private var rawModeEnabled = false

    func enterRawMode() throws {
        guard !rawModeEnabled else { return }
        guard tcgetattr(STDIN_FILENO, &originalTermios) == 0 else {
            throw AshexError.shell("Failed to read terminal attributes")
        }

        var raw = originalTermios
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        raw.c_oflag &= ~tcflag_t(OPOST)
        raw.c_cc.16 = 1
        raw.c_cc.17 = 0

        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else {
            throw AshexError.shell("Failed to enable raw terminal mode")
        }

        rawModeEnabled = true
    }

    func leaveRawMode() {
        guard rawModeEnabled else { return }
        var original = originalTermios
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        rawModeEnabled = false
        write("\u{001B}[?25h\u{001B}[0m\r\n")
    }

    func terminalSize() -> (rows: Int, columns: Int) {
        var windowSize = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &windowSize) == 0,
           windowSize.ws_row > 0,
           windowSize.ws_col > 0 {
            return (Int(windowSize.ws_row), Int(windowSize.ws_col))
        }

        let environment = ProcessInfo.processInfo.environment
        let rows = Int(environment["LINES"] ?? "") ?? 24
        let columns = Int(environment["COLUMNS"] ?? "") ?? 100
        return (rows, columns)
    }

    func write(_ string: String) {
        FileHandle.standardOutput.write(Data(string.utf8))
    }

    func makeKeyStream() -> AsyncStream<TerminalKey> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var buffer = [UInt8](repeating: 0, count: 256)

                while !Task.isCancelled {
                    let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                    guard count > 0 else { continue }
                    let keys = Self.parseKeys(bytes: Array(buffer.prefix(count)))
                    for key in keys {
                        continuation.yield(key)
                    }
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func parseKeys(bytes: [UInt8]) -> [TerminalKey] {
        guard !bytes.isEmpty else { return [.unknown] }

        if bytes.first == 27, bytes.count >= 3, bytes[1] == 91 {
            switch bytes[2] {
            case 65:
                return [.up]
            case 66:
                return [.down]
            case 67:
                return [.right]
            case 68:
                return [.left]
            case 72:
                return [.home]
            case 70:
                return [.end]
            case 49 where bytes.count >= 4 && bytes[3] == 126:
                return [.home]
            case 52 where bytes.count >= 4 && bytes[3] == 126:
                return [.end]
            case 53 where bytes.count >= 4 && bytes[3] == 126:
                return [.pageUp]
            case 54 where bytes.count >= 4 && bytes[3] == 126:
                return [.pageDown]
            default: return [.escape]
            }
        }

        var keys: [TerminalKey] = []
        for byte in bytes {
            switch byte {
            case 9:
                keys.append(.tab)
            case 13, 10:
                keys.append(.enter)
            case 27:
                keys.append(.escape)
            case 127:
                keys.append(.backspace)
            case 32:
                keys.append(.space)
            default:
                if let scalar = UnicodeScalar(Int(byte)) {
                    keys.append(.character(Character(scalar)))
                }
            }
        }
        return keys.isEmpty ? [.unknown] : keys
    }
}

private final class TerminalSurface {
    private let clearScreen = "\u{001B}[?25l\u{001B}[2J\u{001B}[H"
    private var lastLines: [String] = []
    private var lastSize: (rows: Int, columns: Int)?

    func render(lines: [String], size: (rows: Int, columns: Int)) {
        let output = Array(lines.prefix(max(size.rows, 1)))
        var padded = output
        if padded.count < size.rows {
            padded.append(contentsOf: Array(repeating: "", count: size.rows - padded.count))
        }

        var commands = ""
        let needsFullRedraw =
            lastSize?.rows != size.rows ||
            lastSize?.columns != size.columns ||
            lastLines.count != padded.count

        if needsFullRedraw {
            commands += clearScreen
            for (index, line) in padded.enumerated() {
                commands += "\u{001B}[\(index + 1);1H\u{001B}[2K\(line)"
            }
        } else {
            for (index, line) in padded.enumerated() where line != lastLines[index] {
                commands += "\u{001B}[\(index + 1);1H\u{001B}[2K\(line)"
            }
        }

        commands += "\u{001B}[1;1H"
        Swift.print(commands, terminator: "")
        fflush(stdout)
        lastLines = padded
        lastSize = size
    }
}

private enum TerminalUIStyle {
    static let reset = "\u{001B}[0m"
    static let bold = "\u{001B}[1m"
    static let faint = "\u{001B}[38;5;240m"
    static let ink = rgb(230, 236, 245)
    static let slate = rgb(150, 163, 184)
    static let border = rgb(77, 90, 132)
    static let blue = rgb(116, 167, 255)
    static let cyan = rgb(107, 214, 255)
    static let violet = rgb(184, 142, 255)
    static let pink = rgb(255, 135, 182)
    static let green = rgb(130, 223, 166)
    static let amber = rgb(255, 211, 105)
    static let red = rgb(255, 120, 120)
    static let selection = "\u{001B}[48;2;34;47;87m"

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> String {
        "\u{001B}[38;2;\(r);\(g);\(b)m"
    }

    static func stripANSI(from value: String) -> String {
        var result = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            if character == "\u{001B}" {
                guard iterator.next() == "[" else { continue }
                while let next = iterator.next() {
                    if ("@"..."~").contains(next) { break }
                }
                continue
            }
            result.append(character)
        }
        return result
    }

    static func visibleWidth(of value: String) -> Int {
        stripANSI(from: value).count
    }

    static func truncateVisible(_ value: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        let plain = stripANSI(from: value)
        guard plain.count > limit else { return value }
        let index = plain.index(plain.startIndex, offsetBy: max(limit - 1, 0))
        return String(plain[..<index]) + "…"
    }

    static func padVisible(_ value: String, to width: Int) -> String {
        let visible = visibleWidth(of: value)
        guard visible < width else { return value }
        return value + String(repeating: " ", count: width - visible)
    }

    static func rule(width: Int) -> String {
        guard width >= 2 else { return String(repeating: "─", count: max(width, 0)) }
        return border + "├" + String(repeating: "─", count: width - 2) + "┤" + reset
    }
}

private enum ProviderInspector {
    static func inspect(provider: String, model: String, apiKey: String? = nil) async -> TUIApp.ProviderStatusSnapshot {
        switch provider {
        case "mock":
            return .init(
                headline: "Mock provider ready",
                details: [
                    "Rule-based local adapter is active.",
                    "Use this path for quick runtime and tool-loop testing."
                ],
                availableModels: ["mock"],
                guardrailAssessment: nil
            )
        case "openai":
            guard let apiKey, !apiKey.isEmpty else {
                return .init(
                    headline: "OpenAI API key missing",
                    details: [
                        "OpenAI needs an API key before it can fetch models or run prompts.",
                        "Add it in Provider Settings with the API Key action, or set OPENAI_API_KEY before launch.",
                        "After saving the key, choose Refresh Status."
                    ],
                    availableModels: [],
                    guardrailAssessment: nil
                )
            }

            do {
                let models = try await OpenAIModelsClient.fetchModels(apiKey: apiKey)
                let curated = OpenAIModelsClient.curateModels(models)
                let selectedAvailable = curated.contains(model)
                return .init(
                    headline: selectedAvailable ? "OpenAI configuration looks ready" : "Selected OpenAI model not found",
                    details: [
                        "OPENAI_API_KEY is present in the environment.",
                        selectedAvailable
                            ? "The selected model is \(model)."
                            : "The current model \(model) was not returned by the OpenAI models API.",
                        selectedAvailable
                            ? "Choose Refresh Status anytime to fetch the current model list again."
                            : "Pick one of the fetched models below or enter a known model name manually."
                    ],
                    availableModels: curated,
                    guardrailAssessment: nil
                )
            } catch {
                return .init(
                    headline: "OpenAI model list fetch failed",
                    details: [
                        error.localizedDescription,
                        "A 401 usually means the saved key is malformed, expired, or was pasted incorrectly. Re-enter it in Provider Settings, then choose Refresh Status."
                    ],
                    availableModels: [],
                    guardrailAssessment: nil
                )
            }
        case "ollama":
            do {
                let baseURL = CLIConfiguration.ollamaBaseURL()
                let models = try await OllamaCatalogClient().fetchModels(baseURL: baseURL)
                let assessment = LocalModelGuardrails.assessOllamaModel(
                    model: model,
                    installedModels: models,
                    resources: .current()
                )
                let activeStatus: String
                switch assessment.severity {
                case .ok:
                    activeStatus = "Ollama ready with selected model"
                case .warning:
                    activeStatus = assessment.headline
                case .blocked:
                    activeStatus = assessment.headline
                }
                var details = [
                    "Connected to \(baseURL.deletingLastPathComponent().absoluteString).",
                    assessment.details.first ?? "The selected model is \(model)."
                ]
                if models.isEmpty {
                    details.append("No local models were returned by Ollama.")
                }
                let displayModels = models.sorted { $0.name < $1.name }.map { model in
                    if let sizeBytes = model.sizeBytes {
                        return "\(model.name) • \(LocalModelGuardrails.formatBytes(sizeBytes))"
                    }
                    return model.name
                }
                return .init(
                    headline: activeStatus,
                    details: details + assessment.details.dropFirst(),
                    availableModels: displayModels,
                    guardrailAssessment: assessment
                )
            } catch {
                return .init(
                    headline: "Ollama connection failed",
                    details: [
                        error.localizedDescription,
                        "Start Ollama and refresh status again."
                    ],
                    availableModels: [],
                    guardrailAssessment: nil
                )
            }
        case "anthropic":
            guard let apiKey, !apiKey.isEmpty else {
                return .init(
                    headline: "Anthropic API key missing",
                    details: [
                        "Anthropic needs an API key before it can fetch models or run prompts.",
                        "Add it in Provider Settings with the API Key action, or set ANTHROPIC_API_KEY before launch.",
                        "After saving the key, choose Refresh Status."
                    ],
                    availableModels: [],
                    guardrailAssessment: nil
                )
            }

            do {
                let models = try await AnthropicModelsClient.fetchModels(apiKey: apiKey)
                let curated = AnthropicModelsClient.curateModels(models)
                let selectedAvailable = curated.contains(model)
                return .init(
                    headline: selectedAvailable ? "Anthropic configuration looks ready" : "Selected Anthropic model not found",
                    details: [
                        "Anthropic API key is available.",
                        selectedAvailable
                            ? "The selected model is \(model)."
                            : "The current model \(model) was not returned by the Anthropic models API.",
                        selectedAvailable
                            ? "Choose Refresh Status anytime to fetch the current model list again."
                            : "Pick one of the fetched models below or enter a known model name manually."
                    ],
                    availableModels: curated,
                    guardrailAssessment: nil
                )
            } catch {
                return .init(
                    headline: "Anthropic model list fetch failed",
                    details: [
                        error.localizedDescription,
                        "Check the saved API key or network connection, then choose Refresh Status."
                    ],
                    availableModels: [],
                    guardrailAssessment: nil
                )
            }
        default:
            return .init(
                headline: "Unknown provider",
                details: ["Ashex does not know how to inspect \(provider)."],
                availableModels: [],
                guardrailAssessment: nil
            )
        }
    }
}

private enum OpenAIModelsClient {
    private struct Envelope: Decodable {
        let data: [Model]
    }

    private struct Model: Decodable {
        let id: String
        let ownedBy: String?

        enum CodingKeys: String, CodingKey {
            case id
            case ownedBy = "owned_by"
        }
    }

    static func fetchModels(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.openai.com/v1/models")!,
        session: URLSession = .shared
    ) async throws -> [String] {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AshexError.model("OpenAI model list did not return an HTTP response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw AshexError.model("OpenAI rejected the API key (401). Re-enter the key in Provider Settings and verify it is a valid current OpenAI API key.")
            }
            throw AshexError.model("OpenAI model list request failed with status \(httpResponse.statusCode)")
        }

        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return envelope.data.map(\.id)
    }

    static func curateModels(_ models: [String]) -> [String] {
        models
            .filter { model in
                let lowered = model.lowercased()
                let excludedTerms = [
                    "embedding", "whisper", "tts", "transcribe", "moderation",
                    "image", "dall", "realtime", "audio"
                ]
                if excludedTerms.contains(where: lowered.contains) {
                    return false
                }
                return lowered.hasPrefix("gpt") || lowered.hasPrefix("o") || lowered.hasPrefix("codex")
            }
            .sorted()
    }
}

private enum AnthropicModelsClient {
    private struct Envelope: Decodable {
        let data: [Model]
    }

    private struct Model: Decodable {
        let id: String
    }

    static func fetchModels(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.anthropic.com/v1/models")!,
        session: URLSession = .shared
    ) async throws -> [String] {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AshexError.model("Anthropic model list did not return an HTTP response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AshexError.model("Anthropic model list request failed with status \(httpResponse.statusCode)")
        }

        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return envelope.data.map(\.id)
    }

    static func curateModels(_ models: [String]) -> [String] {
        models
            .filter { $0.lowercased().contains("claude") }
            .sorted()
    }
}

private struct PendingApproval {
    let request: ApprovalRequest
    let complete: (ApprovalDecision) -> Void

    func resume(_ decision: ApprovalDecision) {
        complete(decision)
    }
}

private struct TUIApprovalPolicy: ApprovalPolicy {
    let mode: ApprovalMode = .guarded
    private let coordinator: TUIApprovalCoordinator

    init(coordinator: TUIApprovalCoordinator) {
        self.coordinator = coordinator
    }

    func evaluate(_ request: ApprovalRequest) async -> ApprovalDecision {
        await coordinator.evaluate(request)
    }
}

private final class TUIApprovalCoordinator: @unchecked Sendable {
    var handler: (@Sendable (ApprovalRequest) async -> ApprovalDecision)?

    func evaluate(_ request: ApprovalRequest) async -> ApprovalDecision {
        guard let handler else { return .deny("Approval handler is unavailable") }
        return await handler(request)
    }
}
