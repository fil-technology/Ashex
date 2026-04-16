import Foundation

public enum PromptSectionKind: String, Sendable {
    case cachedStatic
    case sessionDynamic
}

public struct PromptSection: Sendable {
    public let title: String
    public let body: String
    public let kind: PromptSectionKind

    public init(title: String, body: String, kind: PromptSectionKind) {
        self.title = title
        self.body = body
        self.kind = kind
    }
}

public struct PreparedModelContext: Sendable {
    public struct Compaction: Sendable {
        public let droppedMessages: [MessageRecord]
        public let summary: String
        public let deduplicatedToolSummaries: Int
        public let estimatedSavedTokenCount: Int

        public init(droppedMessages: [MessageRecord], summary: String, deduplicatedToolSummaries: Int, estimatedSavedTokenCount: Int) {
            self.droppedMessages = droppedMessages
            self.summary = summary
            self.deduplicatedToolSummaries = deduplicatedToolSummaries
            self.estimatedSavedTokenCount = estimatedSavedTokenCount
        }
    }

    public let base: ModelContext
    public let retainedMessages: [MessageRecord]
    public let droppedMessageCount: Int
    public let clippedMessageCount: Int
    public let estimatedTokenCount: Int
    public let estimatedContextWindow: Int
    public let compaction: Compaction?

    public init(
        base: ModelContext,
        retainedMessages: [MessageRecord],
        droppedMessageCount: Int,
        clippedMessageCount: Int,
        estimatedTokenCount: Int,
        estimatedContextWindow: Int,
        compaction: Compaction?
    ) {
        self.base = base
        self.retainedMessages = retainedMessages
        self.droppedMessageCount = droppedMessageCount
        self.clippedMessageCount = clippedMessageCount
        self.estimatedTokenCount = estimatedTokenCount
        self.estimatedContextWindow = estimatedContextWindow
        self.compaction = compaction
    }
}

public struct PromptAssembly: Sendable {
    public let systemPrompt: String
    public let userPrompt: String
    public let sections: [PromptSection]
    public let preparedContext: PreparedModelContext

    public init(systemPrompt: String, userPrompt: String, sections: [PromptSection], preparedContext: PreparedModelContext) {
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.sections = sections
        self.preparedContext = preparedContext
    }

    public var combinedPrompt: String {
        ([systemPrompt, userPrompt].filter { !$0.isEmpty }).joined(separator: "\n\n")
    }
}

public enum ContextManager {
    public static func prepare(
        context: ModelContext,
        provider: String,
        model: String
    ) -> PreparedModelContext {
        let contextWindow = estimatedContextWindow(provider: provider, model: model)
        let softBudget = max(Int(Double(contextWindow) * 0.55), 2_000)

        var retained: [MessageRecord] = []
        var dropped: [MessageRecord] = []
        var runningEstimate = 0

        for message in context.messages.reversed() {
            let messageCost = estimateTokens(in: message.content) + 12
            if !retained.isEmpty && runningEstimate + messageCost > softBudget {
                dropped.append(message)
                break
            }
            retained.append(message)
            runningEstimate += messageCost
        }

        var stopDropping = false
        for message in context.messages.dropLast(retained.count).reversed() where !stopDropping {
            if dropped.contains(where: { $0.id == message.id }) { continue }
            dropped.append(message)
            if dropped.count == context.messages.count - retained.count {
                stopDropping = true
            }
        }

        retained.reverse()
        dropped.reverse()
        let droppedCount = dropped.count
        let clippedRetained = clipOversizedToolMessages(in: retained)
        let clippedCount = zip(retained, clippedRetained).reduce(0) { partial, pair in
            partial + (pair.0.content == pair.1.content ? 0 : 1)
        }
        let compactionSummary = dropped.isEmpty ? nil : buildCompactionSummary(from: dropped)
        let compaction: PreparedModelContext.Compaction? = compactionSummary.map {
            let droppedTokenEstimate = dropped.reduce(into: 0) { partial, message in
                partial += estimateTokens(in: message.content) + 12
            }
            let summaryTokenEstimate = estimateTokens(in: $0.summary) + 24
            return PreparedModelContext.Compaction(
                droppedMessages: dropped,
                summary: $0.summary,
                deduplicatedToolSummaries: $0.deduplicatedToolSummaries,
                estimatedSavedTokenCount: max(droppedTokenEstimate - summaryTokenEstimate, 0)
            )
        }
        let compactionCost = compaction.map { estimateTokens(in: $0.summary) + 24 } ?? 0

        return PreparedModelContext(
            base: context,
            retainedMessages: clippedRetained.isEmpty ? context.messages.suffix(1) : clippedRetained,
            droppedMessageCount: droppedCount,
            clippedMessageCount: clippedCount,
            estimatedTokenCount: runningEstimate + compactionCost,
            estimatedContextWindow: contextWindow,
            compaction: compaction
        )
    }

