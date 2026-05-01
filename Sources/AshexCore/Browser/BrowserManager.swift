import Foundation

public enum BrowserContentFormat: String, Sendable {
    case markdown
    case text
    case html
}

public struct BrowserDoctorReport: Codable, Sendable, Equatable {
    public var configuredBackend: String
    public var obscuraPath: String?
    public var obscuraAvailable: Bool
    public var obscuraDetail: String
    public var chromeExecutablePath: String?
    public var chromeAvailable: Bool
    public var chromeDetail: String
    public var cdpEndpoint: String
    public var cdpReachable: Bool
    public var cdpDetail: String
    public var limitations: [String]
}

public final class BrowserManager: Sendable {
    private let configSection: BrowserConfigSection
    private let validator: BrowserURLValidator
    private let obscuraBackend: ObscuraBrowserBackend
    private let chromeBackend: ChromeCdpBrowserBackend

    public init(
        configSection: BrowserConfigSection,
        obscuraBackend: ObscuraBrowserBackend = .init(),
        chromeBackend: ChromeCdpBrowserBackend = .init()
    ) {
        self.configSection = configSection
        self.validator = BrowserURLValidator(security: configSection.security)
        self.obscuraBackend = obscuraBackend
        self.chromeBackend = chromeBackend
    }

    public func availableBackends(override backend: BrowserBackendID? = nil) async -> [BrowserBackendAvailability] {
        let preferred = backend ?? configSection.backend
        let obscuraConfig = resolvedConfig(for: .obscura)
        let chromeConfig = resolvedConfig(for: .chromeCDP)

        switch preferred {
        case .obscura:
            return [await obscuraBackend.isAvailable(config: obscuraConfig)]
        case .chromeCDP:
            return [await chromeBackend.isAvailable(config: chromeConfig)]
        case .auto:
            return [
                await obscuraBackend.isAvailable(config: obscuraConfig),
                await chromeBackend.isAvailable(config: chromeConfig),
            ]
        }
    }

    public func doctor() async -> BrowserDoctorReport {
        let obscuraConfig = resolvedConfig(for: .obscura)
        let chromeConfig = resolvedConfig(for: .chromeCDP)
        let obscuraStatus = await obscuraBackend.isAvailable(config: obscuraConfig)
        let chromeStatus = await chromeBackend.isAvailable(config: chromeConfig)
        let chromeEndpointStatus = await chromeBackend.endpointAvailability(config: chromeConfig)

        return BrowserDoctorReport(
            configuredBackend: configSection.backend.rawValue,
            obscuraPath: BrowserExecutableDiscovery.resolveExecutable(
                configuredPath: obscuraConfig.executablePath,
                defaultName: "obscura",
                environment: obscuraConfig.environment
            ),
            obscuraAvailable: obscuraStatus.available,
            obscuraDetail: obscuraStatus.detail,
            chromeExecutablePath: BrowserExecutableDiscovery.resolveChromeExecutable(
                configuredPath: chromeConfig.executablePath,
                environment: chromeConfig.environment
            ),
            chromeAvailable: chromeStatus.available,
            chromeDetail: chromeStatus.detail,
            cdpEndpoint: chromeConfig.cdpEndpoint ?? "http://\(chromeConfig.host):\(chromeConfig.port)",
            cdpReachable: chromeEndpointStatus.available,
            cdpDetail: chromeEndpointStatus.detail,
            limitations: [
                "Obscura support is experimental and may vary by installed version and supported flags.",
                "Markdown extraction falls back to text-oriented DOM extraction when custom backend methods are unavailable.",
                "Localhost, private-network, and file URLs are blocked by default unless explicitly enabled in config."
            ]
        )
    }

