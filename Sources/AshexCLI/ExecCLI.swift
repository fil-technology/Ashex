import AshexCore
import Darwin
import Foundation

enum ExecCLI {
    static func handle(arguments: [String]) async throws -> Bool {
        guard arguments.dropFirst().first == "exec" else { return false }
        let options = try ExecRunOptions(arguments: arguments)
        try await run(options: options, executableName: arguments.first ?? "ashex")
        return true
    }

    private static func run(options: ExecRunOptions, executableName: String) async throws {
        if options.showHelp {
            print(helpText)
            return
        }

        let configuration = try CLIConfiguration(arguments: options.configurationArguments(executableName: executableName))
        let execConfig = ExecRunConfig(options: options, configuration: configuration)
        try execConfig.validate()
        try await configuration.validateModelGuardrails()

        let transcript = try ExecTranscriptWriter(storageRoot: configuration.storageRoot)
        let startedAt = Date()
        try transcript.write(type: "run_started", payload: [
            "cwd": .string(execConfig.cwd.path),
            "sandbox": .string(execConfig.sandbox.rawValue),
            "approval": .string(execConfig.approval.rawValue),
            "provider": .string(configuration.provider),
            "model": .string(execConfig.executorModel ?? configuration.model),
            "planner": execConfig.plannerModel.map(JSONValue.string) ?? .null,
            "executor": execConfig.executorModel.map(JSONValue.string) ?? .null,
            "dry_run": .bool(execConfig.dryRun),
        ])

        if execConfig.json {
            print(try transcript.eventLine(type: "run_started", payload: [
                "transcript": .string(transcript.fileURL.path),
                "cwd": .string(execConfig.cwd.path),
                "sandbox": .string(execConfig.sandbox.rawValue),
                "approval": .string(execConfig.approval.rawValue),
            ]))
        } else {
            print(header(for: execConfig, configuration: configuration, transcriptURL: transcript.fileURL))
            if execConfig.sandbox == .dangerFullAccess {
                print("WARNING: danger-full-access is enabled. Ashex may run commands with your full OS user permissions.")
                print("")
            }
        }

        if let plannerModel = execConfig.plannerModel, plannerModel != execConfig.effectiveExecutorModel(configuration: configuration) {
            try await runPlanner(
                model: plannerModel,
                prompt: execConfig.prompt,
                configuration: configuration,
                execConfig: execConfig,
                transcript: transcript
            )
        }

        if execConfig.dryRun {
            let summary = "Dry run complete. No tools were executed."
            try transcript.write(type: "run_finished", payload: [
                "state": .string("completed"),
                "summary": .string(summary),
                "duration_seconds": .number(Date().timeIntervalSince(startedAt)),
            ])
            if execConfig.json {
                print(try transcript.eventLine(type: "run_finished", payload: ["state": .string("completed"), "summary": .string(summary)]))
            } else {
                print("Final:")
                print(summary)
            }
            return
        }

        let runtime = try makeRuntime(configuration: configuration, execConfig: execConfig)
        let execPrompt = promptEnvelope(for: execConfig, configuration: configuration)
        let stream = runtime.run(.init(prompt: execPrompt, maxIterations: execConfig.maxSteps))
        var finalAnswer = ""
        var runtimeRunID: UUID?
        var changedFiles: [String] = []
        var commandsRun: [String] = []

        for await event in stream {
            switch event.payload {
            case .runStarted(_, let runID):
                runtimeRunID = runID
                try transcript.write(type: "runtime_run_started", runtimeRunID: runID, payload: [:])
            case .taskPlanCreated(_, let steps):
                try transcript.write(type: "model_response", runtimeRunID: runtimeRunID, payload: [
                    "kind": .string("plan"),
                    "steps": .array(steps.map(JSONValue.string)),
                ])
                if !execConfig.json {
                    print("Plan:")
                    for (index, step) in steps.enumerated() {
                        print("\(index + 1). \(step)")
                    }
                    print("")
                }
            case .toolCallStarted(_, _, let toolName, let arguments):
                if toolName == "shell", let command = arguments["command"]?.stringValue {
                    commandsRun.append(command)
                }
                try transcript.write(type: "tool_requested", runtimeRunID: runtimeRunID, payload: [
                    "tool": .string(toolName),
                    "arguments": .object(arguments),
                ])
                if execConfig.json {
                    print(try transcript.eventLine(type: "tool_requested", payload: ["tool": .string(toolName), "arguments": .object(arguments)]))
                } else {
                    print("Tool: \(toolName)")
                    if toolName == "shell", let command = arguments["command"]?.stringValue {
                        print("Command: \(command)")
                    }
                }
            case .approvalRequested(_, let toolName, let summary, let reason, let risk):
                try transcript.write(type: "approval_requested", runtimeRunID: runtimeRunID, payload: [
                    "tool": .string(toolName),
                    "summary": .string(summary),
                    "reason": .string(reason),
                    "risk": .string(risk.rawValue),
                ])
                if execConfig.json {
                    print(try transcript.eventLine(type: "approval_requested", payload: [
                        "tool": .string(toolName),
                        "summary": .string(summary),
                        "risk": .string(risk.rawValue),
                    ]))
                }
            case .approvalResolved(_, let toolName, let allowed, let reason):
                try transcript.write(type: "approval_result", runtimeRunID: runtimeRunID, payload: [
                    "tool": .string(toolName),
                    "allowed": .bool(allowed),
                    "reason": .string(reason),
                ])
            case .toolOutput(_, _, let stream, let chunk):
                try transcript.write(type: "tool_output", runtimeRunID: runtimeRunID, payload: [
                    "stream": .string(stream.rawValue),
                    "chunk": .string(chunk),
                ])
                if !execConfig.json {
                    let prefix = stream == .stderr ? "stderr" : "stdout"
                    for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
                        print("[\(prefix)] \(line)")
                    }
                }
            case .toolCallFinished(_, _, let success, let summary):
                try transcript.write(type: "tool_result", runtimeRunID: runtimeRunID, payload: [
                    "success": .bool(success),
                    "summary": .string(summary),
                ])
                if !execConfig.json {
                    print("Result: \(success ? "completed" : "failed")")
                    if !summary.isEmpty {
                        print(truncate(summary, limit: 800))
                    }
                    print("")
                }
            case .changedFilesTracked(_, let paths):
                changedFiles = paths
                try transcript.write(type: "file_changed", runtimeRunID: runtimeRunID, payload: [
                    "paths": .array(paths.map(JSONValue.string)),
                ])
            case .finalAnswer(_, _, let text):
                finalAnswer = text
                try transcript.write(type: "model_response", runtimeRunID: runtimeRunID, payload: [
                    "kind": .string("final"),
                    "text": .string(text),
                ])
            case .error(_, let message):
                try transcript.write(type: "error", runtimeRunID: runtimeRunID, payload: ["message": .string(message)])
                if execConfig.json {
                    print(try transcript.eventLine(type: "error", payload: ["message": .string(message)]))
                } else {
                    fputs("[error] \(message)\n", stderr)
                }
            case .runFinished(_, let state):
                try transcript.write(type: "run_finished", runtimeRunID: runtimeRunID, payload: [
                    "state": .string(state.rawValue),
                    "duration_seconds": .number(Date().timeIntervalSince(startedAt)),
                    "changed_files": .array(changedFiles.map(JSONValue.string)),
                    "commands_run": .array(commandsRun.map(JSONValue.string)),
                ])
                if execConfig.json {
                    print(try transcript.eventLine(type: "run_finished", payload: [
                        "state": .string(state.rawValue),
                        "changed_files": .array(changedFiles.map(JSONValue.string)),
                        "commands_run": .array(commandsRun.map(JSONValue.string)),
                    ]))
                }
            default:
                break
            }
        }

