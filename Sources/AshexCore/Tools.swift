import Foundation

public struct ToolContext: Sendable {
    public let runID: UUID
    public let emit: RuntimeEventHandler
    public let cancellation: CancellationToken

    public init(runID: UUID, emit: @escaping RuntimeEventHandler, cancellation: CancellationToken) {
        self.runID = runID
        self.emit = emit
        self.cancellation = cancellation
    }
}

public protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    func execute(arguments: JSONObject, context: ToolContext) async throws -> ToolContent
}

public final class ToolRegistry: Sendable {
    private let tools: [String: any Tool]

    public init(tools: [any Tool]) {
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
    }

    public func schema() -> [ToolSchema] {
        tools.values
            .map { ToolSchema(name: $0.name, description: $0.description) }
            .sorted { $0.name < $1.name }
    }

    public func tool(named name: String) throws -> any Tool {
        guard let tool = tools[name] else {
            throw AshexError.toolNotFound(name)
        }
        return tool
    }
}
