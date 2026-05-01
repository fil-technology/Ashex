import AshexCore
@testable import AshexComputerUse
import Foundation
import Testing

@Test func computerUseToolListsWindowsAndExposesGuiOperations() async throws {
    let provider = RecordingComputerUseProvider()
    let tool = ComputerUseTool(provider: provider, safetyPolicy: .init(mode: .strict))

    let operations = Set(tool.contract.operations.map(\.name))
    #expect(operations.isSuperset(of: [
        "list_windows", "focus_app", "move_mouse", "click", "double_click", "right_click",
        "drag", "type_text", "press_keys", "scroll", "open_app", "open_url", "screenshot", "wait",
    ]))

    let result = try await tool.execute(
        arguments: ["operation": .string("list_windows")],
        context: .testComputerUseContext()
    )

    guard case .structured(let value) = result else {
        Issue.record("Expected structured window list")
        return
    }
    let windows = try #require(value.objectValue?["windows"]?.arrayValue)
    #expect(windows.count == 1)
    #expect(windows.first?.objectValue?["app_name"]?.stringValue == "Google Chrome")
}

@Test func computerUseToolRequiresApprovalForStateChangingStrictActions() async throws {
    let provider = RecordingComputerUseProvider()
    let tool = ComputerUseTool(provider: provider, safetyPolicy: .init(mode: .strict))

    await #expect(throws: AshexError.self) {
        _ = try await tool.execute(
            arguments: [
                "operation": .string("click"),
                "x": .number(10),
                "y": .number(20),
            ],
            context: .testComputerUseContext(approvalGranted: false)
        )
    }

    _ = try await tool.execute(
        arguments: [
            "operation": .string("click"),
            "x": .number(10),
            "y": .number(20),
        ],
        context: .testComputerUseContext(approvalGranted: true)
    )

    #expect(provider.recordedActions() == ["click:left:10.0:20.0:1"])
}

@Test func computerUseCommandParserSupportsOpenAndPointerCommands() throws {
    let parser = ComputerUseCommandParser()

    #expect(try parser.parse("open url https://example.com") == .openURL("https://example.com"))
    #expect(try parser.parse("open app Google Chrome") == .openApp("Google Chrome"))
    #expect(try parser.parse("move 10 20") == .moveMouse(x: 10, y: 20))
    #expect(try parser.parse("double click 30 40") == .doubleClick(x: 30, y: 40))
    #expect(try parser.parse("right click 50 60") == .rightClick(x: 50, y: 60))
    #expect(try parser.parse("drag 1 2 3 4") == .drag(fromX: 1, fromY: 2, toX: 3, toY: 4))
    #expect(try parser.parse("wait 2") == .wait(seconds: 2))
}

private final class RecordingComputerUseProvider: ComputerUseProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [String] = []

    func bootstrap() async throws {}

    func permissionStatus() async -> ComputerUsePermissionStatus {
        .init(accessibility: .granted, screenRecording: .granted)
    }

    func backendStatus() async throws -> ComputerUseBackendStatus {
        .init(state: .running, detail: "test")
    }

    func listWindows() async throws -> [ComputerUseWindow] {
        [.init(id: "w1", title: "Search", appName: "Google Chrome")]
    }

    func getWindowState(windowId: String) async throws -> ComputerUseWindowState {
        .init(windowID: windowId, title: "Search", appName: "Google Chrome", url: "https://example.com", elements: [])
    }

    func captureScreenshot(windowId: String) async throws -> ComputerUseScreenshot {
        .init(data: Data([0x89, 0x50]), contentType: "image/png", width: 2, height: 1)
    }

    func click(elementId: String, windowId: String) async throws {
        record("click-element:\(elementId):\(windowId)")
    }

    func typeText(_ text: String, windowId: String) async throws {
        record("type:\(text):\(windowId)")
    }

    func pressKey(_ key: String, modifiers: [String], windowId: String) async throws {
        record("press:\(modifiers.joined(separator: "+"))+\(key):\(windowId)")
    }

    func scroll(direction: ScrollDirection, amount: Int, windowId: String) async throws {
        record("scroll:\(direction.rawValue):\(amount):\(windowId)")
    }

    func focusApp(name: String?, windowId: String?) async throws {
        record("focus:\(name ?? ""):\(windowId ?? "")")
    }

    func moveMouse(x: Double, y: Double) async throws {
        record("move:\(x):\(y)")
    }

    func click(x: Double, y: Double, button: ComputerUseMouseButton, clickCount: Int) async throws {
        record("click:\(button.rawValue):\(x):\(y):\(clickCount)")
    }

    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double) async throws {
        record("drag:\(fromX):\(fromY):\(toX):\(toY)")
    }

    func openApp(named name: String) async throws {
        record("open-app:\(name)")
    }

    func openURL(_ url: String) async throws {
        record("open-url:\(url)")
    }

    func wait(seconds: Double) async throws {
        record("wait:\(seconds)")
    }

    func recordedActions() -> [String] {
        lock.withLock { actions }
    }

    private func record(_ value: String) {
        lock.withLock { actions.append(value) }
    }
}

private extension ToolContext {
    static func testComputerUseContext(approvalGranted: Bool = false) -> ToolContext {
        ToolContext(
            runID: UUID(),
            emit: { _ in },
            cancellation: CancellationToken(),
            approvalGranted: approvalGranted
        )
    }
}
