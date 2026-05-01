@testable import AshexCore
import Foundation
import Testing

@Test func projectLearningStoreAppendsEntriesToDedicatedMarkdownFiles() throws {
    let workspaceRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
    let store = ProjectLearningStore(workspaceRoot: workspaceRoot)
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    try store.append(.init(
        id: "learn-001",
        kind: .learning,
        summary: "Prefer focused swift test filters",
        details: "Use the smallest test filter that covers the changed subsystem.",
        tags: ["testing", "swiftpm"],
        source: "worker-d",
        createdAt: date
    ))
    try store.append(.init(
        id: "correction-001",
        kind: .correction,
        summary: "Do not edit shared CLI files from Worker D",
        details: "Leave integration hooks in the final response.",
        tags: ["ownership"],
        source: "assignment",
        createdAt: date
    ))

    let learningsMarkdown = try String(
        contentsOf: workspaceRoot.appendingPathComponent(".learnings/LEARNINGS.md"),
        encoding: .utf8
    )
    let correctionsMarkdown = try String(
        contentsOf: workspaceRoot.appendingPathComponent(".learnings/CORRECTIONS.md"),
        encoding: .utf8
    )

    #expect(learningsMarkdown.contains("# Learnings"))
    #expect(learningsMarkdown.contains("Prefer focused swift test filters"))
    #expect(correctionsMarkdown.contains("# Corrections"))
    #expect(correctionsMarkdown.contains(#""kind":"correction""#))
    #expect(try store.list(kind: .learning).map(\.id) == ["learn-001"])
    #expect(try store.list(kind: .correction).first?.tags == ["ownership"])
}

@Test func projectLearningStoreInitializesAllLearningLogFilesIdempotently() throws {
    let workspaceRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = ProjectLearningStore(workspaceRoot: workspaceRoot)

    try store.initialize()
    try store.initialize()

    #expect(FileManager.default.fileExists(atPath: workspaceRoot.appendingPathComponent(".learnings/LEARNINGS.md").path))
    #expect(FileManager.default.fileExists(atPath: workspaceRoot.appendingPathComponent(".learnings/ERRORS.md").path))
    #expect(FileManager.default.fileExists(atPath: workspaceRoot.appendingPathComponent(".learnings/FEATURE_REQUESTS.md").path))
    #expect(FileManager.default.fileExists(atPath: workspaceRoot.appendingPathComponent(".learnings/CORRECTIONS.md").path))
    #expect(try store.list().isEmpty)
}
