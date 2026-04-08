import Foundation

public struct WorkspaceSnapshot: Sendable, Equatable {
    public let rootURL: URL
    public let topLevelEntries: [String]
    public let instructionFiles: [String]
    public let gitBranch: String?
    public let gitStatusSummary: String?

    public init(
        rootURL: URL,
        topLevelEntries: [String],
        instructionFiles: [String],
        gitBranch: String?,
        gitStatusSummary: String?
    ) {
        self.rootURL = rootURL
        self.topLevelEntries = topLevelEntries
        self.instructionFiles = instructionFiles
        self.gitBranch = gitBranch
        self.gitStatusSummary = gitStatusSummary
    }
}

public enum WorkspaceSnapshotBuilder {
    public static func capture(
        workspaceRoot: URL,
        fileManager: FileManager = .default,
        processInfo: ProcessInfo = .processInfo
    ) -> WorkspaceSnapshot {
        let topLevelEntries: [String] = (try? fileManager.contentsOfDirectory(
            at: workspaceRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(12)
            .map { url in
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return url.lastPathComponent + (isDirectory ? "/" : "")
            } ?? []

        let instructionCandidates = ["README.md", "AGENTS.md", "CLAUDE.md", "CONTRIBUTING.md", "IMPLEMENTATION_PHASES.md"]
        let instructionFiles = instructionCandidates.filter { candidate in
            fileManager.fileExists(atPath: workspaceRoot.appendingPathComponent(candidate).path)
        }

        let gitBranch = runGit(["rev-parse", "--abbrev-ref", "HEAD"], workspaceRoot: workspaceRoot, processInfo: processInfo)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        let gitStatusSummary = runGit(["status", "--short", "--branch"], workspaceRoot: workspaceRoot, processInfo: processInfo)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        return WorkspaceSnapshot(
            rootURL: workspaceRoot,
            topLevelEntries: topLevelEntries,
            instructionFiles: instructionFiles,
            gitBranch: gitBranch,
            gitStatusSummary: gitStatusSummary
        )
    }

    private static func runGit(_ arguments: [String], workspaceRoot: URL, processInfo: ProcessInfo) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = workspaceRoot
        process.environment = processInfo.environment

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
