import Foundation

public enum Permission: String, Codable, Sendable, CaseIterable {
    case screenRecording
    /// Input Monitoring (kTCCServiceListenEvent). A listen-only tap needs this, not Accessibility.
    case inputMonitoring
    case microphone
}

public enum PermissionStatus: Sendable, Equatable { case granted, denied, notDetermined }

public struct PermissionReport: Sendable, Equatable {
    public var statuses: [Permission: PermissionStatus]
    public func missing(for config: RecordingConfig) -> [Permission] { fatalError("not implemented") }
}

/// Seam for tests and for a future XPC helper. The system implementation wraps
/// CGPreflightScreenCaptureAccess, CGPreflightListenEventAccess and AVCaptureDevice.
public protocol PermissionProviding: Sendable {
    func report() async -> PermissionReport
    /// Triggers the system prompt where one exists. Does not wait for the user's decision.
    func request(_ permission: Permission) async
}

public struct SystemPermissions: PermissionProviding {
    public init() {}
    public func report() async -> PermissionReport { fatalError("not implemented") }
    public func request(_ permission: Permission) async { fatalError("not implemented") }
}
