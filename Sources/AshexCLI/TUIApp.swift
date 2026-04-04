import AshexCore
import Darwin
import Foundation

@MainActor
final class TUIApp {
    private struct MenuItem {
        let title: String
        let subtitle: String
        let action: Action
    }

    private enum Action {
        case compose
        case example(String)
        case help
        case quit
    }

    private enum FocusArea {
        case launcher
        case input
        case approval
    }

    private let configuration: CLIConfiguration
    private let runtime: AgentRuntime
    private let terminal = TerminalController()
    private let surface = TerminalSurface()
    private let approvalCoordinator: TUIApprovalCoordinator
    private let menuItems: [MenuItem] = [
        .init(title: "New Prompt", subtitle: "Write your own instruction", action: .compose),
        .init(title: "Example: List Files", subtitle: "Run a quick filesystem task", action: .example("list files")),
        .init(title: "Example: Read README", subtitle: "Read a file through the agent loop", action: .example("read README.md")),
        .init(title: "Example: Shell ls", subtitle: "Run a shell command in the workspace", action: .example("shell: ls -la")),
        .init(title: "Help", subtitle: "Show keyboard shortcuts and behavior", action: .help),
        .init(title: "Quit", subtitle: "Exit Ashex", action: .quit),
    ]

    private var focus: FocusArea = .launcher
    private var selectedIndex = 0
    private var composerText = ""
    private var showHelp = false
    private var statusLine = "Ready"
    private var runLines: [String] = []
    private var runFinished = true
    private var runTask: Task<Void, Never>?
    private var shouldQuit = false
    private var pendingApproval: PendingApproval?

    init(configuration: CLIConfiguration) throws {
        let approvalCoordinator = TUIApprovalCoordinator()
        self.configuration = configuration
        self.approvalCoordinator = approvalCoordinator
        self.runtime = try configuration.makeRuntime(
            approvalPolicy: configuration.approvalMode == .guarded
                ? TUIApprovalPolicy(coordinator: approvalCoordinator)
                : TrustedApprovalPolicy()
        )
        approvalCoordinator.handler = { [weak self] request in
            guard let self else { return .deny("TUI is unavailable") }
            return await self.requestApproval(request)
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
        case .character(let character):
            handleCharacter(character)
        case .space:
            handleCharacter(" ")
        default:
            break
        }
    }

    private func cycleFocus() {
        switch focus {
        case .launcher:
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
        case .input, .approval:
            break
        }
    }

    private func handleDown() {
        switch focus {
        case .launcher:
            moveSelection(1)
        case .input, .approval:
            break
        }
    }

    private func handleEnter() {
        if pendingApproval != nil {
            handleApproval(key: .enter)
            return
        }

        let prompt = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            startRun(prompt: prompt)
            return
        }

