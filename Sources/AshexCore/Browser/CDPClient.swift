import Foundation

struct CDPDiscoveryVersion: Decodable {
    let webSocketDebuggerURL: String?

    private enum CodingKeys: String, CodingKey {
        case webSocketDebuggerURL = "webSocketDebuggerUrl"
    }
}

struct CDPDiscoveryTarget: Decodable {
    let id: String
    let title: String?
    let type: String?
    let url: String?
    let webSocketDebuggerURL: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case type
        case url
        case webSocketDebuggerURL = "webSocketDebuggerUrl"
    }
}

public actor CDPClient {
    private let baseURL: URL
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var nextID = 1
    private var pendingContinuations: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var eventWaiters: [String: [CheckedContinuation<JSONValue, Error>]] = [:]
    private var listenerTask: Task<Void, Never>?

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func connect(initialURL: URL? = nil) async throws {
        let webSocketURL = try await resolveWebSocketURL(initialURL: initialURL)
        let task = session.webSocketTask(with: webSocketURL)
        socket = task
        task.resume()
        listenerTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    public func close() async {
        listenerTask?.cancel()
        listenerTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        for (_, continuation) in pendingContinuations {
            continuation.resume(throwing: BrowserBackendError.protocolError("CDP connection closed before a response arrived."))
        }
        pendingContinuations.removeAll()
    }

    public func send(method: String, params: JSONObject = [:], timeoutSeconds: Int = 30) async throws -> JSONValue {
        guard let socket else {
            throw BrowserBackendError.protocolError("CDP connection is not open.")
        }

        let id = nextID
        nextID += 1

        let payload: [String: Any] = [
            "id": id,
            "method": method,
            "params": params.foundationObject
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        let text = String(decoding: data, as: UTF8.self)

        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                    Task {
                        await self.storePendingContinuation(continuation, for: id)
                    }
                    socket.send(.string(text)) { error in
                        if let error {
                            Task {
                                await self.failPending(id: id, error: error)
                            }
                        }
                    }
                }
            }

            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw BrowserBackendError.timeout("Timed out waiting for CDP response to \(method).")
            }

            let result = try await group.next() ?? .null
            group.cancelAll()
            return result
        }
    }

    public func waitForEvent(_ method: String, timeoutSeconds: Int = 30) async throws -> JSONValue {
        try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                    Task {
                        await self.storeEventWaiter(continuation, for: method)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw BrowserBackendError.timeout("Timed out waiting for CDP event \(method).")
            }
            let result = try await group.next() ?? .null
            group.cancelAll()
            return result
        }
    }

    public func navigate(url: URL, timeoutSeconds: Int) async throws {
        _ = try await send(method: "Page.enable")
        _ = try await send(method: "Runtime.enable")
        _ = try await send(method: "Network.enable")
        _ = try await send(method: "Page.navigate", params: ["url": .string(url.absoluteString)], timeoutSeconds: timeoutSeconds)
        do {
            _ = try await waitForEvent("Page.loadEventFired", timeoutSeconds: timeoutSeconds)
        } catch {
            try await waitForDocumentReady(timeoutSeconds: timeoutSeconds)
        }
    }

    public func evaluate(expression: String, timeoutSeconds: Int = 30) async throws -> BrowserEvaluateResult {
        let response = try await send(method: "Runtime.evaluate", params: [
            "expression": .string(expression),
            "returnByValue": .bool(true),
            "awaitPromise": .bool(true),
        ], timeoutSeconds: timeoutSeconds)

        guard let object = response.objectValue,
              let resultObject = object["result"]?.objectValue,
              let value = resultObject["value"] else {
            return BrowserEvaluateResult(value: response, description: response.prettyPrinted)
        }

        return BrowserEvaluateResult(value: value, description: value.displayString)
    }

    public func title() async throws -> String? {
        let evaluated = try await evaluate(expression: "document.title")
        return evaluated.value.stringValue
    }

    public func outerHTML() async throws -> String {
        _ = try await send(method: "DOM.enable")
        let document = try await send(method: "DOM.getDocument", params: ["depth": .number(1)])
        guard let nodeID = document.objectValue?["root"]?.objectValue?["nodeId"]?.intValue else {
            throw BrowserBackendError.protocolError("CDP DOM.getDocument did not return a root node.")
        }
        let html = try await send(method: "DOM.getOuterHTML", params: ["nodeId": .number(Double(nodeID))])
        return html.objectValue?["outerHTML"]?.stringValue ?? ""
    }

    public func screenshot(options: BrowserScreenshotOptions) async throws -> Data {
        let response = try await send(method: "Page.captureScreenshot", params: [
            "format": .string(options.format),
            "captureBeyondViewport": .bool(options.fullPage),
        ])
        guard let base64 = response.objectValue?["data"]?.stringValue,
              let data = Data(base64Encoded: base64) else {
            throw BrowserBackendError.protocolError("CDP Page.captureScreenshot did not return valid image data.")
        }
        return data
    }

    private func resolveWebSocketURL(initialURL: URL?) async throws -> URL {
        if let initialURL {
            let target = try await createTarget(url: initialURL)
            if let value = target.webSocketDebuggerURL, let url = URL(string: value) {
                return url
            }
        }

        if let versionURL = try await versionDebuggerURL() {
            return versionURL
        }

        let targets = try await listTargets()
        if let value = targets.first(where: { $0.type == "page" })?.webSocketDebuggerURL,
           let url = URL(string: value) {
            return url
        }
        throw BrowserBackendError.unavailable("No page target was available on the configured CDP endpoint.")
    }

    private func versionDebuggerURL() async throws -> URL? {
        let url = baseURL.appending(path: "/json/version")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        let version = try JSONDecoder().decode(CDPDiscoveryVersion.self, from: data)
        guard let string = version.webSocketDebuggerURL else { return nil }
        return URL(string: string)
    }

    private func listTargets() async throws -> [CDPDiscoveryTarget] {
        let url = baseURL.appending(path: "/json")
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode([CDPDiscoveryTarget].self, from: data)
    }

    private func createTarget(url: URL) async throws -> CDPDiscoveryTarget {
        let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url.absoluteString
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw BrowserBackendError.invalidURL("Unable to construct a CDP target creation URL.")
        }
        components.path = "/json/new"
        components.percentEncodedQuery = encoded
        guard let createURL = components.url else {
            throw BrowserBackendError.invalidURL("Unable to construct a CDP target creation URL.")
        }
        var request = URLRequest(url: createURL)
        request.httpMethod = "PUT"

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return try JSONDecoder().decode(CDPDiscoveryTarget.self, from: data)
            }
        } catch {
        }

        guard let fallback = components.url else {
            throw BrowserBackendError.invalidURL("Unable to construct a CDP target creation URL.")
        }
        let (data, _) = try await session.data(from: fallback)
        return try JSONDecoder().decode(CDPDiscoveryTarget.self, from: data)
    }

    private func receiveLoop() async {
        guard let socket else { return }
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                let text: String
                switch message {
                case .string(let string):
                    text = string
                case .data(let data):
                    text = String(decoding: data, as: UTF8.self)
                @unknown default:
                    continue
                }
                try await handleIncomingMessage(text)
            } catch {
                break
            }
        }
    }

    private func handleIncomingMessage(_ text: String) async throws {
        guard let data = text.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let id = json["id"] as? Int {
            let response = JSONValue.fromFoundation(json["result"] ?? NSNull())
            pendingContinuations.removeValue(forKey: id)?.resume(returning: response)
            return
        }

        guard let method = json["method"] as? String else { return }
        let params = JSONValue.fromFoundation(json["params"] ?? NSNull())
        let waiters = eventWaiters.removeValue(forKey: method) ?? []
        for waiter in waiters {
            waiter.resume(returning: params)
        }
    }

    private func failPending(id: Int, error: Error) {
        pendingContinuations.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func storePendingContinuation(_ continuation: CheckedContinuation<JSONValue, Error>, for id: Int) {
        pendingContinuations[id] = continuation
    }

    private func storeEventWaiter(_ continuation: CheckedContinuation<JSONValue, Error>, for method: String) {
        eventWaiters[method, default: []].append(continuation)
    }

    private func waitForDocumentReady(timeoutSeconds: Int) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            let state = try? await evaluate(expression: "document.readyState")
            let hasBody = try? await evaluate(expression: "Boolean(document.body && document.body.innerText)")
            if let readyState = state?.value.stringValue,
               (readyState == "interactive" || readyState == "complete"),
               hasBody?.value.boolValue == true {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw BrowserBackendError.timeout("Timed out waiting for CDP event Page.loadEventFired.")
    }
}

private extension JSONObject {
    var foundationObject: [String: Any] {
        reduce(into: [String: Any]()) { partialResult, entry in
            partialResult[entry.key] = entry.value.foundationValue
        }
    }
}

private extension JSONValue {
    static func fromFoundation(_ value: Any) -> JSONValue {
        switch value {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case let array as [Any]:
            return .array(array.map(Self.fromFoundation))
        case let object as [String: Any]:
            return .object(object.mapValues(Self.fromFoundation))
        default:
            return .null
        }
    }

    var foundationValue: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues(\.foundationValue)
        case .array(let value):
            return value.map(\.foundationValue)
        case .null:
            return NSNull()
        }
    }

    var displayString: String {
        switch self {
        case .string(let value):
            return value
        default:
            return prettyPrinted
        }
    }
}
