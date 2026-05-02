import Foundation

public struct ProjectGraphContext: Codable, Sendable, Equatable {
    public let projectRoot: URL
    public let graphExists: Bool
    public let lastBuiltAt: Date?
    public let reportPath: URL?
    public let querySummary: String?
    public let relatedFiles: [URL]
    public let confidence: Double?

    public init(
        projectRoot: URL,
        graphExists: Bool,
        lastBuiltAt: Date?,
        reportPath: URL?,
        querySummary: String? = nil,
        relatedFiles: [URL] = [],
        confidence: Double? = nil
    ) {
        self.projectRoot = projectRoot
        self.graphExists = graphExists
        self.lastBuiltAt = lastBuiltAt
        self.reportPath = reportPath
        self.querySummary = querySummary
        self.relatedFiles = relatedFiles
        self.confidence = confidence
    }
}

public struct GraphifyStateMetadata: Codable, Sendable, Equatable {
    public let projectRoot: String
    public let lastBuildAt: Date?
    public let graphifyVersion: String?
    public let graphPath: String?
    public let reportPath: String?
    public let sourceHash: String?
    public let status: String

    public init(
        projectRoot: String,
        lastBuildAt: Date?,
        graphifyVersion: String?,
        graphPath: String?,
        reportPath: String?,
        sourceHash: String?,
        status: String
    ) {
        self.projectRoot = projectRoot
        self.lastBuildAt = lastBuildAt
        self.graphifyVersion = graphifyVersion
        self.graphPath = graphPath
        self.reportPath = reportPath
        self.sourceHash = sourceHash
        self.status = status
    }
}

public struct GraphifyStatus: Codable, Sendable, Equatable {
    public let installed: Bool
    public let executablePath: String?
    public let version: String?
    public let pythonImportAvailable: Bool
    public let pythonExecutablePath: String?
    public let projectRoot: String
    public let graphExists: Bool
    public let graphPath: String
    public let reportExists: Bool
    public let reportPath: String
    public let statePath: String
    public let lastBuiltAt: Date?
    public let stateStatus: String?
    public let recommendedNextAction: String

    public init(
        installed: Bool,
        executablePath: String?,
        version: String?,
        pythonImportAvailable: Bool,
        pythonExecutablePath: String?,
        projectRoot: String,
        graphExists: Bool,
        graphPath: String,
        reportExists: Bool,
        reportPath: String,
        statePath: String,
        lastBuiltAt: Date?,
        stateStatus: String?,
        recommendedNextAction: String
    ) {
        self.installed = installed
        self.executablePath = executablePath
        self.version = version
        self.pythonImportAvailable = pythonImportAvailable
        self.pythonExecutablePath = pythonExecutablePath
        self.projectRoot = projectRoot
        self.graphExists = graphExists
        self.graphPath = graphPath
        self.reportExists = reportExists
        self.reportPath = reportPath
        self.statePath = statePath
        self.lastBuiltAt = lastBuiltAt
        self.stateStatus = stateStatus
        self.recommendedNextAction = recommendedNextAction
    }
}

public struct GraphifyIgnorePreparationResult: Codable, Sendable, Equatable {
    public let ignorePath: String
    public let created: Bool
    public let appendedEntries: [String]
    public let preservedExistingEntries: Bool
    public let statePath: String

    public init(ignorePath: String, created: Bool, appendedEntries: [String], preservedExistingEntries: Bool, statePath: String) {
        self.ignorePath = ignorePath
        self.created = created
        self.appendedEntries = appendedEntries
        self.preservedExistingEntries = preservedExistingEntries
        self.statePath = statePath
    }
}

public struct GraphifyCommandResult: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    public var success: Bool {
        exitCode == 0
    }
}

public struct GraphifyQueryResult: Codable, Sendable, Equatable {
    public let operation: String
    public let graphPath: String
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let summary: String

    public init(operation: String, graphPath: String, stdout: String, stderr: String, exitCode: Int32, summary: String) {
        self.operation = operation
        self.graphPath = graphPath
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.summary = summary
    }
}

public struct GraphifyReport: Codable, Sendable, Equatable {
    public let path: String
    public let exists: Bool
    public let content: String?
    public let truncated: Bool

    public init(path: String, exists: Bool, content: String?, truncated: Bool) {
        self.path = path
        self.exists = exists
        self.content = content
        self.truncated = truncated
    }
}