    private static func estimateTokens(in text: String) -> Int {
        max(Int(ceil(Double(text.count) / 4.0)), 1)
    }

    private static func estimatedContextWindow(provider: String, model: String) -> Int {
        let lowered = model.lowercased()
        switch provider {
        case "openai":
            if lowered.contains("gpt-5") { return 400_000 }
            if lowered.contains("gpt-4.1") { return 1_000_000 }
            if lowered.contains("gpt-4o") { return 128_000 }
            return 128_000
        case "anthropic":
            if lowered.contains("claude") { return 200_000 }
            return 200_000
        case "ollama":
            if lowered.contains("llama3") || lowered.contains("qwen") || lowered.contains("mistral") || lowered.contains("gemma") {
                return 128_000
            }
            return 32_000
        default:
            return 8_000
        }
    }

    private static func buildCompactionSummary(from messages: [MessageRecord]) -> (summary: String, deduplicatedToolSummaries: Int) {
        let userPoints = extractPoints(from: messages, role: .user, limit: 3)
        let stepPoints = extractStepResultPoints(from: messages, limit: 4)
        let toolSummary = extractToolOutcomePoints(from: messages, limit: 4)
        let toolPoints = toolSummary.points
        let assistantPoints = extractGeneralAssistantPoints(from: messages, excluding: Set(stepPoints), limit: 2)

        var lines = ["Compacted earlier conversation summary:"]
        lines.append("- Omitted \(messages.count) earlier messages from the active turn context.")
        if toolSummary.deduplicatedCount > 0 {
            lines.append("- Deduplicated \(toolSummary.deduplicatedCount) repeated tool-read summaries while compacting older history.")
        }

        if !userPoints.isEmpty {
            lines.append("- Earlier user requests:")
            lines.append(contentsOf: userPoints.map { "  - \($0)" })
        }
        if !stepPoints.isEmpty {
            lines.append("- Earlier completed task steps:")
            lines.append(contentsOf: stepPoints.map { "  - \($0)" })
        }
        if !toolPoints.isEmpty {
            lines.append("- Earlier tool findings:")
            lines.append(contentsOf: toolPoints.map { "  - \($0)" })
        }
        if !assistantPoints.isEmpty {
            lines.append("- Earlier assistant conclusions:")
            lines.append(contentsOf: assistantPoints.map { "  - \($0)" })
        }

        return (lines.joined(separator: "\n"), toolSummary.deduplicatedCount)
    }

    private static func extractPoints(from messages: [MessageRecord], role: MessageRole, limit: Int) -> [String] {
        messages
            .filter { $0.role == role }
            .suffix(limit)
            .map { normalizeSummarySnippet($0.content) }
            .filter { !$0.isEmpty }
    }

    private static func extractStepResultPoints(from messages: [MessageRecord], limit: Int) -> [String] {
        messages
            .filter { $0.role == .assistant && $0.content.hasPrefix("Step ") && $0.content.contains(" result:") }
            .suffix(limit)
            .map { message in
                let parts = message.content.components(separatedBy: "\n")
                let header = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Step result"
                let detail = parts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedDetail = normalizeSummarySnippet(detail)
                return normalizedDetail.isEmpty ? header : "\(header) \(normalizedDetail)"
            }
            .filter { !$0.isEmpty }
    }

    private static func extractToolOutcomePoints(from messages: [MessageRecord], limit: Int) -> (points: [String], deduplicatedCount: Int) {
        let normalized = messages
            .filter { $0.role == .tool }
            .suffix(limit)
            .map { normalizeToolSnippet($0.content) }
            .filter { !$0.isEmpty }

        var seen: Set<String> = []
        var unique: [String] = []
        var deduplicatedCount = 0
        for point in normalized {
            if seen.insert(point).inserted {
                unique.append(point)
            } else {
                deduplicatedCount += 1
            }
        }
        return (unique, deduplicatedCount)
    }

