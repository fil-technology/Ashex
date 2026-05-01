import AshexCore
import Foundation

public protocol ComputerUseProvider: Sendable {
    func bootstrap() async throws
    func permissionStatus() async -> ComputerUsePermissionStatus
    func backendStatus() async throws -> ComputerUseBackendStatus
    func listWindows() async throws -> [ComputerUseWindow]
    func getWindowState(windowId: String) async throws -> ComputerUseWindowState
    func captureScreenshot(windowId: String) async throws -> ComputerUseScreenshot
    func click(elementId: String, windowId: String) async throws
    func typeText(_ text: String, windowId: String) async throws
    func pressKey(_ key: String, modifiers: [String], windowId: String) async throws
    func scroll(direction: ScrollDirection, amount: Int, windowId: String) async throws
    func focusApp(name: String?, windowId: String?) async throws
    func moveMouse(x: Double, y: Double) async throws
    func click(x: Double, y: Double, button: ComputerUseMouseButton, clickCount: Int) async throws
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double) async throws
    func openApp(named name: String) async throws
    func openURL(_ url: String) async throws
    func wait(seconds: Double) async throws
}

public extension ComputerUseProvider {
    func permissionStatus() async -> ComputerUsePermissionStatus {
        ComputerUsePermissionChecker.current()
    }

    func captureScreenshot(windowId _: String) async throws -> ComputerUseScreenshot {
        try ComputerUseScreenshotCapture.captureMainDisplay()
    }

    func focusApp(name _: String?, windowId _: String?) async throws {
        throw AshexError.model("Computer-use backend does not support focusing apps.")
    }

    func moveMouse(x _: Double, y _: Double) async throws {
        throw AshexError.model("Computer-use backend does not support pointer movement.")
    }

    func click(x _: Double, y _: Double, button _: ComputerUseMouseButton, clickCount _: Int) async throws {
        throw AshexError.model("Computer-use backend does not support coordinate clicks.")
    }

    func drag(fromX _: Double, fromY _: Double, toX _: Double, toY _: Double) async throws {
        throw AshexError.model("Computer-use backend does not support dragging.")
    }

    func openApp(named _: String) async throws {
        throw AshexError.model("Computer-use backend does not support opening apps.")
    }

    func openURL(_: String) async throws {
        throw AshexError.model("Computer-use backend does not support opening URLs.")
    }

    func wait(seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int64(max(0, seconds) * 1000)))
    }
}

public struct ComputerUseBackendManifest: Codable, Sendable, Equatable {
    public let executablePath: String
    public let arguments: [String]
    public let workingDirectory: String?

    public init(executablePath: String, arguments: [String] = [], workingDirectory: String? = nil) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }
}

public final class ManifestBackedComputerUseProvider: ComputerUseProvider {
    private let manifestURL: URL

    public init(manifestURL: URL) {
        self.manifestURL = manifestURL
    }

    public func bootstrap() async throws {
        _ = try loadManifest()
    }

    public func backendStatus() async throws -> ComputerUseBackendStatus {
        let output = try runBackend(arguments: ["status"])
        if let data = output.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(StatusEnvelope.self, from: data) {
            return .init(state: decoded.status == "running" ? .running : .stopped, detail: decoded.detail)
        }

        let lowered = output.lowercased()
        if lowered.contains("running") {
            return .init(state: .running, detail: trimmed(output))
        }
        return .init(state: .stopped, detail: trimmed(output))
    }

    public func listWindows() async throws -> [ComputerUseWindow] {
        let output = try runBackend(arguments: ["list-windows"])
        guard let data = output.data(using: .utf8) else {
            throw AshexError.model("Backend returned unreadable window data.")
        }
        return try JSONDecoder().decode([ComputerUseWindow].self, from: data)
    }

    public func getWindowState(windowId: String) async throws -> ComputerUseWindowState {
        let output = try runBackend(arguments: ["get-window-state", windowId])
        guard let data = output.data(using: .utf8) else {
            throw AshexError.model("Backend returned unreadable state data.")
        }
        return try JSONDecoder().decode(ComputerUseWindowState.self, from: data)
    }

    public func captureScreenshot(windowId: String) async throws -> ComputerUseScreenshot {
        do {
            let output = try runBackend(arguments: ["screenshot", "--window-id", windowId])
            guard let data = output.data(using: .utf8) else {
                throw AshexError.model("Backend returned unreadable screenshot data.")
            }
            return try decodeScreenshotEnvelope(data)
        } catch {
            return try ComputerUseScreenshotCapture.captureMainDisplay()
        }
    }

