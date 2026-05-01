import Foundation

public struct AgentHome: Sendable {
    public let storageRoot: URL
    public let workspaceRoot: URL
    public let paths: AgentHomePaths

    public init(storageRoot: URL, workspaceRoot: URL) {
        self.storageRoot = storageRoot.standardizedFileURL
        self.workspaceRoot = workspaceRoot.standardizedFileURL
        self.paths = AgentHomePaths(storageRoot: self.storageRoot, workspaceRoot: self.workspaceRoot)
    }

    @discardableResult
    public func initialize(createProjectContextFiles: Bool = false) throws -> AgentHomeInitializationReport {
        var createdPaths: [String] = []

        func createDirectory(_ url: URL) throws {
            guard !FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            createdPaths.append(paths.displayPath(for: url))
        }

        func writeFileIfMissing(_ url: URL, contents: String) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !FileManager.default.fileExists(atPath: url.path) else { return }
            try contents.write(to: url, atomically: true, encoding: .utf8)
            createdPaths.append(paths.displayPath(for: url))
        }

        try createDirectory(storageRoot)
        try createDirectory(workspaceRoot)
        try createDirectory(paths.sessionsDirectory)
        try createDirectory(paths.memoryDirectory)
        try createDirectory(paths.skillsInstalledDirectory)
        try createDirectory(paths.skillsQuarantinedDirectory)
        try createDirectory(paths.skillsGeneratedDirectory)
        try createDirectory(paths.tasksDirectory)
        try createDirectory(paths.cronDirectory)
        try createDirectory(paths.logsDirectory)
        try createDirectory(paths.mcpDirectory)
        try createDirectory(paths.approvalsDirectory)

        try writeFileIfMissing(paths.soulFile, contents: """
        # SOUL

        Durable ASHEX identity and personality notes live here.
        """)
        try writeFileIfMissing(paths.configTomlFile, contents: """
        # ASHEX configuration

        [agent]
        local_first = true
        """)
        try writeFileIfMissing(paths.stateSQLiteCompatibilityFile, contents: "")
        try writeFileIfMissing(paths.agentMemoryFile, contents: "# Agent Memory\n\n")
        try writeFileIfMissing(paths.userMemoryFile, contents: "# User Profile\n\n")
        try writeFileIfMissing(paths.projectsMemoryFile, contents: "# Project Memory\n\n")
        try writeFileIfMissing(paths.lessonsMemoryFile, contents: "# Lessons Learned\n\n")
        try writeFileIfMissing(paths.cronJobsFile, contents: "# ASHEX cron jobs\n\n")
        try writeFileIfMissing(paths.cronHistoryFile, contents: "")
        try writeFileIfMissing(paths.ashexLogFile, contents: "")
        try writeFileIfMissing(paths.toolCallsLogFile, contents: "")
        try writeFileIfMissing(paths.mcpServersFile, contents: "[]\n")
        try writeFileIfMissing(paths.approvalsAllowlistFile, contents: "# ASHEX approval allowlist\n\n")
        try writeFileIfMissing(paths.approvalsAuditFile, contents: "")
        try writeFileIfMissing(paths.memoryAuditFile, contents: "")

        try createDirectory(paths.projectAshexDirectory)
        try createDirectory(paths.projectMemoryDirectory)
        try createDirectory(paths.projectSkillsDirectory)
        try createDirectory(paths.projectTasksDirectory)
        try createDirectory(paths.projectLogsDirectory)
        try createDirectory(paths.learningsDirectory)
        try writeFileIfMissing(paths.projectMemoryFile, contents: "# Project Memory\n\n")
        try writeFileIfMissing(paths.learningsFile, contents: "# Learnings\n\n")
        try writeFileIfMissing(paths.errorsFile, contents: "# Errors\n\n")
        try writeFileIfMissing(paths.featureRequestsFile, contents: "# Feature Requests\n\n")
        try writeFileIfMissing(paths.correctionsFile, contents: "# Corrections\n\n")

        if createProjectContextFiles {
            try writeFileIfMissing(paths.projectAgentsFile, contents: """
            # AGENTS

            Project architecture, commands, paths, ports, and workflows live here.
            """)
            try writeFileIfMissing(paths.projectAshexContextFile, contents: """
            # ASHEX

            Project-specific ASHEX context lives here.
            """)
            try writeFileIfMissing(paths.projectASHEXFile, contents: """
            # ASHEX

            Additional project-specific ASHEX context.
            """)
        }

        let kbReport = try AgentKnowledgeBase(home: self).initialize()
        createdPaths.append(contentsOf: kbReport.createdPaths)

        return AgentHomeInitializationReport(createdPaths: Array(Set(createdPaths)).sorted())
    }
}

public struct AgentHomePaths: Sendable {
    public let storageRoot: URL
    public let workspaceRoot: URL

    public var soulFile: URL { storageRoot.appendingPathComponent("SOUL.md") }
    public var configTomlFile: URL { storageRoot.appendingPathComponent("config.toml") }
    public var stateSQLiteCompatibilityFile: URL { storageRoot.appendingPathComponent("state.sqlite") }
    public var sessionsDirectory: URL { storageRoot.appendingPathComponent("sessions", isDirectory: true) }
    public var memoryDirectory: URL { storageRoot.appendingPathComponent("memory", isDirectory: true) }
    public var agentMemoryFile: URL { memoryDirectory.appendingPathComponent("MEMORY.md") }
    public var userMemoryFile: URL { memoryDirectory.appendingPathComponent("USER.md") }
    public var projectsMemoryFile: URL { memoryDirectory.appendingPathComponent("PROJECTS.md") }
    public var lessonsMemoryFile: URL { memoryDirectory.appendingPathComponent("LESSONS.md") }
    public var memoryAuditFile: URL { memoryDirectory.appendingPathComponent("audit.jsonl") }
    public var skillsDirectory: URL { storageRoot.appendingPathComponent("skills", isDirectory: true) }
    public var skillsInstalledDirectory: URL { skillsDirectory.appendingPathComponent("installed", isDirectory: true) }
    public var skillsQuarantinedDirectory: URL { skillsDirectory.appendingPathComponent("quarantined", isDirectory: true) }
    public var skillsGeneratedDirectory: URL { skillsDirectory.appendingPathComponent("generated", isDirectory: true) }
    public var tasksDirectory: URL { storageRoot.appendingPathComponent("tasks", isDirectory: true) }
    public var cronDirectory: URL { storageRoot.appendingPathComponent("cron", isDirectory: true) }
    public var cronJobsFile: URL { cronDirectory.appendingPathComponent("jobs.toml") }
    public var cronHistoryFile: URL { cronDirectory.appendingPathComponent("history.jsonl") }
    public var logsDirectory: URL { storageRoot.appendingPathComponent("logs", isDirectory: true) }
    public var ashexLogFile: URL { logsDirectory.appendingPathComponent("ashex.log") }
    public var toolCallsLogFile: URL { logsDirectory.appendingPathComponent("tool_calls.jsonl") }
    public var mcpDirectory: URL { storageRoot.appendingPathComponent("mcp", isDirectory: true) }
    public var mcpServersFile: URL { mcpDirectory.appendingPathComponent("servers.json") }
    public var approvalsDirectory: URL { storageRoot.appendingPathComponent("approvals", isDirectory: true) }
    public var approvalsAllowlistFile: URL { approvalsDirectory.appendingPathComponent("allowlist.toml") }
    public var approvalsAuditFile: URL { approvalsDirectory.appendingPathComponent("audit.jsonl") }

