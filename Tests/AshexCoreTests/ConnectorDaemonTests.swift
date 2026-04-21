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

@Test func telegramConnectorNormalizesWhoAmICommand() async throws {
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
        updateID: 78,
        message: TelegramMessage(
            messageID: 12,
            from: TelegramUser(id: 44, isBot: false, firstName: "Sam", username: "sam"),
            chat: TelegramChat(id: 55, type: "private"),
            date: 0,
            text: "/whoami"
        )
    ))

    #expect(event?.command == .whoami)
    #expect(event?.conversation.externalConversationID == "55")
    #expect(event?.externalUserID == "44")
}

@Test func telegramConnectorNormalizesPhotoMessagesIntoAttachmentPrompt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let persistence = SQLitePersistenceStore(databaseURL: root.appendingPathComponent("ashex.sqlite"))
    try persistence.initialize()

    let client = MockTelegramBotClient(
        filesByID: [
            "photo-file": TelegramFile(
                fileID: "photo-file",
                fileUniqueID: "photo-uniq",
                fileSize: 128,
                filePath: "photos/demo.jpg"
            )
        ],
        fileDataByPath: [
            "photos/demo.jpg": Data([0x01, 0x02, 0x03])
        ]
    )
    let mediaRoot = root.appendingPathComponent("telegram-media", isDirectory: true)
    let connector = TelegramConnector(
        token: "test-token",
        config: TelegramConfig(enabled: true),
        client: client,
        persistence: persistence,
        mediaRoot: mediaRoot
    )

    let event = try await connector.normalize(update: TelegramUpdate(
        updateID: 81,
        message: TelegramMessage(
            messageID: 15,
            from: TelegramUser(id: 44, isBot: false, firstName: "Sam", username: "sam"),
            chat: TelegramChat(id: 55, type: "private"),
            date: 0,
            text: nil,
            caption: "What is in this image?",
            photo: [
                TelegramPhotoSize(fileID: "photo-file", fileUniqueID: "photo-uniq", width: 1024, height: 768, fileSize: 128)
            ],
            voice: nil,
            audio: nil,
            document: nil
        )
    ))

    #expect(event?.command == nil)
    #expect(event?.text.contains("Telegram image attachment") == true)
    #expect(event?.text.contains("Caption: What is in this image?") == true)
    #expect(event?.attachments.count == 1)
    #expect(event?.attachments.first?.kind == .image)
    #expect(event?.metadata["telegram_media_kind"]?.stringValue == "image")
    let localPath = try #require(event?.metadata["local_path"]?.stringValue)
    #expect(event?.attachments.first?.localPath == localPath)
    #expect(FileManager.default.fileExists(atPath: localPath))
}

@Test func telegramConnectorNormalizesVoiceMessagesIntoAttachmentPrompt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let persistence = SQLitePersistenceStore(databaseURL: root.appendingPathComponent("ashex.sqlite"))
    try persistence.initialize()

    let client = MockTelegramBotClient(
        filesByID: [
            "voice-file": TelegramFile(
                fileID: "voice-file",
                fileUniqueID: "voice-uniq",
                fileSize: 256,
                filePath: "voice/demo.ogg"
            )
        ],
        fileDataByPath: [
            "voice/demo.ogg": Data([0x10, 0x20, 0x30])
        ]
    )
    let mediaRoot = root.appendingPathComponent("telegram-media", isDirectory: true)
    let connector = TelegramConnector(
        token: "test-token",
        config: TelegramConfig(enabled: true),
        client: client,
        persistence: persistence,
        mediaRoot: mediaRoot
    )

    let event = try await connector.normalize(update: TelegramUpdate(
        updateID: 82,
        message: TelegramMessage(
            messageID: 16,
            from: TelegramUser(id: 44, isBot: false, firstName: "Sam", username: "sam"),
            chat: TelegramChat(id: 55, type: "private"),
            date: 0,
            text: nil,
            caption: nil,
            photo: nil,
            voice: TelegramVoice(fileID: "voice-file", fileUniqueID: "voice-uniq", duration: 4, mimeType: "audio/ogg", fileSize: 256),
            audio: nil,
            document: nil
        )
    ))

    #expect(event?.command == nil)
    #expect(event?.text.contains("Telegram audio attachment") == true)
    #expect(event?.attachments.count == 1)
    #expect(event?.attachments.first?.kind == .audio)
    #expect(event?.metadata["telegram_media_kind"]?.stringValue == "audio")
    #expect(event?.metadata["duration_seconds"]?.intValue == 4)
    let localPath = try #require(event?.metadata["local_path"]?.stringValue)
    #expect(event?.attachments.first?.localPath == localPath)
    #expect(FileManager.default.fileExists(atPath: localPath))
}

