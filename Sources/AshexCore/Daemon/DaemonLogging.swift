import Foundation

public enum DaemonLogLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

public struct DaemonLogEntry: Sendable, Codable {
    public let timestamp: Date
    public let level: DaemonLogLevel
    public let subsystem: String
    public let message: String
    public let metadata: JSONObject

    public init(timestamp: Date = Date(), level: DaemonLogLevel, subsystem: String, message: String, metadata: JSONObject = [:]) {
        self.timestamp = timestamp
        self.level = level
        self.subsystem = subsystem
        self.message = message
        self.metadata = metadata
    }
}

public actor DaemonLogger {
    private let minimumLevel: DaemonLogLevel
    private let sink: @Sendable (String) -> Void

    public init(minimumLevel: DaemonLogLevel = .info, sink: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.minimumLevel = minimumLevel
        self.sink = sink
    }

    public func log(_ level: DaemonLogLevel, subsystem: String, message: String, metadata: JSONObject = [:]) {
        guard shouldEmit(level) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(DaemonLogEntry(level: level, subsystem: subsystem, message: message, metadata: metadata)),
           let text = String(data: data, encoding: .utf8) {
            sink(text)
        } else {
            sink("[\(level.rawValue)] [\(subsystem)] \(message)")
        }
    }

    private func shouldEmit(_ level: DaemonLogLevel) -> Bool {
        order(level) >= order(minimumLevel)
    }

    private func order(_ level: DaemonLogLevel) -> Int {
        switch level {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }
}
