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
            if db != nil {
                return
            }
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
            CREATE TABLE IF NOT EXISTS run_steps (
                id TEXT PRIMARY KEY,
                run_id TEXT NOT NULL,
                step_index INTEGER NOT NULL,
                title TEXT NOT NULL,
                state TEXT NOT NULL,
                summary TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS context_compactions (
                id TEXT PRIMARY KEY,
                run_id TEXT NOT NULL,
                dropped_message_count INTEGER NOT NULL,
                retained_message_count INTEGER NOT NULL,
                estimated_token_count INTEGER NOT NULL,
                estimated_context_window INTEGER NOT NULL,
                summary TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS workspace_snapshots (
                id TEXT PRIMARY KEY,
                run_id TEXT NOT NULL UNIQUE,
                workspace_root_path TEXT NOT NULL,
                top_level_entries_json TEXT NOT NULL,
                instruction_files_json TEXT NOT NULL,
                project_markers_json TEXT NOT NULL DEFAULT '[]',
                source_roots_json TEXT NOT NULL DEFAULT '[]',
                test_roots_json TEXT NOT NULL DEFAULT '[]',
                git_branch TEXT,
                git_status_summary TEXT,
                created_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS working_memory (
                id TEXT PRIMARY KEY,
                run_id TEXT NOT NULL UNIQUE,
                current_task TEXT NOT NULL,
                current_phase TEXT,
                exploration_targets_json TEXT NOT NULL DEFAULT '[]',
                pending_exploration_targets_json TEXT NOT NULL DEFAULT '[]',
                inspected_paths_json TEXT NOT NULL,
                changed_paths_json TEXT NOT NULL,
                recent_findings_json TEXT NOT NULL DEFAULT '[]',
                completed_steps_json TEXT NOT NULL DEFAULT '[]',
                unresolved_items_json TEXT NOT NULL DEFAULT '[]',
                validation_suggestions_json TEXT NOT NULL,
                planned_change_set_json TEXT NOT NULL DEFAULT '[]',
                patch_objectives_json TEXT NOT NULL DEFAULT '[]',
                carry_forward_notes_json TEXT NOT NULL DEFAULT '[]',
                summary TEXT NOT NULL,
                updated_at REAL NOT NULL
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
            CREATE TABLE IF NOT EXISTS settings (
                namespace TEXT NOT NULL,
                key TEXT NOT NULL,
                value_json TEXT NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (namespace, key)
            );
            """)
            try ensureColumnExists(table: "workspace_snapshots", column: "project_markers_json", definition: "TEXT NOT NULL DEFAULT '[]'")
            try ensureColumnExists(table: "workspace_snapshots", column: "source_roots_json", definition: "TEXT NOT NULL DEFAULT '[]'")
            try ensureColumnExists(table: "workspace_snapshots", column: "test_roots_json", definition: "TEXT NOT NULL DEFAULT '[]'")
            try ensureColumnExists(table: "working_memory", column: "exploration_targets_json", definition: "TEXT NOT NULL DEFAULT '[]'")
            try ensureColumnExists(table: "working_memory", column: "pending_exploration_targets_json", definition: "TEXT NOT NULL DEFAULT '[]'")
            try ensureColumnExists(table: "working_memory", column: "recent_findings_json", definition: "TEXT NOT NULL DEFAULT '[]'")
            try ensureColumnExists(table: "working_memory", column: "completed_steps_json", definition: "TEXT NOT NULL DEFAULT '[]'")
            try ensureColumnExists(table: "working_memory", column: "unresolved_items_json", definition: "TEXT NOT NULL DEFAULT '[]'")
            try ensureColumnExists(table: "working_memory", column: "planned_change_set_json", definition: "TEXT NOT NULL DEFAULT '[]'")
            try ensureColumnExists(table: "working_memory", column: "patch_objectives_json", definition: "TEXT NOT NULL DEFAULT '[]'")
            try ensureColumnExists(table: "working_memory", column: "carry_forward_notes_json", definition: "TEXT NOT NULL DEFAULT '[]'")
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

    public func createRunSteps(runID: UUID, steps: [String], now: Date) throws -> [RunStepRecord] {
        try queue.sync {
            var records: [RunStepRecord] = []
            for (index, title) in steps.enumerated() {
                let record = RunStepRecord(
                    id: UUID(),
                    runID: runID,
                    index: index + 1,
                    title: title,
                    state: .pending,
                    summary: nil,
                    createdAt: now,
                    updatedAt: now
                )
                try exec(
                    "INSERT INTO run_steps (id, run_id, step_index, title, state, summary, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    bind: [
                        .text(record.id.uuidString),
                        .text(runID.uuidString),
                        .int(Int64(record.index)),
                        .text(record.title),
                        .text(record.state.rawValue),
                        .null,
                        .double(now.timeIntervalSince1970),
                        .double(now.timeIntervalSince1970),
                    ]
                )
                records.append(record)
            }
            return records
        }
    }

    public func transitionRunStep(stepID: UUID, to state: RunStepState, summary: String?, now: Date) throws {
        try queue.sync {
            try exec(
                "UPDATE run_steps SET state = ?, summary = ?, updated_at = ? WHERE id = ?",
                bind: [.text(state.rawValue), .text(summary), .double(now.timeIntervalSince1970), .text(stepID.uuidString)]
            )
        }
    }

    public func fetchRunSteps(runID: UUID) throws -> [RunStepRecord] {
        try queue.sync {
            let sql = "SELECT id, step_index, title, state, summary, created_at, updated_at FROM run_steps WHERE run_id = ? ORDER BY step_index ASC"
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql, statement: &statement)
            bindText(runID.uuidString, to: statement, index: 1)

            var steps: [RunStepRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = UUID(uuidString: columnText(statement, index: 0)) ?? UUID()
                let index = Int(sqlite3_column_int(statement, 1))
                let title = columnText(statement, index: 2)
                let state = RunStepState(rawValue: columnText(statement, index: 3)) ?? .failed
                let summary = columnNullableText(statement, index: 4)
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
                steps.append(.init(id: id, runID: runID, index: index, title: title, state: state, summary: summary, createdAt: createdAt, updatedAt: updatedAt))
            }
            return steps
        }
    }

    public func recordWorkspaceSnapshot(
        runID: UUID,
        workspaceRootPath: String,
        topLevelEntries: [String],
        instructionFiles: [String],
        projectMarkers: [String],
        sourceRoots: [String],
        testRoots: [String],
        gitBranch: String?,
        gitStatusSummary: String?,
        now: Date
    ) throws -> WorkspaceSnapshotRecord {
        try queue.sync {
            let record = WorkspaceSnapshotRecord(
                id: UUID(),
                runID: runID,
                workspaceRootPath: workspaceRootPath,
                topLevelEntries: topLevelEntries,
                instructionFiles: instructionFiles,
                projectMarkers: projectMarkers,
                sourceRoots: sourceRoots,
                testRoots: testRoots,
                gitBranch: gitBranch,
                gitStatusSummary: gitStatusSummary,
                createdAt: now
            )
            try exec(
                """
                INSERT OR REPLACE INTO workspace_snapshots
                (id, run_id, workspace_root_path, top_level_entries_json, instruction_files_json, project_markers_json, source_roots_json, test_roots_json, git_branch, git_status_summary, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bind: [
                    .text(record.id.uuidString),
                    .text(runID.uuidString),
                    .text(record.workspaceRootPath),
                    .text(try encodeJSONString(record.topLevelEntries)),
                    .text(try encodeJSONString(record.instructionFiles)),
                    .text(try encodeJSONString(record.projectMarkers)),
                    .text(try encodeJSONString(record.sourceRoots)),
                    .text(try encodeJSONString(record.testRoots)),
                    .text(record.gitBranch),
                    .text(record.gitStatusSummary),
                    .double(now.timeIntervalSince1970),
                ]
            )
            return record
        }
    }

    public func fetchWorkspaceSnapshot(runID: UUID) throws -> WorkspaceSnapshotRecord? {
        try queue.sync {
            let sql = """
            SELECT id, workspace_root_path, top_level_entries_json, instruction_files_json, project_markers_json, source_roots_json, test_roots_json, git_branch, git_status_summary, created_at
            FROM workspace_snapshots
            WHERE run_id = ?
            LIMIT 1
            """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql, statement: &statement)
            bindText(runID.uuidString, to: statement, index: 1)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return WorkspaceSnapshotRecord(
                id: UUID(uuidString: columnText(statement, index: 0)) ?? UUID(),
                runID: runID,
                workspaceRootPath: columnText(statement, index: 1),
                topLevelEntries: try decodeStringArrayJSON(columnText(statement, index: 2)),
                instructionFiles: try decodeStringArrayJSON(columnText(statement, index: 3)),
                projectMarkers: try decodeStringArrayJSON(columnText(statement, index: 4)),
                sourceRoots: try decodeStringArrayJSON(columnText(statement, index: 5)),
                testRoots: try decodeStringArrayJSON(columnText(statement, index: 6)),
                gitBranch: columnNullableText(statement, index: 7),
                gitStatusSummary: columnNullableText(statement, index: 8),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))
            )
        }
    }

    public func upsertWorkingMemory(
        runID: UUID,
        currentTask: String,
        currentPhase: String?,
        explorationTargets: [String],
        pendingExplorationTargets: [String],
        inspectedPaths: [String],
        changedPaths: [String],
        recentFindings: [String],
        completedStepSummaries: [String],
        unresolvedItems: [String],
        validationSuggestions: [String],
        plannedChangeSet: [String],
        patchObjectives: [String],
        carryForwardNotes: [String],
        summary: String,
        now: Date
    ) throws -> WorkingMemoryRecord {
        try queue.sync {
            let existing = try fetchWorkingMemoryLocked(runID: runID)
            let record = WorkingMemoryRecord(
                id: existing?.id ?? UUID(),
                runID: runID,
                currentTask: currentTask,
                currentPhase: currentPhase,
                explorationTargets: explorationTargets,
                pendingExplorationTargets: pendingExplorationTargets,
                inspectedPaths: inspectedPaths,
                changedPaths: changedPaths,
                recentFindings: recentFindings,
                completedStepSummaries: completedStepSummaries,
                unresolvedItems: unresolvedItems,
                validationSuggestions: validationSuggestions,
                plannedChangeSet: plannedChangeSet,
                patchObjectives: patchObjectives,
                carryForwardNotes: carryForwardNotes,
                summary: summary,
                updatedAt: now
            )
            try exec(
                """
                INSERT OR REPLACE INTO working_memory
                (id, run_id, current_task, current_phase, exploration_targets_json, pending_exploration_targets_json, inspected_paths_json, changed_paths_json, recent_findings_json, completed_steps_json, unresolved_items_json, validation_suggestions_json, planned_change_set_json, patch_objectives_json, carry_forward_notes_json, summary, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bind: [
                    .text(record.id.uuidString),
                    .text(runID.uuidString),
                    .text(record.currentTask),
                    .text(record.currentPhase),
                    .text(try encodeJSONString(record.explorationTargets)),
                    .text(try encodeJSONString(record.pendingExplorationTargets)),
                    .text(try encodeJSONString(record.inspectedPaths)),
                    .text(try encodeJSONString(record.changedPaths)),
                    .text(try encodeJSONString(record.recentFindings)),
                    .text(try encodeJSONString(record.completedStepSummaries)),
                    .text(try encodeJSONString(record.unresolvedItems)),
                    .text(try encodeJSONString(record.validationSuggestions)),
                    .text(try encodeJSONString(record.plannedChangeSet)),
                    .text(try encodeJSONString(record.patchObjectives)),
                    .text(try encodeJSONString(record.carryForwardNotes)),
                    .text(record.summary),
                    .double(now.timeIntervalSince1970),
                ]
            )
            return record
        }
    }

    public func fetchWorkingMemory(runID: UUID) throws -> WorkingMemoryRecord? {
        try queue.sync {
            try fetchWorkingMemoryLocked(runID: runID)
        }
    }

    public func recordContextCompaction(
        runID: UUID,
        droppedMessageCount: Int,
        retainedMessageCount: Int,
        estimatedTokenCount: Int,
        estimatedContextWindow: Int,
        summary: String,
        now: Date
    ) throws -> ContextCompactionRecord {
        try queue.sync {
            let record = ContextCompactionRecord(
                id: UUID(),
                runID: runID,
                droppedMessageCount: droppedMessageCount,
                retainedMessageCount: retainedMessageCount,
                estimatedTokenCount: estimatedTokenCount,
                estimatedContextWindow: estimatedContextWindow,
                summary: summary,
                createdAt: now
            )
            try exec(
                """
                INSERT INTO context_compactions
                (id, run_id, dropped_message_count, retained_message_count, estimated_token_count, estimated_context_window, summary, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bind: [
                    .text(record.id.uuidString),
                    .text(runID.uuidString),
                    .int(Int64(record.droppedMessageCount)),
                    .int(Int64(record.retainedMessageCount)),
                    .int(Int64(record.estimatedTokenCount)),
                    .int(Int64(record.estimatedContextWindow)),
                    .text(record.summary),
                    .double(now.timeIntervalSince1970),
                ]
            )
            return record
        }
    }

    public func fetchContextCompactions(runID: UUID) throws -> [ContextCompactionRecord] {
        try queue.sync {
            let sql = """
            SELECT id, dropped_message_count, retained_message_count, estimated_token_count, estimated_context_window, summary, created_at
            FROM context_compactions
            WHERE run_id = ?
            ORDER BY created_at ASC
            """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql, statement: &statement)
            bindText(runID.uuidString, to: statement, index: 1)

            var records: [ContextCompactionRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                records.append(.init(
                    id: UUID(uuidString: columnText(statement, index: 0)) ?? UUID(),
                    runID: runID,
                    droppedMessageCount: Int(sqlite3_column_int(statement, 1)),
                    retainedMessageCount: Int(sqlite3_column_int(statement, 2)),
                    estimatedTokenCount: Int(sqlite3_column_int(statement, 3)),
                    estimatedContextWindow: Int(sqlite3_column_int(statement, 4)),
                    summary: columnText(statement, index: 5),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
                ))
            }
            return records
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

    public func upsertSetting(namespace: String, key: String, value: JSONValue, now: Date) throws {
        try queue.sync {
            let valueJSON = try encodeJSONString(value)
            try exec(
                """
                INSERT INTO settings (namespace, key, value_json, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(namespace, key) DO UPDATE SET
                    value_json = excluded.value_json,
                    updated_at = excluded.updated_at
                """,
                bind: [
                    .text(namespace),
                    .text(key),
                    .text(valueJSON),
                    .double(now.timeIntervalSince1970),
                ]
            )
        }
    }

    public func fetchSetting(namespace: String, key: String) throws -> PersistedSetting? {
        try queue.sync {
            let sql = "SELECT value_json, updated_at FROM settings WHERE namespace = ? AND key = ? LIMIT 1"
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql, statement: &statement)
            bindText(namespace, to: statement, index: 1)
            bindText(key, to: statement, index: 2)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

            let decoder = JSONDecoder()
            let valueJSON = columnText(statement, index: 0)
            let value = try decoder.decode(JSONValue.self, from: Data(valueJSON.utf8))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            return PersistedSetting(namespace: namespace, key: key, value: value, updatedAt: updatedAt)
        }
    }

    public func listSettings(namespace: String) throws -> [PersistedSetting] {
        try queue.sync {
            let sql = "SELECT key, value_json, updated_at FROM settings WHERE namespace = ? ORDER BY key ASC"
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql, statement: &statement)
            bindText(namespace, to: statement, index: 1)

            let decoder = JSONDecoder()
            var settings: [PersistedSetting] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let key = columnText(statement, index: 0)
                let valueJSON = columnText(statement, index: 1)
                let value = try decoder.decode(JSONValue.self, from: Data(valueJSON.utf8))
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                settings.append(PersistedSetting(namespace: namespace, key: key, value: value, updatedAt: updatedAt))
            }
            return settings
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

    private func queryStrings(_ sql: String, columnIndex: Int32 = 0) throws -> [String] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(sql, statement: &statement)
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(columnText(statement, index: columnIndex))
        }
        return values
    }

    private func fetchWorkingMemoryLocked(runID: UUID) throws -> WorkingMemoryRecord? {
        let sql = """
        SELECT id, current_task, current_phase, exploration_targets_json, pending_exploration_targets_json, inspected_paths_json, changed_paths_json, recent_findings_json, completed_steps_json, unresolved_items_json, validation_suggestions_json, planned_change_set_json, patch_objectives_json, carry_forward_notes_json, summary, updated_at
        FROM working_memory
        WHERE run_id = ?
        LIMIT 1
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(sql, statement: &statement)
        bindText(runID.uuidString, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return WorkingMemoryRecord(
            id: UUID(uuidString: columnText(statement, index: 0)) ?? UUID(),
            runID: runID,
            currentTask: columnText(statement, index: 1),
            currentPhase: columnNullableText(statement, index: 2),
            explorationTargets: try decodeStringArrayJSON(columnText(statement, index: 3)),
            pendingExplorationTargets: try decodeStringArrayJSON(columnText(statement, index: 4)),
            inspectedPaths: try decodeStringArrayJSON(columnText(statement, index: 5)),
            changedPaths: try decodeStringArrayJSON(columnText(statement, index: 6)),
            recentFindings: try decodeStringArrayJSON(columnText(statement, index: 7)),
            completedStepSummaries: try decodeStringArrayJSON(columnText(statement, index: 8)),
            unresolvedItems: try decodeStringArrayJSON(columnText(statement, index: 9)),
            validationSuggestions: try decodeStringArrayJSON(columnText(statement, index: 10)),
            plannedChangeSet: try decodeStringArrayJSON(columnText(statement, index: 11)),
            patchObjectives: try decodeStringArrayJSON(columnText(statement, index: 12)),
            carryForwardNotes: try decodeStringArrayJSON(columnText(statement, index: 13)),
            summary: columnText(statement, index: 14),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 15))
        )
    }

    private func ensureColumnExists(table: String, column: String, definition: String) throws {
        let existingColumns = try queryStrings("PRAGMA table_info(\(table))", columnIndex: 1)
        guard !existingColumns.contains(column) else { return }
        try exec("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
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
            case .int(let number):
                sqlite3_bind_int64(statement, index, number)
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

    private func decodeStringArrayJSON(_ string: String) throws -> [String] {
        try JSONDecoder().decode([String].self, from: Data(string.utf8))
    }
}

private enum SQLiteBindValue {
    case text(String?)
    case int(Int64)
    case double(Double)
    case null
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