public struct GraphifyBuildGuidance: Codable, Sendable, Equatable {
    public let projectRoot: String
    public let installed: Bool
    public let graphExists: Bool
    public let recommendedCommand: String
    public let notes: [String]

    public init(projectRoot: String, installed: Bool, graphExists: Bool, recommendedCommand: String, notes: [String]) {
        self.projectRoot = projectRoot
        self.installed = installed
        self.graphExists = graphExists
        self.recommendedCommand = recommendedCommand
        self.notes = notes
    }
}

public struct GraphifyMaintenanceResult: Codable, Sendable, Equatable {
    public let operation: String
    public let command: [String]
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let statePath: String

    public init(operation: String, command: [String], stdout: String, stderr: String, exitCode: Int32, statePath: String) {
        self.operation = operation
        self.command = command
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.statePath = statePath
    }
}

public struct GraphifyCleanResult: Codable, Sendable, Equatable {
    public let removedPaths: [String]
    public let graphOutputPath: String
    public let statePath: String

    public init(removedPaths: [String], graphOutputPath: String, statePath: String) {
        self.removedPaths = removedPaths
        self.graphOutputPath = graphOutputPath
        self.statePath = statePath
    }
}

public protocol GraphifyCommandRunning: Sendable {
    func runGraphify(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL,
        timeout: TimeInterval
    ) async throws -> GraphifyCommandResult
}

public struct GraphifyProcessCommandRunner: GraphifyCommandRunning {
    public init() {}

    public func runGraphify(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL,
        timeout: TimeInterval
    ) async throws -> GraphifyCommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(timeout))
            if process.isRunning {
                process.terminate()
            }
        }
        process.waitUntilExit()
        timeoutTask.cancel()

        return GraphifyCommandResult(
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }
}

public enum GraphifyCommandBuilder {
    public static func queryArguments(question: String, useDFS: Bool, budget: Int?, graphPath: URL) -> [String] {
        var arguments = ["query", question]
        if useDFS {
            arguments.append("--dfs")
        }
        if let budget {
            arguments += ["--budget", String(budget)]
        }
        arguments += ["--graph", graphPath.path]
        return arguments
    }

    public static func pathArguments(source: String, target: String, graphPath: URL) -> [String] {
        ["path", source, target, "--graph", graphPath.path]
    }

    public static func explainArguments(node: String, graphPath: URL) -> [String] {
        ["explain", node, "--graph", graphPath.path]
    }
}

public enum GraphifyPlanningPolicy {
    public static func shouldUseGraphContext(prompt: String, taskKind: TaskKind) -> Bool {
        let lowered = prompt.lowercased()
        if taskKind == .git || taskKind == .shell {
            return false
        }
        if isTrivialKnownFileEdit(lowered) {
            return false
        }

        let graphMarkers = [
            "architecture", "dependency", "dependencies", "module", "modules",
            "how does", "how do", "where is", "where are", "implemented",
            "project structure", "codebase", "repo", "repository", "relationship",
            "relationships", "flow", "large refactor", "onboard", "understand",
            "build failure", "compile failure", "test failure"
        ]
        if graphMarkers.contains(where: lowered.contains) {
            return true
        }

        switch taskKind {
        case .analysis, .refactor:
            return true
        case .feature, .bugFix:
            return lowered.split(whereSeparator: \.isWhitespace).count >= 10
        case .docs, .general, .git, .shell:
            return false
        }
    }

    private static func isTrivialKnownFileEdit(_ lowered: String) -> Bool {
        let words = lowered.split(whereSeparator: \.isWhitespace)
        guard words.count <= 12 else { return false }
        let knownFileMarkers = [".swift", ".md", ".json", ".yml", ".yaml", ".toml", ".txt"]
        let editMarkers = ["edit", "change", "update", "rename", "fix typo"]
        return knownFileMarkers.contains(where: lowered.contains)
            && editMarkers.contains(where: lowered.contains)
    }
}

public struct KnowledgeGraphProvider {
    public let service: GraphifyService
    public let config: GraphifyConfig

    public init(service: GraphifyService, config: GraphifyConfig = .default) {
        self.service = service
        self.config = config
    }

