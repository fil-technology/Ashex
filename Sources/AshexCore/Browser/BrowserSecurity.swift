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

public enum BrowserURLNormalizer {
    public static func normalize(_ rawURL: String) -> URL? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("//") {
            return URL(string: "https:" + trimmed)
        }

        if trimmed.hasPrefix("/") {
            return nil
        }

        if explicitScheme(in: trimmed) != nil {
            return URL(string: trimmed)
        }

        return URL(string: "https://" + trimmed)
    }

    private static func explicitScheme(in value: String) -> String? {
        guard let colonIndex = value.firstIndex(of: ":") else { return nil }

        let candidate = String(value[..<colonIndex]).lowercased()
        guard isValidScheme(candidate) else { return nil }

        let remainder = value[value.index(after: colonIndex)...]
        if isLikelyBareHostWithPort(candidate, remainder: remainder) {
            return nil
        }

        return candidate
    }

    private static func isValidScheme(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              CharacterSet.letters.contains(first) else {
            return false
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+-."))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isLikelyBareHostWithPort(_ host: String, remainder: Substring) -> Bool {
        let port = remainder.prefix { character in
            character != "/" && character != "?" && character != "#"
        }
        guard !port.isEmpty, port.allSatisfy(\.isNumber) else {
            return false
        }

        return host == "localhost" || host.contains(".")
    }
}
