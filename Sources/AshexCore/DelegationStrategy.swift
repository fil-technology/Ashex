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

struct DelegatedWorkItem: Sendable {
    let title: String
    let brief: DelegationBrief
    let scopedPrompt: String
    let allowedToolNames: Set<String>
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

    static func parallelWorkItems(
        phase: PlannedStepPhase,
        taskKind: TaskKind,
        stepTitle: String,
        stepPrompt: String,
        explorationPlan: ExplorationPlan,
        changedPaths: [String]
    ) -> [DelegatedWorkItem] {
        switch phase {
        case .exploration:
            let targets = Array(explorationPlan.targetPaths.filter(isMeaningfulParallelTarget).prefix(4))
            guard targets.count >= 2 else { return [] }
            let groups = splitEvenly(targets, maxGroups: 2)
            return groups.enumerated().map { index, paths in
                let scopedTitle = "\(stepTitle) [lane \(index + 1)]"
                let scopedPrompt = """
                \(stepPrompt)

                Focus only on these exploration targets:
                \(paths.map { "- \($0)" }.joined(separator: "\n"))

                Stay read-only and use filesystem/git tools only.
                """
                return DelegatedWorkItem(
                    title: scopedTitle,
                    brief: .init(
                        role: "exploration-scout-\(index + 1)",
                        goal: "Inspect only the scoped targets for \(stepTitle) and return a narrow read-only handoff.",
                        deliverables: [
                            "key findings for the scoped targets",
                            "recommended files to inspect next",
                            "remaining unknowns in the scoped area"
                        ]
                    ),
                    scopedPrompt: scopedPrompt,
                    allowedToolNames: ["filesystem", "git"]
                )
            }
        case .validation:
            let paths = Array(changedPaths.prefix(4))
            guard paths.count >= 2 else { return [] }
            let groups = splitEvenly(paths, maxGroups: 2)
            return groups.enumerated().map { index, scopedPaths in
                let scopedTitle = "\(stepTitle) [lane \(index + 1)]"
                let scopedPrompt = """
                \(stepPrompt)

                Validate only these changed paths:
                \(scopedPaths.map { "- \($0)" }.joined(separator: "\n"))

                Stay read-only and use filesystem/git tools only. Focus on diffs, status, and read-back validation.
                """
                return DelegatedWorkItem(
                    title: scopedTitle,
                    brief: .init(
                        role: "validation-scout-\(index + 1)",
                        goal: "Validate only the scoped changed paths for \(stepTitle) and return a read-only handoff.",
                        deliverables: [
                            "checks actually performed for the scoped files",
                            "validated findings for the scoped files",
                            "remaining validation gaps for the scoped files"
                        ]
                    ),
                    scopedPrompt: scopedPrompt,
                    allowedToolNames: ["filesystem", "git"]
                )
            }
        case .planning, .mutation:
            return []
        }
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

    private static func splitEvenly(_ values: [String], maxGroups: Int) -> [[String]] {
        guard !values.isEmpty else { return [] }
        let groupCount = min(maxGroups, values.count)
        var groups = Array(repeating: [String](), count: groupCount)
        for (index, value) in values.enumerated() {
            groups[index % groupCount].append(value)
        }
        return groups.filter { !$0.isEmpty }
    }

    private static func isMeaningfulParallelTarget(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed == "." || trimmed == ".git" || trimmed == ".ashex" || trimmed == ".codex" {
            return false
        }
        if trimmed.hasPrefix(".") && !trimmed.contains("/") {
            return false
        }
        let genericRoots: Set<String> = ["Sources", "Tests", "README.md", "Package.swift", "docs"]
        if genericRoots.contains(trimmed) {
            return true
        }
        return trimmed.contains("/") || trimmed.contains(".")
    }
}
