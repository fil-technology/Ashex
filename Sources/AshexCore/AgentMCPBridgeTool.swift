import Foundation

public struct AgentMCPBridgeTool: Tool {
    public let name = "mcp"
    public let description = "Discover and call tools exposed by configured external MCP servers"
    public let contract = ToolContract(
        name: "mcp",
        description: "Discover and call tools exposed by configured external MCP servers",
        kind: .embedded,
        category: "mcp",
        operationArgumentKey: "operation",
        operations: [
            .init(
                name: "list",
                description: "List tools, resources, or prompts from one configured MCP server or all enabled servers",
                mutatesWorkspace: false,
                requiresNetwork: true,
                inspectedPathArguments: ["server"],
                progressSummary: "listed MCP capabilities",
                arguments: [
                    .init(name: "kind", description: "Capability kind to list", type: .string, required: false, enumValues: AgentMCPListKind.allCases.map(\.rawValue)),
                    .init(name: "server", description: "Optional MCP server name or namespace", type: .string, required: false),
                ]
            ),
            .init(
                name: "call",
                description: "Call an external MCP tool through the configured server transport",
                mutatesWorkspace: false,
                requiresNetwork: true,
                progressSummary: "called external MCP tool",
                approval: .init(risk: .medium, summary: "Call external MCP tool", reasonTemplate: "{{server}}/{{tool}}"),
                arguments: [
                    .init(name: "server", description: "MCP server name or namespace", type: .string, required: true),
                    .init(name: "tool", description: "Unprefixed tool name on the MCP server", type: .string, required: true),
                    .init(name: "arguments", description: "JSON object arguments to pass to the external MCP tool", type: .object, required: false),
                ]
            ),
        ],
        tags: ["mcp", "external-tools"]
    )

    private let home: AgentHome
    private let discovery: any AgentMCPToolDiscovery
    private let liveDiscovery: AgentMCPLiveDiscovery
    private let caller: any AgentMCPToolCalling

    public init(
        home: AgentHome,
        discovery: AgentMCPLiveDiscovery = AgentMCPLiveDiscovery(),
        caller: any AgentMCPToolCalling = AgentMCPLiveToolCaller()
    ) {
        self.home = home
        self.discovery = discovery
        self.liveDiscovery = discovery
        self.caller = caller
    }

    public init(
        home: AgentHome,
        discovery: any AgentMCPToolDiscovery,
        caller: any AgentMCPToolCalling
    ) {
        self.home = home
        self.discovery = discovery
        self.liveDiscovery = AgentMCPLiveDiscovery()
        self.caller = caller
    }

    public func execute(arguments: JSONObject, context: ToolContext) async throws -> ToolContent {
        try await context.cancellation.checkCancellation()
        try home.initialize()
        let operation = arguments["operation"]?.stringValue ?? "list"
        switch operation {
        case "list":
            return try await list(arguments: arguments)
        case "call":
            return try await call(arguments: arguments)
        default:
            throw AshexError.invalidToolArguments("mcp.operation must be one of: list, call")
        }
    }

    private func list(arguments: JSONObject) async throws -> ToolContent {
        let config = try AgentMCPRegistry(home: home).discoveryConfig()
        let selectedServers = try servers(from: config, rawServer: arguments["server"]?.stringValue)
        let kindRaw = arguments["kind"]?.stringValue ?? AgentMCPListKind.tools.rawValue
        guard let kind = AgentMCPListKind(rawValue: kindRaw) else {
            throw AshexError.invalidToolArguments("mcp.kind must be one of: \(AgentMCPListKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }

        var serverObjects: [JSONValue] = []
        for server in selectedServers {
            let items: [AgentMCPDiscoveredItem]
            if discovery is AgentMCPLiveDiscovery {
                items = try await liveDiscovery.listItems(for: server, kind: kind)
            } else if kind == .tools {
                let tools = try await discovery.discoverTools(for: server)
                items = tools.map {
                    AgentMCPDiscoveredItem(
                        name: $0.name,
                        description: $0.description,
                        raw: .object([
                            "name": .string($0.name),
                            "description": .string($0.description),
                        ])
                    )
                }
            } else {
                items = []
            }
            serverObjects.append(.object([
                "server": .string(server.id),
                "namespace": .string(server.namespace),
                "kind": .string(kind.rawValue),
                "items": .array(items.map(mcpItemJSON)),
            ]))
        }

        return .structured(.object([
            "operation": .string("list"),
            "servers": .array(serverObjects),
        ]))
    }

    private func call(arguments: JSONObject) async throws -> ToolContent {
        let config = try AgentMCPRegistry(home: home).discoveryConfig()
        let server = try server(from: config, rawServer: try requiredString("server", in: arguments))
        let toolName = try requiredString("tool", in: arguments)
        let toolArguments = arguments["arguments"]?.objectValue ?? [:]
        let result = try await caller.callTool(server: server, toolName: toolName, arguments: toolArguments)

        var object: JSONObject = [
            "operation": .string("call"),
            "server": .string(result.serverID),
            "namespace": .string(server.namespace),
            "tool": .string(result.toolName),
            "is_error": .bool(result.isError),
            "result": .object(result.result),
        ]
        if let structured = result.result["structuredContent"] {
            object["structured_content"] = structured
        }
        if let content = result.result["content"] {
            object["content"] = content
        }
        return .structured(.object(object))
    }

    private func servers(from config: AgentMCPConfig, rawServer: String?) throws -> [AgentMCPServerDescriptor] {
        let enabledServers = config.servers.filter(\.enabled)
        guard let rawServer = rawServer?.trimmingCharacters(in: .whitespacesAndNewlines), !rawServer.isEmpty else {
            return enabledServers
        }
        return [try server(from: config, rawServer: rawServer)]
    }

    private func server(from config: AgentMCPConfig, rawServer: String) throws -> AgentMCPServerDescriptor {
        let normalized = rawServer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let server = config.servers.first(where: { $0.enabled && ($0.id == normalized || $0.namespace == normalized) }) else {
            throw AshexError.toolNotFound("MCP server '\(normalized)'")
        }
        return server
    }

    private func requiredString(_ key: String, in arguments: JSONObject) throws -> String {
        guard let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw AshexError.invalidToolArguments("mcp.\(key) must be a non-empty string")
        }
        return value
    }
}

private func mcpItemJSON(_ item: AgentMCPDiscoveredItem) -> JSONValue {
    var object: JSONObject = [
        "name": .string(item.name),
        "raw": item.raw,
    ]
    if let title = item.title {
        object["title"] = .string(title)
    }
    if let description = item.description {
        object["description"] = .string(description)
    }
    if let uri = item.uri {
        object["uri"] = .string(uri)
    }
    if let mimeType = item.mimeType {
        object["mime_type"] = .string(mimeType)
    }
    return .object(object)
}
