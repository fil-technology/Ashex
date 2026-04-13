import AshexCore
import Foundation
import Testing

@Suite(.serialized)
struct DFlashServerModelAdapterTests {
    @Test func parsesDirectChatReplyFromChatCompletionsResponse() async throws {
        let session = makeDFlashStubbedSession(statusCode: 200, body: """
        {
          "choices": [
            {
              "message": {
                "content": "Doing well. How can I help?"
              }
            }
          ]
        }
        """)

        let adapter = DFlashServerModelAdapter(
            configuration: .init(
                model: "Qwen/Qwen3.5-4B",
                baseURL: URL(string: "http://127.0.0.1:8000")!
            ),
            session: session
        )

        let reply = try await adapter.directReply(
            history: [
                .init(id: UUID(), threadID: UUID(), runID: UUID(), role: .user, content: "How are you?", createdAt: Date())
            ],
            systemPrompt: "You are helpful."
        )

        #expect(reply == "Doing well. How can I help?")
    }

    @Test func toolModeIsExplicitlyUnsupportedForNow() async throws {
        let adapter = DFlashServerModelAdapter(
            configuration: .init(model: "Qwen/Qwen3.5-4B")
        )

        let thread = ThreadRecord(id: UUID(), createdAt: Date())
        let run = RunRecord(id: UUID(), threadID: thread.id, state: .running, createdAt: Date(), updatedAt: Date())
        let context = ModelContext(
            thread: thread,
            run: run,
            messages: [
                .init(id: UUID(), threadID: thread.id, runID: run.id, role: .user, content: "List files", createdAt: Date())
            ],
            availableTools: []
        )

        await #expect(throws: Error.self) {
            _ = try await adapter.nextAction(for: context)
        }
    }
}

private func makeDFlashStubbedSession(statusCode: Int, body: String) -> URLSession {
    DFlashStubURLProtocol.state.set(statusCode: statusCode, body: body)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DFlashStubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class DFlashStubURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = DFlashStubResponseState()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let current = Self.state.snapshot()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://127.0.0.1:8000/v1/chat/completions")!,
            statusCode: current.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(current.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class DFlashStubResponseState: @unchecked Sendable {
    private let lock = NSLock()
    private var statusCode = 200
    private var body = ""

    func set(statusCode: Int, body: String) {
        lock.lock()
        self.statusCode = statusCode
        self.body = body
        lock.unlock()
    }

    func snapshot() -> (statusCode: Int, body: String) {
        lock.lock()
        defer { lock.unlock() }
        return (statusCode, body)
    }
}
