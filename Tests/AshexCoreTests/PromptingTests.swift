import AshexCore
import Foundation
import Testing

@Test func promptBuilderPrefersBrowserToolsForWebsiteQuestions() throws {
    let thread = ThreadRecord(id: UUID(), createdAt: Date())
    let run = RunRecord(id: UUID(), threadID: thread.id, state: .running, createdAt: Date(), updatedAt: Date())
    let context = ModelContext(
        thread: thread,
        run: run,
        messages: [
            .init(
                id: UUID(),
                threadID: thread.id,
                runID: run.id,
                role: .user,
                content: "what is filsv.com?",
                createdAt: Date()
            ),
        ],
        availableTools: [
            .init(name: "filesystem", description: "Read and inspect local workspace files."),
            .init(
                name: "browser_fetch",
                description: "Render a web page and extract readable markdown or text.",
                category: "browser",
                operationArgumentKey: nil,
                defaultOperationName: "fetch",
                operations: [
                    .init(
                        name: "fetch",
                        description: "Navigate to a page and extract readable content.",
                        mutatesWorkspace: false,
                        requiresNetwork: true,
                        arguments: [
                            .init(name: "url", description: "Absolute URL", type: .string, required: true),
                        ]
                    ),
                ],
                tags: ["browser", "web"]
            ),
        ]
    )

    let assembly = PromptBuilder.build(for: context, provider: "ollama", model: "granite4:1b")

    #expect(assembly.systemPrompt.contains("prefer `browser_fetch`, `browser_extract`, `browser_eval`, or `browser_screenshot` before filesystem tools"))
    #expect(assembly.systemPrompt.contains("do not infer answers from the local repository"))
    #expect(assembly.userPrompt.contains("browser_fetch"))
    #expect(assembly.userPrompt.contains("what is filsv.com?"))
}
