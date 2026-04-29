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

@Test func generationConfigDecodesSnakeCaseModelOptions() throws {
    let data = Data("""
    {
      "generation": {
        "temperature": 0.8,
        "top_p": 0.9,
        "top_k": 40,
        "min_p": 0.05,
        "repetition_penalty": 1.1,
        "seed": 42,
        "options": {
          "mirostat": 1
        }
      }
    }
    """.utf8)

    let config = try JSONDecoder().decode(AshexUserConfig.self, from: data)

    #expect(config.generation.temperature == 0.8)
    #expect(config.generation.topP == 0.9)
    #expect(config.generation.topK == 40)
    #expect(config.generation.minP == 0.05)
    #expect(config.generation.repetitionPenalty == 1.1)
    #expect(config.generation.seed == 42)
    #expect(config.generation.options["mirostat"] == .number(1))
}