    public func click(elementId: String, windowId: String) async throws {
        _ = try runBackend(arguments: ["click", "--window-id", windowId, "--element-id", elementId])
    }

    public func typeText(_ text: String, windowId: String) async throws {
        _ = try runBackend(arguments: ["type-text", "--window-id", windowId, "--text", text])
    }

    public func pressKey(_ key: String, modifiers: [String], windowId: String) async throws {
        var arguments = ["press-key", "--window-id", windowId, "--key", key]
        for modifier in modifiers {
            arguments.append("--modifier")
            arguments.append(modifier)
        }
        _ = try runBackend(arguments: arguments)
    }

    public func scroll(direction: ScrollDirection, amount: Int, windowId: String) async throws {
        _ = try runBackend(arguments: [
            "scroll",
            "--window-id", windowId,
            "--direction", direction.rawValue,
            "--amount", String(max(1, amount)),
        ])
    }

    public func focusApp(name: String?, windowId: String?) async throws {
        var arguments = ["focus"]
        if let name, !name.isEmpty {
            arguments += ["--app", name]
        }
        if let windowId, !windowId.isEmpty {
            arguments += ["--window-id", windowId]
        }
        _ = try runBackend(arguments: arguments)
    }

    public func moveMouse(x: Double, y: Double) async throws {
        _ = try runBackend(arguments: ["move-mouse", "--x", String(x), "--y", String(y)])
    }

    public func click(x: Double, y: Double, button: ComputerUseMouseButton, clickCount: Int) async throws {
        _ = try runBackend(arguments: [
            "click-at",
            "--x", String(x),
            "--y", String(y),
            "--button", button.rawValue,
            "--count", String(max(1, clickCount)),
        ])
    }

    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double) async throws {
        _ = try runBackend(arguments: [
            "drag",
            "--from-x", String(fromX),
            "--from-y", String(fromY),
            "--to-x", String(toX),
            "--to-y", String(toY),
        ])
    }

    public func openApp(named name: String) async throws {
        _ = try runBackend(arguments: ["open-app", "--name", name])
    }

    public func openURL(_ url: String) async throws {
        _ = try runBackend(arguments: ["open-url", "--url", url])
    }

    private func loadManifest() throws -> ComputerUseBackendManifest {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw AshexError.model("Computer-use backend manifest was not found at \(manifestURL.path).")
        }
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(ComputerUseBackendManifest.self, from: data)
    }

    private func runBackend(arguments: [String]) throws -> String {
        let manifest = try loadManifest()
        let executableURL = resolvePath(manifest.executablePath)
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw AshexError.model("Computer-use backend executable was not found at \(executableURL.path).")
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = manifest.arguments + arguments
        if let workingDirectory = manifest.workingDirectory {
            process.currentDirectoryURL = resolvePath(workingDirectory)
        } else {
            process.currentDirectoryURL = manifestURL.deletingLastPathComponent()
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errorOutput = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        guard process.terminationStatus == 0 else {
            let detail = trimmed(errorOutput).isEmpty ? trimmed(output) : trimmed(errorOutput)
            throw AshexError.model(detail.isEmpty ? "Computer-use backend command failed." : detail)
        }

        return trimmed(output)
    }

    private func resolvePath(_ rawPath: String) -> URL {
        let url = URL(fileURLWithPath: rawPath)
        if url.path.hasPrefix("/") {
            return url
        }
        return manifestURL.deletingLastPathComponent().appendingPathComponent(rawPath)
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct StatusEnvelope: Codable {
        let status: String
        let detail: String?
    }

    private func decodeScreenshotEnvelope(_ data: Data) throws -> ComputerUseScreenshot {
        let decoded = try JSONDecoder().decode(ScreenshotEnvelope.self, from: data)
        let screenshotData: Data
        if let base64 = decoded.dataBase64 {
            guard let decodedData = Data(base64Encoded: base64) else {
                throw AshexError.model("Backend screenshot response contained invalid base64 data.")
            }
            screenshotData = decodedData
        } else if let path = decoded.path {
            screenshotData = try Data(contentsOf: URL(fileURLWithPath: path))
        } else {
            throw AshexError.model("Backend screenshot response must include `data_base64` or `path`.")
        }
        return .init(
            data: screenshotData,
            contentType: decoded.contentType ?? "image/png",
            width: decoded.width ?? 0,
            height: decoded.height ?? 0
        )
    }

    private struct ScreenshotEnvelope: Codable {
        let dataBase64: String?
        let path: String?
        let contentType: String?
        let width: Int?
        let height: Int?

        enum CodingKeys: String, CodingKey {
            case dataBase64 = "data_base64"
            case path
            case contentType = "content_type"
            case width
            case height
        }
    }
}
