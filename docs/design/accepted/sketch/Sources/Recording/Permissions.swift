import AVFoundation
import CoreGraphics
import Foundation

/// The privacy permissions a recording can need.
///
/// TCC attaches each grant to the responsible process: the app bundle when the SwiftUI app records,
/// and the terminal application (Terminal, iTerm, Ghostty...) when `osrec` runs from a shell.
/// Error messages say which one, so "I granted it" confusion is diagnosable.
public enum Permission: String, Sendable, CaseIterable, CustomStringConvertible {
    /// ScreenCaptureKit. Checked with `CGPreflightScreenCaptureAccess`.
    case screenRecording
    /// The listen-only CGEventTap. Input Monitoring (`CGPreflightListenEventAccess`), not
    /// Accessibility: a listen-only tap never posts or modifies events.
    case inputMonitoring
    /// Only required when the configuration selects a microphone.
    case microphone

    public var description: String { fatalError("not implemented") }

    /// `x-apple.systempreferences:` URL of the matching Privacy & Security pane.
    public var settingsURL: URL { fatalError("not implemented") }
}

public enum PermissionStatus: Sendable, Equatable {
    case granted
    case denied
    /// Asking would show a system prompt. The CoreGraphics preflight calls cannot tell denied from
    /// never-asked, so screen recording and input monitoring report this whenever they are not granted.
    case notDetermined
}

public struct PermissionReport: Sendable, Equatable {
    public let screenRecording: PermissionStatus
    public let inputMonitoring: PermissionStatus
    public let microphone: PermissionStatus

    /// The permissions `configuration` needs that are not granted. Empty means `start` will not fail
    /// on permissions. Derived from the configuration, so the "is the microphone needed?" rule lives
    /// in one place.
    public func missing(for configuration: RecordingConfiguration) -> [Permission] {
        fatalError("not implemented")
    }
}

public enum Permissions {
    /// Synchronous and side-effect free: never shows a prompt.
    public static func check() -> PermissionReport {
        fatalError("not implemented")
    }

    /// Shows the system prompt when one is possible, otherwise returns the current status.
    /// Screen recording and input monitoring grants usually take effect only after the responsible
    /// process relaunches; callers should say so instead of retrying in a loop.
    public static func request(_ permission: Permission) async -> PermissionStatus {
        fatalError("not implemented")
    }
}
