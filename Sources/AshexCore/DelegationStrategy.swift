import Foundation

struct DelegationBrief: Sendable {
    let role: String
    let goal: String
    let deliverables: [String]
}

struct DelegationHandoff: Sendable, Equatable {
    let summary: String
    let findings: [String]
    let remainingItems: [String]
    let recommendedPaths: [String]
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
                    "what still needs inspection next",
                    "FILES: recommended paths to inspect or change next"
                ]
            )
        case .planning:
            return .init(
                role: taskKind == .bugFix ? "fix-planner" : "implementation-planner",
                goal: "Turn the explored evidence into a bounded plan for '\(stepTitle)' without widening scope.",
                deliverables: [
                    "target files expected to matter",
                    "risks or unknowns that remain",
                    "concise handoff for the main agent",
                    "FILES: recommended paths for the planned change set"
                ]
            )
        case .validation:
            return .init(
                role: "validation-checker",
                goal: "Verify the current task state for '\(stepTitle)' and report what is verified versus still missing.",
                deliverables: [
                    "checks actually performed",
                    "verified outcomes",
                    "remaining validation gaps",
                    "FILES: paths that still need read-back or verification"
                ]
            )
        case .mutation:
            return .init(
                role: "implementation-helper",
                goal: "Stay narrowly focused on '\(stepTitle)' and avoid expanding scope.",
                deliverables: [
                    "concise implementation outcome",
                    "changed files",
                    "remaining follow-up items",
                    "FILES: changed paths or follow-up paths"
                ]
            )
        }
    }

    static func parseHandoff(_ text: String) -> DelegationHandoff {
        let sections = parseSections(in: text)
        let summary = sections["SUMMARY"]?.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        let findings = normalizedBulletLines(from: sections["FINDINGS"] ?? [])
        let remainingItems = normalizedBulletLines(from: sections["REMAINING"] ?? [])
        let recommendedPaths = normalizedBulletLines(from: sections["FILES"] ?? [])
        return .init(
            summary: summary.isEmpty ? "Delegated subtask completed." : summary,
            findings: findings,
            remainingItems: remainingItems,
            recommendedPaths: recommendedPaths
        )
    }

    private static func parseSections(in text: String) -> [String: [String]] {
        var sections: [String: [String]] = [:]
        var currentKey: String?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if ["SUMMARY:", "FINDINGS:", "REMAINING:", "FILES:"].contains(line) {
                currentKey = String(line.dropLast())
                sections[currentKey!, default: []] = []
                continue
            }
            guard let currentKey, !line.isEmpty else { continue }
            sections[currentKey, default: []].append(line)
        }

        return sections
    }

    private static func normalizedBulletLines(from lines: [String]) -> [String] {
        var seen: Set<String> = []
        return lines
            .map { $0.replacingOccurrences(of: "- ", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
