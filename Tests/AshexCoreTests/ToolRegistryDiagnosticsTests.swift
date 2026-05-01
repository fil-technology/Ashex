import AshexCore
import Foundation
import Testing

@Test func toolRegistryDiagnosticsPassesForWellFormedTool() {
    let report = ToolRegistryDiagnostics.inspect(tools: [DiagnosticTestTool(name: "demo_tool")])

    #expect(report.status == .pass)
    #expect(report.toolCount == 1)
    #expect(report.duplicateToolNames.isEmpty)
    #expect(report.issues.isEmpty)
}

@Test func toolRegistryDiagnosticsDetectsDuplicateToolNames() {
    let report = ToolRegistryDiagnostics.inspect(tools: [
        DiagnosticTestTool(name: "duplicate"),
        DiagnosticTestTool(name: "duplicate"),
    ])

    #expect(report.status == .fail)
    #expect(report.duplicateToolNames == ["duplicate"])
    #expect(report.issues.contains { $0.subject == "duplicate" && $0.severity == .fail })
}

private struct DiagnosticTestTool: Tool {
    let name: String
    let description = "A diagnostic test tool with a complete contract."

    var contract: ToolContract {
        ToolContract(
            name: name,
            description: description,
            category: "test",
            operations: [
                .init(
                    name: "inspect",
                    description: "Inspect a deterministic test value.",
                    mutatesWorkspace: false,
                    arguments: [
                        .init(name: "value", description: "Value to inspect.", type: .string, required: false)
                    ]
                )
            ]
        )
    }

    func execute(arguments _: JSONObject, context _: ToolContext) async throws -> ToolContent {
        .text("ok")
    }
}
