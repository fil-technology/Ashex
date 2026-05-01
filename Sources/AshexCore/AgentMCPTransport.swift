import Foundation

public enum AgentMCPTransportKind: String, Codable, Sendable, Equatable {
    case stdio
    case http
}

public struct AgentMCPStdioServerDescriptor: Codable, Sendable, Equatable {
    public let command: String
    public let arguments: [String]
    public let environment: [String: String]

    public init(command: String, arguments: [String] = [], environment: [String: String] = [:]) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
    }
}

public struct AgentMCPHTTPServerDescriptor: Codable, Sendable, Equatable {
    public let url: URL
    public let headers: [String: String]

    public init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }
}

public enum AgentMCPServerTransport: Codable, Sendable, Equatable {
    case stdio(AgentMCPStdioServerDescriptor)
    case http(AgentMCPHTTPServerDescriptor)

    public var kind: AgentMCPTransportKind {
        switch self {
        case .stdio: return .stdio
        case .http: return .http
        }
    }
}

public struct AgentMCPToolFilter: Codable, Sendable, Equatable {
    public let allow: [String]
    public let deny: [String]

    public init(allow: [String] = [], deny: [String] = []) {
        self.allow = allow
        self.deny = deny
    }

    public func permits(sourceName: String, prefixedName: String) -> Bool {
        let allowed = allow.isEmpty || allow.containsPattern(matching: sourceName) || allow.containsPattern(matching: prefixedName)
        let denied = deny.containsPattern(matching: sourceName) || deny.containsPattern(matching: prefixedName)
        return allowed && !denied
    }
}

public struct AgentMCPServerDescriptor: Codable, Sendable, Equatable {
    public let id: String
    public let namespace: String
    public let transport: AgentMCPServerTransport
    public let filter: AgentMCPToolFilter
    public let enabled: Bool

    public init(
        id: String,
        namespace: String,
        transport: AgentMCPServerTransport,
        filter: AgentMCPToolFilter = .init(),
        enabled: Bool = true
    ) {
        self.id = id
        self.namespace = namespace
        self.transport = transport
        self.filter = filter
        self.enabled = enabled
    }
}

public struct AgentMCPConfig: Codable, Sendable, Equatable {
    public let servers: [AgentMCPServerDescriptor]

    public init(servers: [AgentMCPServerDescriptor] = []) {
        self.servers = servers
    }
}

public struct AgentMCPPublishedTool: Sendable {
    public let name: String
    public let sourceName: String
    public let serverID: String
    public let namespace: String
    public let contract: ToolContract

    public init(name: String, sourceName: String, serverID: String, namespace: String, contract: ToolContract) {
        self.name = name
        self.sourceName = sourceName
        self.serverID = serverID
        self.namespace = namespace
        self.contract = contract
    }

    public var toolSpec: ToolSpec {
        ToolContract(
            name: name,
            description: contract.description,
            kind: contract.kind,
            category: contract.category,
            operationArgumentKey: contract.operationArgumentKey,
            defaultOperationName: contract.defaultOperationName,
            operations: contract.operations,
            tags: Array(Set(contract.tags + ["mcp", "mcp:\(serverID)"])).sorted()
        ).toolSpec()
    }
}

public struct AgentMCPServerRefreshMetadata: Codable, Sendable, Equatable {
    public let serverID: String
    public let namespace: String
    public let transportKind: AgentMCPTransportKind
    public let discoveredToolCount: Int
    public let publishedToolCount: Int
    public let filteredToolCount: Int

    public init(
        serverID: String,
        namespace: String,
        transportKind: AgentMCPTransportKind,
        discoveredToolCount: Int,
        publishedToolCount: Int,
        filteredToolCount: Int
    ) {
        self.serverID = serverID
        self.namespace = namespace
        self.transportKind = transportKind
        self.discoveredToolCount = discoveredToolCount
        self.publishedToolCount = publishedToolCount
        self.filteredToolCount = filteredToolCount
    }
}

public struct AgentMCPRefreshMetadata: Codable, Sendable, Equatable {
    public let refreshedAt: Date
    public let servers: [AgentMCPServerRefreshMetadata]

    public init(refreshedAt: Date, servers: [AgentMCPServerRefreshMetadata]) {
        self.refreshedAt = refreshedAt
        self.servers = servers
    }
}

public struct AgentMCPSnapshot: Sendable {
    public let tools: [AgentMCPPublishedTool]
    public let metadata: AgentMCPRefreshMetadata

