import AshexCore
import Foundation
import Testing

private let testShellExecutionPolicy = ShellExecutionPolicy(
    sandbox: .default,
    network: .default,
    shell: ShellCommandPolicy(config: .default)
)

private final class RecordingExecutionRuntime: ExecutionRuntime, @unchecked Sendable {
    private(set) var requests: [ShellExecutionRequest] = []
    let result: ShellExecutionResult

    init(result: ShellExecutionResult = .init(stdout: "ok", stderr: "", exitCode: 0, timedOut: false)) {
        self.result = result
    }

    func execute(
        _ request: ShellExecutionRequest,
        cancellationToken: CancellationToken,
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) async throws -> ShellExecutionResult {
        requests.append(request)
        if !result.stdout.isEmpty {
            onStdout(result.stdout)
        }
        if !result.stderr.isEmpty {
            onStderr(result.stderr)
        }
        return result
    }
}

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
    #expect(TaskPlanner.classify(prompt: "what is this project about?") == .analysis)
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

@Test func taskPlannerSplitsBulletListsIntoExplicitSteps() {
    let prompt = """
    1. Fix persisted token accounting so stats survive restart
    2. Add Telegram commands to view and change the model
    3. Add chunked Telegram replies for long responses
    """
    let plan = TaskPlanner.plan(for: prompt)

    #expect(plan?.steps.count == 3)
    #expect(plan?.steps[0].title == "Fix persisted token accounting so stats survive restart")
    #expect(plan?.steps[1].title == "Add Telegram commands to view and change the model")
    #expect(plan?.steps[2].title == "Add chunked Telegram replies for long responses")
}

@Test func taskPlannerSplitsCoordinatedActionPromptsIntoSequentialSteps() {
    let prompt = "Fix persisted token accounting and add Telegram model commands and validate the updated flow."
    let plan = TaskPlanner.plan(for: prompt)

    #expect(plan?.steps.count == 3)
    #expect(plan?.steps[0].title == "Fix persisted token accounting")
    #expect(plan?.steps[1].title == "add Telegram model commands")
    #expect(plan?.steps[2].title == "validate the updated flow.")
    #expect(plan?.steps[0].phase == .exploration)
    #expect(plan?.steps[2].phase == .validation)
}

@Test func runtimePrefersModelGeneratedPlanWhenAvailable() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dbURL = root.appendingPathComponent(".ashex/test.sqlite")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let runtime = try AgentRuntime(
        modelAdapter: PlannedSequencedModelAdapter(
            plan: TaskPlan(
                steps: [
                    PlannedStep(title: "Inspect the current implementation", phase: .exploration),
                    PlannedStep(title: "Implement the requested changes", phase: .mutation),
                    PlannedStep(title: "Validate the updated behavior", phase: .validation),
                ],
                taskKind: .feature
            ),
            actions: [
                .finalAnswer("Explored the implementation."),
                .finalAnswer("Applied the requested change."),
                .finalAnswer("Validated the result."),
            ]
        ),
        toolRegistry: ToolRegistry(tools: [
            FileSystemTool(workspaceGuard: WorkspaceGuard(rootURL: root)),
        ]),
        persistence: SQLitePersistenceStore(databaseURL: dbURL),
        workspaceSnapshot: WorkspaceSnapshotBuilder.capture(workspaceRoot: root)
    )

    var plannedSteps: [String] = []
    for await event in runtime.run(RunRequest(prompt: "Implement the new Telegram controls and persist the selected model after restart")) {
        if case .taskPlanCreated(_, let steps) = event.payload {
            plannedSteps = steps
        }
    }

    #expect(plannedSteps == [
        "Inspect the current implementation",
        "Implement the requested changes",
        "Validate the updated behavior",
    ])
}

@Test func taskPlannerUsesExplorationFallbackForShortAnalysisPrompts() {
    let step = TaskPlanner.defaultSingleStep(for: "what is this project about?", taskKind: .analysis)

    #expect(step.phase == .exploration)
    #expect(step.title.contains("summarize"))
}

