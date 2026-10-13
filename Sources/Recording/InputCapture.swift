import AppKit
import CoreGraphics
import CryptoKit
import Foundation
internal import RecordingFormat
import Synchronization

/// Two producers, each with its own buffer: the event tap thread and the cursor watcher on the
/// main actor. Neither writes the other's state. `EventLogWriter` is the single consumer and
/// merges them by host time when it drains.
final class InputCapture: Sendable {
    let tapBuffer = InputBuffer<CapturedInput>()
    let cursorBuffer = InputBuffer<CapturedCursor>()
    private let tap: EventTapThread
    private let cursor: CursorWatcher

    init(displayScale: CGFloat, onTapReenabled: @escaping @Sendable (HostTime) -> Void) {
        let tapBuffer = tapBuffer
        let cursorBuffer = cursorBuffer
        tap = EventTapThread(sink: { tapBuffer.append($0) }, onReenabled: onTapReenabled)
        cursor = CursorWatcher(displayScale: displayScale) { cursorBuffer.append($0) }
    }

    func start() async throws(RecordingError) {
        try await tap.start()
        await cursor.start()
    }

    func stop() async {
        tap.stop()
        await cursor.stop()
    }

    /// Pointer position, held buttons, and the current cursor image at the moment of the call.
    func snapshot() async -> CapturedSnapshot {
        let location = CGEvent(source: nil)?.location ?? .zero
        var buttons: Set<WireButton> = []
        if CGEventSource.buttonState(.combinedSessionState, button: .left) { buttons.insert(.left) }
        if CGEventSource.buttonState(.combinedSessionState, button: .right) { buttons.insert(.right) }
        if CGEventSource.buttonState(.combinedSessionState, button: .center) { buttons.insert(.other) }
        return CapturedSnapshot(location: location, buttons: buttons, cursor: await cursor.current())
    }
}

/// A dedicated thread running a CFRunLoop with a session-level, listen-only CGEventTap.
///
/// The callback copies the fields it needs and returns at once: a slow callback gets the tap
/// disabled by the system.
final class EventTapThread: Sendable {
    private let context: TapContext

    init(sink: @escaping @Sendable (CapturedInput) -> Void, onReenabled: @escaping @Sendable (HostTime) -> Void) {
        context = TapContext(sink: sink, onReenabled: onReenabled)
    }

    func start() async throws(RecordingError) {
        let context = context
        let created: Bool = await withCheckedContinuation { continuation in
            let thread = Thread {
                guard let port = CGEvent.tapCreate(
                    tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                    eventsOfInterest: TapContext.mask, callback: tapCallback,
                    userInfo: Unmanaged.passUnretained(context).toOpaque())
                else {
                    continuation.resume(returning: false)
                    return
                }
                context.port = port
                context.runLoop = CFRunLoopGetCurrent()
                CFRunLoopAddSource(context.runLoop, CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
                CGEvent.tapEnable(tap: port, enable: true)
                continuation.resume(returning: true)
                CFRunLoopRun()
                CFMachPortInvalidate(port)
            }
            thread.name = "open-studio.event-tap"
            thread.qualityOfService = .userInteractive
            thread.start()
        }
        guard created else { throw .missingPermissions([.inputMonitoring]) }
    }

    func stop() {
        if let runLoop = context.runLoop { CFRunLoopStop(runLoop) }
    }
}

/// `port` and `runLoop` are written once on the tap thread before `start()`'s continuation
/// resumes, which orders them before any read: the callback reads `port` on the tap thread, and
/// `stop()` reads `runLoop` after `start()` returned. `CFRunLoopStop` is itself thread-safe.
/// That is why this is `@unchecked Sendable` rather than a Mutex, which cannot hand out the
/// non-Sendable CF values.
private final class TapContext: @unchecked Sendable {
    let sink: @Sendable (CapturedInput) -> Void
    let onReenabled: @Sendable (HostTime) -> Void
    var port: CFMachPort?
    var runLoop: CFRunLoop?

