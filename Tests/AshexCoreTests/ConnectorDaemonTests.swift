@testable import AshexCore
import Foundation
import Testing

@Test func connectorConversationMappingPersistsAcrossStoreInstances() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SQLitePersistenceStore(databaseURL: root.appendingPathComponent("ashex.sqlite"))
    try store.initialize()

    let reference = ConnectorConversationReference(
        connectorKind: "telegram",
        connectorID: "telegram",
        externalConversationID: "12345"
    )

    let firstStore = ConnectorConversationMappingStore(persistence: store)
    let first = try await firstStore.resolveOrCreate(
        reference: reference,
        externalUserID: "user-1",
        createThread: { try store.createThread(now: Date()) }
    )

    let secondStore = ConnectorConversationMappingStore(persistence: store)
    let second = try await secondStore.resolveOrCreate(
        reference: reference,
        externalUserID: "user-1",
        createThread: { try store.createThread(now: Date()) }
    )

    #expect(first.threadID == second.threadID)
}

@Test func runDispatcherUsesExistingThreadForFollowUpRuns() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let persistence = SQLitePersistenceStore(databaseURL: root.appendingPathComponent("ashex.sqlite"))
    try persistence.initialize()
    let thread = try persistence.createThread(now: Date())

    let runtime = try AgentRuntime(
        modelAdapter: SequencedDaemonModelAdapter(actions: [
            .finalAnswer("First reply"),
            .finalAnswer("Second reply"),
        ]),
        toolRegistry: ToolRegistry(tools: []),
        persistence: persistence
    )
    let dispatcher = RunDispatcher(runtime: runtime)

    _ = try await dispatcher.dispatch(prompt: "hello", threadID: thread.id, maxIterations: 1)
    _ = try await dispatcher.dispatch(prompt: "follow up", threadID: thread.id, maxIterations: 1)

    let messages = try persistence.fetchMessages(threadID: thread.id)
    #expect(messages.count == 4)
    #expect(messages.map(\.content).contains("hello"))
    #expect(messages.map(\.content).contains("follow up"))
}

@Test func telegramConnectorNormalizesCommandsFromPrivateTextMessages() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let persistence = SQLitePersistenceStore(databaseURL: root.appendingPathComponent("ashex.sqlite"))
    try persistence.initialize()

    let connector = TelegramConnector(
        token: "test-token",
        config: TelegramConfig(enabled: true),
        client: MockTelegramBotClient(),
        persistence: persistence
    )

    let event = try await connector.normalize(update: TelegramUpdate(
        updateID: 77,
        message: TelegramMessage(
            messageID: 11,
            from: TelegramUser(id: 22, isBot: false, firstName: "Sam", username: "sam"),
            chat: TelegramChat(id: 33, type: "private"),
            date: 0,
            text: "/help"
        )
    ))

    #expect(event?.command == .help)
    #expect(event?.conversation.externalConversationID == "33")
    #expect(event?.externalUserID == "22")
}

@Test func telegramConnectorSkipsDuplicateProcessedUpdates() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let persistence = SQLitePersistenceStore(databaseURL: root.appendingPathComponent("ashex.sqlite"))
    try persistence.initialize()

    let update = TelegramUpdate(
        updateID: 101,
        message: TelegramMessage(
            messageID: 201,
            from: TelegramUser(id: 301, isBot: false, firstName: "Test", username: nil),
            chat: TelegramChat(id: 401, type: "private"),
            date: 0,
            text: "hello"
        )
    )
    let client = MockTelegramBotClient(updates: [[update, update]])
    let connector = TelegramConnector(
        token: "test-token",
        config: TelegramConfig(enabled: true, pollingTimeoutSeconds: 1),
        client: client,
        persistence: persistence
    )

    let counter = Counter()
    try await connector.start { _ in
        await counter.increment()
    }
    try await Task.sleep(nanoseconds: 150_000_000)
    await connector.stop()

    #expect(await counter.value == 1)
}

@Test func connectorMessageIntentClassifierUsesDirectChatForCasualQuestions() {
    #expect(ConnectorMessageIntentClassifier.classify("How are you?") == .directChat)
    #expect(ConnectorMessageIntentClassifier.classify("Tell me a joke") == .directChat)
    #expect(ConnectorMessageIntentClassifier.classify("Summarize this repository") == .workspaceTask)
    #expect(ConnectorMessageIntentClassifier.classify("Can you use curl to fetch https://example.com?") == .workspaceTask)
}

