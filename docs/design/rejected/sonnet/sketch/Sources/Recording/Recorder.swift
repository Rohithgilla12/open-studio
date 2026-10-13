import Foundation
import RecordingFormat

/// Entry point. A value type with no hidden state; every recording is its own session.
///
///     let session = try await Recorder().start(config)
///     for await state in session.states { ... }
///     let summary = try await session.stop()
public struct Recorder: Sendable {
    private let permissions: any PermissionProviding

    public init(permissions: any PermissionProviding = SystemPermissions()) {
        self.permissions = permissions
    }

    public func availableDisplays() async throws(RecordingError) -> [DisplayDescriptor] {
        fatalError("not implemented")
    }

    /// Preflights permissions, creates the directory, takes the lock, then starts capture.
    /// Returns once the stream has started. The first frame (and so the clock origin)
    /// arrives asynchronously; `states` moves .starting -> .recording when it does.
    public func start(_ config: RecordingConfig) async throws(RecordingError) -> RecordingSession {
        // TODO:
        //  1. report = await permissions.report(); throw .permissionsMissing(report.missing(for: config))
        //  2. resolve display via SCShareableContent; throw .displayNotFound
        //  3. RecordingDirectoryWriter.create(in:) -> layout + flock + initial manifest (status .recording)
        //  4. wire components to the session actor, run effects from transition(.idle, .begin)
        fatalError("not implemented")
    }
}

/// One live recording. The actor owns the Phase and runs Effects; capture components report
/// back by sending Inputs. No component touches another's state.
public actor RecordingSession {
    public nonisolated let directory: URL
    public nonisolated let states: AsyncStream<RecordingState>

    public var state: RecordingState { fatalError("not implemented") }

    /// Idempotent. Concurrent and repeated calls all await the same finalisation and get
    /// the same summary. Throws only if the take could not be finalised at all.
    public func stop() async throws(RecordingError) -> RecordingSummary {
        fatalError("not implemented")
    }

    init() { fatalError("not implemented") }
}