    init(sink: @escaping @Sendable (CapturedInput) -> Void, onReenabled: @escaping @Sendable (HostTime) -> Void) {
        self.sink = sink
        self.onReenabled = onReenabled
    }

    static let mask: CGEventMask = [
        CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .scrollWheel, .keyDown,
    ].reduce(0) { $0 | (1 << $1.rawValue) }

    func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            onReenabled(.now())
            return
        }
        guard let kind = CapturedInput.Kind(type, event) else { return }
        // Timestamps are nanoseconds on CLOCK_UPTIME_RAW (measured in Experiments/README.md).
        sink(CapturedInput(time: HostTime(nanoseconds: event.timestamp), location: event.location, kind: kind))
    }
}

private let tapCallback: CGEventTapCallBack = { _, type, event, info in
    Unmanaged<TapContext>.fromOpaque(info!).takeUnretainedValue().handle(type, event)
    return Unmanaged.passUnretained(event)
}

extension CapturedInput.Kind {
    init?(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            self = .move
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            self = .down(WireButton(type), clickCount: Int(event.getIntegerValueField(.mouseEventClickState)))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            self = .up(WireButton(type))
        case .scrollWheel:
            self = .scroll(
                dx: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
                dy: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        case .keyDown:
            self = .key(KeyStroke(
                modifiers: Set(WireModifier.allCases.filter { event.flags.contains($0.flag) }),
                pressedKeyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))))
        default:
            return nil
        }
    }
}

extension WireButton {
    fileprivate init(_ type: CGEventType) {
        switch type {
        case .leftMouseDown, .leftMouseUp: self = .left
        case .rightMouseDown, .rightMouseUp: self = .right
        default: self = .other
        }
    }
}

extension WireModifier {
    fileprivate var flag: CGEventFlags {
        switch self {
        case .shift: .maskShift
        case .control: .maskControl
        case .option: .maskAlternate
        case .command: .maskCommand
        case .function: .maskSecondaryFn
        case .capsLock: .maskAlphaShift
        }
    }
}

/// Polls `NSCursor.currentSystem` on the main actor at 60 Hz.
///
/// There is no public cursor-changed notification for other apps' cursors, so polling is the only
/// option. Object identity and a digest of the bitmap gate the PNG encode, so the steady state
/// costs one hash of a small bitmap per tick.
@MainActor
final class CursorWatcher {
    private let sink: @Sendable (CapturedCursor) -> Void
    private let displayScale: CGFloat
    private var task: Task<Void, Never>?
    private var lastCursor: NSCursor?
    private var lastDigest: SHA256Digest?
    private var lastImage: CursorImage?

    nonisolated init(displayScale: CGFloat, sink: @escaping @Sendable (CapturedCursor) -> Void) {
        self.displayScale = displayScale
        self.sink = sink
    }

    func start() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func current() -> CursorImage? {
        poll()
        return lastImage
    }

    private func poll() {
        let cursor = NSCursor.currentSystem ?? NSCursor.current
        guard cursor !== lastCursor else { return }
        lastCursor = cursor
        guard let rendered = render(cursor) else { return }
        guard rendered.digest != lastDigest else { return }
        lastDigest = rendered.digest
        lastImage = rendered.image
        sink(CapturedCursor(time: .now(), image: rendered.image))
    }

    private func render(_ cursor: NSCursor) -> (digest: SHA256Digest, image: CursorImage)? {
        let image = cursor.image
        var rect = CGRect(origin: .zero, size: image.size)
        let hints = [NSImageRep.HintKey.ctm: NSAffineTransform(transform: AffineTransform(scale: displayScale))]
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: hints),
            let bytes = cgImage.dataProvider?.data as Data?
        else { return nil }
        let digest = SHA256.hash(data: bytes)
        guard let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { return nil }
        let scale = image.size.width > 0 ? CGFloat(cgImage.width) / image.size.width : displayScale
        return (digest, CursorImage(
            png: png,
            hotspot: WirePoint(x: cursor.hotSpot.x * scale, y: cursor.hotSpot.y * scale),
            size: WireSize(width: Double(cgImage.width), height: Double(cgImage.height))))
    }
}
