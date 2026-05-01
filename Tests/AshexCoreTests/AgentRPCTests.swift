import AshexCore
import Foundation
import Testing

@Test func rpcTransportListsRegisteredSchemasAndEvaluatesPolicyBeforeToolExecution() async throws {
    let safe = RecordingRPCTool(name: "safe_tool", output: "safe output")
    let blocked = RecordingRPCTool(name: "blocked_tool", output: "blocked output")
    let policy = AgentRPCStaticPolicy(deniedToolNames: ["blocked_tool"])
    let server = AgentRPCServer(registry: ToolRegistry(tools: [safe, blocked]), policy: policy)
    let transport = AgentRPCInProcessTransport(server: server)

    let listed = try await transport.send(.listTools(id: "list-1"))
    #expect(listed.id == "list-1")
    #expect(listed.result?.tools.map(\.name) == ["blocked_tool", "safe_tool"])

    let denied = try await transport.send(.callTool(
        id: "call-1",
        toolName: "blocked_tool",
        arguments: ["input": .string("no")]
    ))
    #expect(denied.id == "call-1")
    #expect(denied.result?.toolCall?.status == .denied)
    #expect(denied.result?.toolCall?.policyDecision.allowed == false)
    #expect(await blocked.callCount == 0)

    let allowed = try await transport.send(.callTool(
        id: "call-2",
        toolName: "safe_tool",
        arguments: ["input": .string("yes")]
    ))
    #expect(allowed.result?.toolCall?.status == .completed)
    #expect(allowed.result?.toolCall?.content == .text("safe output"))
    #expect(await safe.callCount == 1)
}

private actor RecordingRPCTool: Tool {
    let name: String
    let description: String = "Recording test tool"
    private(set) var callCount = 0
    private let output: String

    init(name: String, output: String) {
        self.name = name
        self.output = output
    }

    nonisolated var contract: ToolContract {
        ToolContract(
            name: name,
            description: description,
            operations: [
                .init(
                    name: "run",
                    description: "Run",
                    mutatesWorkspace: false,
                    arguments: [
                        .init(name: "input", description: "Input", type: .string, required: false)
                    ]
                )
            ]
        )
    }

    func execute(arguments: JSONObject, context: ToolContext) async throws -> ToolContent {
        callCount += 1
        return .text(output)
    }
}
