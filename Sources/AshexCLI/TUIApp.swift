import AshexCore
import Darwin
import Foundation

@MainActor
final class TUIApp {
    private enum InputMode {
        case prompt
        case model
        case apiKey
        case telegramToken
        case telegramAllowedChats
        case telegramAllowedUsers
        case workspacePath
        case terminalCommand
        case onboardingText
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
        case reasoningDebug = "Reasoning Debug"
        case telegramEnabled = "Telegram Enabled"
        case telegramToken = "Telegram Token"
        case telegramAccess = "Telegram Access"
        case telegramAllowedChats = "Telegram Chats"
        case telegramAllowedUsers = "Telegram Users"
        case telegramPolicy = "Telegram Safety"
        case telegramTest = "Telegram Test"
        case daemonToggle = "Daemon"
        case daemonStatus = "Daemon Status"
        case refresh = "Refresh Status"
        case back = "Back"
    }

    private enum OnboardingStep {
        case provider
        case experimentalProvider
        case apiKey
        case model
        case modelDownload
        case telegram
        case telegramToken
        case daemon
        case done
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

    private struct ProviderStartupIssue {
        let provider: String
        let message: String
    }

    private struct OnboardingChoice {
        let title: String
        let subtitle: String
    }

    private let configuration: CLIConfiguration
    private var runtime: AgentRuntime
    private var historyStore: SQLitePersistenceStore
    private let secretStore: any SecretStore
    private let terminal = TerminalController()
    private let surface = TerminalSurface()
    private let approvalCoordinator: TUIApprovalCoordinator
    private let menuItems: [MenuItem] = [
        .init(title: "Chat", subtitle: "Talk to Ashex in the active thread or start a new one", action: .compose),
        .init(title: "Commands", subtitle: "See available tools, operations, and config policy", action: .commands),
        .init(title: "Terminal", subtitle: "Toggle the side shell pane for quick workspace commands", action: .terminal),
        .init(title: "Workspaces", subtitle: "Switch between recent project roots and inspect their latest history", action: .workspaces),
        .init(title: "Threads", subtitle: "Browse saved threads, switch chats, and load transcripts", action: .history),
        .init(title: "Assistant Setup", subtitle: "Configure provider, Telegram, and daemon controls", action: .settings),
        .init(title: "Help", subtitle: "Show keyboard shortcuts and behavior", action: .help),
        .init(title: "Quit", subtitle: "Exit Ashex", action: .quit),
    ]

    private var focus: FocusArea = .launcher
    private var selectedIndex = 0
    private var settingsSelection = 0
    private var modelPickerSelection = 0
    private var promptText = ""
    private var modelInput = ""
    private var apiKeyInput = ""
    private var telegramTokenInput = ""
    private var telegramAllowedChatsInput = ""
    private var telegramAllowedUsersInput = ""
    private var workspacePathInput = ""
    private var terminalCommandInput = ""
    private var onboardingTextInput = ""
    private var inputMode: InputMode = .prompt
    private var showHelp = false
    private var showCommands = false
    private var showWorkspaces = false
    private var showHistory = false
    private var showSettings = false
    private var showModelPicker = false
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
    private var settingsScrollOffset = 0
    private var showToolDetails = false
    private var providerStatus = ProviderStatusSnapshot.idle
    private var daemonStatus: DaemonProcessStatus?
    private var shouldQuit = false
    private var pendingApproval: PendingApproval?
    private var sessionWorkspaceRoot: URL
    private var sessionStorageRoot: URL
    private var sessionUserConfig: AshexUserConfig
    private var sessionUserConfigFile: URL
    private var sessionGlobalUserConfigFile: URL?
    private var sessionProvider: String
    private var sessionModel: String
    private var providerStartupIssue: ProviderStartupIssue?
    private var showOnboarding = false
    private var onboardingStep: OnboardingStep = .provider
    private var onboardingSelection = 0
    private var onboardingStatus = ""
    private var historyThreads: [ThreadSummary] = []
    private var historyRuns: [UUID: [RunRecord]] = [:]
    private var historySelection = 0
    private var historyPreviewLines: [String] = []
    private var recentWorkspaces: [RecentWorkspaceRecord] = []
    private var workspaceSelection = 0
    private var workspacePreviewLines: [String] = []
    private var promptQueue = PromptQueueState()
    private var activeQueuedPrompt: QueuedPrompt?
    private var queueRetryTask: Task<Void, Never>?
    private var terminalLines: [String] = ["No terminal commands yet. Open the pane and run one from the input bar."]
    private var terminalTask: Task<Void, Never>?
    private var terminalCancellation = CancellationToken()
    private var currentRunPhase: String?
    private var currentRunActivity: String?
    private var currentExplorationTargets: [String] = []
    private var currentPendingExplorationTargets: [String] = []
    private var currentRejectedExplorationTargets: [String] = []
    private var currentChangedFiles: [String] = []
    private var currentPlannedFiles: [String] = []
    private var currentPatchObjectives: [String] = []
    private var currentRunTodos: [RunTodoItem] = []
    private var activeThreadID: UUID?
    private var activeChatMessages: [MessageRecord] = []
    private var activeRunID: UUID?
    private var activeRunMode: RunRequest.Mode?
    private var sessionInspector: SessionInspector
    private var tokenSavingsSnapshot: TokenSavingsSnapshot?
    private var tokenUsageSnapshot: TokenUsageSnapshot?

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
            let startupIssue = ProviderStartupIssue(
                provider: configuration.provider,
                message: error.localizedDescription
            )
            self.runtime = try configuration.makeRuntime(
                provider: "mock",
                model: CLIConfiguration.defaultModel(for: "mock"),
                approvalPolicy: approvalPolicy
            )
            self.providerStartupIssue = startupIssue
            self.providerStatus = .init(
                headline: "Provider needs attention",
                details: ProviderFailureRouting.runtimeFailureDetails(
                    provider: configuration.provider,
                    message: error.localizedDescription
                ) + [
                    "The TUI is running with a safe mock fallback so you can still browse history and adjust Provider Settings.",
                    Self.recoveryHint(for: startupIssue, provider: configuration.provider)
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
        loadHistory()
        self.showOnboarding = configuration.forceOnboarding || Self.shouldStartOnboarding(store: historyStore)
        if showOnboarding {
            self.onboardingStep = .provider
            self.onboardingSelection = 0
            self.onboardingStatus = "First-run setup"
            self.focus = .transcript
            self.statusLine = "Set up Ashex"
        }
        Task { [weak self] in
            await self?.refreshProviderStatus()
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.refreshProviderStatus()
        }
        refreshDaemonStatus()
        if sessionUserConfig.daemon.enabled {
            Task { [weak self] in
                await self?.restartDaemonOnAppLaunch()
            }
        }
    }

    private static let onboardingNamespace = "ui.onboarding"
    private static let onboardingCompletedKey = "completed"

    private static func shouldStartOnboarding(store: SQLitePersistenceStore) -> Bool {
        do {
            let completed = try store.fetchSetting(namespace: onboardingNamespace, key: onboardingCompletedKey)?.value.boolValue == true
            let hasSessionDefaults = try store.fetchSetting(namespace: "ui.session", key: "default_provider") != nil
            return !completed && !hasSessionDefaults
        } catch {
            return false
        }
    }

    private static func recoveryHint(for provider: String) -> String {
        ProviderFailureRouting.recoveryHint(provider: provider)
    }

    private static func recoveryHint(for startupIssue: ProviderStartupIssue, provider: String) -> String {
        ProviderFailureRouting.recoveryHint(provider: provider, message: startupIssue.message)
    }

    private static func isProviderAttentionTranscript(_ lines: [String]) -> Bool {
        lines.first?.hasPrefix("[provider] Provider '") == true
    }

    private static func selectableModelName(from displayName: String) -> String? {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.components(separatedBy: " • ").first?.trimmingCharacters(in: .whitespacesAndNewlines)
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
        case .escape:
            handleBack()
        case .left:
            handleLeft()
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
        if showOnboarding {
            focus = inputMode == .onboardingText ? .input : .transcript
            statusLine = "First-run setup"
            return
        }

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
        if showOnboarding {
            moveOnboardingSelection(-1)
            return
        }

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
            if showModelPicker {
                modelPickerSelection = max(modelPickerSelection - 1, 0)
            } else {
                settingsSelection = max(settingsSelection - 1, 0)
            }
        case .transcript:
            scrollTranscript(by: 1)
        case .terminal:
            scrollTerminal(by: 1)
        case .input, .approval:
            break
        }
    }

    private func handleDown() {
        if showOnboarding {
            moveOnboardingSelection(1)
            return
        }

        switch focus {
        case .launcher:
            moveSelection(1)
        case .workspaces:
            workspaceSelection = WorkspaceSelection.clamped(workspaceSelection + 1, recentWorkspaceCount: recentWorkspaces.count)
            refreshWorkspacePreview()
        case .history:
            historySelection = min(historySelection + 1, max(historyThreads.count, 0))
            refreshHistoryPreview()
        case .settings:
            if showModelPicker {
                modelPickerSelection = min(modelPickerSelection + 1, max(ollamaPickerModels.count - 1, 0))
            } else {
                settingsSelection = min(settingsSelection + 1, SettingsAction.allCases.count - 1)
            }
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

        if showOnboarding {
            if commitOnboardingTextIfNeeded() {
                return
            }
            handleOnboardingEnter()
            return
        }

        switch inputMode {
        case .prompt:
            let prompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prompt.isEmpty {
                if handleLocalPromptCommand(prompt) {
                    return
                }
                enqueuePrompt(prompt)
                return
            }
        case .model:
            commitModelInput()
            return
        case .apiKey:
            commitAPIKeyInput()
            return
        case .telegramToken:
            commitTelegramTokenInput()
            return
        case .telegramAllowedUsers:
            commitTelegramAllowedUsersInput()
            return
        case .telegramAllowedChats:
            commitTelegramAllowedChatsInput()
            return
        case .workspacePath:
            commitWorkspacePathInput()
            return
        case .terminalCommand:
            commitTerminalCommand()
            return
        case .onboardingText:
            return
        }

        if focus == .launcher {
            activate(menuItems[selectedIndex].action)
        } else if focus == .workspaces {
            openSelectedWorkspace()
        } else if focus == .history {
            openSelectedHistoryRun()
        } else if focus == .settings {
            if showModelPicker {
                commitSelectedOllamaModel()
                return
            }
            activate(settingsAction: SettingsAction.allCases[settingsSelection])
        } else if focus == .input {
            statusLine = inputMode == .prompt ? "Prompt is empty" : "Model name is empty"
        }
    }

    private func handleBackspace() {
        if showOnboarding, inputMode == .onboardingText {
            guard !onboardingTextInput.isEmpty else { return }
            onboardingTextInput.removeLast()
            focus = .input
            statusLine = "Editing setup answer"
            return
        }

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
        case .telegramToken:
            guard !telegramTokenInput.isEmpty else { return }
            telegramTokenInput.removeLast()
            focus = .input
            statusLine = "Editing Telegram token"
        case .telegramAllowedChats:
            guard !telegramAllowedChatsInput.isEmpty else { return }
            telegramAllowedChatsInput.removeLast()
            focus = .input
            statusLine = "Editing allowed Telegram chats"
        case .telegramAllowedUsers:
            guard !telegramAllowedUsersInput.isEmpty else { return }
            telegramAllowedUsersInput.removeLast()
            focus = .input
            statusLine = "Editing allowed Telegram users"
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
        case .onboardingText:
            break
        }
    }

    private func handleBack() {
        if pendingApproval != nil {
            handleApproval(key: .escape)
            return
        }

        if showOnboarding {
            if inputMode == .onboardingText, !onboardingTextInput.isEmpty {
                onboardingTextInput = ""
                statusLine = "Cleared setup answer"
            } else {
                finishOnboarding(markCompleted: false)
                statusLine = "Onboarding closed; open Assistant Setup anytime"
            }
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
            case .telegramToken where !telegramTokenInput.isEmpty:
                telegramTokenInput = ""
                statusLine = "Cleared Telegram token input"
                return
            case .telegramAllowedChats where !telegramAllowedChatsInput.isEmpty:
                telegramAllowedChatsInput = ""
                statusLine = "Cleared allowed chats input"
                return
            case .telegramAllowedUsers where !telegramAllowedUsersInput.isEmpty:
                telegramAllowedUsersInput = ""
                statusLine = "Cleared allowed users input"
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
            case .telegramToken:
                inputMode = .prompt
                focus = showSettings ? .settings : .launcher
                statusLine = "Back to settings"
                return
            case .telegramAllowedChats:
                inputMode = .prompt
                focus = showSettings ? .settings : .launcher
                statusLine = "Back to settings"
                return
            case .telegramAllowedUsers:
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
            case .onboardingText:
                inputMode = .prompt
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
            if showModelPicker {
                showModelPicker = false
                statusLine = "Closed Ollama model picker"
                return
            }
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

        if isComposeTranscriptVisible {
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
            activeQueuedPrompt = nil
            runLines.append("[local] Run cancelled from TUI")
            statusLine = "Run cancelled"
            processPromptQueueIfPossible()
            return
        }

        shouldQuit = true
    }

    private func handleCharacter(_ character: Character) {
        if showOnboarding {
            handleOnboardingCharacter(character)
            return
        }

        guard focus == .input else { return }
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
        case .telegramToken:
            telegramTokenInput.append(character)
            statusLine = "Editing Telegram token"
        case .telegramAllowedChats:
            telegramAllowedChatsInput.append(character)
            statusLine = "Editing allowed Telegram chats"
        case .telegramAllowedUsers:
            telegramAllowedUsersInput.append(character)
            statusLine = "Editing allowed Telegram users"
        case .workspacePath:
            workspacePathInput.append(character)
            statusLine = "Editing workspace"
        case .terminalCommand:
            terminalCommandInput.append(character)
            statusLine = "Editing terminal command"
        case .onboardingText:
            onboardingTextInput.append(character)
            statusLine = "Editing setup answer"
        }
        if inputMode == .prompt {
            showHelp = false
            showSettings = false
            showCommands = false
        }
    }

    private func handleLeft() {
        if pendingApproval != nil {
            handleApproval(key: .left)
            return
        }

        if showOnboarding {
            if inputMode == .onboardingText, !onboardingTextInput.isEmpty {
                onboardingTextInput = ""
                statusLine = "Cleared setup answer"
            } else {
                skipOnboardingStep()
                statusLine = "Skipped setup item"
            }
            return
        }

        handleBack()
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
            statusLine = activeThreadID == nil ? "Start a new chat below" : "Continue the active chat below"
        case .commands:
            showCommands = true
            showHistory = false
            showWorkspaces = false
            showSettings = false
            showHelp = false
            transcriptScrollOffset = 0
            focus = .transcript
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
            statusLine = historyThreads.isEmpty ? "No saved threads yet" : "Threads"
        case .settings:
            showSettings = true
            showHistory = false
            showWorkspaces = false
            showCommands = false
            showHelp = false
            focus = .settings
            settingsScrollOffset = 0
            refreshDaemonStatus()
            statusLine = "Assistant setup"
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
            if sessionProvider == "ollama", !ollamaPickerModels.isEmpty {
                showModelPicker = true
                modelPickerSelection = selectedOllamaModelPickerIndex()
                focus = .settings
                statusLine = "Choose an Ollama model and press Enter"
            } else {
                inputMode = .model
                modelInput = sessionModel
                focus = .input
                statusLine = "Edit model and press Enter to apply"
            }
        case .apiKey:
            inputMode = .apiKey
            apiKeyInput = ""
            focus = .input
            statusLine = "Enter API key and press Enter to save"
        case .reasoningDebug:
            sessionUserConfig.debug.reasoningSummaries.toggle()
            persistUserConfig()
            refreshSessionRuntime()
            statusLine = sessionUserConfig.debug.reasoningSummaries
                ? "Reasoning summaries enabled"
                : "Reasoning summaries disabled"
        case .telegramEnabled:
            sessionUserConfig.telegram.enabled.toggle()
            persistUserConfig()
            refreshDaemonStatus()
            statusLine = sessionUserConfig.telegram.enabled ? "Telegram connector enabled" : "Telegram connector disabled"
        case .telegramToken:
            inputMode = .telegramToken
            telegramTokenInput = ""
            focus = .input
            statusLine = "Paste the Telegram bot token and press Enter to save"
        case .telegramAccess:
            let allModes = TelegramAccessMode.allCases
            if let currentIndex = allModes.firstIndex(of: sessionUserConfig.telegram.accessMode) {
                let nextIndex = allModes.index(after: currentIndex)
                sessionUserConfig.telegram.accessMode = nextIndex == allModes.endIndex
                    ? allModes[allModes.startIndex]
                    : allModes[nextIndex]
            } else {
                sessionUserConfig.telegram.accessMode = .open
            }
            persistUserConfig()
            statusLine = "Telegram access mode: \(sessionUserConfig.telegram.accessMode.rawValue)"
        case .telegramAllowedChats:
            inputMode = .telegramAllowedChats
            telegramAllowedChatsInput = sessionUserConfig.telegram.allowedChatIDs.joined(separator: ",")
            focus = .input
            statusLine = "Enter comma-separated Telegram chat IDs and press Enter"
        case .telegramAllowedUsers:
            inputMode = .telegramAllowedUsers
            telegramAllowedUsersInput = sessionUserConfig.telegram.allowedUserIDs.joined(separator: ",")
            focus = .input
            statusLine = "Enter comma-separated Telegram user IDs and press Enter"
        case .telegramPolicy:
            let allModes = ConnectorExecutionPolicyMode.allCases
            if let currentIndex = allModes.firstIndex(of: sessionUserConfig.telegram.executionPolicy) {
                let nextIndex = allModes.index(after: currentIndex)
                sessionUserConfig.telegram.executionPolicy = nextIndex == allModes.endIndex
                    ? allModes[allModes.startIndex]
                    : allModes[nextIndex]
            } else {
                sessionUserConfig.telegram.executionPolicy = .assistantOnly
            }
            persistUserConfig()
            statusLine = "Telegram safety mode: \(sessionUserConfig.telegram.executionPolicy.rawValue)"
        case .telegramTest:
            statusLine = "Testing Telegram connection"
            Task { [weak self] in
                await self?.runTelegramConnectivityTest()
            }
        case .daemonToggle:
            Task { [weak self] in
                await self?.toggleDaemonFromSettings()
            }
        case .daemonStatus:
            refreshDaemonStatus()
            statusLine = daemonStatus?.isRunning == true ? "Daemon is running" : "Daemon is stopped"
        case .refresh:
            statusLine = "Refreshing provider status"
            Task { [weak self] in
                await self?.refreshProviderStatus()
                await MainActor.run {
                    self?.refreshDaemonStatus()
                }
            }
        case .back:
            showSettings = false
            inputMode = .prompt
            focus = .launcher
            statusLine = "Back to launcher"
        }
    }

