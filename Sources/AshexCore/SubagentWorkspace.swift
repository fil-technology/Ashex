import Foundation

public enum SubagentWorkspaceMode: String, Codable, Sendable, Equatable, CaseIterable {
    case sharedReadOnly = "shared_read_only"
    case copiedWritable = "copied_writable"
}

public struct SubagentWorkspaceLease: Codable, Sendable, Equatable {
    public let id: String
    public let runID: UUID
    public let title: String
    public let mode: SubagentWorkspaceMode
    public let sourceWorkspacePath: String
    public let workspacePath: String
    public let createdAt: Date

    public init(
        id: String,
        runID: UUID,
        title: String,
        mode: SubagentWorkspaceMode,
        sourceWorkspacePath: String,
        workspacePath: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.runID = runID
        self.title = title
        self.mode = mode
        self.sourceWorkspacePath = sourceWorkspacePath
        self.workspacePath = workspacePath
        self.createdAt = createdAt
    }
}

public struct SubagentWorkspaceManager: @unchecked Sendable {
    public let storageRoot: URL
    public let workspaceRoot: URL

    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    public init(
        storageRoot: URL,
        workspaceRoot: URL,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storageRoot = storageRoot
        self.workspaceRoot = workspaceRoot.standardizedFileURL
        self.fileManager = fileManager
        self.now = now
    }

    @discardableResult
    public func createLease(
        runID: UUID,
        title: String,
        mode: SubagentWorkspaceMode = .sharedReadOnly
    ) throws -> SubagentWorkspaceLease {
        let id = stableLeaseID(runID: runID, title: title)
        let directory = leaseDirectory(runID: runID, id: id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let workspaceURL: URL
        switch mode {
        case .sharedReadOnly:
            workspaceURL = workspaceRoot
        case .copiedWritable:
            workspaceURL = directory.appendingPathComponent("workspace", isDirectory: true)
            try copyWorkspace(to: workspaceURL)
        }

        let lease = SubagentWorkspaceLease(
            id: id,
            runID: runID,
            title: title,
            mode: mode,
            sourceWorkspacePath: workspaceRoot.path,
            workspacePath: workspaceURL.standardizedFileURL.path,
            createdAt: now()
        )
        try write(lease, to: directory.appendingPathComponent("lease.json"))
        return lease
    }

    public func listLeases() throws -> [SubagentWorkspaceLease] {
        guard fileManager.fileExists(atPath: rootDirectory.path),
              let runDirectories = try? fileManager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil) else {
            return []
        }

        var leases: [SubagentWorkspaceLease] = []
        for runDirectory in runDirectories where runDirectory.hasDirectoryPath {
            let leaseDirectories = (try? fileManager.contentsOfDirectory(at: runDirectory, includingPropertiesForKeys: nil)) ?? []
            for directory in leaseDirectories where directory.hasDirectoryPath {
                let url = directory.appendingPathComponent("lease.json")
                guard fileManager.fileExists(atPath: url.path) else { continue }
                leases.append(try readLease(at: url))
            }
        }
        return leases.sorted {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return $0.createdAt < $1.createdAt
        }
    }

    public func removeLease(id: String) throws {
        for lease in try listLeases() where lease.id == id {
            let directory = leaseDirectory(runID: lease.runID, id: lease.id)
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
        }
    }

    private var rootDirectory: URL {
        storageRoot.appendingPathComponent("subagents", isDirectory: true)
    }

    private func leaseDirectory(runID: UUID, id: String) -> URL {
        rootDirectory
            .appendingPathComponent(runID.uuidString, isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    private func stableLeaseID(runID: UUID, title: String) -> String {
        let slug = title.lowercased()
            .map { character in
                character.isLetter || character.isNumber ? String(character) : "-"
            }
            .joined()
            .split(separator: "-")
            .prefix(5)
            .joined(separator: "-")
        let suffix = String(runID.uuidString.prefix(8)).lowercased()
        return "\(slug.isEmpty ? "subagent" : slug)-\(suffix)"
    }

    private func copyWorkspace(to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        guard let enumerator = fileManager.enumerator(
            at: workspaceRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let sourceURL as URL in enumerator {
            if shouldSkip(sourceURL) {
                enumerator.skipDescendants()
                continue
            }
            let sourcePath = sourceURL.standardizedFileURL.path
            let relativePath = String(sourcePath.dropFirst(workspaceRoot.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relativePath.isEmpty else { continue }
            let targetURL = destination.appendingPathComponent(relativePath)
            let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
            } else if values.isRegularFile == true {
                try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: sourceURL, to: targetURL)
            }
        }
    }

    private func shouldSkip(_ url: URL) -> Bool {
        let skippedNames: Set<String> = [
            ".ashex", ".build", ".git", ".swiftpm", "DerivedData", "node_modules"
        ]
        return skippedNames.contains(url.lastPathComponent)
    }

    private func write(_ lease: SubagentWorkspaceLease, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(lease).write(to: url, options: .atomic)
    }

    private func readLease(at url: URL) throws -> SubagentWorkspaceLease {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SubagentWorkspaceLease.self, from: Data(contentsOf: url))
    }
}
