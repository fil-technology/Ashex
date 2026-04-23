import Foundation

enum ToolExecutionResult: Sendable {
    case completed(output: String, safeToReuse: Bool, metadata: ToolExecutionMetadata)
    case retryableFailure
}

struct ToolExecutionPreconditions: Sendable {
    let hasPriorInspection: Bool
    let phase: PlannedStepPhase
    let userRequest: String
}

struct ToolExecutionMetadata: Sendable {
    let inspectedPaths: [String]
    let changedPaths: [String]
    let validationArtifacts: [String]
    let summary: String
    let representsProgress: Bool
}

struct ToolExecutor: Sendable {
    let toolRegistry: ToolRegistry
    let persistence: PersistenceStore
    let approvalPolicy: any ApprovalPolicy
    let shellExecutionPolicy: ShellExecutionPolicy?
    let clock: @Sendable () -> Date

    func execute(
        call: ToolCallRequest,
        threadID: UUID,
        runID: UUID,
        attachments: [InputAttachment],
        preconditions: ToolExecutionPreconditions,
        cancellation: CancellationToken,
        emitter: EventEmitter
    ) async throws -> ToolExecutionResult {
        let tool: any Tool
        do {
            tool = try toolRegistry.tool(named: call.toolName)
        } catch {
            if try await handleRecoverableToolRequestError(error, threadID: threadID, runID: runID, emitter: emitter) {
                return .retryableFailure
            }
            throw error
        }

        if let mutationReason = inspectBeforeMutateViolation(for: call, tool: tool, preconditions: preconditions) {
            let toolMessage = try persistence.appendMessage(
                threadID: threadID,
                runID: runID,
                role: .tool,
                content: ToolResultMessageFormatter.blocked(call: call, reason: mutationReason),
                now: clock()
            )
            try emitter.emit(.messageAppended(runID: runID, messageID: toolMessage.id, role: .tool), runID: runID)
            try emitter.emit(.status(runID: runID, message: "Inspect-before-mutate policy blocked a write action. Asking the model to inspect relevant files first."), runID: runID)
            return .retryableFailure
        }

        if let pathReason = filesystemPathIntentViolation(for: call, preconditions: preconditions) {
            let toolMessage = try persistence.appendMessage(
                threadID: threadID,
                runID: runID,
                role: .tool,
                content: ToolResultMessageFormatter.blocked(call: call, reason: pathReason),
                now: clock()
            )
            try emitter.emit(.messageAppended(runID: runID, messageID: toolMessage.id, role: .tool), runID: runID)
            try emitter.emit(.status(runID: runID, message: "A filesystem path looked inconsistent with the request. Asking the model to correct the target path."), runID: runID)
            return .retryableFailure
        }

        let toolCall = try persistence.recordToolCall(runID: runID, toolName: tool.name, arguments: call.arguments, now: clock())

        if let shellPolicyViolation = shellPolicyViolation(for: call) {
            let toolMessage = try persistence.appendMessage(
                threadID: threadID,
                runID: runID,
                role: .tool,
                content: ToolResultMessageFormatter.blocked(call: call, reason: shellPolicyViolation),
                now: clock()
            )
            try emitter.emit(.messageAppended(runID: runID, messageID: toolMessage.id, role: .tool), runID: runID)
            try persistence.finishToolCall(toolCallID: toolCall.id, status: "blocked", output: shellPolicyViolation, finishedAt: clock())
            try emitter.emit(.toolCallFinished(runID: runID, toolCallID: toolCall.id, success: false, summary: shellPolicyViolation), runID: runID)
            throw AshexError.shell(shellPolicyViolation)
        }

        let policyDrivenApprovalRequest = shellApprovalRequest(for: call, runID: runID)

        if let approvalRequest = policyDrivenApprovalRequest ?? approvalRequest(for: tool, call: call, runID: runID),
           approvalPolicy.mode == .guarded {
            try emitter.emit(.approvalRequested(
                runID: runID,
                toolName: tool.name,
                summary: approvalRequest.summary,
                reason: approvalRequest.reason,
                risk: approvalRequest.risk
            ), runID: runID)

            let decision = await approvalPolicy.evaluate(approvalRequest)
            try emitter.emit(.approvalResolved(
                runID: runID,
                toolName: tool.name,
                allowed: decision.allowed,
                reason: decision.reason
            ), runID: runID)

            guard decision.allowed else {
                try persistence.finishToolCall(toolCallID: toolCall.id, status: "denied", output: decision.reason, finishedAt: clock())
                let toolMessage = try persistence.appendMessage(
                    threadID: threadID,
                    runID: runID,
                    role: .tool,
                    content: ToolResultMessageFormatter.denied(call: call, reason: decision.reason),
                    now: clock()
                )
                try emitter.emit(.messageAppended(runID: runID, messageID: toolMessage.id, role: .tool), runID: runID)
                throw AshexError.approvalDenied("Execution denied for \(tool.name): \(decision.reason)")
            }
        }

        try emitter.emit(.toolCallStarted(runID: runID, toolCallID: toolCall.id, toolName: tool.name, arguments: call.arguments), runID: runID)

        let toolContext = ToolContext(
            runID: runID,
            attachments: attachments,
            emit: { event in
                var payload = event.payload
                if case .toolOutput(_, _, let stream, let chunk) = payload {
                    payload = .toolOutput(runID: runID, toolCallID: toolCall.id, stream: stream, chunk: chunk)
                }
                try? emitter.emit(payload, runID: runID)
            },
            cancellation: cancellation
        )

        do {
            let result = try await tool.execute(arguments: call.arguments, context: toolContext)
            let text = result.displayText
            let metadata = metadata(for: tool, call: call, result: result)
            let toolMessage = try persistence.appendMessage(
                threadID: threadID,
                runID: runID,
                role: .tool,
                content: ToolResultMessageFormatter.completed(call: call, result: result),
                now: clock()
            )
            try emitter.emit(.messageAppended(runID: runID, messageID: toolMessage.id, role: .tool), runID: runID)
            try persistence.finishToolCall(toolCallID: toolCall.id, status: "completed", output: text, finishedAt: clock())
            try emitter.emit(.toolCallFinished(runID: runID, toolCallID: toolCall.id, success: true, summary: text), runID: runID)
            return .completed(output: text, safeToReuse: AgentRuntime.isSafeRepeatedToolCall(toolName: tool.name, arguments: call.arguments), metadata: metadata)
        } catch {
            let message = error.localizedDescription
            let toolMessage = try persistence.appendMessage(
                threadID: threadID,
                runID: runID,
                role: .tool,
                content: ToolResultMessageFormatter.failure(call: call, error: message),
                now: clock()
            )
            try emitter.emit(.messageAppended(runID: runID, messageID: toolMessage.id, role: .tool), runID: runID)
            try persistence.finishToolCall(toolCallID: toolCall.id, status: "failed", output: message, finishedAt: clock())
            try emitter.emit(.toolCallFinished(runID: runID, toolCallID: toolCall.id, success: false, summary: message), runID: runID)
            if AgentRuntime.shouldRetryToolRequest(after: error) {
                try emitter.emit(.status(runID: runID, message: "Repairing malformed tool request and asking the model to try again"), runID: runID)
                return .retryableFailure
            }
            throw error
        }
    }

