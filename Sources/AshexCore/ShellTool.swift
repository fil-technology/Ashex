import Foundation

public struct ShellTool: Tool {
    public let name = "shell"
    public let description = "Execute shell commands inside the workspace with streaming stdout/stderr"

    private let executionRuntime: any ExecutionRuntime
    private let workspaceURL: URL

    public init(executionRuntime: any ExecutionRuntime, workspaceURL: URL) {
        self.executionRuntime = executionRuntime
        self.workspaceURL = workspaceURL
    }

    public func execute(arguments: JSONObject, context: ToolContext) async throws -> ToolContent {
        guard let command = arguments["command"]?.stringValue, !command.isEmpty else {
            throw AshexError.invalidToolArguments("shell.command must be a non-empty string")
        }

        let timeoutSeconds = TimeInterval(arguments["timeout_seconds"]?.intValue ?? 30)
        let result = try await executionRuntime.execute(
            .init(command: command, workspaceURL: workspaceURL, timeout: timeoutSeconds),
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