@Test func telegramConnectorNormalizesTasksAndChatsCommands() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let persistence = SQLitePersistenceStore(databaseURL: root.appendingPathComponent("ashex.sqlite"))
    try persistence.initialize()

    let connector = TelegramConnector(
        token: "test-token",
        config: TelegramConfig(enabled: true),
        client: MockTelegramBotClient(),
        persistence: persistence
    )

    let tasksEvent = try await connector.normalize(update: TelegramUpdate(
        updateID: 79,
        message: TelegramMessage(
            messageID: 13,
            from: TelegramUser(id: 44, isBot: false, firstName: "Sam", username: "sam"),
            chat: TelegramChat(id: 55, type: "private"),
            date: 0,
            text: "/tasks"
        )
    ))
    let chatsEvent = try await connector.normalize(update: TelegramUpdate(
        updateID: 80,
        message: TelegramMessage(
            messageID: 14,
            from: TelegramUser(id: 44, isBot: false, firstName: "Sam", username: "sam"),
            chat: TelegramChat(id: 55, type: "private"),
            date: 0,
            text: "/chats"
        )
    ))

    #expect(tasksEvent?.command == .tasks)
    #expect(chatsEvent?.command == .chats)
}

@Test func telegramConnectorRepliesWithOnboardingForUnauthorizedChat() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let persistence = SQLitePersistenceStore(databaseURL: root.appendingPathComponent("ashex.sqlite"))
    try persistence.initialize()

    let client = MockTelegramBotClient()
    let connector = TelegramConnector(
        token: "test-token",
        config: TelegramConfig(
            enabled: true,
            accessMode: .allowlist,
            allowedChatIDs: ["999"],
            allowedUserIDs: ["888"]
        ),
        client: client,
        persistence: persistence
    )

    let event = try await connector.normalize(update: TelegramUpdate(
        updateID: 77,
        message: TelegramMessage(
            messageID: 11,
            from: TelegramUser(id: 22, isBot: false, firstName: "Sam", username: "sam"),
            chat: TelegramChat(id: 33, type: "private"),
            date: 0,
            text: "/start"
        )
    ))

    #expect(event == nil)
    let sent = await client.sentMessages
    #expect(sent.count == 1)
    #expect(sent.first?.0 == 33)
    #expect(sent.first?.1.contains("This Telegram bot is currently gated.") == true)
    #expect(sent.first?.1.contains("Telegram Chats") == true)
    #expect(sent.first?.1.contains("33") == true)
    #expect(sent.first?.1.contains("22") == true)
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
    #expect(ConnectorMessageIntentClassifier.classify("Summarize this repository") == .directChat)
    #expect(ConnectorMessageIntentClassifier.classify("Can you use curl to fetch https://example.com?") == .workspaceTask)
    #expect(ConnectorMessageIntentClassifier.classify("What are the files in current directory?") == .workspaceTask)
    #expect(ConnectorMessageIntentClassifier.classify("List files of the project") == .workspaceTask)
    #expect(ConnectorMessageIntentClassifier.classify("Search for the weather in Petah Tikva Israel") == .workspaceTask)
    #expect(ConnectorMessageIntentClassifier.classify("Give me simple swift hello world app code") == .directChat)
    #expect(ConnectorMessageIntentClassifier.classify("What this repo is about?") == .directChat)
    #expect(ConnectorMessageIntentClassifier.classify("What this repo is about: https://github.com/Eronred/aso-skills") == .workspaceTask)
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
    let usage = try SessionInspector(persistence: persistence).loadTokenUsage(runID: try #require(result.runID))
    #expect(usage?.currentRun.usedTokenCount ?? 0 > 0)
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

@Test func daemonSupervisorStopCommandCancelsActiveConversationRun() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let persistence = SQLitePersistenceStore(databaseURL: root.appendingPathComponent("ashex.sqlite"))
    try persistence.initialize()

    let runtime = BlockingRuntime()
    let dispatcher = RunDispatcher(runtime: runtime)
    let connector = RecordingConnector()
    let registry = ConnectorRegistry(connectors: [connector])
    let runStore = DaemonConversationRunStore()
    let approvalInbox = RemoteApprovalInbox(persistence: persistence)
    let supervisor = DaemonSupervisor(
        registry: registry,
        router: ConversationRouter(mappingStore: ConnectorConversationMappingStore(persistence: persistence)),
        dispatcher: dispatcher,
        persistence: persistence,
        logger: DaemonLogger(minimumLevel: .error),
        runStore: runStore,
        remoteApprovalInbox: approvalInbox,
        config: .init(maxIterations: 2, connectorLabel: "telegram")
    )

    let conversation = ConnectorConversationReference(
        connectorKind: "telegram",
        connectorID: "telegram",
        externalConversationID: "chat-33"
    )
    let promptEvent = InboundConnectorEvent(
        connectorKind: "telegram",
        connectorID: "telegram",
        messageID: "1001",
        conversation: conversation,
        externalUserID: "44",
        text: "please keep working",
        command: nil
    )
    try await supervisor.handle(promptEvent)
    try await Task.sleep(nanoseconds: 100_000_000)

    let stopEvent = InboundConnectorEvent(
        connectorKind: "telegram",
        connectorID: "telegram",
        messageID: "1002",
        conversation: conversation,
        externalUserID: "44",
        text: "/stop",
        command: .stop
    )
    try await supervisor.handle(stopEvent)
    try await Task.sleep(nanoseconds: 200_000_000)

    let sentMessages = await connector.recordedMessages()
    #expect(sentMessages.contains { $0.text.contains("Stopping the current run.") })
    #expect(await runStore.status(for: conversation) == nil)
}

