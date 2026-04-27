import AshexCore
import Foundation

public final class ComputerUsePrototypeLoop {
    public let provider: any ComputerUseProvider
    public let safetyPolicy: ComputerUseSafetyPolicy
    public let observationBuilder: ComputerUseObservationBuilder
    public let parser: ComputerUseCommandParser
    public let executor: ComputerUseActionExecutor

    private let configuration: ComputerUseConfig
    private let manifestURL: URL
    private let io: any ComputerUseIO
    private let fileManager: FileManager

    public init(
        provider: any ComputerUseProvider,
        safetyPolicy: ComputerUseSafetyPolicy,
        observationBuilder: ComputerUseObservationBuilder,
        parser: ComputerUseCommandParser,
        executor: ComputerUseActionExecutor,
        configuration: ComputerUseConfig,
        manifestURL: URL,
        io: any ComputerUseIO = ConsoleComputerUseIO(),
        fileManager: FileManager = .default
    ) {
        self.provider = provider
        self.safetyPolicy = safetyPolicy
        self.observationBuilder = observationBuilder
        self.parser = parser
        self.executor = executor
        self.configuration = configuration
        self.manifestURL = manifestURL
        self.io = io
        self.fileManager = fileManager
    }

    public func run() async throws {
        guard configuration.enabled else {
            throw AshexError.model("Computer use is disabled. Set `computer_use.enabled` to true in ashex.config.json.")
        }
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw AshexError.model("Computer-use backend manifest is missing at \(manifestURL.path).")
        }

        let status = try await provider.backendStatus()
        let permissions = await provider.permissionStatus()
        io.writeLine("Computer Use Prototype")
        io.writeLine("Enabled: \(configuration.enabled)")
        io.writeLine("Backend manifest: \(manifestURL.path)")
        io.writeLine("Backend: \(status.state.rawValue)\(status.detail.map { " (\($0))" } ?? "")")
        io.writeLine("Safety: \(configuration.safety.rawValue)")
        io.writeLine("Accessibility: \(permissions.accessibility.rawValue)")
        io.writeLine("Screen Recording: \(permissions.screenRecording.rawValue)")

        guard permissions.isReadyForComputerUse else {
            throw AshexError.model(permissions.guidance)
        }

        guard status.state == .running else {
            throw AshexError.model("Computer-use backend is not running.")
        }

        try await provider.bootstrap()
        let windows = try await provider.listWindows()
        guard !windows.isEmpty else {
            throw AshexError.model("No windows were reported by the computer-use backend.")
        }

        let selectedWindow = try chooseWindow(from: windows)
        io.writeLine("Selected: \(selectedWindow.appName) - \(selectedWindow.title)")

        while true {
            let state = try await provider.getWindowState(windowId: selectedWindow.id)
            let observation = try await makeObservation(state, windowId: selectedWindow.id)
            io.writeLine("")
            writeObservation(observation)
            guard let input = io.readLine(prompt: "Goal or command"), !input.isEmpty else {
                continue
            }

            let action = try parser.parse(input)
            if action == .quit {
                io.writeLine("Exiting computer-use prototype.")
                return
            }

            if action == .refreshState {
                continue
            }

            let decision = safetyPolicy.evaluate(action, state: state)
            guard decision.isAllowed else {
                io.writeLine("Blocked: \(decision.reason ?? "Action was denied by safety policy.")")
                continue
            }

            if decision.requiresConfirmation {
                let confirmed = io.confirm(prompt: decision.reason ?? "Run action?")
                if !confirmed {
                    io.writeLine("Skipped.")
                    continue
                }
            }

            try await executor.execute(action, windowId: selectedWindow.id)
            let updatedState = try await provider.getWindowState(windowId: selectedWindow.id)
            let updatedObservation = try await makeObservation(updatedState, windowId: selectedWindow.id)
            io.writeLine("")
            io.writeLine("Updated state:")
            writeObservation(updatedObservation)
        }
    }

    private func makeObservation(_ state: ComputerUseWindowState, windowId: String) async throws -> ComputerUseObservation {
        let screenshot = try await provider.captureScreenshot(windowId: windowId)
        return observationBuilder.makeObservation(state, screenshot: screenshot)
    }

    private func writeObservation(_ observation: ComputerUseObservation) {
        io.writeLine(observation.text)
        for screenshot in observation.screenshots {
            io.writeLine("Screenshot: \(screenshot.contentType), \(screenshot.width)x\(screenshot.height), \(screenshot.data.count) bytes")
        }
    }

    private func chooseWindow(from windows: [ComputerUseWindow]) throws -> ComputerUseWindow {
        io.writeLine("")
        io.writeLine("Available windows:")
        for (index, window) in windows.enumerated() {
            io.writeLine("\(index + 1). \(window.appName) - \(window.title) [\(window.id)]")
        }

        guard let rawValue = io.readLine(prompt: "Select window number"),
              let selection = Int(rawValue),
              windows.indices.contains(selection - 1) else {
            throw AshexError.model("Invalid window selection.")
        }
        return windows[selection - 1]
    }
}

public protocol ComputerUseIO: Sendable {
    func writeLine(_ line: String)
    func readLine(prompt: String) -> String?
    func confirm(prompt: String) -> Bool
}

public struct ConsoleComputerUseIO: ComputerUseIO {
    public init() {}

    public func writeLine(_ line: String) {
        Swift.print(line)
    }

    public func readLine(prompt: String) -> String? {
        Swift.print("\(prompt): ", terminator: "")
        fflush(stdout)
        return Swift.readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func confirm(prompt: String) -> Bool {
        Swift.print("\(prompt) [y/N]: ", terminator: "")
        fflush(stdout)
        guard let response = Swift.readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return response == "y" || response == "yes"
    }
}
