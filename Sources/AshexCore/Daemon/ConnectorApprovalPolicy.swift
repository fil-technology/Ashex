import Foundation

public struct ConnectorApprovalPolicy: ApprovalPolicy {
    public var mode: ApprovalMode {
        switch policyMode {
        case .trustedFullAccess:
            return .trusted
        case .assistantOnly, .approvalRequired:
            return .guarded
        }
    }
    public let policyMode: ConnectorExecutionPolicyMode
    public let connectorName: String
    public let remoteApprovalInbox: RemoteApprovalInbox?
    public let runStore: DaemonConversationRunStore?

    public init(
        policyMode: ConnectorExecutionPolicyMode,
        connectorName: String,
        remoteApprovalInbox: RemoteApprovalInbox? = nil,
        runStore: DaemonConversationRunStore? = nil
    ) {
        self.policyMode = policyMode
        self.connectorName = connectorName
        self.remoteApprovalInbox = remoteApprovalInbox
        self.runStore = runStore
    }

    public func evaluate(_ request: ApprovalRequest) async -> ApprovalDecision {
        switch policyMode {
        case .assistantOnly:
            return .deny("\(connectorName) is configured for assistant_only. Tool '\(request.toolName)' was blocked.")
        case .approvalRequired:
            guard let remoteApprovalInbox, let runStore else {
                return .deny("\(connectorName) requires explicit approval for tool execution, and remote approvals are not enabled in daemon mode yet.")
            }
            guard let conversation = await runStore.conversation(for: request.runID) else {
                return .deny("Could not resolve the connector conversation for this approval request.")
            }
            await runStore.setAwaitingApproval(true, for: request.runID)
            let decision = await remoteApprovalInbox.awaitDecision(for: request, conversation: conversation)
            await runStore.setAwaitingApproval(false, for: request.runID)
            return decision
        case .trustedFullAccess:
            return .allow("\(connectorName) is configured for trusted_full_access. Tool '\(request.toolName)' is allowed.")
        }
    }
}