    private func handleRecoverableToolRequestError(
        _ error: Error,
        threadID: UUID,
        runID: UUID,
        emitter: EventEmitter
    ) async throws -> Bool {
        guard AgentRuntime.shouldRetryToolRequest(after: error) else {
            return false
        }

        let toolMessage = try persistence.appendMessage(
            threadID: threadID,
            runID: runID,
            role: .tool,
            content: ToolResultMessageFormatter.failure(
                call: .init(toolName: "unknown", arguments: [:]),
                error: error.localizedDescription
            ),
            now: clock()
        )
        try emitter.emit(.messageAppended(runID: runID, messageID: toolMessage.id, role: .tool), runID: runID)
        try emitter.emit(.status(runID: runID, message: "Model requested an invalid tool action. Asking for a corrected tool call."), runID: runID)
        return true
    }

    private func shellPolicyViolation(for call: ToolCallRequest) -> String? {
        guard call.toolName == "shell",
              let command = call.arguments["command"]?.stringValue else {
            return nil
        }

        guard let shellExecutionPolicy else { return nil }

        switch shellExecutionPolicy.assess(command: command) {
        case .allow:
            return nil
        case .requireApproval(let message):
            guard approvalPolicy.mode != .guarded else { return nil }
            return "Tool error: \(message) Run Ashex in guarded approval mode to approve it interactively, or add the command prefix to ashex.config.json."
        case .deny(let message):
            return "Tool error: \(message)"
        }
    }

    private func shellApprovalRequest(for call: ToolCallRequest, runID: UUID) -> ApprovalRequest? {
        guard call.toolName == "shell",
              let command = call.arguments["command"]?.stringValue,
              let shellExecutionPolicy else {
            return nil
        }

        guard case .requireApproval(let message) = shellExecutionPolicy.assess(command: command) else {
            return nil
        }

        return ApprovalRequest(
            runID: runID,
            toolName: "shell",
            arguments: call.arguments,
            summary: "Shell command outside config allow rules",
            reason: "\(command)\n\(message)",
            risk: .medium
        )
    }

