import AppKit
import Foundation
import RecordingFormat

/// Polls `NSCursor.currentSystem` at `cursorSamplingHz`. There is no system notification
/// for cursor changes, so polling is the only option; the cost is one object-identity
/// comparison per tick and a PNG encode only when a new bitmap appears.
///
/// Emits `cursorImageDefined` once per distinct bitmap (content-hashed) and
/// `cursorChanged` whenever the current cursor's id differs from the last emitted one.
final class CursorWatcher: @unchecked Sendable {
    private let clock: HostClock
    private let log: EventLog
    private let directory: RecordingDirectory
    private let hz: Int
    private var seen: Set<CursorImageID> = []
    private var lastID: CursorImageID?
    private var lastCursorObject: ObjectIdentifier?

    init(clock: HostClock, log: EventLog, directory: RecordingDirectory, hz: Int) {
        fatalError("not implemented")
    }

    func start() {
        fatalError("not implemented")
    }

    func stop() {
        fatalError("not implemented")
    }

    private func tick() {
        // TODO:
        // let cursor = NSCursor.currentSystem ?? NSCursor.current
        // if ObjectIdentifier(cursor) == lastCursorObject { return }   // fast path, most ticks
        // let (png, descriptor) = Self.describe(cursor)                 // hash -> id
        // if !seen.contains(id) { directory.storeCursorImage; log.append(.cursorImageDefined) }
        // if id != lastID { log.append(.cursorChanged(id)) }
        fatalError("not implemented")
    }

    /// Renders the cursor's image at its backing scale to PNG and reads hotspot/size in
    /// points. Pure given an `NSCursor`; testable with a synthetic cursor.
    static func describe(_ cursor: NSCursor) -> (png: Data, descriptor: CursorImageDescriptor) {
        fatalError("not implemented")
    }
}
