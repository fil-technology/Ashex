import Foundation
import Testing
@testable import AshexCore

@Test func graphifyStatusReportsMissingExecutableAndGraph() async throws {
    let root = try temporaryDirectory()
    let service = GraphifyService(
        projectRoot: root,
        runner: MockGraphifyRunner(),
        environment: ["PATH": root.appendingPathComponent("empty").path]
    )

    let status = await service.status()

    #expect(status.installed == false)
    #expect(status.graphExists == false)
    #expect(status.reportExists == false)
    #expect(status.recommendedNextAction.contains("Install Graphify"))
}

@Test func graphifyStatusReadsGraphReportAndState() async throws {
    let root = try temporaryDirectory()
    let output = root.appendingPathComponent("graphify-out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try "{}".write(to: output.appendingPathComponent("graph.json"), atomically: true, encoding: .utf8)
    try "# Graph".write(to: output.appendingPathComponent("GRAPH_REPORT.md"), atomically: true, encoding: .utf8)

    let executable = root.appendingPathComponent("graphify")
    try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let service = GraphifyService(
        projectRoot: root,
        runner: MockGraphifyRunner(result: .init(stdout: "graphify 0.6.0\n", stderr: "", exitCode: 0)),
        environment: ["PATH": root.path]
    )
    try service.writeStateMetadata(.init(
        projectRoot: root.path,
        lastBuildAt: Date(timeIntervalSince1970: 1_800_000_000),
        graphifyVersion: "0.6.0",
        graphPath: service.graphPath.path,
        reportPath: service.reportPath.path,
        sourceHash: "abc",
        status: "ready"
    ))

    let status = await service.status()

    #expect(status.installed == true)
    #expect(status.version == "graphify 0.6.0")
    #expect(status.graphExists == true)
    #expect(status.reportExists == true)
    #expect(status.stateStatus == "ready")
    #expect(status.recommendedNextAction.contains("Graph is ready"))
}

@Test func graphifyQueryBuildsCommandAndSummarizesOutput() async throws {
    let root = try temporaryDirectory()
    let output = root.appendingPathComponent("graphify-out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try "{}".write(to: output.appendingPathComponent("graph.json"), atomically: true, encoding: .utf8)

    let executable = root.appendingPathComponent("graphify")
    try "".write(to: executable, atomically: true, encoding: .utf8)
    let runner = MockGraphifyRunner(result: .init(stdout: "node A\nnode B\n", stderr: "", exitCode: 0))
    let service = GraphifyService(projectRoot: root, runner: runner, executableURL: executable)

    let result = try await service.query(question: "auth flow", useDFS: true, budget: 500)

    #expect(result.operation == "query")
    #expect(result.summary == "node A\nnode B")
    #expect(await runner.calls == [
        .init(executablePath: executable.path, arguments: [
            "query",
            "auth flow",
            "--dfs",
            "--budget",
            "500",
            "--graph",
            output.appendingPathComponent("graph.json").path,
        ], workingDirectory: root.path)
    ])
}

@Test func graphifyCommandBuilderBuildsPathAndExplainArguments() {
    let graph = URL(fileURLWithPath: "/tmp/project/graphify-out/graph.json")

    #expect(GraphifyCommandBuilder.pathArguments(source: "A", target: "B", graphPath: graph) == [
        "path",
        "A",
        "B",
        "--graph",
        "/tmp/project/graphify-out/graph.json",
    ])
    #expect(GraphifyCommandBuilder.explainArguments(node: "Runtime", graphPath: graph) == [
        "explain",
        "Runtime",
        "--graph",
        "/tmp/project/graphify-out/graph.json",
    ])
}

@Test func graphifyReportCanReturnTruncatedContent() throws {
    let root = try temporaryDirectory()
    let output = root.appendingPathComponent("graphify-out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try "abcdef".write(to: output.appendingPathComponent("GRAPH_REPORT.md"), atomically: true, encoding: .utf8)

    let report = try GraphifyService(projectRoot: root, runner: MockGraphifyRunner()).report(maxCharacters: 3)

    #expect(report.exists == true)
    #expect(report.content == "abc")
    #expect(report.truncated == true)
}

@Test func graphifyRebuildRunsUpdateAndWritesState() async throws {
    let root = try temporaryDirectory()
    let output = root.appendingPathComponent("graphify-out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try "{}".write(to: output.appendingPathComponent("graph.json"), atomically: true, encoding: .utf8)
    try "# Graph".write(to: output.appendingPathComponent("GRAPH_REPORT.md"), atomically: true, encoding: .utf8)

    let executable = root.appendingPathComponent("graphify")
    try "".write(to: executable, atomically: true, encoding: .utf8)
    let runner = MockGraphifyRunner(result: .init(stdout: "updated\n", stderr: "", exitCode: 0))
    let service = GraphifyService(projectRoot: root, runner: runner, executableURL: executable)

    let result = try await service.rebuild()

    #expect(result.operation == "rebuild")
    #expect(await runner.calls == [
        .init(executablePath: executable.path, arguments: ["update", root.path], workingDirectory: root.path)
    ])
    #expect(service.readStateMetadata()?.status == "ready")
    #expect(service.readStateMetadata()?.graphPath == output.appendingPathComponent("graph.json").path)
}