    private static func extractGeneralAssistantPoints(from messages: [MessageRecord], excluding excluded: Set<String>, limit: Int) -> [String] {
        messages
            .filter { $0.role == .assistant && !$0.content.hasPrefix("Step ") }
            .suffix(limit + 2)
            .map { normalizeSummarySnippet($0.content) }
            .filter { !$0.isEmpty && !excluded.contains($0) }
            .suffix(limit)
    }

    private static func normalizeSummarySnippet(_ content: String) -> String {
        let firstMeaningfulLine = content
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? content.trimmingCharacters(in: .whitespacesAndNewlines)

        if firstMeaningfulLine.count <= 180 {
            return firstMeaningfulLine
        }
        let endIndex = firstMeaningfulLine.index(firstMeaningfulLine.startIndex, offsetBy: 177)
        return String(firstMeaningfulLine[..<endIndex]) + "..."
    }

    private static func normalizeToolSnippet(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
           let value = try? JSONDecoder().decode(JSONValue.self, from: data),
           case .object(let object) = value {
            if let path = object["path"]?.stringValue, let entries = object["entries"]?.arrayValue {
                return "Listed \(path) with \(entries.count) entries"
            }
            if let path = object["path"]?.stringValue, let query = object["query"]?.stringValue, let matches = object["matches"]?.arrayValue {
                return "Searched \(path) for \"\(query)\" and found \(matches.count) matches"
            }
            if let path = object["path"]?.stringValue, let bytes = object["bytes_written"]?.intValue {
                return "Edited \(path) (\(bytes) bytes written)"
            }
        }

        return normalizeSummarySnippet(trimmed)
    }

    private static func clipOversizedToolMessages(in messages: [MessageRecord]) -> [MessageRecord] {
        messages.map { message in
            guard message.role == .tool else { return message }
            let clipped = clipToolContent(message.content)
            guard clipped != message.content else { return message }
            return MessageRecord(
                id: message.id,
                threadID: message.threadID,
                runID: message.runID,
                role: message.role,
                content: clipped,
                createdAt: message.createdAt
            )
        }
    }

    private static func clipToolContent(_ content: String) -> String {
        let maxCharacters = 4_000
        let maxLines = 80
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard content.count > maxCharacters || lines.count > maxLines else {
            return content
        }

        let keptLines = Array(lines.prefix(maxLines))
        let clippedBody = keptLines.joined(separator: "\n")
        let clippedCharacters = max(content.count - clippedBody.count, 0)
        return """
        [tool-output clipped for prompt context]
        kept \(keptLines.count) of \(lines.count) lines and approximately \(clippedCharacters) trailing characters.
        \(clippedBody)
        """
    }
}

