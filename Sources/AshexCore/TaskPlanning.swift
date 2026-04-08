import Foundation

public struct PlannedStep: Codable, Sendable, Equatable {
    public let title: String
    public let phase: PlannedStepPhase

    public init(title: String, phase: PlannedStepPhase = .mutation) {
        self.title = title
        self.phase = phase
    }
}

public enum PlannedStepPhase: String, Codable, Sendable, Equatable {
    case exploration
    case planning
    case mutation
    case validation
}

public struct TaskPlan: Codable, Sendable, Equatable {
    public let steps: [PlannedStep]

    public init(steps: [PlannedStep]) {
        self.steps = steps
    }
}

public actor ExecutionControl {
    private var skipCurrentStepRequested = false

    public init() {}

    public func requestSkipCurrentStep() {
        skipCurrentStepRequested = true
    }

    public func consumeSkipCurrentStep() -> Bool {
        let shouldSkip = skipCurrentStepRequested
        skipCurrentStepRequested = false
        return shouldSkip
    }
}

public enum TaskPlanner {
    public static func plan(for prompt: String) -> TaskPlan? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shouldPlan(prompt: trimmed) else { return nil }

        let explicitParts = splitExplicitSteps(in: trimmed)
        if explicitParts.count >= 2 {
            return TaskPlan(steps: explicitParts.enumerated().map { index, part in
                PlannedStep(title: part, phase: inferredPhase(for: part, index: index, total: explicitParts.count))
            })
        }

        return TaskPlan(steps: [
            PlannedStep(title: "Inspect the current workspace state relevant to the request", phase: .exploration),
            PlannedStep(title: "Plan the exact changes or commands needed", phase: .planning),
            PlannedStep(title: "Implement or execute the requested changes", phase: .mutation),
            PlannedStep(title: "Validate the result and summarize what changed", phase: .validation)
        ])
    }

    private static func shouldPlan(prompt: String) -> Bool {
        let lowered = prompt.lowercased()
        let words = lowered.split(whereSeparator: \.isWhitespace)
        let largeTaskMarkers = [
            "implement", "build", "create", "refactor", "update", "add", "fix", "investigate",
            "audit", "improve", "migrate", "integrate", "overhaul", "rewrite"
        ]
        let connectiveMarkers = [" then ", " after ", " also ", "\n- ", "\n1.", "; "]
        return words.count >= 14
            || largeTaskMarkers.contains(where: lowered.contains)
            || connectiveMarkers.contains(where: lowered.contains)
    }

    private static func splitExplicitSteps(in prompt: String) -> [String] {
        let normalized = prompt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: ";", with: "\n")
            .replacingOccurrences(of: " then ", with: "\n", options: [.caseInsensitive])
            .replacingOccurrences(of: " also ", with: "\n", options: [.caseInsensitive])
            .replacingOccurrences(of: " after that ", with: "\n", options: [.caseInsensitive])
        let rawParts = normalized.split(separator: "\n", omittingEmptySubsequences: true)
        let trimmedParts = rawParts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let filtered = trimmedParts.filter { $0.count > 8 }
        return Array(filtered.prefix(6))
    }

    private static func inferredPhase(for title: String, index: Int, total: Int) -> PlannedStepPhase {
        let lowered = title.lowercased()
        if lowered.contains("inspect") || lowered.contains("explore") || lowered.contains("read") || lowered.contains("search") || lowered.contains("understand") {
            return .exploration
        }
        if lowered.contains("plan") || lowered.contains("decide") || lowered.contains("design") {
            return .planning
        }
        if lowered.contains("validate") || lowered.contains("verify") || lowered.contains("test") || lowered.contains("summarize") {
            return .validation
        }
        if index == 0 { return .exploration }
        if index == total - 1 { return .validation }
        return .mutation
    }
}
