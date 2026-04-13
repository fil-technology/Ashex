import Foundation

public protocol TelegramBotClient: Sendable {
    func getMe(token: String) async throws -> TelegramBotIdentity
    func getUpdates(token: String, offset: Int64?, timeoutSeconds: Int) async throws -> [TelegramUpdate]
    func sendMessage(token: String, chatID: Int64, text: String, parseMode: String?) async throws
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
        return try JSONDecoder().decode(TelegramGetMeResponse.self, from: data).result
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
        return try JSONDecoder().decode(TelegramUpdatesResponse.self, from: data).result
    }

    public func sendMessage(token: String, chatID: Int64, text: String, parseMode: String?) async throws {
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
        _ = try JSONDecoder().decode(TelegramSendMessageResponse.self, from: data)
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
        _ = try JSONDecoder().decode(TelegramBoolResponse.self, from: data)
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
