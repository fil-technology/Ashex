import AshexCore
import Foundation

enum ValidateCLI {
    static func handle(arguments: [String]) throws -> Bool {
        guard arguments.dropFirst().first == "validate" else { return false }
        let subcommand = arguments.dropFirst().dropFirst().first ?? "help"
        switch subcommand {
        case "help", "--help", "-h":
            print(helpText)
        case "agent-capabilities":
            throw AshexError.model("`ashex validate agent-capabilities` is planned for Phase 6 and is not implemented yet.")
        default:
            throw AshexError.model("Unknown validate command '\(subcommand)'.\n\(helpText)")
        }
        return true
    }

    static let helpText = """
    Usage:
      ashex validate agent-capabilities [options]
    """
}