    public init(tools: [AgentMCPPublishedTool], metadata: AgentMCPRefreshMetadata) {
        self.tools = tools
        self.metadata = metadata
    }
}

public protocol AgentMCPToolDiscovery: Sendable {
    func discoverTools(for server: AgentMCPServerDescriptor) async throws -> [ToolContract]
}

public struct AgentMCPToolCallResult: Sendable, Equatable {
    public let serverID: String
    public let toolName: String
    public let result: JSONObject
    public let isError: Bool

    public init(serverID: String, toolName: String, result: JSONObject, isError: Bool = false) {
        self.serverID = serverID
        self.toolName = toolName
        self.result = result
        self.isError = isError
    }
}

public protocol AgentMCPToolCalling: Sendable {
    func callTool(
        server: AgentMCPServerDescriptor,
        toolName: String,
        arguments: JSONObject
    ) async throws -> AgentMCPToolCallResult
}

public struct AgentMCPMockToolDiscovery: AgentMCPToolDiscovery {
    private let fixtures: [String: [ToolContract]]

    public init(fixtures: [String: [ToolContract]]) {
        self.fixtures = fixtures
    }

    public func discoverTools(for server: AgentMCPServerDescriptor) async throws -> [ToolContract] {
        fixtures[server.id] ?? []
    }
}

public struct AgentMCPMockToolCaller: AgentMCPToolCalling {
    private let fixtures: [String: JSONObject]

    public init(fixtures: [String: JSONObject]) {
        self.fixtures = fixtures
    }

    public func callTool(
        server: AgentMCPServerDescriptor,
        toolName: String,
        arguments _: JSONObject
    ) async throws -> AgentMCPToolCallResult {
        let key = "\(server.id):\(toolName)"
        guard let result = fixtures[key] else {
            throw AshexError.toolNotFound(key)
        }
        return .init(
            serverID: server.id,
            toolName: toolName,
            result: result,
            isError: result["isError"]?.boolValue ?? false
        )
    }
}

public enum AgentMCPListKind: String, Sendable, CaseIterable {
    case tools
    case resources
    case prompts

    var method: String {
        switch self {
        case .tools: return "tools/list"
        case .resources: return "resources/list"
        case .prompts: return "prompts/list"
        }
    }

    var resultKey: String {
        switch self {
        case .tools: return "tools"
        case .resources: return "resources"
        case .prompts: return "prompts"
        }
    }
}

public struct AgentMCPDiscoveredItem: Sendable, Equatable {
    public let name: String
    public let title: String?
    public let description: String?
    public let uri: String?
    public let mimeType: String?
    public let raw: JSONValue

    public init(
        name: String,
        title: String? = nil,
        description: String? = nil,
        uri: String? = nil,
        mimeType: String? = nil,
        raw: JSONValue
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.uri = uri
        self.mimeType = mimeType
        self.raw = raw
    }
}

public struct AgentMCPLiveDiscovery: AgentMCPToolDiscovery {
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    public func discoverTools(for server: AgentMCPServerDescriptor) async throws -> [ToolContract] {
        let items = try await listItems(for: server, kind: .tools)
        return items.map { item in
            let description = item.description ?? item.title ?? "MCP tool \(item.name)"
            return ToolContract(
                name: item.name,
                description: description,
                kind: .installable,
                category: "mcp",
                operationArgumentKey: nil,
                operations: [
                    .init(
                        name: "call",
                        description: description,
                        mutatesWorkspace: false,
                        requiresNetwork: server.transport.kind == .http,
                        arguments: [
                            .init(
                                name: "arguments",
                                description: "MCP tool arguments object",
                                type: .object,
                                required: false
                            ),
                        ]
                    ),
                ],
                tags: ["mcp", "mcp:\(server.id)"]
            )
        }
    }

    public func listItems(for server: AgentMCPServerDescriptor, kind: AgentMCPListKind) async throws -> [AgentMCPDiscoveredItem] {
        guard server.enabled else { return [] }
        switch server.transport {
        case .stdio(let descriptor):
            return try await StdioMCPClient(descriptor: descriptor, timeout: timeout).list(kind: kind)
        case .http(let descriptor):
            return try await HTTPMCPClient(descriptor: descriptor, timeout: timeout).list(kind: kind)
        }
    }
}