        if focus == .launcher {
            activate(menuItems[selectedIndex].action)
        } else if focus == .input {
            statusLine = "Prompt is empty"
        }
    }

    private func handleBackspace() {
        if !composerText.isEmpty {
            composerText.removeLast()
            focus = .input
            statusLine = "Editing prompt"
        }
    }

    private func handleBack() {
        if pendingApproval != nil {
            handleApproval(key: .escape)
            return
        }

        if !composerText.isEmpty && focus == .input {
            composerText = ""
            statusLine = "Cleared prompt"
            return
        }

        if showHelp {
            showHelp = false
            focus = .launcher
            statusLine = "Back to launcher"
            return
        }

        if !runFinished && !runLines.isEmpty {
            runTask?.cancel()
            runTask = nil
            runFinished = true
            runLines.append("[local] Run cancelled from TUI")
            statusLine = "Run cancelled"
            return
        }

        shouldQuit = true
    }

    private func handleCharacter(_ character: Character) {
        composerText.append(character)
        focus = .input
        showHelp = false
        statusLine = "Editing prompt"
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
            focus = .input
            showHelp = false
            statusLine = "Write a prompt below and press Enter"
        case .example(let prompt):
            startRun(prompt: prompt)
        case .help:
            showHelp = true
            focus = .launcher
            statusLine = "Help"
        case .quit:
            shouldQuit = true
        }
    }

    private func startRun(prompt: String) {
        runTask?.cancel()
        runLines = [
            "Prompt: \(prompt)",
            ""
        ]
        runFinished = false
        composerText = ""
        showHelp = false
        focus = .input
        statusLine = "Running"

        let stream = runtime.run(.init(prompt: prompt, maxIterations: configuration.maxIterations))
        runTask = Task { [weak self] in
            for await event in stream {
                await MainActor.run {
                    self?.append(event: event)
                }
            }
            await MainActor.run {
                self?.finishRun()
            }
        }
    }

    private func append(event: RuntimeEvent) {
        switch event.payload {
        case .runStarted(_, let runID):
            runLines.append("[run] started \(runID.uuidString)")
        case .runStateChanged(_, let state, let reason):
            runLines.append("[state] \(state.rawValue)\(reason.map { " - \($0)" } ?? "")")
        case .status(_, let message):
            runLines.append("[status] \(message)")
        case .messageAppended(_, _, let role):
            runLines.append("[message] appended \(role.rawValue)")
        case .approvalRequested(_, let toolName, let summary, let reason, let risk):
            runLines.append("[approval] request \(toolName) \(summary) (\(risk.rawValue)) - \(reason)")
        case .approvalResolved(_, let toolName, let allowed, let reason):
            runLines.append("[approval] \(toolName) \(allowed ? "approved" : "denied") - \(reason)")
        case .toolCallStarted(_, _, let toolName, let arguments):
            runLines.append("[tool] \(toolName) started")
            runLines.append(contentsOf: JSONValue.object(arguments).prettyPrinted.split(separator: "\n").map(String.init))
        case .toolOutput(_, _, let stream, let chunk):
            let prefix = stream == .stderr ? "stderr" : "stdout"
            let lines = chunk.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for line in lines where !line.isEmpty {
                runLines.append("[\(prefix)] \(line)")
            }
        case .toolCallFinished(_, _, let success, let summary):
            runLines.append("[tool] \(success ? "completed" : "failed") \(summary)")
        case .finalAnswer(_, _, let text):
            runLines.append("")
            runLines.append("Final answer:")
            runLines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        case .error(_, let message):
            runLines.append("[error] \(message)")
        case .runFinished(_, let state):
            runLines.append("[run] finished \(state.rawValue)")
        }

        render()
    }

    private func finishRun() {
        runFinished = true
        if statusLine == "Running" {
            statusLine = "Run finished"
        }
        render()
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

        let provider = "\(TerminalUIStyle.faint)provider\(TerminalUIStyle.reset) \(TerminalUIStyle.blue)\(configuration.provider)\(TerminalUIStyle.reset)"
        let model = "\(TerminalUIStyle.faint)model\(TerminalUIStyle.reset) \(TerminalUIStyle.ink)\(configuration.model)\(TerminalUIStyle.reset)"
        let status = "\(statusColor)\(statusLine.uppercased())\(TerminalUIStyle.reset)"
        let right = "\(provider)  \(TerminalUIStyle.faint)•\(TerminalUIStyle.reset)  \(model)  \(TerminalUIStyle.faint)•\(TerminalUIStyle.reset)  \(status)"

        let topLine = join(left: left, right: right, width: innerWidth)
        let workspace = "\(TerminalUIStyle.faint)workspace\(TerminalUIStyle.reset) \(TerminalUIStyle.truncateVisible(configuration.workspaceRoot.path, limit: innerWidth))"

        return [
            TerminalUIStyle.border + "╭" + String(repeating: "─", count: innerWidth + 2) + "╮" + TerminalUIStyle.reset,
            "\(TerminalUIStyle.border)│ \(TerminalUIStyle.reset)\(TerminalUIStyle.padVisible(topLine, to: innerWidth))\(TerminalUIStyle.border) │\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.border)│ \(TerminalUIStyle.reset)\(TerminalUIStyle.padVisible(workspace, to: innerWidth))\(TerminalUIStyle.border) │\(TerminalUIStyle.reset)",
            TerminalUIStyle.border + "╰" + String(repeating: "─", count: innerWidth + 2) + "╯" + TerminalUIStyle.reset
        ]
    }

    private func renderBody(width: Int, height: Int) -> [String] {
        let chromeHeight = 10
        let bodyHeight = max(height - chromeHeight, 10)
        let gap = 1
        let leftWidth = max(min(width / 3, 40), 30)
        let rightWidth = max(width - leftWidth - gap, 38)

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

        return zip(leftPanel, rightPanel).map { left, right in
            left + String(repeating: " ", count: gap) + right
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
        let source = runLines.isEmpty ? ["No run yet. Choose an example or type a prompt below."] : runLines

        var expanded: [String] = []
        for line in source {
            expanded.append(contentsOf: wrapRunLine(line, width: width))
        }

        var output = [transcriptHeader(width: width), ""]
        output.append(contentsOf: Array(expanded.suffix(bodyLimit)))
        return output
    }

    private func renderHelpLines(width: Int) -> [String] {
        [
            "\(TerminalUIStyle.ink)Navigation\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.slate)Tab\(TerminalUIStyle.reset) Switch between launcher and input",
            "\(TerminalUIStyle.slate)Up/Down or j/k\(TerminalUIStyle.reset) Move through launcher items",
            "\(TerminalUIStyle.slate)Enter\(TerminalUIStyle.reset) Open launcher item or submit prompt",
            "\(TerminalUIStyle.slate)Esc or Left\(TerminalUIStyle.reset) Back out, cancel a run, or quit",
            "\(TerminalUIStyle.slate)Backspace\(TerminalUIStyle.reset) Delete text in the input bar",
            "",
            "\(TerminalUIStyle.ink)One-shot commands still work\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.blue)\(TerminalUIStyle.truncateVisible("swift run ashex 'list files'", limit: width))\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.blue)\(TerminalUIStyle.truncateVisible("swift run ashex --approval-mode guarded 'shell: pwd'", limit: width))\(TerminalUIStyle.reset)",
            "",
            "\(TerminalUIStyle.faint)The TUI is a client over the same runtime used by one-shot mode and future app integrations.\(TerminalUIStyle.reset)"
        ]
    }

    private func renderApprovalLines(request: ApprovalRequest, width: Int) -> [String] {
        [
            "\(TerminalUIStyle.amber)Guarded mode requires approval before this tool can run.\(TerminalUIStyle.reset)",
            "",
            "\(TerminalUIStyle.ink)Tool\(TerminalUIStyle.reset): \(TerminalUIStyle.violet)\(request.toolName)\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.ink)Summary\(TerminalUIStyle.reset): \(TerminalUIStyle.truncateVisible(request.summary, limit: max(width - 10, 8)))",
            "\(TerminalUIStyle.ink)Target\(TerminalUIStyle.reset): \(TerminalUIStyle.truncateVisible(request.reason, limit: max(width - 10, 8)))",
            "\(TerminalUIStyle.ink)Risk\(TerminalUIStyle.reset): \(request.risk.rawValue)",
            "",
            "\(TerminalUIStyle.faint)Press y or Enter to approve. Press n, Esc, or Left to deny.\(TerminalUIStyle.reset)"
        ]
    }

    private func renderInputBar(width: Int) -> [String] {
        let innerWidth = max(width - 4, 20)
        let title = focus == .input ? "\(TerminalUIStyle.cyan)Input\(TerminalUIStyle.reset)" : "\(TerminalUIStyle.faint)Input\(TerminalUIStyle.reset)"
        let prompt = composerText.isEmpty
            ? "\(TerminalUIStyle.faint)Type a prompt here, then press Enter to run…\(TerminalUIStyle.reset)"
            : "\(TerminalUIStyle.ink)\(composerText)\(TerminalUIStyle.reset)"
        let line = "\(TerminalUIStyle.blue)›\(TerminalUIStyle.reset) \(prompt)"

        return [
            "\(TerminalUIStyle.border)┌─ \(title) \(TerminalUIStyle.border)" + String(repeating: "─", count: max(innerWidth - 7, 0)) + "┐\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.border)│ \(TerminalUIStyle.reset)\(TerminalUIStyle.padVisible(TerminalUIStyle.truncateVisible(line, limit: innerWidth), to: innerWidth))\(TerminalUIStyle.border) │\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.border)└" + String(repeating: "─", count: innerWidth + 2) + "┘\(TerminalUIStyle.reset)"
        ]
    }

    private func renderFooter(width: Int) -> String {
        let hint = pendingApproval == nil
            ? "\(TerminalUIStyle.faint)tab\(TerminalUIStyle.reset) focus  \(TerminalUIStyle.faint)enter\(TerminalUIStyle.reset) run/open  \(TerminalUIStyle.faint)esc\(TerminalUIStyle.reset) back"
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
        if line.hasPrefix("[error]") {
            baseColor = TerminalUIStyle.red
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
        let limit = max(width, 10)
        if plain.count <= limit {
            return ["\(baseColor)\(plain)\(TerminalUIStyle.reset)"]
        }

        var chunks: [String] = []
        var remainder = plain[...]
        while remainder.count > limit {
            let index = remainder.index(remainder.startIndex, offsetBy: limit)
            chunks.append(String(remainder[..<index]))
            remainder = remainder[index...]
        }
        if !remainder.isEmpty {
            chunks.append(String(remainder))
        }
        return chunks.map { "\(baseColor)\($0)\(TerminalUIStyle.reset)" }
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
        if showHelp { return "help" }
        return runFinished ? "workspace" : "live run"
    }

    private var focusLabel: String {
        switch focus {
        case .launcher: return "launcher"
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

    private func transcriptHeader(width: Int) -> String {
        let state = runLines.isEmpty ? "empty" : (runFinished ? "idle" : "streaming")
        let focusInfo = "\(TerminalUIStyle.faint)stable transcript\(TerminalUIStyle.reset)"
        let left = "\(TerminalUIStyle.faint)state\(TerminalUIStyle.reset) \(state)"
        let right = focusInfo
        return join(left: left, right: right, width: width)
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
                var buffer = [UInt8](repeating: 0, count: 3)

                while !Task.isCancelled {
                    let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                    guard count > 0 else { continue }
                    continuation.yield(Self.parseKey(bytes: Array(buffer.prefix(count))))
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func parseKey(bytes: [UInt8]) -> TerminalKey {
        guard let first = bytes.first else { return .unknown }

        switch first {
        case 9:
            return .tab
        case 13, 10:
            return .enter
        case 27:
            if bytes.count >= 3, bytes[1] == 91 {
                switch bytes[2] {
                case 65: return .up
                case 66: return .down
                case 67: return .right
                case 68: return .left
                default: return .escape
                }
            }
            return .escape
        case 127:
            return .backspace
        case 32:
            return .space
        default:
            if let scalar = UnicodeScalar(Int(first)) {
                return .character(Character(scalar))
            }
            return .unknown
        }
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
