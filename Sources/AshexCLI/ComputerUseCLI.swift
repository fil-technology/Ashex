import AshexComputerUse
import AshexCore
import Foundation

enum ComputerUseCLICommand: Equatable {
    case prototype([String])
    case doctor([String])

    static func parse(arguments: [String]) -> ComputerUseCLICommand? {
        for index in commandCandidateIndexes(in: arguments) {
            guard arguments.indices.contains(index + 1) else { continue }
            if arguments[index] == "computer-use", arguments[index + 1] == "prototype" {
                return .prototype(commandExtraArguments(arguments: arguments, commandIndexes: [index, index + 1]))
            }
            if arguments[index] == "computer-use", arguments[index + 1] == "doctor" {
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
            let configuration = try CLIConfiguration(arguments: [arguments.first ?? "ashex"] + extraArguments)
            try await runDoctor(workspaceRoot: configuration.workspaceRoot, userConfig: configuration.userConfig)
        }
        return true
    }

    static func runPrototype(workspaceRoot: URL, userConfig: AshexUserConfig) async throws {
        let manifestURL = resolvedManifestURL(workspaceRoot: workspaceRoot, config: userConfig.computerUse)
        let provider = ManifestBackedComputerUseProvider(manifestURL: manifestURL)
        let loop = ComputerUsePrototypeLoop(
            provider: provider,
            safetyPolicy: .init(mode: userConfig.computerUse.safety),
            observationBuilder: .init(),
            parser: .init(),
            executor: .init(provider: provider),
            configuration: userConfig.computerUse,
            manifestURL: manifestURL
        )
        try await loop.run()
    }

    static func runDoctor(workspaceRoot: URL, userConfig: AshexUserConfig) async throws {
        let manifestURL = resolvedManifestURL(workspaceRoot: workspaceRoot, config: userConfig.computerUse)
        let provider = ManifestBackedComputerUseProvider(manifestURL: manifestURL)
        let permissions = await provider.permissionStatus()
        print("Computer Use Doctor")
        print("Enabled: \(userConfig.computerUse.enabled)")
        print("Backend manifest: \(manifestURL.path)")
        print("Accessibility: \(permissions.accessibility.rawValue)")
        print("Screen Recording: \(permissions.screenRecording.rawValue)")
        print(permissions.guidance)

        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            print("Backend: manifest missing")
            return
        }

        let status = try await provider.backendStatus()
        print("Backend: \(status.state.rawValue)\(status.detail.map { " (\($0))" } ?? "")")
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
}