public struct AgentMCPLiveToolCaller: AgentMCPToolCalling {
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 30) {
        self.timeout = timeout
    }

    public func callTool(
        server: AgentMCPServerDescriptor,
        toolName: String,
        arguments: JSONObject = [:]
    ) async throws -> AgentMCPToolCallResult {
        guard server.enabled else {
            throw AshexError.toolNotFound("MCP server '\(server.id)' is disabled")
        }
        let result: JSONObject
        switch server.transport {
        case .stdio(let descriptor):
            result = try await StdioMCPClient(descriptor: descriptor, timeout: timeout).call(toolName: toolName, arguments: arguments)
        case .http(let descriptor):
            result = try await HTTPMCPClient(descriptor: descriptor, timeout: timeout).call(toolName: toolName, arguments: arguments)
        }
        return .init(
            serverID: server.id,
            toolName: toolName,
            result: result,
            isError: result["isError"]?.boolValue ?? false
        )
    }
}

public actor AgentMCPToolNamespace {
    private let config: AgentMCPConfig
    private let discovery: any AgentMCPToolDiscovery
    private var currentSnapshot: AgentMCPSnapshot?

    public init(config: AgentMCPConfig, discovery: any AgentMCPToolDiscovery) {
        self.config = config
        self.discovery = discovery
    }

    public func refresh(now: Date = Date()) async throws -> AgentMCPSnapshot {
        var publishedTools: [AgentMCPPublishedTool] = []
        var serverMetadata: [AgentMCPServerRefreshMetadata] = []

        for server in config.servers where server.enabled {
            let discovered = try await discovery.discoverTools(for: server)
            let published = discovered.compactMap { contract -> AgentMCPPublishedTool? in
                let prefixedName = "\(server.namespace)__\(contract.name)"
                guard server.filter.permits(sourceName: contract.name, prefixedName: prefixedName) else {
                    return nil
                }
                return AgentMCPPublishedTool(
                    name: prefixedName,
                    sourceName: contract.name,
                    serverID: server.id,
                    namespace: server.namespace,
                    contract: contract
                )
            }

            publishedTools.append(contentsOf: published)
            serverMetadata.append(.init(
                serverID: server.id,
                namespace: server.namespace,
                transportKind: server.transport.kind,
                discoveredToolCount: discovered.count,
                publishedToolCount: published.count,
                filteredToolCount: discovered.count - published.count
            ))
        }

        let snapshot = AgentMCPSnapshot(
            tools: publishedTools.sorted { $0.name < $1.name },
            metadata: .init(
                refreshedAt: now,
                servers: serverMetadata.sorted { $0.serverID < $1.serverID }
            )
        )
        currentSnapshot = snapshot
        return snapshot
    }

    public func snapshot() -> AgentMCPSnapshot? {
        currentSnapshot
    }
}

private let agentMCPProtocolVersion = "2025-06-18"

private struct StdioMCPClient {
    let descriptor: AgentMCPStdioServerDescriptor
    let timeout: TimeInterval

    func list(kind: AgentMCPListKind) async throws -> [AgentMCPDiscoveredItem] {
        try await withInitializedSession { input, buffer, stderr in
            var items: [AgentMCPDiscoveredItem] = []
            var cursor: String?
            var page = 1
            repeat {
                let id = "list-\(page)"
                let params = cursor.map { ["cursor": JSONValue.string($0)] } ?? [:]
                try send(.request(id: id, method: kind.method, params: params), to: input.fileHandleForWriting)
                let result = try await waitForResult(id: id, in: buffer, timeout: timeout, stderr: stderr)
                items.append(contentsOf: parseItems(from: result, kind: kind))
                cursor = result["nextCursor"]?.stringValue?.nilIfBlank
                page += 1
            } while cursor != nil

            return items
        }
    }

    func call(toolName: String, arguments: JSONObject) async throws -> JSONObject {
        try await withInitializedSession { input, buffer, stderr in
            let id = "call-1"
            try send(.request(id: id, method: "tools/call", params: [
                "name": .string(toolName),
                "arguments": .object(arguments),
            ]), to: input.fileHandleForWriting)
            return try await waitForResult(id: id, in: buffer, timeout: timeout, stderr: stderr)
        }
    }

    private func withInitializedSession<Result>(
        _ operation: (Pipe, MCPOutputBuffer, MCPOutputBuffer) async throws -> Result
    ) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [descriptor.command] + descriptor.arguments
        var environment = ProcessInfo.processInfo.environment
        descriptor.environment.forEach { environment[$0.key] = $0.value }
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        let buffer = MCPOutputBuffer()
        let stderr = MCPOutputBuffer()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        output.fileHandleForReading.readabilityHandler = { handle in
            buffer.append(handle.availableData)
        }
        error.fileHandleForReading.readabilityHandler = { handle in
            stderr.appendDiagnostic(handle.availableData)
        }

