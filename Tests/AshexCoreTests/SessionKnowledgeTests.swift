import AshexCore
import Foundation
import Testing

@Test func sessionTranscriptSearchScansJSONLWithoutSQLite() throws {
    let root = try makeSessionKnowledgeTestRoot()
    let store = SessionTranscriptStore(directoryURL: root.appendingPathComponent("sessions"))
    let threadID = UUID()
    let otherThreadID = UUID()
    let runID = UUID()

    try store.append(.message(MessageRecord(
        id: UUID(),
        threadID: threadID,
        runID: runID,
        role: .user,
        content: "Investigate the JSONL indexing path for session knowledge.",
        createdAt: Date(timeIntervalSince1970: 1)
    )))
    try store.append(.toolCall(ToolCallRecord(
        id: UUID(),
        runID: runID,
        toolName: "search_text",
        arguments: ["query": .string("JSONL indexing")],
        startedAt: Date(timeIntervalSince1970: 2),
        finishedAt: Date(timeIntervalSince1970: 3),
        status: "succeeded",
        output: "Found JSONL indexing tests"
    ), threadID: threadID))
    try store.append(.message(MessageRecord(
        id: UUID(),
        threadID: otherThreadID,
        runID: nil,
        role: .assistant,
        content: "Unrelated checkout work.",
        createdAt: Date(timeIntervalSince1970: 4)
    )))

    let results = try store.search(SessionTranscriptSearchRequest(query: "jsonl indexing", threadID: threadID))

    #expect(results.count == 2)
    #expect(results.map(\.entry.kind) == [.message, .toolCall])
    #expect(results.allSatisfy { $0.entry.threadID == threadID })
    #expect(results.allSatisfy { $0.snippet.lowercased().contains("jsonl") })
}

@Test func sessionSummarizerCanSummarizeTranscriptEntries() throws {
    let threadID = UUID()
    let runID = UUID()
    let entries: [SessionTranscriptEntry] = [
        .message(MessageRecord(
            id: UUID(),
            threadID: threadID,
            runID: runID,
            role: .user,
            content: "Ship compact summaries for session knowledge.",
            createdAt: Date(timeIntervalSince1970: 1)
        )),
        .toolCall(ToolCallRecord(
            id: UUID(),
            runID: runID,
            toolName: "swift_test",
            arguments: [:],
            startedAt: Date(timeIntervalSince1970: 2),
            finishedAt: Date(timeIntervalSince1970: 3),
            status: "succeeded",
            output: "SessionKnowledgeTests passed"
        ), threadID: threadID),
    ]

    let summary = SessionSummarizer.summarize(entries: entries, maxBulletCount: 2)

    #expect(summary.title == "Ship compact summaries for session knowledge.")
    #expect(summary.bullets == [
        "User: Ship compact summaries for session knowledge.",
        "Tool swift_test succeeded: SessionKnowledgeTests passed",
    ])
}

private func makeSessionKnowledgeTestRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ashex-session-knowledge-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