        if !execConfig.json {
            if !changedFiles.isEmpty {
                print("Changed files:")
                for path in changedFiles {
                    print("- \(path)")
                }
                print("")
            }
            print("Final:")
            print(finalAnswer.isEmpty ? "Run finished without a final answer." : finalAnswer)
            print("")
            print("Transcript: \(transcript.fileURL.path)")
        }
    }

    private static func runPlanner(
        model: String,
        prompt: String,
        configuration: CLIConfiguration,
        execConfig: ExecRunConfig,
        transcript: ExecTranscriptWriter
    ) async throws {
        let adapter = try configuration.makeModelAdapter(provider: configuration.provider, model: model)
        guard let chat = adapter as? any DirectChatModelAdapter else {
            try transcript.write(type: "model_response", payload: [
                "kind": .string("planner_skipped"),
                "reason": .string("Selected planner adapter does not support direct chat planning."),
            ])
            return
        }
        let messages = [
            MessageRecord(id: UUID(), threadID: UUID(), runID: nil, role: .user, content: prompt, createdAt: Date())
        ]
        let systemPrompt = """
        You are the planner for ashex exec. Produce a concise high-level plan only. Do not call tools.
        cwd: \(execConfig.cwd.path)
        sandbox: \(execConfig.sandbox.rawValue)
        approval: \(execConfig.approval.rawValue)
        """
        try transcript.write(type: "model_request", payload: [
            "role": .string("planner"),
            "model": .string(model),
            "prompt": .string(prompt),
        ])
        let plan = try await chat.directReply(history: messages, systemPrompt: systemPrompt)
        try transcript.write(type: "model_response", payload: [
            "role": .string("planner"),
            "model": .string(model),
            "text": .string(plan),
        ])
        if !execConfig.json {
            print("Planner:")
            print(plan)
            print("")
        }
    }

    private static func makeRuntime(configuration: CLIConfiguration, execConfig: ExecRunConfig) throws -> AgentRuntime {
        let persistence = try configuration.makePersistenceStore()
        var userConfig = configuration.userConfig
        userConfig.sandbox = SandboxPolicyConfig(
            mode: execConfig.sandbox,
            protectedPaths: protectedPaths(for: execConfig.sandbox, base: userConfig.sandbox.protectedPaths)
        )
        userConfig.network = networkPolicy(for: execConfig.approval, base: userConfig.network)
        userConfig.shell = shellPolicy(for: execConfig.approval, base: userConfig.shell)
        let shellPolicy = ShellExecutionPolicy(
            sandbox: userConfig.sandbox,
            network: userConfig.network,
            shell: ShellCommandPolicy(config: userConfig.shell)
        )
        let tools = try RuntimeToolFactory.makeTools(
            workspaceURL: execConfig.cwd,
            persistence: persistence,
            sandbox: userConfig.sandbox,
            shellExecutionPolicy: shellPolicy
        )
        return try AgentRuntime(
            modelAdapter: configuration.makeModelAdapter(provider: configuration.provider, model: execConfig.effectiveExecutorModel(configuration: configuration)),
            toolRegistry: ToolRegistry(tools: tools),
            persistence: persistence,
            approvalPolicy: approvalPolicy(for: execConfig.approval, json: execConfig.json),
            shellExecutionPolicy: shellPolicy,
            workspaceSnapshot: WorkspaceSnapshotBuilder.capture(workspaceRoot: execConfig.cwd),
            reasoningSummaryDebugEnabled: userConfig.debug.reasoningSummaries
        )
    }

    private static func approvalPolicy(for mode: ExecApprovalPolicyMode, json: Bool) -> any ApprovalPolicy {
        switch mode {
        case .always:
            if json {
                return ExecJSONApprovalPolicy(policy: .always)
            }
            return ExecInteractiveApprovalPolicy(policy: .always)
        case .onRequest:
            if json {
                return ExecJSONApprovalPolicy(policy: .onRequest)
            }
            return ExecInteractiveApprovalPolicy(policy: .onRequest)
        case .never:
            return TrustedApprovalPolicy()
        }
    }

    private static func shellPolicy(for approval: ExecApprovalPolicyMode, base: ShellCommandPolicyConfig) -> ShellCommandPolicyConfig {
        switch approval {
        case .always:
            return ShellCommandPolicyConfig(
                allowList: base.allowList,
                denyList: base.denyList,
                requireApprovalForUnknownCommands: true,
                rules: base.rules
            )
        case .onRequest:
            return ShellCommandPolicyConfig(
                allowList: base.allowList,
                denyList: base.denyList + riskyShellPrefixes,
                requireApprovalForUnknownCommands: true,
                rules: base.rules
            )
        case .never:
            return base
        }
    }

    private static func networkPolicy(for approval: ExecApprovalPolicyMode, base: NetworkPolicyConfig) -> NetworkPolicyConfig {
        switch approval {
        case .always, .onRequest:
            return NetworkPolicyConfig(mode: .prompt, rules: base.rules)
        case .never:
            return base
        }
    }

    private static func protectedPaths(for sandbox: WorkspaceSandboxMode, base: [String]) -> [String] {
        guard sandbox != .dangerFullAccess else { return base }
        return Array(Set(base + sensitiveProtectedPaths)).sorted()
    }

    private static let riskyShellPrefixes = [
        "curl ", "wget ", "ssh ", "scp ", "sudo ", "chmod ", "chown ",
        "git reset", "git clean", "git push",
        "npm install", "pnpm install", "yarn install", "brew install",
        "pip install", "pip3 install"
    ]

    private static let sensitiveProtectedPaths = [
        ".env", ".env.local", ".env.production", ".ssh", ".gnupg", ".aws",
        ".config/gcloud", ".docker/config.json", "id_rsa", "id_ed25519"
    ]

    private static func promptEnvelope(for config: ExecRunConfig, configuration: CLIConfiguration) -> String {
        config.prompt
    }

    private static func header(for config: ExecRunConfig, configuration: CLIConfiguration, transcriptURL: URL) -> String {
        """
        ashex exec
        cwd: \(config.cwd.path)
        sandbox: \(config.sandbox.rawValue)
        approval: \(config.approval.rawValue)
        planner: \(config.plannerModel ?? "single-model")
        executor: \(config.effectiveExecutorModel(configuration: configuration))
        transcript: \(transcriptURL.path)

        """
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(max(limit - 1, 0))) + "…"
    }

    static let helpText = """
    Usage:
      ashex exec [options] "prompt"

    Options:
      -C, --cwd PATH             Working directory
      --planner MODEL            Optional planner model
      --executor MODEL           Optional executor model
      --vision MODEL             Optional future vision model, parsed but unused
      --sandbox MODE             read-only | workspace-write | danger-full-access
      --approval POLICY          always | on-request | never
      --full-auto                Alias for --sandbox workspace-write --approval on-request
      --yolo                     Alias for --sandbox danger-full-access --approval never
      --max-steps N              Default from config or 20
      --json                     Emit JSONL events to stdout
      --dry-run                  Plan only, do not execute tools
      --provider NAME            Provider to use
      --model NAME               Model to use in single-model mode
    """
}