@Test func daemonSupervisorStatsCommandPersistsPerChatToggle() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let persistence = SQLitePersistenceStore(databaseURL: root.appendingPathComponent("ashex.sqlite"))
    try persistence.initialize()

    let supervisor = DaemonSupervisor(
        registry: ConnectorRegistry(connectors: [RecordingConnector()]),
        router: ConversationRouter(mappingStore: ConnectorConversationMappingStore(persistence: persistence)),
        dispatcher: RunDispatcher(runtime: BlockingRuntime()),
        persistence: persistence,
        logger: DaemonLogger(minimumLevel: .error),
        runStore: DaemonConversationRunStore(),
        remoteApprovalInbox: RemoteApprovalInbox(persistence: persistence),
        config: .init(maxIterations: 2, connectorLabel: "telegram")
    )

    let conversation = ConnectorConversationReference(
        connectorKind: "telegram",
        connectorID: "telegram",
        externalConversationID: "chat-99"
    )

    try await supervisor.handle(.init(
        connectorKind: "telegram",
        connectorID: "telegram",
        messageID: "2001",
        conversation: conversation,
        externalUserID: "44",
        text: "/stats off",
        command: .stats
    ))

    let setting = try persistence.fetchSetting(namespace: "connectors.telegram.stats.telegram.chat-99", key: "enabled")
    #expect(setting?.value.boolValue == false)
}

