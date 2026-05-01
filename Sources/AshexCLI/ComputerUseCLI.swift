import AshexComputerUse
import AshexCore
import Foundation

enum ComputerUseCLICommand: Equatable {
    case prototype([String])
    case doctor([String])

    static func parse(arguments: [String]) -> ComputerUseCLICommand? {
        for index in commandCandidateIndexes(in: arguments) {
            guard arguments.indices.contains(index + 1) else { continue }
            if namespaceNames.contains(arguments[index]), arguments[index + 1] == "prototype" {
                return .prototype(commandExtraArguments(arguments: arguments, commandIndexes: [index, index + 1]))
            }
            if namespaceNames.contains(arguments[index]), arguments[index + 1] == "doctor" {
                return .doctor(commandExtraArguments(arguments: arguments, commandIndexes: [index, index + 1]))
            }
        }
        return nil
    }

    private static func commandCandidateIndexes(in arguments: [String]) -> [Int] {
        var indexes: [Int] = []
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if optionNamesWithValues.contains(argument), arguments.indices.contains(index + 1) {
                index += 2
                continue
            }
            if argument.hasPrefix("-") {
                index += 1
                continue
            }
            indexes.append(index)
            index += 1
        }
        return indexes
    }

    private static func commandExtraArguments(arguments: [String], commandIndexes: Set<Int>) -> [String] {
        arguments.indices
            .filter { $0 != arguments.startIndex && !commandIndexes.contains($0) }
            .map { arguments[$0] }
    }

    private static let optionNamesWithValues: Set<String> = [
        "--workspace",
        "--storage",
        "--max-iterations",
        "--provider",
        "--model",
        "--approval-mode",
    ]

    private static let namespaceNames: Set<String> = ["computer-use", "computer"]
}

enum ComputerUseCLI {
    static func handle(arguments: [String]) async throws -> Bool {
        guard let command = ComputerUseCLICommand.parse(arguments: arguments) else {
            return false
        }

        switch command {
        case .prototype(let extraArguments):
            let configuration = try CLIConfiguration(arguments: [arguments.first ?? "ashex"] + extraArguments)
            try await runPrototype(workspaceRoot: configuration.workspaceRoot, userConfig: configuration.userConfig)
        case .doctor(let extraArguments):
            let options = try DoctorOptions(executableName: arguments.first ?? "ashex", extraArguments: extraArguments)
            let configuration = try CLIConfiguration(arguments: options.configurationArguments)
            try await runDoctor(workspaceRoot: configuration.workspaceRoot, userConfig: configuration.userConfig, json: options.json)
        }
        return true
    }

    static func runPrototype(workspaceRoot: URL, userConfig: AshexUserConfig) async throws {
        let manifestURL = resolvedManifestURL(workspaceRoot: workspaceRoot, config: userConfig.computerUse)
        let backend = backendProvider(manifestURL: manifestURL)
        let loop = ComputerUsePrototypeLoop(
            provider: backend.provider,
            safetyPolicy: .init(mode: userConfig.computerUse.safety),
            observationBuilder: .init(),
            parser: .init(),
            executor: .init(provider: backend.provider),
            configuration: userConfig.computerUse,
            manifestURL: manifestURL,
            requiresBackendManifest: backend.requiresManifest,
            backendDescription: backend.description
        )
        try await loop.run()
    }

    static func runDoctor(workspaceRoot: URL, userConfig: AshexUserConfig, json: Bool = false) async throws {
        let manifestURL = resolvedManifestURL(workspaceRoot: workspaceRoot, config: userConfig.computerUse)
        let backend = backendProvider(manifestURL: manifestURL)
        let permissions = ComputerUsePermissionChecker.current(promptForAccessibility: true, promptForScreenRecording: true)
        let manifestExists = FileManager.default.fileExists(atPath: manifestURL.path)
        let status = try await backend.provider.backendStatus()

        if json {
            try CLIJSONOutput.print(ComputerUseDoctorReport(
                enabled: userConfig.computerUse.enabled,
                backendManifestPath: manifestURL.path,
                backendManifestExists: manifestExists,
                selectedBackend: backend.description,
                accessibility: permissions.accessibility.rawValue,
                screenRecording: permissions.screenRecording.rawValue,
                permissionGuidance: permissions.guidance,
                backendState: status.state.rawValue,
                backendDetail: status.detail,
                aggregateToolRegistered: userConfig.computerUse.enabled,
                supportedBackends: [
                    "native macOS Accessibility/CoreGraphics",
                    "manifest-backed external backend"
                ]
            ))
            return
        }

        print("Computer Use Doctor")
        print("Enabled: \(userConfig.computerUse.enabled)")
        print("Backend manifest: \(manifestURL.path)")
        print("Selected backend: \(backend.description)")
        print("Accessibility: \(permissions.accessibility.rawValue)")
        print("Screen Recording: \(permissions.screenRecording.rawValue)")
        print(permissions.guidance)

        if !manifestExists {
            print("Backend manifest: missing; using native macOS fallback")
        }

        print("Backend: \(status.state.rawValue)\(status.detail.map { " (\($0))" } ?? "")")
        print("Registered agent tool: \(userConfig.computerUse.enabled ? "computer_use" : "disabled by config")")
    }

    static func resolvedManifestURL(workspaceRoot: URL, config: ComputerUseConfig) -> URL {
        if let configured = config.backendManifestPath, !configured.isEmpty {
            let url = URL(fileURLWithPath: configured)
            if url.path.hasPrefix("/") {
                return url
            }
            return workspaceRoot.appendingPathComponent(configured)
        }
        return workspaceRoot
            .appendingPathComponent(".ashex", isDirectory: true)
            .appendingPathComponent("background-computer-use.json")
    }

    static func backendProvider(manifestURL: URL) -> (
        provider: any ComputerUseProvider,
        requiresManifest: Bool,
        description: String
    ) {
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            return (
                ManifestBackedComputerUseProvider(manifestURL: manifestURL),
                true,
                "manifest \(manifestURL.path)"
            )
        }
        return (
            NativeMacOSComputerUseProvider(),
            false,
            "native macOS Accessibility/CoreGraphics"
        )
    }
}

private struct ComputerUseDoctorReport: Codable {
    let enabled: Bool
    let backendManifestPath: String
    let backendManifestExists: Bool
    let selectedBackend: String
    let accessibility: String
    let screenRecording: String
    let permissionGuidance: String
    let backendState: String
    let backendDetail: String?
    let aggregateToolRegistered: Bool
    let supportedBackends: [String]
}

private struct DoctorOptions {
    let json: Bool
    let configurationArguments: [String]

    init(executableName: String, extraArguments: [String]) throws {
        var json = false
        var configurationArguments = [executableName]
        var iterator = extraArguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--json":
                json = true
            case "--workspace", "--storage", "--provider", "--model", "--max-iterations", "--approval-mode":
                guard let value = iterator.next() else { throw AshexError.model("Missing value for \(argument)") }
                configurationArguments.append(argument)
                configurationArguments.append(value)
            default:
                throw AshexError.model("Unknown computer doctor option '\(argument)'")
            }
        }
        self.json = json
        self.configurationArguments = configurationArguments
    }
}
