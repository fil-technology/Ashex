import CSQLite
import Foundation

public enum SessionSearchResultKind: String, Codable, Sendable, Equatable {
    case message
    case toolCall
}

public struct SessionSearchRequest: Sendable, Equatable {
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

public struct SessionSearchResult: Codable, Sendable, Equatable {
    public let kind: SessionSearchResultKind
    public let id: UUID
    public let threadID: UUID?
    public let runID: UUID?
    public let role: MessageRole?
    public let toolName: String?
    public let snippet: String
    public let createdAt: Date

    public init(kind: SessionSearchResultKind, id: UUID, threadID: UUID?, runID: UUID?, role: MessageRole?, toolName: String?, snippet: String, createdAt: Date) {
        self.kind = kind
        self.id = id
        self.threadID = threadID
        self.runID = runID
        self.role = role
        self.toolName = toolName
        self.snippet = snippet
        self.createdAt = createdAt
    }
}

public final class SessionSearchStore: @unchecked Sendable {
    private let databaseURL: URL
    private let queue = DispatchQueue(label: "ashex.session.search")
    private var db: OpaquePointer?
    private var ftsAvailable = false

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    deinit {
        sqlite3_close(db)
    }

    public func initialize() throws {
        try queue.sync {
            if db == nil {
                if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
                    throw sqliteError("Failed to open database at \(databaseURL.path)")
                }
            }
            ftsAvailable = try createAndPopulateFTSIndex()
        }
    }