@Test func daemonSupervisorModelCommandSwitchesActiveModel() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let persistence = SQLitePersistenceStore(databaseURL: root.appendingPathComponent("ashex.sqlite"))
    try persistence.initialize()

    let connector = RecordingConnector()
    let switchedModels = LockedValues<String>()
    let supervisor = DaemonSupervisor(
        registry: ConnectorRegistry(connectors: [connector]),
        router: ConversationRouter(mappingStore: ConnectorConversationMappingStore(persistence: persistence)),
        dispatcher: RunDispatcher(runtime: BlockingRuntime()),
        persistence: persistence,
        logger: DaemonLogger(minimumLevel: .error),
        runStore: DaemonConversationRunStore(),
        remoteApprovalInbox: RemoteApprovalInbox(persistence: persistence),
        modelControl: .init(
            listModels: { ["gemma4:latest", "functiongemma:latest"] },
            switchModel: { requestedModel in
                await switchedModels.append(requestedModel)
            }
        ),
        config: .init(maxIterations: 2, connectorLabel: "telegram", provider: "ollama", model: "llama3.2")
    )

    let conversation = ConnectorConversationReference(
        connectorKind: "telegram",
        connectorID: "telegram",
        externalConversationID: "chat-77"
    )

    try await supervisor.handle(.init(
        connectorKind: "telegram",
        connectorID: "telegram",
        messageID: "3001",
        conversation: conversation,
        externalUserID: "44",
        text: "/model gemma4:latest",
        command: .model
    ))

    let sentMessages = await connector.recordedMessages()
    #expect(await switchedModels.values == ["gemma4:latest"])
    #expect(sentMessages.contains { $0.text.contains("Switched model to `gemma4:latest`") })
}

@Test func daemonSupervisorModelsCommandListsAvailableModels() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let persistence = SQLitePersistenceStore(databaseURL: root.appendingPathComponent("ashex.sqlite"))
    try persistence.initialize()

    let connector = RecordingConnector()
    let supervisor = DaemonSupervisor(
        registry: ConnectorRegistry(connectors: [connector]),
        router: ConversationRouter(mappingStore: ConnectorConversationMappingStore(persistence: persistence)),
        dispatcher: RunDispatcher(runtime: BlockingRuntime()),
        persistence: persistence,
        logger: DaemonLogger(minimumLevel: .error),
        runStore: DaemonConversationRunStore(),
        remoteApprovalInbox: RemoteApprovalInbox(persistence: persistence),
        modelControl: .init(
            listModels: { ["gemma4:latest", "functiongemma:latest"] },
            switchModel: { _ in }
        ),
        config: .init(maxIterations: 2, connectorLabel: "telegram", provider: "ollama", model: "gemma4:latest")
    )

    let conversation = ConnectorConversationReference(
        connectorKind: "telegram",
        connectorID: "telegram",
        externalConversationID: "chat-78"
    )

    try await supervisor.handle(.init(
        connectorKind: "telegram",
        connectorID: "telegram",
        messageID: "3002",
        conversation: conversation,
        externalUserID: "44",
        text: "/models",
        command: .models
    ))

    let sentMessages = await connector.recordedMessages()
    #expect(sentMessages.contains { $0.text.contains("Available models for `ollama`") })
    #expect(sentMessages.contains { $0.text.contains("`gemma4:latest` ← current") })
}

