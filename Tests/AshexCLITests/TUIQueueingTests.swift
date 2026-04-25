@testable import AshexCLI
import Foundation
import Testing

@Test func promptQueueTracksOrderAndFrontRequeue() {
    var queue = PromptQueueState()

    let first = queue.enqueue("first")
    let second = queue.enqueue("second")

    #expect(queue.count == 2)
    #expect(queue.dequeue() == first)

    queue.requeueAtFront(first.incrementingAttemptCount())

    #expect(queue.count == 2)
    #expect(queue.dequeue()?.id == first.id)
    #expect(queue.dequeue() == second)
    #expect(queue.isEmpty)
}

@Test func promptFailureRoutingRetriesTransientProviderFailures() {
    #expect(PromptFailureRouting.shouldRetry(message: "429 Too Many Requests"))
    #expect(PromptFailureRouting.shouldRetry(message: "Model is temporarily unavailable, try again later"))
    #expect(PromptFailureRouting.shouldRetry(message: "connection refused"))
    #expect(!PromptFailureRouting.shouldRetry(message: "Ollama request failed with HTTP 500: out of memory"))
    #expect(!PromptFailureRouting.shouldRetry(message: "Run cancelled by user"))
    #expect(!PromptFailureRouting.shouldRetry(message: "Prompt violated policy"))
}

@Test func providerFailureRoutingIdentifiesOllamaResourceFailures() {
    let message = "Ollama request for model 'gemma4:latest' failed with HTTP 500: out of memory"

    #expect(ProviderFailureRouting.isOllamaModelResourceFailure(message: message))
    #expect(ProviderFailureRouting.isOllamaModelResourceFailure(message: "out of memory"))
    #expect(ProviderFailureRouting.recoveryHint(provider: "ollama", message: message).contains("Ollama is running"))
    #expect(ProviderFailureRouting.runtimeFailureDetails(provider: "ollama", message: message).first == "Selected Ollama model could not fit in available memory.")
    #expect(!ProviderFailureRouting.recoveryHint(provider: "ollama", message: message).contains("ollama serve"))
}

@Test func providerFailureRoutingPrioritizesStoragePressure() {
    let message = "Ashex could not write to its local history database at /tmp/ashex.sqlite because the storage volume is nearly full (120 MB free). Free disk space or launch Ashex with `--storage` pointing to a roomier location."

    #expect(StorageFailureRouting.isStoragePressure(message: message))
    #expect(ProviderFailureRouting.runtimeFailureDetails(provider: "ollama", message: message).first == "Ashex could not write to its local history database because storage is nearly full.")
    #expect(ProviderFailureRouting.recoveryHint(provider: "ollama", message: message).contains("--storage"))
    #expect(!ProviderFailureRouting.recoveryHint(provider: "ollama", message: message).contains("ollama serve"))
}

@Test func eshProviderRecoveryHintExplainsHowToRestoreRuntime() {
    let hint = ProviderFailureRouting.recoveryHint(provider: "esh")

    #expect(hint.contains("`esh`"))
    #expect(hint.contains("Provider Settings"))
}

@Test func eshProviderRecoveryHintHandlesMemoryPressure() {
    let message = "out of memory"
    let hint = ProviderFailureRouting.recoveryHint(provider: "esh", message: message)
    let details = ProviderFailureRouting.runtimeFailureDetails(provider: "esh", message: message)

    #expect(hint.contains("fit in memory"))
    #expect(details.first == "Selected `esh` model could not fit in available memory.")
}

@Test func versionFlagIsRecognized() {
    #expect(AshexCLI.isVersionRequested(arguments: ["ashex", "--version"]))
    #expect(AshexCLI.isVersionRequested(arguments: ["ashex", "-v"]))
    #expect(!AshexCLI.isVersionRequested(arguments: ["ashex", "hello"]))
}

@Test func appBuildInfoFormatsVersionAndCommit() {
    let info = AppBuildInfo.load(
        environment: [
            "ASHEX_VERSION": "v1.2.3",
            "ASHEX_COMMIT": "abc1234"
        ],
        executableURL: nil,
        sourceFilePath: "/tmp/not-a-repo/AppBuildInfo.swift"
    )

    #expect(info.displayLabel == "v1.2.3+abc1234")
}

@Test func workspaceSelectionClampMatchesVisibleWorkspaceList() {
    #expect(WorkspaceSelection.clamped(-1, recentWorkspaceCount: 3) == 0)
    #expect(WorkspaceSelection.clamped(3, recentWorkspaceCount: 3) == 3)
    #expect(WorkspaceSelection.clamped(12, recentWorkspaceCount: 20) == WorkspaceSelection.visibleRecentWorkspaceLimit)
    #expect(WorkspaceSelection.maxSelectionIndex(for: 0) == 0)
}

