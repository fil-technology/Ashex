import Foundation

public struct SourceRangeHint: Sendable, Equatable {
    public let lineStart: Int
    public let lineEnd: Int

    public init(lineStart: Int, lineEnd: Int) {
        self.lineStart = lineStart
        self.lineEnd = lineEnd
    }
}

public struct ContextIndexedFile: Sendable, Equatable {
    public let relativePath: String
    public let contentTokens: [String]
    public let importTokens: [String]
    public let lastModifiedAt: Date?

    public init(relativePath: String, contentTokens: [String], importTokens: [String], lastModifiedAt: Date?) {
        self.relativePath = relativePath
        self.contentTokens = contentTokens
        self.importTokens = importTokens
        self.lastModifiedAt = lastModifiedAt
    }
}

public struct ContextIndex: Sendable, Equatable {
    public let workspaceRootPath: String
    public let files: [ContextIndexedFile]

    public init(workspaceRootPath: String, files: [ContextIndexedFile]) {
        self.workspaceRootPath = workspaceRootPath
        self.files = files
    }
}

public struct RankedContextResult: Sendable, Equatable {
    public let filePath: String
    public let score: Double
    public let reasons: [String]
    public let suggestedRanges: [SourceRangeHint]

    public init(filePath: String, score: Double, reasons: [String], suggestedRanges: [SourceRangeHint] = []) {
        self.filePath = filePath
        self.score = score
        self.reasons = reasons
        self.suggestedRanges = suggestedRanges
    }
}

public struct ContextSnippet: Sendable, Equatable {
    public let filePath: String
    public let range: SourceRangeHint
    public let lines: [String]
    public let reason: String

    public init(filePath: String, range: SourceRangeHint, lines: [String], reason: String) {
        self.filePath = filePath
        self.range = range
        self.lines = lines
        self.reason = reason
    }
}

public struct ContextPlanningBrief: Sendable, Equatable {
    public let task: String
    public let summary: String
    public let rankedResults: [RankedContextResult]
    public let snippets: [ContextSnippet]
    public let openQuestions: [String]
    public let suggestedNextSteps: [String]

    public init(
        task: String,
        summary: String,
        rankedResults: [RankedContextResult],
        snippets: [ContextSnippet],
        openQuestions: [String],
        suggestedNextSteps: [String]
    ) {
        self.task = task
        self.summary = summary
        self.rankedResults = rankedResults
        self.snippets = snippets
        self.openQuestions = openQuestions
        self.suggestedNextSteps = suggestedNextSteps
    }

    public var formatted: String {
        var lines: [String] = [
            "Summary: \(summary)"
        ]

        if !rankedResults.isEmpty {
            lines.append("Top files:")
            lines.append(contentsOf: rankedResults.prefix(3).map {
                "- \($0.filePath) [\(String(format: "%.1f", $0.score))] \($0.reasons.prefix(2).joined(separator: ", "))"
            })
        }

        if !snippets.isEmpty {
            lines.append("Suggested surgical reads:")
            lines.append(contentsOf: snippets.prefix(2).map {
                "- \($0.filePath):\($0.range.lineStart)-\($0.range.lineEnd) (\($0.reason))"
            })
        }

        if !openQuestions.isEmpty {
            lines.append("Open questions: \(openQuestions.prefix(2).joined(separator: " | "))")
        }

        if !suggestedNextSteps.isEmpty {
            lines.append("Suggested next steps: \(suggestedNextSteps.prefix(3).joined(separator: " | "))")
        }

        return lines.joined(separator: "\n")
    }
}

public enum ContextIndexBuilder {
    public static func build(
        workspaceRootURL: URL,
        fileManager: FileManager = .default
    ) -> ContextIndex {
        let normalizedRootURL = workspaceRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = normalizedRootURL.path
        guard let enumerator = fileManager.enumerator(
            at: normalizedRootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            return ContextIndex(workspaceRootPath: rootPath, files: [])
        }

        var files: [ContextIndexedFile] = []
        for case let fileURL as URL in enumerator {
            guard shouldIndex(fileURL: fileURL, rootPath: rootPath),
                  let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else {
                continue
            }

            let relativePath = relativePath(for: fileURL, rootPath: rootPath)
            let content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            let truncated = String(content.prefix(24_000))
            let importTokens = extractImportTokens(from: truncated)
            let contentTokens = Array(tokenSet(from: relativePath + "\n" + truncated).prefix(400))

            files.append(
                ContextIndexedFile(
                    relativePath: relativePath,
                    contentTokens: contentTokens,
                    importTokens: importTokens,
                    lastModifiedAt: values.contentModificationDate
                )
            )
        }

        return ContextIndex(workspaceRootPath: rootPath, files: files.sorted { $0.relativePath < $1.relativePath })
    }

