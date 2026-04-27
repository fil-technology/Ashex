import Foundation

enum ModelCLICommand: Equatable {
    case list([String], task: String?)
    case search([String], query: String)
    case install([String], query: String)
    case audioModels([String])

    static func parse(arguments: [String]) -> ModelCLICommand? {
        guard arguments.count >= 2 else { return nil }

        if let index = arguments.firstIndex(of: "model"), arguments.indices.contains(index + 1) {
            let action = arguments[index + 1]
            let extras = commandExtras(arguments: arguments, excluding: [index, index + 1])
            switch action {
            case "list":
                let task = value(for: "--task", in: extras)
                return .list(extras, task: task)
            case "search":
                let queryParts = positionalValues(in: extras)
                let query = queryParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                let commandExtras = extras.filter { !queryParts.contains($0) }
                return query.isEmpty ? nil : .search(commandExtras, query: query)
            case "install":
                let queryParts = positionalValues(in: extras)
                let query = queryParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                let commandExtras = extras.filter { !queryParts.contains($0) }
                return query.isEmpty ? nil : .install(commandExtras, query: query)
            default:
                return nil
            }
        }

        if let index = arguments.firstIndex(of: "audio"),
           arguments.indices.contains(index + 1),
           arguments[index + 1] == "models" {
            let extras = commandExtras(arguments: arguments, excluding: [index, index + 1])
            return .audioModels(extras)
        }

        return nil
    }

    private static func value(for option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func positionalValues(in arguments: [String]) -> [String] {
        var values: [String] = []
        var skipNext = false
        for (index, argument) in arguments.enumerated() {
            if skipNext {
                skipNext = false
                continue
            }
            if ["--workspace", "--storage", "--provider", "--model", "--approval-mode", "--task"].contains(argument),
               arguments.indices.contains(index + 1) {
                skipNext = true
                continue
            }
            if argument.hasPrefix("-") {
                continue
            }
            values.append(argument)
        }
        return values
    }

    private static func commandExtras(arguments: [String], excluding indexes: Set<Int>) -> [String] {
        arguments.enumerated()
            .filter { $0.offset != 0 && !indexes.contains($0.offset) }
            .map(\.element)
    }
}

enum ModelCLI {
    static func handle(arguments: [String]) throws -> Bool {
        guard let command = ModelCLICommand.parse(arguments: arguments) else {
            return false
        }

        switch command {
        case .list(let extraArguments, let task):
            let configuration = try CLIConfiguration(arguments: [arguments[0]] + extraArguments)
            if configuration.provider == "esh" || task == "audio" || task == "tool" {
                let models = try EshCommandClient.listInstalledModels(configuration: configuration)
                if let task, task == "audio" {
                    let audioModels = try EshCommandClient.listInstalledAudioModels(configuration: configuration)
                    print(audioModels.isEmpty ? "No installed esh audio models." : audioModels.joined(separator: "\n"))
                } else {
                    print(models.isEmpty ? "No installed esh models." : models.joined(separator: "\n"))
                }
            } else {
                print("`ashex model list` currently supports local esh-backed model discovery. Use `--provider esh` or `ashex audio models`.")
            }
        case .search(let extraArguments, let query):
            let configuration = try CLIConfiguration(arguments: [arguments[0]] + extraArguments)
            let results = try EshCommandClient.searchModels(configuration: configuration, query: query)
            if results.isEmpty {
                print("No installable models found.")
            } else {
                for result in results {
                    print("\(result.displayName)\n  \(result.detail)")
                }
            }
        case .install(let extraArguments, let query):
            let configuration = try CLIConfiguration(arguments: [arguments[0]] + extraArguments)
            let output = try EshCommandClient.installModel(configuration: configuration, query: query)
            print(output.isEmpty ? "Install complete." : output)
        case .audioModels(let extraArguments):
            let configuration = try CLIConfiguration(arguments: [arguments[0]] + extraArguments)
            let models = try EshCommandClient.listInstalledAudioModels(configuration: configuration)
            print(models.isEmpty ? "No installed esh audio models." : models.joined(separator: "\n"))
        }

        return true
    }
}