    public var projectAgentsFile: URL { workspaceRoot.appendingPathComponent("AGENTS.md") }
    public var projectAshexContextFile: URL { workspaceRoot.appendingPathComponent(".ashex.md") }
    public var projectASHEXFile: URL { workspaceRoot.appendingPathComponent("ASHEX.md") }
    public var projectAshexDirectory: URL { workspaceRoot.appendingPathComponent(".ashex", isDirectory: true) }
    public var projectMemoryDirectory: URL { projectAshexDirectory.appendingPathComponent("memory", isDirectory: true) }
    public var projectMemoryFile: URL { projectMemoryDirectory.appendingPathComponent("project.md") }
    public var projectSkillsDirectory: URL { projectAshexDirectory.appendingPathComponent("skills", isDirectory: true) }
    public var projectTasksDirectory: URL { projectAshexDirectory.appendingPathComponent("tasks", isDirectory: true) }
    public var projectLogsDirectory: URL { projectAshexDirectory.appendingPathComponent("logs", isDirectory: true) }
    public var learningsDirectory: URL { workspaceRoot.appendingPathComponent(".learnings", isDirectory: true) }
    public var learningsFile: URL { learningsDirectory.appendingPathComponent("LEARNINGS.md") }
    public var errorsFile: URL { learningsDirectory.appendingPathComponent("ERRORS.md") }
    public var featureRequestsFile: URL { learningsDirectory.appendingPathComponent("FEATURE_REQUESTS.md") }
    public var correctionsFile: URL { learningsDirectory.appendingPathComponent("CORRECTIONS.md") }

    public var kbRootDirectory: URL { projectAshexDirectory.appendingPathComponent("kb", isDirectory: true) }
    public var kbRawDirectory: URL { kbRootDirectory.appendingPathComponent("raw", isDirectory: true) }
    public var kbWikiDirectory: URL { kbRootDirectory.appendingPathComponent("wiki", isDirectory: true) }
    public var kbWikiIndexFile: URL { kbWikiDirectory.appendingPathComponent("index.md") }
    public var kbWikiLogFile: URL { kbWikiDirectory.appendingPathComponent("log.md") }
    public var kbWikiAgentsFile: URL { kbWikiDirectory.appendingPathComponent("AGENTS.md") }
    public var kbWikiSourcesDirectory: URL { kbWikiDirectory.appendingPathComponent("sources", isDirectory: true) }
    public var kbWikiSummariesDirectory: URL { kbWikiDirectory.appendingPathComponent("summaries", isDirectory: true) }
    public var kbWikiConceptsDirectory: URL { kbWikiDirectory.appendingPathComponent("concepts", isDirectory: true) }
    public var kbWikiExplorationsDirectory: URL { kbWikiDirectory.appendingPathComponent("explorations", isDirectory: true) }
    public var kbWikiReportsDirectory: URL { kbWikiDirectory.appendingPathComponent("reports", isDirectory: true) }
    public var kbConfigFile: URL { kbRootDirectory.appendingPathComponent("config.yaml") }
    public var kbSessionsDirectory: URL { kbRootDirectory.appendingPathComponent("sessions", isDirectory: true) }

    public func displayPath(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        let storagePath = storageRoot.standardizedFileURL.path
        let workspacePath = workspaceRoot.standardizedFileURL.path
        if path == storagePath { return "." }
        if path.hasPrefix(storagePath + "/") {
            return String(path.dropFirst(storagePath.count + 1))
        }
        if path == workspacePath { return "<workspace>" }
        if path.hasPrefix(workspacePath + "/") {
            return String(path.dropFirst(workspacePath.count + 1))
        }
        return path
    }
}

public struct AgentHomeInitializationReport: Sendable, Equatable {
    public let createdPaths: [String]
}

public struct AgentContextFile: Sendable, Equatable {
    public let url: URL
    public let relativePath: String
    public let content: String
    public let truncated: Bool
}

public struct AgentContextWarning: Sendable, Equatable {
    public let relativePath: String
    public let findings: [String]
}

public struct AgentContextBundle: Sendable, Equatable {
    public let files: [AgentContextFile]
    public let warnings: [AgentContextWarning]
}

public struct AgentContextLoader: Sendable {
    public let home: AgentHome
    public let maxCharactersPerFile: Int

    public init(home: AgentHome, maxCharactersPerFile: Int = 12_000) {
        self.home = home
        self.maxCharactersPerFile = maxCharactersPerFile
    }

    public func loadContext(forOperationPath operationPath: URL? = nil) throws -> AgentContextBundle {
        var urls: [URL] = [
            home.paths.soulFile,
            home.paths.userMemoryFile,
            home.paths.agentMemoryFile,
            home.paths.projectAshexContextFile,
            home.paths.projectASHEXFile,
            home.paths.projectAgentsFile,
            home.workspaceRoot.appendingPathComponent("CLAUDE.md"),
            home.workspaceRoot.appendingPathComponent(".cursorrules"),
        ]

        let cursorRules = home.workspaceRoot.appendingPathComponent(".cursor/rules", isDirectory: true)
        if let contents = try? FileManager.default.contentsOfDirectory(at: cursorRules, includingPropertiesForKeys: nil) {
            urls.append(contentsOf: contents.filter { $0.pathExtension == "mdc" }.sorted { $0.path < $1.path })
        }

        if let operationPath {
            urls.append(contentsOf: nestedAgentsFiles(for: operationPath))
        }

        var seen: Set<String> = []
        var files: [AgentContextFile] = []
        var warnings: [AgentContextWarning] = []

        for url in urls {
            let normalized = url.standardizedFileURL.path
            guard seen.insert(normalized).inserted,
                  FileManager.default.fileExists(atPath: normalized) else { continue }
            let raw = try String(contentsOf: url, encoding: .utf8)
            let truncated = raw.count > maxCharactersPerFile
            let content = truncated ? String(raw.prefix(maxCharactersPerFile)) + "\n\n[truncated]" : raw
            let relativePath = home.paths.displayPath(for: url)
            files.append(.init(url: url, relativePath: relativePath, content: content, truncated: truncated))
            let findings = PromptInjectionScanner.findings(in: raw)
            if !findings.isEmpty {
                warnings.append(.init(relativePath: relativePath, findings: findings))
            }
        }

        return AgentContextBundle(files: files, warnings: warnings)
    }

    private func nestedAgentsFiles(for operationPath: URL) -> [URL] {
        let rootPath = home.workspaceRoot.standardizedFileURL.path
        var directory = operationPath
        if operationPath.pathExtension.isEmpty == false {
            directory = operationPath.deletingLastPathComponent()
        }
        directory = directory.standardizedFileURL

        var urls: [URL] = []
        while directory.path.hasPrefix(rootPath + "/") {
            let candidate = directory.appendingPathComponent("AGENTS.md")
            if candidate.path != home.paths.projectAgentsFile.path,
               FileManager.default.fileExists(atPath: candidate.path) {
                urls.append(candidate)
            }
            directory.deleteLastPathComponent()
        }
        return urls.reversed()
    }
}