    public func context(for question: String, taskKind: TaskKind) async -> ProjectGraphContext? {
        guard config.enabled, config.autoQueryForArchitectureTasks else {
            return nil
        }
        guard GraphifyPlanningPolicy.shouldUseGraphContext(prompt: question, taskKind: taskKind) else {
            return nil
        }

        let baseContext = service.projectGraphContext()
        guard baseContext.graphExists else {
            return nil
        }

        if let query = try? await service.query(question: question, budget: max(config.maxContextCharacters, 400)) {
            return ProjectGraphContext(
                projectRoot: baseContext.projectRoot,
                graphExists: true,
                lastBuiltAt: baseContext.lastBuiltAt,
                reportPath: baseContext.reportPath,
                querySummary: Self.clip(query.summary, maxCharacters: config.maxContextCharacters),
                relatedFiles: Self.extractRelatedFiles(from: query.stdout, projectRoot: baseContext.projectRoot),
                confidence: 0.8
            )
        }

        if let report = try? service.report(maxCharacters: config.maxContextCharacters),
           let content = report.content?.trimmingCharacters(in: .whitespacesAndNewlines),
           !content.isEmpty {
            return ProjectGraphContext(
                projectRoot: baseContext.projectRoot,
                graphExists: true,
                lastBuiltAt: baseContext.lastBuiltAt,
                reportPath: baseContext.reportPath,
                querySummary: content,
                relatedFiles: Self.extractRelatedFiles(from: content, projectRoot: baseContext.projectRoot),
                confidence: 0.5
            )
        }

        return baseContext
    }

    public static func renderContextBlock(_ context: ProjectGraphContext, question: String) -> String {
        renderContextBlock(context, question: question, maxRelatedFiles: GraphifyConfig.default.maxContextNodes, maxCharacters: GraphifyConfig.default.maxContextCharacters)
    }

    public static func renderContextBlock(
        _ context: ProjectGraphContext,
        question: String,
        maxRelatedFiles: Int,
        maxCharacters: Int
    ) -> String {
        var lines = [
            "<project_graph_context>",
            "Question: \(question)",
            "Graph exists: \(context.graphExists ? "yes" : "no")",
        ]
        if let lastBuiltAt = context.lastBuiltAt {
            lines.append("Last built: \(ISO8601DateFormatter().string(from: lastBuiltAt))")
        }
        if let reportPath = context.reportPath {
            lines.append("Report: \(reportPath.path)")
        }
        if !context.relatedFiles.isEmpty {
            lines.append("Relevant files:")
            lines.append(contentsOf: context.relatedFiles.prefix(maxRelatedFiles).map { "- \($0.path)" })
        }
        if let summary = context.querySummary, !summary.isEmpty {
            lines.append("Graph summary:")
            lines.append(clip(summary, maxCharacters: maxCharacters))
        }
        if let confidence = context.confidence {
            lines.append("Confidence: \(String(format: "%.2f", confidence))")
        }
        lines.append("</project_graph_context>")
        return clip(lines.joined(separator: "\n"), maxCharacters: maxCharacters + 800)
    }

    public static func extractRelatedFiles(from text: String, projectRoot: URL) -> [URL] {
        let pattern = #"[A-Za-z0-9_./-]+\.(swift|md|json|yml|yaml|toml|py|ts|tsx|js|jsx|go|rs|java|c|cpp|h|hpp)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen: Set<String> = []
        var urls: [URL] = []
        for match in regex.matches(in: text, range: nsRange) {
            guard let range = Range(match.range, in: text) else { continue }
            let rawPath = String(text[range])
                .trimmingCharacters(in: CharacterSet(charactersIn: "`'\".,:)("))
            guard !rawPath.isEmpty else { continue }
            let url = rawPath.hasPrefix("/")
                ? URL(fileURLWithPath: rawPath)
                : projectRoot.appendingPathComponent(rawPath)
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { continue }
            urls.append(standardized)
            if urls.count >= 15 {
                break
            }
        }
        return urls
    }

    public static func clip(_ text: String, maxCharacters: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        let index = trimmed.index(trimmed.startIndex, offsetBy: maxCharacters)
        return String(trimmed[..<index]) + "\n[truncated]"
    }
}

public struct GraphifyService {
    public let projectRoot: URL
    public let runner: any GraphifyCommandRunning
    public let executableURL: URL?
    public let config: GraphifyConfig

    private let fileManager: FileManager
    private let environment: [String: String]

    public init(
        projectRoot: URL,
        runner: any GraphifyCommandRunning = GraphifyProcessCommandRunner(),
        executableURL: URL? = nil,
        config: GraphifyConfig = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.projectRoot = projectRoot.standardizedFileURL
        self.runner = runner
        self.config = config
        self.executableURL = executableURL ?? config.executablePath.map { URL(fileURLWithPath: $0) }
        self.environment = environment
        self.fileManager = fileManager
    }

