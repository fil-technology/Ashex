import AshexCore
import Foundation
import Testing

@Test func browserURLValidatorRejectsFileURLsByDefault() throws {
    let validator = BrowserURLValidator(security: .default)

    #expect(throws: BrowserBackendError.self) {
        try validator.validate(URL(string: "file:///tmp/index.html")!)
    }
}

@Test func browserURLValidatorRejectsLocalhostByDefault() throws {
    let validator = BrowserURLValidator(security: .default)

    #expect(throws: BrowserBackendError.self) {
        try validator.validate(URL(string: "http://127.0.0.1:8080")!)
    }
}

@Test func browserURLValidatorRejectsPrivateNetworksByDefault() throws {
    let validator = BrowserURLValidator(security: .default)

    #expect(throws: BrowserBackendError.self) {
        try validator.validate(URL(string: "http://192.168.1.20/dashboard")!)
    }
}

@Test func browserURLValidatorAllowsPublicHTTPSNavigation() throws {
    let validator = BrowserURLValidator(security: .default)

    #expect(throws: Never.self) {
        try validator.validate(URL(string: "https://example.com/docs")!)
    }
}

@Test func browserURLNormalizerDefaultsSchemelessURLsToHTTPS() throws {
    #expect(BrowserURLNormalizer.normalize("example.com/docs")?.absoluteString == "https://example.com/docs")
    #expect(BrowserURLNormalizer.normalize("filsv.com")?.absoluteString == "https://filsv.com")
    #expect(BrowserURLNormalizer.normalize("www.filsv.com")?.absoluteString == "https://www.filsv.com")
    #expect(BrowserURLNormalizer.normalize("filsv.com:443/about")?.absoluteString == "https://filsv.com:443/about")
    #expect(BrowserURLNormalizer.normalize("  //example.com/docs  ")?.absoluteString == "https://example.com/docs")
    #expect(BrowserURLNormalizer.normalize("http://example.com/docs")?.absoluteString == "http://example.com/docs")
    #expect(BrowserURLNormalizer.normalize("file:///tmp/index.html")?.absoluteString == "file:///tmp/index.html")
}

@Test func browserURLNormalizerPreservesUnsupportedSchemesForSecurityValidation() throws {
    #expect(BrowserURLNormalizer.normalize("mailto:user@example.com")?.scheme == "mailto")
    #expect(BrowserURLNormalizer.normalize("data:text/plain,hello")?.scheme == "data")
}

@Test func browserURLValidatorRejectsNormalizedBareLocalhostByDefault() throws {
    let validator = BrowserURLValidator(security: .default)
    let url = try #require(BrowserURLNormalizer.normalize("localhost:3000"))

    #expect(throws: BrowserBackendError.self) {
        try validator.validate(url)
    }
}

@Test func browserURLValidatorAllowsExplicitlyEnabledLocalTargets() throws {
    let validator = BrowserURLValidator(security: .init(
        allowFileURLs: true,
        allowLocalhostNavigation: true,
        allowPrivateNetworkNavigation: true
    ))

    #expect(throws: Never.self) {
        try validator.validate(URL(string: "file:///tmp/index.html")!)
    }
    #expect(throws: Never.self) {
        try validator.validate(URL(string: "http://localhost:3000")!)
    }
    #expect(throws: Never.self) {
        try validator.validate(URL(string: "http://10.0.0.4/health")!)
    }
}
