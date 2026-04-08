import Foundation

enum ToolExecutionResult: Sendable {
    case completed(output: String, safeToReuse: Bool, metadata: ToolExecutionMetadata)
    case retryableFailure
}

struct ToolExecutionPreconditions: Sendable {
    let hasPriorInspection: Bool
    let phase: PlannedStepPhase
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
    let clock: @Sendable () -> Date

    func execute(
        call: ToolCallRequest,
        threadID: UUID,
        runID: UUID,
        preconditions: ToolExecutionPreconditions,
        cancellation: CancellationToken,
        emitter: EventEmitter
    ) async throws -> ToolExecutionResult {
        if let mutationReason = inspectBeforeMutateViolation(for: call, preconditions: preconditions) {
            let toolMessage = try persistence.appendMessage(threadID: threadID, runID: runID, role: .tool, content: mutationReason, now: clock())
            try emitter.emit(.messageAppended(runID: runID, messageID: toolMessage.id, role: .tool), runID: runID)
            try emitter.emit(.status(runID: runID, message: "Inspect-before-mutate policy blocked a write action. Asking the model to inspect relevant files first."), runID: runID)
            return .retryableFailure
        }

        let tool: any Tool
        do {
            tool = try toolRegistry.tool(named: call.toolName)
        } catch {
            if try await handleRecoverableToolRequestError(error, threadID: threadID, runID: runID, emitter: emitter) {
                return .retryableFailure
            }
            throw error
        }

        let toolCall = try persistence.recordToolCall(runID: runID, toolName: tool.name, arguments: call.arguments, now: clock())

        if let approvalRequest = ApprovalClassifier.requestForTool(runID: runID, toolName: tool.name, arguments: call.arguments),
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
                let toolMessage = try persistence.appendMessage(threadID: threadID, runID: runID, role: .tool, content: "Tool denied: \(decision.reason)", now: clock())
                try emitter.emit(.messageAppended(runID: runID, messageID: toolMessage.id, role: .tool), runID: runID)
                throw AshexError.approvalDenied("Execution denied for \(tool.name): \(decision.reason)")
            }
        }

        try emitter.emit(.toolCallStarted(runID: runID, toolCallID: toolCall.id, toolName: tool.name, arguments: call.arguments), runID: runID)

        let toolContext = ToolContext(
            runID: runID,
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
            let metadata = metadata(for: call, result: result)
            let toolMessage = try persistence.appendMessage(threadID: threadID, runID: runID, role: .tool, content: text, now: clock())
            try emitter.emit(.messageAppended(runID: runID, messageID: toolMessage.id, role: .tool), runID: runID)
            try persistence.finishToolCall(toolCallID: toolCall.id, status: "completed", output: text, finishedAt: clock())
            try emitter.emit(.toolCallFinished(runID: runID, toolCallID: toolCall.id, success: true, summary: text), runID: runID)
            return .completed(output: text, safeToReuse: AgentRuntime.isSafeRepeatedToolCall(toolName: tool.name, arguments: call.arguments), metadata: metadata)
        } catch {
            let message = error.localizedDescription
            let toolMessage = try persistence.appendMessage(threadID: threadID, runID: runID, role: .tool, content: "Tool error: \(message)", now: clock())
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
            content: "Tool error: \(error.localizedDescription)",
            now: clock()
        )
        try emitter.emit(.messageAppended(runID: runID, messageID: toolMessage.id, role: .tool), runID: runID)
        try emitter.emit(.status(runID: runID, message: "Model requested an invalid tool action. Asking for a corrected tool call."), runID: runID)
        return true
    }

    private func inspectBeforeMutateViolation(for call: ToolCallRequest, preconditions: ToolExecutionPreconditions) -> String? {
        if preconditions.phase != .mutation, isMutation(call: call) {
            return "Tool error: the current workflow phase is \(preconditions.phase.rawValue). Mutating actions are only allowed during the implementation phase. Inspect, plan, or validate first."
        }
        guard isMutation(call: call), !preconditions.hasPriorInspection else { return nil }
        return "Tool error: inspect-before-mutate policy requires reading or searching relevant files before making changes. Inspect the target files or repository state first, then retry the mutation."
    }

    private func isMutation(call: ToolCallRequest) -> Bool {
        switch call.toolName {
        case "filesystem":
            let operation = call.arguments["operation"]?.stringValue ?? ""
            return ["write_text_file", "replace_in_file", "apply_patch", "create_directory", "delete_path", "move_path", "copy_path"].contains(operation)
        case "shell":
            let command = call.arguments["command"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return isMutatingShellCommand(command)
        default:
            return false
        }
    }

    private func isMutatingShellCommand(_ command: String) -> Bool {
        let lowered = command.lowercased()
        let prefixes = ["rm ", "mv ", "cp ", "mkdir ", "touch ", "sed -i", "perl -pi", "python ", "python3 ", "node ", "tee ", "echo "]
        if prefixes.contains(where: { lowered.hasPrefix($0) }) {
            return true
        }
        return lowered.contains(" > ") || lowered.contains(">>")
    }

    private func metadata(for call: ToolCallRequest, result: ToolContent) -> ToolExecutionMetadata {
        switch call.toolName {
        case "filesystem":
            return filesystemMetadata(call: call, result: result)
        case "git":
            let operation = call.arguments["operation"]?.stringValue ?? "git"
            return .init(inspectedPaths: [".git"], changedPaths: [], validationArtifacts: gitValidationArtifacts(operation: operation), summary: "inspected git \(operation)", representsProgress: true)
        case "shell":
            let command = call.arguments["command"]?.stringValue ?? "shell"
            if isMutatingShellCommand(command) {
                return .init(inspectedPaths: [], changedPaths: ["<shell>"], validationArtifacts: [], summary: "executed mutating shell command", representsProgress: true)
            }
            return .init(inspectedPaths: ["<shell>"], changedPaths: [], validationArtifacts: shellValidationArtifacts(command: command), summary: "inspected via shell", representsProgress: true)
        default:
            return .init(inspectedPaths: [], changedPaths: [], validationArtifacts: [], summary: result.displayText, representsProgress: false)
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
            let changed = [path].compactMap { $0 }
            return .init(inspectedPaths: [], changedPaths: changed, validationArtifacts: [], summary: "changed \(changed.joined(separator: ", "))", representsProgress: true)
        case "move_path", "copy_path":
            let changed = [sourcePath, destinationPath].compactMap { $0 }
            return .init(inspectedPaths: [], changedPaths: changed, validationArtifacts: [], summary: "changed \(changed.joined(separator: ", "))", representsProgress: true)
        default:
            return .init(inspectedPaths: [], changedPaths: [], validationArtifacts: [], summary: result.displayText, representsProgress: false)
        }
    }

    private func gitValidationArtifacts(operation: String) -> [String] {
        switch operation {
        case "status", "diff_unstaged", "diff_staged", "show_commit":
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
}