@Test func daemonSupervisorListsAndSwitchesThreadsWithinTelegramChat() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let persistence = SQLitePersistenceStore(databaseURL: root.appendingPathComponent("ashex.sqlite"))
    try persistence.initialize()

    let mappingStore = ConnectorConversationMappingStore(persistence: persistence)
    let router = ConversationRouter(mappingStore: mappingStore)
    let connector = RecordingConnector()
    let supervisor = DaemonSupervisor(
        registry: ConnectorRegistry(connectors: [connector]),
        router: router,
        dispatcher: RunDispatcher(runtime: BlockingRuntime()),
        persistence: persistence,
        logger: DaemonLogger(minimumLevel: .error),
        runStore: DaemonConversationRunStore(),
        remoteApprovalInbox: RemoteApprovalInbox(persistence: persistence),
        config: .init(maxIterations: 2, connectorLabel: "telegram", provider: "ollama", model: "gemma4:latest")
    )

    let conversation = ConnectorConversationReference(
        connectorKind: "telegram",
        connectorID: "telegram",
        externalConversationID: "chat-threads"
    )

    _ = try await router.resolveConversation(
        for: conversation,
        externalUserID: "44",
        createThread: { try persistence.createThread(now: Date()) }
    )
    _ = try await router.resetConversation(for: conversation)

    try await supervisor.handle(.init(
        connectorKind: "telegram",
        connectorID: "telegram",
        messageID: "4001",
        conversation: conversation,
        externalUserID: "44",
        text: "/threads",
        command: .threads
    ))

    try await supervisor.handle(.init(
        connectorKind: "telegram",
        connectorID: "telegram",
        messageID: "4002",
        conversation: conversation,
        externalUserID: "44",
        text: "/thread 2",
        command: .thread
    ))

    let sentMessages = await connector.recordedMessages()
    #expect(sentMessages.contains { $0.text.contains("Threads in this chat:") })
    #expect(sentMessages.contains { $0.text.contains("Switched to thread `2`") })
}

@Test func daemonSupervisorWhoAmICommandShowsTelegramIDs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let persistence = SQLitePersistenceStore(databaseURL: root.appendingPathComponent("ashex.sqlite"))
    try persistence.initialize()

    let connector = RecordingConnector()
    let supervisor = DaemonSupervisor(
        registry: ConnectorRegistry(connectors: [connector]),
        router: ConversationRouter(mappingStore: ConnectorConversationMappingStore(persistence: persistence)),
        dispatcher: RunDispatcher(runtime: BlockingRuntime()),
        persistence: persistence,
        logger: DaemonLogger(minimumLevel: .error),
        runStore: DaemonConversationRunStore(),
        remoteApprovalInbox: RemoteApprovalInbox(persistence: persistence),
        config: .init(maxIterations: 2, connectorLabel: "telegram", provider: "ollama", model: "gemma4:latest")
    )

    try await supervisor.handle(.init(
        connectorKind: "telegram",
        connectorID: "telegram",
        messageID: "4010",
        conversation: .init(connectorKind: "telegram", connectorID: "telegram", externalConversationID: "123456"),
        externalUserID: "654321",
        text: "/whoami",
        command: .whoami
    ))

    let sentMessages = await connector.recordedMessages()
    #expect(sentMessages.contains { $0.text.contains("Chat ID: `123456`") })
    #expect(sentMessages.contains { $0.text.contains("User ID: `654321`") })
}

@Test func daemonSupervisorTasksAndChatsCommandsShowGlobalTelegramState() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let persistence = SQLitePersistenceStore(databaseURL: root.appendingPathComponent("ashex.sqlite"))
    try persistence.initialize()

    let mappingStore = ConnectorConversationMappingStore(persistence: persistence)
    let router = ConversationRouter(mappingStore: mappingStore)
    let connector = RecordingConnector()
    let runStore = DaemonConversationRunStore()
    let supervisor = DaemonSupervisor(
        registry: ConnectorRegistry(connectors: [connector]),
        router: router,
        dispatcher: RunDispatcher(runtime: BlockingRuntime()),
        persistence: persistence,
        logger: DaemonLogger(minimumLevel: .error),
        runStore: runStore,
        remoteApprovalInbox: RemoteApprovalInbox(persistence: persistence),
        config: .init(maxIterations: 2, connectorLabel: "telegram", provider: "ollama", model: "gemma4:latest")
    )

    let conversationA = ConnectorConversationReference(
        connectorKind: "telegram",
        connectorID: "telegram",
        externalConversationID: "chat-a"
    )
    let conversationB = ConnectorConversationReference(
        connectorKind: "telegram",
        connectorID: "telegram",
        externalConversationID: "chat-b"
    )
    let mappingA = try await router.resolveConversation(
        for: conversationA,
        externalUserID: "user-a",
        createThread: { try persistence.createThread(now: Date()) }
    )
    _ = try await router.resolveConversation(
        for: conversationB,
        externalUserID: "user-b",
        createThread: { try persistence.createThread(now: Date()) }
    )

    _ = await runStore.beginRun(
        for: conversationB,
        threadID: mappingA.threadID,
        prompt: "Investigate daemon startup and summarize next steps",
        cancellationToken: CancellationToken()
    )

    try await supervisor.handle(.init(
        connectorKind: "telegram",
        connectorID: "telegram",
        messageID: "4020",
        conversation: conversationA,
        externalUserID: "user-a",
        text: "/tasks",
        command: .tasks
    ))
    try await supervisor.handle(.init(
        connectorKind: "telegram",
        connectorID: "telegram",
        messageID: "4021",
        conversation: conversationA,
        externalUserID: "user-a",
        text: "/chats",
        command: .chats
    ))

    let sentMessages = await connector.recordedMessages()
    #expect(sentMessages.contains { $0.text.contains("Active tasks:") })
    #expect(sentMessages.contains { $0.text.contains("chat `chat-b`") })
    #expect(sentMessages.contains { $0.text.contains("Known chats:") })
    #expect(sentMessages.contains { $0.text.contains("chat `chat-a`") })
}

