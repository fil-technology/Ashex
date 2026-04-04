import AshexCore
import Darwin
import Foundation

@MainActor
final class TUIApp {
    private enum Screen {
        case home
        case composer
        case run
        case help
    }

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

    private let configuration: CLIConfiguration
    private let runtime: AgentRuntime
    private let terminal = TerminalController()
    private let surface = TerminalSurface()
    private let menuItems: [MenuItem] = [
        .init(title: "New Prompt", subtitle: "Write your own instruction", action: .compose),
        .init(title: "Example: List Files", subtitle: "Run a quick filesystem task", action: .example("list files")),
        .init(title: "Example: Read README", subtitle: "Read a file through the agent loop", action: .example("read README.md")),
        .init(title: "Example: Shell ls", subtitle: "Run a shell command in the workspace", action: .example("shell: ls -la")),
        .init(title: "Help", subtitle: "Show keyboard shortcuts and behavior", action: .help),
        .init(title: "Quit", subtitle: "Exit Ashex", action: .quit),
    ]

    private var screen: Screen = .home
    private var selectedIndex = 0
    private var composerText = ""
    private var statusLine = "Ready"
    private var runLines: [String] = []
    private var runFinished = true
    private var runTask: Task<Void, Never>?
    private var shouldQuit = false

    init(configuration: CLIConfiguration, runtime: AgentRuntime) throws {
        self.configuration = configuration
        self.runtime = runtime
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
        switch screen {
        case .home:
            handleHome(key: key)
        case .composer:
            handleComposer(key: key)
        case .run:
            handleRun(key: key)
        case .help:
            handleHelp(key: key)
        }
    }

    private func handleHome(key: TerminalKey) {
        switch key {
        case .up:
            selectedIndex = max(0, selectedIndex - 1)
        case .down:
            selectedIndex = min(menuItems.count - 1, selectedIndex + 1)
        case .enter:
            activate(menuItems[selectedIndex].action)
        case .character("k"):
            selectedIndex = max(0, selectedIndex - 1)
        case .character("j"):
            selectedIndex = min(menuItems.count - 1, selectedIndex + 1)
        case .escape, .left:
            shouldQuit = true
        default:
            break
        }
    }

    private func handleComposer(key: TerminalKey) {
        switch key {
        case .enter:
            let prompt = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
            if prompt.isEmpty {
                statusLine = "Prompt is empty"
            } else {
                startRun(prompt: prompt)
            }
        case .backspace:
            if !composerText.isEmpty {
                composerText.removeLast()
            }
        case .escape, .left:
            composerText = ""
            screen = .home
            statusLine = "Back to menu"
        case .character(let character):
            composerText.append(character)
        case .space:
            composerText.append(" ")
        default:
            break
        }
    }

    private func handleRun(key: TerminalKey) {
        switch key {
        case .escape, .left:
            if runFinished {
                screen = .home
                statusLine = "Back to menu"
            } else {
                runTask?.cancel()
                runTask = nil
                runFinished = true
                runLines.append("[local] Run cancelled from TUI")
                statusLine = "Run cancelled"
            }
        default:
            break
        }
    }

    private func handleHelp(key: TerminalKey) {
        switch key {
        case .escape, .left, .enter:
            screen = .home
            statusLine = "Back to menu"
        default:
            break
        }
    }

