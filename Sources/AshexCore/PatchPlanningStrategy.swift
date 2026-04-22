import Foundation

struct PatchPlan: Sendable, Equatable {
    let targetPaths: [String]
    let objectives: [String]
    let fileStatuses: [String]
    let summary: String
}

enum PatchPlanningStrategy {
    static func build(
        taskKind: TaskKind,
        prompt: String,
        explorationTargets: [String],
        pendingExplorationTargets: [String],
        inspectedPaths: [String],
        changedPaths: [String],
        recentFindings: [String],
        workspaceSnapshot: WorkspaceSnapshotRecord?
    ) -> PatchPlan {
        let promptPaths = extractPaths(from: prompt)
        let normalizedTargets = orderedUniqueStrings(
            promptPaths
            + changedPaths
            + inspectedPaths
            + explorationTargets
            + pendingExplorationTargets
        )

        let targetPaths = Array(normalizedTargets.prefix(6))
        var objectives: [String] = []

        switch taskKind {
        case .bugFix:
            objectives.append("Keep the fix narrow and preserve existing behavior outside the failure path.")
            objectives.append("Update only the files needed to resolve the failing path and its validation.")
        case .feature:
            objectives.append("Coordinate the minimal file set required for the new behavior.")
            objectives.append("Prefer targeted edits over broad rewrites across unrelated files.")
        case .refactor:
            objectives.append("Keep behavior stable while changing structure.")
            objectives.append("Batch related edits by file so the diff stays reviewable.")
        case .docs:
            objectives.append("Touch only the documentation files that explain the requested behavior.")
        case .git:
            objectives.append("Keep repository mutations deliberate and verify the resulting repo state.")
        case .shell:
            objectives.append("Use shell changes only when they directly support the requested workspace outcome.")
        case .analysis:
            objectives.append("Prefer targeted inspection of the most informative files before answering.")
            objectives.append("Summarize the workspace clearly once enough evidence is gathered.")
        case .general:
            objectives.append("Prefer a small, coherent set of file changes backed by prior inspection.")
        }

        if !recentFindings.isEmpty {
            objectives.append(contentsOf: recentFindings.suffix(2).map { "Carry forward: \($0)" })
        }
        if targetPaths.isEmpty, let workspaceSnapshot, !workspaceSnapshot.topLevelEntries.isEmpty {
            objectives.append("No concrete file set yet. Start from top-level areas like \(workspaceSnapshot.topLevelEntries.prefix(3).joined(separator: ", ")).")
        }

        objectives = Array(orderedUniqueStrings(objectives).prefix(6))
        let fileStatuses = targetPaths.map { path in
            fileStatusLine(
                path: path,
                taskKind: taskKind,
                changedPaths: changedPaths,
                inspectedPaths: inspectedPaths
            )
        }
        let summary: String
        if targetPaths.isEmpty {
            summary = "Patch plan is still forming. Continue exploration before coordinating edits."
        } else {
            summary = "Planned file set: \(targetPaths.joined(separator: ", "))"
        }

        return PatchPlan(targetPaths: targetPaths, objectives: objectives, fileStatuses: fileStatuses, summary: summary)
    }

    private static func fileStatusLine(
        path: String,
        taskKind: TaskKind,
        changedPaths: [String],
        inspectedPaths: [String]
    ) -> String {
        let status: String
        if changedPaths.contains(path) {
            status = "completed"
        } else if inspectedPaths.contains(path) {
            status = "inspected"
        } else {
            status = "pending"
        }

        return "\(status): \(path) - \(intent(for: taskKind, path: path))"
    }

    private static func intent(for taskKind: TaskKind, path: String) -> String {
        if path.hasSuffix(".md") {
            return "keep documentation aligned with the requested behavior"
        }
        if path.hasSuffix("Tests.swift") || path.contains("/Tests/") || path.hasPrefix("Tests/") {
            return "cover or verify the behavior touched by the change"
        }

        switch taskKind {
        case .bugFix:
            return "apply or verify the narrow fix path"
        case .feature:
            return "implement the requested behavior in the smallest relevant surface"
        case .refactor:
            return "preserve behavior while improving structure"
        case .docs:
            return "document the requested behavior clearly"
        case .git:
            return "verify repository state for this operation"
        case .shell:
            return "support the requested workspace operation"
        case .analysis:
            return "inspect for evidence before answering"
        case .general:
            return "coordinate the requested workspace change"
        }
    }

    private static func extractPaths(from text: String) -> [String] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        return tokens.compactMap { token in
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "[](){}<>,;:'\""))
            guard cleaned.contains("/") || cleaned.hasSuffix(".swift") || cleaned.hasSuffix(".md") || cleaned.hasSuffix(".json") || cleaned.hasSuffix(".txt") else {
                return nil
            }
            return cleaned
        }
    }

    private static func orderedUniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
