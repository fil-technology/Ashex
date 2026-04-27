import AshexCore
import Foundation
import Testing

@Test func browserConfigDefaultsRemainSafeAndOptional() throws {
    let decoded = try JSONDecoder().decode(AshexUserConfig.self, from: Data("{}".utf8))

    #expect(decoded.browser.backend == .auto)
    #expect(decoded.browser.startupTimeoutSeconds == 10)
    #expect(decoded.browser.navigationTimeoutSeconds == 30)
    #expect(decoded.browser.obscura.host == "127.0.0.1")
    #expect(decoded.browser.obscura.port == 0)
    #expect(decoded.browser.obscura.stealth == false)
    #expect(decoded.browser.obscura.blockTrackers == true)
    #expect(decoded.browser.security.allowFileURLs == false)
    #expect(decoded.browser.security.allowLocalhostNavigation == false)
    #expect(decoded.browser.security.allowPrivateNetworkNavigation == false)
    #expect(decoded.browser.cdp.endpoint == nil)
}

@Test func browserConfigDecodesNestedBrowserSettings() throws {
    let data = Data(
        """
        {
          "browser": {
            "backend": "obscura",
            "startupTimeoutSeconds": 17,
            "navigationTimeoutSeconds": 44,
            "extraArgs": ["--foo", "--bar"],
            "environment": {
              "OBSCURA_LOG": "debug"
            },
            "obscura": {
              "path": "/usr/local/bin/obscura",
              "host": "127.0.0.1",
              "port": 7777,
              "stealth": true,
              "blockTrackers": false
            },
            "security": {
              "allowFileUrls": true,
              "allowLocalhostNavigation": true,
              "allowPrivateNetworkNavigation": true
            },
            "cdp": {
              "endpoint": "http://127.0.0.1:9222"
            }
          }
        }
        """.utf8
    )

    let decoded = try JSONDecoder().decode(AshexUserConfig.self, from: data)

    #expect(decoded.browser.backend == .obscura)
    #expect(decoded.browser.startupTimeoutSeconds == 17)
    #expect(decoded.browser.navigationTimeoutSeconds == 44)
    #expect(decoded.browser.extraArgs == ["--foo", "--bar"])
    #expect(decoded.browser.environment == ["OBSCURA_LOG": "debug"])
    #expect(decoded.browser.obscura.path == "/usr/local/bin/obscura")
    #expect(decoded.browser.obscura.port == 7777)
    #expect(decoded.browser.obscura.stealth)
    #expect(decoded.browser.obscura.blockTrackers == false)
    #expect(decoded.browser.security.allowFileURLs)
    #expect(decoded.browser.security.allowLocalhostNavigation)
    #expect(decoded.browser.security.allowPrivateNetworkNavigation)
    #expect(decoded.browser.cdp.endpoint == "http://127.0.0.1:9222")
}
