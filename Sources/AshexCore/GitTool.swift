import Foundation

public struct GitTool: Tool {
    public let name = "git"
    public let description = "Inspect and modify git state in the workspace: status, branches, diffs, staging, commits, tags, sync, and history"
    public let contract = ToolContract(
        name: "git",
        description: "Inspect and modify git state in the workspace: status, branches, diffs, staging, commits, tags, sync, and history",
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
            .init(name: "init", description: "Initialize a repository in the workspace", mutatesWorkspace: true, progressSummary: "initialized git repository", approval: .init(risk: .medium, summary: "Initialize a git repository", reasonTemplate: "Initialize a git repository in the current workspace"), arguments: [.init(name: "initial_branch", description: "Optional initial branch name", type: .string, required: false)]),
            .init(name: "add", description: "Stage one or more paths", mutatesWorkspace: true, progressSummary: "staged selected paths", approval: .init(risk: .medium, summary: "Stage git paths", reasonTemplate: "Stage these paths in git: {{paths}}"), arguments: [.init(name: "paths", description: "Workspace-relative paths to stage", type: .array, required: true)]),
            .init(name: "add_all", description: "Stage all tracked and untracked changes", mutatesWorkspace: true, progressSummary: "staged all changes", approval: .init(risk: .medium, summary: "Stage all git changes", reasonTemplate: "Stage all tracked and untracked changes in the repository")),
            .init(name: "commit", description: "Create a commit from staged changes", mutatesWorkspace: true, progressSummary: "created git commit", approval: .init(risk: .medium, summary: "Create a git commit", reasonTemplate: "Create a git commit with message: {{message}}"), arguments: [
                .init(name: "message", description: "Commit message", type: .string, required: true),
                .init(name: "amend", description: "Amend the previous commit", type: .bool, required: false),
                .init(name: "allow_empty", description: "Allow an empty commit", type: .bool, required: false),
            ]),
            .init(name: "create_branch", description: "Create a new branch", mutatesWorkspace: true, progressSummary: "created branch", approval: .init(risk: .medium, summary: "Create a git branch", reasonTemplate: "Create branch {{branch_name}} from {{start_point}}"), arguments: [
                .init(name: "branch_name", description: "Branch to create", type: .string, required: true),
                .init(name: "start_point", description: "Optional ref to branch from", type: .string, required: false),
            ]),
            .init(name: "switch_branch", description: "Switch to an existing branch", mutatesWorkspace: true, progressSummary: "switched branch", approval: .init(risk: .medium, summary: "Switch git branch", reasonTemplate: "Switch to branch {{branch_name}}"), arguments: [.init(name: "branch_name", description: "Branch to switch to", type: .string, required: true)]),
            .init(name: "switch_new_branch", description: "Create and switch to a new branch", mutatesWorkspace: true, progressSummary: "created and switched branch", approval: .init(risk: .medium, summary: "Create and switch git branch", reasonTemplate: "Create and switch to branch {{branch_name}} from {{start_point}}"), arguments: [
                .init(name: "branch_name", description: "Branch to create and switch to", type: .string, required: true),
                .init(name: "start_point", description: "Optional ref to branch from", type: .string, required: false),
            ]),
            .init(name: "restore_worktree", description: "Restore worktree changes for selected paths", mutatesWorkspace: true, progressSummary: "restored worktree changes", approval: .init(risk: .high, summary: "Discard worktree changes", reasonTemplate: "Discard worktree changes for paths: {{paths}}"), arguments: [
                .init(name: "paths", description: "Workspace-relative paths to restore", type: .array, required: true),
                .init(name: "source", description: "Optional ref to restore from", type: .string, required: false),
            ]),
            .init(name: "restore_staged", description: "Unstage selected paths", mutatesWorkspace: true, progressSummary: "unstaged selected paths", approval: .init(risk: .medium, summary: "Unstage git paths", reasonTemplate: "Unstage paths: {{paths}}"), arguments: [.init(name: "paths", description: "Workspace-relative paths to unstage", type: .array, required: true)]),
            .init(name: "reset_mixed", description: "Reset HEAD and keep worktree changes", mutatesWorkspace: true, progressSummary: "reset git mixed", approval: .init(risk: .high, summary: "Reset HEAD", reasonTemplate: "Reset HEAD to {{commit}} while keeping worktree changes"), arguments: [.init(name: "commit", description: "Optional target ref", type: .string, required: false)]),
            .init(name: "reset_hard", description: "Hard reset repository state", mutatesWorkspace: true, progressSummary: "hard reset git state", approval: .init(risk: .high, summary: "Hard reset repository", reasonTemplate: "Hard reset repository to {{commit}} and discard local changes"), arguments: [.init(name: "commit", description: "Optional target ref", type: .string, required: false)]),
            .init(name: "clean_force", description: "Delete untracked files or directories", mutatesWorkspace: true, progressSummary: "cleaned untracked files", approval: .init(risk: .high, summary: "Delete untracked files", reasonTemplate: "Delete untracked files with git clean")),
            .init(name: "tag", description: "Create a tag", mutatesWorkspace: true, progressSummary: "created tag", approval: .init(risk: .medium, summary: "Create a git tag", reasonTemplate: "Create tag {{name}} for {{commit}}"), arguments: [
                .init(name: "name", description: "Tag name", type: .string, required: true),
                .init(name: "commit", description: "Optional ref to tag", type: .string, required: false),
                .init(name: "message", description: "Optional annotation message", type: .string, required: false),
            ]),
            .init(name: "merge", description: "Merge a branch into the current branch", mutatesWorkspace: true, progressSummary: "merged branch", approval: .init(risk: .high, summary: "Merge a branch", reasonTemplate: "Merge branch {{branch_name}} into the current branch"), arguments: [
                .init(name: "branch_name", description: "Branch to merge", type: .string, required: true),
                .init(name: "no_ff", description: "Force a merge commit", type: .bool, required: false),
            ]),
            .init(name: "rebase", description: "Rebase the current branch onto another ref", mutatesWorkspace: true, progressSummary: "rebased branch", approval: .init(risk: .high, summary: "Rebase the current branch", reasonTemplate: "Rebase the current branch onto {{branch_name}}"), arguments: [.init(name: "branch_name", description: "Target ref to rebase onto", type: .string, required: true)]),
            .init(name: "pull", description: "Pull from a remote", mutatesWorkspace: true, progressSummary: "pulled remote changes", approval: .init(risk: .high, summary: "Pull remote changes", reasonTemplate: "Pull from remote {{remote}} {{branch_name}}"), arguments: [
                .init(name: "remote", description: "Remote name", type: .string, required: false),
                .init(name: "branch_name", description: "Optional branch name", type: .string, required: false),
                .init(name: "rebase", description: "Rebase after fetch instead of merge", type: .bool, required: false),
            ]),
            .init(name: "push", description: "Push to a remote", mutatesWorkspace: true, progressSummary: "pushed remote changes", approval: .init(risk: .high, summary: "Push remote changes", reasonTemplate: "Push to remote {{remote}} {{branch_name}}"), arguments: [
                .init(name: "remote", description: "Remote name", type: .string, required: false),
                .init(name: "branch_name", description: "Optional branch name", type: .string, required: false),
                .init(name: "set_upstream", description: "Set upstream tracking", type: .bool, required: false),
                .init(name: "force_with_lease", description: "Force push with lease", type: .bool, required: false),
            ]),
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
        case "init":
            let initialBranch = optionalString("initial_branch", in: arguments)
            command = ["git", "init", initialBranch.map { "--initial-branch=\(shellQuoted($0))" }].compactMap { $0 }.joined(separator: " ")
        case "add":
            let paths = try requiredStringArray("paths", in: arguments)
            command = "git add -- " + paths.map(shellQuoted).joined(separator: " ")
        case "add_all":
            command = "git add -A"
        case "commit":
            let message = try requiredString("message", in: arguments)
            let amend = arguments["amend"]?.boolValue ?? false
            let allowEmpty = arguments["allow_empty"]?.boolValue ?? false
            var parts = ["git", "commit", "-m", shellQuoted(message)]
            if amend {
                parts.append("--amend")
            }
            if allowEmpty {
                parts.append("--allow-empty")
            }
            command = parts.joined(separator: " ")
        case "create_branch":
            let branchName = try requiredString("branch_name", in: arguments)
            let startPoint = optionalString("start_point", in: arguments)
            command = ["git", "branch", shellQuoted(branchName), startPoint.map(shellQuoted)].compactMap { $0 }.joined(separator: " ")
        case "switch_branch":
            let branchName = try requiredString("branch_name", in: arguments)
            command = "git switch " + shellQuoted(branchName)
        case "switch_new_branch":
            let branchName = try requiredString("branch_name", in: arguments)
            let startPoint = optionalString("start_point", in: arguments)
            command = ["git", "switch", "-c", shellQuoted(branchName), startPoint.map(shellQuoted)].compactMap { $0 }.joined(separator: " ")
        case "restore_worktree":
            let paths = try requiredStringArray("paths", in: arguments)
            let source = optionalString("source", in: arguments)
            var parts = ["git", "restore"]
            if let source {
                parts.append("--source")
                parts.append(shellQuoted(source))
            }
            parts.append("--")
            parts.append(contentsOf: paths.map(shellQuoted))
            command = parts.joined(separator: " ")
        case "restore_staged":
            let paths = try requiredStringArray("paths", in: arguments)
            command = (["git", "restore", "--staged", "--"] + paths.map(shellQuoted))
                .joined(separator: " ")
        case "reset_mixed":
            let commit = optionalString("commit", in: arguments) ?? "HEAD"
            command = "git reset --mixed " + shellQuoted(commit)
        case "reset_hard":
            let commit = optionalString("commit", in: arguments) ?? "HEAD"
            command = "git reset --hard " + shellQuoted(commit)
        case "clean_force":
            let directories = arguments["directories"]?.boolValue ?? true
            let ignored = arguments["ignored"]?.boolValue ?? false
            var parts = ["git", "clean", "-f"]
            if directories {
                parts.append("-d")
            }
            if ignored {
                parts.append("-x")
            }
            command = parts.joined(separator: " ")
        case "tag":
            let name = try requiredString("name", in: arguments)
            let commit = optionalString("commit", in: arguments)
            let message = optionalString("message", in: arguments)
            var parts = ["git", "tag"]
            if let message {
                parts.append("-a")
                parts.append(shellQuoted(name))
                parts.append("-m")
                parts.append(shellQuoted(message))
            } else {
                parts.append(shellQuoted(name))
            }
            if let commit {
                parts.append(shellQuoted(commit))
            }
            command = parts.joined(separator: " ")
        case "merge":
            let branchName = try requiredString("branch_name", in: arguments)
            let noFF = arguments["no_ff"]?.boolValue ?? false
            var parts = ["git", "merge"]
            if noFF {
                parts.append("--no-ff")
            }
            parts.append(shellQuoted(branchName))
            command = parts.joined(separator: " ")
        case "rebase":
            let branchName = try requiredString("branch_name", in: arguments)
            command = "git rebase " + shellQuoted(branchName)
        case "pull":
            let remote = optionalString("remote", in: arguments)
            let branchName = optionalString("branch_name", in: arguments)
            let rebase = arguments["rebase"]?.boolValue ?? false
            var parts = ["git", "pull"]
            if rebase {
                parts.append("--rebase")
            }
            if let remote {
                parts.append(shellQuoted(remote))
            }
            if let branchName {
                parts.append(shellQuoted(branchName))
            }
            command = parts.joined(separator: " ")
        case "push":
            let remote = optionalString("remote", in: arguments)
            let branchName = optionalString("branch_name", in: arguments)
            let setUpstream = arguments["set_upstream"]?.boolValue ?? false
            let forceWithLease = arguments["force_with_lease"]?.boolValue ?? false
            var parts = ["git", "push"]
            if setUpstream {
                parts.append("--set-upstream")
            }
            if forceWithLease {
                parts.append("--force-with-lease")
            }
            if let remote {
                parts.append(shellQuoted(remote))
            }
            if let branchName {
                parts.append(shellQuoted(branchName))
            }
            command = parts.joined(separator: " ")
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

    private func optionalString(_ key: String, in arguments: JSONObject) -> String? {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            return nil
        }
        return value
    }

    private func requiredStringArray(_ key: String, in arguments: JSONObject) throws -> [String] {
        guard let values = arguments[key]?.arrayValue?
            .compactMap(\.stringValue)
            .filter({ !$0.isEmpty }),
              !values.isEmpty else {
            throw AshexError.invalidToolArguments("git.\(key) must be a non-empty array of strings")
        }
        return values
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
