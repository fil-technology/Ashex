import Foundation

public struct GitTool: Tool {
    public let name = "git"
    public let description = "Inspect git state in the workspace: status, branch, diffs, history, and commits"
    public let contract = ToolContract(
        name: "git",
        description: "Inspect git state in the workspace: status, branch, diffs, history, and commits",
        kind: .embedded,
        category: "git",
        operationArgumentKey: "operation",
        operations: [
            .init(name: "status", description: "Show current branch and changed files", mutatesWorkspace: false, validationArtifacts: ["<git>"], inspectedPathArguments: ["path"], progressSummary: "checked git status"),
            .init(name: "current_branch", description: "Show the current branch", mutatesWorkspace: false, inspectedPathArguments: ["path"], progressSummary: "checked git branch"),
            .init(name: "diff_unstaged", description: "Inspect unstaged changes", mutatesWorkspace: false, validationArtifacts: ["<git>"], progressSummary: "inspected unstaged diff"),
            .init(name: "diff_staged", description: "Inspect staged changes", mutatesWorkspace: false, validationArtifacts: ["<git>"], progressSummary: "inspected staged diff"),
            .init(name: "log", description: "Show recent commit history", mutatesWorkspace: false, progressSummary: "read git history", arguments: [.init(name: "limit", description: "Maximum number of commits to show", type: .number, required: false)]),
            .init(name: "show_commit", description: "Inspect one commit with patch and stats", mutatesWorkspace: false, validationArtifacts: ["<git>"], progressSummary: "inspected commit", arguments: [.init(name: "commit", description: "Commit SHA or ref", type: .string, required: true)]),
        ],
        tags: ["core", "git", "validation"]
    )

    private let executionRuntime: any ExecutionRuntime
    private let workspaceURL: URL

    public init(executionRuntime: any ExecutionRuntime, workspaceURL: URL) {
        self.executionRuntime = executionRuntime
        self.workspaceURL = workspaceURL
    }

    public func execute(arguments: JSONObject, context: ToolContext) async throws -> ToolContent {
        guard let operation = arguments["operation"]?.stringValue, !operation.isEmpty else {
            throw AshexError.invalidToolArguments("git.operation must be a non-empty string")
        }

        let command: String
        switch operation {
        case "status":
            command = "git status --short --branch"
        case "current_branch":
            command = "git branch --show-current"
        case "diff_unstaged":
            command = "git diff --no-ext-diff --minimal"
        case "diff_staged":
            command = "git diff --cached --no-ext-diff --minimal"
        case "log":
            let limit = max(arguments["limit"]?.intValue ?? 10, 1)
            command = "git log --decorate --oneline -n \(limit)"
        case "show_commit":
            let commit = try requiredString("commit", in: arguments)
            command = "git show --stat --patch --decorate --no-ext-diff \(shellQuoted(commit))"
        default:
            throw AshexError.invalidToolArguments("Unsupported git operation: \(operation)")
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
            "operation": .string(operation),
            "command": .string(command),
            "stdout": .string(result.stdout),
            "stderr": .string(result.stderr),
            "exit_code": .number(Double(result.exitCode)),
            "timed_out": .bool(result.timedOut),
        ])

        if result.timedOut {
            throw AshexError.shell("Git command timed out after \(Int(timeoutSeconds))s")
        }

        if result.exitCode != 0 {
            throw AshexError.shell("Git command failed with exit code \(result.exitCode)\n\(payload.prettyPrinted)")
        }

        return .structured(payload)
    }

    private func requiredString(_ key: String, in arguments: JSONObject) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw AshexError.invalidToolArguments("git.\(key) must be a non-empty string")
        }
        return value
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
