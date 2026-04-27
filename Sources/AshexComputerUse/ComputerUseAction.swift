import AshexCore
import Foundation

public enum ScrollDirection: String, Codable, Sendable, Equatable {
    case up
    case down
}

public enum ComputerUseAction: Sendable, Equatable {
    case click(elementId: String)
    case typeText(String)
    case pressKey(key: String, modifiers: [String])
    case scroll(direction: ScrollDirection, amount: Int)
    case captureScreenshot
    case refreshState
    case quit
}

public struct ComputerUseWindow: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let appName: String

    public init(id: String, title: String, appName: String) {
        self.id = id
        self.title = title
        self.appName = appName
    }
}

public struct ComputerUseElement: Codable, Sendable, Equatable {
    public let id: String
    public let role: String
    public let title: String?
    public let value: String?
    public let isEnabled: Bool

    public init(id: String, role: String, title: String?, value: String?, isEnabled: Bool) {
        self.id = id
        self.role = role
        self.title = title
        self.value = value
        self.isEnabled = isEnabled
    }
}

public struct ComputerUseWindowState: Codable, Sendable, Equatable {
    public let windowID: String
    public let title: String
    public let appName: String
    public let url: String?
    public let elements: [ComputerUseElement]

    public init(windowID: String, title: String, appName: String, url: String?, elements: [ComputerUseElement]) {
        self.windowID = windowID
        self.title = title
        self.appName = appName
        self.url = url
        self.elements = elements
    }
}

public struct ComputerUseScreenshot: Sendable, Equatable {
    public let data: Data
    public let contentType: String
    public let width: Int
    public let height: Int
    public let capturedAt: Date

    public init(data: Data, contentType: String, width: Int, height: Int, capturedAt: Date = Date()) {
        self.data = data
        self.contentType = contentType
        self.width = width
        self.height = height
        self.capturedAt = capturedAt
    }
}

public struct ComputerUseObservation: Sendable, Equatable {
    public let text: String
    public let screenshots: [ComputerUseScreenshot]

    public init(text: String, screenshots: [ComputerUseScreenshot] = []) {
        self.text = text
        self.screenshots = screenshots
    }

    public func imageAttachments(fileManager: FileManager = .default) throws -> [InputAttachment] {
        try screenshots.enumerated().map { index, screenshot in
            let directory = fileManager.temporaryDirectory
                .appendingPathComponent("ashex-computer-use", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("screenshot-\(UUID().uuidString)-\(index).png")
            try screenshot.data.write(to: fileURL, options: Data.WritingOptions.atomic)
            return InputAttachment(
                kind: .image,
                localPath: fileURL.path,
                originalFilename: fileURL.lastPathComponent,
                mimeType: screenshot.contentType,
                caption: "Screenshot of \(text.components(separatedBy: .newlines).first?.replacingOccurrences(of: "Window: ", with: "") ?? "current computer state").",
                fileSizeBytes: screenshot.data.count,
                metadata: [
                    "source": .string("computer_use"),
                    "width": .number(Double(screenshot.width)),
                    "height": .number(Double(screenshot.height)),
                    "captured_at": .string(ISO8601DateFormatter().string(from: screenshot.capturedAt)),
                ]
            )
        }
    }
}

public struct ComputerUseBackendStatus: Sendable, Equatable {
    public enum State: String, Codable, Sendable, Equatable {
        case running
        case stopped
    }

    public let state: State
    public let detail: String?

    public init(state: State, detail: String? = nil) {
        self.state = state
        self.detail = detail
    }
}

public enum ComputerUseCommandError: LocalizedError, Sendable, Equatable {
    case unsupported(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let message), .invalid(let message):
            return message
        }
    }
}