    private var onboardingChoices: [OnboardingChoice] {
        switch onboardingStep {
        case .provider:
            return [
                .init(title: "ollama", subtitle: "Local Ollama models on this Mac"),
                .init(title: "openai", subtitle: "Hosted OpenAI models with an API key"),
                .init(title: "anthropic", subtitle: "Hosted Claude models with an API key"),
                .init(title: "mock", subtitle: "Offline mock adapter for testing tools without a model"),
                .init(title: "Experimental providers", subtitle: "Try local experimental backends such as DFlash"),
                .init(title: "Skip provider", subtitle: "Keep \(sessionProvider) with model \(sessionModel)")
            ]
        case .experimentalProvider:
            return [
                .init(title: "dflash", subtitle: "Local DFlash server at \(sessionUserConfig.dflash.baseURL)"),
                .init(title: "Back to providers", subtitle: "Return to the main provider list"),
                .init(title: "Skip provider", subtitle: "Keep \(sessionProvider) with model \(sessionModel)")
            ]
        case .apiKey:
            return [
                .init(title: "Enter API key", subtitle: "Save it in local secrets JSON"),
                .init(title: "Skip API key", subtitle: "Keep configuring; prompts will wait until a key is added")
            ]
        case .model:
            var choices: [OnboardingChoice] = []
            choices.append(contentsOf: modelChoicesFromProviderStatus())
            choices.append(.init(title: "Enter model manually", subtitle: "Type any provider-specific model name"))
            if sessionProvider == "ollama" {
                choices.append(.init(title: "Download Ollama model", subtitle: "Run `ollama pull <model>` from setup"))
                choices.append(.init(title: "Refresh local models", subtitle: "Ask Ollama for the current model list again"))
            } else {
                choices.append(.init(title: "Refresh model list", subtitle: "Fetch available models for the selected provider"))
            }
            choices.append(OnboardingChoice(title: "Skip model", subtitle: "Use \(sessionModel)"))
            return choices
        case .modelDownload:
            return [
                .init(title: "Pull model", subtitle: "Type an Ollama model name below, then press Enter"),
                .init(title: "Skip download", subtitle: "Continue without downloading a model")
            ]
        case .telegram:
            return [
                .init(title: "Connect Telegram", subtitle: "Enable Telegram and paste your own bot token from BotFather"),
                .init(title: "Skip Telegram", subtitle: "Use Ashex only from this terminal for now")
            ]
        case .telegramToken:
            return [
                .init(title: "Save Telegram token", subtitle: "Paste a bot token below, then press Enter"),
                .init(title: "Skip token", subtitle: "Leave Telegram disabled until you add one later")
            ]
        case .daemon:
            return [
                .init(title: "Start daemon", subtitle: "Run Ashex in the background for Telegram/remote tasks"),
                .init(title: "Skip daemon", subtitle: "Start it later from Assistant Setup")
            ]
        case .done:
            return [
                .init(title: "Open Ashex", subtitle: "Finish onboarding and show the main UI")
            ]
        }
    }

    private func modelChoicesFromProviderStatus() -> [OnboardingChoice] {
        providerStatus.availableModels.prefix(8).compactMap { displayName in
            guard let name = Self.selectableModelName(from: displayName) else { return nil }
            return OnboardingChoice(title: name, subtitle: displayName == name ? "Available from \(sessionProvider)" : displayName)
        }
    }

    private func moveOnboardingSelection(_ delta: Int) {
        let choices = onboardingChoices
        guard !choices.isEmpty else { return }
        onboardingSelection = min(max(onboardingSelection + delta, 0), choices.count - 1)
        statusLine = "First-run setup"
    }

    private func handleOnboardingCharacter(_ character: Character) {
        if inputMode == .onboardingText {
            onboardingTextInput.append(character)
            focus = .input
            statusLine = "Editing setup answer"
            return
        }

        switch character {
        case "s", "S":
            skipOnboardingStep()
        case "r" where onboardingStep == .model, "R" where onboardingStep == .model:
            refreshOnboardingModels()
        case "d" where onboardingStep == .model && sessionProvider == "ollama",
             "D" where onboardingStep == .model && sessionProvider == "ollama":
            beginOnboardingText(step: .modelDownload, placeholderStatus: "Type an Ollama model name to download")
        default:
            return
        }
    }

    private func handleOnboardingEnter() {
        switch onboardingStep {
        case .provider:
            let choices = onboardingChoices
            guard choices.indices.contains(onboardingSelection) else { return }
            let choice = choices[onboardingSelection].title
            if choice == "Experimental providers" {
                advanceOnboarding(to: .experimentalProvider)
            } else if choice == "Skip provider" {
                advanceOnboarding(to: providerNeedsAPIKey(sessionProvider) ? .apiKey : .model)
            } else {
                applyOnboardingProvider(choice)
                advanceOnboarding(to: providerNeedsAPIKey(sessionProvider) ? .apiKey : .model)
            }
        case .experimentalProvider:
            let choices = onboardingChoices
            guard choices.indices.contains(onboardingSelection) else { return }
            let choice = choices[onboardingSelection].title
            if choice == "Back to providers" {
                advanceOnboarding(to: .provider)
            } else if choice == "Skip provider" {
                advanceOnboarding(to: providerNeedsAPIKey(sessionProvider) ? .apiKey : .model)
            } else {
                applyOnboardingProvider(choice)
                advanceOnboarding(to: providerNeedsAPIKey(sessionProvider) ? .apiKey : .model)
            }
        case .apiKey:
            if onboardingSelection == 0 {
                beginOnboardingText(step: .apiKey, placeholderStatus: "Paste \(sessionProvider.capitalized) API key")
            } else {
                advanceOnboarding(to: .model)
            }
        case .model:
            handleOnboardingModelChoice()
        case .modelDownload:
            if inputMode == .onboardingText {
                commitOnboardingModelDownload()
            } else if onboardingSelection == 0 {
                beginOnboardingText(step: .modelDownload, placeholderStatus: "Type an Ollama model name to download")
            } else {
                advanceOnboarding(to: .telegram)
            }
        case .telegram:
            if onboardingSelection == 0 {
                sessionUserConfig.telegram.enabled = true
                persistUserConfig()
                advanceOnboarding(to: .telegramToken)
            } else {
                sessionUserConfig.telegram.enabled = false
                persistUserConfig()
                advanceOnboarding(to: .daemon)
            }
        case .telegramToken:
            if inputMode == .onboardingText {
                commitOnboardingTelegramToken()
            } else if onboardingSelection == 0 {
                beginOnboardingText(step: .telegramToken, placeholderStatus: "Paste Telegram bot token")
            } else {
                skipOnboardingTelegramToken()
            }
        case .daemon:
            if onboardingSelection == 0 {
                onboardingStatus = "Starting daemon..."
                Task { [weak self] in
                    let started = await self?.toggleDaemonFromSettings() ?? false
                    await MainActor.run {
                        if started {
                            self?.advanceOnboarding(to: .done)
                        }
                    }
                }
            } else {
                advanceOnboarding(to: .done)
            }
        case .done:
            finishOnboarding(markCompleted: true)
        }
    }

    private func handleOnboardingModelChoice() {
        let choices = onboardingChoices
        guard choices.indices.contains(onboardingSelection) else { return }
        let choice = choices[onboardingSelection].title

        switch choice {
        case "Enter model manually":
            beginOnboardingText(step: .model, placeholderStatus: "Type model name")
        case "Download Ollama model":
            beginOnboardingText(step: .modelDownload, placeholderStatus: "Type an Ollama model name to download")
        case "Refresh local models", "Refresh model list":
            refreshOnboardingModels()
        case "Skip model":
            selectSafestOnboardingOllamaModelIfNeeded()
            advanceOnboarding(to: .telegram)
        default:
            sessionModel = choice
            refreshSessionRuntime()
            persistSessionSettings()
            onboardingStatus = "Selected model \(sessionModel)"
            advanceOnboarding(to: .telegram)
        }
    }

    private func beginOnboardingText(step: OnboardingStep, placeholderStatus: String) {
        onboardingStep = step
        onboardingTextInput = step == .model ? sessionModel : ""
        inputMode = .onboardingText
        focus = .input
        onboardingSelection = 0
        statusLine = placeholderStatus
        onboardingStatus = placeholderStatus
    }

    private func commitOnboardingTextIfNeeded() -> Bool {
        guard inputMode == .onboardingText else { return false }
        let trimmed = onboardingTextInput.trimmingCharacters(in: .whitespacesAndNewlines)

        switch onboardingStep {
        case .apiKey:
            guard !trimmed.isEmpty else {
                advanceOnboarding(to: .model)
                return true
            }
            do {
                let normalized = normalizeAPIKeyInput(trimmed, for: sessionProvider)
                try secretStore.writeSecret(namespace: "provider.credentials", key: CLIConfiguration.apiKeySettingKey(for: sessionProvider), value: normalized)
                onboardingStatus = "\(sessionProvider.capitalized) API key saved in local secrets JSON"
            } catch {
                onboardingStatus = "Failed to save API key: \(error.localizedDescription)"
            }
            advanceOnboarding(to: .model)
            return true
        case .model:
            guard !trimmed.isEmpty else {
                advanceOnboarding(to: .telegram)
                return true
            }
            sessionModel = trimmed
            refreshSessionRuntime()
            persistSessionSettings()
            onboardingStatus = "Selected model \(sessionModel)"
            advanceOnboarding(to: .telegram)
            return true
        case .telegramToken:
            commitOnboardingTelegramToken()
            return true
        case .modelDownload:
            commitOnboardingModelDownload()
            return true
        default:
            return false
        }
    }

    private func commitOnboardingTelegramToken() {
        let trimmed = onboardingTextInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            skipOnboardingTelegramToken()
            return
        }

