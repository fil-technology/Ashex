import Foundation

public struct RecentWorkspaceRecord: Codable, Sendable, Equatable {
    public let path: String
    public let lastUsedAt: Date

    public init(path: String, lastUsedAt: Date) {
        self.path = path
        self.lastUsedAt = lastUsedAt
    }
}

public enum RecentWorkspaceStore {
    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Ashex", isDirectory: true)
            .appendingPathComponent("recent-workspaces.json")
    }

    public static func load(from fileURL: URL = defaultFileURL()) throws -> [RecentWorkspaceRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        do {
            return try JSONDecoder().decode([RecentWorkspaceRecord].self, from: data)
        } catch {
            throw AshexError.persistence("Failed to decode recent workspaces: \(error.localizedDescription)")
        }
    }

    public static func record(workspaceURL: URL, now: Date = Date(), at fileURL: URL = defaultFileURL()) throws {
        let path = workspaceURL.standardizedFileURL.path
        var records = try load(from: fileURL)
        records.removeAll { $0.path == path }
        records.insert(.init(path: path, lastUsedAt: now), at: 0)
        records = Array(records.prefix(20))
        try write(records, to: fileURL)
    }

    public static func write(_ records: [RecentWorkspaceRecord], to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
