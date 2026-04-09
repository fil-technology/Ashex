import AshexCore
import Foundation
import Testing

private let testShellExecutionPolicy = ShellExecutionPolicy(
    sandbox: .default,
    network: .default,
    shell: ShellCommandPolicy(config: .default)
)

@Test func workspaceGuardRejectsTraversal() throws {
    let root = URL(fileURLWithPath: "/tmp/ashex-tests/root")
    let guardrail = WorkspaceGuard(rootURL: root)

    #expect(throws: Error.self) {
        _ = try guardrail.resolve(path: "../secrets.txt")
    }
}

@Test func taskPlannerClassifiesCodingTaskKinds() {
    #expect(TaskPlanner.classify(prompt: "fix the failing parser bug in ModelAdapter") == .bugFix)
    #expect(TaskPlanner.classify(prompt: "refactor the runtime to simplify compaction") == .refactor)
    #expect(TaskPlanner.classify(prompt: "update README and docs for installation") == .docs)
    #expect(TaskPlanner.classify(prompt: "show git diff and branch status") == .git)
}

@Test func taskPlannerUsesTaskAwareDefaultSteps() {
    let plan = TaskPlanner.plan(for: "implement a new feature in the runtime with careful testing and validation for the final result")

    #expect(plan != nil)
    #expect(plan?.taskKind == .feature)
    #expect(plan?.steps.count == 4)
    #expect(plan?.steps.first?.phase == .exploration)
    #expect(plan?.steps.first?.title.contains("locate the files") == true)
    #expect(plan?.steps.last?.phase == .validation)
}

@Test func explorationStrategyBuildsCodingFocusedSequence() {
    let snapshot = WorkspaceSnapshotRecord(
        id: UUID(),
        runID: UUID(),
        workspaceRootPath: "/tmp/project",
        topLevelEntries: ["Sources/", "Tests/", "README.md"],
        instructionFiles: ["README.md"],
        gitBranch: "main",
        gitStatusSummary: "## main",
        createdAt: Date()
    )

    let plan = ExplorationStrategy.recommend(
        taskKind: .feature,
        prompt: "implement provider settings for OpenAIModelAdapter in Sources/AshexCore/ModelAdapter.swift",
        workspaceSnapshot: snapshot
    )

    #expect(plan.summary.contains("Explore"))
    #expect(plan.recommendations.contains { $0.contains("find_files") })
    #expect(plan.recommendations.contains { $0.contains("search_text") })
    #expect(plan.recommendations.contains { $0.contains("read_text_file") })
    #expect(plan.recommendations.contains { $0.contains("README.md") })
    #expect(plan.targetPaths.contains("Sources/AshexCore/ModelAdapter.swift"))
    #expect(plan.suggestedQueries.contains { $0.contains("OpenAIModelAdapter") })
}

@Test func runtimeCompletesSimpleFilesystemRun() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dbURL = root.appendingPathComponent(".ashex/test.sqlite")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try "hello".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

    let runtime = try AgentRuntime(
        modelAdapter: MockModelAdapter(),
        toolRegistry: ToolRegistry(tools: [
            FileSystemTool(workspaceGuard: WorkspaceGuard(rootURL: root)),
            ShellTool(executionRuntime: ProcessExecutionRuntime(), workspaceURL: root, executionPolicy: testShellExecutionPolicy),
        ]),
        persistence: SQLitePersistenceStore(databaseURL: dbURL)
    )

    var sawFinalAnswer = false
    for await event in runtime.run(RunRequest(prompt: "read note.txt")) {
        if case .finalAnswer(_, _, let text) = event.payload {
            sawFinalAnswer = text.contains("hello")
        }
    }

    #expect(sawFinalAnswer)
}