    public var graphOutputDirectory: URL {
        projectRoot.appendingPathComponent("graphify-out", isDirectory: true)
    }

    public var graphPath: URL {
        graphOutputDirectory.appendingPathComponent("graph.json")
    }

    public var reportPath: URL {
        resolveProjectPath(config.reportPath ?? "graphify-out/GRAPH_REPORT.md")
    }

    public var statePath: URL {
        resolveProjectPath(config.statePath)
    }

    public var ignorePath: URL {
        projectRoot.appendingPathComponent(".graphifyignore")
    }

    public func status() async -> GraphifyStatus {
        let executable = executableURL ?? locateExecutable()
        let installed = executable != nil
        let version = installed ? await graphifyVersion(executableURL: executable!) : nil
        let pythonImport = pythonImportStatus()
        let metadata = readStateMetadata()
        let graphExists = fileManager.fileExists(atPath: graphPath.path)
        let reportExists = fileManager.fileExists(atPath: reportPath.path)
        let lastBuiltAt = metadata?.lastBuildAt ?? modificationDate(for: graphPath)

        return GraphifyStatus(
            installed: installed,
            executablePath: executable?.path,
            version: version,
            pythonImportAvailable: pythonImport.available,
            pythonExecutablePath: pythonImport.executable?.path,
            projectRoot: projectRoot.path,
            graphExists: graphExists,
            graphPath: graphPath.path,
            reportExists: reportExists,
            reportPath: reportPath.path,
            statePath: statePath.path,
            lastBuiltAt: lastBuiltAt,
            stateStatus: metadata?.status,
            recommendedNextAction: recommendedNextAction(installed: installed, graphExists: graphExists, reportExists: reportExists)
        )
    }

    public func projectGraphContext() -> ProjectGraphContext {
        let graphExists = fileManager.fileExists(atPath: graphPath.path)
        return ProjectGraphContext(
            projectRoot: projectRoot,
            graphExists: graphExists,
            lastBuiltAt: readStateMetadata()?.lastBuildAt ?? modificationDate(for: graphPath),
            reportPath: fileManager.fileExists(atPath: reportPath.path) ? reportPath : nil
        )
    }

    public func query(question: String, useDFS: Bool = false, budget: Int? = nil, graphPath overrideGraphPath: URL? = nil) async throws -> GraphifyQueryResult {
        let graphPath = overrideGraphPath ?? self.graphPath
        return try await runGraphifyCommand(
            operation: "query",
            arguments: GraphifyCommandBuilder.queryArguments(question: question, useDFS: useDFS, budget: budget, graphPath: graphPath),
            graphPath: graphPath
        )
    }

    public func path(source: String, target: String, graphPath overrideGraphPath: URL? = nil) async throws -> GraphifyQueryResult {
        let graphPath = overrideGraphPath ?? self.graphPath
        return try await runGraphifyCommand(
            operation: "path",
            arguments: GraphifyCommandBuilder.pathArguments(source: source, target: target, graphPath: graphPath),
            graphPath: graphPath
        )
    }

    public func explain(node: String, graphPath overrideGraphPath: URL? = nil) async throws -> GraphifyQueryResult {
        let graphPath = overrideGraphPath ?? self.graphPath
        return try await runGraphifyCommand(
            operation: "explain",
            arguments: GraphifyCommandBuilder.explainArguments(node: node, graphPath: graphPath),
            graphPath: graphPath
        )
    }

    public func report(maxCharacters: Int? = nil) throws -> GraphifyReport {
        guard fileManager.fileExists(atPath: reportPath.path) else {
            return GraphifyReport(path: reportPath.path, exists: false, content: nil, truncated: false)
        }
        let content = try String(contentsOf: reportPath, encoding: .utf8)
        if let maxCharacters, content.count > maxCharacters {
            let index = content.index(content.startIndex, offsetBy: maxCharacters)
            return GraphifyReport(path: reportPath.path, exists: true, content: String(content[..<index]), truncated: true)
        }
        return GraphifyReport(path: reportPath.path, exists: true, content: content, truncated: false)
    }

