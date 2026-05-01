import Foundation

public struct SubAgentDefinition: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let instructions: String
    public let allowedTools: [String]
    public let maxSteps: Int
    public let timeoutSeconds: Int
    public let enabled: Bool

    public init(
        name: String,
        description: String,
        instructions: String,
        allowedTools: [String],
        maxSteps: Int,
        timeoutSeconds: Int,
        enabled: Bool = true
    ) {
        self.name = name
        self.description = description
        self.instructions = instructions
        self.allowedTools = allowedTools
        self.maxSteps = max(1, maxSteps)
        self.timeoutSeconds = max(1, timeoutSeconds)
        self.enabled = enabled
    }
}

public struct SubAgentDefinitionIssue: Codable, Sendable, Equatable {
    public let agentName: String
    public let missingTools: [String]

    public init(agentName: String, missingTools: [String]) {
        self.agentName = agentName
        self.missingTools = missingTools
    }
}

public struct SubAgentDiagnosticReport: Codable, Sendable, Equatable {
    public let status: DiagnosticStatus
    public let definitions: [SubAgentDefinition]
    public let missingToolIssues: [SubAgentDefinitionIssue]
    public let workspaceLeaseCount: Int
    public let runtimeDelegationAvailable: Bool

    public init(
        status: DiagnosticStatus,
        definitions: [SubAgentDefinition],
        missingToolIssues: [SubAgentDefinitionIssue],
        workspaceLeaseCount: Int,
        runtimeDelegationAvailable: Bool
    ) {
        self.status = status
        self.definitions = definitions
        self.missingToolIssues = missingToolIssues
        self.workspaceLeaseCount = workspaceLeaseCount
        self.runtimeDelegationAvailable = runtimeDelegationAvailable
    }
}

public enum SubAgentRegistry {
    public static func builtInDefinitions(computerUseEnabled: Bool) -> [SubAgentDefinition] {
        [
            .init(
                name: "researcher",
                description: "Researches local or browser-accessible information and returns a concise summary.",
                instructions: "Stay read-only. Use browser and file inspection tools to gather evidence before summarizing.",
                allowedTools: ["browser_fetch", "browser_extract", "browser_eval", "filesystem", "git"],
                maxSteps: 8,
                timeoutSeconds: 120
            ),
            .init(
                name: "coder",
                description: "Makes bounded code changes and validates them with the narrowest useful checks.",
                instructions: "Inspect before mutating, keep changes scoped, and report changed files plus validation.",
                allowedTools: ["filesystem", "git", "shell", "build", "swiftpm"],
                maxSteps: 12,
                timeoutSeconds: 300
            ),
            .init(
                name: "reviewer",
                description: "Reviews diffs, reads relevant files, and reports concrete risks or validation gaps.",
                instructions: "Stay evidence-based. Prioritize bugs, regressions, safety issues, and missing tests.",
                allowedTools: ["filesystem", "git", "shell", "build", "swiftpm"],
                maxSteps: 8,
                timeoutSeconds: 180
            ),
            .init(
                name: "computer-operator",
                description: "Performs controlled local GUI tasks through the computer-use backend.",
                instructions: "Use computer-use tools only for explicit local GUI tasks and respect permission and approval gates.",
                allowedTools: ["computer_use"],
                maxSteps: 6,
                timeoutSeconds: 120,
                enabled: computerUseEnabled
            ),
        ]
    }

    public static func diagnose(
        definitions: [SubAgentDefinition],
        availableToolNames: Set<String>,
        workspaceLeaseCount: Int
    ) -> SubAgentDiagnosticReport {
        let missingToolIssues = definitions.compactMap { definition -> SubAgentDefinitionIssue? in
            guard definition.enabled else { return nil }
            let missingTools = definition.allowedTools.filter { !availableToolNames.contains($0) }
            guard !missingTools.isEmpty else { return nil }
            return .init(agentName: definition.name, missingTools: missingTools)
        }
        return .init(
            status: missingToolIssues.isEmpty ? .pass : .warn,
            definitions: definitions,
            missingToolIssues: missingToolIssues,
            workspaceLeaseCount: workspaceLeaseCount,
            runtimeDelegationAvailable: true
        )
    }
}
