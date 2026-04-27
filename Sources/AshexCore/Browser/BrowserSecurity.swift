import Foundation

public enum BrowserBackendError: LocalizedError, Sendable, Equatable {
    case invalidURL(String)
    case blockedURL(String)
    case unavailable(String)
    case startupFailed(String)
    case timeout(String)
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let message),
             .blockedURL(let message),
             .unavailable(let message),
             .startupFailed(let message),
             .timeout(let message),
             .protocolError(let message):
            return message
        }
    }
}

public struct BrowserURLValidator: Sendable {
    public let security: BrowserSecurityConfig

    public init(security: BrowserSecurityConfig) {
        self.security = security
    }

    public func validate(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() ?? localHostFallback(for: url) else {
            throw BrowserBackendError.invalidURL("Browser navigation requires an absolute URL with a supported scheme.")
        }

        switch scheme {
        case "http", "https":
            break
        case "file":
            guard security.allowFileURLs else {
                throw BrowserBackendError.blockedURL("Navigation to file URLs is disabled by default. Set browser.security.allowFileUrls=true to enable it.")
            }
            return
        default:
            throw BrowserBackendError.invalidURL("Unsupported browser URL scheme '\(scheme)'. Only http, https, and optionally file are allowed.")
        }

        if isLocalhost(host) {
            guard security.allowLocalhostNavigation else {
                throw BrowserBackendError.blockedURL("Navigation to localhost targets is disabled by default. Set browser.security.allowLocalhostNavigation=true to enable it.")
            }
            return
        }

        if isPrivateNetwork(host) {
            guard security.allowPrivateNetworkNavigation else {
                throw BrowserBackendError.blockedURL("Navigation to private-network targets is disabled by default. Set browser.security.allowPrivateNetworkNavigation=true to enable it.")
            }
        }
    }

    private func localHostFallback(for url: URL) -> String? {
        url.isFileURL ? "file" : nil
    }

    private func isLocalhost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func isPrivateNetwork(_ host: String) -> Bool {
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("169.254.") {
            return true
        }

        if host.hasPrefix("172."),
           let secondOctet = host.split(separator: ".").dropFirst().first,
           let value = Int(secondOctet),
           (16...31).contains(value) {
            return true
        }

        if host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:") {
            return true
        }

        return false
    }
}
