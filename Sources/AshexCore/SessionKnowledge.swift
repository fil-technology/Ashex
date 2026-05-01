import Foundation

public enum SessionTranscriptEntryKind: String, Codable, Sendable, Equatable {
    case message
    case toolCall
}

public struct SessionTranscriptEntry: Codable, Sendable {
    public let kind: SessionTranscriptEntryKind
    public let threadID: UUID
    public let runID: UUID?
    public let createdAt: Date
    public let message: MessageRecord?
    public let toolCall: ToolCallRecord?

    public init(kind: SessionTranscriptEntryKind, threadID: UUID, runID: UUID?, createdAt: Date, message: MessageRecord?, toolCall: ToolCallRecord?) {
        self.kind = kind
        self.threadID = threadID
        self.runID = runID
        self.createdAt = createdAt
        self.message = message
        self.toolCall = toolCall
    }

    public static func message(_ record: MessageRecord) -> SessionTranscriptEntry {
        SessionTranscriptEntry(
            kind: .message,
            threadID: record.threadID,
            runID: record.runID,
            createdAt: record.createdAt,
            message: record,
            toolCall: nil
        )
    }

    public static func toolCall(_ record: ToolCallRecord, threadID: UUID) -> SessionTranscriptEntry {
        SessionTranscriptEntry(
            kind: .toolCall,
            threadID: threadID,
            runID: record.runID,
            createdAt: record.startedAt,
            message: nil,
            toolCall: record
        )
    }

    public var searchableText: String {
        switch kind {
        case .message:
            return message?.content ?? ""
        case .toolCall:
            let call = toolCall
            return [
                call?.toolName,
                call.map { JSONValue.object($0.arguments).prettyPrinted },
                call?.output,
            ]
            .compactMap { $0 }
            .joined(separator: " ")
        }
    }
}

public struct SessionTranscriptSearchRequest: Sendable, Equatable {
    public let query: String
    public let limit: Int
    public let threadID: UUID?
    public let runID: UUID?

    public init(query: String, limit: Int = 20, threadID: UUID? = nil, runID: UUID? = nil) {
        self.query = query
        self.limit = limit
        self.threadID = threadID
        self.runID = runID
    }
}

public struct SessionTranscriptSearchResult: Codable, Sendable {
    public let entry: SessionTranscriptEntry
    public let snippet: String

    public init(entry: SessionTranscriptEntry, snippet: String) {
        self.entry = entry
        self.snippet = snippet
    }
}

public final class SessionTranscriptStore: @unchecked Sendable {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "ashex.session.transcripts")

    public init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    public func append(_ entry: SessionTranscriptEntry) throws {
        try queue.sync {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let line = try Self.encoder.encode(entry)
            let fileURL = transcriptURL(threadID: entry.threadID)
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.write(contentsOf: Data([0x0A]))
        }
    }

    public func read(threadID: UUID) throws -> [SessionTranscriptEntry] {
        try queue.sync {
            let fileURL = transcriptURL(threadID: threadID)
            guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
            return try readEntries(fileURL: fileURL)
        }
    }

    public func readAll() throws -> [SessionTranscriptEntry] {
        try queue.sync {
            guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
            let files = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            )
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

            return try files.flatMap { try readEntries(fileURL: $0) }
                .sorted { lhs, rhs in
                    if lhs.createdAt == rhs.createdAt {
                        return lhs.threadID.uuidString < rhs.threadID.uuidString
                    }
                    return lhs.createdAt < rhs.createdAt
                }
        }
    }

    public func search(_ request: SessionTranscriptSearchRequest) throws -> [SessionTranscriptSearchResult] {
        try queue.sync {
            let terms = Self.normalizedTerms(in: request.query)
            guard request.limit > 0, !terms.isEmpty else { return [] }
            let source: [SessionTranscriptEntry]
            if let threadID = request.threadID {
                source = try readEntriesIfPresent(threadID: threadID)
            } else {
                source = try readAllUnlocked()
            }

            return source
                .filter { entry in
                    if let runID = request.runID, entry.runID != runID {
                        return false
                    }
                    let haystack = entry.searchableText.lowercased()
                    return terms.allSatisfy { haystack.contains($0) }
                }
                .sorted { $0.createdAt < $1.createdAt }
                .prefix(request.limit)
                .map {
                    SessionTranscriptSearchResult(
                        entry: $0,
                        snippet: Self.snippet(from: $0.searchableText, terms: terms, limit: 240)
                    )
                }
        }
    }

    public func transcriptURL(threadID: UUID) -> URL {
        directoryURL.appendingPathComponent("\(threadID.uuidString).jsonl")
    }

    private func readEntriesIfPresent(threadID: UUID) throws -> [SessionTranscriptEntry] {
        let fileURL = transcriptURL(threadID: threadID)
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        return try readEntries(fileURL: fileURL)
    }

    private func readAllUnlocked() throws -> [SessionTranscriptEntry] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        let files = try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.flatMap { try readEntries(fileURL: $0) }
    }

    private func readEntries(fileURL: URL) throws -> [SessionTranscriptEntry] {
        let data = try Data(contentsOf: fileURL)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AshexError.persistence("Transcript is not valid UTF-8: \(fileURL.path)")
        }
        return try text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            guard let lineData = String(line).data(using: .utf8) else {
                throw AshexError.persistence("Transcript line is not valid UTF-8: \(fileURL.path)")
            }
            return try Self.decoder.decode(SessionTranscriptEntry.self, from: lineData)
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    private static func normalizedTerms(in query: String) -> [String] {
        query.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func snippet(from content: String, terms: [String], limit: Int) -> String {
        let collapsed = content.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let lowercased = collapsed.lowercased()
        let firstMatch = terms.compactMap { lowercased.range(of: $0)?.lowerBound }.min()
        let start = firstMatch.map { lowercased.distance(from: lowercased.startIndex, to: $0) } ?? 0
        let offset = max(0, start - 40)
        let startIndex = collapsed.index(collapsed.startIndex, offsetBy: offset)
        let endIndex = collapsed.index(startIndex, offsetBy: min(limit, collapsed.distance(from: startIndex, to: collapsed.endIndex)))
        return String(collapsed[startIndex..<endIndex])
    }
}

