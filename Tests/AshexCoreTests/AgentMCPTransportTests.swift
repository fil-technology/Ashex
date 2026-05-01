import AshexCore
import Foundation
import Testing

@Test func mcpRefreshPrefixesDiscoveredToolsAndAppliesAllowDenyFilters() async throws {
    let fixedDate = Date(timeIntervalSince1970: 1_800)
    let config = AgentMCPConfig(servers: [
        .init(
            id: "linear",
            namespace: "linear",
            transport: .http(.init(url: URL(string: "https://mcp.example.test/linear")!)),
            filter: .init(allow: ["read_issue", "create_issue"], deny: ["create_issue"])
        ),
        .init(
            id: "filesystem",
            namespace: "fs",
            transport: .stdio(.init(command: "npx", arguments: ["-y", "@modelcontextprotocol/server-filesystem"]))
        ),
    ])
    let discovery = AgentMCPMockToolDiscovery(fixtures: [
        "linear": [
            mcpTool("read_issue"),
            mcpTool("create_issue"),
            mcpTool("delete_issue"),
        ],
        "filesystem": [
            mcpTool("read_file"),
        ],
    ])
    let namespace = AgentMCPToolNamespace(config: config, discovery: discovery)

    let snapshot = try await namespace.refresh(now: fixedDate)

    #expect(snapshot.tools.map(\.name) == ["fs__read_file", "linear__read_issue"])
    #expect(snapshot.tools.first { $0.name == "linear__read_issue" }?.sourceName == "read_issue")
    #expect(snapshot.tools.first { $0.name == "linear__read_issue" }?.serverID == "linear")
    #expect(snapshot.metadata.refreshedAt == fixedDate)
    #expect(snapshot.metadata.servers.first { $0.serverID == "linear" }?.discoveredToolCount == 3)
    #expect(snapshot.metadata.servers.first { $0.serverID == "linear" }?.publishedToolCount == 1)
    #expect(snapshot.metadata.servers.first { $0.serverID == "filesystem" }?.transportKind == .stdio)
}

@Test func liveMCPStdioDiscoveryListsToolsResourcesAndPrompts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = root.appendingPathComponent("fixture-mcp.sh")
    try """
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\\n' '{"jsonrpc":"2.0","id":"initialize-1","result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{},"resources":{},"prompts":{}},"serverInfo":{"name":"fixture","version":"1"}}}'
          ;;
        *'"method":"tools\\/list"'*)
          printf '%s\\n' '{"jsonrpc":"2.0","id":"list-1","result":{"tools":[{"name":"lookup","title":"Lookup","description":"Look up records","inputSchema":{"type":"object"}}]}}'
          ;;
        *'"method":"resources\\/list"'*)
          printf '%s\\n' '{"jsonrpc":"2.0","id":"list-1","result":{"resources":[{"uri":"file:///tmp/example.txt","name":"example","mimeType":"text/plain"}]}}'
          ;;
        *'"method":"prompts\\/list"'*)
          printf '%s\\n' '{"jsonrpc":"2.0","id":"list-1","result":{"prompts":[{"name":"review","description":"Review code"}]}}'
          ;;
        *'"method":"tools\\/call"'*)
          printf '%s\\n' '{"jsonrpc":"2.0","id":"call-1","result":{"content":[{"type":"text","text":"lookup ok"}],"structuredContent":{"answer":"ok"},"isError":false}}'
          ;;
      esac
    done
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let server = AgentMCPServerDescriptor(
        id: "fixture",
        namespace: "fixture",
        transport: .stdio(.init(command: script.path))
    )
    let discovery = AgentMCPLiveDiscovery(timeout: 2)

    let tools = try await discovery.listItems(for: server, kind: .tools)
    let resources = try await discovery.listItems(for: server, kind: .resources)
    let prompts = try await discovery.listItems(for: server, kind: .prompts)
    let contracts = try await discovery.discoverTools(for: server)
    let call = try await AgentMCPLiveToolCaller(timeout: 2).callTool(
        server: server,
        toolName: "lookup",
        arguments: ["query": .string("demo")]
    )

    #expect(tools.map(\.name) == ["lookup"])
    #expect(tools.first?.description == "Look up records")
    #expect(resources.first?.uri == "file:///tmp/example.txt")
    #expect(prompts.map(\.name) == ["review"])
    #expect(contracts.first?.name == "lookup")
    #expect(contracts.first?.tags.contains("mcp:fixture") == true)
    #expect(call.serverID == "fixture")
    #expect(call.toolName == "lookup")
    #expect(call.isError == false)
    #expect(call.result["structuredContent"]?.objectValue?["answer"]?.stringValue == "ok")
}

private func mcpTool(_ name: String) -> ToolContract {
    ToolContract(
        name: name,
        description: "\(name) description",
        operations: [
            .init(
                name: "call",
                description: "Call \(name)",
                mutatesWorkspace: false
            )
        ]
    )
}
