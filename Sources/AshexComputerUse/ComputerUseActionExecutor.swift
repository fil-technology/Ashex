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
        case .moveMouse(let x, let y):
            try await provider.moveMouse(x: x, y: y)
        case .clickAt(let x, let y, let button, let clickCount):
            try await provider.click(x: x, y: y, button: button, clickCount: clickCount)
        case .doubleClick(let x, let y):
            try await provider.click(x: x, y: y, button: .left, clickCount: 2)
        case .rightClick(let x, let y):
            try await provider.click(x: x, y: y, button: .right, clickCount: 1)
        case .drag(let fromX, let fromY, let toX, let toY):
            try await provider.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY)
        case .typeText(let text):
            try await provider.typeText(text, windowId: windowId)
        case .pressKey(let key, let modifiers):
            try await provider.pressKey(key, modifiers: modifiers, windowId: windowId)
        case .scroll(let direction, let amount):
            try await provider.scroll(direction: direction, amount: amount, windowId: windowId)
        case .openApp(let name):
            try await provider.openApp(named: name)
        case .openURL(let url):
            try await provider.openURL(url)
        case .wait(let seconds):
            try await provider.wait(seconds: seconds)
        case .captureScreenshot:
            _ = try await provider.captureScreenshot(windowId: windowId)
        case .refreshState, .quit:
            break
        }
    }
}
