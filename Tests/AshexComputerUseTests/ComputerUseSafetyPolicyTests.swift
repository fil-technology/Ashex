import AshexComputerUse
import Testing

@Test func strictSafetyRequiresConfirmationForRiskyActions() {
    let policy = ComputerUseSafetyPolicy(mode: .strict)
    let state = ComputerUseWindowState(
        windowID: "win-1",
        title: "Documents",
        appName: "Notes",
        url: nil,
        elements: []
    )

    #expect(policy.evaluate(.refreshState, state: state) == .allow())
    #expect(policy.evaluate(.scroll(direction: .down, amount: 1), state: state) == .allow())
    #expect(policy.evaluate(.click(elementId: "12"), state: state).requiresConfirmation)
    #expect(policy.evaluate(.typeText("hello"), state: state).requiresConfirmation)
    #expect(policy.evaluate(.pressKey(key: "Enter", modifiers: []), state: state).requiresConfirmation)
    #expect(policy.evaluate(.pressKey(key: "L", modifiers: ["cmd"]), state: state).requiresConfirmation)
}

@Test func strictSafetyBlocksSensitiveTargetsOutsideDevMode() {
    let policy = ComputerUseSafetyPolicy(mode: .strict)
    let state = ComputerUseWindowState(
        windowID: "win-2",
        title: "Vault",
        appName: "1Password",
        url: nil,
        elements: []
    )

    let decision = policy.evaluate(.click(elementId: "1"), state: state)
    #expect(!decision.isAllowed)
    #expect(decision.reason?.contains("sensitive") == true)
}

@Test func devSafetyAllowsSensitiveTargets() {
    let policy = ComputerUseSafetyPolicy(mode: .dev)
    let state = ComputerUseWindowState(
        windowID: "win-3",
        title: "System Settings",
        appName: "System Settings",
        url: nil,
        elements: []
    )

    let decision = policy.evaluate(.click(elementId: "1"), state: state)
    #expect(decision.isAllowed)
}
