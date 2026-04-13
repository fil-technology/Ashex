import Foundation

public struct ConnectorApprovalPolicy: ApprovalPolicy {
    public let mode: ApprovalMode = .guarded
    public let policyMode: ConnectorExecutionPolicyMode
    public let connectorName: String

    public init(policyMode: ConnectorExecutionPolicyMode, connectorName: String) {
        self.policyMode = policyMode
        self.connectorName = connectorName
    }

    public func evaluate(_ request: ApprovalRequest) async -> ApprovalDecision {
        switch policyMode {
        case .assistantOnly:
            return .deny("\(connectorName) is configured for assistant_only. Tool '\(request.toolName)' was blocked.")
        case .approvalRequired:
            return .deny("\(connectorName) requires explicit approval for tool execution, and remote approvals are not enabled in daemon mode yet.")
        }
    }
}
