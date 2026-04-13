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
    public let taskKind: TaskKind

    public init(steps: [PlannedStep], taskKind: TaskKind) {
        self.steps = steps
        self.taskKind = taskKind
    }
}

public enum TaskKind: String, Codable, Sendable, Equatable {
    case bugFix = "bug-fix"
    case feature = "feature"
    case refactor = "refactor"
    case docs = "docs"
    case git = "git"
    case shell = "shell"
    case analysis = "analysis"
    case general = "general"
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
    public static func classify(prompt: String) -> TaskKind {
        let lowered = prompt.lowercased()

        if isAnalysisOverviewPrompt(lowered) {
            return .analysis
        }

        if ["bug", "fix", "error", "regression", "failing", "broken", "issue"].contains(where: lowered.contains) {
            return .bugFix
        }
        if ["refactor", "cleanup", "simplify", "restructure", "rename"].contains(where: lowered.contains) {
            return .refactor
        }
        if ["readme", "docs", "documentation", "guide", "changelog"].contains(where: lowered.contains) {
            return .docs
        }
        if ["git ", "commit", "branch", "diff", "status", "rebase", "merge"].contains(where: lowered.contains) {
            return .git
        }
        if ["shell:", "command", "terminal", "run ", "execute "].contains(where: lowered.contains) {
            return .shell
        }
        if ["implement", "build", "create", "add", "integrate", "feature"].contains(where: lowered.contains) {
            return .feature
        }
        if ["inspect", "analyze", "audit", "explore", "summarize", "understand"].contains(where: lowered.contains) {
            return .analysis
        }
        return .general
    }

    public static func defaultSingleStep(for prompt: String, taskKind: TaskKind) -> PlannedStep {
        switch taskKind {
        case .analysis:
            return PlannedStep(title: "Inspect the relevant workspace context and summarize the answer", phase: .exploration)
        case .docs:
            return PlannedStep(title: "Inspect the relevant documentation context and answer or edit as requested", phase: .exploration)
        case .git:
            return PlannedStep(title: "Inspect repository state and complete the git request", phase: .exploration)
        case .shell:
            return PlannedStep(title: "Run the requested command sequence safely and summarize the result", phase: .mutation)
        case .bugFix, .feature, .refactor:
            return PlannedStep(title: "Complete the user request", phase: .mutation)
        case .general:
            if isAnalysisOverviewPrompt(prompt.lowercased()) {
                return PlannedStep(title: "Inspect the relevant workspace context and summarize the answer", phase: .exploration)
            }
            return PlannedStep(title: "Complete the user request", phase: .mutation)
        }
    }

    public static func plan(for prompt: String) -> TaskPlan? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskKind = classify(prompt: trimmed)
        guard shouldPlan(prompt: trimmed) else { return nil }

        let explicitParts = splitExplicitSteps(in: trimmed)
        if explicitParts.count >= 2 {
            return TaskPlan(steps: explicitParts.enumerated().map { index, part in
                PlannedStep(title: part, phase: inferredPhase(for: part, index: index, total: explicitParts.count))
            }, taskKind: taskKind)
        }

        return TaskPlan(steps: defaultSteps(for: taskKind), taskKind: taskKind)
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

    private static func defaultSteps(for kind: TaskKind) -> [PlannedStep] {
        switch kind {
        case .bugFix:
            return [
                PlannedStep(title: "Inspect the failure surface and find the relevant files, symbols, or diffs", phase: .exploration),
                PlannedStep(title: "Plan the smallest safe fix and the validation path", phase: .planning),
                PlannedStep(title: "Implement the fix in the relevant files", phase: .mutation),
                PlannedStep(title: "Validate with focused diffs, reads, and tests, then summarize the fix", phase: .validation)
            ]
        case .feature:
            return [
                PlannedStep(title: "Explore the current implementation and locate the files that need to change", phase: .exploration),
                PlannedStep(title: "Plan the implementation steps and expected outputs", phase: .planning),
                PlannedStep(title: "Implement the requested feature changes", phase: .mutation),
                PlannedStep(title: "Validate behavior with diffs, reads, and relevant build or test checks", phase: .validation)
            ]
        case .refactor:
            return [
                PlannedStep(title: "Inspect the code paths to understand the current structure and dependencies", phase: .exploration),
                PlannedStep(title: "Plan the refactor boundaries and no-regression checks", phase: .planning),
                PlannedStep(title: "Apply the refactor while preserving behavior", phase: .mutation),
                PlannedStep(title: "Validate with diffs, targeted reads, and any available checks", phase: .validation)
            ]
        case .docs:
            return [
                PlannedStep(title: "Inspect the relevant documentation and supporting project context", phase: .exploration),
                PlannedStep(title: "Plan the documentation updates needed", phase: .planning),
                PlannedStep(title: "Apply the documentation changes", phase: .mutation),
                PlannedStep(title: "Validate wording, file diffs, and summarize what changed", phase: .validation)
            ]
        case .git:
            return [
                PlannedStep(title: "Inspect repository status, branch state, and relevant diffs or commits", phase: .exploration),
                PlannedStep(title: "Plan the repo operations or conclusions needed", phase: .planning),
                PlannedStep(title: "Execute the requested repository changes or inspections", phase: .mutation),
                PlannedStep(title: "Validate the resulting git state and summarize it", phase: .validation)
            ]
        case .shell:
            return [
                PlannedStep(title: "Inspect the workspace state and the commands that are likely needed", phase: .exploration),
                PlannedStep(title: "Plan the command sequence and expected outputs", phase: .planning),
                PlannedStep(title: "Execute the requested shell operations", phase: .mutation),
                PlannedStep(title: "Validate command results and summarize what happened", phase: .validation)
            ]
        case .analysis, .general:
            return [
                PlannedStep(title: "Inspect the current workspace state relevant to the request", phase: .exploration),
                PlannedStep(title: "Synthesize the findings needed to answer the request", phase: .planning),
                PlannedStep(title: "Deliver a concise answer grounded in the inspected workspace context", phase: .validation)
            ]
        }
    }

    private static func isAnalysisOverviewPrompt(_ lowered: String) -> Bool {
        let overviewMarkers = [
            "what is this project about",
            "what's this project about",
            "what does this project do",
            "summarize this project",
            "summarize this repo",
            "summarize this repository",
            "explain this project",
            "explain this repo",
            "explain this repository",
            "give me an overview",
            "overview of this project",
            "overview of this repo",
            "understand this project",
            "understand this repo",
            "understand this codebase"
        ]
        return overviewMarkers.contains(where: lowered.contains)
    }
}
