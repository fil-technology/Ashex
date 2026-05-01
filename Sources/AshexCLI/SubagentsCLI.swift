import AshexCore
import Foundation

enum SubagentsCLI {
    static func handle(arguments: [String]) async throws -> Bool {
        guard arguments.dropFirst().first == "subagents" else { return false }
        let subcommand = arguments.dropFirst().dropFirst().first ?? "help"
        switch subcommand {
        case "doctor":
            try doctor(arguments: arguments)
        case "list":
            try list(arguments: arguments)
        case "help", "--help", "-h":
            print(helpText)
        default:
            throw AshexError.model("Unknown subagents command '\(subcommand)'.\n\(helpText)")
        }
        return true
    }

    private static func doctor(arguments: [String]) throws {
        let options = try Options(arguments: arguments)
        let configuration = try CLIConfiguration(arguments: options.configurationArguments)
        let report = try diagnosticReport(configuration: configuration)
        if options.json {
            try CLIJSONOutput.print(report)
            return
        }

        print("Subagents Doctor")
        print("Status: \(report.status.rawValue)")
        print("Runtime delegation: \(report.runtimeDelegationAvailable ? "available" : "unavailable")")
        print("Definitions: \(report.definitions.count)")
        print("Workspace leases: \(report.workspaceLeaseCount)")
        if report.missingToolIssues.isEmpty {
            print("Tool allowlists: ok")
        } else {
            print("Tool allowlists:")
            for issue in report.missingToolIssues {
                print("- \(issue.agentName): missing \(issue.missingTools.joined(separator: ", "))")
            }
        }
    }

    private static func list(arguments: [String]) throws {
        let options = try Options(arguments: arguments)
        let configuration = try CLIConfiguration(arguments: options.configurationArguments)
        let definitions = SubAgentRegistry.builtInDefinitions(computerUseEnabled: configuration.userConfig.computerUse.enabled)
        if options.json {
            try CLIJSONOutput.print(definitions)
            return
        }

        for definition in definitions {
            let state = definition.enabled ? "enabled" : "disabled"
            print("\(definition.name) [\(state)]: \(definition.description)")
            print("  tools: \(definition.allowedTools.joined(separator: ", "))")
            print("  limits: maxSteps=\(definition.maxSteps), timeoutSeconds=\(definition.timeoutSeconds)")
        }
    }

    private static func diagnosticReport(configuration: CLIConfiguration) throws -> SubAgentDiagnosticReport {
        let persistence = try configuration.makePersistenceStore()
        let tools = try configuration.makeRuntimeTools(
            persistence: persistence,
            userConfig: configuration.userConfig
        )
        let definitions = SubAgentRegistry.builtInDefinitions(computerUseEnabled: configuration.userConfig.computerUse.enabled)
        let leases = try SubagentWorkspaceManager(
            storageRoot: configuration.storageRoot,
            workspaceRoot: configuration.workspaceRoot
        ).listLeases()
        return SubAgentRegistry.diagnose(
            definitions: definitions,
            availableToolNames: Set(tools.map(\.name)),
            workspaceLeaseCount: leases.count
        )
    }

    static let helpText = """
    Usage:
      ashex subagents doctor [--json] [options]
      ashex subagents list [--json] [options]

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
                throw AshexError.model("Unknown subagents option '\(argument)'")
            }
        }
        self.json = json
        self.configurationArguments = configurationArguments
    }
}
