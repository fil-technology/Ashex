import AshexCore
import Foundation

public struct ComputerUseTool: Tool {
    public let name = "computer_use"
    public let description = "Control the visible macOS GUI: inspect windows, move the cursor, click, type, press keys, scroll, open apps or URLs, and capture screenshots."
    public let provider: any ComputerUseProvider
    public let safetyPolicy: ComputerUseSafetyPolicy

    public init(provider: any ComputerUseProvider, safetyPolicy: ComputerUseSafetyPolicy) {
        self.provider = provider
        self.safetyPolicy = safetyPolicy
    }

    public var contract: ToolContract {
        ToolContract(
            name: name,
            description: description,
            category: "computer_use",
            operations: [
                operation("list_windows", "List visible windows and apps.", mutates: false),
                operation("focus_app", "Focus a running app or window.", approval: .low, args: [
                    arg("app_name", "App name to focus.", required: false),
                    arg("window_id", "Window id from list_windows.", required: false),
                ]),
                operation("move_mouse", "Move the visible mouse cursor to screen coordinates.", mutates: false, args: coordinateArgs()),
                operation("click", "Click an element id or screen coordinate.", approval: .medium, args: coordinateArgs(required: false) + [
                    arg("element_id", "Accessibility element id from state.", required: false),
                    arg("window_id", "Window id for element clicks.", required: false),
                ]),
                operation("double_click", "Double click screen coordinates.", approval: .medium, args: coordinateArgs()),
                operation("right_click", "Right click screen coordinates.", approval: .medium, args: coordinateArgs()),
                operation("drag", "Drag from one screen coordinate to another.", approval: .medium, args: [
                    arg("from_x", "Start x coordinate.", type: .number),
                    arg("from_y", "Start y coordinate.", type: .number),
                    arg("to_x", "End x coordinate.", type: .number),
                    arg("to_y", "End y coordinate.", type: .number),
                ]),
                operation("type_text", "Type text into the focused app or selected window.", approval: .medium, args: [
                    arg("text", "Text to type."),
                    arg("window_id", "Optional target window id.", required: false),
                ]),
                operation("press_keys", "Press a key or shortcut like cmd+l.", approval: .medium, args: [
                    arg("key", "Main key, for example enter, l, escape."),
                    arg("modifiers", "Optional modifiers: cmd, shift, ctrl, alt.", type: .array, required: false),
                    arg("window_id", "Optional target window id.", required: false),
                ]),
                operation("scroll", "Scroll the focused app or selected window.", mutates: false, args: [
                    arg("direction", "Scroll direction.", enumValues: ["up", "down"]),
                    arg("amount", "Scroll amount.", type: .number, required: false),
                    arg("window_id", "Optional target window id.", required: false),
                ]),
                operation("open_app", "Open a macOS app by name.", approval: .low, args: [arg("app_name", "App name.")]),
                operation("open_url", "Open a URL in the default browser.", requiresNetwork: true, approval: .low, args: [arg("url", "URL to open.")]),
                operation("screenshot", "Capture current screen or target window screenshot.", mutates: false, args: [arg("window_id", "Optional target window id.", required: false)]),
                operation("state", "Read accessibility state for a window.", mutates: false, args: [arg("window_id", "Window id.")]),
                operation("wait", "Wait for UI to settle.", mutates: false, args: [arg("seconds", "Seconds to wait.", type: .number)]),
            ],
            tags: ["computer", "gui", "macos", "cursor"]
        )
    }

