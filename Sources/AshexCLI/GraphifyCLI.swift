import AshexCore
import Foundation

enum GraphifyCLI {
    static func handle(arguments: [String]) async throws -> Bool {
        guard arguments.dropFirst().first == "graphify" else { return false }
        let subcommand = arguments.dropFirst().dropFirst().first ?? "help"
        switch subcommand {
        case "init":
            try initGraph(arguments: arguments)
        case "build":
            try await build(arguments: arguments)
        case "status":
            try await status(arguments: arguments)
        case "query":
            try await query(arguments: arguments)
        case "path":
            try await path(arguments: arguments)
        case "explain":
            try await explain(arguments: arguments)
        case "report":
            try report(arguments: arguments)
        case "rebuild":
            try await rebuild(arguments: arguments)
        case "cluster-only":
            try await clusterOnly(arguments: arguments)
        case "clean":
            try clean(arguments: arguments)
        case "help", "--help", "-h":
            print(helpText)
        default:
            throw AshexError.model("Unknown graphify command '\(subcommand)'.\n\(helpText)")
        }
        return true
    }

    private static func initGraph(arguments: [String]) throws {
        let options = try GraphifyOptions(arguments: arguments, positionalMode: .none)
        let configuration = try CLIConfiguration(arguments: options.configurationArguments)
        let result = try GraphifyService(
            projectRoot: configuration.workspaceRoot,
            config: configuration.userConfig.graphify
        ).prepareForInitialBuild()
        if options.json {
            try CLIJSONOutput.print(result)
            return
        }

        print("Graphify Init")
        print("Ignore file: \(result.ignorePath)")
        print("State: \(result.statePath)")
        if result.appendedEntries.isEmpty {
            print("Ignore entries: already up to date")
        } else {
            print("Added ignore entries:")
            for entry in result.appendedEntries {
                print("- \(entry)")
            }
        }
    }

    private static func build(arguments: [String]) async throws {
        let options = try GraphifyOptions(arguments: arguments, positionalMode: .none)
        let configuration = try CLIConfiguration(arguments: options.configurationArguments)
        let service = GraphifyService(projectRoot: configuration.workspaceRoot, config: configuration.userConfig.graphify)
        _ = try? service.prepareForInitialBuild()
        let guidance = await service.buildGuidance()
        if options.json {
            try CLIJSONOutput.print(guidance)
            return
        }

        print("Graphify Build")
        print("Project root: \(guidance.projectRoot)")
        print("Installed: \(guidance.installed ? "yes" : "no")")
        print("Graph exists: \(guidance.graphExists ? "yes" : "no")")
        print("Recommended first-build command: \(guidance.recommendedCommand)")
        print("Notes:")
        for note in guidance.notes {
            print("- \(note)")
        }
    }

    private static func status(arguments: [String]) async throws {
        let options = try GraphifyOptions(arguments: arguments, positionalMode: .none)
        let configuration = try CLIConfiguration(arguments: options.configurationArguments)
        let service = GraphifyService(projectRoot: configuration.workspaceRoot, config: configuration.userConfig.graphify)
        let status = await service.status()
        if options.json {
            try CLIJSONOutput.print(status)
            return
        }

        print("Graphify Status")
        print("Installed: \(status.installed ? "yes" : "no")")
        print("Executable: \(status.executablePath ?? "<not found>")")
        print("Version: \(status.version ?? "<unknown>")")
        print("Python import: \(status.pythonImportAvailable ? "yes" : "no")")
        print("Python: \(status.pythonExecutablePath ?? "<not found>")")
        print("Project root: \(status.projectRoot)")
        print("Graph: \(status.graphExists ? status.graphPath : "<missing>")")
        print("Report: \(status.reportExists ? status.reportPath : "<missing>")")
        print("State: \(status.statePath)")
        if let stateStatus = status.stateStatus {
            print("State status: \(stateStatus)")
        }
        if let lastBuiltAt = status.lastBuiltAt {
            print("Last built: \(ISO8601DateFormatter().string(from: lastBuiltAt))")
        }
        print("Next: \(status.recommendedNextAction)")
    }