@Test func graphifyClusterOnlyRunsClusterCommand() async throws {
    let root = try temporaryDirectory()
    let output = root.appendingPathComponent("graphify-out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try "{}".write(to: output.appendingPathComponent("graph.json"), atomically: true, encoding: .utf8)

    let executable = root.appendingPathComponent("graphify")
    try "".write(to: executable, atomically: true, encoding: .utf8)
    let runner = MockGraphifyRunner(result: .init(stdout: "clustered\n", stderr: "", exitCode: 0))
    let service = GraphifyService(projectRoot: root, runner: runner, executableURL: executable)

    _ = try await service.clusterOnly()

    #expect(await runner.calls == [
        .init(executablePath: executable.path, arguments: ["cluster-only", root.path], workingDirectory: root.path)
    ])
}

@Test func graphifyCleanRequiresConfirmationAndRemovesOutput() throws {
    let root = try temporaryDirectory()
    let output = root.appendingPathComponent("graphify-out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try "{}".write(to: output.appendingPathComponent("graph.json"), atomically: true, encoding: .utf8)
    let service = GraphifyService(projectRoot: root, runner: MockGraphifyRunner())
    try service.writeStateMetadata(.init(
        projectRoot: root.path,
        lastBuildAt: Date(),
        graphifyVersion: nil,
        graphPath: service.graphPath.path,
        reportPath: nil,
        sourceHash: nil,
        status: "ready"
    ))

    #expect(throws: Error.self) {
        try service.clean(confirm: false)
    }

    let result = try service.clean(confirm: true)

    #expect(result.removedPaths.contains(output.path))
    #expect(FileManager.default.fileExists(atPath: output.path) == false)
    #expect(FileManager.default.fileExists(atPath: service.statePath.path) == false)
}

@Test func graphifyPlanningPolicyChoosesGraphForArchitectureButSkipsTinyKnownFileEdits() {
    #expect(GraphifyPlanningPolicy.shouldUseGraphContext(
        prompt: "How does memory persistence work across modules in this repo?",
        taskKind: .analysis
    ))
    #expect(GraphifyPlanningPolicy.shouldUseGraphContext(
        prompt: "Refactor tool calling to be safer",
        taskKind: .refactor
    ))
    #expect(GraphifyPlanningPolicy.shouldUseGraphContext(
        prompt: "Fix this build failure across runtime and tool modules",
        taskKind: .bugFix
    ))
    #expect(GraphifyPlanningPolicy.shouldUseGraphContext(
        prompt: "Update README.md title",
        taskKind: .docs
    ) == false)
    #expect(GraphifyPlanningPolicy.shouldUseGraphContext(
        prompt: "git status",
        taskKind: .git
    ) == false)
}

@Test func knowledgeGraphProviderExtractsRelatedFilesAndRendersContextBlock() {
    let root = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
    let files = KnowledgeGraphProvider.extractRelatedFiles(
        from: "Source: Sources/AshexCore/AgentRuntime.swift and docs/GRAPHIFY_RESEARCH.md",
        projectRoot: root
    )

    #expect(files.map(\.path) == [
        "/tmp/project/Sources/AshexCore/AgentRuntime.swift",
        "/tmp/project/docs/GRAPHIFY_RESEARCH.md",
    ])

    let block = KnowledgeGraphProvider.renderContextBlock(.init(
        projectRoot: root,
        graphExists: true,
        lastBuiltAt: nil,
        reportPath: root.appendingPathComponent("graphify-out/GRAPH_REPORT.md"),
        querySummary: "Runtime connects to tool execution.",
        relatedFiles: files,
        confidence: 0.8
    ), question: "How does runtime work?")

    #expect(block.contains("<project_graph_context>"))
    #expect(block.contains("Runtime connects to tool execution."))
    #expect(block.contains("/tmp/project/Sources/AshexCore/AgentRuntime.swift"))
}

