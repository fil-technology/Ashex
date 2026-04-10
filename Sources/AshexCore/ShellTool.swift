import Foundation

public struct ShellTool: Tool {
    public let name = "shell"
    public let description = "Execute shell commands inside the workspace with streaming stdout/stderr"
    public let contract = ToolContract(
        name: "shell",
        description: "Execute shell commands inside the workspace with streaming stdout/stderr",
        kind: .embedded,
        category: "shell",
        operationArgumentKey: nil,
        defaultOperationName: "execute",
        operations: [
            .init(
                name: "execute",
                description: "Run a shell command in the current workspace",
                mutatesWorkspace: true,
                requiresNetwork: true,
                validationArtifacts: ["<check>"],
                inspectedPathArguments: [],
                changedPathArguments: ["path"],
                progressSummary: "executed shell command",
                approval: .init(risk: .medium, summary: "Shell command", reasonTemplate: "{{command}}"),
                arguments: [
                    .init(name: "command", description: "Shell command to execute", type: .string, required: true),
                    .init(name: "timeout_seconds", description: "Optional timeout in seconds", type: .number, required: false),
                ]
            )
        ],
        tags: ["core", "shell", "validation"]
    )

    private let executionRuntime: any ExecutionRuntime
    private let workspaceURL: URL
    private let executionPolicy: ShellExecutionPolicy

    public init(executionRuntime: any ExecutionRuntime, workspaceURL: URL, executionPolicy: ShellExecutionPolicy) {
        self.executionRuntime = executionRuntime
        self.workspaceURL = workspaceURL
        self.executionPolicy = executionPolicy
    }

    public func execute(arguments: JSONObject, context: ToolContext) async throws -> ToolContent {
        guard let command = arguments["command"]?.stringValue, !command.isEmpty else {
            throw AshexError.invalidToolArguments("shell.command must be a non-empty string")
        }

        try executionPolicy.validate(command: command)

        let timeoutSeconds = TimeInterval(arguments["timeout_seconds"]?.intValue ?? 30)
        let result = try await executionRuntime.execute(
            .init(command: command, workspaceURL: workspaceURL, timeout: timeoutSeconds, executionPolicy: executionPolicy),
            cancellationToken: context.cancellation,
            onStdout: { chunk in
                context.emit(RuntimeEvent(payload: .toolOutput(
                    runID: context.runID,
                    toolCallID: .init(),
                    stream: .stdout,
                    chunk: chunk
                )))
            },
            onStderr: { chunk in
                context.emit(RuntimeEvent(payload: .toolOutput(
                    runID: context.runID,
                    toolCallID: .init(),
                    stream: .stderr,
                    chunk: chunk
                )))
            }
        )

        let payload: JSONValue = .object([
            "command": .string(command),
            "stdout": .string(result.stdout),
            "stderr": .string(result.stderr),
            "exit_code": .number(Double(result.exitCode)),
            "timed_out": .bool(result.timedOut),
        ])

        if result.timedOut {
            throw AshexError.shell("Command timed out after \(Int(timeoutSeconds))s")
        }

        if result.exitCode != 0 {
            throw AshexError.shell("Command failed with exit code \(result.exitCode)\n\(payload.prettyPrinted)")
        }

        return .structured(payload)
    }
}
