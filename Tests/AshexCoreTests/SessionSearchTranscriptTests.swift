import AshexCore
import Foundation
import Testing

@Test func sessionSearchFindsMessagesAndToolCallsInSQLiteHistory() throws {
    let root = try makeSessionTestRoot()
    let databaseURL = root.appendingPathComponent(".ashex/history.sqlite")
    let persistence = SQLitePersistenceStore(databaseURL: databaseURL)
    try persistence.initialize()

    let thread = try persistence.createThread(now: Date(timeIntervalSince1970: 1))
    let run = try persistence.createRun(threadID: thread.id, state: .completed, now: Date(timeIntervalSince1970: 2))
    _ = try persistence.appendMessage(
        threadID: thread.id,
        runID: run.id,
        role: .user,
        content: "Find the checkout regression in the payment provider.",
        now: Date(timeIntervalSince1970: 3)
    )
    let call = try persistence.recordToolCall(
        runID: run.id,
        toolName: "search_text",
        arguments: ["query": .string("checkout regression")],
        now: Date(timeIntervalSince1970: 4)
    )
    try persistence.finishToolCall(
        toolCallID: call.id,
        status: "succeeded",
        output: "Sources/Payments/Checkout.swift:42: regression reproduced",
        finishedAt: Date(timeIntervalSince1970: 5)
    )

    let search = SessionSearchStore(databaseURL: databaseURL)
    try search.initialize()
    let results = try search.search(SessionSearchRequest(query: "checkout regression", limit: 10))

    #expect(results.map(\.kind).contains(.message))
    #expect(results.map(\.kind).contains(.toolCall))
    #expect(results.contains { $0.threadID == thread.id && $0.runID == run.id })
    #expect(results.contains { $0.snippet.contains("checkout regression") })
}

@Test func sessionTranscriptWritesAndReadsMessageAndToolCallJSONL() throws {
    let root = try makeSessionTestRoot()
    let transcriptURL = root.appendingPathComponent("sessions")
    let store = SessionTranscriptStore(directoryURL: transcriptURL)
    let threadID = UUID()
    let runID = UUID()
    let message = MessageRecord(
        id: UUID(),
        threadID: threadID,
        runID: runID,
        role: .assistant,
        content: "Implemented the deterministic transcript reader.",
        createdAt: Date(timeIntervalSince1970: 10)
    )
    let call = ToolCallRecord(
        id: UUID(),
        runID: runID,
        toolName: "read_text_file",
        arguments: ["path": .string("Sources/AshexCore/SessionTranscripts.swift")],
        startedAt: Date(timeIntervalSince1970: 11),
        finishedAt: Date(timeIntervalSince1970: 12),
        status: "succeeded",
        output: "public struct SessionTranscriptStore"
    )

    try store.append(.message(message))
    try store.append(.toolCall(call, threadID: threadID))

    let entries = try store.read(threadID: threadID)

    #expect(entries.count == 2)
    #expect(entries.map(\.kind) == [.message, .toolCall])
    #expect(entries[0].message?.content == message.content)
    #expect(entries[1].toolCall?.toolName == "read_text_file")
    #expect(entries[1].threadID == threadID)
}

@Test func sessionSummarizerReturnsDeterministicExtractiveSummary() throws {
    let threadID = UUID()
    let runID = UUID()
    let messages = [
        MessageRecord(id: UUID(), threadID: threadID, runID: runID, role: .user, content: "Implement session search, JSONL transcripts, and summaries.", createdAt: Date(timeIntervalSince1970: 1)),
        MessageRecord(id: UUID(), threadID: threadID, runID: runID, role: .assistant, content: "Added SQLite search and transcript helpers.", createdAt: Date(timeIntervalSince1970: 2)),
        MessageRecord(id: UUID(), threadID: threadID, runID: runID, role: .assistant, content: "Validation passes for focused session tests.", createdAt: Date(timeIntervalSince1970: 3)),
    ]
    let toolCalls = [
        ToolCallRecord(id: UUID(), runID: runID, toolName: "search_text", arguments: ["query": .string("session")], startedAt: Date(timeIntervalSince1970: 4), finishedAt: Date(timeIntervalSince1970: 5), status: "succeeded", output: "3 matches")
    ]

    let first = SessionSummarizer.summarize(messages: messages, toolCalls: toolCalls, maxBulletCount: 3)
    let second = SessionSummarizer.summarize(messages: messages, toolCalls: toolCalls, maxBulletCount: 3)

    #expect(first == second)
    #expect(first.title == "Implement session search, JSONL transcripts, and summaries.")
    #expect(first.bullets == [
        "User: Implement session search, JSONL transcripts, and summaries.",
        "Assistant: Added SQLite search and transcript helpers.",
        "Tool search_text succeeded: 3 matches",
    ])
}

private func makeSessionTestRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ashex-session-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
