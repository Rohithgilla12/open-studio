import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Owns the SCStream and both AVAssetWriters.
///
/// The actor's executor is the same serial queue ScreenCaptureKit delivers sample buffers on, so the
/// per-frame path enters actor isolation with `assumeIsolated` and never hops. At 60 to 120 frames
/// per second, an `await` per frame would add scheduling jitter for nothing.
actor CaptureSink {
    nonisolated let queue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let stream: SCStream
    private let screen: MovieWriter
    private let microphone: MovieWriter?
    private var origin: HostTime?
    private var lastScreenPTS: HostTime?
    private var firstFrameWaiters: [CheckedContinuation<HostTime, any Error>] = []
    private let onInput: @Sendable (SessionInput) -> Void

    init(
        display: SCDisplay, configuration: RecordingConfiguration, directory: URL,
        onInput: @escaping @Sendable (SessionInput) -> Void
    ) throws(RecordingError) {
        fatalError("not implemented")
    }

    func startCapture() async throws(RecordingError) {
        fatalError("not implemented")
    }

    /// Resolves with the PTS of the first complete frame. Does not start the writers' sessions;
    /// the session does that once, for both writers, with the same origin.
    func firstFrame(timeout: Duration) async throws(RecordingError) -> HostTime {
        fatalError("not implemented")
    }

    func beginWriting(origin: HostTime) {
        fatalError("not implemented")
    }

    /// Stops the stream, ends both writer sessions at the last screen PTS (so a static screen still
    /// produces a movie as long as the take), and finishes writing. Returns the screen duration.
    func finish() async throws -> Duration {
        fatalError("not implemented")
    }

    /// Called on `queue` by the SCStreamOutput adapter.
    private func receive(_ buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // TODO:
        // .screen:
        //   read SCStreamFrameInfo.status from the attachments; only .complete frames carry pixels.
        //   (.idle frames mean "nothing changed" and are skipped; the movie is variable frame rate.)
        //   if origin == nil: resolve firstFrameWaiters with PTS and buffer the frame until
        //     beginWriting(origin:) runs (at most a few frames).
        //   else append to screen writer if input.isReadyForMoreMediaData, otherwise count a drop and
        //     report .warning(.framesDropped) at most once per second.
        //   every ~250 ms of media time report .progress.
        // .microphone:
        //   drop buffers whose PTS < origin; append the rest to the microphone writer.
        // .audio: not requested (system audio is out of scope for this unit).
        fatalError("not implemented")
    }
}

/// One AVAssetWriter writing a fragmented QuickTime movie.
///
/// `movieFragmentInterval = 1 s`: AVFoundation documents that an interrupted fragmented movie can be
/// opened and played up to the last complete fragment, which is the whole crash-safety story for media.
///
/// Not Sendable on purpose: it lives inside CaptureSink and is only touched on its queue.
final class MovieWriter {
    enum Kind {
        /// Keyframe interval 2 x frame rate, quality 0.85, expectsMediaDataInRealTime.
        case screen(codec: VideoCodec, pixelSize: CGSize, frameRate: Int)
        /// AAC 48 kHz, matching the device channel count up to 2.
        case microphone(sampleRate: Double, channels: Int)
    }

    init(url: URL, kind: Kind) throws(RecordingError) {
        fatalError("not implemented")
    }
}

/// mach host time in nanoseconds. The one clock every source is converted to before media time is
/// derived. CMSampleBuffer PTS from ScreenCaptureKit is already on the host time clock.
struct HostTime: Sendable, Hashable, Comparable {
    var nanoseconds: UInt64

    static func < (lhs: HostTime, rhs: HostTime) -> Bool { lhs.nanoseconds < rhs.nanoseconds }

    init(nanoseconds: UInt64) { self.nanoseconds = nanoseconds }

    /// From a PTS on CMClockGetHostTimeClock().
    init(_ time: CMTime) { fatalError("not implemented") }

    /// From mach_absolute_time units, via mach_timebase_info. On Apple Silicon one tick is 125/3 ns,
    /// so treating ticks as nanoseconds would skew events by a factor of ~41.
    init(machTicks: UInt64) { fatalError("not implemented") }

    /// Media time in microseconds relative to `origin`. Negative for events before the first frame.
    func microseconds(since origin: HostTime) -> Int64 { fatalError("not implemented") }
}
