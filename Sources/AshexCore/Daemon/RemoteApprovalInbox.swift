import Foundation

public struct PendingRemoteApproval: Sendable, Codable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable {
        case pending
        case approved
        case denied
        case interrupted
    }

    public let id: UUID
    public let runID: UUID
    public let conversation: ConnectorConversationReference
    public let toolName: String
    public let summary: String
    public let reason: String
    public let risk: ApprovalRisk
    public let status: Status
    public let createdAt: Date
    public let updatedAt: Date
    public let resolutionReason: String?

    public init(
        id: UUID,
        runID: UUID,
        conversation: ConnectorConversationReference,
        toolName: String,
        summary: String,
        reason: String,
        risk: ApprovalRisk,
        status: Status,
        createdAt: Date,
        updatedAt: Date,
        resolutionReason: String? = nil
    ) {
        self.id = id
        self.runID = runID
        self.conversation = conversation
        self.toolName = toolName
        self.summary = summary
        self.reason = reason
        self.risk = risk
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.resolutionReason = resolutionReason
    }

    fileprivate func toJSONValue() -> JSONValue {
        .object([
            "id": .string(id.uuidString),
            "run_id": .string(runID.uuidString),
            "conversation": .object([
                "connector_kind": .string(conversation.connectorKind),
                "connector_id": .string(conversation.connectorID),
                "external_conversation_id": .string(conversation.externalConversationID),
            ]),
            "tool_name": .string(toolName),
            "summary": .string(summary),
            "reason": .string(reason),
            "risk": .string(risk.rawValue),
            "status": .string(status.rawValue),
            "created_at": .number(createdAt.timeIntervalSince1970),
            "updated_at": .number(updatedAt.timeIntervalSince1970),
            "resolution_reason": resolutionReason.map(JSONValue.string) ?? .null,
        ])
    }

    fileprivate static func from(setting: PersistedSetting) -> PendingRemoteApproval? {
        guard case .object(let object) = setting.value,
              let id = object["id"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let runID = object["run_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
              case .object(let conversationObject)? = object["conversation"],
              let connectorKind = conversationObject["connector_kind"]?.stringValue,
              let connectorID = conversationObject["connector_id"]?.stringValue,
              let externalConversationID = conversationObject["external_conversation_id"]?.stringValue,
              let toolName = object["tool_name"]?.stringValue,
              let summary = object["summary"]?.stringValue,
              let reason = object["reason"]?.stringValue,
              let risk = object["risk"]?.stringValue.flatMap(ApprovalRisk.init(rawValue:)),
              let status = object["status"]?.stringValue.flatMap(Status.init(rawValue:)),
              case .number(let createdAtSeconds)? = object["created_at"],
              case .number(let updatedAtSeconds)? = object["updated_at"] else {
            return nil
        }

        return PendingRemoteApproval(
            id: id,
            runID: runID,
            conversation: .init(
                connectorKind: connectorKind,
                connectorID: connectorID,
                externalConversationID: externalConversationID
            ),
            toolName: toolName,
            summary: summary,
            reason: reason,
            risk: risk,
            status: status,
            createdAt: Date(timeIntervalSince1970: createdAtSeconds),
            updatedAt: Date(timeIntervalSince1970: updatedAtSeconds),
            resolutionReason: object["resolution_reason"]?.stringValue
        )
    }
}

public actor RemoteApprovalInbox {
    private let persistence: PersistenceStore
    private let clock: @Sendable () -> Date
    private var pendingApprovals: [ConnectorConversationReference: PendingRemoteApproval] = [:]
    private var continuations: [UUID: CheckedContinuation<ApprovalDecision, Never>] = [:]
    private var approvedFilesystemMutationRuns: Set<ApprovalRunScope> = []
    private let namespace = "daemon.remote_approvals"

    public init(
        persistence: PersistenceStore,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.persistence = persistence
        self.clock = clock
    }

    public func normalizeInterruptedApprovals() throws {
        let now = clock()
        let settings = try persistence.listSettings(namespace: namespace)
        for setting in settings {
            guard let pending = PendingRemoteApproval.from(setting: setting),
                  pending.status == .pending else {
                continue
            }
            try persist(
                pending.replacing(status: .interrupted, updatedAt: now, resolutionReason: "Daemon restarted before approval was resolved.")
            )
        }
        pendingApprovals.removeAll()
        continuations.removeAll()
        approvedFilesystemMutationRuns.removeAll()
    }

    public func cachedDecision(
        for request: ApprovalRequest,
        conversation: ConnectorConversationReference
    ) -> ApprovalDecision? {
        guard Self.canReuseApproval(for: request),
              approvedFilesystemMutationRuns.contains(.init(conversation: conversation, runID: request.runID)) else {
            return nil
        }
        return .allow("Allowed because low-risk filesystem changes were approved earlier in this run.")
    }

    public func rememberReusableApproval(
        for request: ApprovalRequest,
        conversation: ConnectorConversationReference
    ) {
        guard Self.canReuseApproval(for: request) else { return }
        approvedFilesystemMutationRuns.insert(.init(conversation: conversation, runID: request.runID))
    }

    public func awaitDecision(
        for request: ApprovalRequest,
        conversation: ConnectorConversationReference
    ) async -> ApprovalDecision {
        let now = clock()
        let pending = PendingRemoteApproval(
            id: request.id,
            runID: request.runID,
            conversation: conversation,
            toolName: request.toolName,
            summary: request.summary,
            reason: request.reason,
            risk: request.risk,
            status: .pending,
            createdAt: now,
            updatedAt: now
        )
        pendingApprovals[conversation] = pending
        try? persist(pending)

        return await withCheckedContinuation { continuation in
            continuations[pending.id] = continuation
        }
    }

    public func pendingApproval(for conversation: ConnectorConversationReference) -> PendingRemoteApproval? {
        if let pending = pendingApprovals[conversation] {
            return pending
        }
        let settings = try? persistence.listSettings(namespace: namespace)
        return settings?
            .compactMap(PendingRemoteApproval.from(setting:))
            .first(where: { $0.conversation == conversation && $0.status == .pending })
    }

    @discardableResult
    public func resolvePendingApproval(
        for conversation: ConnectorConversationReference,
        allowed: Bool,
        reason: String
    ) -> PendingRemoteApproval? {
        guard let pending = pendingApproval(for: conversation) else { return nil }
        let resolved = pending.replacing(
            status: allowed ? .approved : .denied,
            updatedAt: clock(),
            resolutionReason: reason
        )
        pendingApprovals.removeValue(forKey: conversation)
        try? persist(resolved)
        continuations.removeValue(forKey: pending.id)?.resume(
            returning: allowed ? .allow(reason) : .deny(reason)
        )
        return resolved
    }

    private func persist(_ approval: PendingRemoteApproval) throws {
        try persistence.upsertSetting(
            namespace: namespace,
            key: approval.id.uuidString,
            value: approval.toJSONValue(),
            now: approval.updatedAt
        )
    }

    private static func canReuseApproval(for request: ApprovalRequest) -> Bool {
        guard request.toolName == "filesystem",
              request.risk != .high,
              let operation = request.arguments["operation"]?.stringValue else {
            return false
        }
        return [
            "create_directory",
            "write_text_file",
            "replace_in_file",
            "apply_patch",
            "copy_path",
            "move_path",
        ].contains(operation)
    }
}

private struct ApprovalRunScope: Hashable {
    let conversation: ConnectorConversationReference
    let runID: UUID
}

private extension PendingRemoteApproval {
    func replacing(status: Status, updatedAt: Date, resolutionReason: String?) -> PendingRemoteApproval {
        PendingRemoteApproval(
            id: id,
            runID: runID,
            conversation: conversation,
            toolName: toolName,
            summary: summary,
            reason: reason,
            risk: risk,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt,
            resolutionReason: resolutionReason
        )
    }
}
