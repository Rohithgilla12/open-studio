import AppKit
import CoreGraphics
import Foundation
internal import RecordingFormat
import Synchronization

/// Two producers, each with its own buffer: the event tap thread and the cursor watcher on the main
/// actor. Neither ever writes the other's state. EventLogWriter is the single consumer and merges them
/// by host time when it drains. Per separate-before-serializing-shared-state, there is no shared
/// mutable log for the two producers to contend on.
final class InputCapture: Sendable {
    let tapBuffer = Mutex<[CapturedInput]>([])
    let cursorBuffer = Mutex<[CapturedCursor]>([])
    private let tapThread: EventTapThread
    private let cursorWatcher: CursorWatcher

    init(onWarning: @escaping @Sendable (RecordingWarning) -> Void) throws(RecordingError) {
        fatalError("not implemented")
    }

    func start() async throws(RecordingError) { fatalError("not implemented") }
    func stop() async { fatalError("not implemented") }

    /// Pointer position, held buttons, and current cursor image, read at the moment of the call.
    /// Used once, for the t = 0 state line.
    func snapshot() async -> CapturedSnapshot { fatalError("not implemented") }
}

/// A raw input event, before the clock and coordinate conversions.
struct CapturedInput: Sendable {
    var time: HostTime
    /// Global display points, origin top-left of the main display (CGEvent's space).
    var location: CGPoint
    var kind: Kind

    enum Kind: Sendable {
        case move
        case down(WireButton, clickCount: Int)
        case up(WireButton)
        case scroll(dx: Double, dy: Double)
        case key(modifiers: [WireModifier], keyCode: UInt16?)
    }
}

struct CapturedCursor: Sendable {
    var time: HostTime
    var image: CursorImage
}

struct CapturedSnapshot: Sendable {
    var location: CGPoint
    var buttons: [WireButton]
    var cursor: CursorImage?
}

/// PNG bytes plus geometry in screen video pixels. `id` is the first 16 hex digits of
/// SHA-256(png || hotspot), so writing the same cursor twice is a no-op.
struct CursorImage: Sendable, Hashable {
    var id: String
    var png: Data
    var hotspot: CGPoint
    var size: CGSize
}

/// A dedicated thread running a CFRunLoop with a session-level, listen-only CGEventTap.
///
/// Mask: mouseMoved, left/right/otherMouseDown/Up, left/right/otherMouseDragged, scrollWheel, keyDown,
/// flagsChanged. The callback copies the fields it needs into the sink (an append to `InputCapture.tapBuffer`) and returns immediately; a
/// slow callback gets the tap disabled by the system.
final class EventTapThread: Sendable {
    init(sink: @escaping @Sendable (CapturedInput) -> Void, onWarning: @escaping @Sendable (RecordingWarning) -> Void) {
        fatalError("not implemented")
    }

    func start() throws(RecordingError) {
        // TODO:
        // CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
        //                   options: .listenOnly, eventsOfInterest: mask, callback: c function, userInfo)
        // nil -> throw .missingPermissions([.inputMonitoring]) (the usual cause), else add the run loop
        // source to this thread's run loop and run it.
        // Callback:
        //   .tapDisabledByTimeout / .tapDisabledByUserInput -> CGEvent.tapEnable(tap, true),
        //     report .inputTapReenabled; return.
        //   time = HostTime(machTicks: event.timestamp)   // see risk: verify units on Apple Silicon
        //   keyDown: keyCode only if flags contain .maskCommand or .maskControl.
        //   dragged events are recorded as .move; held buttons are derivable from down/up.
        fatalError("not implemented")
    }

    func stop() { fatalError("not implemented") }
}

/// Polls `NSCursor.currentSystem` on the main actor at 60 Hz.
///
/// There is no public cursor-changed notification for other apps' cursors, so polling is the only
/// option. A cheap byte hash of the cursor bitmap gates the expensive work (PNG encode, SHA-256);
/// both run only when the cursor actually changes.
@MainActor
final class CursorWatcher {
    init(sink: @escaping @Sendable (CapturedCursor) -> Void, displayScale: CGFloat) { fatalError("not implemented") }
    func start() { fatalError("not implemented") }
    func stop() { fatalError("not implemented") }
}

/// The single writer of `events.ndjson` and `cursors/`.
///
/// Every 100 ms: drain both producer buffers, merge by host time, convert each event to media time
/// and screen pixels, write any new cursor PNGs (temp file + rename) before the lines that reference
/// them, then append all lines with one write(2). A process crash loses at most the last 100 ms;
/// already-written bytes are in the kernel and survive. No fsync per batch: power loss is not in
/// scope, and fsync at 10 Hz would contend with the movie writers.
actor EventLogWriter {
    init(directory: URL, input: InputCapture, mapping: DisplayMapping) throws(RecordingError) {
        fatalError("not implemented")
    }

    /// Writes the t = 0 `state` line from `snapshot`, then starts the drain loop. Buffered events
    /// stamped before `origin` are dropped: the snapshot already describes the state at 0.
    func begin(origin: HostTime, snapshot: CapturedSnapshot) throws {
        fatalError("not implemented")
    }

    /// Final drain, then close the file. Idempotent.
    func finish() async throws -> Int {
        fatalError("not implemented")
    }
}

/// Global display points to screen video pixels for the captured display. Pure, so the one
/// coordinate conversion in the system is unit-testable.
struct DisplayMapping: Sendable, Equatable {
    var displayPointFrame: CGRect
    var pixelSize: CGSize

    func pixels(fromGlobalPoint point: CGPoint) -> WirePoint { fatalError("not implemented") }
    func pixels(fromPoints size: CGSize) -> WireSize { fatalError("not implemented") }
}

/// flock(2) on `.lock`. Held for the whole recording; the kernel drops it when the process dies.
final class DirectoryLock: Sendable {
    /// Non-blocking. Returns nil when another live process holds the lock.
    static func acquire(in directory: URL) throws -> DirectoryLock? { fatalError("not implemented") }
    func release() { fatalError("not implemented") }
}
