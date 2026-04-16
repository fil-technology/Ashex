@testable import AshexCore
import Foundation
import Testing

@Test func githubRepoToolInspectsListsReadsAndSearchesRemoteRepository() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let repositoryURL = root.appendingPathComponent("fixture-repo", isDirectory: true)
    try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)

    try """
    # ASO Skills

    Toolkit for exploring App Store Optimization automations.
    """.write(to: repositoryURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: repositoryURL.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    try """
    struct SkillIndex {
        let title = "ASO"
    }
    """.write(to: repositoryURL.appendingPathComponent("Sources/SkillIndex.swift"), atomically: true, encoding: .utf8)

    try runFixtureCommand("git init -b main", in: repositoryURL)
    try runFixtureCommand("git add -A", in: repositoryURL)
    try runFixtureCommand("git -c user.name='Test User' -c user.email='test@example.com' commit -m 'Initial fixture'", in: repositoryURL)

    let tool = GitHubRepoTool(executionRuntime: ProcessExecutionRuntime())
    let context = ToolContext(runID: UUID(), emit: { _ in }, cancellation: CancellationToken())

    let inspectResult = try await tool.execute(arguments: [
        "operation": .string("inspect_repository"),
        "repository_url": .string(repositoryURL.path),
        "refresh_remote": .bool(false),
    ], context: context)
    let listResult = try await tool.execute(arguments: [
        "operation": .string("list_files"),
        "repository_url": .string(repositoryURL.path),
        "recursive": .bool(true),
        "refresh_remote": .bool(false),
    ], context: context)
    let readResult = try await tool.execute(arguments: [
        "operation": .string("read_file"),
        "repository_url": .string(repositoryURL.path),
        "path": .string("README.md"),
        "refresh_remote": .bool(false),
    ], context: context)
    let searchResult = try await tool.execute(arguments: [
        "operation": .string("search_text"),
        "repository_url": .string(repositoryURL.path),
        "query": .string("ASO"),
        "refresh_remote": .bool(false),
    ], context: context)

    let inspectObject = try #require(inspectResult.structuredObject)
    let listObject = try #require(listResult.structuredObject)
    let readObject = try #require(readResult.structuredObject)
    let searchObject = try #require(searchResult.structuredObject)

    #expect(inspectObject["top_level_entries"]?.arrayValue?.contains(.string("README.md")) == true)
    #expect(inspectObject["readme_excerpt"]?.stringValue?.contains("ASO Skills") == true)
    #expect(listObject["entries"]?.arrayValue?.contains(.string("Sources/SkillIndex.swift")) == true)
    #expect(readObject["content"]?.stringValue?.contains("Toolkit for exploring App Store Optimization") == true)
    #expect(searchObject["matches"]?.arrayValue?.contains(where: { $0.stringValue?.contains("ASO") == true }) == true)
}

private func runFixtureCommand(_ command: String, in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", command]
    process.currentDirectoryURL = directory
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw AshexError.shell("Fixture command failed: \(command)\n\(errorText)")
    }
}

private extension ToolContent {
    var structuredObject: JSONObject? {
        guard case .structured(.object(let object)) = self else { return nil }
        return object
    }
}