@Test func explorationStrategyBuildsCodingFocusedSequence() {
    let snapshot = WorkspaceSnapshotRecord(
        id: UUID(),
        runID: UUID(),
        workspaceRootPath: "/tmp/project",
        topLevelEntries: ["Sources/", "Tests/", "README.md", "docs/"],
        instructionFiles: ["README.md"],
        projectMarkers: ["Package.swift"],
        sourceRoots: ["Sources"],
        testRoots: ["Tests"],
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
    #expect(plan.targetPaths.contains("Package.swift"))
    #expect(plan.targetPaths.contains("Tests"))
    #expect(plan.deprioritizedPaths.contains("docs/"))
    #expect(plan.suggestedQueries.contains { $0.contains("OpenAIModelAdapter") })
}

@Test func runtimeEmitsStructuredExplorationPlanUpdates() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dbURL = root.appendingPathComponent(".ashex/test.sqlite")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try "swift-tools-version: 6.0".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try "# Demo".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try fileManager.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: root.appendingPathComponent("Tests"), withIntermediateDirectories: true)

    let runtime = try AgentRuntime(
        modelAdapter: PlannedSequencedModelAdapter(
            plan: TaskPlan(
                steps: [
                    PlannedStep(title: "Inspect the current implementation", phase: .exploration),
                ],
                taskKind: .feature
            ),
            actions: [
                .finalAnswer("Explored the implementation."),
            ]
        ),
        toolRegistry: ToolRegistry(tools: [
            FileSystemTool(workspaceGuard: WorkspaceGuard(rootURL: root)),
        ]),
        persistence: SQLitePersistenceStore(databaseURL: dbURL)
    )

    var sawExplorationEvent = false
    var sawSuggestedQueries = false
    for await event in runtime.run(RunRequest(prompt: "Implement provider settings for the runtime")) {
        if case .explorationPlanUpdated(_, let targets, let pendingTargets, _, let suggestedQueries) = event.payload {
            sawExplorationEvent = !targets.isEmpty && !pendingTargets.isEmpty
            sawSuggestedQueries = !suggestedQueries.isEmpty
        }
    }

    #expect(sawExplorationEvent)
    #expect(sawSuggestedQueries)
}

@Test func workspaceSnapshotBuilderDetectsRepoProfileMarkersAndRoots() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: root.appendingPathComponent("Tests"), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: root.appendingPathComponent("docs/roadmap"), withIntermediateDirectories: true)
    try "{}".write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    try "name: demo".write(to: root.appendingPathComponent("pnpm-lock.yaml"), atomically: true, encoding: .utf8)
    try "# Demo".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try "# Phases".write(to: root.appendingPathComponent("docs/roadmap/implementation-phases.md"), atomically: true, encoding: .utf8)

    let snapshot = WorkspaceSnapshotBuilder.capture(workspaceRoot: root)

    #expect(snapshot.projectMarkers.contains("package.json"))
    #expect(snapshot.projectMarkers.contains("pnpm-lock.yaml"))
    #expect(snapshot.sourceRoots.contains("Sources"))
    #expect(snapshot.testRoots.contains("Tests"))
    #expect(snapshot.instructionFiles.contains("README.md"))
    #expect(snapshot.instructionFiles.contains("docs/roadmap/implementation-phases.md"))
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

@Test func runtimePassesNormalizedAttachmentsIntoToolContext() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dbURL = root.appendingPathComponent(".ashex/test.sqlite")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let attachmentURL = root.appendingPathComponent("image.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: attachmentURL)
    let tool = AttachmentProbeTool()

    let runtime = try AgentRuntime(
        modelAdapter: SequencedModelAdapter(actions: [
            .toolCall(.init(toolName: "attachment_probe", arguments: [:])),
            .finalAnswer("done"),
        ]),
        toolRegistry: ToolRegistry(tools: [
            tool,
        ]),
        persistence: SQLitePersistenceStore(databaseURL: dbURL)
    )

    for await _ in runtime.run(RunRequest(
        prompt: "Inspect the attachment",
        attachments: [
            .init(
                kind: .image,
                localPath: attachmentURL.path,
                originalFilename: "image.png",
                mimeType: "image/png",
                caption: "What is in this image?"
            )
        ]
    )) {}

    #expect(await tool.recordedPaths() == [attachmentURL.path])
}