@Test func filesystemToolAppliesStructuredPatchEdits() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let fileURL = root.appendingPathComponent("note.txt")
    try "alpha\nbeta\ngamma\n".write(to: fileURL, atomically: true, encoding: .utf8)

    let tool = FileSystemTool(workspaceGuard: WorkspaceGuard(rootURL: root))
    let result = try await tool.execute(
        arguments: [
            "operation": .string("apply_patch"),
            "path": .string("note.txt"),
            "edits": .array([
                .object([
                    "old_text": .string("alpha"),
                    "new_text": .string("ALPHA"),
                    "replace_all": .bool(false),
                ]),
                .object([
                    "old_text": .string("gamma"),
                    "new_text": .string("GAMMA"),
                    "replace_all": .bool(false),
                ]),
            ]),
        ],
        context: ToolContext(runID: UUID(), emit: { _ in }, cancellation: CancellationToken())
    )

    let updatedContent = try String(contentsOf: fileURL, encoding: .utf8)
    #expect(updatedContent.contains("ALPHA"))
    #expect(updatedContent.contains("GAMMA"))
    #expect(updatedContent.contains("beta"))

    guard case .structured(let payload) = result,
          let object = payload.objectValue else {
        Issue.record("Expected structured apply_patch payload")
        return
    }

    #expect(object["operation"]?.stringValue == "apply_patch")
    #expect(object["edit_count"]?.intValue == 2)
    #expect((object["diff"]?.arrayValue?.count ?? 0) > 0)
}

@Test func runtimeRecoversFromMalformedToolCall() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dbURL = root.appendingPathComponent(".ashex/test.sqlite")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try "hello".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

    let runtime = try AgentRuntime(
        modelAdapter: SequencedModelAdapter(actions: [
            .toolCall(.init(toolName: "filesystem", arguments: ["path": .string("note.txt")])),
            .toolCall(.init(toolName: "filesystem", arguments: ["operation": .string("read_text_file"), "path": .string("note.txt")])),
            .finalAnswer("Recovered"),
        ]),
        toolRegistry: ToolRegistry(tools: [
            FileSystemTool(workspaceGuard: WorkspaceGuard(rootURL: root)),
            ShellTool(executionRuntime: ProcessExecutionRuntime(), workspaceURL: root, executionPolicy: testShellExecutionPolicy),
        ]),
        persistence: SQLitePersistenceStore(databaseURL: dbURL)
    )

    var sawRecoveredAnswer = false
    for await event in runtime.run(RunRequest(prompt: "read note.txt")) {
        if case .finalAnswer(_, _, let text) = event.payload {
            sawRecoveredAnswer = text == "Recovered"
        }
    }

    #expect(sawRecoveredAnswer)
}

@Test func runtimeBreaksRepeatedReadOnlyToolLoop() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dbURL = root.appendingPathComponent(".ashex/test.sqlite")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try "hello".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

    let runtime = try AgentRuntime(
        modelAdapter: SequencedModelAdapter(actions: [
            .toolCall(.init(toolName: "filesystem", arguments: ["operation": .string("read_text_file"), "path": .string("note.txt")])),
            .toolCall(.init(toolName: "filesystem", arguments: ["operation": .string("read_text_file"), "path": .string("note.txt")])),
        ]),
        toolRegistry: ToolRegistry(tools: [
            FileSystemTool(workspaceGuard: WorkspaceGuard(rootURL: root)),
            ShellTool(executionRuntime: ProcessExecutionRuntime(), workspaceURL: root, executionPolicy: testShellExecutionPolicy),
        ]),
        persistence: SQLitePersistenceStore(databaseURL: dbURL)
    )

    var sawRecoveryAnswer = false
    for await event in runtime.run(RunRequest(prompt: "read note.txt")) {
        if case .finalAnswer(_, _, let text) = event.payload {
            sawRecoveryAnswer = text.contains("hello") && text.contains("Using the latest tool result")
        }
    }

    #expect(sawRecoveryAnswer)
}

