import Foundation

enum CLIJSONOutput {
    static func string<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func print<T: Encodable>(_ value: T) throws {
        Swift.print(try string(value))
    }
}
