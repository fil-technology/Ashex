import Foundation

public struct BrowserNavigateOptions: Sendable, Equatable {
    public var timeoutSeconds: Int
    public var waitForLoad: Bool

    public init(timeoutSeconds: Int = 30, waitForLoad: Bool = true) {
        self.timeoutSeconds = max(1, timeoutSeconds)
        self.waitForLoad = waitForLoad
    }
}

public struct BrowserScreenshotOptions: Sendable, Equatable {
    public var format: String
    public var quality: Int?
    public var fullPage: Bool

    public init(format: String = "png", quality: Int? = nil, fullPage: Bool = true) {
        self.format = format
        self.quality = quality
        self.fullPage = fullPage
    }
}

public struct BrowserPageResult: Sendable, Equatable {
    public var url: String
    public var title: String?
    public var loadTimeMs: Int
    public var backend: String

    public init(url: String, title: String? = nil, loadTimeMs: Int, backend: String) {
        self.url = url
        self.title = title
        self.loadTimeMs = loadTimeMs
        self.backend = backend
    }
}

public struct BrowserEvaluateResult: Sendable, Equatable {
    public var value: JSONValue
    public var description: String

    public init(value: JSONValue, description: String) {
        self.value = value
        self.description = description
    }
}

public struct BrowserBenchmarkResult: Sendable, Equatable {
    public var backend: String
    public var executablePath: String?
    public var startupMs: Int
    public var readyMs: Int
    public var navigationMs: Int
    public var extractionMs: Int
    public var screenshotMs: Int
    public var peakRSSBytes: Int?
    public var success: Bool
    public var errorSummary: String?

    public init(
        backend: String,
        executablePath: String?,
        startupMs: Int,
        readyMs: Int,
        navigationMs: Int,
        extractionMs: Int,
        screenshotMs: Int,
        peakRSSBytes: Int? = nil,
        success: Bool,
        errorSummary: String? = nil
    ) {
        self.backend = backend
        self.executablePath = executablePath
        self.startupMs = startupMs
        self.readyMs = readyMs
        self.navigationMs = navigationMs
        self.extractionMs = extractionMs
        self.screenshotMs = screenshotMs
        self.peakRSSBytes = peakRSSBytes
        self.success = success
        self.errorSummary = errorSummary
    }
}

public final class BrowserSession: @unchecked Sendable {
    public let id: UUID
    public let backendID: String
    public let startedAt: Date

    let state: BrowserSessionState

    init(id: UUID = UUID(), backendID: String, startedAt: Date = Date(), state: BrowserSessionState) {
        self.id = id
        self.backendID = backendID
        self.startedAt = startedAt
        self.state = state
    }

    public var endpointURL: URL {
        state.endpointURL
    }

    public var executablePath: String? {
        state.executablePath
    }

    public var readyDurationMs: Int {
        Int(state.readyAt.timeIntervalSince(state.startupStartedAt) * 1000)
    }
}

final class BrowserSessionState: @unchecked Sendable {
    let config: BrowserConfig
    let endpointURL: URL
    let client: CDPClient
    let process: BrowserManagedProcess?
    let executablePath: String?
    let startupStartedAt: Date
    let readyAt: Date

    init(
        config: BrowserConfig,
        endpointURL: URL,
        client: CDPClient,
        process: BrowserManagedProcess?,
        executablePath: String?,
        startupStartedAt: Date,
        readyAt: Date
    ) {
        self.config = config
        self.endpointURL = endpointURL
        self.client = client
        self.process = process
        self.executablePath = executablePath
        self.startupStartedAt = startupStartedAt
        self.readyAt = readyAt
    }
}

public protocol BrowserBackend: Sendable {
    var id: BrowserBackendID { get }
    func isAvailable(config: BrowserConfig) async -> BrowserBackendAvailability
    func start(config: BrowserConfig) async throws -> BrowserSession
    func stop(session: BrowserSession) async throws
    func navigate(session: BrowserSession, url: URL, options: BrowserNavigateOptions) async throws -> BrowserPageResult
    func evaluate(session: BrowserSession, expression: String) async throws -> BrowserEvaluateResult
    func screenshot(session: BrowserSession, options: BrowserScreenshotOptions) async throws -> Data
    func extractText(session: BrowserSession) async throws -> String
    func extractMarkdown(session: BrowserSession) async throws -> String
    func extractHTML(session: BrowserSession) async throws -> String
}

public struct BrowserBackendAvailability: Sendable, Equatable {
    public let id: BrowserBackendID
    public let available: Bool
    public let detail: String

    public init(id: BrowserBackendID, available: Bool, detail: String) {
        self.id = id
        self.available = available
        self.detail = detail
    }
}

public struct BrowserFetchResult: Sendable, Equatable {
    public var url: String
    public var title: String?
    public var backend: String
    public var contentType: String
    public var content: String
    public var timing: BrowserFetchTiming

    public init(
        url: String,
        title: String?,
        backend: String,
        contentType: String,
        content: String,
        timing: BrowserFetchTiming
    ) {
        self.url = url
        self.title = title
        self.backend = backend
        self.contentType = contentType
        self.content = content
        self.timing = timing
    }
}

public struct BrowserFetchTiming: Sendable, Equatable {
    public var startupMs: Int
    public var navigationMs: Int
    public var extractionMs: Int

    public init(startupMs: Int, navigationMs: Int, extractionMs: Int) {
        self.startupMs = startupMs
        self.navigationMs = navigationMs
        self.extractionMs = extractionMs
    }
}
