import CSQLite
import Foundation

public final class SQLitePersistenceStore: PersistenceStore, @unchecked Sendable {
    private let databaseURL: URL
    private let queue = DispatchQueue(label: "ashex.sqlite.persistence")
    private var db: OpaquePointer?

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    deinit {
        sqlite3_close(db)
    }

    public func initialize() throws {
        try queue.sync {
            try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
                throw AshexError.persistence("Failed to open database at \(databaseURL.path)")
            }

            try exec("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS threads (
                id TEXT PRIMARY KEY,
                created_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                thread_id TEXT NOT NULL,
                run_id TEXT,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS runs (
                id TEXT PRIMARY KEY,
                thread_id TEXT NOT NULL,
                state TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS run_state_transitions (
                id TEXT PRIMARY KEY,
                run_id TEXT NOT NULL,
                state TEXT NOT NULL,
                reason TEXT,
                created_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS tool_calls (
                id TEXT PRIMARY KEY,
                run_id TEXT NOT NULL,
                tool_name TEXT NOT NULL,
                arguments_json TEXT NOT NULL,
                started_at REAL NOT NULL,
                finished_at REAL,
                status TEXT NOT NULL,
                output TEXT
            );
            CREATE TABLE IF NOT EXISTS events (
                id TEXT PRIMARY KEY,
                run_id TEXT,
                payload_json TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            """)
        }
    }

    public func normalizeInterruptedRuns(now: Date) throws {
        try queue.sync {
            let ids = try queryStrings("SELECT id FROM runs WHERE state = 'running'")
            for id in ids {
                try exec("UPDATE runs SET state = 'interrupted', updated_at = ? WHERE id = ?", bind: [.double(now.timeIntervalSince1970), .text(id)])
                try exec(
                    "INSERT INTO run_state_transitions (id, run_id, state, reason, created_at) VALUES (?, ?, ?, ?, ?)",
                    bind: [.text(UUID().uuidString), .text(id), .text(RunState.interrupted.rawValue), .text("Recovered after process restart"), .double(now.timeIntervalSince1970)]
                )
                let event = RuntimeEvent(timestamp: now, payload: .runStateChanged(runID: UUID(uuidString: id) ?? UUID(), state: .interrupted, reason: "Recovered after process restart"))
                try appendEventLocked(event, runID: UUID(uuidString: id))
            }
        }
    }

    public func createThread(now: Date) throws -> ThreadRecord {
        try queue.sync {
            let record = ThreadRecord(id: UUID(), createdAt: now)
            try exec("INSERT INTO threads (id, created_at) VALUES (?, ?)", bind: [.text(record.id.uuidString), .double(now.timeIntervalSince1970)])
            return record
        }
    }

    public func createRun(threadID: UUID, state: RunState, now: Date) throws -> RunRecord {
        try queue.sync {
            let run = RunRecord(id: UUID(), threadID: threadID, state: state, createdAt: now, updatedAt: now)
            try exec(
                "INSERT INTO runs (id, thread_id, state, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                bind: [.text(run.id.uuidString), .text(threadID.uuidString), .text(state.rawValue), .double(now.timeIntervalSince1970), .double(now.timeIntervalSince1970)]
            )
            try exec(
                "INSERT INTO run_state_transitions (id, run_id, state, reason, created_at) VALUES (?, ?, ?, ?, ?)",
                bind: [.text(UUID().uuidString), .text(run.id.uuidString), .text(state.rawValue), .null, .double(now.timeIntervalSince1970)]
            )
            return run
        }
    }

    public func transitionRun(runID: UUID, to state: RunState, reason: String?, now: Date) throws {
        try queue.sync {
            try exec("UPDATE runs SET state = ?, updated_at = ? WHERE id = ?", bind: [.text(state.rawValue), .double(now.timeIntervalSince1970), .text(runID.uuidString)])
            try exec(
                "INSERT INTO run_state_transitions (id, run_id, state, reason, created_at) VALUES (?, ?, ?, ?, ?)",
                bind: [.text(UUID().uuidString), .text(runID.uuidString), .text(state.rawValue), .text(reason), .double(now.timeIntervalSince1970)]
            )
        }
    }

    public func appendMessage(threadID: UUID, runID: UUID?, role: MessageRole, content: String, now: Date) throws -> MessageRecord {
        try queue.sync {
            let record = MessageRecord(id: UUID(), threadID: threadID, runID: runID, role: role, content: content, createdAt: now)
            try exec(
                "INSERT INTO messages (id, thread_id, run_id, role, content, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                bind: [.text(record.id.uuidString), .text(threadID.uuidString), .text(runID?.uuidString), .text(role.rawValue), .text(content), .double(now.timeIntervalSince1970)]
            )
            return record
        }
    }

    public func fetchMessages(threadID: UUID) throws -> [MessageRecord] {
        try queue.sync {
            let sql = "SELECT id, run_id, role, content, created_at FROM messages WHERE thread_id = ? ORDER BY created_at ASC"
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql, statement: &statement)
            bindText(threadID.uuidString, to: statement, index: 1)

            var messages: [MessageRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = UUID(uuidString: columnText(statement, index: 0)) ?? UUID()
                let runID = UUID(uuidString: columnNullableText(statement, index: 1) ?? "")
                let role = MessageRole(rawValue: columnText(statement, index: 2)) ?? .system
                let content = columnText(statement, index: 3)
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                messages.append(.init(id: id, threadID: threadID, runID: runID, role: role, content: content, createdAt: createdAt))
            }
            return messages
        }
    }

    public func recordToolCall(runID: UUID, toolName: String, arguments: JSONObject, now: Date) throws -> ToolCallRecord {
        try queue.sync {
            let record = ToolCallRecord(id: UUID(), runID: runID, toolName: toolName, arguments: arguments, startedAt: now, finishedAt: nil, status: "running", output: nil)
            let argsJSON = try encodeJSONString(JSONValue.object(arguments))
            try exec(
                "INSERT INTO tool_calls (id, run_id, tool_name, arguments_json, started_at, status) VALUES (?, ?, ?, ?, ?, ?)",
                bind: [.text(record.id.uuidString), .text(runID.uuidString), .text(toolName), .text(argsJSON), .double(now.timeIntervalSince1970), .text("running")]
            )
            return record
        }
    }

    public func finishToolCall(toolCallID: UUID, status: String, output: String, finishedAt: Date) throws {
        try queue.sync {
            try exec(
                "UPDATE tool_calls SET status = ?, output = ?, finished_at = ? WHERE id = ?",
                bind: [.text(status), .text(output), .double(finishedAt.timeIntervalSince1970), .text(toolCallID.uuidString)]
            )
        }
    }

    public func appendEvent(_ event: RuntimeEvent, runID: UUID?) throws {
        try queue.sync {
            try appendEventLocked(event, runID: runID)
        }
    }

    public func listThreads(limit: Int) throws -> [ThreadSummary] {
        try queue.sync {
            let sql = """
            SELECT
                t.id,
                t.created_at,
                COALESCE(MAX(r.updated_at), t.created_at) AS updated_at,
                (
                    SELECT r2.id
                    FROM runs r2
                    WHERE r2.thread_id = t.id
                    ORDER BY r2.updated_at DESC
                    LIMIT 1
                ) AS latest_run_id,
                (
                    SELECT r2.state
                    FROM runs r2
                    WHERE r2.thread_id = t.id
                    ORDER BY r2.updated_at DESC
                    LIMIT 1
                ) AS latest_run_state,
                (
                    SELECT COUNT(*)
                    FROM messages m
                    WHERE m.thread_id = t.id
                ) AS message_count
            FROM threads t
            LEFT JOIN runs r ON r.thread_id = t.id
            GROUP BY t.id, t.created_at
            ORDER BY updated_at DESC
            LIMIT ?
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql, statement: &statement)
            sqlite3_bind_int(statement, 1, Int32(limit))

            var threads: [ThreadSummary] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = UUID(uuidString: columnText(statement, index: 0)) ?? UUID()
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                let latestRunID = UUID(uuidString: columnNullableText(statement, index: 3) ?? "")
                let latestRunState = columnNullableText(statement, index: 4).flatMap(RunState.init(rawValue:))
                let messageCount = Int(sqlite3_column_int(statement, 5))
                threads.append(.init(
                    id: id,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    latestRunID: latestRunID,
                    latestRunState: latestRunState,
                    messageCount: messageCount
                ))
            }

            return threads
        }
    }

    public func fetchRuns(threadID: UUID) throws -> [RunRecord] {
        try queue.sync {
            let sql = "SELECT id, state, created_at, updated_at FROM runs WHERE thread_id = ? ORDER BY updated_at DESC"
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql, statement: &statement)
            bindText(threadID.uuidString, to: statement, index: 1)

            var runs: [RunRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let runID = UUID(uuidString: columnText(statement, index: 0)) ?? UUID()
                let state = RunState(rawValue: columnText(statement, index: 1)) ?? .failed
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                runs.append(.init(id: runID, threadID: threadID, state: state, createdAt: createdAt, updatedAt: updatedAt))
            }
            return runs
        }
    }