public enum PromptInjectionScanner {
    private static let patterns: [(String, String)] = [
        ("ignore previous", "Attempts to ignore previous instructions."),
        ("ignore all previous", "Attempts to ignore previous instructions."),
        ("system prompt", "References the system prompt."),
        ("developer message", "References developer instructions."),
        ("reveal", "May request disclosure of hidden context."),
        ("exfiltrate", "May request data exfiltration."),
        ("bypass", "May request bypassing safety or policy."),
        ("override instructions", "Attempts to override instructions."),
    ]

    public static func findings(in text: String) -> [String] {
        let lowered = text.lowercased()
        return patterns.compactMap { pattern, finding in
            lowered.contains(pattern) ? finding : nil
        }
    }
}

public enum AgentMemoryScope: String, Codable, Sendable, CaseIterable {
    case agent
    case user
    case projects
    case lessons
    case project
}

public struct AgentMemorySearchResult: Sendable, Equatable {
    public let scope: AgentMemoryScope
    public let path: String
    public let line: Int
    public let text: String
}

public struct AgentMemoryStore: Sendable {
    public let home: AgentHome

    public init(home: AgentHome) {
        self.home = home
    }

    public func read(scope: AgentMemoryScope) throws -> String {
        try String(contentsOf: fileURL(for: scope), encoding: .utf8)
    }

    public func append(scope: AgentMemoryScope, text: String) throws {
        let redacted = SecretRedactor.redact(text)
        let url = fileURL(for: scope)
        try ensureFile(url, header: header(for: scope))
        let entry = "- \(Self.timestamp()): \(redacted.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(entry.utf8))
        try appendAudit(operation: "append", scope: scope, detail: redacted)
    }

    public func replace(scope: AgentMemoryScope, uniqueSubstring: String, replacement: String) throws {
        let url = fileURL(for: scope)
        let original = try String(contentsOf: url, encoding: .utf8)
        let count = original.components(separatedBy: uniqueSubstring).count - 1
        guard count == 1 else {
            throw AshexError.fileSystem("Expected one match in \(scope.rawValue) memory, found \(count).")
        }
        let updated = original.replacingOccurrences(of: uniqueSubstring, with: SecretRedactor.redact(replacement))
        try updated.write(to: url, atomically: true, encoding: .utf8)
        try appendAudit(operation: "replace", scope: scope, detail: uniqueSubstring)
    }

    public func remove(scope: AgentMemoryScope, uniqueSubstring: String) throws {
        let url = fileURL(for: scope)
        let original = try String(contentsOf: url, encoding: .utf8)
        let lines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let matching = lines.filter { $0.contains(uniqueSubstring) }
        guard matching.count == 1 else {
            throw AshexError.fileSystem("Expected one line match in \(scope.rawValue) memory, found \(matching.count).")
        }
        let updated = lines.filter { !$0.contains(uniqueSubstring) }.joined(separator: "\n")
        try (updated.hasSuffix("\n") ? updated : updated + "\n").write(to: url, atomically: true, encoding: .utf8)
        try appendAudit(operation: "remove", scope: scope, detail: uniqueSubstring)
    }

    public func search(_ query: String) throws -> [AgentMemorySearchResult] {
        let loweredQuery = query.lowercased()
        guard !loweredQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var results: [AgentMemorySearchResult] = []
        for scope in AgentMemoryScope.allCases {
            let url = fileURL(for: scope)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (index, line) in lines.enumerated() where line.lowercased().contains(loweredQuery) {
                results.append(.init(scope: scope, path: home.paths.displayPath(for: url), line: index + 1, text: line))
            }
        }
        return results
    }

    public func fileURL(for scope: AgentMemoryScope) -> URL {
        switch scope {
        case .agent: return home.paths.agentMemoryFile
        case .user: return home.paths.userMemoryFile
        case .projects: return home.paths.projectsMemoryFile
        case .lessons: return home.paths.lessonsMemoryFile
        case .project: return home.paths.projectMemoryFile
        }
    }

    private func header(for scope: AgentMemoryScope) -> String {
        switch scope {
        case .agent: return "# Agent Memory\n\n"
        case .user: return "# User Profile\n\n"
        case .projects: return "# Project Memory\n\n"
        case .lessons: return "# Lessons Learned\n\n"
        case .project: return "# Project Memory\n\n"
        }
    }

    private func ensureFile(_ url: URL, header: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try header.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func appendAudit(operation: String, scope: AgentMemoryScope, detail: String) throws {
        try appendJSONLine(to: home.paths.memoryAuditFile, object: [
            "timestamp": Self.timestamp(),
            "operation": operation,
            "scope": scope.rawValue,
            "detail": detail,
        ])
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

public enum SecretRedactor {
    private static let patterns = [
        #"(?i)(password|token|secret|api[_-]?key)\s*[:=]\s*[^\s]+"#,
        #"sk-[A-Za-z0-9_\-]{8,}"#,
    ]

    public static func redact(_ text: String) -> String {
        patterns.reduce(text) { partial, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return partial }
            let range = NSRange(partial.startIndex..<partial.endIndex, in: partial)
            return regex.stringByReplacingMatches(in: partial, range: range, withTemplate: "[REDACTED_SECRET]")
        }
    }
}

public enum AgentSkillState: String, Codable, Sendable, CaseIterable {
    case installed
    case quarantined
    case generated
}

public struct AgentSkillMetadata: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let version: String?
    public let tags: [String]
    public let contentHash: String
}

public struct AgentSkillRecord: Codable, Sendable, Equatable {
    public let name: String
    public let state: AgentSkillState
    public let metadata: AgentSkillMetadata
    public let path: String
}

public struct AgentSkillAudit: Sendable, Equatable {
    public let name: String
    public let findings: [String]
}

public struct AgentSkillValidation: Sendable, Equatable {
    public let name: String
    public let state: AgentSkillState
    public let path: String
    public let errors: [String]
    public let warnings: [String]

    public var isValid: Bool {
        errors.isEmpty
    }
}

public struct AgentSkillContent: Sendable, Equatable {
    public let record: AgentSkillRecord
    public let content: String
}

public struct AgentSkillStore: Sendable {
    public let home: AgentHome

    public init(home: AgentHome) {
        self.home = home
    }

    @discardableResult
    public func install(from sourceURL: URL) throws -> AgentSkillRecord {
        let skillFile = sourceURL.appendingPathComponent("SKILL.md")
        guard FileManager.default.fileExists(atPath: skillFile.path) else {
            throw AshexError.fileSystem("Skill source must contain SKILL.md: \(sourceURL.path)")
        }
        let content = try String(contentsOf: skillFile, encoding: .utf8)
        let metadata = parseMetadata(content: content, fallbackName: sourceURL.lastPathComponent)
        let destination = directory(for: .quarantined).appendingPathComponent(metadata.name, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        let record = AgentSkillRecord(name: metadata.name, state: .quarantined, metadata: metadata, path: destination.path)
        try writeMetadata(record, to: destination)
        return record
    }

    public func list(state: AgentSkillState? = nil) throws -> [AgentSkillRecord] {
        let states = state.map { [$0] } ?? AgentSkillState.allCases
        return try states.flatMap { state in
            let root = directory(for: state)
            let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            return try contents
                .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }
                .map { try record(at: $0, state: state) }
        }
        .sorted { $0.name < $1.name }
    }

    public func show(name: String) throws -> AgentSkillContent {
        let located = try locate(name: name)
        let content = try String(contentsOf: located.url.appendingPathComponent("SKILL.md"), encoding: .utf8)
        return .init(record: try record(at: located.url, state: located.state), content: content)
    }