    private func inspectBeforeMutateViolation(for call: ToolCallRequest, tool: any Tool, preconditions: ToolExecutionPreconditions) -> String? {
        if preconditions.phase != .mutation, isMutation(call: call, tool: tool) {
            return "Tool error: the current workflow phase is \(preconditions.phase.rawValue). Mutating actions are only allowed during the implementation phase. Inspect, plan, or validate first."
        }
        guard isMutation(call: call, tool: tool), !preconditions.hasPriorInspection else { return nil }
        if isExplicitNewPathCreation(call: call) {
            return nil
        }
        return "Tool error: inspect-before-mutate policy requires reading or searching relevant files before making changes. Inspect the target files or repository state first, then retry the mutation."
    }

    private func filesystemPathIntentViolation(for call: ToolCallRequest, preconditions: ToolExecutionPreconditions) -> String? {
        guard call.toolName == "filesystem",
              let operation = call.arguments["operation"]?.stringValue else {
            return nil
        }

        if operation == "create_directory",
           let path = call.arguments["path"]?.stringValue,
           Self.pathLooksLikeFile(path) {
            return "Tool error: '\(path)' looks like a file path, not a directory. Create its parent folder if needed, then use filesystem.write_text_file with path '\(path)' for file contents."
        }

        guard ["write_text_file", "replace_in_file", "apply_patch"].contains(operation),
              let path = call.arguments["path"]?.stringValue,
              Self.pathLooksLikeFile(path),
              let targetDirectory = Self.requestedNestedDirectory(in: preconditions.userRequest) else {
            return nil
        }

        guard !Self.path(path, includesDirectoryComponent: targetDirectory) else {
            return nil
        }

        return "Tool error: the user request names '\(targetDirectory)' as the target folder, but this write targets '\(path)' outside that folder. Write the file under '\(targetDirectory)/...' unless the user explicitly asks for a root-level file."
    }

