import AshexCore
import Foundation
import Testing

@Test func workspaceGuardRejectsTraversal() throws {
    let root = URL(fileURLWithPath: "/tmp/ashex-tests/root")
    let guardrail = WorkspaceGuard(rootURL: root)

    #expect(throws: Error.self) {
        _ = try guardrail.resolve(path: "../secrets.txt")
    }
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
            ShellTool(executionRuntime: ProcessExecutionRuntime(), workspaceURL: root),
        ]),
        persistence: SQLitePersistenceStore(databaseURL: dbURL)
    )

    var sawFinalAnswer = false
    for await event in runtime.run(.init(prompt: "read note.txt")) {
        if case .finalAnswer(_, _, let text) = event.payload {
            sawFinalAnswer = text.contains("hello")
        }
    }

    #expect(sawFinalAnswer)
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
            ShellTool(executionRuntime: ProcessExecutionRuntime(), workspaceURL: root),
        ]),
        persistence: SQLitePersistenceStore(databaseURL: dbURL)
    )

    var sawRecoveredAnswer = false
    for await event in runtime.run(.init(prompt: "read note.txt")) {
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
            ShellTool(executionRuntime: ProcessExecutionRuntime(), workspaceURL: root),
        ]),
        persistence: SQLitePersistenceStore(databaseURL: dbURL)
    )

    var sawRecoveryAnswer = false
    for await event in runtime.run(.init(prompt: "read note.txt")) {
        if case .finalAnswer(_, _, let text) = event.payload {
            sawRecoveryAnswer = text.contains("hello") && text.contains("Using the latest tool result")
        }
    }

    #expect(sawRecoveryAnswer)
}

private actor SequencedModelAdapter: ModelAdapter {
    let name = "sequenced-test"
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