    public func audit(name: String) throws -> AgentSkillAudit {
        let content = try show(name: name).content
        return .init(name: name, findings: PromptInjectionScanner.findings(in: content))
    }

    public func validate(name: String, availableCapabilities: Set<String> = []) throws -> AgentSkillValidation {
        let located = try locateDirectory(name: name)
        return try validate(directory: located.url, state: located.state, availableCapabilities: availableCapabilities)
    }

    public func validateAll(availableCapabilities: Set<String> = []) throws -> [AgentSkillValidation] {
        try AgentSkillState.allCases.flatMap { state in
            let root = directory(for: state)
            let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            return try contents
                .filter { url in
                    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
                .map { try validate(directory: $0, state: state, availableCapabilities: availableCapabilities) }
        }
        .sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.state.rawValue < $1.state.rawValue
        }
    }

    public func routeMetadata(includeInactive: Bool = false) throws -> [SkillRouteMetadata] {
        try list().compactMap { record in
            let located = try locate(name: record.name)
            let content = try String(contentsOf: located.url.appendingPathComponent("SKILL.md"), encoding: .utf8)
            let frontmatter = Self.frontmatter(in: content)
            let isEnabled = record.state == .installed && frontmatter.boolValue(for: "enabled", default: true)
            let isQuarantined = record.state == .quarantined || frontmatter.boolValue(for: "quarantined", default: false)
            guard includeInactive || (isEnabled && !isQuarantined) else { return nil }
            return SkillRouteMetadata(
                name: record.name,
                description: record.metadata.description,
                triggerPhrases: frontmatter.listValue(for: "trigger_phrases") + frontmatter.listValue(for: "triggers"),
                requiredTools: frontmatter.listValue(for: "required_tools"),
                capabilitiesRequired: frontmatter.listValue(for: "capabilities_required"),
                openDesignMode: frontmatter["od.mode"]?.nilIfBlank,
                openDesignInputs: frontmatter.listValue(for: "od.inputs"),
                isEnabled: isEnabled,
                isQuarantined: isQuarantined
            )
        }
        .sorted { $0.name < $1.name }
    }

    public func enable(name: String) throws {
        let source = directory(for: .quarantined).appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw AshexError.fileSystem("No quarantined skill named \(name)")
        }
        let destination = directory(for: .installed).appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: destination)
        let updated = try record(at: destination, state: .installed)
        try writeMetadata(updated, to: destination)
    }

    public func remove(name: String) throws {
        let located = try locate(name: name)
        try FileManager.default.removeItem(at: located.url)
    }

    public func directory(for state: AgentSkillState) -> URL {
        switch state {
        case .installed: return home.paths.skillsInstalledDirectory
        case .quarantined: return home.paths.skillsQuarantinedDirectory
        case .generated: return home.paths.skillsGeneratedDirectory
        }
    }

    private func locate(name: String) throws -> (state: AgentSkillState, url: URL) {
        for state in AgentSkillState.allCases {
            let url = directory(for: state).appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("SKILL.md").path) {
                return (state, url)
            }
        }
        throw AshexError.fileSystem("No skill named \(name)")
    }

    private func locateDirectory(name: String) throws -> (state: AgentSkillState, url: URL) {
        for state in AgentSkillState.allCases {
            let url = directory(for: state).appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return (state, url)
            }
        }
        throw AshexError.fileSystem("No skill directory named \(name)")
    }

    private func validate(directory: URL, state: AgentSkillState, availableCapabilities: Set<String>) throws -> AgentSkillValidation {
        let name = directory.lastPathComponent
        let skillFile = directory.appendingPathComponent("SKILL.md")
        var errors: [String] = []
        var warnings: [String] = []

        guard FileManager.default.fileExists(atPath: skillFile.path) else {
            return .init(name: name, state: state, path: directory.path, errors: ["Missing SKILL.md."], warnings: warnings)
        }

        let content = try String(contentsOf: skillFile, encoding: .utf8)
        let frontmatter = Self.frontmatter(in: content)
        if frontmatter.isEmpty {
            warnings.append("Missing YAML frontmatter.")
        }
        if let frontmatterName = frontmatter["name"]?.nilIfBlank, frontmatterName != name {
            errors.append("Frontmatter name '\(frontmatterName)' does not match folder name '\(name)'.")
        }
        if (frontmatter["description"]?.nilIfBlank ?? firstMarkdownHeading(in: content)) == nil {
            warnings.append("Missing description.")
        }
        let missingCapabilities = frontmatter.listValue(for: "capabilities_required")
            .filter { !availableCapabilities.map { $0.lowercased() }.contains($0.lowercased()) }
        if !availableCapabilities.isEmpty, !missingCapabilities.isEmpty {
            warnings.append("Missing required capabilities: \(missingCapabilities.joined(separator: ", "))")
        }
        errors.append(contentsOf: PromptInjectionScanner.findings(in: content))
        if state == .quarantined {
            warnings.append("Skill is quarantined and will not be routed until enabled.")
        }

        return .init(name: name, state: state, path: directory.path, errors: errors, warnings: warnings)
    }

    private func record(at url: URL, state: AgentSkillState) throws -> AgentSkillRecord {
        let content = try String(contentsOf: url.appendingPathComponent("SKILL.md"), encoding: .utf8)
        let metadata = parseMetadata(content: content, fallbackName: url.lastPathComponent)
        return .init(name: metadata.name, state: state, metadata: metadata, path: url.path)
    }

    private func writeMetadata(_ record: AgentSkillRecord, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record.metadata)
        try data.write(to: directory.appendingPathComponent("_meta.json"), options: .atomic)
    }

    private func parseMetadata(content: String, fallbackName: String) -> AgentSkillMetadata {
        let frontmatter = Self.frontmatter(in: content)
        let name = frontmatter["name"]?.nilIfBlank ?? fallbackName
        let description = frontmatter["description"]?.nilIfBlank ?? firstMarkdownHeading(in: content) ?? "Portable ASHEX skill"
        let tags = frontmatter["tags"]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        return .init(
            name: name,
            description: description,
            version: frontmatter["version"],
            tags: tags,
            contentHash: StableHash.fnv1a64Hex(content)
        )
    }

    private static func frontmatter(in content: String) -> [String: String] {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return [:] }
        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" { break }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            result[key] = value
        }
        return result
    }

    private func firstMarkdownHeading(in content: String) -> String? {
        content
            .split(separator: "\n")
            .map(String.init)
            .first { $0.hasPrefix("# ") }?
            .dropFirst(2)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }
}

public enum AgentMCPTransport: String, Codable, Sendable {
    case stdio
    case http
}

public struct AgentMCPServerConfig: Codable, Sendable, Equatable {
    public let name: String
    public let transport: AgentMCPTransport
    public let command: String?
    public let args: [String]
    public let url: String?
    public let enabled: Bool
    public let allowTools: [String]
    public let denyTools: [String]

    public init(
        name: String,
        transport: AgentMCPTransport,
        command: String?,
        args: [String] = [],
        url: String?,
        enabled: Bool = true,
        allowTools: [String] = [],
        denyTools: [String] = []
    ) {
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.url = url
        self.enabled = enabled
        self.allowTools = allowTools
        self.denyTools = denyTools
    }
}

public struct AgentMCPRegistry: Sendable {
    public let home: AgentHome

    public init(home: AgentHome) {
        self.home = home
    }

