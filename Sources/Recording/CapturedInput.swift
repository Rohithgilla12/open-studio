import CoreGraphics
import Foundation
internal import RecordingFormat
import Synchronization

/// A raw input event, before the clock and coordinate conversions.
struct CapturedInput: Sendable, Equatable {
    var time: HostTime
    /// Global display points, origin top-left of the main display (CGEvent's space).
    var location: CGPoint
    var kind: Kind

    enum Kind: Sendable, Equatable {
        case move
        case down(WireButton, clickCount: Int)
        case up(WireButton)
        case scroll(dx: Double, dy: Double)
        case key(KeyStroke)
    }
}

struct CapturedCursor: Sendable, Equatable {
    var time: HostTime
    var image: CursorImage
}

struct CapturedSnapshot: Sendable, Equatable {
    var location: CGPoint
    var buttons: Set<WireButton>
    var cursor: CursorImage?
}

/// PNG bytes plus geometry in screen video pixels.
struct CursorImage: Sendable, Hashable {
    var png: Data
    var hotspot: WirePoint
    var size: WireSize
}

/// Host time and global points to media time and screen pixels. Pure, so the conversion every
/// event goes through is unit-testable.
struct EventConversion: Sendable, Equatable {
    var origin: HostTime
    var mapping: DisplayMapping

    /// Nil for an event stamped before the origin. The t = 0 state snapshot already describes the
    /// state at the first frame, so earlier events add nothing a reader could place.
    func event(_ input: CapturedInput) -> WireEvent? {
        guard let t = input.time.mediaTime(since: origin) else { return nil }
        let position = mapping.pixels(fromGlobalPoint: input.location)
        switch input.kind {
        case .move:
            return .move(t: t, position: position)
        case .down(let button, let clickCount):
            return .down(t: t, button: button, position: position, clickCount: clickCount)
        case .up(let button):
            return .up(t: t, button: button, position: position)
        case .scroll(let dx, let dy):
            return .scroll(t: t, position: position, dx: dx, dy: dy)
        case .key(let stroke):
            return .key(t: t, stroke: stroke)
        }
    }

    func state(_ snapshot: CapturedSnapshot, cursor: CursorImageID?) -> WireEvent {
        .state(t: .zero, position: mapping.pixels(fromGlobalPoint: snapshot.location), buttons: snapshot.buttons, cursor: cursor)
    }
}

/// A producer's own append-only buffer. The producer appends; the single consumer takes everything
/// at once, so the two never contend on anything but the lock.
final class InputBuffer<Element: Sendable>: Sendable {
    private let elements = Mutex<[Element]>([])

    func append(_ element: Element) { elements.withLock { $0.append(element) } }

    func take() -> [Element] {
        elements.withLock { buffer in
            defer { buffer.removeAll(keepingCapacity: true) }
            return buffer
        }
    }

    var isEmpty: Bool { elements.withLock(\.isEmpty) }
}
