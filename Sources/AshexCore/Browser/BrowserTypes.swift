import Foundation

public enum BrowserBackendID: String, Codable, Sendable, CaseIterable {
    case auto
    case obscura
    case chromeCDP = "chrome-cdp"
}

public struct BrowserObscuraConfig: Codable, Sendable, Equatable {
    public var path: String?
    public var host: String
    public var port: Int
    public var stealth: Bool
    public var blockTrackers: Bool

    public init(
        path: String? = nil,
        host: String = "127.0.0.1",
        port: Int = 0,
        stealth: Bool = false,
        blockTrackers: Bool = true
    ) {
        self.path = path?.trimmingCharacters(in: .whitespacesAndNewlines).browserNilIfEmpty
        self.host = host
        self.port = max(0, port)
        self.stealth = stealth
        self.blockTrackers = blockTrackers
    }

    public static let `default` = BrowserObscuraConfig()

    private enum CodingKeys: String, CodingKey {
        case path
        case host
        case port
        case stealth
        case blockTrackers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decodeIfPresent(String.self, forKey: .path)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .browserNilIfEmpty
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? Self.default.host
        port = max(0, try container.decodeIfPresent(Int.self, forKey: .port) ?? Self.default.port)
        stealth = try container.decodeIfPresent(Bool.self, forKey: .stealth) ?? Self.default.stealth
        blockTrackers = try container.decodeIfPresent(Bool.self, forKey: .blockTrackers) ?? Self.default.blockTrackers
    }
}

public struct BrowserSecurityConfig: Codable, Sendable, Equatable {
    public var allowFileURLs: Bool
    public var allowLocalhostNavigation: Bool
    public var allowPrivateNetworkNavigation: Bool

    public init(
        allowFileURLs: Bool = false,
        allowLocalhostNavigation: Bool = false,
        allowPrivateNetworkNavigation: Bool = false
    ) {
        self.allowFileURLs = allowFileURLs
        self.allowLocalhostNavigation = allowLocalhostNavigation
        self.allowPrivateNetworkNavigation = allowPrivateNetworkNavigation
    }

    public static let `default` = BrowserSecurityConfig()

    private enum CodingKeys: String, CodingKey {
        case allowFileURLs
        case allowFileUrls
        case allowLocalhostNavigation
        case allowPrivateNetworkNavigation
    }

    private enum SnakeCodingKeys: String, CodingKey {
        case allowFileURLs = "allow_file_urls"
        case allowLocalhostNavigation = "allow_localhost_navigation"
        case allowPrivateNetworkNavigation = "allow_private_network_navigation"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let snakeContainer = try decoder.container(keyedBy: SnakeCodingKeys.self)
        allowFileURLs = try container.decodeIfPresent(Bool.self, forKey: .allowFileURLs)
            ?? container.decodeIfPresent(Bool.self, forKey: .allowFileUrls)
            ?? snakeContainer.decodeIfPresent(Bool.self, forKey: .allowFileURLs)
            ?? Self.default.allowFileURLs
        allowLocalhostNavigation = try container.decodeIfPresent(Bool.self, forKey: .allowLocalhostNavigation)
            ?? snakeContainer.decodeIfPresent(Bool.self, forKey: .allowLocalhostNavigation)
            ?? Self.default.allowLocalhostNavigation
        allowPrivateNetworkNavigation = try container.decodeIfPresent(Bool.self, forKey: .allowPrivateNetworkNavigation)
            ?? snakeContainer.decodeIfPresent(Bool.self, forKey: .allowPrivateNetworkNavigation)
            ?? Self.default.allowPrivateNetworkNavigation
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(allowFileURLs, forKey: .allowFileURLs)
        try container.encode(allowLocalhostNavigation, forKey: .allowLocalhostNavigation)
        try container.encode(allowPrivateNetworkNavigation, forKey: .allowPrivateNetworkNavigation)
    }
}

public struct BrowserCDPConfig: Codable, Sendable, Equatable {
    public var endpoint: String?

    public init(endpoint: String? = nil) {
        self.endpoint = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines).browserNilIfEmpty
    }

    public static let `default` = BrowserCDPConfig()

    private enum CodingKeys: String, CodingKey {
        case endpoint
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .browserNilIfEmpty
    }
}

public struct BrowserConfigSection: Codable, Sendable, Equatable {
    public var backend: BrowserBackendID
    public var executablePath: String?
    public var host: String?
    public var port: Int?
    public var startupTimeoutSeconds: Int
    public var navigationTimeoutSeconds: Int
    public var headless: Bool
    public var stealthEnabled: Bool
    public var blockTrackers: Bool
    public var extraArgs: [String]
    public var userDataDir: String?
    public var environment: [String: String]
    public var obscura: BrowserObscuraConfig
    public var security: BrowserSecurityConfig
    public var cdp: BrowserCDPConfig

    public init(
        backend: BrowserBackendID = .auto,
        executablePath: String? = nil,
        host: String? = nil,
        port: Int? = nil,
        startupTimeoutSeconds: Int = 10,
        navigationTimeoutSeconds: Int = 30,
        headless: Bool = true,
        stealthEnabled: Bool = false,
        blockTrackers: Bool = true,
        extraArgs: [String] = [],
        userDataDir: String? = nil,
        environment: [String: String] = [:],
        obscura: BrowserObscuraConfig = .default,
        security: BrowserSecurityConfig = .default,
        cdp: BrowserCDPConfig = .default
    ) {
        self.backend = backend
        self.executablePath = executablePath?.trimmingCharacters(in: .whitespacesAndNewlines).browserNilIfEmpty
        self.host = host?.trimmingCharacters(in: .whitespacesAndNewlines).browserNilIfEmpty
        self.port = port.map { max(0, $0) }
        self.startupTimeoutSeconds = max(1, startupTimeoutSeconds)
        self.navigationTimeoutSeconds = max(1, navigationTimeoutSeconds)
        self.headless = headless
        self.stealthEnabled = stealthEnabled
        self.blockTrackers = blockTrackers
        self.extraArgs = extraArgs
        self.userDataDir = userDataDir?.trimmingCharacters(in: .whitespacesAndNewlines).browserNilIfEmpty
        self.environment = environment
        self.obscura = obscura
        self.security = security
        self.cdp = cdp
    }

