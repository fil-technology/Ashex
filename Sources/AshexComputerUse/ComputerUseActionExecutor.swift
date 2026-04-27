import Foundation

public struct ComputerUseActionExecutor: Sendable {
    public let provider: any ComputerUseProvider

    public init(provider: any ComputerUseProvider) {
        self.provider = provider
    }

    public func execute(_ action: ComputerUseAction, windowId: String) async throws {
        switch action {
        case .click(let elementId):
            try await provider.click(elementId: elementId, windowId: windowId)
        case .typeText(let text):
            try await provider.typeText(text, windowId: windowId)
        case .pressKey(let key, let modifiers):
            try await provider.pressKey(key, modifiers: modifiers, windowId: windowId)
        case .scroll(let direction, let amount):
            try await provider.scroll(direction: direction, amount: amount, windowId: windowId)
        case .captureScreenshot:
            _ = try await provider.captureScreenshot(windowId: windowId)
        case .refreshState, .quit:
            break
        }
    }
}
