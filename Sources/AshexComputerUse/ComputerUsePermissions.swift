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
        return """
        Missing macOS permission(s): \(missing.joined(separator: ", ")).
        Open System Settings > Privacy & Security, grant Accessibility and Screen Recording to the app or terminal running ashex, then restart that app.
        """
    }
}

public enum ComputerUsePermissionChecker {
    public static func current(promptForAccessibility: Bool = false) -> ComputerUsePermissionStatus {
        let accessibility: ComputerUsePermissionGrant
        if promptForAccessibility {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            accessibility = AXIsProcessTrustedWithOptions(options) ? .granted : .denied
        } else {
            accessibility = AXIsProcessTrusted() ? .granted : .denied
        }

        let screenRecording: ComputerUsePermissionGrant = CGPreflightScreenCaptureAccess() ? .granted : .denied
        return .init(accessibility: accessibility, screenRecording: screenRecording)
    }
}
