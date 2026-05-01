import Foundation

public enum DiagnosticStatus: String, Codable, Sendable, Equatable {
    case pass
    case warn
    case fail
}

public enum DiagnosticSeverity: String, Codable, Sendable, Equatable {
    case info
    case warn
    case fail
}

public struct DiagnosticIssue: Codable, Sendable, Equatable {
    public let severity: DiagnosticSeverity
    public let subject: String
    public let message: String

    public init(severity: DiagnosticSeverity, subject: String, message: String) {
        self.severity = severity
        self.subject = subject
        self.message = message
    }
}

public struct ToolRegistryDiagnosticReport: Codable, Sendable, Equatable {
    public let status: DiagnosticStatus
    public let toolCount: Int
    public let duplicateToolNames: [String]
    public let issues: [DiagnosticIssue]

    public init(status: DiagnosticStatus, toolCount: Int, duplicateToolNames: [String], issues: [DiagnosticIssue]) {
        self.status = status
        self.toolCount = toolCount
        self.duplicateToolNames = duplicateToolNames
        self.issues = issues
    }
}

public enum ToolRegistryDiagnostics {
    public static func inspect(tools: [any Tool]) -> ToolRegistryDiagnosticReport {
        inspect(registry: ToolRegistry(tools: tools))
    }

    public static func inspect(registry: ToolRegistry) -> ToolRegistryDiagnosticReport {
        let specs = registry.specs()
        var issues: [DiagnosticIssue] = []

        for name in registry.duplicateToolNames {
            issues.append(.init(
                severity: .fail,
                subject: name,
                message: "Duplicate tool name. Tool names must be globally unique."
            ))
        }

        for spec in specs {
            inspect(spec: spec, issues: &issues)
        }

        let status: DiagnosticStatus
        if issues.contains(where: { $0.severity == .fail }) {
            status = .fail
        } else if issues.contains(where: { $0.severity == .warn }) {
            status = .warn
        } else {
            status = .pass
        }

        return .init(
            status: status,
            toolCount: specs.count,
            duplicateToolNames: registry.duplicateToolNames,
            issues: issues
        )
    }

    private static func inspect(spec: ToolSpec, issues: inout [DiagnosticIssue]) {
        let subject = spec.name.isEmpty ? "<unnamed>" : spec.name
        if spec.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(severity: .fail, subject: subject, message: "Tool name is empty."))
        }
        if spec.description.trimmingCharacters(in: .whitespacesAndNewlines).count < 12 {
            issues.append(.init(severity: .warn, subject: subject, message: "Tool description is missing or too terse."))
        }
        if spec.operations.isEmpty {
            issues.append(.init(severity: .warn, subject: subject, message: "Tool has no operation contracts."))
        }

        let operationNames = spec.operations.map(\.name)
        let duplicateOperations = duplicates(in: operationNames)
        for operationName in duplicateOperations {
            issues.append(.init(
                severity: .fail,
                subject: "\(subject).\(operationName)",
                message: "Duplicate operation name in tool contract."
            ))
        }

        if let defaultOperationName = spec.defaultOperationName,
           !operationNames.contains(defaultOperationName) {
            issues.append(.init(
                severity: .fail,
                subject: subject,
                message: "Default operation `\(defaultOperationName)` is not declared in operations."
            ))
        }

        for operation in spec.operations {
            inspect(operation: operation, toolName: subject, issues: &issues)
        }
    }

    private static func inspect(operation: ToolOperationSpec, toolName: String, issues: inout [DiagnosticIssue]) {
        let subject = "\(toolName).\(operation.name.isEmpty ? "<unnamed>" : operation.name)"
        if operation.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(severity: .fail, subject: subject, message: "Operation name is empty."))
        }
        if operation.description.trimmingCharacters(in: .whitespacesAndNewlines).count < 12 {
            issues.append(.init(severity: .warn, subject: subject, message: "Operation description is missing or too terse."))
        }
        if operation.safety.requiresApproval && operation.safety.risk == nil {
            issues.append(.init(severity: .warn, subject: subject, message: "Operation requires approval but has no risk level."))
        }
    }

    private static func duplicates(in values: [String]) -> [String] {
        var seen: Set<String> = []
        var duplicated: Set<String> = []
        for value in values where !seen.insert(value).inserted {
            duplicated.insert(value)
        }
        return duplicated.sorted()
    }
}
