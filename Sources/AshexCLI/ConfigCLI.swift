import AshexCore
import Foundation

enum ConfigCLI {
    static func handle(arguments: [String]) throws -> Bool {
        guard arguments.dropFirst().first == "config" else { return false }
        let command = arguments.dropFirst().dropFirst().first ?? "help"
        switch command {
        case "set":
            try set(arguments: arguments)
        case "help", "--help", "-h":
            print(helpText)
        default:
            throw AshexError.model("Unknown config command '\(command)'.\n\(helpText)")
        }
        return true
    }

    private static func set(arguments: [String]) throws {
        let options = try SetOptions(arguments: arguments)
        let configuration = try CLIConfiguration(arguments: options.configurationArguments)
        let configURL = configuration.userConfigFile
        let existingData = try Data(contentsOf: configURL)
        let existingObject = (try JSONSerialization.jsonObject(with: existingData) as? [String: Any]) ?? [:]
        let updatedObject = try JSONConfigEditor.setting(existingObject, path: options.keyPath, value: options.rawValue)
        let data = try JSONSerialization.data(withJSONObject: updatedObject, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configURL, options: .atomic)
        print("\(options.keyPath) = \(options.rawValue)")
    }

    static let helpText = """
    Usage:
      ashex config set <key.path> <value> [--workspace PATH]
    """
}

private struct SetOptions {
    let keyPath: String
    let rawValue: String
    let configurationArguments: [String]

    init(arguments: [String]) throws {
        var positional: [String] = []
        var configurationArguments = [arguments.first ?? "ashex"]
        var iterator = arguments.dropFirst().dropFirst().dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--workspace", "--storage", "--provider", "--model", "--max-iterations", "--approval-mode":
                guard let value = iterator.next() else { throw AshexError.model("Missing value for \(argument)") }
                configurationArguments.append(argument)
                configurationArguments.append(value)
            default:
                positional.append(argument)
            }
        }
        guard positional.count >= 2 else {
            throw AshexError.model("config set requires a key path and value")
        }
        self.keyPath = positional[0]
        self.rawValue = positional.dropFirst().joined(separator: " ")
        self.configurationArguments = configurationArguments
    }
}

private enum JSONConfigEditor {
    static func setting(_ object: [String: Any], path: String, value: String) throws -> [String: Any] {
        let parts = path.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { throw AshexError.model("Config key path cannot be empty") }
        return set(object, parts: parts[...], value: parseValue(value))
    }

    private static func set(_ object: [String: Any], parts: ArraySlice<String>, value: Any) -> [String: Any] {
        guard let head = parts.first else { return object }
        var updated = object
        if parts.count == 1 {
            updated[head] = value
            return updated
        }
        let child = updated[head] as? [String: Any] ?? [:]
        updated[head] = set(child, parts: parts.dropFirst(), value: value)
        return updated
    }

    private static func parseValue(_ value: String) -> Any {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "true" { return true }
        if trimmed == "false" { return false }
        if trimmed == "null" { return NSNull() }
        if let int = Int(trimmed) { return int }
        if let double = Double(trimmed), trimmed.contains(".") { return double }
        return trimmed
    }
}
