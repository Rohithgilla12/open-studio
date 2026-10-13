import CoreGraphics
import Foundation
import RecordingFormat

/// Listen-only `CGEventTap` on a dedicated thread with its own run loop. Each event is
/// stamped with `CGEvent.timestamp` (not "now"), so queueing delay in the tap does not
/// skew alignment with video.
///
/// Mask: mouseMoved, left/right/otherMouseDown/Up, left/right/otherMouseDragged,
/// scrollWheel, keyDown, keyUp, flagsChanged. Dragged events are recorded as `mouseMoved`
/// because the renderer only needs the path; button state comes from down/up.
final class InputTap: @unchecked Sendable {
    private let clock: HostClock
    private let log: EventLog
    private let recordsKeyCodes: Bool
    private var thread: Thread?

    init(clock: HostClock, log: EventLog, recordsKeyCodes: Bool) {
        fatalError("not implemented")
    }

    /// Fails with `.permissionsMissing([.inputMonitoring])` if `CGEvent.tapCreate` returns
    /// nil, which is how macOS reports a denied listen tap.
    func start() throws {
        fatalError("not implemented")
    }

    func stop() {
        fatalError("not implemented")
    }

    /// Pure translation from CGEvent to wire record, kept separate so it is unit-testable
    /// with synthetic events.
    static func record(for event: CGEvent, type: CGEventType, recordsKeyCodes: Bool) -> EventBody? {
        // TODO: map type -> case; location -> x,y; flags -> Modifiers; keyCode only if opted in.
        // Return nil for tapDisabledByTimeout / tapDisabledByUserInput, after re-enabling the tap.
        fatalError("not implemented")
    }
}
