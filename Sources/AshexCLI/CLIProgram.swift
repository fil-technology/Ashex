import AshexCore
import Darwin
import Foundation

struct AshexCLI {
    static func main() async {
        do {
            let configuration = try CLIConfiguration(arguments: CommandLine.arguments)
            let runtime = try configuration.makeRuntime()

            if let prompt = configuration.prompt {
                let stream = runtime.run(.init(prompt: prompt, maxIterations: configuration.maxIterations))
                for await event in stream {
                    render(event)
                }
            } else {
                let app = try await MainActor.run {
                    try TUIApp(configuration: configuration, runtime: runtime)
                }
                try await app.run()
            }
        } catch {
            fputs("ashex error: \(error.localizedDescription)\n", stderr)
            Darwin.exit(1)
        }
    }

    private static func render(_ event: RuntimeEvent) {
        switch event.payload {
        case .runStarted(_, let runID):
            print("[run] started \(runID.uuidString)")
        case .runStateChanged(_, let state, let reason):
            print("[state] \(state.rawValue)\(reason.map { " - \($0)" } ?? "")")
        case .status(_, let message):
            print("[status] \(message)")
        case .messageAppended(_, _, let role):
            print("[message] appended \(role.rawValue)")
        case .toolCallStarted(_, _, let toolName, let arguments):
            print("[tool] \(toolName) started \(JSONValue.object(arguments).prettyPrinted)")
        case .toolOutput(_, _, let stream, let chunk):
            let prefix = stream == .stderr ? "stderr" : "stdout"
            for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
                if !line.isEmpty {
                    print("[\(prefix)] \(line)")
                }
            }
        case .toolCallFinished(_, _, let success, let summary):
            print("[tool] \(success ? "completed" : "failed") \(summary)")
        case .finalAnswer(_, _, let text):
            print("\nFinal answer:\n\(text)")
        case .error(_, let message):
            fputs("[error] \(message)\n", stderr)
        case .runFinished(_, let state):
            print("[run] finished \(state.rawValue)")
        }
    }
}

struct CLIConfiguration {
    let prompt: String?
    let workspaceRoot: URL
    let storageRoot: URL
    let maxIterations: Int
    let provider: String
    let model: String

    init(arguments: [String]) throws {
        var promptParts: [String] = []
        var workspaceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var storageRoot: URL?
        var maxIterations = 8
        var provider = ProcessInfo.processInfo.environment["ASHEX_PROVIDER"] ?? "mock"
        var model = ProcessInfo.processInfo.environment["OPENAI_MODEL"] ?? "gpt-5.4-mini"

        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--workspace":
                guard let value = iterator.next() else { throw AshexError.model("Missing value for --workspace") }
                workspaceRoot = URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            case "--storage":
                guard let value = iterator.next() else { throw AshexError.model("Missing value for --storage") }
                storageRoot = URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            case "--max-iterations":
                guard let value = iterator.next(), let parsed = Int(value), parsed > 0 else {
                    throw AshexError.model("Invalid value for --max-iterations")
                }
                maxIterations = parsed
            case "--provider":
                guard let value = iterator.next(), !value.isEmpty else {
                    throw AshexError.model("Missing value for --provider")
                }
                provider = value
            case "--model":
                guard let value = iterator.next(), !value.isEmpty else {
                    throw AshexError.model("Missing value for --model")
                }
                model = value
            default:
                promptParts.append(argument)
            }
        }

        let promptText = promptParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = promptText.isEmpty ? nil : promptText

        self.prompt = prompt
        self.workspaceRoot = workspaceRoot.standardizedFileURL
        self.storageRoot = storageRoot?.standardizedFileURL ?? workspaceRoot.appendingPathComponent(".ashex")
        self.maxIterations = maxIterations
        self.provider = provider
        self.model = model
    }

    func makeModelAdapter() throws -> any ModelAdapter {
        switch provider {
        case "mock":
            return MockModelAdapter()
        case "openai":
            guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !apiKey.isEmpty else {
                throw AshexError.model("OPENAI_API_KEY is required when --provider openai is used")
            }
            return OpenAIResponsesModelAdapter(
                configuration: .init(apiKey: apiKey, model: model)
            )
        default:
            throw AshexError.model("Unsupported provider '\(provider)'. Supported: mock, openai")
        }
    }

    func makeRuntime() throws -> AgentRuntime {
        let workspaceURL = workspaceRoot.standardizedFileURL
        let persistence = SQLitePersistenceStore(databaseURL: storageRoot.appendingPathComponent("ashex.sqlite"))
        return try AgentRuntime(
            modelAdapter: makeModelAdapter(),
            toolRegistry: ToolRegistry(tools: [
                FileSystemTool(workspaceGuard: WorkspaceGuard(rootURL: workspaceURL)),
                ShellTool(executionRuntime: ProcessExecutionRuntime(), workspaceURL: workspaceURL),
            ]),
            persistence: persistence
        )
    }
}