    private func activate(_ action: Action) {
        switch action {
        case .compose:
            composerText = ""
            screen = .composer
            statusLine = "Write a prompt and press Enter"
        case .example(let prompt):
            startRun(prompt: prompt)
        case .help:
            screen = .help
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
        screen = .run
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
        statusLine = "Run finished. Press Esc or Left to return."
        render()
    }

    private func render() {
        let size = terminal.terminalSize()
        let width = max(size.columns, 72)
        var lines = renderHeader(width: width)
        lines.append(TerminalUIStyle.rule(width: width))
        lines.append(contentsOf: renderContent(width: width, height: size.rows))
        lines.append(TerminalUIStyle.rule(width: width))
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

    private func renderContent(width: Int, height: Int) -> [String] {
        let chromeHeight = 9
        let available = max(height - chromeHeight, 8)
        switch screen {
        case .home:
            return panel(
                title: "Launcher",
                lines: renderHomeLines(width: width - 4),
                width: width,
                maxBodyHeight: available
            )
        case .composer:
            return panel(
                title: "Prompt Composer",
                lines: renderComposerLines(width: width - 4),
                width: width,
                maxBodyHeight: available
            )
        case .run:
            return panel(
                title: runFinished ? "Run Transcript" : "Live Run",
                lines: renderRunLines(width: width - 4, maxBodyHeight: available),
                width: width,
                maxBodyHeight: available
            )
        case .help:
            return panel(
                title: "Controls",
                lines: renderHelpLines(width: width - 4),
                width: width,
                maxBodyHeight: available
            )
        }
    }

    private func renderHomeLines(width: Int) -> [String] {
        var lines: [String] = [
            "\(TerminalUIStyle.faint)Use Up/Down or j/k to move. Enter selects. Esc leaves Ashex.\(TerminalUIStyle.reset)",
            ""
        ]

        for (index, item) in menuItems.enumerated() {
            let selected = index == selectedIndex
            let marker = selected ? "\(TerminalUIStyle.selection) \(TerminalUIStyle.reset)" : " "
            let titleColor = selected ? TerminalUIStyle.cyan : TerminalUIStyle.ink
            let title = "\(marker) \(TerminalUIStyle.bold)\(titleColor)\(item.title)\(TerminalUIStyle.reset)"
            let detail = "   \(TerminalUIStyle.slate)\(TerminalUIStyle.truncateVisible(item.subtitle, limit: max(width - 3, 10)))\(TerminalUIStyle.reset)"
            lines.append(title)
            lines.append(detail)
            if index != menuItems.count - 1 {
                lines.append("")
            }
        }
        return lines
    }

    private func renderComposerLines(width: Int) -> [String] {
        var lines: [String] = [
            "\(TerminalUIStyle.faint)Type your instruction and press Enter to launch a run. Esc or Left returns to the launcher.\(TerminalUIStyle.reset)",
            ""
        ]

        let prompt = composerText.isEmpty
            ? "\(TerminalUIStyle.faint)Describe what you want Ashex to do…\(TerminalUIStyle.reset)"
            : "\(TerminalUIStyle.ink)\(composerText)\(TerminalUIStyle.reset)"
        lines.append(contentsOf: wrapVisible("\(TerminalUIStyle.cyan)›\(TerminalUIStyle.reset) \(prompt)", width: width))
        lines.append("")
        lines.append("\(TerminalUIStyle.faint)Tip:\(TerminalUIStyle.reset) \(TerminalUIStyle.blue)list files\(TerminalUIStyle.reset), \(TerminalUIStyle.blue)read README.md\(TerminalUIStyle.reset), \(TerminalUIStyle.blue)shell: ls -la\(TerminalUIStyle.reset)")
        return lines
    }

    private func renderRunLines(width: Int, maxBodyHeight: Int) -> [String] {
        var visible = Array(runLines.suffix(max(maxBodyHeight - 2, 1)))
        if visible.isEmpty {
            visible = ["Waiting for events..."]
        }

        var output: [String] = [
            runFinished
                ? "\(TerminalUIStyle.faint)Run completed. Esc or Left returns to the launcher.\(TerminalUIStyle.reset)"
                : "\(TerminalUIStyle.amber)Streaming live events… Esc or Left cancels the active run.\(TerminalUIStyle.reset)",
            ""
        ]

        for line in visible {
            output.append(stylizeRunLine(line, width: width))
        }
        return output
    }

    private func renderHelpLines(width: Int) -> [String] {
        [
            "\(TerminalUIStyle.ink)Navigation\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.slate)Up/Down or j/k\(TerminalUIStyle.reset) Move through the launcher",
            "\(TerminalUIStyle.slate)Enter\(TerminalUIStyle.reset) Open an item or submit a prompt",
            "\(TerminalUIStyle.slate)Esc or Left\(TerminalUIStyle.reset) Back out, cancel a run, or quit",
            "\(TerminalUIStyle.slate)Backspace\(TerminalUIStyle.reset) Delete text in the composer",
            "",
            "\(TerminalUIStyle.ink)One-shot commands still work\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.blue)\(TerminalUIStyle.truncateVisible("swift run ashex 'list files'", limit: width))\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.blue)\(TerminalUIStyle.truncateVisible("swift run ashex --provider openai 'read README.md'", limit: width))\(TerminalUIStyle.reset)",
            "",
            "\(TerminalUIStyle.faint)This TUI is intentionally thin: it is a client over the same reusable runtime used by one-shot mode.\(TerminalUIStyle.reset)"
        ]
    }

    private func renderFooter(width: Int) -> String {
        let hint = switch screen {
        case .home:
            "\(TerminalUIStyle.faint)enter\(TerminalUIStyle.reset) open  \(TerminalUIStyle.faint)esc\(TerminalUIStyle.reset) quit"
        case .composer:
            "\(TerminalUIStyle.faint)enter\(TerminalUIStyle.reset) run  \(TerminalUIStyle.faint)backspace\(TerminalUIStyle.reset) edit  \(TerminalUIStyle.faint)esc\(TerminalUIStyle.reset) back"
        case .run:
            runFinished
                ? "\(TerminalUIStyle.faint)esc\(TerminalUIStyle.reset) back to launcher"
                : "\(TerminalUIStyle.faint)esc\(TerminalUIStyle.reset) cancel run"
        case .help:
            "\(TerminalUIStyle.faint)enter/esc\(TerminalUIStyle.reset) close"
        }

        let value = "\(TerminalUIStyle.faint)Ashex local agent runtime\(TerminalUIStyle.reset)  \(TerminalUIStyle.faint)•\(TerminalUIStyle.reset)  \(hint)"
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

    private func wrapVisible(_ value: String, width: Int) -> [String] {
        guard width > 8 else { return [TerminalUIStyle.truncateVisible(value, limit: width)] }
        let plain = TerminalUIStyle.stripANSI(from: value)
        guard plain.count > width else { return [value] }

        var lines: [String] = []
        var current = plain[...]
        while current.count > width {
            let index = current.index(current.startIndex, offsetBy: width)
            lines.append(String(current[..<index]))
            current = current[index...]
        }
        if !current.isEmpty {
            lines.append(String(current))
        }
        return lines.map { "\(TerminalUIStyle.ink)\($0)\(TerminalUIStyle.reset)" }
    }

    private func join(left: String, right: String, width: Int) -> String {
        let leftWidth = TerminalUIStyle.visibleWidth(of: left)
        let rightWidth = TerminalUIStyle.visibleWidth(of: right)
        if leftWidth + rightWidth + 2 <= width {
            return left + String(repeating: " ", count: width - leftWidth - rightWidth) + right
        }
        return TerminalUIStyle.truncateVisible(left, limit: width)
    }

    private var screenLabel: String {
        switch screen {
        case .home: return "launcher"
        case .composer: return "composer"
        case .run: return runFinished ? "run summary" : "live run"
        case .help: return "help"
        }
    }

    private var statusColor: String {
        let lowered = statusLine.lowercased()
        if lowered.contains("fail") || lowered.contains("error") {
            return TerminalUIStyle.red
        }
        if lowered.contains("running") || lowered.contains("stream") {
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
}

private enum TerminalKey {
    case up
    case down
    case left
    case right
    case enter
    case backspace
    case escape
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
                    if ("@"..."~").contains(next) {
                        break
                    }
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
