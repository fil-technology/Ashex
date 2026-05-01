import Foundation

public enum ProjectLearningKind: String, Codable, CaseIterable, Sendable {
    case learning
    case error
    case featureRequest
    case correction

    var fileName: String {
        switch self {
        case .learning: "LEARNINGS.md"
        case .error: "ERRORS.md"
        case .featureRequest: "FEATURE_REQUESTS.md"
        case .correction: "CORRECTIONS.md"
        }
    }

    var title: String {
        switch self {
        case .learning: "Learnings"
        case .error: "Errors"
        case .featureRequest: "Feature Requests"
        case .correction: "Corrections"
        }
    }
}

public struct ProjectLearningEntry: Codable, Equatable, Sendable {
    public let id: String
    public let kind: ProjectLearningKind
    public let summary: String
    public let details: String
    public let tags: [String]
    public let source: String?
    public let createdAt: Date

    public init(
        id: String,
        kind: ProjectLearningKind,
        summary: String,
        details: String,
        tags: [String] = [],
        source: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.details = details
        self.tags = tags
        self.source = source
        self.createdAt = createdAt
    }
}

public struct ProjectLearningStore: Sendable {
    public let workspaceRoot: URL
    public let learningsDirectory: URL

    public init(workspaceRoot: URL) {
        self.workspaceRoot = workspaceRoot.standardizedFileURL
        self.learningsDirectory = self.workspaceRoot.appendingPathComponent(".learnings", isDirectory: true)
    }

    public func initialize() throws {
        try FileManager.default.createDirectory(at: learningsDirectory, withIntermediateDirectories: true)
        for kind in ProjectLearningKind.allCases {
            let url = fileURL(for: kind)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try "# \(kind.title)\n\n".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public func append(_ entry: ProjectLearningEntry) throws {
        try initialize()
        let url = fileURL(for: entry.kind)
        var markdown = try String(contentsOf: url, encoding: .utf8)
        if !markdown.hasSuffix("\n") {
            markdown += "\n"
        }
        markdown += try render(entry)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    public func list(kind: ProjectLearningKind? = nil) throws -> [ProjectLearningEntry] {
        try initialize()
        let kinds = kind.map { [$0] } ?? ProjectLearningKind.allCases
        return try kinds.flatMap { try entries(in: fileURL(for: $0)) }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.id < rhs.id
            }
    }

    private func fileURL(for kind: ProjectLearningKind) -> URL {
        learningsDirectory.appendingPathComponent(kind.fileName)
    }

    private func render(_ entry: ProjectLearningEntry) throws -> String {
        let json = try LearningJSON.encoder.encode(entry)
        let encoded = String(decoding: json, as: UTF8.self)
        var lines = [
            "<!-- ashex-learning-entry",
            encoded,
            "-->",
            "## \(LearningJSON.iso8601.string(from: entry.createdAt)) - \(entry.summary)",
            "",
        ]
        if !entry.tags.isEmpty {
            lines.append("Tags: \(entry.tags.joined(separator: ", "))")
            lines.append("")
        }
        if let source = entry.source, !source.isEmpty {
            lines.append("Source: \(source)")
            lines.append("")
        }
        lines.append(entry.details)
        lines.append("")
        return lines.joined(separator: "\n") + "\n"
    }

    private func entries(in url: URL) throws -> [ProjectLearningEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let markdown = try String(contentsOf: url, encoding: .utf8)
        return try LearningJSON.decodeBlocks(
            in: markdown,
            startMarker: "<!-- ashex-learning-entry",
            endMarker: "-->",
            as: ProjectLearningEntry.self
        )
    }
}

enum LearningJSON {
    static var iso8601: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func decodeBlocks<T: Decodable>(
        in text: String,
        startMarker: String,
        endMarker: String,
        as _: T.Type
    ) throws -> [T] {
        var values: [T] = []
        var remainder = text[...]
        while let start = remainder.range(of: startMarker) {
            let afterStart = remainder[start.upperBound...]
            guard let end = afterStart.range(of: endMarker) else { break }
            let json = afterStart[..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = json.data(using: .utf8) {
                values.append(try decoder.decode(T.self, from: data))
            }
            remainder = afterStart[end.upperBound...]
        }
        return values
    }
}
