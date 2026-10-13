import Foundation
import RecordingFormat

/// Internal components. Each owns one external resource, one queue and one output file.
/// They share no mutable state. They talk to the session only by sending `Input`s, and the
/// only cross-component fact, the clock origin, flows through the session.

/// SCStream (showsCursor = false, captureMicrophone when requested) feeding two writers.
/// Video and microphone samples arrive on one stream and so on one clock.
final class ScreenCapture: @unchecked Sendable {
    // Confined to `queue`. CMSampleBuffer is not Sendable, so buffers never leave it.
    func start(display: DisplayDescriptor, config: RecordingConfig, layout: RecordingLayout,
               report: @escaping @Sendable (Input) -> Void) async throws(RecordingError) {
        // TODO:
        //  SCStreamConfiguration: showsCursor = false, minimumFrameInterval = 1/fps,
        //  pixelFormat = 420v/BGRA per codec, queueDepth = 6, captureMicrophone = (mic != .off)
        //  On first .complete video frame: origin = HostTime(pts); startSession(atSourceTime: pts)
        //  on BOTH writers (mic starts at video origin so t=0 is shared); report(.firstFrame(origin)).
        //  Ignore frames whose SCFrameStatus != .complete.
        //  Video PTS written as-is, so file time == host time - origin.
        fatalError("not implemented")
    }

    /// endSession(atSourceTime: stopHost) holds the last frame to the stop instant,
    /// which makes duration == stopHost - origin independent of the last screen change.
    func stop(at stopHost: HostTime) async throws(RecordingError) { fatalError("not implemented") }
}

/// AVAssetWriter wrapper. movieFragmentInterval makes the file playable up to the last
/// completed fragment even if the process is killed.
final class FragmentedMP4Writer: @unchecked Sendable {
    init(url: URL, video: RecordingConfig.VideoEncoding, fragmentInterval: Duration) { fatalError("not implemented") }
}

/// Session-level, listen-only CGEventTap on a dedicated thread's run loop.
/// Mask: mouseMoved, left/right/other down+up and dragged, scrollWheel, keyDown.
/// The callback records timestamp + position + modifiers only. Key codes are never read.
final class InputTap: @unchecked Sendable {
    func start(display: RecordingManifest.Display, log: AppendLog,
               report: @escaping @Sendable (Input) -> Void) throws(RecordingError) {
        // TODO:
        //  event.timestamp is in mach ticks or ns depending on architecture; convert through
        //  HostClock.nanoseconds(fromEventTimestamp:) and verify with `osrec verify-clock`.
        //  tapDisabledByTimeout / tapDisabledByUserInput: re-enable once, else report(.degraded(.inputTapLost)).
        //  position = event.location - displayOrigin (CG global space is already top-left).
        fatalError("not implemented")
    }
}

/// Polls NSCursor.currentSystem (and on every mouse event), hashes the image data, and on
/// first sight of an image writes cursors/<id>.png, then its catalog line, then the change line.
/// That order means a change line never references an image that is not on disk.
final class CursorWatcher: @unchecked Sendable {
    func start(layout: RecordingLayout, changes: AppendLog, catalog: AppendLog) { fatalError("not implemented") }
}

/// Append-only NDJSON file. Buffers lines, flushes every eventFlushInterval with one
/// write(2), fsync on stop. A single writer per file; two actors never share one.
final class AppendLog: @unchecked Sendable {
    init(url: URL, flushInterval: Duration) throws(RecordingError) { fatalError("not implemented") }
    func append(_ line: Data) { fatalError("not implemented") }
    func close() throws(RecordingError) { fatalError("not implemented") }
}

enum HostClock {
    static func now() -> HostTime { fatalError("not implemented") }
    static func nanoseconds(fromEventTimestamp ticks: UInt64) -> HostTime { fatalError("not implemented") }
}
