import AshexCore
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ComputerUseScreenshotCapture {
    public static func captureMainDisplay() throws -> ComputerUseScreenshot {
        guard CGPreflightScreenCaptureAccess() else {
            throw AshexError.model(ComputerUsePermissionStatus(
                accessibility: AXIsProcessTrusted() ? .granted : .denied,
                screenRecording: .denied
            ).guidance)
        }
        let displayID = CGMainDisplayID()
        guard let image = CGDisplayCreateImage(displayID) else {
            throw AshexError.model("Unable to capture the main display screenshot.")
        }
        let data = try pngData(from: image)
        return ComputerUseScreenshot(
            data: data,
            contentType: "image/png",
            width: image.width,
            height: image.height
        )
    }

    private static func pngData(from image: CGImage) throws -> Data {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw AshexError.model("Unable to prepare PNG screenshot encoder.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AshexError.model("Unable to encode PNG screenshot.")
        }
        return mutableData as Data
    }
}