    public func execute(arguments: JSONObject, context: ToolContext) async throws -> ToolContent {
        let operation = try requiredString("operation", in: arguments)
        let permissions = await provider.permissionStatus()
        guard permissions.isReadyForComputerUse else {
            throw AshexError.model(permissions.guidance)
        }

        switch operation {
        case "list_windows":
            let windows = try await provider.listWindows()
            return .structured(.object(["windows": .array(windows.map(windowJSON))]))
        case "state":
            let windowID = try requiredString("window_id", in: arguments)
            let state = try await provider.getWindowState(windowId: windowID)
            return .structured(stateJSON(state))
        case "focus_app":
            try await confirmIfNeeded(.openApp(arguments["app_name"]?.stringValue ?? arguments["window_id"]?.stringValue ?? "app"), arguments: arguments, context: context)
            try await provider.focusApp(name: arguments["app_name"]?.stringValue, windowId: arguments["window_id"]?.stringValue)
            return .text("Focused app/window.")
        case "move_mouse":
            try await provider.moveMouse(x: try requiredDouble("x", in: arguments), y: try requiredDouble("y", in: arguments))
            return .text("Moved mouse.")
        case "click":
            let action = try clickAction(arguments: arguments)
            try await confirmIfNeeded(action, arguments: arguments, context: context)
            try await ComputerUseActionExecutor(provider: provider).execute(action, windowId: arguments["window_id"]?.stringValue ?? "")
            return .text("Clicked.")
        case "double_click":
            let action = ComputerUseAction.doubleClick(x: try requiredDouble("x", in: arguments), y: try requiredDouble("y", in: arguments))
            try await confirmIfNeeded(action, arguments: arguments, context: context)
            try await ComputerUseActionExecutor(provider: provider).execute(action, windowId: "")
            return .text("Double clicked.")
        case "right_click":
            let action = ComputerUseAction.rightClick(x: try requiredDouble("x", in: arguments), y: try requiredDouble("y", in: arguments))
            try await confirmIfNeeded(action, arguments: arguments, context: context)
            try await ComputerUseActionExecutor(provider: provider).execute(action, windowId: "")
            return .text("Right clicked.")
        case "drag":
            let action = ComputerUseAction.drag(
                fromX: try requiredDouble("from_x", in: arguments),
                fromY: try requiredDouble("from_y", in: arguments),
                toX: try requiredDouble("to_x", in: arguments),
                toY: try requiredDouble("to_y", in: arguments)
            )
            try await confirmIfNeeded(action, arguments: arguments, context: context)
            try await ComputerUseActionExecutor(provider: provider).execute(action, windowId: "")
            return .text("Dragged.")
        case "type_text":
            let action = ComputerUseAction.typeText(try requiredString("text", in: arguments))
            try await confirmIfNeeded(action, arguments: arguments, context: context)
            try await ComputerUseActionExecutor(provider: provider).execute(action, windowId: arguments["window_id"]?.stringValue ?? "")
            return .text("Typed text.")
        case "press_keys":
            let parsed = parseKeyArguments(arguments)
            let action = ComputerUseAction.pressKey(key: parsed.key, modifiers: parsed.modifiers)
            try await confirmIfNeeded(action, arguments: arguments, context: context)
            try await ComputerUseActionExecutor(provider: provider).execute(action, windowId: arguments["window_id"]?.stringValue ?? "")
            return .text("Pressed keys.")
        case "scroll":
            guard let direction = arguments["direction"]?.stringValue.flatMap(ScrollDirection.init(rawValue:)) else {
                throw AshexError.invalidToolArguments("computer_use.direction must be up or down")
            }
            try await provider.scroll(direction: direction, amount: Int(arguments["amount"]?.numberValue ?? 1), windowId: arguments["window_id"]?.stringValue ?? "")
            return .text("Scrolled.")
        case "open_app":
            let appName = try requiredString("app_name", in: arguments)
            let action = ComputerUseAction.openApp(appName)
            try await confirmIfNeeded(action, arguments: arguments, context: context)
            try await provider.openApp(named: appName)
            return .text("Opened \(appName).")
        case "open_url":
            let url = try requiredString("url", in: arguments)
            let action = ComputerUseAction.openURL(url)
            try await confirmIfNeeded(action, arguments: arguments, context: context)
            try await provider.openURL(url)
            return .text("Opened \(url).")
        case "screenshot":
            let screenshot = try await provider.captureScreenshot(windowId: arguments["window_id"]?.stringValue ?? "")
            return .structured(.object([
                "content_type": .string(screenshot.contentType),
                "width": .number(Double(screenshot.width)),
                "height": .number(Double(screenshot.height)),
                "bytes": .number(Double(screenshot.data.count)),
            ]))
        case "wait":
            let seconds = try requiredDouble("seconds", in: arguments)
            try await provider.wait(seconds: seconds)
            return .text("Waited \(seconds) seconds.")
        default:
            throw AshexError.invalidToolArguments("Unsupported computer_use operation `\(operation)`.")
        }
    }

