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
