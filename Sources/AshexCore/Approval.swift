import Foundation

public enum ApprovalMode: String, Codable, Sendable {
    case trusted
    case guarded
}

public enum ApprovalRisk: String, Codable, Sendable {
    case low
    case medium
    case high
}

public struct ApprovalRequest: Sendable {
    public let id: UUID
    public let runID: UUID
    public let toolName: String
    public let arguments: JSONObject
    public let summary: String
    public let reason: String
    public let risk: ApprovalRisk

    public init(id: UUID = UUID(), runID: UUID, toolName: String, arguments: JSONObject, summary: String, reason: String, risk: ApprovalRisk) {
        self.id = id
        self.runID = runID
        self.toolName = toolName
        self.arguments = arguments
        self.summary = summary
        self.reason = reason
        self.risk = risk
    }
}

public struct ApprovalDecision: Sendable {
    public let allowed: Bool
    public let reason: String

    public init(allowed: Bool, reason: String) {
        self.allowed = allowed
        self.reason = reason
    }

    public static func allow(_ reason: String = "Allowed") -> ApprovalDecision {
        .init(allowed: true, reason: reason)
    }

    public static func deny(_ reason: String = "Denied") -> ApprovalDecision {
        .init(allowed: false, reason: reason)
    }
}

public protocol ApprovalPolicy: Sendable {
    var mode: ApprovalMode { get }
    func evaluate(_ request: ApprovalRequest) async -> ApprovalDecision
}

public struct TrustedApprovalPolicy: ApprovalPolicy {
    public let mode: ApprovalMode = .trusted

    public init() {}

    public func evaluate(_ request: ApprovalRequest) async -> ApprovalDecision {
        .allow("Trusted mode allows tool execution")
    }
}

public enum ApprovalClassifier {
    public static func requestForTool(runID: UUID, toolName: String, arguments: JSONObject) -> ApprovalRequest? {
        switch toolName {
        case "shell":
            let command = arguments["command"]?.stringValue ?? "<unknown>"
            return ApprovalRequest(
                runID: runID,
                toolName: toolName,
                arguments: arguments,
                summary: "Shell command",
                reason: command,
                risk: commandRisk(command)
            )
        case "filesystem":
            guard let operation = arguments["operation"]?.stringValue else { return nil }
            switch operation {
            case "write_text_file":
                let path = arguments["path"]?.stringValue ?? "<unknown>"
                return ApprovalRequest(
                    runID: runID,
                    toolName: toolName,
                    arguments: arguments,
                    summary: "Write file",
                    reason: path,
                    risk: .medium
                )
            case "create_directory":
                let path = arguments["path"]?.stringValue ?? "<unknown>"
                return ApprovalRequest(
                    runID: runID,
                    toolName: toolName,
                    arguments: arguments,
                    summary: "Create directory",
                    reason: path,
                    risk: .low
                )
            case "replace_in_file":
                let path = arguments["path"]?.stringValue ?? "<unknown>"
                return ApprovalRequest(
                    runID: runID,
                    toolName: toolName,
                    arguments: arguments,
                    summary: "Replace text in file",
                    reason: path,
                    risk: .medium
                )
            case "delete_path":
                let path = arguments["path"]?.stringValue ?? "<unknown>"
                return ApprovalRequest(
                    runID: runID,
                    toolName: toolName,
                    arguments: arguments,
                    summary: "Delete path",
                    reason: path,
                    risk: .high
                )
            case "move_path":
                let sourcePath = arguments["source_path"]?.stringValue ?? "<unknown>"
                let destinationPath = arguments["destination_path"]?.stringValue ?? "<unknown>"
                return ApprovalRequest(
                    runID: runID,
                    toolName: toolName,
                    arguments: arguments,
                    summary: "Move path",
                    reason: "\(sourcePath) → \(destinationPath)",
                    risk: .medium
                )
            case "copy_path":
                let sourcePath = arguments["source_path"]?.stringValue ?? "<unknown>"
                let destinationPath = arguments["destination_path"]?.stringValue ?? "<unknown>"
                return ApprovalRequest(
                    runID: runID,
                    toolName: toolName,
                    arguments: arguments,
                    summary: "Copy path",
                    reason: "\(sourcePath) → \(destinationPath)",
                    risk: .low
                )
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private static func commandRisk(_ command: String) -> ApprovalRisk {
        let lowered = command.lowercased()
        let dangerousMarkers = [
            "rm ", "mv ", "chmod ", "chown ", "sudo ", "git reset", "git clean", "dd ", "mkfs", "shutdown", "reboot"
        ]
        return dangerousMarkers.contains { lowered.contains($0) } ? .high : .medium
    }
}
