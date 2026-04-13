import AshexCore
import Foundation
import Testing

private final class GitToolRecordingExecutionRuntime: ExecutionRuntime, @unchecked Sendable {
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

@Test func gitToolBuildsInitAddAndCommitCommands() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let runtime = GitToolRecordingExecutionRuntime()
    let tool = GitTool(executionRuntime: runtime, workspaceURL: root)
    let context = ToolContext(runID: UUID(), emit: { _ in }, cancellation: CancellationToken())

    _ = try await tool.execute(arguments: [
        "operation": .string("init"),
        "initial_branch": .string("main"),
    ], context: context)

    _ = try await tool.execute(arguments: [
        "operation": .string("add"),
        "paths": .array([.string("README.md"), .string("Sources/App.swift")]),
    ], context: context)

    _ = try await tool.execute(arguments: [
        "operation": .string("commit"),
        "message": .string("Initial commit"),
        "amend": .bool(false),
        "allow_empty": .bool(false),
    ], context: context)

    #expect(runtime.requests.count == 3)
    #expect(runtime.requests[0].command == "git init --initial-branch='main'")
    #expect(runtime.requests[1].command == "git add -- 'README.md' 'Sources/App.swift'")
    #expect(runtime.requests[2].command == "git commit -m 'Initial commit'")
}

@Test func gitToolBuildsBranchAndSyncCommands() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let runtime = GitToolRecordingExecutionRuntime()
    let tool = GitTool(executionRuntime: runtime, workspaceURL: root)
    let context = ToolContext(runID: UUID(), emit: { _ in }, cancellation: CancellationToken())

    _ = try await tool.execute(arguments: [
        "operation": .string("switch_new_branch"),
        "branch_name": .string("feature/retrieval"),
        "start_point": .string("main"),
    ], context: context)

    _ = try await tool.execute(arguments: [
        "operation": .string("push"),
        "remote": .string("origin"),
        "branch_name": .string("feature/retrieval"),
        "set_upstream": .bool(true),
        "force_with_lease": .bool(false),
    ], context: context)

    #expect(runtime.requests.count == 2)
    #expect(runtime.requests[0].command == "git switch -c 'feature/retrieval' 'main'")
    #expect(runtime.requests[1].command == "git push --set-upstream 'origin' 'feature/retrieval'")
}