    public func fetch(
        url: URL,
        format: BrowserContentFormat = .markdown,
        backend: BrowserBackendID? = nil,
        timeoutSeconds: Int? = nil
    ) async throws -> BrowserFetchResult {
        try validator.validate(url)
        let resolvedBackend = try await resolveBackend(override: backend)
        let config = resolvedConfig(for: resolvedBackend.id, timeoutSeconds: timeoutSeconds)

        let startupStarted = Date()
        let session = try await resolvedBackend.start(config: config)
        defer { Task { try? await resolvedBackend.stop(session: session) } }
        let startupMs = Int(Date().timeIntervalSince(startupStarted) * 1000)

        let navigationStarted = Date()
        let page = try await resolvedBackend.navigate(
            session: session,
            url: url,
            options: BrowserNavigateOptions(timeoutSeconds: config.navigationTimeoutSeconds)
        )
        let navigationMs = Int(Date().timeIntervalSince(navigationStarted) * 1000)

        let extractionStarted = Date()
        let content: String
        switch format {
        case .markdown:
            content = try await resolvedBackend.extractMarkdown(session: session)
        case .text:
            content = try await resolvedBackend.extractText(session: session)
        case .html:
            content = try await resolvedBackend.extractHTML(session: session)
        }
        let extractionMs = Int(Date().timeIntervalSince(extractionStarted) * 1000)

        return BrowserFetchResult(
            url: page.url,
            title: page.title,
            backend: resolvedBackend.id.rawValue,
            contentType: format.rawValue,
            content: content,
            timing: BrowserFetchTiming(
                startupMs: startupMs,
                navigationMs: navigationMs,
                extractionMs: extractionMs
            )
        )
    }

    public func evaluate(
        url: URL,
        expression: String,
        backend: BrowserBackendID? = nil,
        timeoutSeconds: Int? = nil
    ) async throws -> (BrowserPageResult, BrowserEvaluateResult) {
        try validator.validate(url)
        let resolvedBackend = try await resolveBackend(override: backend)
        let config = resolvedConfig(for: resolvedBackend.id, timeoutSeconds: timeoutSeconds)
        let session = try await resolvedBackend.start(config: config)
        defer { Task { try? await resolvedBackend.stop(session: session) } }
        let page = try await resolvedBackend.navigate(
            session: session,
            url: url,
            options: BrowserNavigateOptions(timeoutSeconds: config.navigationTimeoutSeconds)
        )
        let result = try await resolvedBackend.evaluate(session: session, expression: expression)
        return (page, result)
    }

    public func screenshot(
        url: URL,
        backend: BrowserBackendID? = nil,
        timeoutSeconds: Int? = nil
    ) async throws -> (BrowserPageResult, Data) {
        try validator.validate(url)
        let resolvedBackend = try await resolveBackend(override: backend)
        let config = resolvedConfig(for: resolvedBackend.id, timeoutSeconds: timeoutSeconds)
        let session = try await resolvedBackend.start(config: config)
        defer { Task { try? await resolvedBackend.stop(session: session) } }
        let page = try await resolvedBackend.navigate(
            session: session,
            url: url,
            options: BrowserNavigateOptions(timeoutSeconds: config.navigationTimeoutSeconds)
        )
        let data = try await resolvedBackend.screenshot(session: session, options: .init())
        return (page, data)
    }

