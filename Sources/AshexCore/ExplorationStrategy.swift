import Foundation

public struct ExplorationPlan: Sendable, Equatable {
    public let summary: String
    public let recommendations: [String]
    public let targetPaths: [String]
    public let suggestedQueries: [String]

    public init(summary: String, recommendations: [String], targetPaths: [String] = [], suggestedQueries: [String] = []) {
        self.summary = summary
        self.recommendations = recommendations
        self.targetPaths = targetPaths
        self.suggestedQueries = suggestedQueries
    }

    public var formatted: String {
        ([summary] + recommendations.enumerated().map { "\($0.offset + 1). \($0.element)" }).joined(separator: "\n")
    }
}

public enum ExplorationStrategy {
    public static func recommend(
        taskKind: TaskKind,
        prompt: String,
        workspaceSnapshot: WorkspaceSnapshotRecord?
    ) -> ExplorationPlan {
        let focus = PromptFocus(prompt: prompt)
        let searchRoots = preferredSearchRoots(for: taskKind, snapshot: workspaceSnapshot)
        let focusTerms = focus.signalTerms
        let focusText = focusTerms.isEmpty ? "the request and nearby implementation" : focusTerms.joined(separator: ", ")
        let rootText = searchRoots.joined(separator: ", ")
        let targetPaths = prioritizedTargetPaths(
            taskKind: taskKind,
            focus: focus,
            snapshot: workspaceSnapshot,
            searchRoots: searchRoots
        )
        let suggestedQueries = prioritizedQueries(taskKind: taskKind, focus: focus, snapshot: workspaceSnapshot)

        let summary = switch taskKind {
        case .bugFix:
            "Explore the failing surface first so the fix is based on evidence, not guesses."
        case .feature:
            "Explore the current implementation surface before adding behavior."
        case .refactor:
            "Explore dependencies and call sites before changing structure."
        case .docs:
            "Explore the relevant docs and adjacent instructions before editing text."
        case .git:
            "Explore repository state before making or summarizing repo changes."
        case .shell:
            "Explore the workspace state before running mutating commands."
        case .analysis, .general:
            "Explore the relevant files and repo context before deciding on changes."
        }

        var recommendations: [String] = []

        switch taskKind {
        case .bugFix:
            recommendations.append("Run `search_text` in \(rootText) for \(focusText) to find the failing code path.")
            recommendations.append("Run `find_files` for likely file names or symbols related to \(focusText).")
            recommendations.append("Use `read_text_file` on the most relevant implementation file and nearby test file before editing.")
            recommendations.append("Use read-only git inspection like `status` or `diff_unstaged` if the bug may relate to recent local changes.")
        case .feature:
            recommendations.append("Run `find_files` in \(rootText) to locate the main implementation surface for \(focusText).")
            recommendations.append("Run `search_text` for reused symbols, routes, types, or commands related to \(focusText).")
            recommendations.append("Use `read_text_file` on the main implementation file and one adjacent test or supporting file before editing.")
            recommendations.append("Inspect README or instruction files if the feature touches public behavior or setup.")
        case .refactor:
            recommendations.append("Run `search_text` in \(rootText) for the primary types, functions, or modules involved in \(focusText).")
            recommendations.append("Run `find_files` to map implementation files, tests, and related call sites.")
            recommendations.append("Use `read_text_file` on the core file plus at least one dependency or caller before restructuring.")
            recommendations.append("Use read-only git inspection to understand any local changes before refactoring further.")
        case .docs:
            recommendations.append("Run `find_files` for README, docs, changelog, or instruction files related to \(focusText).")
            recommendations.append("Use `read_text_file` on the main doc plus one adjacent instruction or config file before editing.")
        case .git:
            recommendations.append("Start with git `status` and `current_branch` to anchor the repo state.")
            recommendations.append("Use `diff_unstaged`, `diff_staged`, or `log` based on the request before changing anything.")
        case .shell:
            recommendations.append("Use `list_directory` or `file_info` to confirm the workspace shape before running commands.")
            recommendations.append("Prefer one small read-only shell command first if the task depends on command output.")
        case .analysis, .general:
            recommendations.append("Run `find_files` in \(rootText) to locate the most relevant files for \(focusText).")
            recommendations.append("Run `search_text` for the main symbols or concepts related to \(focusText).")
            recommendations.append("Use `read_text_file` on the top one or two matching files before deciding on changes.")
        }

        if let snapshot = workspaceSnapshot, !snapshot.instructionFiles.isEmpty, taskKind != .git {
            recommendations.append("Check instruction files first if they are relevant: \(snapshot.instructionFiles.joined(separator: ", ")).")
        }

        if !targetPaths.isEmpty {
            recommendations.append("Prioritize these likely targets first: \(targetPaths.joined(separator: ", ")).")
        }
        if !suggestedQueries.isEmpty {
            recommendations.append("Use these search queries early: \(suggestedQueries.joined(separator: ", ")).")
        }

        var seen: Set<String> = []
        let deduped = recommendations.filter { seen.insert($0).inserted }
        return ExplorationPlan(summary: summary, recommendations: deduped, targetPaths: targetPaths, suggestedQueries: suggestedQueries)
    }