@Test func knowledgeGraphProviderUsesQueryForArchitectureFlow() async throws {
    let root = try temporaryDirectory()
    let output = root.appendingPathComponent("graphify-out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try "{}".write(to: output.appendingPathComponent("graph.json"), atomically: true, encoding: .utf8)

    let executable = root.appendingPathComponent("graphify")
    let prompt = "How does architecture flow from runtime to tool execution?"
    let runner = MockGraphifyRunner(result: .init(
        stdout: "Runtime connects through Sources/AshexCore/AgentRuntime.swift and Sources/AshexCore/ToolExecutor.swift",
        stderr: "",
        exitCode: 0
    ))
    let provider = KnowledgeGraphProvider(service: GraphifyService(projectRoot: root, runner: runner, executableURL: executable))

    let context = await provider.context(for: prompt, taskKind: .analysis)

    #expect(context?.confidence == 0.8)
    #expect(context?.querySummary?.contains("Runtime connects") == true)
    #expect(context?.relatedFiles.map(\.lastPathComponent) == ["AgentRuntime.swift", "ToolExecutor.swift"])
    #expect(await runner.calls == [
        .init(executablePath: executable.path, arguments: [
            "query",
            prompt,
            "--budget",
            "1200",
            "--graph",
            output.appendingPathComponent("graph.json").path,
        ], workingDirectory: root.path)
    ])
}

@Test func knowledgeGraphProviderUsesQueryForRefactorFlow() async throws {
    let root = try temporaryDirectory()
    let output = root.appendingPathComponent("graphify-out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try "{}".write(to: output.appendingPathComponent("graph.json"), atomically: true, encoding: .utf8)

    let executable = root.appendingPathComponent("graphify")
    let runner = MockGraphifyRunner(result: .init(
        stdout: "Refactor touches Sources/AshexCore/Prompting.swift and Sources/AshexCore/GraphifyService.swift",
        stderr: "",
        exitCode: 0
    ))
    let provider = KnowledgeGraphProvider(service: GraphifyService(projectRoot: root, runner: runner, executableURL: executable))

    let context = await provider.context(
        for: "Refactor planner graph context to stay bounded before file inspection",
        taskKind: .refactor
    )

    #expect(context?.confidence == 0.8)
    #expect(context?.relatedFiles.map(\.lastPathComponent) == ["Prompting.swift", "GraphifyService.swift"])
}

@Test func knowledgeGraphProviderFallsBackToReportForBuildFailureFlow() async throws {
    let root = try temporaryDirectory()
    let output = root.appendingPathComponent("graphify-out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try "{}".write(to: output.appendingPathComponent("graph.json"), atomically: true, encoding: .utf8)
    try """
    Build failure orientation:
    Sources/AshexCore/ModelAdapter.swift owns native tool schema descriptions.
    Sources/AshexCore/Prompting.swift renders tool safety hints.
    """.write(to: output.appendingPathComponent("GRAPH_REPORT.md"), atomically: true, encoding: .utf8)

    let executable = root.appendingPathComponent("graphify")
    let runner = MockGraphifyRunner(result: .init(stdout: "", stderr: "query failed", exitCode: 2))
    let provider = KnowledgeGraphProvider(service: GraphifyService(projectRoot: root, runner: runner, executableURL: executable))

    let context = await provider.context(
        for: "Fix this build failure across runtime and model tool schema modules",
        taskKind: .bugFix
    )

    #expect(context?.confidence == 0.5)
    #expect(context?.querySummary?.contains("Build failure orientation") == true)
    #expect(context?.relatedFiles.map(\.lastPathComponent) == ["ModelAdapter.swift", "Prompting.swift"])
    #expect(await runner.calls.count == 1)
}

private struct GraphifyRunnerCall: Equatable {
    let executablePath: String
    let arguments: [String]
    let workingDirectory: String
}

private actor MockGraphifyRunner: GraphifyCommandRunning {
    private let result: GraphifyCommandResult
    private(set) var calls: [GraphifyRunnerCall] = []

    init(result: GraphifyCommandResult = .init(stdout: "", stderr: "", exitCode: 0)) {
        self.result = result
    }

    func runGraphify(executableURL: URL, arguments: [String], workingDirectory: URL, timeout _: TimeInterval) async throws -> GraphifyCommandResult {
        calls.append(.init(executablePath: executableURL.path, arguments: arguments, workingDirectory: workingDirectory.path))
        return result
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ashex-graphify-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.standardizedFileURL
}