@Test func directChatRunEmitsThinkingStatus() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dbURL = root.appendingPathComponent(".ashex/test.sqlite")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let runtime = try AgentRuntime(
        modelAdapter: MockModelAdapter(),
        toolRegistry: ToolRegistry(tools: []),
        persistence: SQLitePersistenceStore(databaseURL: dbURL)
    )

    var sawThinkingStatus = false
    for await event in runtime.run(RunRequest(prompt: "How are you?", mode: .directChat)) {
        if case .status(_, let message) = event.payload, message.localizedCaseInsensitiveContains("thinking about the reply") {
            sawThinkingStatus = true
        }
    }

    #expect(sawThinkingStatus)
}

@Test func directChatRunEmitsReasoningSummaryWhenDebugModeIsEnabled() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dbURL = root.appendingPathComponent(".ashex/test.sqlite")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let runtime = try AgentRuntime(
        modelAdapter: ReasoningSummaryDirectChatAdapter(),
        toolRegistry: ToolRegistry(tools: []),
        persistence: SQLitePersistenceStore(databaseURL: dbURL),
        reasoningSummaryDebugEnabled: true
    )

    var sawReasoningSummary = false
    for await event in runtime.run(RunRequest(prompt: "How are you?", mode: .directChat)) {
        if case .status(_, let message) = event.payload, message.localizedCaseInsensitiveContains("reasoning summary: analyzed the request") {
            sawReasoningSummary = true
        }
    }

    #expect(sawReasoningSummary)
}

@Test func buildToolRunsTypedSwiftAndXcodeCommands() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let runtime = RecordingExecutionRuntime()
    let tool = BuildTool(executionRuntime: runtime, workspaceURL: root)
    let context = ToolContext(runID: UUID(), emit: { _ in }, cancellation: CancellationToken())

    _ = try await tool.execute(arguments: [
        "operation": .string("swift_build"),
    ], context: context)

    _ = try await tool.execute(arguments: [
        "operation": .string("xcodebuild_test"),
        "workspace": .string("App.xcworkspace"),
        "scheme": .string("Demo"),
        "destination": .string("platform=iOS Simulator,name=iPhone 16"),
    ], context: context)

    #expect(runtime.requests.count == 2)
    #expect(runtime.requests[0].command == "swift build")
    #expect(runtime.requests[1].command.contains("xcodebuild"))
    #expect(runtime.requests[1].command.contains("-workspace"))
    #expect(runtime.requests[1].command.contains("App.xcworkspace"))
    #expect(runtime.requests[1].command.contains("-scheme"))
    #expect(runtime.requests[1].command.contains("Demo"))
    #expect(runtime.requests[1].command.contains("-destination"))
    #expect(runtime.requests[1].command.contains("iPhone 16"))
    #expect(runtime.requests[1].command.hasSuffix(" test"))
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

@Test func runtimeRejectsRawToolTranscriptAsFinalAnswer() async throws {
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
            .finalAnswer("""
            Tool execution finished.

            [tool_result]
            tool filesystem
            status completed
            structured_output:
            {"content":"hello"}
            """),
            .finalAnswer("The file currently contains hello."),
        ]),
        toolRegistry: ToolRegistry(tools: [
            FileSystemTool(workspaceGuard: WorkspaceGuard(rootURL: root)),
            ShellTool(executionRuntime: ProcessExecutionRuntime(), workspaceURL: root, executionPolicy: testShellExecutionPolicy),
        ]),
        persistence: SQLitePersistenceStore(databaseURL: dbURL)
    )

    var statuses: [String] = []
    var finalAnswer = ""
    for await event in runtime.run(RunRequest(prompt: "read note.txt")) {
        switch event.payload {
        case .status(_, let message):
            statuses.append(message)
        case .finalAnswer(_, _, let text):
            finalAnswer = text
        default:
            break
        }
    }

    #expect(statuses.contains { $0.contains("echoed raw tool output") })
    #expect(finalAnswer == "The file currently contains hello.")
}

