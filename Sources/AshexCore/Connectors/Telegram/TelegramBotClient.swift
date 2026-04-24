import Foundation

public protocol TelegramBotClient: Sendable {
    func getMe(token: String) async throws -> TelegramBotIdentity
    func getUpdates(token: String, offset: Int64?, timeoutSeconds: Int) async throws -> [TelegramUpdate]
    func getFile(token: String, fileID: String) async throws -> TelegramFile
    func downloadFile(token: String, filePath: String) async throws -> Data
    func sendMessage(token: String, chatID: Int64, text: String, parseMode: String?) async throws -> TelegramMessage
    func editMessageText(token: String, chatID: Int64, messageID: Int64, text: String, parseMode: String?) async throws
    func sendChatAction(token: String, chatID: Int64, action: String) async throws
}

public struct URLSessionTelegramBotClient: TelegramBotClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func getMe(token: String) async throws -> TelegramBotIdentity {
        let request = try makeRequest(token: token, method: "getMe")
        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(TelegramGetMeResponse.self, from: data)
        guard response.ok, let result = response.result else {
            throw AshexError.model(response.description ?? "Telegram error: \(response.error_code ?? 0)")
        }
        return result
    }

    public func getUpdates(token: String, offset: Int64?, timeoutSeconds: Int) async throws -> [TelegramUpdate] {
        var components = URLComponents(url: try endpoint(token: token, method: "getUpdates"), resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "timeout", value: String(timeoutSeconds))]
        if let offset {
            queryItems.append(URLQueryItem(name: "offset", value: String(offset)))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw AshexError.model("Failed to build Telegram getUpdates URL")
        }
        let (data, _) = try await session.data(from: url)
        do {
            let response = try JSONDecoder().decode(TelegramUpdatesResponse.self, from: data)
            guard response.ok, let result = response.result else {
                throw AshexError.model(response.description ?? "Telegram error: \(response.error_code ?? 0)")
            }
            return result
        } catch let DecodingError.dataCorrupted(context) {
            throw AshexError.model("Telegram decoding error (dataCorrupted): \(context)")
        } catch let DecodingError.keyNotFound(key, context) {
            throw AshexError.model("Telegram decoding error (keyNotFound): \(key.stringValue) at \(context.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch let DecodingError.valueNotFound(value, context) {
            throw AshexError.model("Telegram decoding error (valueNotFound): \(value) at \(context.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch let DecodingError.typeMismatch(type, context) {
            throw AshexError.model("Telegram decoding error (typeMismatch): \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch {
            throw error
        }
    }

    public func getFile(token: String, fileID: String) async throws -> TelegramFile {
        var components = URLComponents(url: try endpoint(token: token, method: "getFile"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "file_id", value: fileID)]
        guard let url = components?.url else {
            throw AshexError.model("Failed to build Telegram getFile URL")
        }
        let (data, _) = try await session.data(from: url)
        let response = try JSONDecoder().decode(TelegramGetFileResponse.self, from: data)
        guard response.ok, let result = response.result else {
            throw AshexError.model(response.description ?? "Telegram error: \(response.error_code ?? 0)")
        }
        return result
    }

    public func downloadFile(token: String, filePath: String) async throws -> Data {
        guard let url = URL(string: "https://api.telegram.org/file/bot\(token)/\(filePath)") else {
            throw AshexError.model("Failed to build Telegram file download URL")
        }
        let (data, _) = try await session.data(from: url)
        return data
    }

    public func sendMessage(token: String, chatID: Int64, text: String, parseMode: String?) async throws -> TelegramMessage {
        var request = try makeRequest(token: token, method: "sendMessage")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "chat_id": chatID,
            "text": text,
        ]
        if let parseMode, !parseMode.isEmpty {
            payload["parse_mode"] = parseMode
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(TelegramSendMessageResponse.self, from: data)
        guard response.ok, let result = response.result else {
            throw AshexError.model(response.description ?? "Telegram error: \(response.error_code ?? 0)")
        }
        return result
    }

    public func editMessageText(token: String, chatID: Int64, messageID: Int64, text: String, parseMode: String?) async throws {
        var request = try makeRequest(token: token, method: "editMessageText")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "chat_id": chatID,
            "message_id": messageID,
            "text": text,
        ]
        if let parseMode, !parseMode.isEmpty {
            payload["parse_mode"] = parseMode
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(TelegramEditMessageResponse.self, from: data)
        guard response.ok else {
            throw AshexError.model(response.description ?? "Telegram error: \(response.error_code ?? 0)")
        }
    }

    public func sendChatAction(token: String, chatID: Int64, action: String) async throws {
        var request = try makeRequest(token: token, method: "sendChatAction")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "chat_id": chatID,
            "action": action,
        ])
        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(TelegramBoolResponse.self, from: data)
        guard response.ok else {
            throw AshexError.model(response.description ?? "Telegram error: \(response.error_code ?? 0)")
        }
    }

    private func makeRequest(token: String, method: String) throws -> URLRequest {
        URLRequest(url: try endpoint(token: token, method: method))
    }

    private func endpoint(token: String, method: String) throws -> URL {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
            throw AshexError.model("Failed to build Telegram endpoint for \(method)")
        }
        return url
    }
}
