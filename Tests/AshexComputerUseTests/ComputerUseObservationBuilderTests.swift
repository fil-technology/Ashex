import AshexComputerUse
import AshexCore
import Foundation
import Testing

@Test func observationIncludesScreenshotAttachmentForModels() throws {
    let screenshot = ComputerUseScreenshot(
        data: Data([0x89, 0x50, 0x4E, 0x47]),
        contentType: "image/png",
        width: 1440,
        height: 900,
        capturedAt: Date(timeIntervalSince1970: 10)
    )
    let state = ComputerUseWindowState(
        windowID: "win-1",
        title: "Example",
        appName: "Safari",
        url: "https://example.com",
        elements: []
    )

    let observation = ComputerUseObservationBuilder().makeObservation(state, screenshot: screenshot)

    #expect(observation.text.contains("Window: Safari - Example"))
    #expect(observation.screenshots == [screenshot])

    let attachment = try #require(observation.imageAttachments().first)
    #expect(attachment.kind == .image)
    #expect(attachment.mimeType == "image/png")
    #expect(attachment.caption?.contains("Screenshot of Safari - Example") == true)
    #expect(try Data(contentsOf: attachment.fileURL) == screenshot.data)
    try? FileManager.default.removeItem(at: attachment.fileURL)
}

@Test func permissionStatusExplainsMissingMacOSGrants() {
    let denied = ComputerUsePermissionStatus(accessibility: .denied, screenRecording: .denied)

    #expect(!denied.isReadyForComputerUse)
    #expect(denied.guidance.contains("Accessibility"))
    #expect(denied.guidance.contains("Screen Recording"))
    #expect(denied.guidance.contains("System Settings"))
    #expect(denied.guidance.contains("does not let command-line tools grant"))
    #expect(denied.guidance.contains(ProcessInfo.processInfo.processName))
}