    public func list() throws -> [AgentMCPServerConfig] {
        guard FileManager.default.fileExists(atPath: home.paths.mcpServersFile.path) else { return [] }
        let data = try Data(contentsOf: home.paths.mcpServersFile)
        if data.isEmpty { return [] }
        return try JSONDecoder().decode([AgentMCPServerConfig].self, from: data)
            .sorted { $0.name < $1.name }
    }

    public func upsert(_ config: AgentMCPServerConfig) throws {
        var configs = try list().filter { $0.name != config.name }
        configs.append(config)
        try save(configs)
    }

    public func remove(name: String) throws {
        try save(try list().filter { $0.name != name })
    }

    public func discoveryConfig() throws -> AgentMCPConfig {
        let descriptors = try list().map { config -> AgentMCPServerDescriptor in
            let transport: AgentMCPServerTransport
            switch config.transport {
            case .stdio:
                guard let command = config.command?.nilIfBlank else {
                    throw AshexError.fileSystem("MCP stdio server '\(config.name)' is missing command.")
                }
                transport = .stdio(.init(command: command, arguments: config.args))
            case .http:
                guard let rawURL = config.url?.nilIfBlank,
                      let url = URL(string: rawURL) else {
                    throw AshexError.fileSystem("MCP HTTP server '\(config.name)' is missing a valid URL.")
                }
                transport = .http(.init(url: url))
            }
            return AgentMCPServerDescriptor(
                id: config.name,
                namespace: Self.namespace(for: config.name),
                transport: transport,
                filter: .init(allow: config.allowTools, deny: config.denyTools),
                enabled: config.enabled
            )
        }
        return AgentMCPConfig(servers: descriptors)
    }

    private func save(_ configs: [AgentMCPServerConfig]) throws {
        try FileManager.default.createDirectory(at: home.paths.mcpServersFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configs.sorted { $0.name < $1.name }).write(to: home.paths.mcpServersFile, options: .atomic)
    }

    private static func namespace(for name: String) -> String {
        var scalars: [Character] = []
        var previousWasSeparator = false
        for character in name.lowercased() {
            if character.isLetter || character.isNumber {
                scalars.append(character)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                scalars.append("_")
                previousWasSeparator = true
            }
        }
        let normalized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return normalized.isEmpty ? "mcp" : normalized
    }
}

public struct AgentKnowledgeBaseInitializationReport: Sendable, Equatable {
    public let createdPaths: [String]
}

public struct AgentKnowledgeBaseIngestReport: Sendable, Equatable {
    public let ingestedCount: Int
    public let sourcePages: [String]
}

public struct AgentKnowledgeBaseQueryResult: Sendable, Equatable {
    public let title: String
    public let path: String
    public let snippet: String
    public let score: Int
}

public struct AgentKnowledgeBaseLintReport: Sendable, Equatable {
    public let missingSourcePages: [String]
    public let orphanPages: [String]
}

public struct AgentKnowledgeBaseWatchReport: Sendable, Equatable {
    public let scannedCount: Int
    public let changedCount: Int
    public let ingestReport: AgentKnowledgeBaseIngestReport

    public init(scannedCount: Int, changedCount: Int, ingestReport: AgentKnowledgeBaseIngestReport) {
        self.scannedCount = scannedCount
        self.changedCount = changedCount
        self.ingestReport = ingestReport
    }
}

public struct AgentKnowledgeBase: Sendable {
    public let home: AgentHome

    public init(home: AgentHome) {
        self.home = home
    }

    @discardableResult
    public func initialize() throws -> AgentKnowledgeBaseInitializationReport {
        var created: [String] = []
        func createDirectory(_ url: URL) throws {
            guard !FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            created.append(home.paths.displayPath(for: url))
        }
        func writeIfMissing(_ url: URL, _ text: String) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !FileManager.default.fileExists(atPath: url.path) else { return }
            try text.write(to: url, atomically: true, encoding: .utf8)
            created.append(home.paths.displayPath(for: url))
        }

        try createDirectory(home.paths.kbRootDirectory)
        try createDirectory(home.paths.kbRawDirectory)
        try createDirectory(home.paths.kbWikiDirectory)
        try createDirectory(home.paths.kbWikiSourcesDirectory)
        try createDirectory(home.paths.kbWikiSummariesDirectory)
        try createDirectory(home.paths.kbWikiConceptsDirectory)
        try createDirectory(home.paths.kbWikiExplorationsDirectory)
        try createDirectory(home.paths.kbWikiReportsDirectory)
        try createDirectory(home.paths.kbSessionsDirectory)
        try writeIfMissing(home.paths.kbWikiIndexFile, "# ASHEX Knowledge Base\n\n")
        try writeIfMissing(home.paths.kbWikiLogFile, "# Knowledge Base Log\n\n")
        try writeIfMissing(home.paths.kbWikiAgentsFile, """
        # KB Maintenance Instructions

        Preserve source provenance, mark uncertain synthesis, and prefer wikilinks for cross-page references.
        """)
        try writeIfMissing(home.paths.kbConfigFile, """
        enabled: true
        root: .ashex/kb
        format: markdown-wiki
        use_wikilinks: true
        watch_enabled: false
        retrieval_mode: hybrid
        """)