struct ExecRunOptions: Equatable {
    var prompt: String = ""
    var cwd: String?
    var planner: String?
    var executor: String?
    var vision: String?
    var sandbox: WorkspaceSandboxMode?
    var approval: ExecApprovalPolicyMode?
    var maxSteps: Int?
    var json = false
    var dryRun = false
    var fullAuto = false
    var yolo = false
    var showHelp = false
    var provider: String?
    var model: String?
    var storage: String?

    init(arguments: [String]) throws {
        var promptParts: [String] = []
        var iterator = arguments.dropFirst().dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "-h", "--help":
                showHelp = true
            case "-C", "--cwd":
                cwd = try Self.requiredValue(after: argument, iterator: &iterator)
            case "--planner":
                planner = try Self.requiredValue(after: argument, iterator: &iterator)
            case "--executor":
                executor = try Self.requiredValue(after: argument, iterator: &iterator)
            case "--vision":
                vision = try Self.requiredValue(after: argument, iterator: &iterator)
            case "--sandbox":
                sandbox = try Self.parseSandbox(try Self.requiredValue(after: argument, iterator: &iterator))
            case "--approval":
                approval = try Self.parseApproval(try Self.requiredValue(after: argument, iterator: &iterator))
            case "--full-auto":
                fullAuto = true
                sandbox = .workspaceWrite
                approval = .onRequest
            case "--yolo":
                yolo = true
                sandbox = .dangerFullAccess
                approval = .never
            case "--max-steps":
                let value = try Self.requiredValue(after: argument, iterator: &iterator)
                guard let parsed = Int(value), parsed > 0 else {
                    throw AshexError.model("Invalid value for --max-steps")
                }
                maxSteps = parsed
            case "--json":
                json = true
            case "--dry-run":
                dryRun = true
            case "--provider":
                provider = try Self.requiredValue(after: argument, iterator: &iterator)
            case "--model":
                model = try Self.requiredValue(after: argument, iterator: &iterator)
            case "--storage":
                storage = try Self.requiredValue(after: argument, iterator: &iterator)
            default:
                promptParts.append(argument)
            }
        }
        prompt = promptParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func configurationArguments(executableName: String) -> [String] {
        var args = [executableName]
        if let cwd {
            args += ["--workspace", cwd]
        }
        if let storage {
            args += ["--storage", storage]
        }
        if let provider {
            args += ["--provider", provider]
        }
        if let model {
            args += ["--model", model]
        }
        return args
    }

    private static func requiredValue(after option: String, iterator: inout IndexingIterator<ArraySlice<String>>) throws -> String {
        guard let value = iterator.next(), !value.isEmpty else {
            throw AshexError.model("Missing value for \(option)")
        }
        return value
    }

    private static func parseSandbox(_ value: String) throws -> WorkspaceSandboxMode {
        switch value {
        case "read-only", "read_only":
            return .readOnly
        case "workspace-write", "workspace_write":
            return .workspaceWrite
        case "danger-full-access", "danger_full_access":
            return .dangerFullAccess
        default:
            throw AshexError.model("Invalid --sandbox value. Supported: read-only, workspace-write, danger-full-access")
        }
    }

    private static func parseApproval(_ value: String) throws -> ExecApprovalPolicyMode {
        switch value {
        case "always":
            return .always
        case "on-request", "on_request":
            return .onRequest
        case "never":
            return .never
        default:
            throw AshexError.model("Invalid --approval value. Supported: always, on-request, never")
        }
    }
}