    private static func query(arguments: [String]) async throws {
        let options = try GraphifyOptions(arguments: arguments, positionalMode: .query)
        guard let question = options.positionals.first?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty else {
            throw AshexError.model("graphify query requires a question")
        }
        let configuration = try CLIConfiguration(arguments: options.configurationArguments)
        let result = try await GraphifyService(projectRoot: configuration.workspaceRoot, config: configuration.userConfig.graphify).query(
            question: question,
            useDFS: options.useDFS,
            budget: options.budget,
            graphPath: options.graphPath
        )
        try render(result: result, json: options.json)
    }

    private static func path(arguments: [String]) async throws {
        let options = try GraphifyOptions(arguments: arguments, positionalMode: .path)
        guard options.positionals.count >= 2 else {
            throw AshexError.model("graphify path requires source and target labels")
        }
        let configuration = try CLIConfiguration(arguments: options.configurationArguments)
        let result = try await GraphifyService(projectRoot: configuration.workspaceRoot, config: configuration.userConfig.graphify).path(
            source: options.positionals[0],
            target: options.positionals[1],
            graphPath: options.graphPath
        )
        try render(result: result, json: options.json)
    }

    private static func explain(arguments: [String]) async throws {
        let options = try GraphifyOptions(arguments: arguments, positionalMode: .explain)
        guard let node = options.positionals.first?.trimmingCharacters(in: .whitespacesAndNewlines), !node.isEmpty else {
            throw AshexError.model("graphify explain requires a node label")
        }
        let configuration = try CLIConfiguration(arguments: options.configurationArguments)
        let result = try await GraphifyService(projectRoot: configuration.workspaceRoot, config: configuration.userConfig.graphify).explain(
            node: node,
            graphPath: options.graphPath
        )
        try render(result: result, json: options.json)
    }

    private static func report(arguments: [String]) throws {
        let options = try GraphifyOptions(arguments: arguments, positionalMode: .none)
        let configuration = try CLIConfiguration(arguments: options.configurationArguments)
        let report = try GraphifyService(projectRoot: configuration.workspaceRoot, config: configuration.userConfig.graphify).report(maxCharacters: options.maxCharacters)
        if options.json {
            try CLIJSONOutput.print(report)
            return
        }
        if options.pathOnly {
            print(report.path)
            return
        }
        guard report.exists, let content = report.content else {
            throw AshexError.model("No Graphify report found at \(report.path). Build the graph with the official `/graphify <path>` workflow first.")
        }
        print(content)
        if report.truncated {
            print("\n[report truncated]")
        }
    }

    private static func rebuild(arguments: [String]) async throws {
        let options = try GraphifyOptions(arguments: arguments, positionalMode: .none)
        let configuration = try CLIConfiguration(arguments: options.configurationArguments)
        let result = try await GraphifyService(projectRoot: configuration.workspaceRoot, config: configuration.userConfig.graphify).rebuild()
        try render(maintenance: result, json: options.json)
    }

    private static func clusterOnly(arguments: [String]) async throws {
        let options = try GraphifyOptions(arguments: arguments, positionalMode: .none)
        let configuration = try CLIConfiguration(arguments: options.configurationArguments)
        let result = try await GraphifyService(projectRoot: configuration.workspaceRoot, config: configuration.userConfig.graphify).clusterOnly()
        try render(maintenance: result, json: options.json)
    }

