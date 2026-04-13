import Darwin
import Foundation

enum ExecutableLocator {
    static func currentExecutableURL() throws -> URL {
        let fileManager = FileManager.default

        let argumentPath = CommandLine.arguments[0]
        if argumentPath.hasPrefix("/"), fileManager.isExecutableFile(atPath: argumentPath) {
            return URL(fileURLWithPath: argumentPath).standardizedFileURL
        }

        if let bundleURL = Bundle.main.executableURL,
           fileManager.isExecutableFile(atPath: bundleURL.path) {
            return bundleURL.standardizedFileURL
        }

        var bufferSize = UInt32(PATH_MAX)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(bufferSize))
        defer { buffer.deallocate() }

        guard _NSGetExecutablePath(buffer, &bufferSize) == 0 else {
            throw NSError(domain: "AshexCLI", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to resolve the current Ashex executable path."
            ])
        }

        let resolvedPath = String(cString: buffer)
        guard fileManager.isExecutableFile(atPath: resolvedPath) else {
            throw NSError(domain: "AshexCLI", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Resolved executable is not runnable: \(resolvedPath)"
            ])
        }
        return URL(fileURLWithPath: resolvedPath).standardizedFileURL
    }
}

struct DaemonProcessState: Codable {
    let pid: Int32
    let startedAt: Date
    let logPath: String
}

struct DaemonProcessStatus {
    let pid: Int32
    let startedAt: Date
    let logPath: String
    let isRunning: Bool
}

final class DaemonProcessStateStore {
    let storageRoot: URL

    init(storageRoot: URL) {
        self.storageRoot = storageRoot
    }

    var stateFileURL: URL {
        storageRoot.appendingPathComponent("daemon", isDirectory: true).appendingPathComponent("state.json")
    }

    var logFileURL: URL {
        storageRoot.appendingPathComponent("daemon", isDirectory: true).appendingPathComponent("daemon.log")
    }

    func writeCurrentProcess(logPath: String) throws {
        let state = DaemonProcessState(pid: getpid(), startedAt: Date(), logPath: logPath)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(at: stateFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: stateFileURL, options: .atomic)
    }

    func clearIfOwnedByCurrentProcess() throws {
        guard let status = try status(), status.pid == getpid() else { return }
        try? FileManager.default.removeItem(at: stateFileURL)
    }

    func status() throws -> DaemonProcessStatus? {
        guard FileManager.default.fileExists(atPath: stateFileURL.path) else { return nil }
        let data = try Data(contentsOf: stateFileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(DaemonProcessState.self, from: data)
        let isRunning = kill(state.pid, 0) == 0
        if !isRunning {
            try? FileManager.default.removeItem(at: stateFileURL)
            return DaemonProcessStatus(pid: state.pid, startedAt: state.startedAt, logPath: state.logPath, isRunning: false)
        }
        return DaemonProcessStatus(pid: state.pid, startedAt: state.startedAt, logPath: state.logPath, isRunning: true)
    }
}
