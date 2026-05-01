import Foundation

public enum AgentRPCMethod: String, Codable, Sendable, Equatable {
    case listTools = "tools/list"
    case callTool = "tools/call"
}

public struct AgentRPCToolCallParams: Codable, Sendable, Equatable {
    public let toolName: String
    public let arguments: JSONObject
    public let runID: UUID

    public init(toolName: String, arguments: JSONObject = [:], runID: UUID = UUID()) {
        self.toolName = toolName
        self.arguments = arguments
        self.runID = runID
    }
}

public struct AgentRPCRequest: Codable, Sendable, Equatable {
    public let id: String
    public let method: AgentRPCMethod
    public let toolCall: AgentRPCToolCallParams?

    public init(id: String, method: AgentRPCMethod, toolCall: AgentRPCToolCallParams? = nil) {
        self.id = id
        self.method = method
        self.toolCall = toolCall
    }

    public static func listTools(id: String) -> AgentRPCRequest {
        .init(id: id, method: .listTools)
    }

    public static func callTool(id: String, toolName: String, arguments: JSONObject = [:], runID: UUID = UUID()) -> AgentRPCRequest {
        .init(
            id: id,
            method: .callTool,
            toolCall: .init(toolName: toolName, arguments: arguments, runID: runID)
        )
    }
}

public struct AgentRPCPolicyDecision: Codable, Sendable, Equatable {
    public let allowed: Bool
    public let reason: String

    public init(allowed: Bool, reason: String) {
        self.allowed = allowed
        self.reason = reason
    }

    public static func allow(_ reason: String = "Allowed") -> AgentRPCPolicyDecision {
        .init(allowed: true, reason: reason)
    }

    public static func deny(_ reason: String = "Denied") -> AgentRPCPolicyDecision {
        .init(allowed: false, reason: reason)
    }
}

public protocol AgentRPCPolicy: Sendable {
    func evaluate(_ call: AgentRPCToolCallParams, toolSpec: ToolSpec) async -> AgentRPCPolicyDecision
}

public struct AgentRPCStaticPolicy: AgentRPCPolicy {
    private let deniedToolNames: Set<String>
    private let allowedToolNames: Set<String>

    public init(allowedToolNames: Set<String> = [], deniedToolNames: Set<String> = []) {
        self.allowedToolNames = allowedToolNames
        self.deniedToolNames = deniedToolNames
    }

    public func evaluate(_ call: AgentRPCToolCallParams, toolSpec: ToolSpec) async -> AgentRPCPolicyDecision {
        if deniedToolNames.contains(call.toolName) {
            return .deny("Tool '\(call.toolName)' is denied by RPC policy")
        }
        if !allowedToolNames.isEmpty && !allowedToolNames.contains(call.toolName) {
            return .deny("Tool '\(call.toolName)' is not allowed by RPC policy")
        }
        if toolSpec.safety.requiresApproval {
            return .deny("Tool '\(call.toolName)' requires approval before RPC execution")
        }
        return .allow("RPC policy allowed tool execution")
    }
}

public enum AgentRPCToolCallStatus: String, Codable, Sendable, Equatable {
    case completed
    case denied
}

public struct AgentRPCToolCallResult: Codable, Sendable, Equatable {
    public let toolName: String
    public let status: AgentRPCToolCallStatus
    public let policyDecision: AgentRPCPolicyDecision
    public let content: ToolContent?

    public init(
        toolName: String,
        status: AgentRPCToolCallStatus,
        policyDecision: AgentRPCPolicyDecision,
        content: ToolContent? = nil
    ) {
        self.toolName = toolName
        self.status = status
        self.policyDecision = policyDecision
        self.content = content
    }
}

public struct AgentRPCResult: Codable, Sendable, Equatable {
    public let tools: [ToolSpec]
    public let toolCall: AgentRPCToolCallResult?

    public init(tools: [ToolSpec] = [], toolCall: AgentRPCToolCallResult? = nil) {
        self.tools = tools
        self.toolCall = toolCall
    }
}

public struct AgentRPCError: Codable, Error, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct AgentRPCResponse: Codable, Sendable, Equatable {
    public let id: String
    public let result: AgentRPCResult?
    public let error: AgentRPCError?

    public init(id: String, result: AgentRPCResult? = nil, error: AgentRPCError? = nil) {
        self.id = id
        self.result = result
        self.error = error
    }
}

public actor AgentRPCServer {
    private let registry: ToolRegistry
    private let policy: any AgentRPCPolicy

    public init(registry: ToolRegistry, policy: any AgentRPCPolicy = AgentRPCStaticPolicy()) {
        self.registry = registry
        self.policy = policy
    }

    public func handle(_ request: AgentRPCRequest) async throws -> AgentRPCResponse {
        switch request.method {
        case .listTools:
            return .init(id: request.id, result: .init(tools: registry.specs()))
        case .callTool:
            guard let call = request.toolCall else {
                return .init(id: request.id, error: .init(code: "invalid_request", message: "Missing tool call parameters"))
            }

            let tool = try registry.tool(named: call.toolName)
            let spec = tool.contract.toolSpec()
            let decision = await policy.evaluate(call, toolSpec: spec)
            guard decision.allowed else {
                return .init(
                    id: request.id,
                    result: .init(toolCall: .init(
                        toolName: call.toolName,
                        status: .denied,
                        policyDecision: decision
                    ))
                )
            }

            let content = try await tool.execute(
                arguments: call.arguments,
                context: ToolContext(runID: call.runID, emit: { _ in }, cancellation: CancellationToken())
            )
            return .init(
                id: request.id,
                result: .init(toolCall: .init(
                    toolName: call.toolName,
                    status: .completed,
                    policyDecision: decision,
                    content: content
                ))
            )
        }
    }
}

public struct AgentRPCInProcessTransport: Sendable {
    private let server: AgentRPCServer

    public init(server: AgentRPCServer) {
        self.server = server
    }

    public func send(_ request: AgentRPCRequest) async throws -> AgentRPCResponse {
        try await server.handle(request)
    }
}