    public func fetchEvents(runID: UUID) throws -> [RuntimeEvent] {
        try queue.sync {
            let sql = "SELECT payload_json FROM events WHERE run_id = ? ORDER BY created_at ASC"
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql, statement: &statement)
            bindText(runID.uuidString, to: statement, index: 1)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970

            var events: [RuntimeEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let payloadJSON = columnText(statement, index: 0)
                let data = Data(payloadJSON.utf8)
                events.append(try decoder.decode(RuntimeEvent.self, from: data))
            }
            return events
        }
    }

    public func fetchRun(runID: UUID) throws -> RunRecord? {
        try queue.sync {
            let sql = "SELECT thread_id, state, created_at, updated_at FROM runs WHERE id = ? LIMIT 1"
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql, statement: &statement)
            bindText(runID.uuidString, to: statement, index: 1)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return RunRecord(
                id: runID,
                threadID: UUID(uuidString: columnText(statement, index: 0)) ?? UUID(),
                state: RunState(rawValue: columnText(statement, index: 1)) ?? .failed,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            )
        }
    }

    private func appendEventLocked(_ event: RuntimeEvent, runID: UUID?) throws {
        let payloadJSON = try encodeJSONString(event)
        try exec(
            "INSERT INTO events (id, run_id, payload_json, created_at) VALUES (?, ?, ?, ?)",
            bind: [.text(event.id.uuidString), .text(runID?.uuidString), .text(payloadJSON), .double(event.timestamp.timeIntervalSince1970)]
        )
    }

    private func exec(_ sql: String, bind: [SQLiteBindValue] = []) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        if bind.isEmpty {
            if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
                let message = errorMessage.map { String(cString: $0) } ?? "Unknown SQLite error"
                sqlite3_free(errorMessage)
                throw AshexError.persistence(message)
            }
            return
        }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(sql, statement: &statement)
        try bindValues(bind, to: statement)
        if sqlite3_step(statement) != SQLITE_DONE {
            throw AshexError.persistence(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func queryStrings(_ sql: String) throws -> [String] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(sql, statement: &statement)
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(columnText(statement, index: 0))
        }
        return values
    }

    private func prepare(_ sql: String, statement: inout OpaquePointer?) throws {
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            throw AshexError.persistence(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bindText(_ text: String, to statement: OpaquePointer?, index: Int32) {
        _ = text.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, sqliteTransient)
        }
    }

    private func bindValues(_ values: [SQLiteBindValue], to statement: OpaquePointer?) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text):
                if let text {
                    bindText(text, to: statement, index: index)
                } else {
                    sqlite3_bind_null(statement, index)
                }
            case .double(let number):
                sqlite3_bind_double(statement, index, number)
            case .null:
                sqlite3_bind_null(statement, index)
            }
        }
    }

    private func columnText(_ statement: OpaquePointer?, index: Int32) -> String {
        String(cString: sqlite3_column_text(statement, index))
    }

    private func columnNullableText(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func encodeJSONString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw AshexError.persistence("Failed to encode JSON payload")
        }
        return string
    }
}

private enum SQLiteBindValue {
    case text(String?)
    case double(Double)
    case null
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
