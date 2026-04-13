import AshexCore
import Foundation
import Testing

@Test func symbolExtractorFindsSwiftTypesAndFunctions() {
    let content = """
    import Foundation

    struct ProjectBuilder {
        func createProject() {}
    }

    final class AgentCoordinator {
        func runTask() {}
    }
    """

    let result = SymbolExtractor().extractSymbols(
        from: content,
        relativePath: "Sources/App.swift",
        language: "swift"
    )

    #expect(result.imports.contains("Foundation"))
    #expect(result.symbols.contains { $0.name == "ProjectBuilder" && $0.kind == "struct" })
    #expect(result.symbols.contains { $0.name == "ProjectBuilder.createProject" && $0.kind == "func" })
    #expect(result.symbols.contains { $0.name == "AgentCoordinator" && $0.kind == "class" })
    #expect(result.symbols.contains { $0.name == "AgentCoordinator.runTask" && $0.kind == "func" })
}

@Test func contextQueryEngineUsesSwiftSymbolsForRankingAndRanges() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: root.appendingPathComponent("Sources/AshexCore"), withIntermediateDirectories: true)

    try """
    import Foundation

    struct PromptAssemblyBuilder {
        func buildContextPlanningBrief() {}
    }
    """.write(to: root.appendingPathComponent("Sources/AshexCore/Prompting.swift"), atomically: true, encoding: .utf8)

    try """
    import Foundation

    struct ShellRunner {
        func executeCommand() {}
    }
    """.write(to: root.appendingPathComponent("Sources/AshexCore/Shell.swift"), atomically: true, encoding: .utf8)

    let index = ContextIndexBuilder.build(workspaceRootURL: root)
    let results = ContextQueryEngine().query("PromptAssemblyBuilder buildContextPlanningBrief", in: index, limit: 2)

    #expect(results.first?.filePath == "Sources/AshexCore/Prompting.swift")
    #expect(!(results.first?.suggestedRanges.isEmpty ?? true))
    #expect((results.first?.suggestedRanges.first?.lineStart ?? 0) >= 1)
}