public enum PromptBuilder {
    public static func build(
        for context: ModelContext,
        provider: String,
        model: String
    ) -> PromptAssembly {
        let prepared = ContextManager.prepare(context: context, provider: provider, model: model)
        let toolBlock = prepared.base.availableTools
            .map { tool in
                let operationNames = tool.operations.map(\.name)
                let operationSuffix = operationNames.isEmpty ? "" : " [ops: \(operationNames.joined(separator: ", "))]"
                let kindSuffix = tool.kind == .installable ? " (installable \(tool.category))" : " (\(tool.category))"
                return "- \(tool.name)\(kindSuffix): \(tool.description)\(operationSuffix)"
            }
            .joined(separator: "\n")

        let transcript = prepared.retainedMessages.map { message in
            let role = message.role.rawValue.uppercased()
            return "[\(role)]\n\(message.content)"
        }.joined(separator: "\n\n")
        let workspaceSnapshotBlock = renderWorkspaceSnapshot(prepared.base.workspaceSnapshot)
        let workingMemoryBlock = renderWorkingMemory(prepared.base.workingMemory)

        let staticRules = PromptSection(
            title: "Core Instructions",
            body: """
            You are Ashex, a local single-agent runtime.

            Decide the next action for the current loop iteration.

            You must return exactly one JSON object matching the provided schema:
            - If the task is complete, return `type = "final_answer"` and fill `final_answer`.
            - If a tool is needed, return `type = "tool_call"` and fill `tool_name` and `arguments`.

            Rules:
            - Use only the tools listed below.
            - Never invent tools.
            - Do not call tools for greetings, casual chat, or questions that can be answered without workspace state.
            - Only call filesystem, git, or shell when the user is asking about files, wants you to inspect project state, or explicitly asks you to run something.
            - When the user asks about a GitHub or other remote repository URL, prefer `github_repo` for read-only inspection before using local workspace tools.
            - For coding or editing requests, prefer this workflow: explore relevant files first, plan briefly, then mutate, then validate, then summarize.
            - During exploration, bias toward `find_files`, `search_text`, `list_directory`, `file_info`, `read_text_file`, and read-only git inspection before changing anything.
            - During validation, prefer checking changed files, `git diff`, focused reads, and relevant test/build commands before concluding.
            - When a patch plan is present in working memory, prefer staying within that planned file set unless new evidence justifies expanding it.
            - If a tool result already contains the needed information, prefer answering directly.
            - Keep final answers concise and useful.
            - Tool arguments must be valid JSON objects.
            - When returning a tool_call, include only the argument keys needed for that tool call.
            """,
            kind: .cachedStatic
        )

        let toolRules = PromptSection(
            title: "Tool Contract",
            body: """
            For filesystem tool calls, always use the `operation` field with one of:
            `read_text_file`, `write_text_file`, `replace_in_file`, `apply_patch`, `list_directory`, `create_directory`, `delete_path`, `move_path`, `copy_path`, `file_info`, `find_files`, `search_text`.
            For git tool calls, always use the `operation` field with one of:
            `status`, `current_branch`, `diff_unstaged`, `diff_staged`, `log`, `show_commit`, `init`, `add`, `add_all`, `commit`, `create_branch`, `switch_branch`, `switch_new_branch`, `restore_worktree`, `restore_staged`, `reset_mixed`, `reset_hard`, `clean_force`, `tag`, `merge`, `rebase`, `pull`, `push`.
            For github_repo tool calls, always use the `operation` field with one of:
            `inspect_repository`, `list_files`, `read_file`, `search_text`.
            For shell tool calls, always send `command` and optional `timeout_seconds`.
            For installable tools, use the tool's listed operations and argument names exactly as shown in the available tools block.

            Prefer `apply_patch` when multiple targeted edits are needed in the same file. Use `edits` as an array of objects with `old_text`, `new_text`, and `replace_all`.

            Canonical tool-call examples:
            {"type":"tool_call","final_answer":null,"tool_name":"filesystem","arguments":{"operation":"list_directory","path":"."}}
            {"type":"tool_call","final_answer":null,"tool_name":"filesystem","arguments":{"operation":"read_text_file","path":"README.md"}}
            {"type":"tool_call","final_answer":null,"tool_name":"filesystem","arguments":{"operation":"search_text","path":"Sources","query":"ApprovalPolicy","max_results":20}}
            {"type":"tool_call","final_answer":null,"tool_name":"filesystem","arguments":{"operation":"apply_patch","path":"README.md","edits":[{"old_text":"old","new_text":"new","replace_all":false}]}}
            {"type":"tool_call","final_answer":null,"tool_name":"git","arguments":{"operation":"status","limit":null,"commit":null}}
            {"type":"tool_call","final_answer":null,"tool_name":"github_repo","arguments":{"operation":"inspect_repository","repository_url":"https://github.com/owner/repo","ref":"main"}}
            {"type":"tool_call","final_answer":null,"tool_name":"github_repo","arguments":{"operation":"read_file","repository_url":"https://github.com/owner/repo","ref":"main","path":"README.md"}}
            {"type":"tool_call","final_answer":null,"tool_name":"git","arguments":{"operation":"add","paths":["README.md","Sources/App.swift"]}}
            {"type":"tool_call","final_answer":null,"tool_name":"git","arguments":{"operation":"commit","message":"Initial project setup","amend":false,"allow_empty":false}}
            {"type":"tool_call","final_answer":null,"tool_name":"shell","arguments":{"command":"ls -la","timeout_seconds":30}}
            """,
            kind: .cachedStatic
        )

        let dynamicContext = PromptSection(
            title: "Session Context",
            body: """
            Available tools:
            \(toolBlock)

            Workspace snapshot:
            \(workspaceSnapshotBlock)

            Working memory:
            \(workingMemoryBlock)

            Context window estimate: \(prepared.estimatedTokenCount) / \(prepared.estimatedContextWindow) tokens kept for this turn.
            \(prepared.droppedMessageCount > 0 ? "Older conversation was trimmed for this turn: \(prepared.droppedMessageCount) earlier messages omitted." : "Full recent conversation is included for this turn.")
            \(prepared.compaction.map { "\n\($0.summary)\n" } ?? "")

            Conversation transcript:
            \(transcript)
            """,
            kind: .sessionDynamic
        )

        let sections = [staticRules, toolRules, dynamicContext]
        let systemPrompt = sections
            .filter { $0.kind == .cachedStatic }
            .map(sectionText)
            .joined(separator: "\n\n")
        let userPrompt = sections
            .filter { $0.kind == .sessionDynamic }
            .map(sectionText)
            .joined(separator: "\n\n")

        return PromptAssembly(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            sections: sections,
            preparedContext: prepared
        )
    }

