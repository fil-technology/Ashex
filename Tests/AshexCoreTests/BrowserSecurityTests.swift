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