@Test func runtimeRequiresInspectionBeforeMutationAndReportsChanges() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dbURL = root.appendingPathComponent(".ashex/test.sqlite")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try "hello".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

    let runtime = try AgentRuntime(
        modelAdapter: SequencedModelAdapter(actions: [
            .toolCall(.init(toolName: "filesystem", arguments: [
                "operation": .string("write_text_file"),
                "path": .string("note.txt"),
                "content": .string("updated"),
            ])),
            .toolCall(.init(toolName: "filesystem", arguments: [
                "operation": .string("read_text_file"),
                "path": .string("note.txt"),
            ])),
            .toolCall(.init(toolName: "filesystem", arguments: [
                "operation": .string("write_text_file"),
                "path": .string("note.txt"),
                "content": .string("updated"),
            ])),
            .finalAnswer("Updated note.txt"),
        ]),
        toolRegistry: ToolRegistry(tools: [
            FileSystemTool(workspaceGuard: WorkspaceGuard(rootURL: root)),
            ShellTool(executionRuntime: ProcessExecutionRuntime(), workspaceURL: root, executionPolicy: testShellExecutionPolicy),
        ]),
        persistence: SQLitePersistenceStore(databaseURL: dbURL)
    )

    var finalAnswer = ""
    for await event in runtime.run(RunRequest(prompt: "edit note.txt")) {
        if case .finalAnswer(_, _, let text) = event.payload {
            finalAnswer = text
        }
    }

    let updatedContent = try String(contentsOf: root.appendingPathComponent("note.txt"), encoding: .utf8)
    #expect(updatedContent == "updated")
    #expect(finalAnswer.contains("Changed files:"))
    #expect(finalAnswer.contains("note.txt"))
}

@Test func runtimeEmitsExplorationPlanForLargeCodingTask() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dbURL = root.appendingPathComponent(".ashex/test.sqlite")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)

    let snapshot = WorkspaceSnapshot(
        rootURL: root,
        topLevelEntries: ["Sources/"],
        instructionFiles: [],
        gitBranch: "main",
        gitStatusSummary: "## main"
    )

    let runtime = try AgentRuntime(
        modelAdapter: SequencedModelAdapter(actions: [.finalAnswer("done"), .finalAnswer("done"), .finalAnswer("done"), .finalAnswer("done")]),
        toolRegistry: ToolRegistry(tools: [
            FileSystemTool(workspaceGuard: WorkspaceGuard(rootURL: root)),
            ShellTool(executionRuntime: ProcessExecutionRuntime(), workspaceURL: root, executionPolicy: testShellExecutionPolicy),
        ]),
        persistence: SQLitePersistenceStore(databaseURL: dbURL),
        workspaceSnapshot: snapshot
    )

    var sawExplorationPlan = false
    for await event in runtime.run(RunRequest(prompt: "implement provider settings in the runtime and validate the result carefully")) {
        if case .status(_, let message) = event.payload, message.contains("Exploration plan:") {
            sawExplorationPlan = true
        }
    }

    #expect(sawExplorationPlan)
}

@Test func runtimeCanDelegateBoundedSubagentSteps() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dbURL = root.appendingPathComponent(".ashex/test.sqlite")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let runtime = try AgentRuntime(
        modelAdapter: SequencedModelAdapter(actions: [
            .finalAnswer("Explored the relevant files."),
            .finalAnswer("Planned a small implementation."),
            .finalAnswer("Applied the requested change."),
            .finalAnswer("Validated the result."),
        ]),
        toolRegistry: ToolRegistry(tools: [
            FileSystemTool(workspaceGuard: WorkspaceGuard(rootURL: root)),
            ShellTool(executionRuntime: ProcessExecutionRuntime(), workspaceURL: root, executionPolicy: testShellExecutionPolicy),
        ]),
        persistence: SQLitePersistenceStore(databaseURL: dbURL),
        workspaceSnapshot: WorkspaceSnapshot(
            rootURL: root,
            topLevelEntries: ["Sources/"],
            instructionFiles: [],
            gitBranch: "main",
            gitStatusSummary: "## main"
        )
    )

    var sawSubagentAssignment = false
    var sawSubagentStart = false
    var sawSubagentHandoff = false
    var sawSubagentFinish = false
    for await event in runtime.run(RunRequest(prompt: "implement a new feature in the runtime, validate it carefully, and summarize what remains")) {
        if case .subagentAssigned = event.payload {
            sawSubagentAssignment = true
        }
        if case .subagentStarted = event.payload {
            sawSubagentStart = true
        }
        if case .subagentHandoff = event.payload {
            sawSubagentHandoff = true
        }
        if case .subagentFinished = event.payload {
            sawSubagentFinish = true
        }
    }

    #expect(sawSubagentAssignment)
    #expect(sawSubagentStart)
    #expect(sawSubagentHandoff)
    #expect(sawSubagentFinish)
}