@Test func daemonDisplayStateShowsActionableStoppedStartingFailureAndRunningStates() {
    let stopped = TUIApp.DaemonDisplayState.make(
        status: nil,
        isStarting: false,
        lastError: nil,
        timeString: { _ in "now" }
    )
    #expect(stopped.summary == "Stopped")
    #expect(stopped.detailLines.contains { $0.contains("Startup errors will appear here") })
    #expect(!stopped.detailLines.contains { $0.contains("after the onboarding checklist") })

    let starting = TUIApp.DaemonDisplayState.make(
        status: nil,
        isStarting: true,
        lastError: "Previous problem",
        timeString: { _ in "now" }
    )
    #expect(starting.summary == "Starting...")
    #expect(starting.detailLines.contains("Starting daemon in background..."))
    #expect(starting.detailLines.contains("Previous failure: Previous problem"))

    let failed = TUIApp.DaemonDisplayState.make(
        status: nil,
        isStarting: false,
        lastError: "Missing Telegram token",
        timeString: { _ in "now" }
    )
    #expect(failed.summary == "Failed to start")
    #expect(failed.detailLines.contains("Last startup error: Missing Telegram token"))

    let running = TUIApp.DaemonDisplayState.make(
        status: DaemonProcessStatus(pid: 42, startedAt: Date(timeIntervalSince1970: 0), logPath: "/tmp/daemon.log", isRunning: true),
        isStarting: false,
        lastError: "Old failure",
        timeString: { _ in "epoch" }
    )
    #expect(running.summary == "Running (pid 42)")
    #expect(running.detailLines == ["Running with pid 42", "Started epoch", "Log: /tmp/daemon.log"])
}

@Test func ollamaModelOrderingPrefersGeneralModelsOverFunctionModels() {
    let ordered = OllamaModelDisplayOrdering.orderedDisplayNames(
        [
            "functiongemma:latest • 300 MB",
            "gemma4:latest • 9.6 GB"
        ],
        selectedModel: "llama3.2"
    )

    #expect(ordered.first == "gemma4:latest • 9.6 GB")
}

@Test func ollamaModelOrderingKeepsUsableSelectedModelFirst() {
    let ordered = OllamaModelDisplayOrdering.orderedDisplayNames(
        [
            "qwen2.5-coder:7b • 4.7 GB",
            "gemma4:latest • 9.6 GB"
        ],
        selectedModel: "qwen2.5-coder:7b"
    )

    #expect(ordered.first == "qwen2.5-coder:7b • 4.7 GB")
}

@Test func ollamaOnboardingSafestModelPrefersSmallestGeneralInstalledModel() {
    let selected = OllamaModelDisplayOrdering.safestInstalledModelName(
        from: [
            "gemma4:latest • 9.6 GB",
            "functiongemma:latest • 300.8 MB"
        ]
    )

    #expect(selected == "gemma4:latest")
}

@Test func ollamaOnboardingSafestModelPrefersGranite4OneBWhenInstalled() {
    let selected = OllamaModelDisplayOrdering.safestInstalledModelName(
        from: [
            "qwen3:0.6b • 522 MB",
            "granite4:1b • 3.3 GB",
            "gemma4:latest • 9.6 GB"
        ]
    )

    #expect(selected == "granite4:1b")
}

@Test func eshMemoryRecoveryCanChooseDifferentSmallerInstalledModel() {
    let selected = OllamaModelDisplayOrdering.safestInstalledModelName(
        from: [
            "bartowski--llama-3.2-3b-instruct-gguf • gguf",
            "qwen3:0.6b • mlx",
            "functiongemma:latest • gguf"
        ],
        excluding: "bartowski--llama-3.2-3b-instruct-gguf"
    )

    #expect(selected == "qwen3:0.6b")
}

@Test func eshAudioModelCatalogBuildsProviderQualifiedChoices() {
    let choices = EshAudioModelCatalog.choices(from: [
        "audio-model • mlx",
        "voice-model • gguf"
    ])

    #expect(choices.map(\.title) == ["esh/audio-model", "esh/voice-model"])
    #expect(choices.first?.model == "audio-model")
    #expect(choices.first?.subtitle == "audio-model • mlx")
}

@Test func ollamaModelOrderingShowsCuratedOnboardingModelsFirst() {
    let ordered = OllamaModelDisplayOrdering.orderedDisplayNames(
        [
            "gemma4:latest • 9.6 GB",
            "qwen3:0.6b • 522 MB",
            "granite4:1b • 3.3 GB",
            "granite4:350m • 708 MB"
        ],
        selectedModel: "llama3.2"
    )

    #expect(ordered.prefix(3) == [
        "granite4:1b • 3.3 GB",
        "qwen3:0.6b • 522 MB",
        "granite4:350m • 708 MB"
    ])
}
