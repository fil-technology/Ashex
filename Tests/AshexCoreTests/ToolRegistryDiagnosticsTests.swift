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

@Test func toolSpecClassifiesOperationSideEffectLevels() {
    let spec = ToolContract(
        name: "metadata_demo",
        description: "A diagnostic test tool with mixed side effects.",
        category: "test",
        operations: [
            .init(
                name: "inspect",
                description: "Inspect a deterministic test value.",
                mutatesWorkspace: false
            ),
            .init(
                name: "write",
                description: "Write a deterministic test value.",
                mutatesWorkspace: true,
                approval: .init(risk: .medium, summary: "Write test value")
            ),
            .init(
                name: "delete",
                description: "Delete a deterministic test value.",
                mutatesWorkspace: true,
                approval: .init(risk: .high, summary: "Delete test value")
            ),
        ]
    ).toolSpec()

    #expect(spec.safety.sideEffectLevel == .destructive)
    #expect(spec.operations.first { $0.name == "inspect" }?.safety.sideEffectLevel == .readOnly)
    #expect(spec.operations.first { $0.name == "write" }?.safety.sideEffectLevel == .localWrite)
    #expect(spec.operations.first { $0.name == "delete" }?.safety.sideEffectLevel == .destructive)
}

@Test func shellToolSpecKeepsTerminalSideEffectMetadata() {
    let spec = ToolContract(
        name: "shell",
        description: "Execute shell commands inside the workspace with streaming output.",
        category: "shell",
        operationArgumentKey: nil,
        defaultOperationName: "execute",
        operations: [
            .init(
                name: "execute",
                description: "Run a shell command in the current workspace.",
                mutatesWorkspace: true,
                requiresNetwork: true,
                approval: .init(risk: .medium, summary: "Shell command")
            )
        ],
        tags: ["shell"]
    ).toolSpec()

    #expect(spec.safety.sideEffectLevel == .shellCommand)
    #expect(ToolRegistry(tools: [ShellMetadataTestTool()]).schema().first?.sideEffectLevel == .shellCommand)
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

private struct ShellMetadataTestTool: Tool {
    let name = "shell"
    let description = "Execute shell commands inside the workspace with streaming output."

    let contract = ToolContract(
        name: "shell",
        description: "Execute shell commands inside the workspace with streaming output.",
        category: "shell",
        operationArgumentKey: nil,
        defaultOperationName: "execute",
        operations: [
            .init(
                name: "execute",
                description: "Run a shell command in the current workspace.",
                mutatesWorkspace: true,
                requiresNetwork: true,
                approval: .init(risk: .medium, summary: "Shell command")
            )
        ],
        tags: ["shell"]
    )

    func execute(arguments _: JSONObject, context _: ToolContext) async throws -> ToolContent {
        .text("ok")
    }
}