    private func confirmIfNeeded(_ action: ComputerUseAction, arguments: JSONObject, context: ToolContext) async throws {
        let state = ComputerUseWindowState(
            windowID: arguments["window_id"]?.stringValue ?? "",
            title: arguments["title"]?.stringValue ?? "",
            appName: arguments["app_name"]?.stringValue ?? "",
            url: arguments["url"]?.stringValue,
            elements: []
        )
        let decision = safetyPolicy.evaluate(action, state: state)
        guard decision.isAllowed else {
            throw AshexError.model(decision.reason ?? "Computer-use action blocked by safety policy.")
        }
        if decision.requiresConfirmation && !context.approvalGranted {
            throw AshexError.approvalDenied(decision.reason ?? "Computer-use action requires approval.")
        }
    }

    private func clickAction(arguments: JSONObject) throws -> ComputerUseAction {
        if let elementID = arguments["element_id"]?.stringValue, !elementID.isEmpty {
            return .click(elementId: elementID)
        }
        return .clickAt(
            x: try requiredDouble("x", in: arguments),
            y: try requiredDouble("y", in: arguments),
            button: .left,
            clickCount: 1
        )
    }

    private func parseKeyArguments(_ arguments: JSONObject) -> (key: String, modifiers: [String]) {
        let key = arguments["key"]?.stringValue ?? "enter"
        let modifiers = arguments["modifiers"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return (key, modifiers)
    }

    private func requiredString(_ key: String, in arguments: JSONObject) throws -> String {
        guard let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw AshexError.invalidToolArguments("computer_use.\(key) must be a non-empty string")
        }
        return value
    }

    private func requiredDouble(_ key: String, in arguments: JSONObject) throws -> Double {
        if let value = arguments[key]?.numberValue {
            return value
        }
        throw AshexError.invalidToolArguments("computer_use.\(key) must be a number")
    }

    private func windowJSON(_ window: ComputerUseWindow) -> JSONValue {
        .object([
            "id": .string(window.id),
            "title": .string(window.title),
            "app_name": .string(window.appName),
        ])
    }

    private func stateJSON(_ state: ComputerUseWindowState) -> JSONValue {
        .object([
            "window_id": .string(state.windowID),
            "title": .string(state.title),
            "app_name": .string(state.appName),
            "url": state.url.map(JSONValue.string) ?? .null,
            "elements": .array(state.elements.map { element in
                .object([
                    "id": .string(element.id),
                    "role": .string(element.role),
                    "title": element.title.map(JSONValue.string) ?? .null,
                    "value": element.value.map(JSONValue.string) ?? .null,
                    "enabled": .bool(element.isEnabled),
                ])
            }),
        ])
    }

    private func operation(
        _ name: String,
        _ description: String,
        mutates: Bool = true,
        requiresNetwork: Bool = false,
        approval: ApprovalRisk? = nil,
        args: [ToolArgumentContract] = []
    ) -> ToolOperationContract {
        ToolOperationContract(
            name: name,
            description: description,
            mutatesWorkspace: mutates,
            requiresNetwork: requiresNetwork,
            progressSummary: "\(name) via computer use",
            approval: approval.map {
                ToolApprovalContract(
                    risk: $0,
                    summary: "Computer Use \(name)",
                    reasonTemplate: "Run computer_use.\(name) with {{app_name}}{{url}}{{x}}{{y}}{{text}}"
                )
            },
            arguments: args
        )
    }

    private func arg(
        _ name: String,
        _ description: String,
        type: ToolArgumentType = .string,
        required: Bool = true,
        enumValues: [String] = []
    ) -> ToolArgumentContract {
        ToolArgumentContract(name: name, description: description, type: type, required: required, enumValues: enumValues)
    }

    private func coordinateArgs(required: Bool = true) -> [ToolArgumentContract] {
        [
            arg("x", "Screen x coordinate.", type: .number, required: required),
            arg("y", "Screen y coordinate.", type: .number, required: required),
        ]
    }
}