        return .init(createdPaths: Array(Set(created)).sorted())
    }

    @discardableResult
    public func add(_ url: URL) throws -> AgentKnowledgeBaseIngestReport {
        try initialize()
        let urls = try ingestibleFiles(from: url)
        return try ingest(urls)
    }

    @discardableResult
    public func watch(_ url: URL) throws -> AgentKnowledgeBaseWatchReport {
        try initialize()
        let urls = try ingestibleFiles(from: url)
        let stateURL = home.paths.kbSessionsDirectory.appendingPathComponent("watch-state.json")
        let previousState = try readWatchState(from: stateURL)
        let currentState = Dictionary(uniqueKeysWithValues: try urls.map { url in
            (url.standardizedFileURL.path, try fileFingerprint(for: url))
        })
        let changedURLs = urls.filter { url in
            let path = url.standardizedFileURL.path
            return previousState[path] != currentState[path]
        }
        let ingestReport = try ingest(changedURLs)
        try writeWatchState(currentState, to: stateURL)
        return .init(scannedCount: urls.count, changedCount: changedURLs.count, ingestReport: ingestReport)
    }

    private func ingest(_ urls: [URL]) throws -> AgentKnowledgeBaseIngestReport {
        var pages: [String] = []
        for fileURL in urls {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let pageName = stablePageName(for: fileURL)
            let sourcePageURL = home.paths.kbWikiSourcesDirectory.appendingPathComponent(pageName)
            let summaryURL = home.paths.kbWikiSummariesDirectory.appendingPathComponent(pageName)
            let sourcePage = """
            # \(fileURL.deletingPathExtension().lastPathComponent)

            Source: \(fileURL.path)

            ```text
            \(content)
            ```
            """
            try sourcePage.write(to: sourcePageURL, atomically: true, encoding: .utf8)
            try summary(for: content, title: fileURL.lastPathComponent, sourcePage: pageName)
                .write(to: summaryURL, atomically: true, encoding: .utf8)
            pages.append(home.paths.displayPath(for: sourcePageURL))
        }
        if !pages.isEmpty {
            try updateIndex(with: pages)
            try appendLog("Ingested \(pages.count) source page(s): \(pages.joined(separator: ", "))")
        }
        return .init(ingestedCount: pages.count, sourcePages: pages)
    }

    public func query(_ query: String, limit: Int = 8) throws -> [AgentKnowledgeBaseQueryResult] {
        let terms = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !terms.isEmpty else { return [] }
        let pages = try markdownPages(under: home.paths.kbWikiDirectory)
        return try pages.compactMap { page -> AgentKnowledgeBaseQueryResult? in
            let content = try String(contentsOf: page, encoding: .utf8)
            let lowered = content.lowercased()
            let score = terms.reduce(0) { partial, term in partial + (lowered.contains(term) ? 1 : 0) }
            guard score > 0 else { return nil }
            return .init(
                title: page.deletingPathExtension().lastPathComponent,
                path: home.paths.displayPath(for: page),
                snippet: snippet(from: content, terms: terms),
                score: score
            )
        }
        .sorted {
            if $0.score == $1.score { return $0.path < $1.path }
            return $0.score > $1.score
        }
        .prefix(limit)
        .map { $0 }
    }

    public func lint() throws -> AgentKnowledgeBaseLintReport {
        let sourcePages = try markdownPages(under: home.paths.kbWikiSourcesDirectory)
        let missing = try sourcePages.compactMap { page -> String? in
            let content = try String(contentsOf: page, encoding: .utf8)
            guard let sourceLine = content.split(separator: "\n").map(String.init).first(where: { $0.hasPrefix("Source: ") }) else {
                return home.paths.displayPath(for: page)
            }
            let path = String(sourceLine.dropFirst("Source: ".count))
            return FileManager.default.fileExists(atPath: path) ? nil : home.paths.displayPath(for: page)
        }
        return .init(missingSourcePages: missing, orphanPages: [])
    }

    private func ingestibleFiles(from url: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw AshexError.fileSystem("KB input not found: \(url.path)")
        }
        if !isDirectory.boolValue {
            return isIngestible(url) ? [url] : []
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]) else {
            return []
        }
        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            if shouldSkipIngesting(fileURL) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  isIngestible(fileURL) else { continue }
            files.append(fileURL)
        }
        return files.sorted { $0.path < $1.path }
    }

    private func isIngestible(_ url: URL) -> Bool {
        let extensions = ["md", "markdown", "txt", "swift", "json", "yaml", "yml", "html", "csv"]
        return extensions.contains(url.pathExtension.lowercased())
    }

    private func shouldSkipIngesting(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path == home.paths.kbRootDirectory.standardizedFileURL.path ||
            path.hasPrefix(home.paths.kbRootDirectory.standardizedFileURL.path + "/") {
            return true
        }
        let ignoredDirectoryNames: Set<String> = [".ashex", ".git", ".build", ".learnings", "node_modules", "DerivedData"]
        return ignoredDirectoryNames.contains(url.lastPathComponent)
    }

    private func stablePageName(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        let ext = url.pathExtension.isEmpty ? "md" : "md"
        return "\(base).\(ext)"
    }

    private func summary(for content: String, title: String, sourcePage: String) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).prefix(12).map(String.init)
        return """
        # Summary: \(title)

        Source page: [[sources/\(sourcePage.dropLast(3))]]

        \(lines.joined(separator: "\n"))
        """
    }

    private func updateIndex(with pages: [String]) throws {
        let existing = (try? String(contentsOf: home.paths.kbWikiIndexFile, encoding: .utf8)) ?? "# ASHEX Knowledge Base\n\n"
        let additions = pages.map { "- [[\($0.replacingOccurrences(of: ".ashex/kb/wiki/", with: "").dropLast(3))]]" }.joined(separator: "\n")
        let updated = existing + (additions.isEmpty ? "" : "\n## Sources\n\(additions)\n")
        try updated.write(to: home.paths.kbWikiIndexFile, atomically: true, encoding: .utf8)
    }

    private func appendLog(_ message: String) throws {
        let entry = "- \(ISO8601DateFormatter().string(from: Date())): \(message)\n"
        let handle = try FileHandle(forWritingTo: home.paths.kbWikiLogFile)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(entry.utf8))
    }

    private struct WatchFileFingerprint: Codable, Sendable, Equatable {
        let modifiedAt: TimeInterval
        let size: Int64
    }

    private func fileFingerprint(for url: URL) throws -> WatchFileFingerprint {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return .init(
            modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
            size: Int64(values.fileSize ?? 0)
        )
    }

    private func readWatchState(from url: URL) throws -> [String: WatchFileFingerprint] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        return try JSONDecoder().decode([String: WatchFileFingerprint].self, from: data)
    }

    private func writeWatchState(_ state: [String: WatchFileFingerprint], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    private func markdownPages(under root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        return enumerator.compactMap { entry -> URL? in
            guard let url = entry as? URL,
                  url.pathExtension == "md",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { return nil }
            return url
        }
        .sorted { $0.path < $1.path }
    }

    private func snippet(from content: String, terms: [String]) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let line = lines.first(where: { line in
            let lowered = line.lowercased()
            return terms.contains(where: lowered.contains)
        }) {
            return line.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(content.prefix(240))
    }
}

