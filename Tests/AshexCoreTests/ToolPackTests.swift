import AshexCore
import Foundation
import Testing

private let toolPackTestShellExecutionPolicy = ShellExecutionPolicy(
    sandbox: .default,
    network: .default,
    shell: ShellCommandPolicy(config: .default)
)

private final class ToolPackRecordingExecutionRuntime: ExecutionRuntime, @unchecked Sendable {
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

@Test func bundledToolPacksExposeExpectedIDs() throws {
    let packs = try ToolPackManager.availableBundledPacks()
    let ids = Set(packs.map(\.id))

    #expect(ids.contains("swiftpm"))
    #expect(ids.contains("ios_xcode"))
    #expect(ids.contains("python"))
}

@Test func manifestBackedSwiftPMToolRendersTypedCommand() async throws {
    let packs = try ToolPackManager.availableBundledPacks()
    guard let manifest = packs.first(where: { $0.id == "swiftpm" })?.tools.first else {
        Issue.record("Missing bundled SwiftPM tool pack")
        return
    }

    let runtime = ToolPackRecordingExecutionRuntime()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let tool = ManifestBackedTool(
        packID: "swiftpm",
        manifest: manifest,
        executionRuntime: runtime,
        workspaceURL: root,
        executionPolicy: toolPackTestShellExecutionPolicy
    )

    _ = try await tool.execute(arguments: [
        "operation": JSONValue.string("build"),
        "package_path": JSONValue.string("Modules/Demo"),
        "configuration": JSONValue.string("release"),
    ], context: ToolContext(runID: UUID(), emit: { _ in }, cancellation: CancellationToken()))

    #expect(runtime.requests.count == 1)
    #expect(runtime.requests[0].command.contains("swift build"))
    #expect(runtime.requests[0].command.contains("--package-path"))
    #expect(runtime.requests[0].command.contains("Modules/Demo"))
    #expect(runtime.requests[0].command.contains("-c"))
    #expect(runtime.requests[0].command.contains("release"))
}

@Test func scaffoldToolCreatesEditableManifest() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let tool = ToolPackScaffoldTool(workspaceGuard: WorkspaceGuard(rootURL: root))

    _ = try await tool.execute(arguments: [
        "operation": .string("scaffold_pack"),
        "pack_id": .string("demo_pack"),
        "name": .string("Demo Pack"),
        "description": .string("A demo pack"),
        "tool_name": .string("demo_tool"),
        "tool_description": .string("Demo tool"),
    ], context: ToolContext(runID: UUID(), emit: { _ in }, cancellation: CancellationToken()))

    let manifestURL = root.appendingPathComponent("toolpacks/demo_pack.json")
    let data = try Data(contentsOf: manifestURL)
    let manifest = try JSONDecoder().decode(ToolPackManifest.self, from: data)

    #expect(manifest.id == "demo_pack")
    #expect(manifest.tools.first?.name == "demo_tool")
    #expect(manifest.tools.first?.operations.first?.name == "example_operation")
}

@Test func runtimeToolFactoryIncludesBundledAndCoreToolsByDefault() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let dbURL = root.appendingPathComponent(".ashex/test.sqlite")
    try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let store = SQLitePersistenceStore(databaseURL: dbURL)
    try store.initialize()

    let tools = try RuntimeToolFactory.makeTools(
        workspaceURL: root,
        persistence: store,
        sandbox: .default,
        shellExecutionPolicy: toolPackTestShellExecutionPolicy
    )
    let names = Set(tools.map { $0.name })

    #expect(names.contains("filesystem"))
    #expect(names.contains("git"))
    #expect(names.contains("build"))
    #expect(names.contains("shell"))
    #expect(names.contains("audio"))
    #expect(names.contains("toolpack"))
    #expect(names.contains("swiftpm"))
    #expect(names.contains("ios_xcode"))
    #expect(names.contains("python"))
}

@Test func sqlitePersistenceInitializationIsIdempotentForToolPackLoading() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let dbURL = root.appendingPathComponent(".ashex/test.sqlite")
    try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let store = SQLitePersistenceStore(databaseURL: dbURL)

    try store.initialize()
    try store.initialize()

    let tools = try RuntimeToolFactory.makeTools(
        workspaceURL: root,
        persistence: store,
        sandbox: .default,
        shellExecutionPolicy: toolPackTestShellExecutionPolicy
    )

    #expect(tools.contains { $0.name == "swiftpm" })
}
