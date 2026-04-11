import AshexCore
import Foundation
import Testing

@Test func contextQueryEnginePrefersRelevantImplementationFiles() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: root.appendingPathComponent("Sources/AshexCore"), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: root.appendingPathComponent("Tests/AshexCoreTests"), withIntermediateDirectories: true)

    try """
    import Foundation

    struct PromptBuilder {
        func buildPlanningBrief() {}
    }
    """.write(to: root.appendingPathComponent("Sources/AshexCore/Prompting.swift"), atomically: true, encoding: .utf8)

    try """
    import Foundation

    final class AgentRuntime {
        func executeStep() {}
    }
    """.write(to: root.appendingPathComponent("Sources/AshexCore/AgentRuntime.swift"), atomically: true, encoding: .utf8)

    try """
    import Testing

    @Test func testPromptBuilder() {}
    """.write(to: root.appendingPathComponent("Tests/AshexCoreTests/PromptingTests.swift"), atomically: true, encoding: .utf8)

    let index = ContextIndexBuilder.build(workspaceRootURL: root)
    let results = ContextQueryEngine().query("planning brief prompt builder", in: index, limit: 3)

    #expect(!results.isEmpty)
    #expect(results.first?.filePath == "Sources/AshexCore/Prompting.swift")
    #expect(results.contains { $0.filePath == "Sources/AshexCore/AgentRuntime.swift" })
}

@Test func contextPlanningServiceBuildsBriefWithSurgicalReads() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: root.appendingPathComponent("Sources/AshexCore"), withIntermediateDirectories: true)

    try """
    import Foundation

    struct ContextPlanningBrief {}
    struct ContextQueryEngine {}
    """.write(to: root.appendingPathComponent("Sources/AshexCore/ContextPlanning.swift"), atomically: true, encoding: .utf8)

    let brief = ContextPlanningService().makeBrief(
        task: "context planning brief query engine",
        workspaceRootURL: root
    )

    #expect(brief.summary.contains("Likely starting points"))
    #expect(!brief.rankedResults.isEmpty)
    #expect(!brief.snippets.isEmpty)
    #expect(brief.suggestedNextSteps.contains { $0.contains("Inspect") })
}
