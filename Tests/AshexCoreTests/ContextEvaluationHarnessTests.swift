import AshexCore
import Foundation
import Testing

@Test func contextEvaluationHarnessScoresFixtureQueries() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: root.appendingPathComponent("Sources/AshexCore"), withIntermediateDirectories: true)

    try """
    import Foundation

    public struct ContextPlanningBrief {}
    public struct RankedContextResult {}
    public struct ContextPlanningService {}
    """.write(to: root.appendingPathComponent("Sources/AshexCore/ContextPlanning.swift"), atomically: true, encoding: .utf8)

    try """
    import Foundation

    public struct AgentRuntime {
        func phaseStrategyBlock() {}
    }
    """.write(to: root.appendingPathComponent("Sources/AshexCore/AgentRuntime.swift"), atomically: true, encoding: .utf8)

    try """
    import Foundation

    public struct GitTool {
        func add() {}
        func commit() {}
        func push() {}
        func createBranch() {}
    }
    """.write(to: root.appendingPathComponent("Sources/AshexCore/GitTool.swift"), atomically: true, encoding: .utf8)

    try """
    import Foundation

    public struct ToolExecutor {
        func gitValidationArtifacts() {}
    }
    """.write(to: root.appendingPathComponent("Sources/AshexCore/ToolExecutor.swift"), atomically: true, encoding: .utf8)

    try """
    import Foundation

    public struct PromptBuilder {
        func toolContract() {}
        func gitOperations() {}
    }
    """.write(to: root.appendingPathComponent("Sources/AshexCore/Prompting.swift"), atomically: true, encoding: .utf8)

    try """
    import Foundation

    public struct ModelAdapter {
        func responseSchema() {}
        func gitArguments() {}
    }
    """.write(to: root.appendingPathComponent("Sources/AshexCore/ModelAdapter.swift"), atomically: true, encoding: .utf8)

    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/context-eval.json")
    let fixtureData = try Data(contentsOf: fixtureURL)
    let cases = try JSONDecoder().decode([ContextEvaluationCase].self, from: fixtureData)

    let index = ContextIndexBuilder.build(workspaceRootURL: root)
    let report = ContextEvaluationHarness().evaluate(cases: cases, index: index, limit: 3)

    #expect(report.caseCount == 3)
    #expect(report.top1Hits >= 2)
    #expect(report.top3Hits == 3)
    #expect(report.meanReciprocalRank > 0.8)
    #expect(report.queries.allSatisfy { $0.firstRelevantRank != nil })
}