    private static func clean(arguments: [String]) throws {
        let options = try GraphifyOptions(arguments: arguments, positionalMode: .none)
        let configuration = try CLIConfiguration(arguments: options.configurationArguments)
        let result = try GraphifyService(projectRoot: configuration.workspaceRoot, config: configuration.userConfig.graphify).clean(confirm: options.confirm)
        if options.json {
            try CLIJSONOutput.print(result)
            return
        }
        if result.removedPaths.isEmpty {
            print("No Graphify output or ASHEX graph state existed.")
        } else {
            print("Removed:")
            for path in result.removedPaths {
                print("- \(path)")
            }
        }
    }

    private static func render(result: GraphifyQueryResult, json: Bool) throws {
        if json {
            try CLIJSONOutput.print(result)
        } else {
            print(result.stdout, terminator: result.stdout.hasSuffix("\n") ? "" : "\n")
        }
    }

    private static func render(maintenance result: GraphifyMaintenanceResult, json: Bool) throws {
        if json {
            try CLIJSONOutput.print(result)
            return
        }
        print(result.stdout, terminator: result.stdout.hasSuffix("\n") ? "" : "\n")
        if !result.stderr.isEmpty {
            fputs(result.stderr, stderr)
        }
    }

    static let helpText = """
    Usage:
      ashex graphify init [--json] [options]
      ashex graphify build [--json] [options]
      ashex graphify status [--json] [options]
      ashex graphify query "<question>" [--dfs] [--budget N] [--graph path] [--json] [options]
      ashex graphify path "<source>" "<target>" [--graph path] [--json] [options]
      ashex graphify explain "<node>" [--graph path] [--json] [options]
      ashex graphify report [--path-only] [--max-characters N] [--json] [options]
      ashex graphify rebuild [--json] [options]
      ashex graphify cluster-only [--json] [options]
      ashex graphify clean --yes [--json] [options]

    Options:
      --workspace PATH
      --storage PATH
      --provider NAME
      --model NAME
      --approval-mode MODE
    """
}

private struct GraphifyOptions {
    enum PositionalMode {
        case none
        case query
        case path
        case explain
    }

    let json: Bool
    let useDFS: Bool
    let budget: Int?
    let graphPath: URL?
    let pathOnly: Bool
    let maxCharacters: Int?
    let confirm: Bool
    let positionals: [String]
    let configurationArguments: [String]

    init(arguments: [String], positionalMode: PositionalMode) throws {
        var json = false
        var useDFS = false
        var budget: Int?
        var graphPath: URL?
        var pathOnly = false
        var maxCharacters: Int?
        var confirm = false
        var positionals: [String] = []
        var configurationArguments = [arguments.first ?? "ashex"]

        var iterator = arguments.dropFirst().dropFirst().dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--json":
                json = true
            case "--dfs":
                useDFS = true
            case "--budget":
                guard let value = iterator.next(), let parsed = Int(value), parsed > 0 else {
                    throw AshexError.model("Invalid value for --budget")
                }
                budget = parsed
            case "--graph":
                guard let value = iterator.next() else { throw AshexError.model("Missing value for --graph") }
                graphPath = URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
            case "--path-only":
                pathOnly = true
            case "--yes":
                confirm = true
            case "--max-characters":
                guard let value = iterator.next(), let parsed = Int(value), parsed > 0 else {
                    throw AshexError.model("Invalid value for --max-characters")
                }
                maxCharacters = parsed
            case "--workspace", "--storage", "--provider", "--model", "--max-iterations", "--approval-mode":
                guard let value = iterator.next() else { throw AshexError.model("Missing value for \(argument)") }
                configurationArguments.append(argument)
                configurationArguments.append(value)
            default:
                positionals.append(argument)
            }
        }

        if positionalMode == .query, positionals.count > 1 {
            positionals = [positionals.joined(separator: " ")]
        }

        self.json = json
        self.useDFS = useDFS
        self.budget = budget
        self.graphPath = graphPath
        self.pathOnly = pathOnly
        self.maxCharacters = maxCharacters
        self.confirm = confirm
        self.positionals = positionals
        self.configurationArguments = configurationArguments
    }
}