@Test func runtimeRequiresConcreteValidationAfterChanges() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dbURL = root.appendingPathComponent(".ashex/test.sqlite")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try "hello".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

    let runtime = try AgentRuntime(
        modelAdapter: SequencedModelAdapter(actions: [
            .toolCall(.init(toolName: "filesystem", arguments: [
                "operation": .string("read_text_file"),
                "path": .string("note.txt"),
            ])),
            .finalAnswer("Explored the current file."),
            .finalAnswer("Plan the minimal update."),
            .toolCall(.init(toolName: "filesystem", arguments: [
                "operation": .string("read_text_file"),
                "path": .string("note.txt"),
            ])),
            .toolCall(.init(toolName: "filesystem", arguments: [
                "operation": .string("write_text_file"),
                "path": .string("note.txt"),
                "content": .string("updated"),
            ])),
            .finalAnswer("Applied the change."),
            .finalAnswer("Looks done."),
            .toolCall(.init(toolName: "filesystem", arguments: [
                "operation": .string("read_text_file"),
                "path": .string("note.txt"),
            ])),
            .finalAnswer("Validated the file contents after the edit."),
        ]),
        toolRegistry: ToolRegistry(tools: [
            FileSystemTool(workspaceGuard: WorkspaceGuard(rootURL: root)),
            ShellTool(executionRuntime: ProcessExecutionRuntime(), workspaceURL: root, executionPolicy: testShellExecutionPolicy),
        ]),
        persistence: SQLitePersistenceStore(databaseURL: dbURL)
    )

    var sawValidationGateOrAutoValidation = false
    var finalAnswer = ""
    for await event in runtime.run(RunRequest(prompt: "implement a new feature in note.txt with validation and a final summary")) {
        switch event.payload {
        case .status(_, let message):
            if message.contains("Validation gate blocked completion") || message.contains("Automatic validation:") {
                sawValidationGateOrAutoValidation = true
            }
        case .finalAnswer(_, _, let text):
            finalAnswer = text
        default:
            break
        }
    }

    #expect(sawValidationGateOrAutoValidation)
    #expect(finalAnswer.contains("Validated the file contents"))
}

@Test func runtimeRecoversFromRepeatedUnproductiveRetries() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dbURL = root.appendingPathComponent(".ashex/test.sqlite")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let runtime = try AgentRuntime(
        modelAdapter: SequencedModelAdapter(actions: [
            .toolCall(.init(toolName: "missing-tool", arguments: [:])),
            .toolCall(.init(toolName: "missing-tool", arguments: [:])),
            .toolCall(.init(toolName: "missing-tool", arguments: [:])),
            .finalAnswer("should not be needed"),
            .finalAnswer("should not be needed"),
            .finalAnswer("should not be needed"),
            .finalAnswer("should not be needed"),
        ]),
        toolRegistry: ToolRegistry(tools: [
            FileSystemTool(workspaceGuard: WorkspaceGuard(rootURL: root)),
            ShellTool(executionRuntime: ProcessExecutionRuntime(), workspaceURL: root, executionPolicy: testShellExecutionPolicy),
        ]),
        persistence: SQLitePersistenceStore(databaseURL: dbURL)
    )

    var finalAnswer = ""
    for await event in runtime.run(RunRequest(prompt: "implement a feature that currently has a weak plan and needs reliability")) {
        if case .finalAnswer(_, _, let text) = event.payload {
            finalAnswer = text
        }
    }

    #expect(finalAnswer.contains("repeated unproductive retries"))
    #expect(finalAnswer.contains("What remains:"))
}