        try process.run()
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            error.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        try send(.request(id: "initialize-1", method: "initialize", params: initializeParams()), to: input.fileHandleForWriting)
        _ = try await waitForResult(id: "initialize-1", in: buffer, timeout: timeout, stderr: stderr)
        try send(.notification(method: "notifications/initialized"), to: input.fileHandleForWriting)
        return try await operation(input, buffer, stderr)
    }
}

private struct HTTPMCPClient {
    let descriptor: AgentMCPHTTPServerDescriptor
    let timeout: TimeInterval

    func list(kind: AgentMCPListKind) async throws -> [AgentMCPDiscoveredItem] {
        var sessionID: String?
        let initialize = try await post(.request(id: "initialize-1", method: "initialize", params: initializeParams()), sessionID: nil)
        sessionID = initialize.sessionID
        _ = try await post(.notification(method: "notifications/initialized"), sessionID: sessionID)

        var items: [AgentMCPDiscoveredItem] = []
        var cursor: String?
        var page = 1
        repeat {
            let id = "list-\(page)"
            let params = cursor.map { ["cursor": JSONValue.string($0)] } ?? [:]
            let response = try await post(.request(id: id, method: kind.method, params: params), sessionID: sessionID)
            guard let result = response.message?["result"]?.objectValue else {
                throw AshexError.model("MCP HTTP server returned no result for \(kind.method)")
            }
            items.append(contentsOf: parseItems(from: result, kind: kind))
            cursor = result["nextCursor"]?.stringValue?.nilIfBlank
            page += 1
        } while cursor != nil

        return items
    }

    func call(toolName: String, arguments: JSONObject) async throws -> JSONObject {
        var sessionID: String?
        let initialize = try await post(.request(id: "initialize-1", method: "initialize", params: initializeParams()), sessionID: nil)
        sessionID = initialize.sessionID
        _ = try await post(.notification(method: "notifications/initialized"), sessionID: sessionID)

        let response = try await post(.request(id: "call-1", method: "tools/call", params: [
            "name": .string(toolName),
            "arguments": .object(arguments),
        ]), sessionID: sessionID)
        guard let result = response.message?["result"]?.objectValue else {
            throw AshexError.model("MCP HTTP server returned no result for tools/call")
        }
        return result
    }

    private func post(_ message: MCPMessage, sessionID: String?) async throws -> (message: JSONObject?, sessionID: String?) {
        var request = URLRequest(url: descriptor.url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(agentMCPProtocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        for (key, value) in descriptor.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.httpBody = try encodedLine(message)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AshexError.model("MCP HTTP request did not return an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AshexError.model("MCP HTTP request failed with \(http.statusCode): \(body)")
        }
        let returnedSessionID = http.headerValue(caseInsensitive: "Mcp-Session-Id") ?? sessionID
        if http.statusCode == 202 || data.isEmpty {
            return (nil, returnedSessionID)
        }

        let contentType = http.headerValue(caseInsensitive: "Content-Type") ?? ""
        let object = contentType.lowercased().contains("text/event-stream")
            ? try parseSSEMessage(data)
            : try decodeJSONObject(data)
        try throwIfJSONRPCError(object)
        return (object, returnedSessionID)
    }
}

private enum MCPMessage {
    case request(id: String, method: String, params: JSONObject = [:])
    case notification(method: String, params: JSONObject = [:])

    var json: JSONValue {
        switch self {
        case .request(let id, let method, let params):
            return .object([
                "jsonrpc": .string("2.0"),
                "id": .string(id),
                "method": .string(method),
                "params": .object(params),
            ])
        case .notification(let method, let params):
            return .object([
                "jsonrpc": .string("2.0"),
                "method": .string(method),
                "params": .object(params),
            ])
        }
    }
}

private final class MCPOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var partial = ""
    private var messages: [JSONObject] = []
    private var diagnosticText = ""

    func append(_ data: Data) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        partial.append(text)
        while let newline = partial.firstIndex(of: "\n") {
            let line = String(partial[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            partial.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            if let object = try? decodeJSONObject(Data(line.utf8)) {
                messages.append(object)
            } else {
                diagnosticText.append(line + "\n")
            }
        }
        lock.unlock()
    }

    func appendDiagnostic(_ data: Data) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        lock.withLock {
            diagnosticText.append(text)
        }
    }

    func takeMessage(id: String) -> JSONObject? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = messages.firstIndex(where: { $0["id"]?.matchesJSONRPCID(id) == true }) else {
            return nil
        }
        return messages.remove(at: index)
    }

