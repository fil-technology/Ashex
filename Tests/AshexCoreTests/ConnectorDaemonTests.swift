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
    private(set) var sentMessages: [(Int64, String)] = []

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

    func sendMessage(token: String, chatID: Int64, text: String) async throws {
        sentMessages.append((chatID, text))
    }
}