    public static let `default` = BrowserConfigSection()

    private enum CodingKeys: String, CodingKey {
        case backend
        case executablePath
        case host
        case port
        case startupTimeoutSeconds
        case navigationTimeoutSeconds
        case headless
        case stealthEnabled
        case blockTrackers
        case extraArgs
        case userDataDir
        case environment
        case obscura
        case security
        case cdp
    }

    private enum SnakeCodingKeys: String, CodingKey {
        case executablePath = "executable_path"
        case startupTimeoutSeconds = "startup_timeout_seconds"
        case navigationTimeoutSeconds = "navigation_timeout_seconds"
        case stealthEnabled = "stealth_enabled"
        case blockTrackers = "block_trackers"
        case extraArgs = "extra_args"
        case userDataDir = "user_data_dir"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let snakeContainer = try decoder.container(keyedBy: SnakeCodingKeys.self)
        backend = try container.decodeIfPresent(BrowserBackendID.self, forKey: .backend) ?? .auto
        executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .browserNilIfEmpty
            ?? snakeContainer.decodeIfPresent(String.self, forKey: .executablePath)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .browserNilIfEmpty
        host = try container.decodeIfPresent(String.self, forKey: .host)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .browserNilIfEmpty
        port = try container.decodeIfPresent(Int.self, forKey: .port).map { max(0, $0) }
        startupTimeoutSeconds = max(1, try container.decodeIfPresent(Int.self, forKey: .startupTimeoutSeconds)
            ?? snakeContainer.decodeIfPresent(Int.self, forKey: .startupTimeoutSeconds)
            ?? Self.default.startupTimeoutSeconds)
        navigationTimeoutSeconds = max(1, try container.decodeIfPresent(Int.self, forKey: .navigationTimeoutSeconds)
            ?? snakeContainer.decodeIfPresent(Int.self, forKey: .navigationTimeoutSeconds)
            ?? Self.default.navigationTimeoutSeconds)
        headless = try container.decodeIfPresent(Bool.self, forKey: .headless) ?? Self.default.headless
        stealthEnabled = try container.decodeIfPresent(Bool.self, forKey: .stealthEnabled)
            ?? snakeContainer.decodeIfPresent(Bool.self, forKey: .stealthEnabled)
            ?? Self.default.stealthEnabled
        blockTrackers = try container.decodeIfPresent(Bool.self, forKey: .blockTrackers)
            ?? snakeContainer.decodeIfPresent(Bool.self, forKey: .blockTrackers)
            ?? Self.default.blockTrackers
        extraArgs = try container.decodeIfPresent([String].self, forKey: .extraArgs)
            ?? snakeContainer.decodeIfPresent([String].self, forKey: .extraArgs)
            ?? []
        userDataDir = try container.decodeIfPresent(String.self, forKey: .userDataDir)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .browserNilIfEmpty
            ?? snakeContainer.decodeIfPresent(String.self, forKey: .userDataDir)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .browserNilIfEmpty
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        obscura = try container.decodeIfPresent(BrowserObscuraConfig.self, forKey: .obscura) ?? .default
        security = try container.decodeIfPresent(BrowserSecurityConfig.self, forKey: .security) ?? .default
        cdp = try container.decodeIfPresent(BrowserCDPConfig.self, forKey: .cdp) ?? .default
    }
}

public struct BrowserConfig: Sendable, Equatable {
    public var backend: BrowserBackendID
    public var executablePath: String?
    public var host: String
    public var port: Int
    public var startupTimeoutSeconds: Int
    public var navigationTimeoutSeconds: Int
    public var headless: Bool
    public var stealthEnabled: Bool
    public var blockTrackers: Bool
    public var extraArgs: [String]
    public var userDataDir: String?
    public var environment: [String: String]
    public var security: BrowserSecurityConfig
    public var cdpEndpoint: String?

    public init(
        backend: BrowserBackendID = .auto,
        executablePath: String? = nil,
        host: String = "127.0.0.1",
        port: Int = 0,
        startupTimeoutSeconds: Int = 10,
        navigationTimeoutSeconds: Int = 30,
        headless: Bool = true,
        stealthEnabled: Bool = false,
        blockTrackers: Bool = true,
        extraArgs: [String] = [],
        userDataDir: String? = nil,
        environment: [String: String] = [:],
        security: BrowserSecurityConfig = .default,
        cdpEndpoint: String? = nil
    ) {
        self.backend = backend
        self.executablePath = executablePath?.trimmingCharacters(in: .whitespacesAndNewlines).browserNilIfEmpty
        self.host = host
        self.port = max(0, port)
        self.startupTimeoutSeconds = max(1, startupTimeoutSeconds)
        self.navigationTimeoutSeconds = max(1, navigationTimeoutSeconds)
        self.headless = headless
        self.stealthEnabled = stealthEnabled
        self.blockTrackers = blockTrackers
        self.extraArgs = extraArgs
        self.userDataDir = userDataDir?.trimmingCharacters(in: .whitespacesAndNewlines).browserNilIfEmpty
        self.environment = environment
        self.security = security
        self.cdpEndpoint = cdpEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines).browserNilIfEmpty
    }
}

private extension String {
    var browserNilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