    var diagnostics: String {
        lock.withLock { diagnosticText.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

private func initializeParams() -> JSONObject {
    [
        "protocolVersion": .string(agentMCPProtocolVersion),
        "capabilities": .object([:]),
        "clientInfo": .object([
            "name": .string("ashex"),
            "version": .string("0.1.0"),
        ]),
    ]
}

private func send(_ message: MCPMessage, to handle: FileHandle) throws {
    try handle.write(contentsOf: encodedLine(message) + Data("\n".utf8))
}

private func encodedLine(_ message: MCPMessage) throws -> Data {
    try JSONEncoder().encode(message.json)
}

private func waitForResult(id: String, in buffer: MCPOutputBuffer, timeout: TimeInterval, stderr: MCPOutputBuffer) async throws -> JSONObject {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let object = buffer.takeMessage(id: id) {
            try throwIfJSONRPCError(object)
            guard let result = object["result"]?.objectValue else {
                throw AshexError.model("MCP response \(id) did not include a result")
            }
            return result
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    let diagnostics = stderr.diagnostics
    let suffix = diagnostics.isEmpty ? "" : " Stderr: \(diagnostics)"
    throw AshexError.model("Timed out waiting for MCP response \(id).\(suffix)")
}

private func parseItems(from result: JSONObject, kind: AgentMCPListKind) -> [AgentMCPDiscoveredItem] {
    (result[kind.resultKey]?.arrayValue ?? []).compactMap { value in
        guard let object = value.objectValue else { return nil }
        let name = object["name"]?.stringValue?.nilIfBlank
            ?? object["uri"]?.stringValue?.nilIfBlank
        guard let name else { return nil }
        return AgentMCPDiscoveredItem(
            name: name,
            title: object["title"]?.stringValue?.nilIfBlank,
            description: object["description"]?.stringValue?.nilIfBlank,
            uri: object["uri"]?.stringValue?.nilIfBlank,
            mimeType: object["mimeType"]?.stringValue?.nilIfBlank,
            raw: .object(object)
        )
    }
}

private func throwIfJSONRPCError(_ object: JSONObject) throws {
    guard let error = object["error"]?.objectValue else { return }
    let code = error["code"]?.numberValue.map { String(Int($0)) } ?? "error"
    let message = error["message"]?.stringValue ?? "Unknown MCP error"
    throw AshexError.model("MCP JSON-RPC error \(code): \(message)")
}

private func decodeJSONObject(_ data: Data) throws -> JSONObject {
    let value = try JSONDecoder().decode(JSONValue.self, from: data)
    guard case .object(let object) = value else {
        throw AshexError.model("Expected a JSON object MCP message")
    }
    return object
}

private func parseSSEMessage(_ data: Data) throws -> JSONObject {
    let text = String(data: data, encoding: .utf8) ?? ""
    var eventData: [String] = []
    var candidates: [String] = []

    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if line.isEmpty {
            if !eventData.isEmpty {
                candidates.append(eventData.joined(separator: "\n"))
                eventData = []
            }
            continue
        }
        if line.hasPrefix("data:") {
            eventData.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }
    }
    if !eventData.isEmpty {
        candidates.append(eventData.joined(separator: "\n"))
    }
    candidates.append(text)

    for candidate in candidates where !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if let object = try? decodeJSONObject(Data(candidate.utf8)),
           object["id"] != nil || object["result"] != nil || object["error"] != nil {
            return object
        }
    }
    throw AshexError.model("MCP SSE response did not contain a JSON-RPC response")
}

private extension [String] {
    func containsPattern(matching value: String) -> Bool {
        contains { pattern in
            if pattern == value || pattern == "*" {
                return true
            }
            guard pattern.contains("*") else {
                return false
            }
            let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 2 {
                let prefixMatches = parts[0].isEmpty || value.hasPrefix(parts[0])
                let suffixMatches = parts[1].isEmpty || value.hasSuffix(parts[1])
                return prefixMatches && suffixMatches
            }
            return false
        }
    }
}

private extension JSONValue {
    func matchesJSONRPCID(_ id: String) -> Bool {
        switch self {
        case .string(let value):
            return value == id
        case .number(let value):
            return String(Int(value)) == id || String(value) == id
        default:
            return false
        }
    }
}

private extension HTTPURLResponse {
    func headerValue(caseInsensitive name: String) -> String? {
        for (key, value) in allHeaderFields {
            guard String(describing: key).caseInsensitiveCompare(name) == .orderedSame else { continue }
            return String(describing: value)
        }
        return nil
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
