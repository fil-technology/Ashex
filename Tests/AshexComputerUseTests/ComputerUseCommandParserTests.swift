import AshexComputerUse
import Testing

@Test func parsesDeterministicPrototypeCommands() throws {
    let parser = ComputerUseCommandParser()

    #expect(try parser.parse("click 12") == .click(elementId: "12"))
    #expect(try parser.parse("type hello") == .typeText("hello"))
    #expect(try parser.parse("press enter") == .pressKey(key: "Enter", modifiers: []))
    #expect(try parser.parse("press cmd l") == .pressKey(key: "L", modifiers: ["cmd"]))
    #expect(try parser.parse("press cmd shift p") == .pressKey(key: "P", modifiers: ["cmd", "shift"]))
    #expect(try parser.parse("scroll down") == .scroll(direction: .down, amount: 1))
    #expect(try parser.parse("screenshot") == .captureScreenshot)
    #expect(try parser.parse("state") == .refreshState)
    #expect(try parser.parse("quit") == .quit)
}

@Test func parserRejectsUnsupportedCommandsClearly() {
    let parser = ComputerUseCommandParser()

    #expect(throws: ComputerUseCommandError.self) {
        _ = try parser.parse("drag 12")
    }
}