struct ExecRunConfig: Equatable {
    let prompt: String
    let cwd: URL
    let plannerModel: String?
    let executorModel: String?
    let visionModel: String?
    let sandbox: WorkspaceSandboxMode
    let approval: ExecApprovalPolicyMode
    let maxSteps: Int
    let json: Bool
    let dryRun: Bool
    let yolo: Bool

    init(options: ExecRunOptions, configuration: CLIConfiguration) {
        self.prompt = options.prompt
        self.cwd = (options.cwd.map { URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) } ?? configuration.workspaceRoot).standardizedFileURL
        self.plannerModel = options.planner ?? configuration.userConfig.exec.models.planner
        self.executorModel = options.executor ?? configuration.userConfig.exec.models.executor
        self.visionModel = options.vision ?? configuration.userConfig.exec.models.vision
        self.sandbox = options.sandbox ?? configuration.userConfig.exec.defaultSandbox
        self.approval = options.approval ?? configuration.userConfig.exec.defaultApproval
        self.maxSteps = options.maxSteps ?? configuration.userConfig.exec.maxSteps
        self.json = options.json
        self.dryRun = options.dryRun
        self.yolo = options.yolo
    }

    func effectiveExecutorModel(configuration: CLIConfiguration) -> String {
        executorModel ?? plannerModel ?? configuration.model
    }

    func validate() throws {
        guard !prompt.isEmpty else {
            throw AshexError.model("ashex exec requires a prompt")
        }
        guard FileManager.default.fileExists(atPath: cwd.path) else {
            throw AshexError.workspaceViolation("Exec cwd does not exist: \(cwd.path)")
        }
        if sandbox == .dangerFullAccess, approval != .never, !yolo {
            throw AshexError.model("danger-full-access requires --yolo or --approval never")
        }
    }
}

