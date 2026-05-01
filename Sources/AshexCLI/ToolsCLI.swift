import AshexCore
import Foundation

enum ToolsCLI {
    static func handle(arguments: [String]) async throws -> Bool {
        guard arguments.dropFirst().first == "tools" else { return false }
        let subcommand = arguments.dropFirst().dropFirst().first ?? "help"
        switch subcommand {
        case "list":
            try list(arguments: arguments)
        case "doctor":
            try doctor(arguments: arguments)
        case "help", "--help", "-h":
            print(helpText)
        default:
            throw AshexError.model("Unknown tools command '\(subcommand)'.\n\(helpText)")
        }
        return true
    }

    private static func list(arguments: [String]) throws {
        let options = try Options(arguments: arguments)
        let tools = try runtimeTools(configurationArguments: options.configurationArguments)
        let specs = ToolRegistry(tools: tools).specs()
        if options.json {
            try CLIJSONOutput.print(specs)
            return
        }

        for spec in specs {
            print("\(spec.name): \(spec.description)")
        }
    }

    private static func doctor(arguments: [String]) throws {
        let options = try Options(arguments: arguments)
        let tools = try runtimeTools(configurationArguments: options.configurationArguments)
        let report = ToolRegistryDiagnostics.inspect(tools: tools)
        if options.json {
            try CLIJSONOutput.print(report)
            return
        }

        print("Tools Doctor")
        print("Status: \(report.status.rawValue)")
        print("Registered tools: \(report.toolCount)")
        print("Duplicate names: \(report.duplicateToolNames.isEmpty ? "none" : report.duplicateToolNames.joined(separator: ", "))")
        if report.issues.isEmpty {
            print("Issues: none")
        } else {
            print("Issues:")
            for issue in report.issues {
                print("- [\(issue.severity.rawValue)] \(issue.subject): \(issue.message)")
            }
        }
    }

    private static func runtimeTools(configurationArguments: [String]) throws -> [any Tool] {
        let configuration = try CLIConfiguration(arguments: configurationArguments)
        let persistence = try configuration.makePersistenceStore()
        return try configuration.makeRuntimeTools(
            persistence: persistence,
            userConfig: configuration.userConfig
        )
    }

    static let helpText = """
    Usage:
      ashex tools list [--json] [options]
      ashex tools doctor [--json] [options]

    Options:
      --workspace PATH
      --storage PATH
      --provider NAME
      --model NAME
      --approval-mode MODE
    """
}

private struct Options {
    let json: Bool
    let configurationArguments: [String]

    init(arguments: [String]) throws {
        var json = false
        var configurationArguments = [arguments.first ?? "ashex"]
        var iterator = arguments.dropFirst().dropFirst().dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--json":
                json = true
            case "--workspace", "--storage", "--provider", "--model", "--max-iterations", "--approval-mode":
                guard let value = iterator.next() else { throw AshexError.model("Missing value for \(argument)") }
                configurationArguments.append(argument)
                configurationArguments.append(value)
            default:
                throw AshexError.model("Unknown tools option '\(argument)'")
            }
        }
        self.json = json
        self.configurationArguments = configurationArguments
    }
}