@Test func githubRepoApprovalReasonOmitsMissingRefPlaceholder() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dbURL = root.appendingPathComponent(".ashex/test.sqlite")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let runtime = try AgentRuntime(
        modelAdapter: SequencedModelAdapter(actions: [
            .toolCall(.init(toolName: "github_repo", arguments: [
                "operation": .string("inspect_repository"),
                "repository_url": .string("https://github.com/z-lab/dflash"),
            ])),
            .finalAnswer("done"),
        ]),
        toolRegistry: ToolRegistry(tools: [
            GitHubRepoTool(executionRuntime: ProcessExecutionRuntime()),
        ]),
        persistence: SQLitePersistenceStore(databaseURL: dbURL),
        approvalPolicy: AutoApprovePolicy()
    )

    var approvalReason = ""
    for await event in runtime.run(RunRequest(prompt: "Inspect https://github.com/z-lab/dflash")) {
        if case .approvalRequested(_, _, _, let reason, _) = event.payload {
            approvalReason = reason
            break
        }
    }

    #expect(approvalReason == "https://github.com/z-lab/dflash")
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
    var sawPatchPlan = false
    for await event in runtime.run(RunRequest(prompt: "implement provider settings in the runtime and validate the result carefully")) {
        if case .status(_, let message) = event.payload, message.contains("Exploration plan:") {
            sawExplorationPlan = true
        }
        if case .patchPlanUpdated(_, let paths, let objectives) = event.payload, !paths.isEmpty, !objectives.isEmpty {
            sawPatchPlan = true
        }
    }

    #expect(sawExplorationPlan)
    #expect(sawPatchPlan)
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

@Test func runtimeCanLaunchParallelExplorationSubagents() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dbURL = root.appendingPathComponent(".ashex/test.sqlite")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let runtime = try AgentRuntime(
        modelAdapter: SequencedModelAdapter(actions: [
            .finalAnswer("SUMMARY:\nlooked at Sources\nFINDINGS:\n- Runtime likely lives in Sources\nREMAINING:\n- inspect Tests\nFILES:\n- Sources"),
            .finalAnswer("SUMMARY:\nlooked at Tests\nFINDINGS:\n- Tests cover runtime behavior\nREMAINING:\n- inspect README\nFILES:\n- Tests"),
            .finalAnswer("Planned implementation."),
            .finalAnswer("Applied changes."),
            .finalAnswer("Validated results."),
        ]),
        toolRegistry: ToolRegistry(tools: [
            FileSystemTool(workspaceGuard: WorkspaceGuard(rootURL: root)),
            GitTool(executionRuntime: ProcessExecutionRuntime(), workspaceURL: root),
            ShellTool(executionRuntime: ProcessExecutionRuntime(), workspaceURL: root, executionPolicy: testShellExecutionPolicy),
        ]),
        persistence: SQLitePersistenceStore(databaseURL: dbURL),
        workspaceSnapshot: WorkspaceSnapshot(
            rootURL: root,
            topLevelEntries: ["Sources/", "Tests/", "README.md"],
            instructionFiles: ["README.md"],
            gitBranch: "main",
            gitStatusSummary: "## main"
        )
    )

    var assignments = 0
    var sawParallelStatus = false
    for await event in runtime.run(RunRequest(prompt: "implement a new feature across Sources and Tests and validate the result")) {
        if case .subagentAssigned = event.payload {
            assignments += 1
        }
        if case .status(_, let message) = event.payload, message.contains("Launching 2 bounded read-only subagents") {
            sawParallelStatus = true
        }
    }

    #expect(sawParallelStatus)
    #expect(assignments >= 2)
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
        projectMarkers: ["Package.swift"],
        sourceRoots: ["Sources"],
        testRoots: ["Tests"],
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
        rejectedExplorationTargets: ["README.md"],
        inspectedPaths: ["Sources/AshexCore/Prompting.swift"],
        changedPaths: ["README.md"],
        recentFindings: ["Inspected Prompting.swift and found compaction entry points."],
        completedStepSummaries: ["Explored the harness files."],
        unresolvedItems: ["Need to validate context persistence."],
        validationSuggestions: ["git diff", "run targeted tests"],
        plannedChangeSet: ["Sources/AshexCore/Prompting.swift", "README.md"],
        patchObjectives: ["Keep the change set small.", "Preserve current behavior while improving context persistence."],
        carryForwardNotes: ["Compaction logic is in Prompting.swift."],
        summary: "Collected relevant harness files.",
        now: now
    )

    let snapshot = try store.fetchWorkspaceSnapshot(runID: run.id)
    let memory = try store.fetchWorkingMemory(runID: run.id)

    #expect(snapshot?.workspaceRootPath == root.path)
    #expect(snapshot?.topLevelEntries == ["Sources/", "README.md"])
    #expect(snapshot?.instructionFiles == ["README.md"])
    #expect(snapshot?.projectMarkers == ["Package.swift"])
    #expect(snapshot?.sourceRoots == ["Sources"])
    #expect(snapshot?.testRoots == ["Tests"])
    #expect(memory?.currentTask == "Fix harness architecture")
    #expect(memory?.currentPhase == "exploration")
    #expect(memory?.explorationTargets == ["Sources/AshexCore/Prompting.swift", "Tests/AshexCoreTests/AgentRuntimeTests.swift"])
    #expect(memory?.pendingExplorationTargets == ["Tests/AshexCoreTests/AgentRuntimeTests.swift"])
    #expect(memory?.rejectedExplorationTargets == ["README.md"])
    #expect(memory?.inspectedPaths == ["Sources/AshexCore/Prompting.swift"])
    #expect(memory?.changedPaths == ["README.md"])
    #expect(memory?.recentFindings == ["Inspected Prompting.swift and found compaction entry points."])
    #expect(memory?.completedStepSummaries == ["Explored the harness files."])
    #expect(memory?.unresolvedItems == ["Need to validate context persistence."])
    #expect(memory?.plannedChangeSet == ["Sources/AshexCore/Prompting.swift", "README.md"])
    #expect(memory?.patchObjectives == ["Keep the change set small.", "Preserve current behavior while improving context persistence."])
    #expect(memory?.carryForwardNotes == ["Compaction logic is in Prompting.swift."])
}

