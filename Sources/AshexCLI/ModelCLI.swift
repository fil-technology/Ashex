import Foundation

enum ModelCLICommand: Equatable {
    case list([String], task: String?)
    case search([String], query: String)
    case install([String], query: String, select: Bool)
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
                let select = extras.contains("--select")
                let filteredExtras = extras.filter { $0 != "--select" }
                let queryParts = positionalValues(in: filteredExtras)
                let query = queryParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                let commandExtras = filteredExtras.filter { !queryParts.contains($0) }
                return query.isEmpty ? nil : .install(commandExtras, query: query, select: select)
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
            if configuration.provider == "ollama", task == nil {
                let models = try OllamaCommandClient.listInstalledModels()
                print(models.isEmpty ? "No installed Ollama models." : models.joined(separator: "\n"))
            } else if configuration.provider == "esh" || task == "audio" || task == "tool" {
                let models = try EshCommandClient.listInstalledModels(configuration: configuration)
                if let task, task == "audio" {
                    let audioModels = try EshCommandClient.listInstalledAudioModels(configuration: configuration)
                    print(audioModels.isEmpty ? "No installed esh audio models." : audioModels.joined(separator: "\n"))
                } else {
                    print(models.isEmpty ? "No installed esh models." : models.joined(separator: "\n"))
                }
            } else {
                print("`ashex model list` supports local esh and Ollama discovery. Use `--provider esh`, `--provider ollama`, or `ashex audio models`.")
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
        case .install(let extraArguments, let query, let select):
            let configuration = try CLIConfiguration(arguments: [arguments[0]] + extraArguments)
            if configuration.provider == "ollama" {
                let output = try OllamaCommandClient.installModel(modelName: query)
                print(output.isEmpty ? "Ollama install complete." : output)
                if select {
                    try configuration.persistSessionSelection(provider: "ollama", model: query.trimmingCharacters(in: .whitespacesAndNewlines))
                    print("Selected ollama/\(query.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            } else {
                let selected = try EshCommandClient.installModelResolvingSelection(
                    configuration: configuration,
                    query: query
                )
                print(selected.output.isEmpty ? "Install complete." : selected.output)
                if select {
                    try configuration.persistSessionSelection(provider: "esh", model: selected.model)
                    print("Selected esh/\(selected.model)")
                }
            }
        case .audioModels(let extraArguments):
            let configuration = try CLIConfiguration(arguments: [arguments[0]] + extraArguments)
            let models = try EshCommandClient.listInstalledAudioModels(configuration: configuration)
            print(models.isEmpty ? "No installed esh audio models." : models.joined(separator: "\n"))
        }

        return true
    }
}