@Test func finalSummaryIncludesValidationSectionForPlannedRuns() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dbURL = root.appendingPathComponent(".ashex/test.sqlite")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try "hello".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

    let runtime = try AgentRuntime(
        modelAdapter: SequencedModelAdapter(actions: [
            .toolCall(.init(toolName: "filesystem", arguments: [
                "operation": .string("read_text_file"),
                "path": .string("note.txt"),
            ])),
            .finalAnswer("Explored note.txt."),
            .finalAnswer("Planned the minimal change."),
            .toolCall(.init(toolName: "filesystem", arguments: [
                "operation": .string("read_text_file"),
                "path": .string("note.txt"),
            ])),
            .toolCall(.init(toolName: "filesystem", arguments: [
                "operation": .string("apply_patch"),
                "path": .string("note.txt"),
                "edits": .array([
                    .object([
                        "old_text": .string("hello"),
                        "new_text": .string("updated"),
                        "replace_all": .bool(false),
                    ])
                ]),
            ])),
            .finalAnswer("Applied the patch."),
            .toolCall(.init(toolName: "filesystem", arguments: [
                "operation": .string("read_text_file"),
                "path": .string("note.txt"),
            ])),
            .finalAnswer("Validated the patched file contents."),
        ]),
        toolRegistry: ToolRegistry(tools: [
            FileSystemTool(workspaceGuard: WorkspaceGuard(rootURL: root)),
            ShellTool(executionRuntime: ProcessExecutionRuntime(), workspaceURL: root, executionPolicy: testShellExecutionPolicy),
        ]),
        persistence: SQLitePersistenceStore(databaseURL: dbURL)
    )

    var finalAnswer = ""
    for await event in runtime.run(RunRequest(prompt: "implement a feature in note.txt and validate it carefully before summarizing")) {
        if case .finalAnswer(_, _, let text) = event.payload {
            finalAnswer = text
        }
    }

    #expect(finalAnswer.contains("Validation:"))
    #expect(finalAnswer.contains("Validation completed with concrete verification") || finalAnswer.contains("inspected note.txt"))
    #expect(finalAnswer.contains("Changed files:"))
}

@Test func runtimeCanAutoExecuteValidationChecksBeforeAcceptingCompletion() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dbURL = root.appendingPathComponent(".ashex/test.sqlite")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try "hello".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

    let runtime = try AgentRuntime(
        modelAdapter: SequencedModelAdapter(actions: [
            .toolCall(.init(toolName: "filesystem", arguments: [
                "operation": .string("read_text_file"),
                "path": .string("note.txt"),
            ])),
            .finalAnswer("Explored note.txt."),
            .finalAnswer("Planned the smallest change."),
            .toolCall(.init(toolName: "filesystem", arguments: [
                "operation": .string("read_text_file"),
                "path": .string("note.txt"),
            ])),
            .toolCall(.init(toolName: "filesystem", arguments: [
                "operation": .string("apply_patch"),
                "path": .string("note.txt"),
                "edits": .array([
                    .object([
                        "old_text": .string("hello"),
                        "new_text": .string("updated"),
                        "replace_all": .bool(false),
                    ])
                ]),
            ])),
            .finalAnswer("Applied the patch."),
            .finalAnswer("Too early to finish."),
            .finalAnswer("Accepted after automatic validation."),
        ]),
        toolRegistry: ToolRegistry(tools: [
            FileSystemTool(workspaceGuard: WorkspaceGuard(rootURL: root)),
            ShellTool(executionRuntime: ProcessExecutionRuntime(), workspaceURL: root, executionPolicy: testShellExecutionPolicy),
        ]),
        persistence: SQLitePersistenceStore(databaseURL: dbURL)
    )

    var finalAnswer = ""
    for await event in runtime.run(RunRequest(prompt: "implement a feature in note.txt and validate it carefully before summarizing")) {
        if case .finalAnswer(_, _, let text) = event.payload {
            finalAnswer = text
        }
    }

    #expect(finalAnswer.contains("Accepted after automatic validation."))
    #expect(finalAnswer.contains("Validation:"))
}

@Test func sqlitePersistenceRoundTripsGenericSettings() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dbURL = root.appendingPathComponent(".ashex/test.sqlite")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let store = SQLitePersistenceStore(databaseURL: dbURL)
    try store.initialize()
    try store.upsertSetting(namespace: "ui.session", key: "default_provider", value: .string("ollama"), now: Date())
    try store.upsertSetting(namespace: "ui.session", key: "default_model", value: .string("llama3.1:8b"), now: Date())

    let provider = try store.fetchSetting(namespace: "ui.session", key: "default_provider")
    let model = try store.fetchSetting(namespace: "ui.session", key: "default_model")
    let settings = try store.listSettings(namespace: "ui.session")

    #expect(provider?.value == .string("ollama"))
    #expect(model?.value == .string("llama3.1:8b"))
    #expect(settings.count == 2)
}

