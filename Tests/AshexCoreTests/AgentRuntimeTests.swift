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