    private static func shouldIndex(fileURL: URL, rootPath: String) -> Bool {
        let relativePath = relativePath(for: fileURL, rootPath: rootPath)
        let pathComponents = relativePath.split(separator: "/").map(String.init)
        let ignoredDirectories: Set<String> = [
            ".git", ".build", ".ashex", ".codex", "node_modules", "DerivedData", "build", "dist"
        ]

        if pathComponents.dropLast().contains(where: { ignoredDirectories.contains($0) }) {
            return false
        }

        let ignoredExtensions: Set<String> = [
            "png", "jpg", "jpeg", "gif", "pdf", "zip", "xcresult", "a", "o", "dylib"
        ]
        if ignoredExtensions.contains(fileURL.pathExtension.lowercased()) {
            return false
        }

        return true
    }

    private static func relativePath(for fileURL: URL, rootPath: String) -> String {
        let normalizedFilePath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        if normalizedFilePath.hasPrefix(rootPath + "/") {
            return String(normalizedFilePath.dropFirst(rootPath.count + 1))
        }
        return fileURL.lastPathComponent
    }

    private static func extractImportTokens(from text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var imports: [String] = []
        for line in lines.prefix(120) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("import ") {
                imports.append(String(trimmed.dropFirst("import ".count)))
            }
        }
        return Array(tokenSet(from: imports.joined(separator: " ")).prefix(50))
    }

    fileprivate static func tokenSet(from text: String) -> Set<String> {
        let separatedCamelCase = text.unicodeScalars.reduce(into: "") { partial, scalar in
            if CharacterSet.uppercaseLetters.contains(scalar), !partial.isEmpty {
                partial.append(" ")
            }
            partial.append(Character(scalar))
        }

        let normalized = separatedCamelCase
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: "\\", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .lowercased()

        return Set(
            normalized
                .split { $0.isWhitespace || $0.isPunctuation }
                .map(String.init)
                .filter { $0.count >= 2 }
        )
    }
}

public struct ContextQueryEngine: Sendable {
    public init() {}

