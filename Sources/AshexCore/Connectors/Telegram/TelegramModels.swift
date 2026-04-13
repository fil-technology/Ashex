import Foundation

public struct TelegramBotIdentity: Codable, Sendable, Equatable {
    public let id: Int64
    public let isBot: Bool
    public let firstName: String
    public let username: String?

    enum CodingKeys: String, CodingKey {
        case id
        case isBot = "is_bot"
        case firstName = "first_name"
        case username
    }
}

public struct TelegramGetMeResponse: Codable, Sendable {
    public let ok: Bool
    public let result: TelegramBotIdentity
}

public struct TelegramUpdatesResponse: Codable, Sendable {
    public let ok: Bool
    public let result: [TelegramUpdate]
}

public struct TelegramUpdate: Codable, Sendable, Equatable {
    public let updateID: Int64
    public let message: TelegramMessage?

    enum CodingKeys: String, CodingKey {
        case updateID = "update_id"
        case message
    }
}

public struct TelegramMessage: Codable, Sendable, Equatable {
    public let messageID: Int64
    public let from: TelegramUser?
    public let chat: TelegramChat
    public let date: Int64
    public let text: String?

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case from
        case chat
        case date
        case text
    }
}

public struct TelegramUser: Codable, Sendable, Equatable {
    public let id: Int64
    public let isBot: Bool
    public let firstName: String
    public let username: String?

    enum CodingKeys: String, CodingKey {
        case id
        case isBot = "is_bot"
        case firstName = "first_name"
        case username
    }
}

public struct TelegramChat: Codable, Sendable, Equatable {
    public let id: Int64
    public let type: String
    public let username: String?

    public init(id: Int64, type: String, username: String? = nil) {
        self.id = id
        self.type = type
        self.username = username
    }
}

public struct TelegramSendMessageResponse: Codable, Sendable {
    public let ok: Bool
    public let result: TelegramMessage
}

public struct TelegramBoolResponse: Codable, Sendable {
    public let ok: Bool
    public let result: Bool
}