struct ExecTranscriptWriter: Sendable {
    let runID: UUID
    let fileURL: URL
    private let encoder = JSONEncoder()

    init(storageRoot: URL, runID: UUID = UUID()) throws {
        self.runID = runID
        self.fileURL = storageRoot
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent("\(runID.uuidString).jsonl")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        }
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    func write(type: String, runtimeRunID: UUID? = nil, step: Int? = nil, payload: JSONObject) throws {
        let line = try eventLine(type: type, runtimeRunID: runtimeRunID, step: step, payload: payload)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
    }

    func eventLine(type: String, runtimeRunID: UUID? = nil, step: Int? = nil, payload: JSONObject) throws -> String {
        var object: JSONObject = [
            "type": .string(type),
            "run_id": .string(runID.uuidString),
            "timestamp": .string(ISO8601DateFormatter().string(from: Date())),
        ]
        if let runtimeRunID {
            object["runtime_run_id"] = .string(runtimeRunID.uuidString)
        }
        if let step {
            object["step"] = .number(Double(step))
        }
        for (key, value) in payload {
            object[key] = value
        }
        let data = try encoder.encode(JSONValue.object(object))
        return String(decoding: data, as: UTF8.self)
    }
}

struct ExecInteractiveApprovalPolicy: ApprovalPolicy {
    let mode: ApprovalMode = .guarded
    let policy: ExecApprovalPolicyMode

    func evaluate(_ request: ApprovalRequest) async -> ApprovalDecision {
        if policy == .onRequest, Self.canAutoAllow(request) {
            return .allow("Allowed by exec on-request policy")
        }
        return await ConsoleApprovalPolicy().evaluate(request)
    }

    static func canAutoAllow(_ request: ApprovalRequest) -> Bool {
        guard request.toolName == "shell",
              let command = request.arguments["command"]?.stringValue?.lowercased() else {
            return false
        }
        let safePrefixes = [
            "ls", "pwd", "cat ", "grep ", "rg ", "find ", "git status", "git diff",
            "swift test", "swift build", "npm test", "pnpm test", "pytest", "cargo test", "cargo build"
        ]
        return safePrefixes.contains { command.hasPrefix($0) }
    }
}

struct ExecJSONApprovalPolicy: ApprovalPolicy {
    let mode: ApprovalMode = .guarded
    let policy: ExecApprovalPolicyMode

    func evaluate(_ request: ApprovalRequest) async -> ApprovalDecision {
        if policy == .onRequest, ExecInteractiveApprovalPolicy.canAutoAllow(request) {
            return .allow("Allowed by exec on-request policy")
        }
        return .deny("--json mode cannot prompt interactively; rerun without --json to approve this action or use --approval never with an appropriate sandbox.")
    }
}
