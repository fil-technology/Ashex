import AshexCore
import Testing

@Test func modelRoutingResolvesPurposeOverridesAndFallsBackToCapabilityDefaults() {
    let config = ModelRoutingConfig(
        fast: .init(provider: "openai", model: "gpt-5-mini"),
        reasoning: .init(provider: "openai", model: "gpt-5"),
        local: .init(provider: "ollama", model: "qwen3:8b"),
        vision: .init(provider: "openai", model: "gpt-5-vision"),
        audio: .init(provider: "openai", model: "gpt-4o-transcribe"),
        purposeRoutes: [
            .planning: .reasoning,
            .summarization: .fast,
            .verification: .reasoning,
            .skillAmendment: .local,
        ]
    )

    #expect(config.route(for: .planning).model == "gpt-5")
    #expect(config.route(for: .summarization).model == "gpt-5-mini")
    #expect(config.route(for: .skillAmendment).provider == "ollama")
    #expect(config.route(for: .visionUnderstanding).model == "gpt-5-vision")
    #expect(config.route(for: .audioTranscription).model == "gpt-4o-transcribe")
    #expect(config.slot(for: .verification) == .reasoning)
}
