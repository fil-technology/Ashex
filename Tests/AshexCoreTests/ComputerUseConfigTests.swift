import AshexCore
import Foundation
import Testing

@Test func computerUseConfigDecodesDefaultsAndSnakeCaseSafety() throws {
    let data = Data("""
    {
      "computer_use": {
        "enabled": true,
        "backend_manifest_path": "/tmp/background-computer-use.json",
        "safety": "dev"
      }
    }
    """.utf8)

    let config = try JSONDecoder().decode(AshexUserConfig.self, from: data)

    #expect(config.computerUse.enabled)
    #expect(config.computerUse.backendManifestPath == "/tmp/background-computer-use.json")
    #expect(config.computerUse.safety.rawValue == "dev")
}
