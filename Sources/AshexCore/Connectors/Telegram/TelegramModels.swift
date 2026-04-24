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
    public let result: TelegramBotIdentity?
    public let description: String?
    public let error_code: Int?
}

public struct TelegramUpdatesResponse: Codable, Sendable {
    public let ok: Bool
    public let result: [TelegramUpdate]?
    public let description: String?
    public let error_code: Int?
}

public struct TelegramUpdate: Codable, Sendable, Equatable {
    public let updateID: Int64
    public let message: TelegramMessage?
    public let editedMessage: TelegramMessage?

    enum CodingKeys: String, CodingKey {
        case updateID = "update_id"
        case message
        case editedMessage = "edited_message"
    }

    public init(updateID: Int64, message: TelegramMessage? = nil, editedMessage: TelegramMessage? = nil) {
        self.updateID = updateID
        self.message = message
        self.editedMessage = editedMessage
    }
}

public struct TelegramMessage: Codable, Sendable, Equatable {
    public let messageID: Int64
    public let from: TelegramUser?
    public let chat: TelegramChat
    public let date: Int64
    public let text: String?
    public let caption: String?
    public let photo: [TelegramPhotoSize]?
    public let voice: TelegramVoice?
    public let audio: TelegramAudio?
    public let document: TelegramDocument?

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case from
        case chat
        case date
        case text
        case caption
        case photo
        case voice
        case audio
        case document
    }

    public init(
        messageID: Int64,
        from: TelegramUser?,
        chat: TelegramChat,
        date: Int64,
        text: String?,
        caption: String? = nil,
        photo: [TelegramPhotoSize]? = nil,
        voice: TelegramVoice? = nil,
        audio: TelegramAudio? = nil,
        document: TelegramDocument? = nil
    ) {
        self.messageID = messageID
        self.from = from
        self.chat = chat
        self.date = date
        self.text = text
        self.caption = caption
        self.photo = photo
        self.voice = voice
        self.audio = audio
        self.document = document
    }
}

public struct TelegramPhotoSize: Codable, Sendable, Equatable {
    public let fileID: String
    public let fileUniqueID: String
    public let width: Int
    public let height: Int
    public let fileSize: Int?

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case fileUniqueID = "file_unique_id"
        case width
        case height
        case fileSize = "file_size"
    }
}

public struct TelegramVoice: Codable, Sendable, Equatable {
    public let fileID: String
    public let fileUniqueID: String
    public let duration: Int
    public let mimeType: String?
    public let fileSize: Int?

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case fileUniqueID = "file_unique_id"
        case duration
        case mimeType = "mime_type"
        case fileSize = "file_size"
    }
}

public struct TelegramAudio: Codable, Sendable, Equatable {
    public let fileID: String
    public let fileUniqueID: String
    public let duration: Int
    public let fileName: String?
    public let mimeType: String?
    public let fileSize: Int?

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case fileUniqueID = "file_unique_id"
        case duration
        case fileName = "file_name"
        case mimeType = "mime_type"
        case fileSize = "file_size"
    }
}

public struct TelegramDocument: Codable, Sendable, Equatable {
    public let fileID: String
    public let fileUniqueID: String
    public let fileName: String?
    public let mimeType: String?
    public let fileSize: Int?

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case fileUniqueID = "file_unique_id"
        case fileName = "file_name"
        case mimeType = "mime_type"
        case fileSize = "file_size"
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
    public let result: TelegramMessage?
    public let description: String?
    public let error_code: Int?
}

public struct TelegramEditMessageResponse: Codable, Sendable {
    public let ok: Bool
    public let result: TelegramEditMessageResult?
    public let description: String?
    public let error_code: Int?
}

public enum TelegramEditMessageResult: Codable, Sendable, Equatable {
    case bool(Bool)
    case message(TelegramMessage)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
            return
        }
        self = .message(try container.decode(TelegramMessage.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value):
            try container.encode(value)
        case .message(let message):
            try container.encode(message)
        }
    }
}

public struct TelegramBoolResponse: Codable, Sendable {
    public let ok: Bool
    public let result: Bool?
    public let description: String?
    public let error_code: Int?
}

public struct TelegramFile: Codable, Sendable, Equatable {
    public let fileID: String
    public let fileUniqueID: String
    public let fileSize: Int?
    public let filePath: String?

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case fileUniqueID = "file_unique_id"
        case fileSize = "file_size"
        case filePath = "file_path"
    }
}

public struct TelegramGetFileResponse: Codable, Sendable {
    public let ok: Bool
    public let result: TelegramFile?
    public let description: String?
    public let error_code: Int?
}