public struct SessionSummary: Codable, Sendable, Equatable {
    public let title: String
    public let bullets: [String]

    public init(title: String, bullets: [String]) {
        self.title = title
        self.bullets = bullets
    }
}

public enum SessionSummarizer {
    public static func summarize(messages: [MessageRecord], toolCalls: [ToolCallRecord], maxBulletCount: Int = 6) -> SessionSummary {
        let title = messages.first(where: { $0.role == .user })?.content ?? messages.first?.content ?? "Session"
        let compactTitle = compact(title, limit: 96)

        let messageItems = messages.map {
            item(
                date: $0.createdAt,
                priority: messagePriority(role: $0.role, content: $0.content),
                text: "\($0.role.summaryLabel): \(compact($0.content, limit: 180))"
            )
        }
        let toolItems = toolCalls.map { call in
            let output = call.output.map { compact($0, limit: 140) } ?? call.status
            return item(date: call.startedAt, priority: 2, text: "Tool \(call.toolName) \(call.status): \(output)")
        }

        let bullets = (messageItems + toolItems)
            .sorted { lhs, rhs in
                if lhs.priority == rhs.priority {
                    return lhs.date < rhs.date
                }
                return lhs.priority < rhs.priority
            }
            .map(\.text)
            .prefix(max(0, maxBulletCount))

        return SessionSummary(title: compactTitle, bullets: Array(bullets))
    }

    public static func summarize(entries: [SessionTranscriptEntry], maxBulletCount: Int = 6) -> SessionSummary {
        summarize(
            messages: entries.compactMap(\.message),
            toolCalls: entries.compactMap(\.toolCall),
            maxBulletCount: maxBulletCount
        )
    }

    private static func item(date: Date, priority: Int, text: String) -> (date: Date, priority: Int, text: String) {
        (date, priority, text)
    }

    private static func messagePriority(role: MessageRole, content: String) -> Int {
        switch role {
        case .user:
            return 0
        case .assistant:
            let normalized = content.lowercased()
            if normalized.contains("validation") || normalized.contains("test") || normalized.contains("passes") {
                return 3
            }
            return 1
        case .tool:
            return 2
        case .system:
            return 4
        }
    }

    private static func compact(_ text: String, limit: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let index = collapsed.index(collapsed.startIndex, offsetBy: limit)
        return String(collapsed[..<index])
    }
}

private extension MessageRole {
    var summaryLabel: String {
        switch self {
        case .user:
            "User"
        case .assistant:
            "Assistant"
        case .tool:
            "Tool"
        case .system:
            "System"
        }
    }
}