@Test func telegramConnectorNormalizesStatsAliases() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let persistence = SQLitePersistenceStore(databaseURL: root.appendingPathComponent("ashex.sqlite"))
    try persistence.initialize()

    let connector = TelegramConnector(
        token: "test-token",
        config: TelegramConfig(enabled: true),
        client: MockTelegramBotClient(),
        persistence: persistence
    )

    let statsOnEvent = try await connector.normalize(update: TelegramUpdate(
        updateID: 78,
        message: TelegramMessage(
            messageID: 12,
            from: TelegramUser(id: 22, isBot: false, firstName: "Sam", username: "sam"),
            chat: TelegramChat(id: 33, type: "private"),
            date: 0,
            text: "/statson"
        )
    ))
    let statsOffEvent = try await connector.normalize(update: TelegramUpdate(
        updateID: 79,
        message: TelegramMessage(
            messageID: 13,
            from: TelegramUser(id: 22, isBot: false, firstName: "Sam", username: "sam"),
            chat: TelegramChat(id: 33, type: "private"),
            date: 0,
            text: "/statsoff"
        )
    ))

    #expect(statsOnEvent?.command == .statsOn)
    #expect(statsOffEvent?.command == .statsOff)
}

@Test func telegramConnectorNormalizesReasoningAliases() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let persistence = SQLitePersistenceStore(databaseURL: root.appendingPathComponent("ashex.sqlite"))
    try persistence.initialize()

    let connector = TelegramConnector(
        token: "test-token",
        config: TelegramConfig(enabled: true),
        client: MockTelegramBotClient(),
        persistence: persistence
    )

    let reasoningEvent = try await connector.normalize(update: TelegramUpdate(
        updateID: 80,
        message: TelegramMessage(
            messageID: 14,
            from: TelegramUser(id: 22, isBot: false, firstName: "Sam", username: "sam"),
            chat: TelegramChat(id: 33, type: "private"),
            date: 0,
            text: "/reasoning"
        )
    ))
    let reasoningOnEvent = try await connector.normalize(update: TelegramUpdate(
        updateID: 81,
        message: TelegramMessage(
            messageID: 15,
            from: TelegramUser(id: 22, isBot: false, firstName: "Sam", username: "sam"),
            chat: TelegramChat(id: 33, type: "private"),
            date: 0,
            text: "/reasoningon"
        )
    ))
    let reasoningOffEvent = try await connector.normalize(update: TelegramUpdate(
        updateID: 82,
        message: TelegramMessage(
            messageID: 16,
            from: TelegramUser(id: 22, isBot: false, firstName: "Sam", username: "sam"),
            chat: TelegramChat(id: 33, type: "private"),
            date: 0,
            text: "/reasoningoff"
        )
    ))

    #expect(reasoningEvent?.command == .reasoning)
    #expect(reasoningOnEvent?.command == .reasoningOn)
    #expect(reasoningOffEvent?.command == .reasoningOff)
}