    public func benchmark(
        url: URL,
        backend: BrowserBackendID? = nil,
        timeoutSeconds: Int? = nil
    ) async -> BrowserBenchmarkResult {
        do {
            try validator.validate(url)
            let resolvedBackend = try await resolveBackend(override: backend)
            let config = resolvedConfig(for: resolvedBackend.id, timeoutSeconds: timeoutSeconds)
            let startupStarted = Date()
            let session = try await resolvedBackend.start(config: config)
            let startupMs = Int(Date().timeIntervalSince(startupStarted) * 1000)
            defer { Task { try? await resolvedBackend.stop(session: session) } }

            let readyMs = session.readyDurationMs

            let navigationStarted = Date()
            _ = try await resolvedBackend.navigate(
                session: session,
                url: url,
                options: BrowserNavigateOptions(timeoutSeconds: config.navigationTimeoutSeconds)
            )
            let navigationMs = Int(Date().timeIntervalSince(navigationStarted) * 1000)

            let extractionStarted = Date()
            _ = try await resolvedBackend.extractMarkdown(session: session)
            let extractionMs = Int(Date().timeIntervalSince(extractionStarted) * 1000)

            let screenshotStarted = Date()
            _ = try await resolvedBackend.screenshot(session: session, options: .init())
            let screenshotMs = Int(Date().timeIntervalSince(screenshotStarted) * 1000)

            return BrowserBenchmarkResult(
                backend: resolvedBackend.id.rawValue,
                executablePath: session.executablePath,
                startupMs: startupMs,
                readyMs: readyMs,
                navigationMs: navigationMs,
                extractionMs: extractionMs,
                screenshotMs: screenshotMs,
                peakRSSBytes: nil,
                success: true
            )
        } catch {
            return BrowserBenchmarkResult(
                backend: (backend ?? configSection.backend).rawValue,
                executablePath: configSection.obscura.path,
                startupMs: 0,
                readyMs: 0,
                navigationMs: 0,
                extractionMs: 0,
                screenshotMs: 0,
                peakRSSBytes: nil,
                success: false,
                errorSummary: error.localizedDescription
            )
        }
    }

    public func startSession(backend override: BrowserBackendID? = nil, timeoutSeconds: Int? = nil) async throws -> (any BrowserBackend, BrowserSession) {
        let backend = try await resolveBackend(override: override)
        let config = resolvedConfig(for: backend.id, timeoutSeconds: timeoutSeconds)
        let session = try await backend.start(config: config)
        return (backend, session)
    }

    private func resolveBackend(override requested: BrowserBackendID?) async throws -> any BrowserBackend {
        switch requested ?? configSection.backend {
        case .obscura:
            let availability = await obscuraBackend.isAvailable(config: resolvedConfig(for: .obscura))
            guard availability.available else {
                throw BrowserBackendError.unavailable(availability.detail)
            }
            return obscuraBackend
        case .chromeCDP:
            return chromeBackend
        case .auto:
            let obscuraStatus = await obscuraBackend.isAvailable(config: resolvedConfig(for: .obscura))
            if obscuraStatus.available {
                return obscuraBackend
            }
            return chromeBackend
        }
    }

    private func resolvedConfig(for backend: BrowserBackendID, timeoutSeconds: Int? = nil) -> BrowserConfig {
        let host = configSection.host ?? configSection.obscura.host
        let port = configSection.port ?? configSection.obscura.port
        let executablePath = configSection.executablePath ?? configSection.obscura.path
        let stealthEnabled = configSection.stealthEnabled || configSection.obscura.stealth
        let blockTrackers = configSection.blockTrackers && configSection.obscura.blockTrackers
        let navigationTimeout = timeoutSeconds ?? configSection.navigationTimeoutSeconds

        switch backend {
        case .obscura:
            return BrowserConfig(
                backend: backend,
                executablePath: executablePath,
                host: host,
                port: port,
                startupTimeoutSeconds: configSection.startupTimeoutSeconds,
                navigationTimeoutSeconds: navigationTimeout,
                headless: configSection.headless,
                stealthEnabled: stealthEnabled,
                blockTrackers: blockTrackers,
                extraArgs: configSection.extraArgs,
                userDataDir: configSection.userDataDir,
                environment: configSection.environment,
                security: configSection.security,
                cdpEndpoint: nil
            )
        case .chromeCDP, .auto:
            return BrowserConfig(
                backend: backend,
                executablePath: executablePath,
                host: host,
                port: port == 0 ? 9222 : port,
                startupTimeoutSeconds: configSection.startupTimeoutSeconds,
                navigationTimeoutSeconds: navigationTimeout,
                headless: configSection.headless,
                stealthEnabled: stealthEnabled,
                blockTrackers: blockTrackers,
                extraArgs: configSection.extraArgs,
                userDataDir: configSection.userDataDir,
                environment: configSection.environment,
                security: configSection.security,
                cdpEndpoint: configSection.cdp.endpoint
            )
        }
    }
}
