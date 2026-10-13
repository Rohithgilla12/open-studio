import AVFoundation
import CoreGraphics
public import Foundation

/// The privacy permissions a recording can need.
///
/// TCC attaches each grant to the responsible process: the app bundle when the SwiftUI app records,
/// and the terminal application when `osrec` runs from a shell.
public enum Permission: String, Sendable, CaseIterable, CustomStringConvertible {
    case screenRecording
    case inputMonitoring
    /// Required only when the configuration selects a microphone.
    case microphone

    public var description: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .inputMonitoring: "Input Monitoring"
        case .microphone: "Microphone"
        }
    }

    /// The matching Privacy & Security pane.
    public var settingsURL: URL {
        let pane = switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .microphone: "Privacy_Microphone"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

public enum PermissionStatus: Sendable, Equatable {
    case granted
    case denied
    /// Asking would show a system prompt. The CoreGraphics preflight calls cannot tell denied from
    /// never asked, so screen recording and input monitoring report this whenever not granted.
    case notDetermined
}

public struct PermissionReport: Sendable, Equatable {
    public let screenRecording: PermissionStatus
    public let inputMonitoring: PermissionStatus
    public let microphone: PermissionStatus

    public func status(of permission: Permission) -> PermissionStatus {
        switch permission {
        case .screenRecording: screenRecording
        case .inputMonitoring: inputMonitoring
        case .microphone: microphone
        }
    }

    /// The permissions `configuration` needs that are not granted. Empty means `start` will not
    /// fail on permissions.
    public func missing(for configuration: RecordingConfiguration) -> [Permission] {
        var needed: [Permission] = [.screenRecording, .inputMonitoring]
        if configuration.microphone != .none { needed.append(.microphone) }
        return needed.filter { status(of: $0) != .granted }
    }
}

public enum Permissions {
    /// Synchronous and side-effect free. Never shows a prompt.
    public static func check() -> PermissionReport {
        PermissionReport(
            screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .notDetermined,
            inputMonitoring: CGPreflightListenEventAccess() ? .granted : .notDetermined,
            microphone: microphoneStatus())
    }

    /// Shows the system prompt when one is possible, otherwise returns the current status.
    /// Screen recording and input monitoring grants take effect only after the responsible process
    /// relaunches, so callers should say so instead of retrying.
    public static func request(_ permission: Permission) async -> PermissionStatus {
        switch permission {
        case .screenRecording:
            return CGRequestScreenCaptureAccess() ? .granted : .denied
        case .inputMonitoring:
            return CGRequestListenEventAccess() ? .granted : .denied
        case .microphone:
            return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        }
    }

    /// Who TCC charges this process's grants to.
    public static var responsibleProcess: String {
        if let identifier = Bundle.main.bundleIdentifier {
            return Bundle.main.infoDictionary?["CFBundleName"] as? String ?? identifier
        }
        let terminal = ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "unknown"
        return "the terminal application that launched this process (TERM_PROGRAM=\(terminal))"
    }

    private static func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }
}