    public func query(
        _ query: String,
        in index: ContextIndex,
        limit: Int = 8
    ) -> [RankedContextResult] {
        let queryTerms = ContextIndexBuilder.tokenSet(from: query)
        let changedFiles = changedFileSet(workspaceRootPath: index.workspaceRootPath)
        let recentFiles = recentlyTouchedFileSet(workspaceRootPath: index.workspaceRootPath)

        let ranked = index.files.compactMap { file -> RankedContextResult? in
            let path = file.relativePath
            let pathLower = path.lowercased()
            let pathTokens = ContextIndexBuilder.tokenSet(from: path)
            let basenameTokens = ContextIndexBuilder.tokenSet(from: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
            let contentTokens = Set(file.contentTokens)
            let importTokens = Set(file.importTokens)

            let matchedPath = queryTerms.intersection(pathTokens)
            let matchedBasename = queryTerms.intersection(basenameTokens)
            let matchedContent = queryTerms.intersection(contentTokens)
            let matchedImports = queryTerms.intersection(importTokens)

            var score = 0.0
            var reasons: [String] = []

            for term in queryTerms where pathLower.contains(term) {
                score += pathLower.hasSuffix(term) ? 8 : 4
                reasons.append("filename/path match: \(term)")
            }

            if !matchedBasename.isEmpty {
                score += Double(matchedBasename.count) * 8
                reasons.append("basename token match")
            }
            if !matchedPath.isEmpty {
                score += Double(matchedPath.count) * 3
                reasons.append("path token coverage")
            }
            if !matchedContent.isEmpty {
                score += Double(matchedContent.count) * 4
                reasons.append("content token match")
            }
            if !matchedImports.isEmpty {
                score += Double(matchedImports.count) * 2
                reasons.append("import token match")
            }

            let matchedTerms = matchedPath.union(matchedBasename).union(matchedContent).union(matchedImports)
            if !queryTerms.isEmpty {
                let coverage = Double(matchedTerms.count) / Double(queryTerms.count)
                if coverage > 0 {
                    score += coverage * 18
                    reasons.append("term coverage")
                }
                if matchedTerms.count == queryTerms.count {
                    score += 6
                    reasons.append("all query terms covered")
                }
            }

            if changedFiles.contains(path) {
                score += 3
                reasons.append("uncommitted changes")
            }
            if recentFiles.contains(path) {
                score += 2
                reasons.append("recent git history")
            }
            if let lastModifiedAt = file.lastModifiedAt, Date().timeIntervalSince(lastModifiedAt) < 60 * 60 * 24 * 7 {
                score += 1.5
                reasons.append("recently edited")
            }
            if path.hasPrefix("Sources/") {
                score += 1.5
                reasons.append("source file")
            } else if path.hasPrefix("Tests/"), !queryTerms.contains("test"), !queryTerms.contains("tests") {
                score -= 2
                reasons.append("test file penalty")
            }

            guard score > 0 else {
                return nil
            }

            return RankedContextResult(
                filePath: path,
                score: score,
                reasons: Array(NSOrderedSet(array: reasons)) as? [String] ?? reasons,
                suggestedRanges: [SourceRangeHint(lineStart: 1, lineEnd: 40)]
            )
        }

        return ranked
            .sorted {
                if $0.score == $1.score {
                    return $0.filePath < $1.filePath
                }
                return $0.score > $1.score
            }
            .prefix(limit)
            .map { $0 }
    }

    private func changedFileSet(workspaceRootPath: String) -> Set<String> {
        runGit(["status", "--porcelain"], workspaceRootPath: workspaceRootPath)
            .split(separator: "\n")
            .compactMap { line in
                let trimmed = line.dropFirst(3)
                return trimmed.isEmpty ? nil : String(trimmed)
            }
            .reduce(into: Set<String>()) { $0.insert($1) }
    }

    private func recentlyTouchedFileSet(workspaceRootPath: String) -> Set<String> {
        runGit(["log", "--since=90.days", "--name-only", "--format="], workspaceRootPath: workspaceRootPath)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
            .reduce(into: Set<String>()) { $0.insert($1) }
    }

    private func runGit(_ arguments: [String], workspaceRootPath: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", workspaceRootPath] + arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "" }
            return String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}

public struct ContextReadService: Sendable {
    public init() {}

    public func readFile(
        _ relativePath: String,
        range: SourceRangeHint,
        workspaceRootURL: URL
    ) throws -> ContextSnippet {
        let fileURL = workspaceRootURL.standardizedFileURL
            .resolvingSymlinksInPath()
            .appendingPathComponent(relativePath)
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
        let startIndex = max(range.lineStart - 1, 0)
        let endIndex = min(range.lineEnd, lines.count)
        let snippet = Array(lines[startIndex..<endIndex])
        return ContextSnippet(filePath: relativePath, range: range, lines: snippet, reason: "ranked context")
    }
}

public struct ContextPlanningService: Sendable {
    private let queryEngine: ContextQueryEngine
    private let readService: ContextReadService

    public init(
        queryEngine: ContextQueryEngine = .init(),
        readService: ContextReadService = .init()
    ) {
        self.queryEngine = queryEngine
        self.readService = readService
    }

    public func makeBrief(
        task: String,
        workspaceRootURL: URL,
        limit: Int = 5,
        snippetCount: Int = 2
    ) -> ContextPlanningBrief {
        let index = ContextIndexBuilder.build(workspaceRootURL: workspaceRootURL)
        let rankedResults = queryEngine.query(task, in: index, limit: limit)
        let snippets = rankedResults.prefix(snippetCount).compactMap { result in
            let range = result.suggestedRanges.first ?? SourceRangeHint(lineStart: 1, lineEnd: 40)
            return try? readService.readFile(result.filePath, range: range, workspaceRootURL: workspaceRootURL)
        }

        let summary: String
        if rankedResults.isEmpty {
            summary = "No direct ranked hits yet for the current task."
        } else {
            let topFiles = rankedResults.prefix(2).map(\.filePath).joined(separator: ", ")
            summary = "Likely starting points are \(topFiles), with \(snippets.count) suggested surgical read\(snippets.count == 1 ? "" : "s")."
        }

        let openQuestions = rankedResults.isEmpty
            ? ["No ranked context matched the task yet. Broaden the query or inspect repo structure first."]
            : []

        let suggestedNextSteps = rankedResults.prefix(3).map { result in
            "Inspect \(result.filePath)"
        }

        return ContextPlanningBrief(
            task: task,
            summary: summary,
            rankedResults: rankedResults,
            snippets: snippets,
            openQuestions: openQuestions,
            suggestedNextSteps: suggestedNextSteps
        )
    }
}
