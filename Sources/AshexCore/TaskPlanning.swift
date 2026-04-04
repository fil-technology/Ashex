import Foundation

public struct PlannedStep: Codable, Sendable, Equatable {
    public let title: String

    public init(title: String) {
        self.title = title
    }
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
            return TaskPlan(steps: explicitParts.map(PlannedStep.init(title:)))
        }

        return TaskPlan(steps: [
            PlannedStep(title: "Inspect the current workspace state relevant to the request"),
            PlannedStep(title: "Implement or execute the requested changes"),
            PlannedStep(title: "Validate the result and summarize what changed")
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
}