    public func buildGuidance() async -> GraphifyBuildGuidance {
        let status = await status()
        return GraphifyBuildGuidance(
            projectRoot: projectRoot.path,
            installed: status.installed,
            graphExists: status.graphExists,
            recommendedCommand: "/graphify \(projectRoot.path)",
            notes: [
                "Graphify's current full initial graph build is an AI-assistant skill workflow, not a standalone `graphify build` terminal command.",
                "Use the official `/graphify <path>` workflow for the first build so semantic extraction can run through the assistant.",
                "After a graph exists, ASHEX can run `ashex graphify rebuild` for code-only upstream `graphify update` maintenance.",
            ]
        )
    }

    public func prepareForInitialBuild() throws -> GraphifyIgnorePreparationResult {
        let existingContent = (try? String(contentsOf: ignorePath, encoding: .utf8)) ?? ""
        let existingEntries = Set(existingContent
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") })
        let missingEntries = Self.defaultIgnoreEntries.filter { !existingEntries.contains($0) }
        let existed = fileManager.fileExists(atPath: ignorePath.path)

        if !missingEntries.isEmpty {
            var content = existingContent
            if !content.isEmpty, !content.hasSuffix("\n") {
                content.append("\n")
            }
            if content.isEmpty {
                content.append("# Generated by ASHEX. Graphify also respects its own upstream ignore behavior.\n")
            } else {
                content.append("\n# Added by ASHEX for generated/cache-heavy paths.\n")
            }
            content.append(missingEntries.joined(separator: "\n"))
            content.append("\n")
            try content.write(to: ignorePath, atomically: true, encoding: .utf8)
        }

        try writeStateMetadata(.init(
            projectRoot: projectRoot.path,
            lastBuildAt: nil,
            graphifyVersion: nil,
            graphPath: graphPath.path,
            reportPath: reportPath.path,
            sourceHash: nil,
            status: "prepared"
        ))

        return GraphifyIgnorePreparationResult(
            ignorePath: ignorePath.path,
            created: !existed,
            appendedEntries: missingEntries,
            preservedExistingEntries: existed,
            statePath: statePath.path
        )
    }

    public func rebuild() async throws -> GraphifyMaintenanceResult {
        try await runMaintenanceCommand(operation: "rebuild", arguments: ["update", projectRoot.path])
    }

    public func clusterOnly() async throws -> GraphifyMaintenanceResult {
        try await runMaintenanceCommand(operation: "cluster-only", arguments: ["cluster-only", projectRoot.path])
    }

    public func clean(confirm: Bool) throws -> GraphifyCleanResult {
        guard confirm else {
            throw AshexError.model("`ashex graphify clean` removes graphify-out and graph state. Re-run with --yes to confirm.")
        }

        var removed: [String] = []
        if fileManager.fileExists(atPath: graphOutputDirectory.path) {
            try fileManager.removeItem(at: graphOutputDirectory)
            removed.append(graphOutputDirectory.path)
        }
        let stateDirectory = statePath.deletingLastPathComponent()
        if fileManager.fileExists(atPath: stateDirectory.path) {
            try fileManager.removeItem(at: stateDirectory)
            removed.append(stateDirectory.path)
        }
        return GraphifyCleanResult(
            removedPaths: removed,
            graphOutputPath: graphOutputDirectory.path,
            statePath: statePath.path
        )
    }

    public func readStateMetadata() -> GraphifyStateMetadata? {
        guard fileManager.fileExists(atPath: statePath.path),
              let data = try? Data(contentsOf: statePath) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GraphifyStateMetadata.self, from: data)
    }

    public func writeStateMetadata(_ metadata: GraphifyStateMetadata) throws {
        try fileManager.createDirectory(at: statePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: statePath, options: .atomic)
    }