    private static func preferredSearchRoots(for taskKind: TaskKind, snapshot: WorkspaceSnapshotRecord?) -> [String] {
        let topLevel = snapshot?.topLevelEntries ?? []
        let containsSources = topLevel.contains(where: { $0.hasPrefix("Sources") })
        let containsTests = topLevel.contains(where: { $0.hasPrefix("Tests") })
        let containsDocs = topLevel.contains(where: { $0.lowercased().contains("docs") || $0.lowercased().contains("readme") })

        switch taskKind {
        case .docs:
            var roots = ["README.md"]
            if containsDocs { roots.append("docs") }
            return roots
        case .git:
            return [".git", "."]
        case .shell:
            return containsSources ? [".", "Sources"] : ["."]
        case .bugFix, .feature, .refactor, .analysis, .general:
            var roots: [String] = []
            if containsSources { roots.append("Sources") }
            if containsTests { roots.append("Tests") }
            if roots.isEmpty { roots.append(".") }
            return roots
        }
    }

    private static func prioritizedTargetPaths(
        taskKind: TaskKind,
        focus: PromptFocus,
        snapshot: WorkspaceSnapshotRecord?,
        searchRoots: [String]
    ) -> [String] {
        var targets: [String] = []

        if let snapshot {
            targets.append(contentsOf: snapshot.instructionFiles)
        }
        targets.append(contentsOf: focus.fileLikeTerms)

        switch taskKind {
        case .bugFix, .feature, .refactor, .analysis, .general:
            targets.append(contentsOf: searchRoots)
            if searchRoots.contains("Sources") { targets.append("Sources") }
            if searchRoots.contains("Tests") { targets.append("Tests") }
        case .docs:
            targets.append(contentsOf: searchRoots)
        case .git:
            targets.append(contentsOf: [".git", "."])
        case .shell:
            targets.append(contentsOf: searchRoots)
        }

        var seen: Set<String> = []
        return targets
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(8)
            .map { $0 }
    }

    private static func prioritizedQueries(
        taskKind: TaskKind,
        focus: PromptFocus,
        snapshot: WorkspaceSnapshotRecord?
    ) -> [String] {
        var queries = focus.signalTerms
        if let branch = snapshot?.gitBranch, taskKind == .git {
            queries.append(branch)
        }

        if queries.isEmpty, let snapshot {
            queries.append(contentsOf: snapshot.topLevelEntries.prefix(2).map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            })
        }

        var seen: Set<String> = []
        return queries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(6)
            .map { $0 }
    }
}

private struct PromptFocus {
    let prompt: String

    var signalTerms: [String] {
        var terms: [String] = []
        terms.append(contentsOf: fileLikeTerms)
        terms.append(contentsOf: symbolLikeTerms)
        if terms.isEmpty {
            terms.append(contentsOf: meaningfulWords.prefix(4))
        }

        var seen: Set<String> = []
        return terms.filter { seen.insert($0.lowercased()).inserted }
    }

    var fileLikeTerms: [String] {
        prompt.split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters) }
            .filter { $0.contains("/") || $0.contains(".") }
            .filter { !$0.isEmpty }
    }

    private var symbolLikeTerms: [String] {
        prompt.split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters) }
            .filter { token in
                guard token.count >= 3 else { return false }
                return token.first?.isUppercase == true || token.contains("_") || token.contains("-")
            }
    }

    private var meaningfulWords: [String] {
        let stopWords: Set<String> = [
            "the", "and", "for", "with", "that", "this", "from", "into", "then", "also",
            "please", "make", "need", "want", "show", "update", "fix", "add", "create",
            "implement", "build", "refactor", "improve", "project", "code", "files"
        ]

        return prompt.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters) }
            .filter { $0.count >= 4 && !stopWords.contains($0) }
    }
}