public struct AgentKnowledgeTool: Tool {
    public let name = "agent_knowledge"
    public let description = "Manage ASHEX durable context, memory, skills, MCP server config, and compiled project knowledge"
    public let contract = ToolContract(
        name: "agent_knowledge",
        description: "Manage ASHEX durable context, memory, skills, MCP server config, and compiled project knowledge",
        kind: .embedded,
        category: "agent",
        operationArgumentKey: "operation",
        operations: [
            .init(name: "context_list", description: "List loaded context files and prompt-injection warnings", mutatesWorkspace: false, arguments: [.init(name: "operation_path", description: "Optional operation path for lazy AGENTS.md discovery", type: .string, required: false)]),
            .init(name: "soul_show", description: "Show SOUL.md", mutatesWorkspace: false),
            .init(name: "memory_add", description: "Append durable memory", mutatesWorkspace: true, approval: .init(risk: .low, summary: "Add durable memory", reasonTemplate: "{{scope}}"), arguments: memoryArguments(requiredText: true)),
            .init(name: "memory_read", description: "Read durable memory", mutatesWorkspace: false, arguments: [.init(name: "scope", description: "Memory scope", type: .string, required: true, enumValues: AgentMemoryScope.allCases.map(\.rawValue))]),
            .init(name: "memory_search", description: "Search durable memory", mutatesWorkspace: false, arguments: [.init(name: "query", description: "Search query", type: .string, required: true)]),
            .init(name: "memory_replace", description: "Replace a unique durable-memory substring", mutatesWorkspace: true, approval: .init(risk: .medium, summary: "Replace durable memory", reasonTemplate: "{{scope}}"), arguments: [.init(name: "scope", description: "Memory scope", type: .string, required: true, enumValues: AgentMemoryScope.allCases.map(\.rawValue)), .init(name: "unique_substring", description: "Unique text to replace", type: .string, required: true), .init(name: "replacement", description: "Replacement text", type: .string, required: true)]),
            .init(name: "memory_remove", description: "Remove a durable-memory line by unique substring", mutatesWorkspace: true, approval: .init(risk: .medium, summary: "Remove durable memory", reasonTemplate: "{{scope}}"), arguments: [.init(name: "scope", description: "Memory scope", type: .string, required: true, enumValues: AgentMemoryScope.allCases.map(\.rawValue)), .init(name: "unique_substring", description: "Unique text to remove", type: .string, required: true)]),
            .init(name: "skills_list", description: "List portable skills", mutatesWorkspace: false),
            .init(name: "skills_show", description: "Show a portable skill", mutatesWorkspace: false, arguments: [.init(name: "name", description: "Skill name", type: .string, required: true)]),
            .init(name: "skills_install", description: "Install a portable skill into quarantine", mutatesWorkspace: true, approval: .init(risk: .medium, summary: "Install skill", reasonTemplate: "{{source_path}}"), arguments: [.init(name: "source_path", description: "Local folder containing SKILL.md", type: .string, required: true)]),
            .init(name: "skills_audit", description: "Audit a portable skill", mutatesWorkspace: false, arguments: [.init(name: "name", description: "Skill name", type: .string, required: true)]),
            .init(name: "skills_validate", description: "Validate one portable skill or all portable skills", mutatesWorkspace: false, arguments: [.init(name: "name", description: "Optional skill name", type: .string, required: false), .init(name: "available_capabilities", description: "Available capability names", type: .array, required: false)]),
            .init(name: "skills_route", description: "Rank enabled disk skills for a task", mutatesWorkspace: false, arguments: [.init(name: "task", description: "Task description", type: .string, required: true), .init(name: "available_tools", description: "Available tool names", type: .array, required: false), .init(name: "available_capabilities", description: "Available capability names", type: .array, required: false)]),
            .init(name: "skills_enable", description: "Enable a quarantined skill", mutatesWorkspace: true, approval: .init(risk: .medium, summary: "Enable skill", reasonTemplate: "{{name}}"), arguments: [.init(name: "name", description: "Skill name", type: .string, required: true)]),
            .init(name: "mcp_list", description: "List configured MCP servers", mutatesWorkspace: false),
            .init(name: "mcp_discovery_config", description: "Return persisted MCP servers as runtime discovery descriptors", mutatesWorkspace: false),
            .init(name: "mcp_add", description: "Add or update an MCP server config", mutatesWorkspace: true, approval: .init(risk: .medium, summary: "Configure MCP server", reasonTemplate: "{{name}}"), arguments: [.init(name: "name", description: "Server name", type: .string, required: true), .init(name: "transport", description: "stdio or http", type: .string, required: true, enumValues: AgentMCPTransport.allCasesRawValues), .init(name: "command", description: "Command for stdio transport", type: .string, required: false), .init(name: "url", description: "URL for HTTP transport", type: .string, required: false)]),
            .init(name: "mcp_remove", description: "Remove an MCP server config", mutatesWorkspace: true, approval: .init(risk: .medium, summary: "Remove MCP server", reasonTemplate: "{{name}}"), arguments: [.init(name: "name", description: "Server name", type: .string, required: true)]),
            .init(name: "kb_init", description: "Initialize project knowledge base", mutatesWorkspace: true, arguments: []),
            .init(name: "kb_add", description: "Ingest a file or directory into the project knowledge base", mutatesWorkspace: true, approval: .init(risk: .low, summary: "Ingest KB source", reasonTemplate: "{{path}}"), arguments: [.init(name: "path", description: "File or directory path", type: .string, required: true)]),
            .init(name: "kb_query", description: "Query compiled project knowledge", mutatesWorkspace: false, arguments: [.init(name: "query", description: "Question or search query", type: .string, required: true)]),
            .init(name: "kb_lint", description: "Lint project knowledge base", mutatesWorkspace: false),
        ],
        tags: ["agent", "memory", "skills", "mcp", "kb"]
    )

    private let home: AgentHome

    public init(home: AgentHome) {
        self.home = home
    }