    private static func sectionText(_ section: PromptSection) -> String {
        "\(section.title):\n\(section.body)"
    }

    private static func renderWorkspaceSnapshot(_ snapshot: WorkspaceSnapshotRecord?) -> String {
        guard let snapshot else {
            return "No workspace snapshot captured for this run."
        }

        var lines = ["Root: \(snapshot.workspaceRootPath)"]
        if !snapshot.topLevelEntries.isEmpty {
            lines.append("Top level: \(snapshot.topLevelEntries.joined(separator: ", "))")
        }
        if !snapshot.instructionFiles.isEmpty {
            lines.append("Instruction files: \(snapshot.instructionFiles.joined(separator: ", "))")
        }
        if !snapshot.projectMarkers.isEmpty {
            lines.append("Project markers: \(snapshot.projectMarkers.joined(separator: ", "))")
        }
        if !snapshot.sourceRoots.isEmpty {
            lines.append("Source roots: \(snapshot.sourceRoots.joined(separator: ", "))")
        }
        if !snapshot.testRoots.isEmpty {
            lines.append("Test roots: \(snapshot.testRoots.joined(separator: ", "))")
        }
        if let branch = snapshot.gitBranch {
            lines.append("Git branch: \(branch)")
        }
        if let status = snapshot.gitStatusSummary, !status.isEmpty {
            let compactStatus = status
                .split(separator: "\n", omittingEmptySubsequences: true)
                .prefix(4)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: " | ")
            lines.append("Git status summary: \(compactStatus)")
        }
        return lines.joined(separator: "\n")
    }

    private static func renderWorkingMemory(_ memory: WorkingMemoryRecord?) -> String {
        guard let memory else {
            return "No distilled working memory yet for this run."
        }

        var lines = ["Current task: \(memory.currentTask)"]
        if let phase = memory.currentPhase {
            lines.append("Current phase: \(phase)")
        }
        if !memory.explorationTargets.isEmpty {
            lines.append("Exploration targets: \(memory.explorationTargets.joined(separator: ", "))")
        }
        if !memory.pendingExplorationTargets.isEmpty {
            lines.append("Still worth inspecting: \(memory.pendingExplorationTargets.joined(separator: ", "))")
        }
        if !memory.inspectedPaths.isEmpty {
            lines.append("Inspected paths: \(memory.inspectedPaths.joined(separator: ", "))")
        }
        if !memory.changedPaths.isEmpty {
            lines.append("Changed paths: \(memory.changedPaths.joined(separator: ", "))")
        }
        if !memory.plannedChangeSet.isEmpty {
            lines.append("Planned file set: \(memory.plannedChangeSet.joined(separator: ", "))")
        }
        if !memory.patchObjectives.isEmpty {
            lines.append("Patch objectives: \(memory.patchObjectives.joined(separator: " | "))")
        }
        if !memory.recentFindings.isEmpty {
            lines.append("Recent findings: \(memory.recentFindings.joined(separator: " | "))")
        }
        if !memory.carryForwardNotes.isEmpty {
            lines.append("Carry-forward notes: \(memory.carryForwardNotes.joined(separator: " | "))")
        }
        if !memory.completedStepSummaries.isEmpty {
            lines.append("Completed steps: \(memory.completedStepSummaries.joined(separator: " | "))")
        }
        if !memory.unresolvedItems.isEmpty {
            lines.append("Unresolved items: \(memory.unresolvedItems.joined(separator: " | "))")
        }
        if !memory.validationSuggestions.isEmpty {
            lines.append("Suggested validation: \(memory.validationSuggestions.joined(separator: ", "))")
        }
        if !memory.summary.isEmpty {
            lines.append("Summary: \(memory.summary)")
        }
        return lines.joined(separator: "\n")
    }
}
