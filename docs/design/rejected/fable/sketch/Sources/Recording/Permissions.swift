import CoreGraphics
import Foundation

public enum Permission: String, Sendable, CaseIterable, Hashable {
    /// ScreenCaptureKit display capture.
    case screenRecording
    /// A listen-only session event tap that includes keyboard events. Input Monitoring is
    /// sufficient; Accessibility is only needed for taps that modify events, which we never
    /// create.
    case inputMonitoring

    /// Deep link into System Settings for the user-facing error.
    public var settingsURL: URL {
        fatalError("not implemented")
    }
}

public struct PermissionReport: Sendable, Equatable {
    public var screenRecording: Bool
    public var inputMonitoring: Bool

    public var missing: [Permission] {
        fatalError("not implemented")
    }

    public var allowsRecording: Bool { missing.isEmpty }
}

/// TCC attaches both permissions to the responsible app bundle. In-process capture means
/// that is simply "the app" (or Terminal, when `osrec` runs from a shell), which is why
/// no helper process is involved.
public enum Permissions {
    /// Non-prompting. `CGPreflightScreenCaptureAccess` and `CGPreflightListenEventAccess`.
    public static func check() -> PermissionReport {
        fatalError("not implemented")
    }

    /// Prompts once via `CGRequestScreenCaptureAccess` / `CGRequestListenEventAccess` and
    /// returns the state afterwards. Screen Recording grants take effect only after the
    /// process relaunches, so the caller must re-check rather than trust `true`.
    @discardableResult
    public static func request(_ permission: Permission) -> Bool {
        fatalError("not implemented")
    }
}
