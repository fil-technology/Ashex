import Darwin
import Foundation

public struct BrowserCommandOutput: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
}

public enum BrowserExecutableDiscovery {
    public static func resolveExecutable(
        configuredPath: String?,
        defaultName: String,
        additionalPaths: [String] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let configuredPath = configuredPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: configuredPath) {
            return configuredPath
        }

        for path in additionalPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let pathVariable = environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for entry in pathVariable.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(entry)).appendingPathComponent(defaultName).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    public static func resolveChromeExecutable(
        configuredPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let macOSApplicationPaths = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
            "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
            "\(NSHomeDirectory())/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "\(NSHomeDirectory())/Applications/Chromium.app/Contents/MacOS/Chromium",
        ]

        for binaryName in ["google-chrome", "chrome", "chromium", "chromium-browser"] {
            if let executable = resolveExecutable(
                configuredPath: configuredPath,
                defaultName: binaryName,
                additionalPaths: macOSApplicationPaths,
                environment: environment
            ) {
                return executable
            }
        }
        return nil
    }
}

public enum BrowserProcessSupport {
    public static func runCommand(
        executablePath: String,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeoutSeconds: Int = 5
    ) async throws -> BrowserCommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let controller = BrowserManagedProcess(process: process, stdoutPipe: stdout, stderrPipe: stderr)
        defer { controller.terminateIfRunning() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                controller.terminateIfRunning()
            }
            group.addTask {
                process.waitUntilExit()
            }
            _ = try await group.next()
            group.cancelAll()
        }

        return BrowserCommandOutput(
            stdout: controller.stdoutString,
            stderr: controller.stderrString,
            exitCode: process.terminationStatus
        )
    }

    public static func availableFlags(
        executablePath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> Set<String> {
        let output: BrowserCommandOutput?
        do {
            output = try await runCommand(
                executablePath: executablePath,
                arguments: ["--help"],
                environment: environment,
                timeoutSeconds: 5
            )
        } catch {
            return []
        }

        let helpText = [output?.stdout ?? "", output?.stderr ?? ""].joined(separator: "\n")
        let candidates = helpText
            .split(whereSeparator: \.isWhitespace)
            .filter { $0.hasPrefix("--") }
            .map { token -> String in
                let value = token.split(separator: "=").first ?? token[...]
                return String(value)
            }
        return Set(candidates)
    }

    public static func chooseFreePort(host: String = "127.0.0.1") throws -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw BrowserBackendError.startupFailed("Unable to allocate a local TCP socket for browser startup.")
        }
        defer { close(socketFD) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr(host))

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(socketFD, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw BrowserBackendError.startupFailed("Unable to reserve a free local port for browser startup.")
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                getsockname(socketFD, pointer, &length)
            }
        }
        guard nameResult == 0 else {
            throw BrowserBackendError.startupFailed("Unable to inspect a reserved local browser port.")
        }

        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    public static func waitForReadyEndpoint(
        baseURL: URL,
        timeoutSeconds: Int
    ) async throws -> URL {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        let session = URLSession(configuration: .ephemeral)

        while Date() < deadline {
            for path in ["/json/version", "/json"] {
                let probeURL = baseURL.appending(path: path)
                do {
                    let (_, response) = try await session.data(from: probeURL)
                    if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                        return baseURL
                    }
                } catch {
                }
            }
            try await Task.sleep(for: .milliseconds(200))
        }

        throw BrowserBackendError.timeout("Timed out waiting for browser backend at \(baseURL.absoluteString) to become ready.")
    }
}

final class BrowserManagedProcess: @unchecked Sendable {
    let process: Process
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe

    init(process: Process, stdoutPipe: Pipe, stderrPipe: Pipe) {
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
    }

    var stdoutString: String {
        String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    var stderrString: String {
        String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func terminateIfRunning() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }
}