@Test func runDispatcherDirectChatModeAvoidsToolLoopForCasualMessage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let persistence = SQLitePersistenceStore(databaseURL: root.appendingPathComponent("ashex.sqlite"))
    try persistence.initialize()
    let thread = try persistence.createThread(now: Date())

    let runtime = try AgentRuntime(
        modelAdapter: MockModelAdapter(),
        toolRegistry: ToolRegistry(tools: []),
        persistence: persistence
    )
    let dispatcher = RunDispatcher(runtime: runtime)
    let result = try await dispatcher.dispatch(
        prompt: "How are you?",
        threadID: thread.id,
        maxIterations: 1,
        mode: .directChat
    )

    #expect(result.finalText.contains("I'm doing well"))
    let messages = try persistence.fetchMessages(threadID: thread.id)
    #expect(messages.count == 2)
    #expect(messages.last?.role == .assistant)
}

@Test func telegramConnectorActivityHeartbeatStartsAndStopsForTyping() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let persistence = SQLitePersistenceStore(databaseURL: root.appendingPathComponent("ashex.sqlite"))
    try persistence.initialize()

    let client = MockTelegramBotClient()
    let connector = TelegramConnector(
        token: "test-token",
        config: TelegramConfig(enabled: true),
        client: client,
        persistence: persistence
    )
    let conversation = ConnectorConversationReference(
        connectorKind: "telegram",
        connectorID: "telegram",
        externalConversationID: "33"
    )

    try await connector.beginActivity(.typing, for: conversation)
    try await Task.sleep(nanoseconds: 100_000_000)
    await connector.endActivity(.typing, for: conversation)

    let actions = await client.chatActions
    #expect(actions.count == 1)
    #expect(actions.first?.0 == 33)
    #expect(actions.first?.1 == "typing")
}

@Test func telegramMessageFormatterRendersCommonAssistantMarkdownForTelegram() {
    let rendered = TelegramMessageFormatter.format("""
    For example:

    * **Understand the files:** Tell me what `ashex.config.json` does.

    ```swift
    print("hi")
    ```
    """)

    #expect(rendered.contains("<b>Understand the files:</b>"))
    #expect(rendered.contains("<code>ashex.config.json</code>"))
    #expect(rendered.contains("<pre><code>print(\"hi\")</code></pre>"))
}

@Test func telegramConnectorSendsHTMLFormattedMessages() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let persistence = SQLitePersistenceStore(databaseURL: root.appendingPathComponent("ashex.sqlite"))
    try persistence.initialize()

    let client = MockTelegramBotClient()
    let connector = TelegramConnector(
        token: "test-token",
        config: TelegramConfig(enabled: true),
        client: client,
        persistence: persistence
    )
    let conversation = ConnectorConversationReference(
        connectorKind: "telegram",
        connectorID: "telegram",
        externalConversationID: "33"
    )

    try await connector.send(.init(
        connectorID: "telegram",
        conversation: conversation,
        text: "**Hello** from `Ash`"
    ))

    let sentMessages = await client.sentMessages
    #expect(sentMessages.count == 1)
    #expect(sentMessages.first?.0 == 33)
    #expect(sentMessages.first?.1.contains("<b>Hello</b>") == true)
    #expect(sentMessages.first?.2 == "HTML")
}

@Test func telegramChatActionResponseDecodesTelegramBoolPayload() throws {
    let data = """
    {"ok":true,"result":true}
    """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(TelegramBoolResponse.self, from: data)
    #expect(decoded.ok == true)
    #expect(decoded.result == true)
}

private actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor SequencedDaemonModelAdapter: ModelAdapter {
    let name = "daemon-sequenced"
    let providerID = "test"
    let modelID = "daemon-sequenced"
    private var actions: [ModelAction]

    init(actions: [ModelAction]) {
        self.actions = actions
    }

    func nextAction(for context: ModelContext) async throws -> ModelAction {
        guard !actions.isEmpty else {
            throw AshexError.model("No more actions")
        }
        return actions.removeFirst()
    }
}

private actor MockTelegramBotClient: TelegramBotClient {
    private var updates: [[TelegramUpdate]]
    private(set) var sentMessages: [(Int64, String, String?)] = []
    private(set) var chatActions: [(Int64, String)] = []

    init(updates: [[TelegramUpdate]] = []) {
        self.updates = updates
    }

    func getMe(token: String) async throws -> TelegramBotIdentity {
        TelegramBotIdentity(id: 1, isBot: true, firstName: "Test", username: "test_bot")
    }

    func getUpdates(token: String, offset: Int64?, timeoutSeconds: Int) async throws -> [TelegramUpdate] {
        if updates.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
            return []
        }
        return updates.removeFirst()
    }

    func sendMessage(token: String, chatID: Int64, text: String, parseMode: String?) async throws {
        sentMessages.append((chatID, text, parseMode))
    }

    func sendChatAction(token: String, chatID: Int64, action: String) async throws {
        chatActions.append((chatID, action))
    }
}
