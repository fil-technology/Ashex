import Foundation

public actor TelegramConnector: Connector, ConnectorActivityControlling {
    public let id: String
    public let kind: String = "telegram"

    private let token: String
    private let config: TelegramConfig
    private let client: any TelegramBotClient
    private let persistence: PersistenceStore
    private let logger: DaemonLogger?
    private var pollTask: Task<Void, Never>?
    private var activityTasks: [String: Task<Void, Never>] = [:]

    public init(
        id: String = "telegram",
        token: String,
        config: TelegramConfig,
        client: any TelegramBotClient = URLSessionTelegramBotClient(),
        persistence: PersistenceStore,
        logger: DaemonLogger? = nil
    ) {
        self.id = id
        self.token = token
        self.config = config
        self.client = client
        self.persistence = persistence
        self.logger = logger
    }

    public func start(handler: @escaping @Sendable (InboundConnectorEvent) async throws -> Void) async throws {
        guard pollTask == nil else { return }
        pollTask = Task {
            await logger?.log(.info, subsystem: "telegram", message: "Polling started")
            await runPollingLoop(handler: handler)
        }
    }

    public func stop() async {
        pollTask?.cancel()
        pollTask = nil
        await logger?.log(.info, subsystem: "telegram", message: "Polling stopped")
    }

    public func send(_ message: OutboundConnectorMessage) async throws {
        guard let chatID = Int64(message.conversation.externalConversationID) else {
            throw AshexError.model("Invalid Telegram chat ID: \(message.conversation.externalConversationID)")
        }
        for chunk in Self.chunk(text: message.text, limit: 4000) {
            try await client.sendMessage(
                token: token,
                chatID: chatID,
                text: TelegramMessageFormatter.format(chunk),
                parseMode: TelegramMessageFormatter.parseMode
            )
        }
    }

    public func beginActivity(_ activity: ConnectorActivity, for conversation: ConnectorConversationReference) async throws {
        let key = activityKey(activity, conversation: conversation)
        if let existingTask = activityTasks[key], !existingTask.isCancelled {
            return
        }
        guard let chatID = Int64(conversation.externalConversationID) else {
            throw AshexError.model("Invalid Telegram chat ID: \(conversation.externalConversationID)")
        }
        try await sendChatAction(activity, chatID: chatID)
        activityTasks[key] = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 4_000_000_000)
                    try Task.checkCancellation()
                    try await self.sendChatAction(activity, chatID: chatID)
                } catch is CancellationError {
                    return
                } catch {
                    await self.logger?.log(.warning, subsystem: "telegram", message: "Failed to refresh chat activity", metadata: [
                        "chat_id": .string(conversation.externalConversationID),
                        "activity": .string(activity.rawValue),
                        "error": .string(error.localizedDescription),
                    ])
                }
            }
        }
    }

    public func endActivity(_ activity: ConnectorActivity, for conversation: ConnectorConversationReference) async {
        let key = activityKey(activity, conversation: conversation)
        activityTasks[key]?.cancel()
        activityTasks[key] = nil
    }

    public func verifyConnection() async throws -> TelegramBotIdentity {
        try await client.getMe(token: token)
    }

    private func runPollingLoop(handler: @escaping @Sendable (InboundConnectorEvent) async throws -> Void) async {
        while !Task.isCancelled {
            do {
                let offset = try loadNextOffset()
                let updates = try await client.getUpdates(token: token, offset: offset, timeoutSeconds: config.pollingTimeoutSeconds)
                if updates.isEmpty {
                    continue
                }
                for update in updates.sorted(by: { $0.updateID < $1.updateID }) {
                    try Task.checkCancellation()
                    let nextOffset = update.updateID + 1
                    if try isProcessed(updateID: update.updateID) {
                        try persistNextOffset(nextOffset)
                        continue
                    }
                    guard let event = try await normalize(update: update) else {
                        try markProcessed(updateID: update.updateID)
                        try persistNextOffset(nextOffset)
                        continue
                    }
                    try await handler(event)
                    try markProcessed(updateID: update.updateID)
                    try persistNextOffset(nextOffset)
                }
            } catch is CancellationError {
                return
            } catch {
                await logger?.log(.error, subsystem: "telegram", message: "Polling failed", metadata: [
                    "error": .string(error.localizedDescription),
                ])
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func normalize(update: TelegramUpdate) async throws -> InboundConnectorEvent? {
        guard let message = update.message else {
            await logger?.log(.debug, subsystem: "telegram", message: "Skipping non-message update", metadata: [
                "update_id": .string(String(update.updateID)),
            ])
            return nil
        }

        guard message.chat.type == "private" else {
            await logger?.log(.info, subsystem: "telegram", message: "Skipping non-private chat", metadata: [
                "chat_id": .string(String(message.chat.id)),
                "chat_type": .string(message.chat.type),
            ])
            return nil
        }

        guard let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            await logger?.log(.info, subsystem: "telegram", message: "Skipping unsupported message", metadata: [
                "chat_id": .string(String(message.chat.id)),
                "message_id": .string(String(message.messageID)),
            ])
            return nil
        }

        let chatID = String(message.chat.id)
        let userID = message.from.map { String($0.id) }
        let access = Self.evaluateAccess(config: config, chatID: chatID, userID: userID)
        guard access.allowed else {
            await logger?.log(.warning, subsystem: "telegram", message: "Rejected message by Telegram access gate", metadata: [
                "chat_id": .string(chatID),
                "user_id": .string(userID ?? "<unknown>"),
                "reason": .string(access.reason),
            ])
            try? await client.sendMessage(
                token: token,
                chatID: message.chat.id,
                text: TelegramMessageFormatter.format(Self.accessDeniedMessage(chatID: chatID, userID: userID)),
                parseMode: TelegramMessageFormatter.parseMode
            )
            return nil
        }

        let command = Self.command(from: text)
        return InboundConnectorEvent(
            connectorKind: kind,
            connectorID: id,
            messageID: String(update.updateID),
            conversation: .init(connectorKind: kind, connectorID: id, externalConversationID: chatID),
            externalUserID: userID,
            text: text,
            command: command,
            metadata: [
                "telegram_update_id": .string(String(update.updateID)),
                "telegram_message_id": .string(String(message.messageID)),
            ]
        )
    }

    private func loadNextOffset() throws -> Int64? {
        try persistence.fetchSetting(namespace: stateNamespace, key: "next_offset")?.value.stringValue.flatMap(Int64.init)
    }

    private func persistNextOffset(_ nextOffset: Int64) throws {
        try persistence.upsertSetting(namespace: stateNamespace, key: "next_offset", value: .string(String(nextOffset)), now: Date())
    }

    private func isProcessed(updateID: Int64) throws -> Bool {
        try persistence.fetchSetting(namespace: stateNamespace, key: processedKey(for: updateID)) != nil
    }

    private func markProcessed(updateID: Int64) throws {
        try persistence.upsertSetting(namespace: stateNamespace, key: processedKey(for: updateID), value: .bool(true), now: Date())
    }

    private var stateNamespace: String {
        "connectors.telegram.\(id)"
    }

    private func processedKey(for updateID: Int64) -> String {
        "processed_update_\(updateID)"
    }

    private static func command(from text: String) -> ConnectorCommand? {
        guard text.hasPrefix("/") else { return nil }
        let raw = text.dropFirst().split(separator: " ").first?.split(separator: "@").first.map(String.init)?.lowercased()
        if raw == "tokenstats" {
            return .stats
        }
        if raw == "statson" {
            return .statsOn
        }
        if raw == "statsoff" {
            return .statsOff
        }
        return raw.flatMap(ConnectorCommand.init(rawValue:))
    }

    private static func chunk(text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var remaining = text[...]
        var chunks: [String] = []
        while remaining.count > limit {
            let endIndex = remaining.index(remaining.startIndex, offsetBy: limit)
            chunks.append(String(remaining[..<endIndex]))
            remaining = remaining[endIndex...]
        }
        if !remaining.isEmpty {
            chunks.append(String(remaining))
        }
        return chunks
    }

    private func sendChatAction(_ activity: ConnectorActivity, chatID: Int64) async throws {
        try await client.sendChatAction(token: token, chatID: chatID, action: activity.rawValue)
    }

    private func activityKey(_ activity: ConnectorActivity, conversation: ConnectorConversationReference) -> String {
        "\(activity.rawValue):\(conversation.externalConversationID)"
    }

    private static func evaluateAccess(config: TelegramConfig, chatID: String, userID: String?) -> (allowed: Bool, reason: String) {
        switch config.accessMode {
        case .open:
            return (true, "open")
        case .allowlist:
            let hasChatAllowlist = !config.allowedChatIDs.isEmpty
            let hasUserAllowlist = !config.allowedUserIDs.isEmpty
            guard hasChatAllowlist || hasUserAllowlist else {
                return (false, "allowlist is enabled but no chat or user IDs are configured")
            }
            if hasChatAllowlist, !config.allowedChatIDs.contains(chatID) {
                return (false, "chat is not on the allowlist")
            }
            if hasUserAllowlist {
                guard let userID else {
                    return (false, "message did not include a Telegram user ID")
                }
                if !config.allowedUserIDs.contains(userID) {
                    return (false, "user is not on the allowlist")
                }
            }
            return (true, "allowlisted")
        }
    }

    private static func accessDeniedMessage(chatID: String, userID: String?) -> String {
        let renderedUserID = userID ?? "<unknown>"
        return """
        This Telegram bot is currently gated.

        To allow this chat in Ashex, add these IDs in `Assistant Setup`:

        - `Telegram Chats`: `\(chatID)`
        - `Telegram Users`: `\(renderedUserID)`

        Or add them directly in `ashex.config.json` under:
        - `telegram.allowedChatIDs`
        - `telegram.allowedUserIDs`

        After saving, restart the daemon.
        """
    }
}