    private static func path(_ path: String, includesDirectoryComponent targetDirectory: String) -> Bool {
        let target = targetDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        let components = path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)
        return components.contains(target)
    }

    private static func pathLooksLikeFile(_ path: String) -> Bool {
        let lastComponent = NSString(string: path).lastPathComponent
        guard !lastComponent.hasPrefix(".") else { return false }
        let ext = NSString(string: lastComponent).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return fileLikeExtensions.contains(ext)
    }

    private static let fileLikeExtensions: Set<String> = [
        "bash", "c", "cc", "cpp", "cs", "css", "csv", "env", "gif", "go", "h", "hpp",
        "htm", "html", "java", "jpeg", "jpg", "js", "json", "jsx", "kt", "m", "md",
        "mm", "pdf", "php", "plist", "png", "py", "rb", "rs", "scss", "sh", "svg",
        "swift", "toml", "ts", "tsx", "txt", "webp", "xcstrings", "xml", "yaml",
        "yml", "zsh"
    ]

    private static func requestedNestedDirectory(in request: String) -> String? {
        let lowered = request.lowercased()
        guard lowered.contains("inside")
            || lowered.contains("in that")
            || lowered.contains("into that")
            || lowered.contains("there")
            || lowered.contains("here")
            || lowered.contains("html")
            || lowered.contains("css")
            || lowered.contains("style sheet")
            || lowered.contains("stylesheet")
        else {
            return nil
        }

        let patterns = [
            #"(?i)\b(?:folder|directory)\s+(?:called|named)\s+['"]?([A-Za-z0-9._-]+)['"]?"#,
            #"(?i)\b(?:create|make)\s+(?:a\s+|an\s+)?['"]?([A-Za-z0-9._-]+)['"]?\s+(?:folder|directory)\b"#,
            #"(?i)\b(?:inside|in|under)\s+(?:the\s+)?['"]?([A-Za-z0-9._-]+)['"]?\s+(?:folder|directory)\b"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(request.startIndex..<request.endIndex, in: request)
            guard let match = regex.firstMatch(in: request, range: range),
                  match.numberOfRanges > 1,
                  let capture = Range(match.range(at: 1), in: request) else {
                continue
            }
            let candidate = String(request[capture]).trimmingCharacters(in: CharacterSet(charactersIn: "'\"` "))
            if isPlausibleDirectoryName(candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func isPlausibleDirectoryName(_ name: String) -> Bool {
        guard !name.isEmpty,
              !name.contains("/"),
              !name.contains("\\"),
              !pathLooksLikeFile(name) else {
            return false
        }
        return true
    }

    private func isExplicitNewPathCreation(call: ToolCallRequest) -> Bool {
        guard call.toolName == "filesystem" else { return false }
        switch call.arguments["operation"]?.stringValue {
        case "create_directory":
            return call.arguments["path"]?.stringValue?.isEmpty == false
        case "write_text_file":
            return call.arguments["path"]?.stringValue?.isEmpty == false
                && call.arguments["content"]?.stringValue != nil
                && call.arguments["create_directories"] == .bool(true)
        default:
            return false
        }
    }

    private func isMutation(call: ToolCallRequest, tool: any Tool) -> Bool {
        if let operation = tool.contract.operation(for: call.arguments) {
            return operation.mutatesWorkspace
        }

        switch call.toolName {
        case "filesystem":
            let operation = call.arguments["operation"]?.stringValue ?? ""
            return ["write_text_file", "replace_in_file", "apply_patch", "create_directory", "delete_path", "move_path", "copy_path"].contains(operation)
        case "build":
            return false
        case "shell":
            let command = call.arguments["command"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ShellExecutionPolicy.isMutatingShellCommand(command)
        default:
            return false
        }
    }

    private func metadata(for tool: any Tool, call: ToolCallRequest, result: ToolContent) -> ToolExecutionMetadata {
        let contractMetadata: ToolExecutionMetadata?
        if let operation = tool.contract.operation(for: call.arguments) {
            let inspectedPaths = resolveArgumentValues(keys: operation.inspectedPathArguments, from: call.arguments)
            let changedPaths = resolveArgumentValues(keys: operation.changedPathArguments, from: call.arguments)
            if !operation.validationArtifacts.isEmpty || !inspectedPaths.isEmpty || !changedPaths.isEmpty || operation.progressSummary != nil {
                contractMetadata = .init(
                    inspectedPaths: inspectedPaths,
                    changedPaths: changedPaths,
                    validationArtifacts: operation.validationArtifacts,
                    summary: operation.progressSummary ?? result.displayText,
                    representsProgress: true
                )
            } else {
                contractMetadata = nil
            }
        } else {
            contractMetadata = nil
        }

        switch call.toolName {
        case "filesystem":
            return filesystemMetadata(call: call, result: result)
        case "git":
            let operation = call.arguments["operation"]?.stringValue ?? "git"
            let mutatingOperations: Set<String> = [
                "init", "add", "add_all", "commit", "create_branch", "switch_branch", "switch_new_branch",
                "restore_worktree", "restore_staged", "reset_mixed", "reset_hard", "clean_force",
                "tag", "merge", "rebase", "pull", "push"
            ]
            return .init(
                inspectedPaths: mutatingOperations.contains(operation) ? [] : [".git"],
                changedPaths: mutatingOperations.contains(operation) ? [".git"] : [],
                validationArtifacts: gitValidationArtifacts(operation: operation),
                summary: mutatingOperations.contains(operation) ? "changed git state with \(operation)" : "inspected git \(operation)",
                representsProgress: true
            )
        case "build":
            return buildMetadata(call: call)
        case "shell":
            let command = call.arguments["command"]?.stringValue ?? "shell"
            if ShellExecutionPolicy.isMutatingShellCommand(command) {
                return .init(inspectedPaths: [], changedPaths: ["<shell>"], validationArtifacts: [], summary: "executed mutating shell command", representsProgress: true)
            }
            return .init(inspectedPaths: ["<shell>"], changedPaths: [], validationArtifacts: shellValidationArtifacts(command: command), summary: "inspected via shell", representsProgress: true)
        default:
            return contractMetadata ?? .init(inspectedPaths: [], changedPaths: [], validationArtifacts: [], summary: result.displayText, representsProgress: false)
        }
    }

    private func filesystemMetadata(call: ToolCallRequest, result: ToolContent) -> ToolExecutionMetadata {
        let operation = call.arguments["operation"]?.stringValue ?? "unknown"
        let path = call.arguments["path"]?.stringValue
        let sourcePath = call.arguments["source_path"]?.stringValue
        let destinationPath = call.arguments["destination_path"]?.stringValue

        switch operation {
        case "read_text_file", "list_directory", "find_files", "search_text", "file_info":
            let inspected = [path].compactMap { $0 }
            let validationArtifacts = operation == "read_text_file" || operation == "file_info" ? inspected : []
            return .init(inspectedPaths: inspected, changedPaths: [], validationArtifacts: validationArtifacts, summary: "inspected \(inspected.joined(separator: ", "))", representsProgress: true)
        case "write_text_file", "replace_in_file", "apply_patch", "create_directory", "delete_path":
            if isUnchangedMutationResult(result) {
                return .init(inspectedPaths: [], changedPaths: [], validationArtifacts: [], summary: "no workspace change from \(operation)", representsProgress: false)
            }
            let changed = [path].compactMap { $0 }
            return .init(inspectedPaths: [], changedPaths: changed, validationArtifacts: [], summary: "changed \(changed.joined(separator: ", "))", representsProgress: true)
        case "move_path", "copy_path":
            let changed = [sourcePath, destinationPath].compactMap { $0 }
            return .init(inspectedPaths: [], changedPaths: changed, validationArtifacts: [], summary: "changed \(changed.joined(separator: ", "))", representsProgress: true)
        default:
            return .init(inspectedPaths: [], changedPaths: [], validationArtifacts: [], summary: result.displayText, representsProgress: false)
        }
    }

    private func isUnchangedMutationResult(_ result: ToolContent) -> Bool {
        guard case .structured(let value) = result,
              let status = value.objectValue?["status"]?.stringValue?.lowercased() else {
            return false
        }
        return ["unchanged", "existing", "noop", "no_op"].contains(status)
    }

    private func gitValidationArtifacts(operation: String) -> [String] {
        switch operation {
        case "status", "diff_unstaged", "diff_staged", "show_commit",
             "add", "add_all", "commit", "create_branch", "switch_branch", "switch_new_branch",
             "restore_worktree", "restore_staged", "reset_mixed", "reset_hard", "clean_force",
             "tag", "merge", "rebase", "pull", "push":
            return ["<git>"]
        default:
            return []
        }
    }

    private func shellValidationArtifacts(command: String) -> [String] {
        let lowered = command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let validationPrefixes = [
            "swift test", "swift build", "xcodebuild", "pytest", "npm test", "pnpm test",
            "yarn test", "cargo test", "go test", "bundle exec rspec", "gradle test", "make test"
        ]
        return validationPrefixes.contains(where: lowered.hasPrefix) ? ["<check>"] : []
    }

    private func buildMetadata(call: ToolCallRequest) -> ToolExecutionMetadata {
        let operation = call.arguments["operation"]?.stringValue ?? "build"
        let summary: String
        switch operation {
        case "swift_build":
            summary = "validated with swift build"
        case "swift_test":
            summary = "validated with swift test"
        case "xcodebuild_list":
            summary = "inspected xcodebuild targets"
        case "xcodebuild_build":
            summary = "validated with xcodebuild build"
        case "xcodebuild_test":
            summary = "validated with xcodebuild test"
        default:
            summary = "validated with build tool"
        }
        return .init(
            inspectedPaths: operation == "xcodebuild_list" ? ["<build>"] : [],
            changedPaths: [],
            validationArtifacts: ["<build>"],
            summary: summary,
            representsProgress: true
        )
    }

    private func approvalRequest(for tool: any Tool, call: ToolCallRequest, runID: UUID) -> ApprovalRequest? {
        if let operation = tool.contract.operation(for: call.arguments),
           let approval = operation.approval {
            return ApprovalRequest(
                runID: runID,
                toolName: tool.name,
                arguments: call.arguments,
                summary: approval.summary,
                reason: renderApprovalReason(template: approval.reasonTemplate, arguments: call.arguments),
                risk: approval.risk
            )
        }

        return ApprovalClassifier.requestForTool(runID: runID, toolName: tool.name, arguments: call.arguments)
    }

    private func resolveArgumentValues(keys: [String], from arguments: JSONObject) -> [String] {
        keys.compactMap { arguments[$0]?.stringValue }.filter { !$0.isEmpty }
    }

    private func renderApprovalReason(template: String?, arguments: JSONObject) -> String {
        guard let template, !template.isEmpty else {
            return JSONValue.object(arguments).prettyPrinted
        }

        var rendered = template
        for (key, value) in arguments {
            rendered = rendered.replacingOccurrences(of: "{{\(key)}}", with: value.stringValue ?? value.prettyPrinted)
        }
        rendered = rendered.replacingOccurrences(
            of: #"\{\{[^}]+\}\}"#,
            with: "",
            options: .regularExpression
        )
        rendered = rendered.replacingOccurrences(
            of: #"\s+([,.;:])"#,
            with: "$1",
            options: .regularExpression
        )
        rendered = rendered.replacingOccurrences(
            of: #"\s{2,}"#,
            with: " ",
            options: .regularExpression
        )
        rendered = rendered.replacingOccurrences(
            of: #"\s*@\s*$"#,
            with: "",
            options: .regularExpression
        )
        return rendered.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
