import Foundation

public enum AshexError: LocalizedError, Sendable {
    case invalidToolArguments(String)
    case toolNotFound(String)
    case workspaceViolation(String)
    case fileSystem(String)
    case shell(String)
    case model(String)
    case persistence(String)
    case approvalDenied(String)
    case maxIterationsReached(Int)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidToolArguments(let message),
             .workspaceViolation(let message),
             .fileSystem(let message),
             .shell(let message),
             .model(let message),
             .approvalDenied(let message),
             .persistence(let message):
            return message
        case .toolNotFound(let name):
            return "Tool not found: \(name)"
        case .maxIterationsReached(let count):
            return "Maximum iterations reached: \(count)"
        case .cancelled:
            return "Run cancelled"
        }
    }
}