@Test func validationStrategyPlansBuildAndTestForPackageManagers() {
    let snapshot = WorkspaceSnapshotRecord(
        id: UUID(),
        runID: UUID(),
        workspaceRootPath: "/tmp/project",
        topLevelEntries: ["package.json", "pnpm-lock.yaml", "src", "tests"],
        instructionFiles: [],
        gitBranch: nil,
        gitStatusSummary: nil,
        createdAt: Date()
    )

    let actions = ValidationStrategy.plan(
        request: "fix the failing web feature and validate it",
        taskKind: .bugFix,
        changedFiles: ["src/app.ts"],
        workspaceSnapshot: snapshot,
        availableToolNames: ["shell", "filesystem", "git"]
    )

    let commands = actions.compactMap { $0.call.arguments["command"]?.stringValue }
    #expect(commands.contains("pnpm run build"))
    #expect(commands.contains("pnpm test"))
}

@Test func validationStrategyPrefersTypedBuildToolForSwiftAndXcodeProjects() {
    let swiftSnapshot = WorkspaceSnapshotRecord(
        id: UUID(),
        runID: UUID(),
        workspaceRootPath: "/tmp/swift-project",
        topLevelEntries: ["Package.swift", "Sources", "Tests"],
        instructionFiles: [],
        projectMarkers: ["Package.swift"],
        sourceRoots: ["Sources"],
        testRoots: ["Tests"],
        gitBranch: nil,
        gitStatusSummary: nil,
        createdAt: Date()
    )

    let swiftActions = ValidationStrategy.plan(
        request: "fix the Swift runtime and validate it",
        taskKind: .bugFix,
        changedFiles: ["Sources/App.swift"],
        workspaceSnapshot: swiftSnapshot,
        availableToolNames: ["build"]
    )

    #expect(swiftActions.contains { $0.call.toolName == "build" && $0.call.arguments["operation"]?.stringValue == "swift_build" })
    #expect(swiftActions.contains { $0.call.toolName == "build" && $0.call.arguments["operation"]?.stringValue == "swift_test" })

    let xcodeSnapshot = WorkspaceSnapshotRecord(
        id: UUID(),
        runID: UUID(),
        workspaceRootPath: "/tmp/xcode-project",
        topLevelEntries: ["App.xcodeproj", "Sources", "Tests"],
        instructionFiles: [],
        projectMarkers: ["App.xcodeproj"],
        sourceRoots: ["Sources"],
        testRoots: ["Tests"],
        gitBranch: nil,
        gitStatusSummary: nil,
        createdAt: Date()
    )

    let xcodeActions = ValidationStrategy.plan(
        request: "build and test the app after this fix",
        taskKind: .bugFix,
        changedFiles: ["Sources/AppViewController.swift"],
        workspaceSnapshot: xcodeSnapshot,
        availableToolNames: ["build"]
    )

    #expect(xcodeActions.contains { $0.call.toolName == "build" && $0.call.arguments["operation"]?.stringValue == "xcodebuild_build" })
    #expect(xcodeActions.contains { $0.call.toolName == "build" && $0.call.arguments["operation"]?.stringValue == "xcodebuild_test" })
    #expect(xcodeActions.contains { $0.call.arguments["project"]?.stringValue == "App.xcodeproj" })
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

@Test func ollamaGuardrailWarnsInsteadOfBlockingInstalledModelAboveBackgroundBudget() {
    let assessment = LocalModelGuardrails.assessOllamaModel(
        model: "local",
        installedModels: [
            .init(name: "local", sizeBytes: 5_000_000_000),
        ],
        resources: .init(
            physicalMemoryBytes: 8_000_000_000,
            usableLocalModelMemoryBytes: 4_000_000_000
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

private struct AutoApprovePolicy: ApprovalPolicy {
    let mode: ApprovalMode = .guarded

    func evaluate(_ request: ApprovalRequest) async -> ApprovalDecision {
        .allow("Approved in test")
    }
}

private actor PlannedSequencedModelAdapter: TaskPlanningModelAdapter {
    let name = "planned-sequenced-test"
    let providerID = "test"
    let modelID = "planned-sequenced-test"

    private let planValue: TaskPlan?
    private var actions: [ModelAction]

    init(plan: TaskPlan?, actions: [ModelAction]) {
        self.planValue = plan
        self.actions = actions
    }

    func taskPlan(for prompt: String, taskKind: TaskKind) async throws -> TaskPlan? {
        planValue
    }

    func nextAction(for context: ModelContext) async throws -> ModelAction {
        guard !actions.isEmpty else {
            throw AshexError.model("No more actions")
        }
        return actions.removeFirst()
    }
}

private actor ReasoningSummaryDirectChatAdapter: DirectChatModelAdapter {
    let name = "reasoning-summary-direct-chat"
    let providerID = "test"
    let modelID = "reasoning-summary-direct-chat"

    func nextAction(for context: ModelContext) async throws -> ModelAction {
        .finalAnswer("unused")
    }

    func directReply(history: [MessageRecord], systemPrompt: String) async throws -> String {
        "I'm doing well."
    }

    func directReplyEnvelope(history: [MessageRecord], systemPrompt: String, attachments: [InputAttachment]) async throws -> DirectChatReplyEnvelope {
        .init(text: "I'm doing well.", reasoningSummary: "Analyzed the request and considered what to inspect or use.")
    }
}

private actor AttachmentProbeTool: Tool {
    let name = "attachment_probe"
    let description = "Reports normalized attachment context"
    private var lastPaths: [String] = []

    func execute(arguments: JSONObject, context: ToolContext) async throws -> ToolContent {
        let paths = context.attachments.map(\.localPath)
        lastPaths = paths
        return .structured(.object([
            "summary": .string(paths.isEmpty ? "No attachments" : "Attachments: \(paths.joined(separator: ", "))"),
            "paths": .array(paths.map(JSONValue.string)),
        ]))
    }

    func recordedPaths() -> [String] {
        lastPaths
    }
}