    public func execute(arguments: JSONObject, context: ToolContext) async throws -> ToolContent {
        try await context.cancellation.checkCancellation()
        try home.initialize()
        let operation = try requiredString("operation", in: arguments)
        switch operation {
        case "context_list":
            let operationPath = arguments["operation_path"]?.stringValue.map { URL(fileURLWithPath: $0, relativeTo: home.workspaceRoot) }
            let bundle = try AgentContextLoader(home: home).loadContext(forOperationPath: operationPath)
            return .structured(.object([
                "files": .array(bundle.files.map { .object(["path": .string($0.relativePath), "truncated": .bool($0.truncated)]) }),
                "warnings": .array(bundle.warnings.map { .object(["path": .string($0.relativePath), "findings": .array($0.findings.map(JSONValue.string))]) }),
            ]))
        case "soul_show":
            return .text(try String(contentsOf: home.paths.soulFile, encoding: .utf8))
        case "memory_add":
            try AgentMemoryStore(home: home).append(scope: try memoryScope(arguments), text: try requiredString("text", in: arguments))
            return .structured(.object(["status": .string("added")]))
        case "memory_read":
            return .text(try AgentMemoryStore(home: home).read(scope: try memoryScope(arguments)))
        case "memory_search":
            let results = try AgentMemoryStore(home: home).search(try requiredString("query", in: arguments))
            return .structured(.object(["results": .array(results.map(memoryResultJSON))]))
        case "memory_replace":
            try AgentMemoryStore(home: home).replace(scope: try memoryScope(arguments), uniqueSubstring: try requiredString("unique_substring", in: arguments), replacement: try requiredString("replacement", in: arguments))
            return .structured(.object(["status": .string("replaced")]))
        case "memory_remove":
            try AgentMemoryStore(home: home).remove(scope: try memoryScope(arguments), uniqueSubstring: try requiredString("unique_substring", in: arguments))
            return .structured(.object(["status": .string("removed")]))
        case "skills_list":
            let records = try AgentSkillStore(home: home).list()
            return .structured(.object(["skills": .array(records.map(skillRecordJSON))]))
        case "skills_show":
            return .text(try AgentSkillStore(home: home).show(name: try requiredString("name", in: arguments)).content)
        case "skills_install":
            let record = try AgentSkillStore(home: home).install(from: URL(fileURLWithPath: try requiredString("source_path", in: arguments), relativeTo: home.workspaceRoot))
            return .structured(skillRecordJSON(record))
        case "skills_audit":
            let audit = try AgentSkillStore(home: home).audit(name: try requiredString("name", in: arguments))
            return .structured(.object(["name": .string(audit.name), "findings": .array(audit.findings.map(JSONValue.string))]))
        case "skills_validate":
            let store = AgentSkillStore(home: home)
            let capabilities = Set(arguments["available_capabilities"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            let validations: [AgentSkillValidation]
            if let name = arguments["name"]?.stringValue?.nilIfBlank {
                validations = try [store.validate(name: name, availableCapabilities: capabilities)]
            } else {
                validations = try store.validateAll(availableCapabilities: capabilities)
            }
            return .structured(.object(["validations": .array(validations.map(skillValidationJSON))]))
        case "skills_route":
            let store = AgentSkillStore(home: home)
            let tools = arguments["available_tools"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let capabilities = arguments["available_capabilities"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let router = SkillRouter(availableTools: tools, availableCapabilities: capabilities)
            let scores = router.rank(task: try requiredString("task", in: arguments), skills: try store.routeMetadata())
            return .structured(.object(["routes": .array(scores.map(skillRouteScoreJSON))]))
        case "skills_enable":
            try AgentSkillStore(home: home).enable(name: try requiredString("name", in: arguments))
            return .structured(.object(["status": .string("enabled")]))
        case "mcp_list":
            return .structured(.object(["servers": .array(try AgentMCPRegistry(home: home).list().map(mcpServerJSON))]))
        case "mcp_discovery_config":
            return .structured(.object(["servers": .array(try AgentMCPRegistry(home: home).discoveryConfig().servers.map(mcpDiscoveryServerJSON))]))
        case "mcp_add":
            let transport = try mcpTransport(arguments)
            try AgentMCPRegistry(home: home).upsert(.init(
                name: try requiredString("name", in: arguments),
                transport: transport,
                command: arguments["command"]?.stringValue,
                args: arguments["args"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                url: arguments["url"]?.stringValue,
                enabled: arguments["enabled"]?.boolValue ?? true,
                allowTools: arguments["allow_tools"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                denyTools: arguments["deny_tools"]?.arrayValue?.compactMap(\.stringValue) ?? []
            ))
            return .structured(.object(["status": .string("saved")]))
        case "mcp_remove":
            try AgentMCPRegistry(home: home).remove(name: try requiredString("name", in: arguments))
            return .structured(.object(["status": .string("removed")]))
        case "kb_init":
            let report = try AgentKnowledgeBase(home: home).initialize()
            return .structured(.object(["created_paths": .array(report.createdPaths.map(JSONValue.string))]))
        case "kb_add":
            let report = try AgentKnowledgeBase(home: home).add(URL(fileURLWithPath: try requiredString("path", in: arguments), relativeTo: home.workspaceRoot))
            return .structured(.object(["ingested_count": .number(Double(report.ingestedCount)), "source_pages": .array(report.sourcePages.map(JSONValue.string))]))
        case "kb_query":
            let results = try AgentKnowledgeBase(home: home).query(try requiredString("query", in: arguments))
            return .structured(.object(["results": .array(results.map(kbResultJSON))]))
        case "kb_lint":
            let report = try AgentKnowledgeBase(home: home).lint()
            return .structured(.object(["missing_source_pages": .array(report.missingSourcePages.map(JSONValue.string)), "orphan_pages": .array(report.orphanPages.map(JSONValue.string))]))
        default:
            throw AshexError.invalidToolArguments("Unknown agent_knowledge operation: \(operation)")
        }
    }

    private static func memoryArguments(requiredText: Bool) -> [ToolArgumentContract] {
        [
            .init(name: "scope", description: "Memory scope", type: .string, required: true, enumValues: AgentMemoryScope.allCases.map(\.rawValue)),
            .init(name: "text", description: "Memory text", type: .string, required: requiredText),
        ]
    }
}

private extension AgentMCPTransport {
    static var allCasesRawValues: [String] { ["stdio", "http"] }
}

private func requiredString(_ key: String, in arguments: JSONObject) throws -> String {
    guard let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else {
        throw AshexError.invalidToolArguments("\(key) is required")
    }
    return value
}

private func memoryScope(_ arguments: JSONObject) throws -> AgentMemoryScope {
    guard let raw = arguments["scope"]?.stringValue else {
        throw AshexError.invalidToolArguments("scope must be one of: memory, \(AgentMemoryScope.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    let normalized = raw == "memory" ? AgentMemoryScope.agent.rawValue : raw
    guard let scope = AgentMemoryScope(rawValue: normalized) else {
        throw AshexError.invalidToolArguments("scope must be one of: \(AgentMemoryScope.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    return scope
}

private func mcpTransport(_ arguments: JSONObject) throws -> AgentMCPTransport {
    guard let raw = arguments["transport"]?.stringValue,
          let transport = AgentMCPTransport(rawValue: raw) else {
        throw AshexError.invalidToolArguments("transport must be stdio or http")
    }
    return transport
}

private func memoryResultJSON(_ result: AgentMemorySearchResult) -> JSONValue {
    .object([
        "scope": .string(result.scope.rawValue),
        "path": .string(result.path),
        "line": .number(Double(result.line)),
        "text": .string(result.text),
    ])
}

private func skillRecordJSON(_ record: AgentSkillRecord) -> JSONValue {
    .object([
        "name": .string(record.name),
        "state": .string(record.state.rawValue),
        "description": .string(record.metadata.description),
        "version": record.metadata.version.map(JSONValue.string) ?? .null,
        "tags": .array(record.metadata.tags.map(JSONValue.string)),
        "path": .string(record.path),
    ])
}

private func skillValidationJSON(_ validation: AgentSkillValidation) -> JSONValue {
    .object([
        "name": .string(validation.name),
        "state": .string(validation.state.rawValue),
        "path": .string(validation.path),
        "valid": .bool(validation.isValid),
        "errors": .array(validation.errors.map(JSONValue.string)),
        "warnings": .array(validation.warnings.map(JSONValue.string)),
    ])
}

private func skillRouteScoreJSON(_ score: SkillRouteScore) -> JSONValue {
    .object([
        "name": .string(score.metadata.name),
        "description": .string(score.metadata.description),
        "score": .number(score.score),
        "trigger_phrases": .array(score.metadata.triggerPhrases.map(JSONValue.string)),
        "required_tools": .array(score.metadata.requiredTools.map(JSONValue.string)),
        "capabilities_required": .array(score.metadata.capabilitiesRequired.map(JSONValue.string)),
        "od_mode": score.metadata.openDesignMode.map(JSONValue.string) ?? .null,
        "od_inputs": .array(score.metadata.openDesignInputs.map(JSONValue.string)),
        "reasons": .array(score.reasons.map(JSONValue.string)),
    ])
}

private func mcpServerJSON(_ server: AgentMCPServerConfig) -> JSONValue {
    .object([
        "name": .string(server.name),
        "transport": .string(server.transport.rawValue),
        "command": server.command.map(JSONValue.string) ?? .null,
        "args": .array(server.args.map(JSONValue.string)),
        "url": server.url.map(JSONValue.string) ?? .null,
        "enabled": .bool(server.enabled),
        "allow_tools": .array(server.allowTools.map(JSONValue.string)),
        "deny_tools": .array(server.denyTools.map(JSONValue.string)),
    ])
}

private func mcpDiscoveryServerJSON(_ server: AgentMCPServerDescriptor) -> JSONValue {
    let transport: JSONValue
    switch server.transport {
    case .stdio(let stdio):
        transport = .object([
            "kind": .string("stdio"),
            "command": .string(stdio.command),
            "args": .array(stdio.arguments.map(JSONValue.string)),
        ])
    case .http(let http):
        transport = .object([
            "kind": .string("http"),
            "url": .string(http.url.absoluteString),
        ])
    }
    return .object([
        "id": .string(server.id),
        "namespace": .string(server.namespace),
        "enabled": .bool(server.enabled),
        "transport": transport,
        "allow_tools": .array(server.filter.allow.map(JSONValue.string)),
        "deny_tools": .array(server.filter.deny.map(JSONValue.string)),
    ])
}

private func kbResultJSON(_ result: AgentKnowledgeBaseQueryResult) -> JSONValue {
    .object([
        "title": .string(result.title),
        "path": .string(result.path),
        "snippet": .string(result.snippet),
        "score": .number(Double(result.score)),
    ])
}

private func appendJSONLine(to url: URL, object: [String: String]) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: url.path) {
        try Data().write(to: url)
    }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.write(contentsOf: Data("\n".utf8))
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension [String: String] {
    func listValue(for key: String) -> [String] {
        self[key]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
    }

    func boolValue(for key: String, default defaultValue: Bool) -> Bool {
        guard let raw = self[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return defaultValue
        }
        return ["true", "yes", "1", "enabled"].contains(raw)
    }
}
