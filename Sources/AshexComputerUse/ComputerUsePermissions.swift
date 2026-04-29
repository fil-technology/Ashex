import ApplicationServices
import CoreGraphics
import Foundation

public enum ComputerUsePermissionGrant: String, Codable, Sendable, Equatable {
    case granted
    case denied
    case unknown
}

public struct ComputerUsePermissionStatus: Codable, Sendable, Equatable {
    public let accessibility: ComputerUsePermissionGrant
    public let screenRecording: ComputerUsePermissionGrant

    public init(accessibility: ComputerUsePermissionGrant, screenRecording: ComputerUsePermissionGrant) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
    }

    public var isReadyForComputerUse: Bool {
        accessibility == .granted && screenRecording == .granted
    }

    public var guidance: String {
        var missing: [String] = []
        if accessibility != .granted {
            missing.append("Accessibility")
        }
        if screenRecording != .granted {
            missing.append("Screen Recording")
        }
        guard !missing.isEmpty else {
            return "Computer-use permissions are granted."
        }
        let processName = ProcessInfo.processInfo.processName
        return """
        Missing macOS permission(s): \(missing.joined(separator: ", ")).
        macOS does not let command-line tools grant these permissions programmatically.
        Open System Settings > Privacy & Security, grant Accessibility and Screen Recording to the app or terminal running ashex (currently: \(processName)), then fully quit and restart that app.
        Direct pane: x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility
        """
    }
}

public enum ComputerUsePermissionChecker {
    public static func current(
        promptForAccessibility: Bool = false,
        promptForScreenRecording: Bool = false
    ) -> ComputerUsePermissionStatus {
        let accessibility: ComputerUsePermissionGrant
        if promptForAccessibility {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            accessibility = AXIsProcessTrustedWithOptions(options) ? .granted : .denied
        } else {
            accessibility = AXIsProcessTrusted() ? .granted : .denied
        }

        let hasScreenRecording = promptForScreenRecording
            ? CGRequestScreenCaptureAccess()
            : CGPreflightScreenCaptureAccess()
        let screenRecording: ComputerUsePermissionGrant = hasScreenRecording ? .granted : .denied
        return .init(accessibility: accessibility, screenRecording: screenRecording)
    }
}