@Test func sqlitePersistenceRoundTripsWorkspaceSnapshotAndWorkingMemory() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dbURL = root.appendingPathComponent(".ashex/test.sqlite")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let store = SQLitePersistenceStore(databaseURL: dbURL)
    try store.initialize()
    let now = Date()
    let thread = try store.createThread(now: now)
    let run = try store.createRun(threadID: thread.id, state: .running, now: now)

    _ = try store.recordWorkspaceSnapshot(
        runID: run.id,
        workspaceRootPath: root.path,
        topLevelEntries: ["Sources/", "README.md"],
        instructionFiles: ["README.md"],
        gitBranch: "main",
        gitStatusSummary: "## main",
        now: now
    )
    _ = try store.upsertWorkingMemory(
        runID: run.id,
        currentTask: "Fix harness architecture",
        currentPhase: "exploration",
        explorationTargets: ["Sources/AshexCore/Prompting.swift", "Tests/AshexCoreTests/AgentRuntimeTests.swift"],
        pendingExplorationTargets: ["Tests/AshexCoreTests/AgentRuntimeTests.swift"],
        inspectedPaths: ["Sources/AshexCore/Prompting.swift"],
        changedPaths: ["README.md"],
        recentFindings: ["Inspected Prompting.swift and found compaction entry points."],
        completedStepSummaries: ["Explored the harness files."],
        unresolvedItems: ["Need to validate context persistence."],
        validationSuggestions: ["git diff", "run targeted tests"],
        summary: "Collected relevant harness files.",
        now: now
    )

    let snapshot = try store.fetchWorkspaceSnapshot(runID: run.id)
    let memory = try store.fetchWorkingMemory(runID: run.id)

    #expect(snapshot?.workspaceRootPath == root.path)
    #expect(snapshot?.topLevelEntries == ["Sources/", "README.md"])
    #expect(snapshot?.instructionFiles == ["README.md"])
    #expect(memory?.currentTask == "Fix harness architecture")
    #expect(memory?.currentPhase == "exploration")
    #expect(memory?.explorationTargets == ["Sources/AshexCore/Prompting.swift", "Tests/AshexCoreTests/AgentRuntimeTests.swift"])
    #expect(memory?.pendingExplorationTargets == ["Tests/AshexCoreTests/AgentRuntimeTests.swift"])
    #expect(memory?.inspectedPaths == ["Sources/AshexCore/Prompting.swift"])
    #expect(memory?.changedPaths == ["README.md"])
    #expect(memory?.recentFindings == ["Inspected Prompting.swift and found compaction entry points."])
    #expect(memory?.completedStepSummaries == ["Explored the harness files."])
    #expect(memory?.unresolvedItems == ["Need to validate context persistence."])
}

@Test func ollamaGuardrailWarnsForMemoryHeavyModel() {
    let assessment = LocalModelGuardrails.assessOllamaModel(
        model: "medium",
        installedModels: [
            .init(name: "small", sizeBytes: 2_000_000_000),
            .init(name: "medium", sizeBytes: 7_000_000_000),
        ],
        resources: .init(
            physicalMemoryBytes: 16_000_000_000,
            usableLocalModelMemoryBytes: 12_000_000_000
        )
    )

    #expect(assessment.severity == .warning)
}

@Test func ollamaGuardrailBlocksOversizedModel() {
    let assessment = LocalModelGuardrails.assessOllamaModel(
        model: "large",
        installedModels: [
            .init(name: "small", sizeBytes: 2_000_000_000),
            .init(name: "large", sizeBytes: 7_500_000_000),
        ],
        resources: .init(physicalMemoryBytes: 8_000_000_000)
    )

    #expect(assessment.severity == .blocked)
}

private actor SequencedModelAdapter: ModelAdapter {
    let name = "sequenced-test"
    let providerID = "test"
    let modelID = "sequenced-test"
    private var actions: [ModelAction]

    init(actions: [ModelAction]) {
        self.actions = actions
    }

    func nextAction(for context: ModelContext) async throws -> ModelAction {
        guard !actions.isEmpty else {
            throw AshexError.model("No more actions")
        }
        return actions.removeFirst()
    }
}