@Test func daemonSupervisorReasoningCommandPersistsPerChatToggle() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let persistence = SQLitePersistenceStore(databaseURL: root.appendingPathComponent("ashex.sqlite"))
    try persistence.initialize()

    let supervisor = DaemonSupervisor(
        registry: ConnectorRegistry(connectors: [RecordingConnector()]),
        router: ConversationRouter(mappingStore: ConnectorConversationMappingStore(persistence: persistence)),
        dispatcher: RunDispatcher(runtime: BlockingRuntime()),
        persistence: persistence,
        logger: DaemonLogger(minimumLevel: .error),
        runStore: DaemonConversationRunStore(),
        remoteApprovalInbox: RemoteApprovalInbox(persistence: persistence),
        config: .init(maxIterations: 2, connectorLabel: "telegram")
    )

    let conversation = ConnectorConversationReference(
        connectorKind: "telegram",
        connectorID: "telegram",
        externalConversationID: "chat-101"
    )

    try await supervisor.handle(.init(
        connectorKind: "telegram",
        connectorID: "telegram",
        messageID: "2101",
        conversation: conversation,
        externalUserID: "44",
        text: "/reasoning on",
        command: .reasoning
    ))

    let setting = try persistence.fetchSetting(namespace: "connectors.telegram.reasoning.telegram.chat-101", key: "enabled")
    #expect(setting?.value.boolValue == true)
}

@Test func daemonSupervisorAppendsReasoningSummaryWhenEnabled() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let persistence = SQLitePersistenceStore(databaseURL: root.appendingPathComponent("ashex.sqlite"))
    try persistence.initialize()

    let connector = RecordingConnector()
    let supervisor = DaemonSupervisor(
        registry: ConnectorRegistry(connectors: [connector]),
        router: ConversationRouter(mappingStore: ConnectorConversationMappingStore(persistence: persistence)),
        dispatcher: RunDispatcher(runtime: ReasoningRuntime()),
        persistence: persistence,
        logger: DaemonLogger(minimumLevel: .error),
        runStore: DaemonConversationRunStore(),
        remoteApprovalInbox: RemoteApprovalInbox(persistence: persistence),
        config: .init(maxIterations: 2, connectorLabel: "telegram", provider: "ollama", model: "gemma4:latest")
    )

    let conversation = ConnectorConversationReference(
        connectorKind: "telegram",
        connectorID: "telegram",
        externalConversationID: "chat-reasoning"
    )

    try persistence.upsertSetting(
        namespace: "connectors.telegram.reasoning.telegram.chat-reasoning",
        key: "enabled",
        value: .bool(true),
        now: Date()
    )
    try persistence.upsertSetting(
        namespace: "connectors.telegram.stats.telegram.chat-reasoning",
        key: "enabled",
        value: .bool(false),
        now: Date()
    )

    try await supervisor.handle(.init(
        connectorKind: "telegram",
        connectorID: "telegram",
        messageID: "2201",
        conversation: conversation,
        externalUserID: "44",
        text: "How are you?",
        command: nil
    ))

    try await Task.sleep(nanoseconds: 150_000_000)

    let sentMessages = await connector.recordedMessages()
    #expect(sentMessages.contains { $0.text.contains("Final reply") })
    #expect(sentMessages.contains { $0.text.contains("Reasoning: analyzed the request") })
}

@Test func daemonTelegramFailureFormatterExplainsModelTimeouts() {
    let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
    let message = DaemonTelegramFailureFormatter.message(for: error)

    #expect(message.contains("model or provider request timed out"))
    #expect(message.contains("ollama.requestTimeoutSeconds"))
}

@Test func daemonTelegramFailureFormatterExplainsToolTimeouts() {
    let message = DaemonTelegramFailureFormatter.message(for: AshexError.shell("Command timed out after 30s"))

    #expect(message.contains("tool run timed out"))
    #expect(message.contains("Details: Command timed out after 30s"))
}

