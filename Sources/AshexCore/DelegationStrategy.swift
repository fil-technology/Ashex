import Foundation

struct DelegationBrief: Sendable {
    let role: String
    let goal: String
    let deliverables: [String]
}

enum DelegationStrategy {
    static func brief(
        phase: PlannedStepPhase,
        taskKind: TaskKind,
        stepTitle: String,
        explorationPlan: ExplorationPlan
    ) -> DelegationBrief {
        switch phase {
        case .exploration:
            return .init(
                role: "exploration-scout",
                goal: "Inspect the most relevant parts of the workspace for '\(stepTitle)' before any mutations happen.",
                deliverables: [
                    "important files or directories inspected",
                    "key findings relevant to the task",
                    "what still needs inspection next"
                ]
            )
        case .planning:
            return .init(
                role: taskKind == .bugFix ? "fix-planner" : "implementation-planner",
                goal: "Turn the explored evidence into a bounded plan for '\(stepTitle)' without widening scope.",
                deliverables: [
                    "target files expected to matter",
                    "risks or unknowns that remain",
                    "concise handoff for the main agent"
                ]
            )
        case .validation:
            return .init(
                role: "validation-checker",
                goal: "Verify the current task state for '\(stepTitle)' and report what is verified versus still missing.",
                deliverables: [
                    "checks actually performed",
                    "verified outcomes",
                    "remaining validation gaps"
                ]
            )
        case .mutation:
            return .init(
                role: "implementation-helper",
                goal: "Stay narrowly focused on '\(stepTitle)' and avoid expanding scope.",
                deliverables: [
                    "concise implementation outcome",
                    "changed files",
                    "remaining follow-up items"
                ]
            )
        }
    }
}