    private func runGraphifyCommand(operation: String, arguments: [String], graphPath: URL) async throws -> GraphifyQueryResult {
        guard fileManager.fileExists(atPath: graphPath.path) else {
            throw AshexError.model("No Graphify graph found at \(graphPath.path). Build it with the official `/graphify <path>` workflow first.")
        }
        guard let executable = executableURL ?? locateExecutable() else {
            throw AshexError.model("Graphify is not installed. Install it from https://github.com/safishamsi/graphify, then rerun this command.")
        }

        let result = try await runner.runGraphify(
            executableURL: executable,
            arguments: arguments,
            workingDirectory: projectRoot,
            timeout: 60
        )
        guard result.success else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AshexError.shell("Graphify \(operation) failed with exit code \(result.exitCode)\(detail.isEmpty ? "" : "\n\(detail)")")
        }
        return GraphifyQueryResult(
            operation: operation,
            graphPath: graphPath.path,
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode,
            summary: Self.summary(from: result.stdout)
        )
    }

    private func runMaintenanceCommand(operation: String, arguments: [String]) async throws -> GraphifyMaintenanceResult {
        guard fileManager.fileExists(atPath: graphPath.path) else {
            throw AshexError.model("No Graphify graph found at \(graphPath.path). Build it with the official `/graphify <path>` workflow first.")
        }
        guard let executable = executableURL ?? locateExecutable() else {
            throw AshexError.model("Graphify is not installed. Install it from https://github.com/safishamsi/graphify, then rerun this command.")
        }

        let result = try await runner.runGraphify(
            executableURL: executable,
            arguments: arguments,
            workingDirectory: projectRoot,
            timeout: 120
        )
        guard result.success else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AshexError.shell("Graphify \(operation) failed with exit code \(result.exitCode)\(detail.isEmpty ? "" : "\n\(detail)")")
        }

        try writeStateMetadata(.init(
            projectRoot: projectRoot.path,
            lastBuildAt: Date(),
            graphifyVersion: nil,
            graphPath: graphPath.path,
            reportPath: fileManager.fileExists(atPath: reportPath.path) ? reportPath.path : nil,
            sourceHash: nil,
            status: "ready"
        ))

        return GraphifyMaintenanceResult(
            operation: operation,
            command: [executable.path] + arguments,
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode,
            statePath: statePath.path
        )
    }

    private func locateExecutable() -> URL? {
        if let configured = config.executablePath {
            let url = URL(fileURLWithPath: configured)
            if isExecutableFile(url) {
                return url
            }
        }

        if let explicit = environment["ASHEX_GRAPHIFY_PATH"], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit)
            if isExecutableFile(url) {
                return url
            }
        }

        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("graphify")
            if isExecutableFile(candidate) {
                return candidate
            }
        }
        return nil
    }

    private func pythonImportStatus() -> (available: Bool, executable: URL?) {
        guard let executable = locatePythonExecutable() else {
            return (false, nil)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["-c", "import graphify"]
        process.currentDirectoryURL = projectRoot
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return (process.terminationStatus == 0, executable)
        } catch {
            return (false, executable)
        }
    }

    private func locatePythonExecutable() -> URL? {
        let names = ["python3", "python"]
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            for name in names {
                let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
                if isExecutableFile(candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    private func isExecutableFile(_ url: URL) -> Bool {
        fileManager.isExecutableFile(atPath: url.path)
    }

    private func resolveProjectPath(_ path: String) -> URL {
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : projectRoot.appendingPathComponent(path)
        return url.standardizedFileURL
    }

    private func graphifyVersion(executableURL: URL) async -> String? {
        guard let result = try? await runner.runGraphify(
            executableURL: executableURL,
            arguments: ["--version"],
            workingDirectory: projectRoot,
            timeout: 5
        ), result.success else {
            return nil
        }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func modificationDate(for url: URL) -> Date? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }

    private func recommendedNextAction(installed: Bool, graphExists: Bool, reportExists: Bool) -> String {
        if !installed {
            return "Install Graphify from https://github.com/safishamsi/graphify (Python package `graphifyy`), then run `ashex graphify status`."
        }
        if !graphExists {
            return "Build the initial graph with the official `/graphify <path>` assistant workflow, then run `ashex graphify query \"...\"`."
        }
        if !reportExists {
            return "Graph JSON exists. Regenerate the report with the official `/graphify <path> --cluster-only` flow if needed."
        }
        return "Graph is ready. Use `ashex graphify query \"...\"` for architecture/context questions."
    }

    public static func summary(from output: String, maxCharacters: Int = 1200) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else {
            return trimmed
        }
        let index = trimmed.index(trimmed.startIndex, offsetBy: maxCharacters)
        return String(trimmed[..<index]) + "\n[truncated]"
    }

    public static let defaultIgnoreEntries = [
        ".git/",
        ".ashex/",
        ".codex/",
        "node_modules/",
        ".build/",
        "DerivedData/",
        "dist/",
        "build/",
        "target/",
        "vendor/",
        ".venv/",
        "venv/",
        "__pycache__/",
        "*.xcarchive",
        "*.xcodeproj/project.xcworkspace/xcuserdata/",
        "*.xcworkspace/xcuserdata/",
        "*.mlmodelc",
        "*.safetensors",
        "*.gguf",
    ]
}