    public func search(_ request: SessionSearchRequest) throws -> [SessionSearchResult] {
        try queue.sync {
            try ensureOpen()
            let terms = normalizedTerms(in: request.query)
            guard !terms.isEmpty, request.limit > 0 else { return [] }
            let results = ftsAvailable
                ? try searchFTS(request: request, terms: terms)
                : try searchLIKE(request: request, terms: terms)
            return Array(results.sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.createdAt < rhs.createdAt
            }.prefix(request.limit))
        }
    }

    private func createAndPopulateFTSIndex() throws -> Bool {
        do {
            try exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS session_message_fts USING fts5(
                record_id UNINDEXED,
                thread_id UNINDEXED,
                run_id UNINDEXED,
                role UNINDEXED,
                content,
                created_at UNINDEXED
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS session_tool_call_fts USING fts5(
                record_id UNINDEXED,
                thread_id UNINDEXED,
                run_id UNINDEXED,
                tool_name,
                arguments_json,
                output,
                created_at UNINDEXED
            );
            DELETE FROM session_message_fts;
            DELETE FROM session_tool_call_fts;
            INSERT INTO session_message_fts(record_id, thread_id, run_id, role, content, created_at)
            SELECT id, thread_id, run_id, role, content, created_at FROM messages;
            INSERT INTO session_tool_call_fts(record_id, thread_id, run_id, tool_name, arguments_json, output, created_at)
            SELECT tc.id, r.thread_id, tc.run_id, tc.tool_name, tc.arguments_json, COALESCE(tc.output, ''), tc.started_at
            FROM tool_calls tc
            LEFT JOIN runs r ON r.id = tc.run_id;
            """)
            return true
        } catch {
            try? exec("DROP TABLE IF EXISTS session_message_fts; DROP TABLE IF EXISTS session_tool_call_fts;")
            return false
        }
    }

    private func searchFTS(request: SessionSearchRequest, terms: [String]) throws -> [SessionSearchResult] {
        let matchQuery = terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " ")
        var results: [SessionSearchResult] = []
        results += try queryResults(
            sql: """
            SELECT record_id, thread_id, run_id, role, NULL, content, created_at, 'message'
            FROM session_message_fts
            WHERE session_message_fts MATCH ?\(filterSQL(request))
            ORDER BY bm25(session_message_fts)
            LIMIT ?
            """,
            bind: ftsBindValues(query: matchQuery, request: request)
        )
        results += try queryResults(
            sql: """
            SELECT record_id, thread_id, run_id, NULL, tool_name, trim(tool_name || ' ' || arguments_json || ' ' || output), created_at, 'toolCall'
            FROM session_tool_call_fts
            WHERE session_tool_call_fts MATCH ?\(filterSQL(request))
            ORDER BY bm25(session_tool_call_fts)
            LIMIT ?
            """,
            bind: ftsBindValues(query: matchQuery, request: request)
        )
        return results
    }

    private func searchLIKE(request: SessionSearchRequest, terms: [String]) throws -> [SessionSearchResult] {
        let messagePredicates = terms.map { _ in "lower(content) LIKE ?" }.joined(separator: " AND ")
        let toolPredicates = terms.map { _ in "lower(tool_name || ' ' || arguments_json || ' ' || COALESCE(output, '')) LIKE ?" }.joined(separator: " AND ")
        var results: [SessionSearchResult] = []
        results += try queryResults(
            sql: """
            SELECT id, thread_id, run_id, role, NULL, content, created_at, 'message'
            FROM messages
            WHERE \(messagePredicates)\(filterSQL(request))
            ORDER BY created_at ASC
            LIMIT ?
            """,
            bind: likeBindValues(terms: terms, request: request)
        )
        results += try queryResults(
            sql: """
            SELECT tc.id, r.thread_id, tc.run_id, NULL, tc.tool_name, trim(tc.tool_name || ' ' || tc.arguments_json || ' ' || COALESCE(tc.output, '')), tc.started_at, 'toolCall'
            FROM tool_calls tc
            LEFT JOIN runs r ON r.id = tc.run_id
            WHERE \(toolPredicates)\(filterSQL(request, tableAlias: "tc", threadExpression: "r.thread_id"))
            ORDER BY tc.started_at ASC
            LIMIT ?
            """,
            bind: likeBindValues(terms: terms, request: request)
        )
        return results
    }

    private func queryResults(sql: String, bind: [SessionSQLiteBindValue]) throws -> [SessionSearchResult] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(sql, statement: &statement)
        bindValues(bind, to: statement)

        var results: [SessionSearchResult] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let kind = SessionSearchResultKind(rawValue: columnText(statement, index: 7)) ?? .message
            results.append(SessionSearchResult(
                kind: kind,
                id: UUID(uuidString: columnText(statement, index: 0)) ?? UUID(),
                threadID: UUID(uuidString: columnNullableText(statement, index: 1) ?? ""),
                runID: UUID(uuidString: columnNullableText(statement, index: 2) ?? ""),
                role: columnNullableText(statement, index: 3).flatMap(MessageRole.init(rawValue:)),
                toolName: columnNullableText(statement, index: 4),
                snippet: Self.snippet(from: columnText(statement, index: 5), limit: 240),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            ))
        }
        return results
    }

    private func filterSQL(_ request: SessionSearchRequest, tableAlias: String? = nil, threadExpression: String? = nil) -> String {
        var clauses: [String] = []
        let prefix = tableAlias.map { "\($0)." } ?? ""
        if request.threadID != nil {
            clauses.append("\(threadExpression ?? "\(prefix)thread_id") = ?")
        }
        if request.runID != nil {
            clauses.append("\(prefix)run_id = ?")
        }
        return clauses.isEmpty ? "" : " AND " + clauses.joined(separator: " AND ")
    }

    private func ftsBindValues(query: String, request: SessionSearchRequest) -> [SessionSQLiteBindValue] {
        var values: [SessionSQLiteBindValue] = [.text(query)]
        appendScopeBindings(request, to: &values)
        values.append(.int(Int64(request.limit)))
        return values
    }

    private func likeBindValues(terms: [String], request: SessionSearchRequest) -> [SessionSQLiteBindValue] {
        var values = terms.map { SessionSQLiteBindValue.text("%\($0)%") }
        appendScopeBindings(request, to: &values)
        values.append(.int(Int64(request.limit)))
        return values
    }

    private func appendScopeBindings(_ request: SessionSearchRequest, to values: inout [SessionSQLiteBindValue]) {
        if let threadID = request.threadID {
            values.append(.text(threadID.uuidString))
        }
        if let runID = request.runID {
            values.append(.text(runID.uuidString))
        }
    }

    private func normalizedTerms(in query: String) -> [String] {
        query.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func ensureOpen() throws {
        if db == nil {
            try initialize()
        }
    }

    private func exec(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errorMessage)
            throw sqliteError(message)
        }
    }

    private func prepare(_ sql: String, statement: inout OpaquePointer?) throws {
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            throw sqliteError(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bindValues(_ values: [SessionSQLiteBindValue], to statement: OpaquePointer?) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text):
                text.withCString { pointer in
                    sqlite3_bind_text(statement, index, pointer, -1, sessionSQLiteTransient)
                }
            case .int(let number):
                sqlite3_bind_int64(statement, index, number)
            }
        }
    }

    private func columnText(_ statement: OpaquePointer?, index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private func columnNullableText(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func sqliteError(_ message: String) -> AshexError {
        AshexError.persistence(message)
    }

    private static func snippet(from content: String, limit: Int) -> String {
        let collapsed = content.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let index = collapsed.index(collapsed.startIndex, offsetBy: limit)
        return String(collapsed[..<index])
    }
}

private enum SessionSQLiteBindValue {
    case text(String)
    case int(Int64)
}

private let sessionSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