@Test func daemonTelegramFailureFormatterExplainsConnectorTimeouts() {
    let message = DaemonTelegramFailureFormatter.message(for: AshexError.model("Telegram sendMessage timed out"))

    #expect(message.contains("Telegram connector timed out"))
    #expect(message.contains("daemon is still running"))
}

private actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor RecordingConnector: Connector, ConnectorActivityControlling {
    let id = "telegram"
    let kind = "telegram"
    private var messages: [OutboundConnectorMessage] = []

    func start(handler: @escaping @Sendable (InboundConnectorEvent) async throws -> Void) async throws {}

    func stop() async {}

    func send(_ message: OutboundConnectorMessage) async throws {
        messages.append(message)
    }

    func beginActivity(_ activity: ConnectorActivity, for conversation: ConnectorConversationReference) async throws {}

    func endActivity(_ activity: ConnectorActivity, for conversation: ConnectorConversationReference) async {}

    func recordedMessages() -> [OutboundConnectorMessage] {
        messages
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

private struct BlockingRuntime: RuntimeStreaming, Sendable {
    func run(_ request: RunRequest) -> AsyncStream<RuntimeEvent> {
        AsyncStream { continuation in
            let threadID = request.threadID ?? UUID()
            let runID = UUID()
            continuation.yield(.init(payload: .runStarted(threadID: threadID, runID: runID)))
            continuation.yield(.init(payload: .runStateChanged(runID: runID, state: .running, reason: nil)))
            Task {
                while true {
                    do {
                        try await request.cancellationToken?.checkCancellation()
                    } catch {
                        continuation.yield(.init(payload: .error(runID: runID, message: "Cancelled")))
                        continuation.finish()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 25_000_000)
                }
            }
        }
    }
}

private struct ReasoningRuntime: RuntimeStreaming, Sendable {
    func run(_ request: RunRequest) -> AsyncStream<RuntimeEvent> {
        AsyncStream { continuation in
            let threadID = request.threadID ?? UUID()
            let runID = UUID()
            continuation.yield(.init(payload: .runStarted(threadID: threadID, runID: runID)))
            continuation.yield(.init(payload: .status(runID: runID, message: "Thinking about the reply")))
            continuation.yield(.init(payload: .status(runID: runID, message: "Reasoning summary: analyzed the request, considered what to inspect or use, and formed a short approach.")))
            continuation.yield(.init(payload: .finalAnswer(runID: runID, messageID: UUID(), text: "Final reply")))
            continuation.finish()
        }
    }
}

private actor MockTelegramBotClient: TelegramBotClient {
    private var updates: [[TelegramUpdate]]
    private let filesByID: [String: TelegramFile]
    private let fileDataByPath: [String: Data]
    private(set) var sentMessages: [(Int64, String, String?)] = []
    private(set) var chatActions: [(Int64, String)] = []

    init(
        updates: [[TelegramUpdate]] = [],
        filesByID: [String: TelegramFile] = [:],
        fileDataByPath: [String: Data] = [:]
    ) {
        self.updates = updates
        self.filesByID = filesByID
        self.fileDataByPath = fileDataByPath
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

    func getFile(token: String, fileID: String) async throws -> TelegramFile {
        guard let file = filesByID[fileID] else {
            throw AshexError.model("Missing mocked Telegram file for \(fileID)")
        }
        return file
    }

    func downloadFile(token: String, filePath: String) async throws -> Data {
        guard let data = fileDataByPath[filePath] else {
            throw AshexError.model("Missing mocked Telegram file data for \(filePath)")
        }
        return data
    }

    func sendMessage(token: String, chatID: Int64, text: String, parseMode: String?) async throws {
        sentMessages.append((chatID, text, parseMode))
    }

    func sendChatAction(token: String, chatID: Int64, action: String) async throws {
        chatActions.append((chatID, action))
    }
}

private actor LockedValues<T: Sendable> {
    private var storage: [T] = []

    func append(_ value: T) {
        storage.append(value)
    }

    var values: [T] {
        storage
    }
}