        do {
            let normalized = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            try secretStore.writeSecret(namespace: DaemonCLI.telegramSecretNamespace, key: DaemonCLI.telegramSecretKey, value: normalized)
            sessionUserConfig.telegram.botToken = nil
            sessionUserConfig.telegram.enabled = true
            persistUserConfig()
            onboardingStatus = "Telegram token saved in local secrets JSON"
        } catch {
            onboardingStatus = "Failed to save Telegram token: \(error.localizedDescription)"
        }
        advanceOnboarding(to: .daemon)
    }

    private func skipOnboardingTelegramToken() {
        sessionUserConfig.telegram.enabled = false
        persistUserConfig()
        onboardingStatus = "Telegram left disabled until a bot token is added"
        advanceOnboarding(to: .daemon)
    }

    private func commitOnboardingModelDownload() {
        let modelName = onboardingTextInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelName.isEmpty else {
            advanceOnboarding(to: .telegram)
            return
        }
        guard sessionProvider == "ollama" else {
            sessionModel = modelName
            refreshSessionRuntime()
            persistSessionSettings()
            advanceOnboarding(to: .telegram)
            return
        }

        onboardingStatus = "Downloading \(modelName) with ollama pull..."
        inputMode = .prompt
        focus = .transcript
        render()
        Task { [weak self] in
            let result = await Self.runOllamaPull(modelName: modelName)
            await MainActor.run {
                guard let self else { return }
                if result.success {
                    self.sessionModel = modelName
                    self.refreshSessionRuntime()
                    self.persistSessionSettings()
                    self.onboardingStatus = "Downloaded and selected \(modelName)"
                } else {
                    self.onboardingStatus = "Download failed: \(result.message ?? "unknown error")"
                }
                self.advanceOnboarding(to: .telegram)
            }
        }
    }

    private static func runOllamaPull(modelName: String) async -> (success: Bool, message: String?) {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["ollama", "pull", modelName]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    return (true, nil)
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? "ollama pull exited \(process.terminationStatus)"
                return (false, output.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                return (false, error.localizedDescription)
            }
        }.value
    }

    private func refreshOnboardingModels() {
        onboardingStatus = "Refreshing \(sessionProvider) models..."
        Task { [weak self] in
            await self?.refreshProviderStatus()
            await MainActor.run {
                self?.onboardingSelection = 0
                self?.onboardingStatus = self?.providerStatus.headline ?? "Model refresh completed"
                self?.render()
            }
        }
    }

    private func applyOnboardingProvider(_ provider: String) {
        sessionProvider = provider
        sessionModel = CLIConfiguration.defaultModel(for: provider)
        showModelPicker = false
        providerStartupIssue = nil
        refreshSessionRuntime()
        persistSessionSettings()
        onboardingStatus = "Provider set to \(provider)"
        Task { [weak self] in
            await self?.refreshProviderStatus()
        }
    }

    private func providerNeedsAPIKey(_ provider: String) -> Bool {
        provider == "openai" || provider == "anthropic"
    }

    private func skipOnboardingStep() {
        switch onboardingStep {
        case .provider, .experimentalProvider:
            advanceOnboarding(to: providerNeedsAPIKey(sessionProvider) ? .apiKey : .model)
        case .apiKey:
            advanceOnboarding(to: .model)
        case .model, .modelDownload:
            advanceOnboarding(to: .telegram)
        case .telegram, .telegramToken:
            advanceOnboarding(to: .daemon)
        case .daemon:
            advanceOnboarding(to: .done)
        case .done:
            finishOnboarding(markCompleted: true)
        }
    }

    private func advanceOnboarding(to step: OnboardingStep) {
        onboardingStep = step
        onboardingSelection = 0
        onboardingTextInput = ""
        inputMode = .prompt
        focus = .transcript
        transcriptScrollOffset = 0
        if step == .done {
            onboardingStatus = onboardingStatus.isEmpty ? "Setup complete" : onboardingStatus
        }
        render()
    }

    private func finishOnboarding(markCompleted: Bool) {
        if markCompleted {
            do {
                try historyStore.upsertSetting(namespace: Self.onboardingNamespace, key: Self.onboardingCompletedKey, value: .bool(true), now: Date())
            } catch {
                statusLine = "Failed to save onboarding state"
            }
        }
        showOnboarding = false
        onboardingStep = .provider
        onboardingSelection = 0
        onboardingTextInput = ""
        inputMode = .prompt
        focus = .launcher
        showSettings = false
        showHistory = false
        showWorkspaces = false
        showCommands = false
        showHelp = false
        if sessionProvider == "ollama" {
            providerStartupIssue = nil
        }
        clearProviderAttentionTranscriptIfPresent()
        statusLine = "Ready"
        render()
    }

    private func cycleProvider() {
        let providers = ["mock", "ollama", "dflash", "openai", "anthropic"]
        let currentIndex = providers.firstIndex(of: sessionProvider) ?? 0
        let nextProvider = providers[(currentIndex + 1) % providers.count]

        sessionProvider = nextProvider
        sessionModel = CLIConfiguration.defaultModel(for: nextProvider)
        showModelPicker = false
        providerStartupIssue = nil
        if Self.isProviderAttentionTranscript(runLines) {
            runLines = []
            transcriptScrollOffset = 0
        }
        refreshSessionRuntime()
        persistSessionSettings()
        statusLine = "Provider switched to \(sessionProvider)"

        Task { [weak self] in
            await self?.refreshProviderStatus()
        }
    }

    private func commitTelegramTokenInput() {
        let trimmed = telegramTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusLine = "Telegram token is empty"
            return
        }

        do {
            let normalized = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            try secretStore.writeSecret(
                namespace: DaemonCLI.telegramSecretNamespace,
                key: DaemonCLI.telegramSecretKey,
                value: normalized
            )
            sessionUserConfig.telegram.botToken = nil
            sessionUserConfig.telegram.enabled = true
            persistUserConfig()
            telegramTokenInput = ""
            inputMode = .prompt
            focus = .settings
            statusLine = "Telegram token saved in local secrets JSON"
        } catch {
            statusLine = "Failed to save Telegram token"
        }
    }

    private func commitTelegramAllowedChatsInput() {
        let values = telegramAllowedChatsInput
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        sessionUserConfig.telegram.allowedChatIDs = values
        persistUserConfig()
        inputMode = .prompt
        focus = .settings
        statusLine = values.isEmpty ? "Telegram chat allowlist cleared" : "Saved \(values.count) allowed chat ID(s)"
    }

    private func commitTelegramAllowedUsersInput() {
        let values = telegramAllowedUsersInput
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        sessionUserConfig.telegram.allowedUserIDs = values
        persistUserConfig()
        inputMode = .prompt
        focus = .settings
        statusLine = values.isEmpty ? "Telegram user allowlist cleared" : "Saved \(values.count) allowed user ID(s)"
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

    private var ollamaPickerModels: [String] {
        guard sessionProvider == "ollama" else { return [] }
        return OllamaModelDisplayOrdering.orderedDisplayNames(
            providerStatus.availableModels,
            selectedModel: sessionModel
        ).compactMap(Self.selectableModelName(from:))
    }

    private func selectedOllamaModelPickerIndex() -> Int {
        let models = ollamaPickerModels
        guard !models.isEmpty else { return 0 }
        return models.firstIndex(of: sessionModel) ?? 0
    }

    private func commitSelectedOllamaModel() {
        let models = ollamaPickerModels
        guard !models.isEmpty else {
            statusLine = "No Ollama models available yet. Refresh status first."
            showModelPicker = false
            return
        }

        let index = min(max(modelPickerSelection, 0), models.count - 1)
        sessionModel = models[index]
        showModelPicker = false
        refreshSessionRuntime()
        persistSessionSettings()
        statusLine = "Model updated to \(sessionModel)"

        Task { [weak self] in
            await self?.refreshProviderStatus()
        }
    }

    private func commitWorkspacePathInput() {
        let normalizedInput = normalizeWorkspacePathInput(workspacePathInput)
        guard !normalizedInput.isEmpty else {
            statusLine = "Workspace path is empty"
            return
        }

        let proposed = URL(
            fileURLWithPath: normalizedInput,
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ).standardizedFileURL

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: proposed.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            statusLine = "Workspace directory not found"
            return
        }

        do {
            try switchWorkspace(to: proposed)
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
            loadHistory()
            refreshDaemonStatus()
            statusLine = "Workspace updated"
            Task { [weak self] in
                await self?.refreshProviderStatus()
            }
        } catch {
            statusLine = "Failed to switch workspace: \(error.localizedDescription)"
        }
    }

    private func normalizeWorkspacePathInput(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
        }
        if trimmed.hasPrefix("'"), trimmed.hasSuffix("'"), trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
        }
        if trimmed.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            trimmed = home + trimmed.dropFirst()
        }
        return trimmed
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
        let previousRuntime = runtime
        do {
            runtime = try makeSessionRuntime()
            providerStartupIssue = nil
        } catch {
            let startupIssue = ProviderStartupIssue(provider: sessionProvider, message: error.localizedDescription)
            providerStartupIssue = startupIssue
            let failureDetails = ProviderFailureRouting.runtimeFailureDetails(
                provider: sessionProvider,
                message: error.localizedDescription
            )

            do {
                runtime = try makeSessionRuntime(provider: "mock", model: CLIConfiguration.defaultModel(for: "mock"))
            } catch {
                runtime = previousRuntime
            }

            providerStatus = .init(
                headline: "Provider needs attention",
                details: failureDetails + [Self.recoveryHint(for: startupIssue, provider: sessionProvider)],
                availableModels: [],
                guardrailAssessment: nil
            )
            statusLine = promptQueue.isEmpty ? "Provider needs attention" : "Prompt queue waiting for provider"
            if !promptQueue.isEmpty {
                schedulePromptQueueRetry()
            }
        }

        processPromptQueueIfPossible()
    }

    private func switchWorkspace(to proposed: URL) throws {
        stopWorkingIndicator()
        runTask?.cancel()
        runTask = nil
        runExecutionControl = nil
        activeQueuedPrompt = nil
        queueRetryTask?.cancel()
        queueRetryTask = nil

        terminalTask?.cancel()
        terminalTask = nil
        terminalCancellation = CancellationToken()
        terminalLines = ["No terminal commands yet. Open the pane and run one from the input bar."]
        terminalScrollOffset = 0

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
        workspaceSelection = 0
        workspacePreviewLines = []
        activeThreadID = nil
        activeChatMessages = []
        providerStartupIssue = nil
        promptQueue = PromptQueueState()
        activeQueuedPrompt = nil
        refreshSessionRuntime()
    }

    @discardableResult
    private func handleLocalPromptCommand(_ prompt: String) -> Bool {
        guard let command = LocalPromptCommand.parse(prompt) else {
            return false
        }

        switch command {
        case .showWorkspace:
            presentLocalPromptResult(lines: [
                "Prompt: /pwd",
                "",
                "[local] Current workspace",
                sessionWorkspaceRoot.path
            ], status: "Workspace shown")
            return true
        case .showWorkspaceHelp:
            presentLocalPromptResult(lines: [
                "Prompt: /workspace",
                "",
                "[local] Workspace commands",
                SimpleWorkspaceCommandExecutor.workspaceHelp(
                    workspaceRoot: sessionWorkspaceRoot,
                    startupCommand: "ashex daemon run --workspace \(sessionWorkspaceRoot.path) --provider \(sessionProvider) --model \(sessionModel)"
                )
            ], status: "Workspace help shown")
            return true
        case .showLastRun:
            do {
                let inspector = SessionInspector(persistence: historyStore)
                let text = try inspector.summarizeLatestRun(recentEventLimit: 500)
                    .map { SessionInspector.format(summary: $0) }
                    ?? "No persisted runs were found for this workspace yet."
                presentLocalPromptResult(lines: [
                    "Prompt: /last",
                    "",
                    "[local] Last run",
                    text
                ], status: "Last run shown")
            } catch {
                presentLocalPromptResult(lines: [
                    "Prompt: /last",
                    "",
                    "[error] \(error.localizedDescription)"
                ], status: "Last run unavailable")
            }
            return true
        case .simpleWorkspace(let workspaceCommand):
            do {
                let text = try SimpleWorkspaceCommandExecutor.execute(
                    workspaceCommand,
                    workspaceRoot: sessionWorkspaceRoot,
                    sandbox: sessionUserConfig.sandbox
                )
                presentLocalPromptResult(lines: [
                    "Prompt: \(prompt.trimmingCharacters(in: .whitespacesAndNewlines))",
                    "",
                    "[local] Workspace",
                    text
                ], status: "Workspace command completed")
            } catch {
                presentLocalPromptResult(lines: [
                    "Prompt: \(prompt.trimmingCharacters(in: .whitespacesAndNewlines))",
                    "",
                    "[error] \(error.localizedDescription)"
                ], status: "Workspace command failed")
            }
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
        case .showToolPacks:
            presentToolPackStatus(prompt: "/toolpacks")
            return true
        case .installToolPack(let packID):
            installBundledToolPack(packID)
            return true
        case .uninstallToolPack(let packID):
            uninstallBundledToolPack(packID)
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

    private func presentLocalPromptResult(lines: [String], status: String) {
        runTask?.cancel()
        runExecutionControl = nil
        stopWorkingIndicator()
        runLines = lines
        transcriptScrollOffset = 0
        runFinished = true
        runStartedAt = nil
        promptText = ""
        inputMode = .prompt
        showSettings = false
        showHelp = false
        showHistory = false
        showCommands = false
        focus = .transcript
        statusLine = status
    }

    private func presentToolPackStatus(prompt: String) {
        runTask?.cancel()
        runExecutionControl = nil
        stopWorkingIndicator()
        let availablePacks = (try? ToolPackManager.availableBundledPacks()) ?? []
        let enabledIDs = (try? ToolPackManager.enabledBundledPackIDs(persistence: historyStore)) ?? ToolPackSettings.defaultBundledPackIDs
        let packLines: [String]
        if availablePacks.isEmpty {
            packLines = ["No bundled tool packs found."]
        } else {
            packLines = availablePacks.map { pack in
                let enabled = enabledIDs.contains(pack.id) ? "enabled" : "disabled"
                return "- \(pack.id) (\(enabled)): \(pack.description)"
            }
        }

        runLines = [
            "Prompt: \(prompt)",
            "",
            "[local] Tool packs",
            "Bundled packs:",
        ] + packLines + [
            "",
            "Custom manifests auto-load from:",
            "- \(sessionWorkspaceRoot.appendingPathComponent("toolpacks").path)",
            "- \(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ashex/toolpacks").path)",
        ]
        transcriptScrollOffset = 0
        runFinished = true
        runStartedAt = nil
        promptText = ""
        inputMode = .prompt
        focus = .transcript
        statusLine = "Tool packs"
    }

    private func installBundledToolPack(_ packID: String) {
        do {
            let available = try ToolPackManager.availableBundledPacks()
            guard available.contains(where: { $0.id == packID }) else {
                runLines = ["Prompt: /install-pack \(packID)", "", "[local] Tool packs", "Unknown bundled tool pack '\(packID)'."]
                runFinished = true
                statusLine = "Unknown tool pack"
                promptText = ""
                inputMode = .prompt
                focus = .transcript
                return
            }

            var enabled = try ToolPackManager.enabledBundledPackIDs(persistence: historyStore)
            if !enabled.contains(packID) {
                enabled.append(packID)
            }
            try ToolPackManager.saveEnabledBundledPackIDs(enabled, persistence: historyStore, now: Date())
            presentToolPackStatus(prompt: "/install-pack \(packID)")
            statusLine = "Installed tool pack \(packID)"
        } catch {
            runLines = ["Prompt: /install-pack \(packID)", "", "[local] Tool packs", "Failed to install tool pack: \(error.localizedDescription)"]
            runFinished = true
            statusLine = "Tool pack install failed"
            promptText = ""
            inputMode = .prompt
            focus = .transcript
        }
    }

    private func uninstallBundledToolPack(_ packID: String) {
        do {
            var enabled = try ToolPackManager.enabledBundledPackIDs(persistence: historyStore)
            enabled.removeAll { $0 == packID }
            try ToolPackManager.saveEnabledBundledPackIDs(enabled, persistence: historyStore, now: Date())
            presentToolPackStatus(prompt: "/uninstall-pack \(packID)")
            statusLine = "Removed tool pack \(packID)"
        } catch {
            runLines = ["Prompt: /uninstall-pack \(packID)", "", "[local] Tool packs", "Failed to remove tool pack: \(error.localizedDescription)"]
            runFinished = true
            statusLine = "Tool pack removal failed"
            promptText = ""
            inputMode = .prompt
            focus = .transcript
        }
    }

    private func startRun(prompt: String) {
        refreshSessionRuntime()
        if let providerStartupIssue, providerStartupIssue.provider == sessionProvider {
            runLines = [
                "Prompt: \(prompt)",
                "",
                "[error] \(Self.providerAttentionMessage(startupIssue: providerStartupIssue, snapshot: providerStatus, provider: sessionProvider))",
                Self.recoveryHint(for: providerStartupIssue, provider: sessionProvider)
            ]
            runFinished = true
            runStartedAt = nil
            statusLine = "Run blocked"
            render()
            return
        }

        queueRetryTask?.cancel()
        queueRetryTask = nil
        runTask?.cancel()
        let executionControl = ExecutionControl()
        runExecutionControl = executionControl
        let intent = ConnectorMessageIntentClassifier.classify(prompt)
        let requestedMode: RunRequest.Mode = intent == .directChat ? .directChat : .agent
        activeRunMode = requestedMode
        runLines = [
            "Prompt: \(prompt)",
            ""
        ]
        transcriptScrollOffset = 0
        runFinished = false
        runStartedAt = Date()
        workingFrameIndex = 0
        currentRunPhase = nil
        currentRunActivity = "Checking model guardrails"
        currentExplorationTargets = []
        currentPendingExplorationTargets = []
        currentRejectedExplorationTargets = []
        currentChangedFiles = []
        currentPlannedFiles = []
        currentPatchObjectives = []
        promptText = ""
        inputMode = .prompt
        showSettings = false
        showHelp = false
        showHistory = false
        focus = .input
        statusLine = "Checking model guardrails"
        if let activeQueuedPrompt {
            runLines.append("[queue] Starting prompt #\(activeQueuedPrompt.id) (\(promptQueue.count) queued behind it)")
        }
        startWorkingIndicator()
        let queuedPrompt = activeQueuedPrompt
        let requestedThreadID = activeThreadID
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
                    threadID: requestedThreadID,
                    mode: requestedMode,
                    executionControl: executionControl
                ))
                for await event in stream {
                    await MainActor.run {
                        self.append(event: event)
                    }
                }
                await MainActor.run {
                    self.activeQueuedPrompt = nil
                    self.runTask = nil
                    self.runExecutionControl = nil
                    self.finishRun()
                    self.processPromptQueueIfPossible()
                    self.restorePromptEntryIfIdle()
                }
            } catch {
                await MainActor.run {
                    self.runTask = nil
                    self.runExecutionControl = nil
                    self.stopWorkingIndicator()
                    self.activeRunMode = nil
                    if let queuedPrompt, PromptFailureRouting.shouldRetry(message: error.localizedDescription) {
                        let retriedPrompt = queuedPrompt.incrementingAttemptCount()
                        self.promptQueue.requeueAtFront(retriedPrompt)
                        self.activeQueuedPrompt = nil
                        self.runLines.append("[queue] Prompt #\(retriedPrompt.id) is waiting to retry: \(error.localizedDescription)")
                        self.runFinished = true
                        self.runStartedAt = nil
                        self.statusLine = "Prompt queue waiting for provider"
                        self.schedulePromptQueueRetry()
                        self.render()
                        return
                    }
                    self.activeQueuedPrompt = nil
                    self.runLines.append("[error] \(error.localizedDescription)")
                    self.runFinished = true
                    self.runStartedAt = nil
                    self.statusLine = "Run blocked"
                    self.processPromptQueueIfPossible()
                    self.restorePromptEntryIfIdle()
                    self.render()
                }
            }
        }
    }

    private func append(event: RuntimeEvent) {
        let shouldFollowTail = isTranscriptNearBottom()
        updateLiveRunState(from: event.payload)
        refreshActiveChatMessagesIfNeeded(for: event.payload)
        runLines.append(contentsOf: renderLines(for: event.payload))
        if shouldFollowTail {
            transcriptScrollOffset = 0
        }

        render()
    }

    private func refreshActiveChatMessagesIfNeeded(for payload: RuntimeEventPayload) {
        switch payload {
        case .messageAppended, .finalAnswer:
            loadActiveChatMessages()
        default:
            break
        }
    }

    private func finishRun() {
        stopWorkingIndicator()
        runExecutionControl = nil
        activeRunMode = nil
        runFinished = true
        runStartedAt = nil
        currentRunActivity = nil
        loadActiveChatMessages()
        loadHistory()
        refreshTokenEconomicsSnapshot(runID: activeRunID)
        if statusLine == "Running" {
            statusLine = "Run finished"
        } else if !promptQueue.isEmpty {
            statusLine = "Queued prompts remaining: \(promptQueue.count)"
            runLines.append("[queue] \(promptQueue.count) queued prompt(s) still waiting")
        }
        render()
    }

    private func restorePromptEntryIfIdle() {
        guard runFinished, runTask == nil, activeQueuedPrompt == nil, pendingApproval == nil, promptQueue.isEmpty else { return }
        guard !showOnboarding else { return }
        guard !showSettings, !showHelp, !showHistory, !showCommands, !showWorkspaces else { return }
        inputMode = .prompt
        focus = .input
        if promptText.isEmpty {
            statusLine = "Type your next prompt"
        }
    }

    private func updateLiveRunState(from payload: RuntimeEventPayload) {
        switch payload {
        case .runStarted(_, let runID):
            activeRunID = runID
            refreshTokenEconomicsSnapshot(runID: runID)
            currentRunPhase = nil
            currentExplorationTargets = []
            currentPendingExplorationTargets = []
            currentRejectedExplorationTargets = []
            currentChangedFiles = []
            currentPlannedFiles = []
            currentPatchObjectives = []
            currentRunTodos = []
        case .workflowPhaseChanged(_, let phase, _):
            currentRunPhase = phase
            currentRunActivity = friendlyActivityTitle(for: phase)
        case .todoListUpdated(_, let items):
            currentRunTodos = items
        case .explorationPlanUpdated(_, let targets, let pendingTargets, let rejectedTargets, _):
            currentExplorationTargets = targets
            currentPendingExplorationTargets = pendingTargets
            currentRejectedExplorationTargets = rejectedTargets
        case .contextPrepared(let runID, _, _, _, _, _):
            activeRunID = runID
            refreshTokenEconomicsSnapshot(runID: runID)
        case .changedFilesTracked(_, let paths):
            for path in paths where !currentChangedFiles.contains(path) {
                currentChangedFiles.append(path)
            }
        case .patchPlanUpdated(_, let paths, let objectives):
            currentPlannedFiles = paths
            currentPatchObjectives = objectives
        case .runFinished(let runID, _):
            activeRunID = runID
            refreshTokenEconomicsSnapshot(runID: runID)
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
        case .runStarted(let threadID, let runID):
            activeThreadID = threadID
            loadActiveChatMessages()
            return ["[run] Started run \(runID.uuidString)"]
        case .runStateChanged(_, let state, let reason):
            switch state {
            case .pending, .running:
                return []
            case .completed:
                return ["[run] Agent completed the run"]
            case .failed:
                return ["[error] Run failed\(reason.map { ": \($0)" } ?? "")"]
            case .interrupted:
                return ["[run] Run interrupted\(reason.map { ": \($0)" } ?? "")"]
            case .cancelled:
                return ["[run] Run cancelled\(reason.map { ": \($0)" } ?? "")"]
            }
        case .workflowPhaseChanged(_, let phase, let title):
            return ["[agent] \(friendlyPhaseTitle(phase: phase, title: title))"]
        case .contextPrepared(_, let retainedMessages, let droppedMessages, let clippedMessages, let estimatedTokens, let estimatedContextWindow):
            var details = ["using \(retainedMessages) message\(retainedMessages == 1 ? "" : "s")", "~\(estimatedTokens) tokens"]
            if droppedMessages > 0 {
                details.append("dropped \(droppedMessages)")
            }
            if clippedMessages > 0 {
                details.append("clipped \(clippedMessages)")
            }
            details.append("window \(estimatedContextWindow)")
            return ["[context] Prepared context: " + details.joined(separator: " • ")]
        case .contextCompacted(_, let droppedMessages, let summary):
            var lines = ["[context] Compacted \(droppedMessages) earlier message\(droppedMessages == 1 ? "" : "s")"]
            if showToolDetails {
                lines.append(contentsOf: summary.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
            }
            return lines
        case .taskPlanCreated(_, let steps):
            var lines = ["[plan] Plan created with \(steps.count) step\(steps.count == 1 ? "" : "s")"]
            lines.append(contentsOf: steps.enumerated().map { "[plan] \($0.offset + 1). \($0.element)" })
            return lines
        case .todoListUpdated(_, let items):
            let completed = items.filter { $0.status == .completed }.count
            let skipped = items.filter { $0.status == .skipped }.count
            let active = items.first { $0.status == .inProgress }
            var details = ["\(completed)/\(items.count) done"]
            if skipped > 0 {
                details.append("\(skipped) skipped")
            }
            if let active {
                details.append("now \(active.index). \(active.title)")
            }
            return ["[todo] " + details.joined(separator: " • ")]
        case .taskStepStarted(_, let index, let total, let title):
            return ["[plan] Step \(index) of \(total): \(title)"]
        case .taskStepFinished(_, let index, let total, let title, let outcome):
            return ["[plan] Step \(index) of \(total) \(friendlyOutcome(outcome)): \(title)"]
        case .explorationPlanUpdated(_, let targets, let pendingTargets, let rejectedTargets, let suggestedQueries):
            var lines: [String] = []
            if !targets.isEmpty {
                lines.append("[explore] Focus: " + targets.joined(separator: ", "))
            }
            if !pendingTargets.isEmpty {
                lines.append("[explore] Next: " + pendingTargets.joined(separator: ", "))
            }
            if !rejectedTargets.isEmpty {
                lines.append("[explore] Deprioritized: " + rejectedTargets.joined(separator: ", "))
            }
            if !suggestedQueries.isEmpty {
                lines.append("[explore] Queries: " + suggestedQueries.joined(separator: ", "))
            }
            return lines
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
            return ["[change] Tracking changes in " + paths.joined(separator: ", ")]
        case .patchPlanUpdated(_, let paths, let objectives):
            var lines = ["[plan] " + (paths.isEmpty ? "Preparing a small change set" : "Planned files: " + paths.joined(separator: ", "))]
            if !objectives.isEmpty {
                lines.append("[plan] Goals: " + objectives.joined(separator: " | "))
            }
            return lines
        case .status(_, let message):
            currentRunActivity = friendlyStatusActivity(message)
            return summarizeStatusMessage(message)
        case .messageAppended(_, _, let role):
            switch role {
            case .user:
                return []
            case .assistant:
                return ["[agent] Drafted a response"]
            case .tool:
                return []
            case .system:
                return ["[agent] Updated internal working notes"]
            }
        case .approvalRequested(_, let toolName, let summary, let reason, let risk):
            return ["[approval] \(summary) for \(toolName) (\(risk.rawValue))", reason]
        case .approvalResolved(_, let toolName, let allowed, let reason):
            return ["[approval] \(toolName) \(allowed ? "approved" : "denied"): \(reason)"]
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
            return ["[\(success ? "done" : "error")] \(normalizedSummary)"]
        case .finalAnswer(_, _, let text):
            let normalizedText = normalizeStoredTranscriptText(text)
            if let structured = formattedStructuredLines(from: normalizedText) {
                return ["", "Assistant:"] + structured
            }
            return ["", "Assistant:"] + normalizedText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        case .error(_, let message):
            return ["[error] \(normalizeStoredTranscriptText(message))"]
        case .runFinished(_, let state):
            return ["[run] Finished with state: \(state.rawValue)"]
        }
    }

    private func friendlyPhaseTitle(phase: String, title: String) -> String {
        switch phase.lowercased() {
        case "exploration":
            return "Inspecting the workspace — \(title)"
        case "mutation":
            return "Making changes — \(title)"
        case "validation":
            return "Validating the result — \(title)"
        default:
            return "\(title)"
        }
    }

    private func friendlyActivityTitle(for phase: String) -> String {
        switch phase.lowercased() {
        case "exploration":
            return "Inspecting workspace"
        case "mutation":
            return "Making changes"
        case "validation":
            return "Validating result"
        default:
            return "Working on \(phase)"
        }
    }

    private func friendlyStatusActivity(_ message: String) -> String {
        let lowered = message.lowercased()
        if lowered.contains("thinking about the reply") {
            return "Thinking about the reply"
        }
        if lowered.contains("thinking about the next action") || lowered.contains("thinking about the next step") {
            return "Thinking about the next step"
        }
        if lowered.contains("subagent") {
            return "Waiting on subagent"
        }
        if lowered.contains("tool") {
            return "Running tool"
        }
        return message
    }

    private func friendlyOutcome(_ outcome: String) -> String {
        switch outcome.lowercased() {
        case "completed":
            return "completed"
        case "skipped":
            return "skipped"
        case "failed":
            return "failed"
        default:
            return outcome
        }
    }

    private func summarizeStatusMessage(_ message: String) -> [String] {
        if let iteration = parseIterationNumber(from: message),
           message.localizedCaseInsensitiveContains("thinking about the next action") {
            return ["[thinking] Thinking about the next step (iteration \(iteration))"]
        }

        if message.localizedCaseInsensitiveContains("thinking about the reply") {
            return ["[thinking] Thinking about the reply"]
        }

        if let iteration = parseIterationNumber(from: message),
           message.localizedCaseInsensitiveContains("subagent thinking") {
            return ["[thinking] Subagent reasoning on the current step (iteration \(iteration))"]
        }

        if message.localizedCaseInsensitiveContains("reasoning summary:") {
            let summary = message.replacingOccurrences(of: "Reasoning summary:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            return ["[reasoning] \(summary)"]
        }

        if let iteration = parseIterationNumber(from: message),
           message.localizedCaseInsensitiveContains("requesting next model action") {
            return ["[agent] Thinking about the next step (iteration \(iteration))"]
        }

        if let remainder = message.split(separator: ":", maxSplits: 1).dropFirst().first,
           message.hasPrefix("Exploration plan:") {
            return ["[agent] Exploration guidance: \(remainder.trimmingCharacters(in: .whitespaces))"]
        }

        if message.hasPrefix("Launching ") && message.contains("subagents") {
            return ["[agent] \(message)"]
        }

        if message.hasPrefix("Automatic validation:") {
            return ["[agent] \(message)"]
        }

        if message.localizedCaseInsensitiveContains("validation gate blocked") {
            return ["[agent] Needs stronger verification before finishing"]
        }

        if message.localizedCaseInsensitiveContains("repeated identical read-only tool call") {
            return ["[agent] Reused a previous read result instead of repeating the same tool call"]
        }

        if message.localizedCaseInsensitiveContains("repeated unproductive retries") {
            return ["[agent] Stopped repeated retries and is moving on with a recoverable summary"]
        }

        if message.localizedCaseInsensitiveContains("no longer making useful progress") {
            return ["[agent] Tool activity stopped making progress, so the step is being wrapped up safely"]
        }

        if message.localizedCaseInsensitiveContains("inspect-before-mutate policy blocked") {
            return ["[agent] Write action blocked until relevant files are inspected first"]
        }

        if message.localizedCaseInsensitiveContains("repairing malformed tool request") {
            return ["[agent] Correcting a malformed tool request and retrying"]
        }

        if message.localizedCaseInsensitiveContains("invalid tool action") {
            return ["[agent] The model requested an invalid tool call and is being asked to correct it"]
        }

        return ["[agent] \(message)"]
    }

    private func parseIterationNumber(from message: String) -> Int? {
        guard let range = message.range(of: #"Iteration\s+(\d+)"#, options: .regularExpression) else {
            return nil
        }
        let match = String(message[range])
        return Int(match.replacingOccurrences(of: "Iteration", with: "").trimmingCharacters(in: .whitespaces))
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
        let purpose = "\(TerminalUIStyle.faint)local agent for workspace tasks: chat, inspect files, run shell, and keep threads\(TerminalUIStyle.reset)"

        let provider = "\(TerminalUIStyle.faint)provider\(TerminalUIStyle.reset) \(TerminalUIStyle.blue)\(sessionProvider)\(TerminalUIStyle.reset)"
        let model = "\(TerminalUIStyle.faint)model\(TerminalUIStyle.reset) \(TerminalUIStyle.ink)\(sessionModel)\(TerminalUIStyle.reset)"
        let version = "\(TerminalUIStyle.faint)ver\(TerminalUIStyle.reset) \(TerminalUIStyle.ink)\(AppBuildInfo.current.displayLabel)\(TerminalUIStyle.reset)"
        let sandbox = "\(TerminalUIStyle.faint)sandbox\(TerminalUIStyle.reset) \(TerminalUIStyle.cyan)\(sessionUserConfig.sandbox.mode.rawValue)\(TerminalUIStyle.reset)"
        let usage = "\(TerminalUIStyle.faint)tok~\(TerminalUIStyle.reset) \(TerminalUIStyle.ink)\(formattedEstimatedTokens)\(TerminalUIStyle.reset)"
        let context = "\(TerminalUIStyle.faint)ctx~\(TerminalUIStyle.reset) \(TerminalUIStyle.ink)\(formattedContextUsage)\(TerminalUIStyle.reset)"
        let economicsLabel = tokenEconomicsMode == .savings ? "saved" : "used"
        let economicsColor = tokenEconomicsMode == .savings ? TerminalUIStyle.green : TerminalUIStyle.amber
        let todayValue = formattedTokenMetric(tokenUsageSnapshot?.today.usedTokenCount)
        let sessionValue = formattedTokenMetric(tokenUsageSnapshot?.session.usedTokenCount)
        let totalValue = formattedTokenMetric(tokenUsageSnapshot?.total.usedTokenCount)
        let moneyValue = tokenEconomicsMode == .savings
            ? formattedSavedMoney(tokenUsageSnapshot?.total.usedTokenCount)
            : formattedUsedMoney(tokenUsageSnapshot?.total.usedTokenCount)
        let savedToday = "\(TerminalUIStyle.faint)today \(economicsLabel)\(TerminalUIStyle.reset) \(economicsColor)\(todayValue)\(TerminalUIStyle.reset)"
        let savedSession = "\(TerminalUIStyle.faint)session \(economicsLabel)\(TerminalUIStyle.reset) \(economicsColor)\(sessionValue)\(TerminalUIStyle.reset)"
        let savedTotal = "\(TerminalUIStyle.faint)total \(economicsLabel)\(TerminalUIStyle.reset) \(economicsColor)\(totalValue)\(TerminalUIStyle.reset)"
        let savedMoney = "\(TerminalUIStyle.faint)\(economicsLabel) money\(TerminalUIStyle.reset) \(economicsColor)\(moneyValue)\(TerminalUIStyle.reset)"
        let status = "\(statusColor)\(displayStatusLine)\(TerminalUIStyle.reset)"
        let right = "\(version)  \(TerminalUIStyle.faint)•\(TerminalUIStyle.reset)  \(provider)  \(TerminalUIStyle.faint)•\(TerminalUIStyle.reset)  \(model)  \(TerminalUIStyle.faint)•\(TerminalUIStyle.reset)  \(sandbox)  \(TerminalUIStyle.faint)•\(TerminalUIStyle.reset)  \(usage)  \(TerminalUIStyle.faint)•\(TerminalUIStyle.reset)  \(context)  \(TerminalUIStyle.faint)•\(TerminalUIStyle.reset)  \(savedToday)  \(TerminalUIStyle.faint)•\(TerminalUIStyle.reset)  \(savedSession)  \(TerminalUIStyle.faint)•\(TerminalUIStyle.reset)  \(savedTotal)  \(TerminalUIStyle.faint)•\(TerminalUIStyle.reset)  \(savedMoney)  \(TerminalUIStyle.faint)•\(TerminalUIStyle.reset)  \(status)"

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
        if phaseLabel.lowercased() == "exploration", !currentPendingExplorationTargets.isEmpty || !currentExplorationTargets.isEmpty {
            let previewSource = currentPendingExplorationTargets.isEmpty ? currentExplorationTargets : currentPendingExplorationTargets
            let preview = previewSource.prefix(3).joined(separator: ", ")
            let suffix = previewSource.count > 3 ? " +\(previewSource.count - 3)" : ""
            rightSummary = "\(TerminalUIStyle.faint)explore\(TerminalUIStyle.reset) \(TerminalUIStyle.blue)\(preview)\(suffix)\(TerminalUIStyle.reset)"
        } else if !currentPlannedFiles.isEmpty {
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

        if showOnboarding, pendingApproval == nil {
            return panel(
                title: "First-Run Setup",
                lines: renderOnboardingWizardLines(width: width - 4, maxBodyHeight: bodyHeight),
                width: width,
                maxBodyHeight: bodyHeight,
                isFocused: isRightPanelFocused
            )
        }

        let gap = 1
        let leftWidth = max(min(width / 3, 40), 30)
        let availableRightWidth = max(width - leftWidth - gap, 38)
        let terminalWidth = showTerminalPane ? max(min(availableRightWidth / 3, 48), 32) : 0
        let rightWidth = showTerminalPane ? max(availableRightWidth - terminalWidth - gap, 38) : availableRightWidth

        let leftPanel = panel(
            title: "Launcher",
            lines: renderHomeLines(width: leftWidth - 4),
            width: leftWidth,
            maxBodyHeight: bodyHeight,
            isFocused: focus == .launcher
        )

        let rightTitle: String
        let rightLines: [String]
        if let pendingApproval {
            rightTitle = "Approval Required"
            rightLines = renderApprovalLines(request: pendingApproval.request, width: rightWidth - 4)
        } else if showOnboarding {
            rightTitle = "First-Run Setup"
            rightLines = renderOnboardingWizardLines(width: rightWidth - 4, maxBodyHeight: bodyHeight)
        } else if showWorkspaces {
            rightTitle = "Workspaces"
            rightLines = renderWorkspaceLines(width: rightWidth - 4)
        } else if showHistory {
            rightTitle = "Threads"
            rightLines = renderHistoryLines(width: rightWidth - 4)
        } else if showSettings {
            rightTitle = "Assistant Setup"
            rightLines = renderSettingsLines(width: rightWidth - 4, maxBodyHeight: bodyHeight)
        } else if showCommands {
            rightTitle = "Commands"
            rightLines = renderScrollableStaticLines(
                renderCommandCatalogLines(width: rightWidth - 4),
                width: rightWidth - 4,
                maxBodyHeight: bodyHeight,
                emptyState: "No command catalog entries."
            )
        } else if showHelp {
            rightTitle = "Controls"
            rightLines = renderScrollableStaticLines(
                renderHelpLines(width: rightWidth - 4),
                width: rightWidth - 4,
                maxBodyHeight: bodyHeight,
                emptyState: "No help entries."
            )
        } else if isChatConversationVisible {
            rightTitle = "Chat"
            rightLines = renderChatConversationLines(width: rightWidth - 4, maxBodyHeight: bodyHeight)
        } else if isComposeTranscriptVisible {
            rightTitle = "New Chat"
            rightLines = renderComposeLines(width: rightWidth - 4, maxBodyHeight: bodyHeight)
        } else {
            rightTitle = runFinished ? "Run Transcript" : "Live Run"
            rightLines = renderRunLines(width: rightWidth - 4, maxBodyHeight: bodyHeight)
        }

        let rightPanel = panel(
            title: rightTitle,
            lines: rightLines,
            width: rightWidth,
            maxBodyHeight: bodyHeight,
            isFocused: isRightPanelFocused
        )

        if showTerminalPane {
            let terminalPanel = panel(
                title: "Terminal",
                lines: renderTerminalLines(width: terminalWidth - 4, maxBodyHeight: bodyHeight),
                width: terminalWidth,
                maxBodyHeight: bodyHeight,
                isFocused: focus == .terminal
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

        if showOnboarding {
            lines.append("\(TerminalUIStyle.amber)Setup is open\(TerminalUIStyle.reset)")
            lines.append("\(TerminalUIStyle.slate)Answer each step or press s to skip. Esc exits setup.\(TerminalUIStyle.reset)")
            lines.append("")
        }

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
        if let progressLine = transcriptProgressLine(width: width) {
            output.append(progressLine)
            output.append("")
        }
        let todoLines = renderRunTodoLines(width: width)
        if !todoLines.isEmpty {
            output.append(contentsOf: todoLines)
            output.append("")
        }
        output.append(contentsOf: viewport)
        return output
    }

    private func renderComposeLines(width: Int, maxBodyHeight: Int) -> [String] {
        let bodyLimit = max(maxBodyHeight - 3, 1)
        let expanded = composeTranscriptLines(width: width)
        let maxOffset = max(expanded.count - bodyLimit, 0)
        transcriptScrollOffset = min(max(transcriptScrollOffset, 0), maxOffset)
        let endIndex = max(expanded.count - transcriptScrollOffset, 0)
        let startIndex = max(endIndex - bodyLimit, 0)
        let viewport = Array(expanded[startIndex..<endIndex])

        var output = [transcriptHeader(width: width, totalLines: expanded.count, visibleLines: bodyLimit), ""]
        output.append(contentsOf: viewport)
        return output
    }

    private func renderChatConversationLines(width: Int, maxBodyHeight: Int) -> [String] {
        let bodyLimit = max(maxBodyHeight - 3, 1)
        let expanded = chatConversationLines(width: width)
        let maxOffset = max(expanded.count - bodyLimit, 0)
        transcriptScrollOffset = min(max(transcriptScrollOffset, 0), maxOffset)
        let endIndex = max(expanded.count - transcriptScrollOffset, 0)
        let startIndex = max(endIndex - bodyLimit, 0)
        let viewport = Array(expanded[startIndex..<endIndex])

        var output = [transcriptHeader(width: width, totalLines: expanded.count, visibleLines: bodyLimit), ""]
        output.append(contentsOf: viewport)
        return output
    }

    private func renderOnboardingWizardLines(width: Int, maxBodyHeight: Int) -> [String] {
        let allSteps: [OnboardingStep] = [.provider, .apiKey, .model, .telegram, .daemon, .done]
        let stepIndex = allSteps.firstIndex(of: onboardingStep).map { $0 + 1 } ?? allSteps.count
        var lines: [String] = [
            "\(TerminalUIStyle.faint)Step \(min(stepIndex, allSteps.count))/\(allSteps.count) • Enter accepts • s skips • Esc closes setup\(TerminalUIStyle.reset)",
            ""
        ]

        lines.append(contentsOf: wrapText(onboardingTitle, width: width).map { "\(TerminalUIStyle.bold)\(TerminalUIStyle.ink)\($0)\(TerminalUIStyle.reset)" })
        lines.append(contentsOf: wrapText(onboardingBody, width: width).map { "\(TerminalUIStyle.slate)\($0)\(TerminalUIStyle.reset)" })

        lines.append("")
        lines.append("\(TerminalUIStyle.ink)Current setup\(TerminalUIStyle.reset)")
        lines.append("\(TerminalUIStyle.slate)Provider: \(sessionProvider)   Model: \(sessionModel)\(TerminalUIStyle.reset)")
        lines.append("\(TerminalUIStyle.slate)Telegram: \(sessionUserConfig.telegram.enabled ? "enabled" : "disabled")   Daemon: \(daemonStatus?.isRunning == true ? "running" : "stopped")\(TerminalUIStyle.reset)")
        let status = onboardingStatus.isEmpty ? "Choose an option to continue." : onboardingStatus
        lines.append("\(TerminalUIStyle.amber)Status: \(TerminalUIStyle.truncateVisible(status, limit: max(width - 8, 10)))\(TerminalUIStyle.reset)")

        if onboardingStep == .model, !providerStatus.details.isEmpty {
            lines.append("")
            lines.append("\(TerminalUIStyle.ink)Provider status\(TerminalUIStyle.reset)")
            for detail in providerStatus.details.prefix(3) {
                lines.append("\(TerminalUIStyle.slate)\(TerminalUIStyle.truncateVisible(detail, limit: width))\(TerminalUIStyle.reset)")
            }
        }

        lines.append("")
        lines.append("\(TerminalUIStyle.ink)Choices\(TerminalUIStyle.reset)")
        let choices = onboardingChoices
        for (index, choice) in choices.enumerated() {
            let selected = index == onboardingSelection && inputMode != .onboardingText
            let marker = selected ? "\(TerminalUIStyle.selection) \(TerminalUIStyle.reset)" : " "
            let isSkip = choice.title.localizedCaseInsensitiveContains("skip")
            let color = selected ? TerminalUIStyle.cyan : (isSkip ? TerminalUIStyle.faint : TerminalUIStyle.blue)
            let titleStyle = isSkip && !selected ? "" : TerminalUIStyle.bold
            lines.append("\(marker) \(titleStyle)\(color)\(choice.title)\(TerminalUIStyle.reset)")
            lines.append("   \(TerminalUIStyle.slate)\(TerminalUIStyle.truncateVisible(choice.subtitle, limit: max(width - 3, 10)))\(TerminalUIStyle.reset)")
        }

        if inputMode == .onboardingText {
            lines.append("")
            lines.append("\(TerminalUIStyle.amber)Type your answer in the input bar and press Enter. Empty input skips this step.\(TerminalUIStyle.reset)")
        } else if onboardingStep == .model && sessionProvider == "ollama" {
            lines.append("")
            lines.append("\(TerminalUIStyle.faint)Shortcut: press r to refresh local models, or d to download with ollama pull.\(TerminalUIStyle.reset)")
        } else if onboardingStep == .model {
            lines.append("")
            lines.append("\(TerminalUIStyle.faint)Shortcut: press r to refresh the model list.\(TerminalUIStyle.reset)")
        }

        let bodyLimit = max(maxBodyHeight - 3, 1)
        let expanded = lines.flatMap { wrapRunLine($0, width: width) }
        let maxOffset = max(expanded.count - bodyLimit, 0)
        transcriptScrollOffset = min(max(transcriptScrollOffset, 0), maxOffset)
        let endIndex = max(expanded.count - transcriptScrollOffset, 0)
        let startIndex = max(endIndex - bodyLimit, 0)
        let viewport = Array(expanded[startIndex..<endIndex])

        return [transcriptHeader(width: width, totalLines: expanded.count, visibleLines: bodyLimit), ""] + viewport
    }

    private var onboardingTitle: String {
        switch onboardingStep {
        case .provider:
            return "Which provider would you like to use?"
        case .experimentalProvider:
            return "Experimental providers"
        case .apiKey:
            return "Add the API key for \(sessionProvider.capitalized)"
        case .model:
            return "Choose a model"
        case .modelDownload:
            return "Download an Ollama model"
        case .telegram:
            return "Connect Telegram?"
        case .telegramToken:
            return "Add your Telegram bot token"
        case .daemon:
            return "Start the background daemon?"
        case .done:
            return "Setup is complete"
        }
    }

    private var onboardingBody: String {
        switch onboardingStep {
        case .provider:
            return "Choose the model provider Ashex should use for chat and coding runs. Local providers keep work on your Mac. Hosted providers need API keys."
        case .experimentalProvider:
            return "These providers are useful for local experiments, but may need extra services or have rougher model behavior than the main provider list."
        case .apiKey:
            return "Keys are stored in `.ashex/secrets.json`, not in the project config. You can also skip and add one later from Assistant Setup."
        case .model:
            return "Pick a discovered model, enter one manually, or download an Ollama model if you are using Ollama."
        case .modelDownload:
            return "Ashex will run `ollama pull <model>` and select the model after it finishes."
        case .telegram:
            return "Telegram lets you send tasks to Ashex remotely. For privacy and routing, each user should create their own bot with BotFather; a shared bot would mix users behind the same token and is not the safe default."
        case .telegramToken:
            return "Create a Telegram bot by messaging @BotFather, copy the token, and paste it here. Ashex saves the token in local secrets JSON and uses it only for your local daemon."
        case .daemon:
            return "The daemon is needed for background Telegram polling. It reads the Telegram token from environment, config, or local secrets JSON."
        case .done:
            return "You can open Assistant Setup anytime to change provider, model, Telegram, daemon, or safety settings."
        }
    }

    private func renderScrollableStaticLines(_ lines: [String], width: Int, maxBodyHeight: Int, emptyState: String) -> [String] {
        let bodyLimit = max(maxBodyHeight - 3, 1)
        let source = lines.isEmpty ? [emptyState] : lines
        let expanded = source.flatMap { wrapRunLine($0, width: width) }
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
            "\(TerminalUIStyle.slate)Tab\(TerminalUIStyle.reset) Switch between launcher, transcript, threads/settings, and input",
            "\(TerminalUIStyle.slate)Up/Down or j/k\(TerminalUIStyle.reset) Move through launcher items, threads, or scroll the transcript",
            "\(TerminalUIStyle.slate)Page Up/Down or Shift+j/Shift+k\(TerminalUIStyle.reset) Scroll the transcript faster",
            "\(TerminalUIStyle.slate)Home/End or g/G\(TerminalUIStyle.reset) Jump to the oldest output or back to the live tail",
            "\(TerminalUIStyle.slate)t\(TerminalUIStyle.reset) Toggle the side terminal pane",
            "\(TerminalUIStyle.slate)e\(TerminalUIStyle.reset) Expand or collapse tool details in the transcript",
            "\(TerminalUIStyle.slate)x\(TerminalUIStyle.reset) Skip the current planned step and continue",
            "\(TerminalUIStyle.slate)Enter\(TerminalUIStyle.reset) Open launcher item or submit prompt",
            "\(TerminalUIStyle.slate)Esc or Left\(TerminalUIStyle.reset) Back out, cancel a run, or quit",
            "\(TerminalUIStyle.slate)Backspace\(TerminalUIStyle.reset) Delete text in the input bar",
            "",
            "\(TerminalUIStyle.ink)Chat Controls\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.slate)Chat\(TerminalUIStyle.reset) Open the active chat composer and continue the selected thread",
            "\(TerminalUIStyle.slate)Threads\(TerminalUIStyle.reset) Pick a saved thread or choose New Chat to start fresh",
            "",
            "\(TerminalUIStyle.ink)Provider Controls\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.slate)Assistant Setup\(TerminalUIStyle.reset) Configure provider, Telegram, and daemon controls",
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
            "\(TerminalUIStyle.blue)\(TerminalUIStyle.truncateVisible("List installable packs: /toolpacks", limit: width))\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.blue)\(TerminalUIStyle.truncateVisible("Enable a bundled pack: /install-pack swiftpm", limit: width))\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.blue)\(TerminalUIStyle.truncateVisible("Disable a bundled pack: /uninstall-pack python", limit: width))\(TerminalUIStyle.reset)",
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
            "\(TerminalUIStyle.ink)Tool Pack Tools\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.slate)toolpack.scaffold_pack\(TerminalUIStyle.reset) Create a reusable installable tool-pack manifest",
            "\(TerminalUIStyle.slate)Bundled packs\(TerminalUIStyle.reset) swiftpm, ios_xcode, python",
            "\(TerminalUIStyle.slate)Custom pack folders\(TerminalUIStyle.reset) WORKSPACE/toolpacks and ~/.config/ashex/toolpacks",
            "\(TerminalUIStyle.slate)Manifest format\(TerminalUIStyle.reset) JSON with pack metadata, typed operations, approvals, and shell templates",
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

    private func renderSettingsLines(width: Int, maxBodyHeight: Int) -> [String] {
        var lines: [String] = [
            "\(TerminalUIStyle.faint)\(focus == .settings ? "Settings focused" : "Press Tab to focus settings")\(TerminalUIStyle.reset)",
            ""
        ]
        var selectedLineRange: ClosedRange<Int>?

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
            case .reasoningDebug:
                value = sessionUserConfig.debug.reasoningSummaries ? "Enabled (safe summary only)" : "Disabled"
            case .telegramEnabled:
                value = sessionUserConfig.telegram.enabled ? "Enabled" : "Disabled"
            case .telegramToken:
                value = telegramTokenStatusLabel()
            case .telegramAccess:
                value = sessionUserConfig.telegram.accessMode.rawValue
            case .telegramAllowedChats:
                value = sessionUserConfig.telegram.allowedChatIDs.isEmpty
                    ? "No chat IDs configured"
                    : sessionUserConfig.telegram.allowedChatIDs.joined(separator: ", ")
            case .telegramAllowedUsers:
                value = sessionUserConfig.telegram.allowedUserIDs.isEmpty
                    ? "No user IDs configured"
                    : sessionUserConfig.telegram.allowedUserIDs.joined(separator: ", ")
            case .telegramPolicy:
                value = sessionUserConfig.telegram.executionPolicy.rawValue
            case .telegramTest:
                value = "Verify bot token with Telegram getMe"
            case .daemonToggle:
                value = daemonStatus?.isRunning == true ? "Stop the background daemon" : "Start the background daemon"
            case .daemonStatus:
                value = daemonStatusSummary
            case .refresh:
                value = providerStatus.headline
            case .back:
                value = "Return to launcher"
            }

            let entryStart = lines.count
            lines.append("\(marker) \(TerminalUIStyle.bold)\(color)\(action.rawValue)\(TerminalUIStyle.reset)")
            lines.append("   \(TerminalUIStyle.slate)\(TerminalUIStyle.truncateVisible(value, limit: max(width - 3, 10)))\(TerminalUIStyle.reset)")
            if index != SettingsAction.allCases.count - 1 {
                lines.append("")
            }
            let entryEnd = lines.count - 1
            if selected {
                selectedLineRange = entryStart...entryEnd
            }
        }

        lines.append("")
        lines.append("\(TerminalUIStyle.ink)Onboarding\(TerminalUIStyle.reset)")
        lines.append(contentsOf: renderOnboardingChecklist(width: width))

        lines.append("")
        lines.append("\(TerminalUIStyle.ink)Status\(TerminalUIStyle.reset)")
        for detail in providerStatus.details.prefix(4) {
            lines.append("\(TerminalUIStyle.slate)\(TerminalUIStyle.truncateVisible(detail, limit: width))\(TerminalUIStyle.reset)")
        }

        lines.append("")
        lines.append("\(TerminalUIStyle.ink)Daemon\(TerminalUIStyle.reset)")
        for detail in renderDaemonDetailLines(width: width) {
            lines.append(detail)
        }

        if !providerStatus.availableModels.isEmpty {
            lines.append("")
            lines.append("\(TerminalUIStyle.ink)\(showModelPicker ? "Pick an Ollama Model" : "Available Models")\(TerminalUIStyle.reset)")
            let availableModels = showModelPicker ? providerStatus.availableModels : Array(providerStatus.availableModels.prefix(6))
            for (index, model) in availableModels.enumerated() {
                let pickerSelected = showModelPicker && index == modelPickerSelection
                let marker = pickerSelected ? "\(TerminalUIStyle.selection) \(TerminalUIStyle.reset)" : " "
                let color = pickerSelected ? TerminalUIStyle.cyan : TerminalUIStyle.blue
                let line = "\(marker) \(color)\(TerminalUIStyle.truncateVisible(model, limit: max(width - 2, 10)))\(TerminalUIStyle.reset)"
                let lineIndex = lines.count
                lines.append(line)
                if pickerSelected {
                    selectedLineRange = lineIndex...lineIndex
                }
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

        if showModelPicker {
            lines.append("")
            lines.append("\(TerminalUIStyle.amber)Use ↑/↓ to choose an Ollama model and press Enter to apply. Esc closes the picker.\(TerminalUIStyle.reset)")
        } else if inputMode == .model {
            lines.append("")
            lines.append("\(TerminalUIStyle.amber)Model edit mode is active in the input bar below.\(TerminalUIStyle.reset)")
        } else if inputMode == .apiKey {
            lines.append("")
            lines.append("\(TerminalUIStyle.amber)API key edit mode is active in the input bar below.\(TerminalUIStyle.reset)")
        } else if inputMode == .telegramToken {
            lines.append("")
            lines.append("\(TerminalUIStyle.amber)Telegram token edit mode is active in the input bar below.\(TerminalUIStyle.reset)")
        } else if inputMode == .telegramAllowedChats {
            lines.append("")
            lines.append("\(TerminalUIStyle.amber)Telegram allowlist edit mode is active in the input bar below.\(TerminalUIStyle.reset)")
        } else if inputMode == .telegramAllowedUsers {
            lines.append("")
            lines.append("\(TerminalUIStyle.amber)Telegram user allowlist edit mode is active in the input bar below.\(TerminalUIStyle.reset)")
        }

        let bodyLimit = max(maxBodyHeight, 1)
        let maxOffset = max(lines.count - bodyLimit, 0)
        if let selectedLineRange {
            if selectedLineRange.lowerBound < settingsScrollOffset {
                settingsScrollOffset = selectedLineRange.lowerBound
            } else if selectedLineRange.upperBound >= settingsScrollOffset + bodyLimit {
                settingsScrollOffset = selectedLineRange.upperBound - bodyLimit + 1
            }
        }
        settingsScrollOffset = min(max(settingsScrollOffset, 0), maxOffset)
        let endIndex = min(settingsScrollOffset + bodyLimit, lines.count)
        return Array(lines[settingsScrollOffset..<endIndex])
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
            if try secretStore.containsSecret(namespace: "provider.credentials", key: CLIConfiguration.apiKeySettingKey(for: provider)) {
                return "Saved in local secrets JSON"
            }
        } catch {
            return "Lookup failed"
        }

        return "Missing"
    }

    private func telegramTokenStatusLabel() -> String {
        if let envValue = ProcessInfo.processInfo.environment["ASHEX_TELEGRAM_BOT_TOKEN"], !envValue.isEmpty {
            return "Loaded from environment (\(maskSecret(envValue)))"
        }

        if let configToken = sessionUserConfig.telegram.botToken, !configToken.isEmpty {
            return "Saved in config (\(maskSecret(configToken)))"
        }

        do {
            if try secretStore.containsSecret(
                namespace: DaemonCLI.telegramSecretNamespace,
                key: DaemonCLI.telegramSecretKey
            ) {
                return "Saved in local secrets JSON"
            }
        } catch {
            return "Lookup failed"
        }

        return "Missing"
    }

    private var daemonStatusSummary: String {
        if let daemonStatus, daemonStatus.isRunning {
            return "Running (pid \(daemonStatus.pid))"
        }
        return "Stopped"
    }

    private func renderOnboardingChecklist(width: Int) -> [String] {
        let items = onboardingChecklistItems()
        return items.map { item in
            let prefix = item.isDone ? "\(TerminalUIStyle.green)[done]\(TerminalUIStyle.reset)" : "\(TerminalUIStyle.amber)[todo]\(TerminalUIStyle.reset)"
            return "\(prefix) \(TerminalUIStyle.truncateVisible(item.text, limit: max(width - 8, 10)))"
        }
    }

    private func renderDaemonDetailLines(width: Int) -> [String] {
        var lines: [String] = []
        if let daemonStatus, daemonStatus.isRunning {
            lines.append("\(TerminalUIStyle.green)Running with pid \(daemonStatus.pid)\(TerminalUIStyle.reset)")
            lines.append("\(TerminalUIStyle.slate)\(TerminalUIStyle.truncateVisible("Started " + Self.timeString(daemonStatus.startedAt), limit: width))\(TerminalUIStyle.reset)")
            lines.append("\(TerminalUIStyle.slate)\(TerminalUIStyle.truncateVisible("Log: " + daemonStatus.logPath, limit: width))\(TerminalUIStyle.reset)")
        } else {
            lines.append("\(TerminalUIStyle.slate)Daemon is currently stopped.\(TerminalUIStyle.reset)")
            lines.append("\(TerminalUIStyle.slate)Use the Daemon action above after the onboarding checklist is complete.\(TerminalUIStyle.reset)")
        }
        return lines
    }

    private func onboardingChecklistItems() -> [(text: String, isDone: Bool)] {
        let providerReady = queuedPromptBlockedReason() == nil || sessionProvider == "mock"
        let telegramEnabled = sessionUserConfig.telegram.enabled
        let tokenReady = telegramTokenStatusLabel() != "Missing"
        let daemonRunning = daemonStatus?.isRunning == true
        return [
            ("Choose a provider and working model for daemon runs.", providerReady),
            ("Save the Telegram bot token.", tokenReady),
            ("Enable Telegram and choose access and safety modes.", telegramEnabled),
            ("If gating is enabled, save allowed chat IDs and user IDs.", sessionUserConfig.telegram.accessMode == .open || !sessionUserConfig.telegram.allowedChatIDs.isEmpty || !sessionUserConfig.telegram.allowedUserIDs.isEmpty),
            ("Start the daemon and confirm it stays running.", daemonRunning),
        ]
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
            "\(TerminalUIStyle.faint)\(focus == .history ? "Threads focused" : "Press Tab to focus threads")\(TerminalUIStyle.reset)",
            ""
        ]

        lines.append("\(TerminalUIStyle.ink)Chat Actions\(TerminalUIStyle.reset)")
        let newChatSelected = focus == .history && historySelection == 0
        lines.append("\((newChatSelected ? "\(TerminalUIStyle.selection) \(TerminalUIStyle.reset)" : " ")) \(TerminalUIStyle.bold)\((newChatSelected ? TerminalUIStyle.cyan : TerminalUIStyle.ink))New Chat\(TerminalUIStyle.reset)")
        let newChatSubtitle = activeThreadID == nil
            ? "Start a fresh conversation in this workspace"
            : "Clear the active thread and start a fresh conversation"
        lines.append("   \(TerminalUIStyle.slate)\(TerminalUIStyle.truncateVisible(newChatSubtitle, limit: max(width - 3, 10)))\(TerminalUIStyle.reset)")

        if historyThreads.isEmpty {
            lines.append("")
            lines.append("\(TerminalUIStyle.slate)No saved threads yet. Send a message to create your first chat thread.\(TerminalUIStyle.reset)")
            return lines
        }

        lines.append("")
        lines.append("\(TerminalUIStyle.ink)Saved Threads\(TerminalUIStyle.reset)")
        for (offset, thread) in historyThreads.enumerated().prefix(6) {
            let index = offset + 1
            let selected = focus == .history && index == historySelection
            let marker = selected ? "\(TerminalUIStyle.selection) \(TerminalUIStyle.reset)" : " "
            let state = thread.latestRunState?.rawValue ?? "no-runs"
            let isActive = thread.id == activeThreadID
            let title = "Thread \(thread.id.uuidString.prefix(8))\(isActive ? " • active" : "") • \(state) • \(thread.messageCount) msg"
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
            let footer = historySelection == 0
                ? "Press Enter to clear the current thread and start a new chat."
                : "Press Enter to load this thread and continue chatting in it."
            lines.append("\(TerminalUIStyle.faint)\(footer)\(TerminalUIStyle.reset)")
        }

        return lines
    }

    private func renderWorkspaceLines(width: Int) -> [String] {
        var lines: [String] = [
            "\(TerminalUIStyle.faint)\(focus == .workspaces ? "Workspaces focused" : "Press Tab to focus workspaces")\(TerminalUIStyle.reset)",
            ""
        ]

        lines.append("\(TerminalUIStyle.ink)Workspace Actions\(TerminalUIStyle.reset)")
        let addSelected = focus == .workspaces && workspaceSelection == 0
        let addMarker = addSelected ? "\(TerminalUIStyle.selection) \(TerminalUIStyle.reset)" : " "
        let addColor = addSelected ? TerminalUIStyle.cyan : TerminalUIStyle.ink
        lines.append("\(addMarker) \(TerminalUIStyle.bold)\(addColor)Add Workspace\(TerminalUIStyle.reset)")
        lines.append("   \(TerminalUIStyle.slate)\(TerminalUIStyle.truncateVisible("Type or paste a project path and switch the current session there", limit: max(width - 3, 10)))\(TerminalUIStyle.reset)")

        if !recentWorkspaces.isEmpty {
            lines.append("")
            lines.append("\(TerminalUIStyle.ink)Recent Workspaces\(TerminalUIStyle.reset)")
        }

        for (offset, workspace) in recentWorkspaces.enumerated().prefix(WorkspaceSelection.visibleRecentWorkspaceLimit) {
            let index = offset + 1
            let selected = focus == .workspaces && index == workspaceSelection
            let marker = selected ? "\(TerminalUIStyle.selection) \(TerminalUIStyle.reset)" : " "
            let color = selected ? TerminalUIStyle.cyan : TerminalUIStyle.ink
            let pathURL = URL(fileURLWithPath: workspace.path)
            let title = pathURL.lastPathComponent + (workspace.path == sessionWorkspaceRoot.path ? " • current" : "")
            let subtitle = "\(workspace.path) • \(Self.timeString(workspace.lastUsedAt))"
            lines.append("\(marker) \(TerminalUIStyle.bold)\(color)\(TerminalUIStyle.truncateVisible(title, limit: width - 2))\(TerminalUIStyle.reset)")
            lines.append("   \(TerminalUIStyle.slate)\(TerminalUIStyle.truncateVisible(subtitle, limit: max(width - 3, 10)))\(TerminalUIStyle.reset)")
            if offset != min(recentWorkspaces.count, 8) - 1 {
                lines.append("")
            }
        }

        if recentWorkspaces.isEmpty {
            lines.append("")
            lines.append("\(TerminalUIStyle.slate)No recent workspaces yet. Add one manually to start building a list.\(TerminalUIStyle.reset)")
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
        if showOnboarding, inputMode != .onboardingText {
            return []
        }

        let innerWidth = max(width - 4, 20)
        let actualLabelText: String
        switch inputMode {
        case .prompt: actualLabelText = "Chat"
        case .model: actualLabelText = "Model"
        case .apiKey: actualLabelText = "API Key"
        case .telegramToken: actualLabelText = "Telegram"
        case .telegramAllowedChats: actualLabelText = "Chats"
        case .telegramAllowedUsers: actualLabelText = "Users"
        case .workspacePath: actualLabelText = "Workspace"
        case .terminalCommand: actualLabelText = "Terminal"
        case .onboardingText: actualLabelText = "Setup"
        }
        let title = focus == .input ? "\(TerminalUIStyle.cyan)\(actualLabelText)\(TerminalUIStyle.reset)" : "\(TerminalUIStyle.faint)\(actualLabelText)\(TerminalUIStyle.reset)"
        let currentText: String
        switch inputMode {
        case .prompt: currentText = promptText
        case .model: currentText = modelInput
        case .apiKey: currentText = String(repeating: "•", count: apiKeyInput.count)
        case .telegramToken: currentText = String(repeating: "•", count: telegramTokenInput.count)
        case .telegramAllowedChats: currentText = telegramAllowedChatsInput
        case .telegramAllowedUsers: currentText = telegramAllowedUsersInput
        case .workspacePath: currentText = workspacePathInput
        case .terminalCommand: currentText = terminalCommandInput
        case .onboardingText:
            currentText = onboardingStep == .apiKey || onboardingStep == .telegramToken
                ? String(repeating: "•", count: onboardingTextInput.count)
                : onboardingTextInput
        }
        let placeholder = inputMode == .model
            ? "Type a model name, then press Enter to apply…"
            : inputMode == .apiKey
                ? "Paste an API key, then press Enter to save…"
                : inputMode == .telegramToken
                    ? "Paste a Telegram bot token, then press Enter to save…"
                : inputMode == .telegramAllowedChats
                    ? "Type comma-separated Telegram chat IDs, then press Enter to save…"
                : inputMode == .telegramAllowedUsers
                    ? "Type comma-separated Telegram user IDs, then press Enter to save…"
                : inputMode == .workspacePath
                    ? "Type a project directory path, then press Enter to switch…"
                : inputMode == .terminalCommand
                    ? "Type a shell command for the side terminal, then press Enter…"
                : inputMode == .onboardingText
                    ? "Type setup answer, then press Enter…"
                : "Type a message here, then press Enter to send…"
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

    private func panel(title: String, lines: [String], width: Int, maxBodyHeight: Int, isFocused: Bool) -> [String] {
        let innerWidth = max(width - 4, 20)
        let body = Array(lines.prefix(maxBodyHeight))
        let borderColor = isFocused ? TerminalUIStyle.focusBorder : TerminalUIStyle.border
        let titleColor = isFocused ? TerminalUIStyle.focusTitle : TerminalUIStyle.cyan
        let focusMarker = isFocused ? "● " : ""
        var rendered: [String] = []
        rendered.append("\(borderColor)┌─ \(TerminalUIStyle.bold)\(titleColor)\(focusMarker)\(title)\(TerminalUIStyle.reset) \(borderColor)" + String(repeating: "─", count: max(innerWidth - TerminalUIStyle.visibleWidth(of: focusMarker + title) - 3, 0)) + "┐\(TerminalUIStyle.reset)")
        for line in body {
            rendered.append("\(borderColor)│ \(TerminalUIStyle.reset)\(TerminalUIStyle.padVisible(TerminalUIStyle.truncateVisible(line, limit: innerWidth), to: innerWidth))\(borderColor) │\(TerminalUIStyle.reset)")
        }
        if body.count < maxBodyHeight {
            rendered.append(contentsOf: Array(repeating: "\(borderColor)│ \(TerminalUIStyle.reset)\(String(repeating: " ", count: innerWidth))\(borderColor) │\(TerminalUIStyle.reset)", count: maxBodyHeight - body.count))
        }
        rendered.append("\(borderColor)└" + String(repeating: "─", count: innerWidth + 2) + "┘\(TerminalUIStyle.reset)")
        return rendered
    }

    private var isRightPanelFocused: Bool {
        switch focus {
        case .transcript, .settings, .history, .workspaces, .approval:
            return true
        case .launcher, .terminal, .input:
            return false
        }
    }

    private func stylizeRunLine(_ line: String, width: Int) -> String {
        let colored: String
        if line.hasPrefix("[error]") {
            colored = "\(TerminalUIStyle.red)\(line)\(TerminalUIStyle.reset)"
        } else if line.hasPrefix("[plan]") {
            colored = "\(TerminalUIStyle.cyan)\(line)\(TerminalUIStyle.reset)"
        } else if line.hasPrefix("[agent]") {
            colored = "\(TerminalUIStyle.amber)\(line)\(TerminalUIStyle.reset)"
        } else if line.hasPrefix("[thinking]") {
            colored = "\(TerminalUIStyle.amber)\(line)\(TerminalUIStyle.reset)"
        } else if line.hasPrefix("[action]") {
            colored = "\(TerminalUIStyle.violet)\(line)\(TerminalUIStyle.reset)"
        } else if line.hasPrefix("[done]") {
            colored = "\(TerminalUIStyle.green)\(line)\(TerminalUIStyle.reset)"
        } else if line.hasPrefix("[context]") {
            colored = "\(TerminalUIStyle.slate)\(line)\(TerminalUIStyle.reset)"
        } else if line.hasPrefix("[change]") {
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
        } else if line.hasPrefix("[agent]") {
            baseColor = TerminalUIStyle.amber
        } else if line.hasPrefix("[thinking]") {
            baseColor = TerminalUIStyle.amber
        } else if line.hasPrefix("[action]") {
            baseColor = TerminalUIStyle.violet
        } else if line.hasPrefix("[done]") {
            baseColor = TerminalUIStyle.green
        } else if line.hasPrefix("[context]") {
            baseColor = TerminalUIStyle.slate
        } else if line.hasPrefix("[change]") {
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
        if showHistory { return "threads" }
        if showSettings { return "settings" }
        if showCommands { return "commands" }
        if showHelp { return "help" }
        return runFinished ? "chat" : "live run"
    }

    private var focusLabel: String {
        switch focus {
        case .launcher: return "launcher"
        case .workspaces: return "workspaces"
        case .history: return "threads"
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
        let activity = currentRunActivity ?? "Working"
        return "\(frame) \(activity)\(elapsedText.map { " (\($0))" } ?? "")"
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

    private var tokenEconomicsMode: TokenCostPresentationMode {
        TokenSavingsEstimator.costPresentationMode(provider: sessionProvider)
    }

    private func formattedTokenMetric(_ value: Int?) -> String {
        Self.formatTokenCount(max(value ?? 0, 0))
    }

    private func formattedSavedMoney(_ savedTokens: Int?) -> String {
        let dollars = estimatedSavedMoneyUSD(for: max(savedTokens ?? 0, 0))
        return TokenSavingsEstimator.formatUSD(dollars)
    }

    private func formattedUsedMoney(_ usedTokens: Int?) -> String {
        let dollars = estimatedUsedMoneyUSD(for: max(usedTokens ?? 0, 0))
        return TokenSavingsEstimator.formatUSD(dollars)
    }

    private func estimatedSavedMoneyUSD(for savedTokens: Int) -> Double {
        guard savedTokens > 0 else { return 0 }
        return TokenSavingsEstimator.estimatedSavedMoneyUSD(for: savedTokens, provider: sessionProvider, model: sessionModel)
    }

    private func estimatedUsedMoneyUSD(for usedTokens: Int) -> Double {
        guard usedTokens > 0 else { return 0 }
        return TokenSavingsEstimator.estimatedUsageMoneyUSD(for: usedTokens, provider: sessionProvider, model: sessionModel)
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
            return 4_096
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
        let state: String
        if isChatConversationVisible {
            state = "chat"
        } else if isComposeTranscriptVisible {
            state = "draft"
        } else {
            state = runLines.isEmpty ? "empty" : (runFinished ? "idle" : "streaming")
        }
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

    private func transcriptProgressLine(width: Int) -> String? {
        guard !runFinished else { return nil }
        let progress = TerminalUIStyle.truncateVisible(displayStatusLine, limit: width)
        return "\(TerminalUIStyle.amber)\(progress)\(TerminalUIStyle.reset)"
    }

    private func renderRunTodoLines(width: Int) -> [String] {
        guard !currentRunTodos.isEmpty else { return [] }
        var lines = ["\(TerminalUIStyle.ink)Todos\(TerminalUIStyle.reset)"]
        for item in currentRunTodos {
            let marker: String
            switch item.status {
            case .pending:
                marker = "\(TerminalUIStyle.faint)[ ]\(TerminalUIStyle.reset)"
            case .inProgress:
                marker = "\(TerminalUIStyle.amber)[~]\(TerminalUIStyle.reset)"
            case .completed:
                marker = "\(TerminalUIStyle.green)[x]\(TerminalUIStyle.reset)"
            case .skipped:
                marker = "\(TerminalUIStyle.slate)[-]\(TerminalUIStyle.reset)"
            }
            let title = TerminalUIStyle.truncateVisible("\(item.index). \(item.title)", limit: max(width - 5, 10))
            lines.append("\(marker) \(title)")
        }
        return lines
    }

    private func composeTranscriptLines(width: Int) -> [String] {
        let threadLabel = activeThreadID.map { "thread \($0.uuidString.prefix(8))" } ?? "new thread"
        var lines: [String] = [
            "\(TerminalUIStyle.ink)\(activeThreadID == nil ? "Start a new chat" : "Continue chat")\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.slate)Send a normal message for chat, or ask for workspace work and Ashex will switch into agent mode automatically.\(TerminalUIStyle.reset)",
            "",
            "\(TerminalUIStyle.faint)workspace\(TerminalUIStyle.reset) \(TerminalUIStyle.truncateVisible(sessionWorkspaceRoot.path, limit: width))",
            "\(TerminalUIStyle.faint)provider\(TerminalUIStyle.reset) \(sessionProvider)  \(TerminalUIStyle.faint)model\(TerminalUIStyle.reset) \(sessionModel)",
            "\(TerminalUIStyle.faint)active\(TerminalUIStyle.reset) \(threadLabel)",
            ""
        ]

        if promptText.isEmpty {
            lines.append("\(TerminalUIStyle.cyan)You\(TerminalUIStyle.reset)")
            lines.append("\(TerminalUIStyle.faint)Draft is empty. Type below, then press Enter to send it.\(TerminalUIStyle.reset)")
            lines.append("")
            lines.append("\(TerminalUIStyle.ink)Try messages like:\(TerminalUIStyle.reset)")
            lines.append("\(TerminalUIStyle.slate)- How are you?\(TerminalUIStyle.reset)")
            lines.append("\(TerminalUIStyle.slate)- What files are in this project?\(TerminalUIStyle.reset)")
            lines.append("\(TerminalUIStyle.slate)- Review this repository and fix failing tests\(TerminalUIStyle.reset)")
        } else {
            lines.append("\(TerminalUIStyle.cyan)You\(TerminalUIStyle.reset)")
            lines.append(contentsOf: wrapRunLine(promptText, width: width))
            lines.append("")
            let intent = ConnectorMessageIntentClassifier.classify(promptText)
            let modeText = intent == .directChat ? "chat reply" : "agent run"
            lines.append("\(TerminalUIStyle.faint)Press Enter to send this message. Ashex will start a \(modeText) in the active thread.\(TerminalUIStyle.reset)")
        }

        return lines
    }

    private func chatConversationLines(width: Int) -> [String] {
        let threadLabel = activeThreadID.map { "thread \($0.uuidString.prefix(8))" } ?? "thread"
        var lines: [String] = [
            "\(TerminalUIStyle.ink)Active chat\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.slate)Type in the input bar and press Enter to continue this conversation.\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.faint)\(threadLabel) • \(sessionProvider) • \(sessionModel)\(TerminalUIStyle.reset)",
            ""
        ]

        let visibleMessages = activeChatMessages.filter { message in
            message.role == .user || message.role == .assistant
        }

        guard !visibleMessages.isEmpty else {
            lines.append("\(TerminalUIStyle.faint)No visible chat messages yet. Type below to start.\(TerminalUIStyle.reset)")
            return lines
        }

        for message in visibleMessages.suffix(24) {
            let isUser = message.role == .user
            let label = isUser ? "You" : "Ashex"
            let color = isUser ? TerminalUIStyle.cyan : TerminalUIStyle.green
            lines.append("\(TerminalUIStyle.bold)\(color)\(label)\(TerminalUIStyle.reset)")
            let normalized = normalizeStoredTranscriptText(message.content)
            if let structured = formattedStructuredLines(from: normalized) {
                lines.append(contentsOf: structured.flatMap { wrapRunLine($0, width: width) })
            } else {
                lines.append(contentsOf: normalized.split(separator: "\n", omittingEmptySubsequences: false).flatMap {
                    wrapRunLine(String($0), width: width)
                })
            }
            lines.append("")
        }

        if runFinished {
            let visibleErrors = runLines.filter { $0.hasPrefix("[error]") }
            if !visibleErrors.isEmpty {
                lines.append("\(TerminalUIStyle.ink)Last run\(TerminalUIStyle.reset)")
                lines.append(contentsOf: visibleErrors.flatMap { wrapRunLine($0, width: width) })
                lines.append("")
            }
            lines.append("\(TerminalUIStyle.faint)Ready for your next message.\(TerminalUIStyle.reset)")
        } else if !runLines.isEmpty {
            lines.append("\(TerminalUIStyle.ink)Activity\(TerminalUIStyle.reset)")
            lines.append(contentsOf: wrappedRunLines(width: width))
        }
        return lines
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

    private var isComposeTranscriptVisible: Bool {
        guard pendingApproval == nil else { return false }
        guard !showWorkspaces, !showHistory, !showSettings, !showCommands, !showHelp else { return false }
        guard runFinished, runLines.isEmpty, inputMode == .prompt else { return false }
        switch focus {
        case .input, .transcript:
            return true
        default:
            return false
        }
    }

    private var isChatConversationVisible: Bool {
        guard pendingApproval == nil else { return false }
        guard !showWorkspaces, !showHistory, !showSettings, !showCommands, !showHelp else { return false }
        guard inputMode == .prompt, activeThreadID != nil else { return false }
        return !activeChatMessages.isEmpty || !runFinished || activeRunMode != nil
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
                return "[action] Exploring directory \(path)"
            case "read_text_file":
                return "[action] Reading \(path)"
            case "write_text_file":
                return "[action] Writing \(path)"
            case "replace_in_file":
                return "[action] Replacing text in \(path)"
            case "apply_patch":
                return "[action] Applying patch to \(path)"
            case "create_directory":
                return "[action] Creating directory \(path)"
            case "delete_path":
                return "[action] Deleting \(path)"
            case "move_path":
                let sourcePath = arguments["source_path"]?.stringValue ?? path
                let destinationPath = arguments["destination_path"]?.stringValue ?? "."
                return "[action] Moving \(sourcePath) → \(destinationPath)"
            case "copy_path":
                let sourcePath = arguments["source_path"]?.stringValue ?? path
                let destinationPath = arguments["destination_path"]?.stringValue ?? "."
                return "[action] Copying \(sourcePath) → \(destinationPath)"
            case "file_info":
                return "[action] Inspecting \(path)"
            case "find_files":
                let query = arguments["query"]?.stringValue ?? ""
                return "[action] Finding files in \(path) matching \"\(query)\""
            case "search_text":
                let query = arguments["query"]?.stringValue ?? ""
                return "[action] Searching text in \(path) for \"\(query)\""
            default:
                return "[action] Filesystem: \(operation)"
            }
        }

        if toolName == "git" {
            let operation = arguments["operation"]?.stringValue ?? "status"
            switch operation {
            case "status":
                return "[action] Checking git status"
            case "current_branch":
                return "[action] Checking current git branch"
            case "diff_unstaged":
                return "[action] Inspecting unstaged git changes"
            case "diff_staged":
                return "[action] Inspecting staged git changes"
            case "log":
                return "[action] Reading recent git history"
            case "show_commit":
                let commit = arguments["commit"]?.stringValue ?? "HEAD"
                return "[action] Inspecting commit \(commit)"
            default:
                return "[action] Git: \(operation)"
            }
        }

        if toolName == "build" {
            let operation = arguments["operation"]?.stringValue ?? "build"
            switch operation {
            case "swift_build":
                return "[action] Running swift build"
            case "swift_test":
                return "[action] Running swift test"
            case "xcodebuild_list":
                return "[action] Listing Xcode schemes and targets"
            case "xcodebuild_build":
                let scheme = arguments["scheme"]?.stringValue
                return "[action] Running xcodebuild build" + (scheme.map { " for \($0)" } ?? "")
            case "xcodebuild_test":
                let scheme = arguments["scheme"]?.stringValue
                return "[action] Running xcodebuild test" + (scheme.map { " for \($0)" } ?? "")
            default:
                return "[action] Build: \(operation)"
            }
        }

        if toolName == "shell" {
            let command = arguments["command"]?.stringValue ?? "<unknown>"
            return "[action] Running shell command: \(command)"
        }

        return "[action] Starting \(toolName)"
    }

    private func summarizeStructuredCompletion(success: Bool, value: JSONValue) -> String {
        guard case .object(let object) = value else {
            return "[\(success ? "done" : "error")] Tool \(success ? "completed" : "failed")"
        }

        if let operation = object["operation"]?.stringValue {
            switch operation {
            case "list_directory":
                let path = object["path"]?.stringValue ?? "."
                let childCount = (object["children"]?.arrayValue?.count) ?? (object["entries"]?.arrayValue?.count) ?? 0
                return "[done] Explored \(path) (\(childCount) entries)"
            case "write_text_file":
                let path = object["path"]?.stringValue ?? "<unknown>"
                let bytesWritten = object["bytes_written"]?.intValue ?? 0
                return "[done] Wrote \(path) (\(bytesWritten) chars)"
            case "replace_in_file":
                let path = object["path"]?.stringValue ?? "<unknown>"
                return "[done] Updated \(path)"
            case "apply_patch":
                let path = object["path"]?.stringValue ?? "<unknown>"
                let editCount = object["edit_count"]?.intValue ?? object["applied_edits"]?.arrayValue?.count ?? 0
                return "[done] Patched \(path) (\(editCount) edit\(editCount == 1 ? "" : "s"))"
            case "delete_path":
                let path = object["path"]?.stringValue ?? "<unknown>"
                return "[done] Deleted \(path)"
            case "move_path":
                let sourcePath = object["source_path"]?.stringValue ?? "<unknown>"
                let destinationPath = object["destination_path"]?.stringValue ?? "<unknown>"
                return "[done] Moved \(sourcePath) → \(destinationPath)"
            case "copy_path":
                let sourcePath = object["source_path"]?.stringValue ?? "<unknown>"
                let destinationPath = object["destination_path"]?.stringValue ?? "<unknown>"
                return "[done] Copied \(sourcePath) → \(destinationPath)"
            case "file_info":
                let path = object["path"]?.stringValue ?? "<unknown>"
                return "[done] Inspected \(path)"
            case "find_files":
                let path = object["path"]?.stringValue ?? "."
                let count = object["matches"]?.arrayValue?.count ?? 0
                return "[done] Found \(count) matching path\(count == 1 ? "" : "s") in \(path)"
            case "search_text":
                let path = object["path"]?.stringValue ?? "."
                let count = object["matches"]?.arrayValue?.count ?? 0
                return "[done] Found \(count) text match\(count == 1 ? "" : "es") in \(path)"
            case "status", "current_branch", "diff_unstaged", "diff_staged", "log", "show_commit":
                return "[done] Git \(operation) finished"
            default:
                break
            }
        }

        if let command = object["command"]?.stringValue,
           let exitCode = object["exit_code"]?.intValue {
            return "[done] Shell command finished with exit \(exitCode): \(command)"
        }

        return "[\(success ? "done" : "error")] Tool \(success ? "completed" : "failed")"
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
        let index = historySelection - 1
        guard historyThreads.indices.contains(index) else { return nil }
        return historyThreads[index]
    }

    private var selectedWorkspace: RecentWorkspaceRecord? {
        let recentIndex = workspaceSelection - 1
        guard recentWorkspaces.indices.contains(recentIndex) else { return nil }
        return recentWorkspaces[recentIndex]
    }

    private func loadRecentWorkspaces() {
        do {
            recentWorkspaces = try RecentWorkspaceStore.load()
            workspaceSelection = WorkspaceSelection.clamped(workspaceSelection, recentWorkspaceCount: recentWorkspaces.count)
            refreshWorkspacePreview()
        } catch {
            recentWorkspaces = []
            workspacePreviewLines = ["[error] \(error.localizedDescription)"]
        }
    }

    private func refreshWorkspacePreview() {
        if workspaceSelection == 0 {
            workspacePreviewLines = [
                "Add a project root manually.",
                "Press Enter to type or paste a full directory path.",
                "Tip: you can also use /workspace /full/path/from/the/input/bar."
            ]
            return
        }

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
            historySelection = min(historySelection, max(historyThreads.count, 0))
            refreshTokenEconomicsSnapshot(runID: latestPersistedRunID())
            refreshHistoryPreview()
            loadActiveChatMessages()
        } catch {
            historyThreads = []
            historyRuns = [:]
            historyPreviewLines = ["[error] \(error.localizedDescription)"]
            tokenSavingsSnapshot = nil
            tokenUsageSnapshot = nil
        }
    }

    private func loadActiveChatMessages() {
        guard let activeThreadID else {
            activeChatMessages = []
            return
        }

        do {
            activeChatMessages = try historyStore.fetchMessages(threadID: activeThreadID)
        } catch {
            activeChatMessages = []
        }
    }

    private func refreshTokenEconomicsSnapshot(runID: UUID?) {
        let snapshotRunID = runID ?? latestPersistedRunID()
        guard let snapshotRunID else {
            tokenSavingsSnapshot = nil
            tokenUsageSnapshot = nil
            return
        }

        tokenSavingsSnapshot = try? sessionInspector.loadTokenSavings(runID: snapshotRunID)
        tokenUsageSnapshot = try? sessionInspector.loadTokenUsage(runID: snapshotRunID)
    }

    private func latestPersistedRunID() -> UUID? {
        if let activeRunID {
            return activeRunID
        }
        if let activeThreadID {
            if let runID = historyRuns[activeThreadID]?.first?.id {
                return runID
            }
            if let thread = historyThreads.first(where: { $0.id == activeThreadID }) {
                return thread.latestRunID
            }
        }
        for thread in historyThreads {
            if let runID = historyRuns[thread.id]?.first?.id ?? thread.latestRunID {
                return runID
            }
        }
        return nil
    }

    private func persistSessionSettings() {
        do {
            try historyStore.upsertSetting(namespace: "ui.session", key: "default_provider", value: .string(sessionProvider), now: Date())
            try historyStore.upsertSetting(namespace: "ui.session", key: "default_model", value: .string(sessionModel), now: Date())
        } catch {
            statusLine = "Failed to save settings"
        }
    }

    private func persistUserConfig() {
        do {
            try UserConfigStore.write(sessionUserConfig, to: sessionUserConfigFile)
        } catch {
            statusLine = "Failed to save ashex.config.json"
        }
    }

    private func refreshDaemonStatus() {
        let store = DaemonProcessStateStore(storageRoot: sessionStorageRoot)
        daemonStatus = try? store.status()
    }

    private func currentCLIArgumentsForBackgroundTasks() -> [String] {
        [
            "--workspace", sessionWorkspaceRoot.path,
            "--storage", sessionStorageRoot.path,
            "--provider", sessionProvider,
            "--model", sessionModel,
            "--approval-mode", configuration.approvalMode.rawValue,
        ]
    }

    private func startDaemonFromTUI() throws {
        let stateStore = DaemonProcessStateStore(storageRoot: sessionStorageRoot)
        if let status = try stateStore.status(), status.isRunning {
            daemonStatus = status
            statusLine = "Daemon is already running"
            return
        }

        let logURL = stateStore.logFileURL
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: Data())
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()

        let process = Process()
        process.executableURL = try ExecutableLocator.currentExecutableURL()
        process.arguments = ["daemon", "start"] + currentCLIArgumentsForBackgroundTasks()
        process.currentDirectoryURL = sessionWorkspaceRoot
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        try? handle.close()

        guard process.terminationStatus == 0 else {
            throw AshexError.model(DaemonCLI.daemonStartupFailureMessage(
                logURL: logURL,
                fallback: "Daemon failed to start in background."
            ))
        }

        statusLine = "Starting daemon in background"
        Thread.sleep(forTimeInterval: 0.2)
        daemonStatus = try stateStore.status()
        guard daemonStatus?.isRunning == true else {
            throw AshexError.model(DaemonCLI.daemonStartupFailureMessage(
                logURL: logURL,
                fallback: "Daemon did not stay running."
            ))
        }
    }

    private func restartDaemonFromTUI(statusPrefix: String) throws {
        DaemonProcessReaper.terminateExistingDaemons()
        Thread.sleep(forTimeInterval: 0.2)
        daemonStatus = nil
        try startDaemonFromTUI()
        if daemonStatus?.isRunning == true {
            statusLine = "\(statusPrefix): daemon restarted"
        }
    }

    private func stopDaemonFromTUI() throws {
        let stateStore = DaemonProcessStateStore(storageRoot: sessionStorageRoot)
        guard let status = try stateStore.status(), status.isRunning else {
            daemonStatus = nil
            statusLine = "Daemon is already stopped"
            return
        }

        guard kill(status.pid, SIGTERM) == 0 else {
            throw AshexError.shell("Failed to stop daemon pid \(status.pid)")
        }

        statusLine = "Stopping daemon"
        Thread.sleep(forTimeInterval: 0.2)
        daemonStatus = try stateStore.status()
    }

    private func restartDaemonOnAppLaunch() async {
        do {
            statusLine = "Restarting daemon"
            render()
            try restartDaemonFromTUI(statusPrefix: "Startup")
            refreshDaemonStatus()
            render()
        } catch {
            statusLine = "Daemon startup failed: \(error.localizedDescription)"
            refreshDaemonStatus()
            render()
        }
    }

    @discardableResult
    private func toggleDaemonFromSettings() async -> Bool {
        do {
            refreshDaemonStatus()
            if daemonStatus?.isRunning == true {
                try stopDaemonFromTUI()
            } else {
                DaemonProcessReaper.terminateExistingDaemons()
                try startDaemonFromTUI()
            }
            refreshDaemonStatus()
            if daemonStatus?.isRunning == true {
                sessionUserConfig.daemon.enabled = true
                persistUserConfig()
                statusLine = "Daemon is running"
            } else {
                sessionUserConfig.daemon.enabled = false
                persistUserConfig()
                statusLine = "Daemon is stopped"
            }
            render()
            return true
        } catch {
            statusLine = error.localizedDescription
            render()
            return false
        }
    }

    private func runTelegramConnectivityTest() async {
        guard sessionUserConfig.telegram.enabled else {
            statusLine = "Enable Telegram first"
            render()
            return
        }
        guard let token = resolvedTelegramToken(), !token.isEmpty else {
            statusLine = "Telegram token is missing"
            render()
            return
        }

        do {
            let identity = try await URLSessionTelegramBotClient().getMe(token: token)
            statusLine = "Telegram connected as @\(identity.username ?? "<unknown>")"
        } catch {
            statusLine = "Telegram test failed: \(error.localizedDescription)"
        }
        render()
    }

    private func resolvedTelegramToken() -> String? {
        if let envToken = ProcessInfo.processInfo.environment["ASHEX_TELEGRAM_BOT_TOKEN"], !envToken.isEmpty {
            return envToken
        }
        if let configToken = sessionUserConfig.telegram.botToken, !configToken.isEmpty {
            return configToken
        }
        return try? secretStore.readSecret(
            namespace: DaemonCLI.telegramSecretNamespace,
            key: DaemonCLI.telegramSecretKey
        )
    }

    private func refreshHistoryPreview() {
        if historySelection == 0 {
            historyPreviewLines = [
                activeThreadID == nil ? "No active thread selected." : "Current active thread will be cleared.",
                "Press Enter to start a fresh chat from the input bar."
            ]
            tokenSavingsSnapshot = nil
            return
        }

        guard let thread = selectedHistoryThread,
              let runID = historyRuns[thread.id]?.first?.id ?? thread.latestRunID else {
            historyPreviewLines = []
            return
        }

        do {
            guard let snapshotBundle = try sessionInspector.loadRunSnapshot(runID: runID, recentEventLimit: 8) else {
                historyPreviewLines = ["[error] Run not found"]
                tokenSavingsSnapshot = nil
                tokenUsageSnapshot = nil
                return
            }
            tokenSavingsSnapshot = try sessionInspector.loadTokenSavings(runID: runID)
            tokenUsageSnapshot = try sessionInspector.loadTokenUsage(runID: runID)
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
            if let memory, !memory.rejectedExplorationTargets.isEmpty {
                lines.append("[history] deprioritized \(memory.rejectedExplorationTargets.count)")
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
                    lines.append("[saved] run \(Self.formatTokenCount(compactions.reduce(0) { $0 + $1.estimatedSavedTokenCount })) • \(formattedSavedMoney(compactions.reduce(0) { $0 + $1.estimatedSavedTokenCount }))")
                }
            }
            if let usage = tokenUsageSnapshot {
                let label = tokenEconomicsMode == .savings ? "saved" : "used"
                let moneyValue = tokenEconomicsMode == .savings
                    ? formattedSavedMoney(usage.total.usedTokenCount)
                    : formattedUsedMoney(usage.total.usedTokenCount)
                lines.append("[\(label)] today \(Self.formatTokenCount(usage.today.usedTokenCount)) • session \(Self.formatTokenCount(usage.session.usedTokenCount)) • total \(Self.formatTokenCount(usage.total.usedTokenCount)) • \(moneyValue)")
            }
            lines.append(contentsOf: events.flatMap { renderLines(for: $0.payload) })
            historyPreviewLines = Array(lines.suffix(8))
        } catch {
            historyPreviewLines = ["[error] \(error.localizedDescription)"]
            tokenSavingsSnapshot = nil
            tokenUsageSnapshot = nil
        }
    }

    private func openSelectedHistoryRun() {
        if historySelection == 0 {
            activeThreadID = nil
            activeChatMessages = []
            runLines = []
            transcriptScrollOffset = 0
            runFinished = true
            currentRunPhase = nil
            currentExplorationTargets = []
            currentPendingExplorationTargets = []
            currentRejectedExplorationTargets = []
            currentChangedFiles = []
            currentPlannedFiles = []
            currentPatchObjectives = []
            showHistory = false
            focus = .input
            inputMode = .prompt
            statusLine = "New chat ready"
            return
        }

        guard let thread = selectedHistoryThread,
              let runID = historyRuns[thread.id]?.first?.id ?? thread.latestRunID else {
            statusLine = "No stored run to load"
            return
        }

        do {
            guard let snapshotBundle = try sessionInspector.loadRunSnapshot(runID: runID) else {
                statusLine = "Failed to load thread"
                runLines = ["[error] Run not found"]
                tokenSavingsSnapshot = nil
                tokenUsageSnapshot = nil
                return
            }
            tokenSavingsSnapshot = try sessionInspector.loadTokenSavings(runID: runID)
            tokenUsageSnapshot = try sessionInspector.loadTokenUsage(runID: runID)
            let events = snapshotBundle.events
            let steps = snapshotBundle.steps
            let compactions = snapshotBundle.compactions
            let snapshot = snapshotBundle.workspaceSnapshot
            let memory = snapshotBundle.workingMemory
            runLines = ["Chat thread \(thread.id.uuidString.prefix(8))", ""]
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
                if !memory.rejectedExplorationTargets.isEmpty {
                    runLines.append("  deprioritized \(memory.rejectedExplorationTargets.joined(separator: ", "))")
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
                    runLines.append("  - dropped \(compaction.droppedMessageCount), retained \(compaction.retainedMessageCount), tok~ \(compaction.estimatedTokenCount)/\(compaction.estimatedContextWindow), saved~ \(compaction.estimatedSavedTokenCount)")
                    runLines.append(contentsOf: compaction.summary.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + String($0) })
                }
                runLines.append("")
            }
            if let usage = tokenUsageSnapshot {
                let label = tokenEconomicsMode == .savings ? "Saved" : "Used"
                let formatMoney: (Int) -> String = tokenEconomicsMode == .savings
                    ? { self.formattedSavedMoney($0) }
                    : { self.formattedUsedMoney($0) }
                runLines.append("\(label) token estimates:")
                runLines.append("  run \(Self.formatTokenCount(usage.currentRun.usedTokenCount)) • \(formatMoney(usage.currentRun.usedTokenCount))")
                runLines.append("  today \(Self.formatTokenCount(usage.today.usedTokenCount)) • \(formatMoney(usage.today.usedTokenCount))")
                runLines.append("  this session \(Self.formatTokenCount(usage.session.usedTokenCount)) • \(formatMoney(usage.session.usedTokenCount))")
                runLines.append("  total \(Self.formatTokenCount(usage.total.usedTokenCount)) • \(formatMoney(usage.total.usedTokenCount))")
                runLines.append("")
            }
            runLines.append(contentsOf: events.flatMap { renderLines(for: $0.payload) })
            currentRunPhase = memory?.currentPhase
            currentExplorationTargets = memory?.explorationTargets ?? []
            currentPendingExplorationTargets = memory?.pendingExplorationTargets ?? []
            currentRejectedExplorationTargets = memory?.rejectedExplorationTargets ?? []
            currentChangedFiles = memory?.changedPaths ?? []
            currentPlannedFiles = memory?.plannedChangeSet ?? []
            currentPatchObjectives = memory?.patchObjectives ?? []
            activeThreadID = thread.id
            loadActiveChatMessages()
            transcriptScrollOffset = 0
            runFinished = true
            showHistory = false
            focus = .transcript
            statusLine = "Loaded thread \(thread.id.uuidString.prefix(8))"
        } catch {
            statusLine = "Failed to load thread"
            runLines = ["[error] \(error.localizedDescription)"]
            tokenSavingsSnapshot = nil
            tokenUsageSnapshot = nil
        }
    }

    private func openSelectedWorkspace() {
        workspaceSelection = WorkspaceSelection.clamped(workspaceSelection, recentWorkspaceCount: recentWorkspaces.count)
        if workspaceSelection == 0 {
            inputMode = .workspacePath
            workspacePathInput = ""
            focus = .input
            statusLine = "Enter or paste a project directory and press Enter"
            return
        }

        guard let workspace = selectedWorkspace else {
            statusLine = "No workspace selected"
            return
        }

        workspacePathInput = workspace.path
        commitWorkspacePathInput()
        showWorkspaces = false
        focus = .launcher
    }

    private func enqueuePrompt(_ prompt: String) {
        let queuedPrompt = promptQueue.enqueue(prompt)
        promptText = ""
        inputMode = .prompt
        showSettings = false
        showHelp = false
        showHistory = false
        showCommands = false
        focus = .input

        let queuePosition = promptQueue.count
        runLines.append("[queue] Added prompt #\(queuedPrompt.id) at position \(queuePosition)")
        transcriptScrollOffset = 0
        if activeQueuedPrompt == nil && runFinished {
            statusLine = "Prompt queued"
        } else {
            statusLine = "Prompt queued behind \(max(queuePosition - 1, 0)) active request(s)"
        }

        processPromptQueueIfPossible()
    }

    private func processPromptQueueIfPossible() {
        guard runTask == nil, runFinished, pendingApproval == nil, activeQueuedPrompt == nil else { return }
        guard let nextPrompt = promptQueue.first else { return }

        if let blockedReason = queuedPromptBlockedReason() {
            statusLine = "Prompt queue waiting"
            if runLines.isEmpty || runFinished {
                runLines = [
                    "[queue] Waiting to send prompt #\(nextPrompt.id)",
                    blockedReason
                ]
                transcriptScrollOffset = 0
            }
            schedulePromptQueueRetry()
            render()
            return
        }

        _ = promptQueue.dequeue()
        activeQueuedPrompt = nextPrompt
        startRun(prompt: nextPrompt.text)
    }

    private func queuedPromptBlockedReason() -> String? {
        switch sessionProvider {
        case "openai", "anthropic":
            let apiKey = try? configuration.resolvedAPIKey(for: sessionProvider)
            if (apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "\(sessionProvider.capitalized) API key is missing."
            }
        case "ollama":
            if providerStatus.headline == "Ollama connection failed" {
                return providerStatus.details.first ?? "Ollama is unavailable."
            }
            if let assessment = providerStatus.guardrailAssessment, assessment.severity == .blocked {
                return ([assessment.headline] + assessment.details).joined(separator: " ")
            }
        default:
            break
        }

        if let providerStartupIssue, providerStartupIssue.provider == sessionProvider,
           ProviderFailureRouting.isOllamaModelResourceFailure(message: providerStartupIssue.message) {
            return providerStartupIssue.message
        }

        if let providerStartupIssue, providerStartupIssue.provider == sessionProvider,
           !Self.providerStatusAllowsRuntimeRetry(providerStatus, provider: sessionProvider) {
            return providerStartupIssue.message
        }

        return nil
    }

    private func schedulePromptQueueRetry() {
        guard queueRetryTask == nil else { return }
        queueRetryTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await self.refreshProviderStatus()
                await MainActor.run {
                    self.queueRetryTask?.cancel()
                    self.queueRetryTask = nil
                    self.processPromptQueueIfPossible()
                }
            }
        }
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
        return try AgentRuntime(
            modelAdapter: modelAdapter,
            toolRegistry: ToolRegistry(tools: try RuntimeToolFactory.makeTools(
                workspaceURL: sessionWorkspaceRoot,
                persistence: persistence,
                sandbox: sessionUserConfig.sandbox,
                shellExecutionPolicy: shellExecutionPolicy
            )),
            persistence: persistence,
            approvalPolicy: approvalPolicy,
            shellExecutionPolicy: shellExecutionPolicy,
            workspaceSnapshot: WorkspaceSnapshotBuilder.capture(workspaceRoot: sessionWorkspaceRoot),
            reasoningSummaryDebugEnabled: sessionUserConfig.debug.reasoningSummaries
        )
    }

    private func refreshProviderStatus() async {
        let provider = sessionProvider
        let model = sessionModel
        let apiKey = try? configuration.resolvedAPIKey(for: provider)
        let snapshot = await ProviderInspector.inspect(
            provider: provider,
            model: model,
            apiKey: apiKey ?? nil,
            dflashConfig: sessionUserConfig.dflash
        )
        guard provider == sessionProvider, model == sessionModel else {
            return
        }
        providerStatus = snapshot
        if let selectedModel = autoSelectOnboardingOllamaModelIfNeeded(from: snapshot) {
            let updatedSnapshot = await ProviderInspector.inspect(
                provider: sessionProvider,
                model: selectedModel,
                apiKey: apiKey ?? nil,
                dflashConfig: sessionUserConfig.dflash
            )
            guard provider == sessionProvider, selectedModel == sessionModel else {
                return
            }
            providerStatus = updatedSnapshot
        }
        if showModelPicker {
            if sessionProvider != "ollama" || ollamaPickerModels.isEmpty {
                showModelPicker = false
            } else {
                modelPickerSelection = min(max(modelPickerSelection, 0), ollamaPickerModels.count - 1)
            }
        }
        if let providerStartupIssue {
            guard providerStartupIssue.provider == sessionProvider else {
                self.providerStartupIssue = nil
                render()
                return
            }
            if sessionProvider == "ollama",
               ProviderFailureRouting.isOllamaModelResourceFailure(message: providerStartupIssue.message),
               snapshot.headline != "Ollama connection failed",
               snapshot.guardrailAssessment?.severity != .blocked {
                self.providerStartupIssue = nil
                clearProviderAttentionTranscriptIfPresent()
                statusLine = snapshot.headline
                processPromptQueueIfPossible()
                render()
                return
            }
            if Self.providerStatusAllowsRuntimeRetry(snapshot, provider: sessionProvider) {
                refreshSessionRuntime()
                if self.providerStartupIssue == nil {
                    statusLine = snapshot.headline
                    if Self.isProviderAttentionTranscript(runLines) {
                        runLines = []
                        transcriptScrollOffset = 0
                    }
                    processPromptQueueIfPossible()
                    render()
                    return
                }
                mergeDiscoveredModelsIntoProviderAttentionStatus(from: snapshot)
            }
            statusLine = "Provider needs attention"
            let shouldReplaceTranscript = runLines.isEmpty ||
                runLines.first?.hasPrefix("[startup]") == true ||
                Self.isProviderAttentionTranscript(runLines)
            if shouldReplaceTranscript {
                let attentionMessage = Self.providerAttentionMessage(
                    startupIssue: providerStartupIssue,
                    snapshot: snapshot,
                    provider: sessionProvider
                )
                runLines = [
                    "[provider] Provider '\(sessionProvider)' needs attention",
                    attentionMessage,
                    Self.recoveryHint(for: providerStartupIssue, provider: sessionProvider)
                ]
                runFinished = true
                transcriptScrollOffset = 0
            }
            render()
            return
        }
        if showSettings || statusLine == "Ready" {
            statusLine = snapshot.headline
        }
        if Self.providerStatusAllowsRuntimeRetry(snapshot, provider: sessionProvider) {
            clearProviderAttentionTranscriptIfPresent()
        }
        processPromptQueueIfPossible()
        render()
    }

    private func autoSelectOnboardingOllamaModelIfNeeded(from snapshot: ProviderStatusSnapshot) -> String? {
        guard showOnboarding,
              onboardingStep == .model,
              sessionProvider == "ollama",
              snapshot.guardrailAssessment?.headline == "Selected model is not installed" ||
              OllamaModelDisplayOrdering.isDiscouragedChatModel(sessionModel) else {
            return nil
        }

        let installedModels = snapshot.availableModels.compactMap(Self.selectableModelName)
        let currentModelIsInstalled = installedModels.contains {
            $0.localizedCaseInsensitiveCompare(sessionModel) == .orderedSame
        }
        let shouldReplaceCurrentModel = !currentModelIsInstalled ||
            OllamaModelDisplayOrdering.isDiscouragedChatModel(sessionModel)
        guard shouldReplaceCurrentModel,
              let selectedModel = OllamaModelDisplayOrdering.safestInstalledModelName(from: snapshot.availableModels) ?? installedModels.first,
              selectedModel.localizedCaseInsensitiveCompare(sessionModel) != .orderedSame else {
            return nil
        }

        applySafestOnboardingOllamaModel(selectedModel)
        return selectedModel
    }

    private func selectSafestOnboardingOllamaModelIfNeeded() {
        guard showOnboarding,
              onboardingStep == .model,
              sessionProvider == "ollama",
              providerStatus.guardrailAssessment?.headline == "Selected model is not installed" ||
              OllamaModelDisplayOrdering.isDiscouragedChatModel(sessionModel),
              let selectedModel = OllamaModelDisplayOrdering.safestInstalledModelName(from: providerStatus.availableModels) else {
            return
        }

        applySafestOnboardingOllamaModel(selectedModel)
    }

    private func applySafestOnboardingOllamaModel(_ selectedModel: String) {
        sessionModel = selectedModel
        showModelPicker = false
        providerStartupIssue = nil
        refreshSessionRuntime()
        providerStartupIssue = nil
        clearProviderAttentionTranscriptIfPresent()
        persistSessionSettings()
        onboardingStatus = "Selected installed Ollama model \(selectedModel)"
    }

    private func clearProviderAttentionTranscriptIfPresent() {
        guard Self.isProviderAttentionTranscript(runLines) else { return }
        runLines = []
        transcriptScrollOffset = 0
    }

    private func mergeDiscoveredModelsIntoProviderAttentionStatus(from snapshot: ProviderStatusSnapshot) {
        guard !snapshot.availableModels.isEmpty else { return }
        var details = providerStatus.details
        let discoveredSummary = "Discovered \(snapshot.availableModels.count) available model(s) from \(sessionProvider)."
        if !details.contains(discoveredSummary) {
            details.append(discoveredSummary)
        }
        providerStatus = .init(
            headline: providerStatus.headline,
            details: details,
            availableModels: snapshot.availableModels,
            guardrailAssessment: snapshot.guardrailAssessment
        )
    }

    private static func providerStatusAllowsRuntimeRetry(_ snapshot: ProviderStatusSnapshot, provider: String) -> Bool {
        switch provider {
        case "mock":
            return true
        case "openai", "anthropic":
            return !snapshot.headline.localizedCaseInsensitiveContains("missing") &&
                !snapshot.headline.localizedCaseInsensitiveContains("failed")
        case "ollama":
            if snapshot.headline == "Ollama connection failed" { return false }
            return snapshot.guardrailAssessment?.severity != .blocked
        case "dflash":
            return snapshot.headline == "DFlash server looks ready" ||
                snapshot.headline == "DFlash server is reachable"
        default:
            return false
        }
    }

    private static func providerAttentionMessage(
        startupIssue: ProviderStartupIssue,
        snapshot: ProviderStatusSnapshot,
        provider: String
    ) -> String {
        if provider == "ollama",
           let assessment = snapshot.guardrailAssessment,
           assessment.severity == .blocked {
            return ([assessment.headline] + assessment.details).joined(separator: " ")
        }
        if snapshot.headline == "Ollama connection failed" {
            return snapshot.details.first ?? startupIssue.message
        }
        if ProviderFailureRouting.isOllamaModelResourceFailure(message: startupIssue.message) {
            return "Ollama is reachable, but its backend could not load the selected model/context: \(startupIssue.message). This is not Ashex's local memory checker."
        }
        return startupIssue.message
    }

    private func validateRunGuardrails() async throws {
        guard sessionProvider == "ollama" else { return }
        if ProcessInfo.processInfo.environment["ASHEX_ALLOW_LARGE_MODELS"] == "1" { return }

        let snapshot = await ProviderInspector.inspect(
            provider: sessionProvider,
            model: sessionModel,
            dflashConfig: sessionUserConfig.dflash
        )
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
    static let focusBorder = rgb(107, 214, 255)
    static let blue = rgb(116, 167, 255)
    static let cyan = rgb(107, 214, 255)
    static let focusTitle = rgb(156, 232, 255)
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
    static func inspect(
        provider: String,
        model: String,
        apiKey: String? = nil,
        dflashConfig: DFlashConfig = .default
    ) async -> TUIApp.ProviderStatusSnapshot {
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
                let models = try await fetchOllamaModelsWithStartupRetry(baseURL: baseURL)
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
                let displayModels = OllamaModelDisplayOrdering.ordered(models, selectedModel: model).map { model in
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
        case "dflash":
            do {
                try CLIConfiguration.validateDFlashSupport()
                let baseURL = CLIConfiguration.dflashBaseURL(config: dflashConfig)
                let models = try await DFlashModelsClient.fetchModels(baseURL: baseURL)
                let selectedAvailable = models.contains(model)
                return .init(
                    headline: selectedAvailable ? "DFlash server looks ready" : "DFlash server is reachable",
                    details: [
                        "Connected to \(baseURL.absoluteString).",
                        selectedAvailable
                            ? "The selected model is \(model)."
                            : "The current model \(model) was not returned by the DFlash models API."
                    ],
                    availableModels: models.sorted(),
                    guardrailAssessment: nil
                )
            } catch {
                return .init(
                    headline: "DFlash connection failed",
                    details: [
                        error.localizedDescription,
                        "Start `dflash-serve` and refresh status again."
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

    private static func fetchOllamaModelsWithStartupRetry(baseURL: URL) async throws -> [LocalModelDescriptor] {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await OllamaCatalogClient().fetchModels(baseURL: baseURL)
            } catch {
                lastError = error
                guard attempt < 2 else { break }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
        throw lastError ?? AshexError.model("Failed to read Ollama model catalog")
    }
}

enum OllamaModelDisplayOrdering {
    private struct DisplayModelCandidate {
        let name: String
        let sizeBytes: Double?
    }

    static func ordered(_ models: [LocalModelDescriptor], selectedModel: String) -> [LocalModelDescriptor] {
        models.sorted { lhs, rhs in
            let lhsRank = rank(modelName: lhs.name, selectedModel: selectedModel)
            let rhsRank = rank(modelName: rhs.name, selectedModel: selectedModel)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func orderedDisplayNames(_ displayNames: [String], selectedModel: String) -> [String] {
        displayNames.sorted { lhs, rhs in
            let lhsName = selectableName(from: lhs)
            let rhsName = selectableName(from: rhs)
            let lhsRank = rank(modelName: lhsName, selectedModel: selectedModel)
            let rhsRank = rank(modelName: rhsName, selectedModel: selectedModel)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    static func safestInstalledModelName(from displayNames: [String]) -> String? {
        let candidates = displayNames.compactMap(displayModelCandidate(from:))
        let usableCandidates = candidates.filter { !isDiscouragedChatModel($0.name.lowercased()) }
        return (usableCandidates.isEmpty ? candidates : usableCandidates)
            .sorted { lhs, rhs in
                switch (lhs.sizeBytes, rhs.sizeBytes) {
                case let (lhsSize?, rhsSize?) where lhsSize != rhsSize:
                    return lhsSize < rhsSize
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            }
            .first?
            .name
    }

    private static func rank(modelName: String, selectedModel: String) -> Int {
        let normalized = modelName.lowercased()
        if normalized == selectedModel.lowercased(), !isDiscouragedChatModel(normalized) {
            return 0
        }
        if isDiscouragedChatModel(normalized) {
            return 30
        }
        if isPreferredGeneralModel(normalized) {
            return 10
        }
        return 20
    }

    private static func selectableName(from displayName: String) -> String {
        displayName.components(separatedBy: "•").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? displayName
    }

    private static func displayModelCandidate(from displayName: String) -> DisplayModelCandidate? {
        let parts = displayName.components(separatedBy: "•")
        let name = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }

        let sizeBytes = parts.dropFirst().first.flatMap {
            parsedSizeBytes(from: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .init(name: name, sizeBytes: sizeBytes)
    }

    private static func parsedSizeBytes(from sizeText: String) -> Double? {
        let components = sizeText.split(separator: " ")
        guard components.count >= 2,
              let value = Double(components[0].replacingOccurrences(of: ",", with: "")) else {
            return nil
        }

        let unit = components[1].lowercased()
        if unit.hasPrefix("gb") { return value * 1_000_000_000 }
        if unit.hasPrefix("mb") { return value * 1_000_000 }
        if unit.hasPrefix("kb") { return value * 1_000 }
        return value
    }

    private static func isPreferredGeneralModel(_ modelName: String) -> Bool {
        [
            "llama",
            "qwen",
            "gemma",
            "mistral",
            "codellama",
            "deepseek-coder"
        ].contains { modelName.contains($0) }
    }

    static func isDiscouragedChatModel(_ modelName: String) -> Bool {
        [
            "function",
            "embed",
            "embedding",
            "whisper",
            "bge",
            "nomic-embed"
        ].contains { modelName.contains($0) }
    }
}

private enum DFlashModelsClient {
    private struct Envelope: Decodable {
        let data: [Model]
    }

    private struct Model: Decodable {
        let id: String
    }

    static func fetchModels(baseURL: URL, session: URLSession = .shared) async throws -> [String] {
        let requestURL = baseURL.appending(path: "v1/models")
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AshexError.model("DFlash model list did not return an HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AshexError.model("DFlash model list request failed with status \(httpResponse.statusCode)")
        }
        return try JSONDecoder().decode(Envelope.self, from: data).data.map(\.id)
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
