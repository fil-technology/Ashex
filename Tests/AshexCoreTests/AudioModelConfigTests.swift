import AshexCore
import Foundation
import Testing

@Test func audioConfigDefaultsToReuseChatModel() throws {
    let decoded = try JSONDecoder().decode(AshexUserConfig.self, from: Data("{}".utf8))

    #expect(decoded.audio.selection == .reuseChatModel)
    #expect(decoded.audio.provider == nil)
    #expect(decoded.audio.model == nil)
}

@Test func audioConfigResolvesConfiguredOverrideIndependentlyFromChatModel() {
    let config = AudioConfig(selection: .separateModel, provider: "esh", model: "voice-model")

    let resolved = config.resolvedModel(chatProvider: "openai", chatModel: "gpt-5.4-mini")

    #expect(resolved.provider == "esh")
    #expect(resolved.model == "voice-model")
    #expect(resolved.usesChatModel == false)
}

@Test func audioConfigReusesChatModelWhenVoiceCapable() {
    let config = AudioConfig(selection: .reuseChatModel)

    let resolved = config.resolvedModel(chatProvider: "openai", chatModel: "gpt-4o-audio-preview")

    #expect(resolved.provider == "openai")
    #expect(resolved.model == "gpt-4o-audio-preview")
    #expect(resolved.usesChatModel)
}

@Test func audioConfigFallsBackToLocalSpeechWhenChatModelHasNoVoiceSupport() {
    let config = AudioConfig(selection: .reuseChatModel)

    let resolved = config.resolvedModel(chatProvider: "openai", chatModel: "gpt-5.4-mini")

    #expect(resolved.provider == "local")
    #expect(resolved.model == "macos-say")
    #expect(resolved.usesChatModel == false)
}

@Test(arguments: [
    ("openai", "gpt-4o-audio-preview"),
    ("openai", "gpt-realtime"),
    ("esh", "voice-model"),
    ("ollama", "llama3.2-omni"),
])
func voiceSupportRecognizesMultimodalAudioModels(provider: String, model: String) {
    #expect(AudioModelSupport.supportsVoice(provider: provider, model: model))
}
