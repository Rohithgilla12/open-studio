// Sources/Recording/CaptureSink.swift (changed), AudioTrack.swift (one method added).
//
// The sink now outlives a take. It always runs the stream; whether a buffer is written depends
// only on its timestamp and the take's clock, so the countdown and a pause are the same thing to
// every writer: time the clock does not admit.

import CoreMedia
import Foundation

actor CaptureSink {
    nonisolated let queue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var stage: Stage
    /// The newest complete screen frame the clock did not admit. One buffer, not a queue: holding
    /// more would take surfaces from ScreenCaptureKit's pool of `queueDepth` (6) and drop frames.
    private var held: HeldFrame?

    /// What the sink is doing with buffers. One enum instead of today's `origin`, `stopping`, and
    /// optional writers, so "writing before the origin" and "writing after finish" do not exist.
    enum Stage {
        /// Stream running, writers configured but not started, nothing on disk. Rolls at
        /// `notBefore`, or at the first complete frame after it when no frame was held.
        case armed(TakeWriters, notBefore: HostTime)
        case writing(TakeWriters, HostClock)
        /// Between a restart's discard and the next arm, or after cancel.
        case idle
    }

    /// Starts the stream and the camera consumer with no writers. Returns once the first complete
    /// screen frame is held, or throws `.noFramesDelivered` after the start timeout.
    func startCapture(filter: CaptureFilterPlan) async throws(RecordingError) {
        fatalError("not implemented")
    }

    /// Takes writers built off the sink's queue (their init is the slow part: 120 to 165 ms cold,
    /// 27 to 40 ms warm, measured in spike/writer-startup) and schedules the roll.
    func arm(_ writers: TakeWriters, notBefore: HostTime) {
        // stage = .armed(writers, notBefore)
        // schedule a DispatchSource on `queue` at notBefore -> rollIfDue(now:)
        fatalError("not implemented")
    }

    /// Idempotent: runs from the deadline timer and from `receiveScreen` when a frame at or after
    /// `notBefore` arrives first, and rolls once.
    ///
    /// origin = max(notBefore, held frame's pts) when a frame is held, else the arriving frame's
    /// pts. Creates the directory and starts every writer at the origin (2 to 17 ms, measured),
    /// appends the held frame restamped to the origin so `screen.mov` has a picture at 0 even
    /// when the screen is still, then reports `.rolled(origin:)`.
    private func rollIfDue(now: HostTime) {
        fatalError("not implemented")
    }

    /// The session's clock changed. On resume, appends the held frame restamped to `resumedAt`,
    /// so a screen that changed during the pause and then stayed still shows its new state, not
    /// the frame from before the pause.
    func apply(_ clock: HostClock, resumedAt: HostTime?) {
        fatalError("not implemented")
    }

    /// Finishes the current writers at `at` and returns what they produced; the stage becomes
    /// `.idle`. The stream keeps running for a restart.
    func finishTake(at: HostTime) async throws(RecordingError) -> CaptureSink.Finished {
        fatalError("not implemented")
    }

    /// Stops the stream. Writers that never started are dropped, which writes nothing: an
    /// `AVAssetWriter` that was configured but never started creates no file and no directory
    /// (measured in spike/writer-startup).
    func shutDown() async {
        fatalError("not implemented")
    }

    /// Per-buffer routing. The only place a buffer meets the clock.
    ///
    ///   screen     admitted: append, remember as `lastFrame`.
    ///              not admitted: keep as `held`, never write.
    ///   mic, sys   admitted: append (continuity fills small gaps, as today).
    ///              not admitted: drop.
    ///   camera     admitted: append. not admitted: drop. No fill: video holds its last frame,
    ///              and the editor removes the range.
    private func route(_ buffer: CMSampleBuffer, of source: Source) {
        fatalError("not implemented")
    }

    /// Once a second, as today, plus the pause's share:
    /// - writing, not paused: repeat `lastFrame` when the screen was still for a second (today).
    /// - paused: repeat `lastFrame`, which is from before the pause, so `screen.mov` stays
    ///   readable to the end if the process dies while paused; and write silence on each audio
    ///   track through `now - audioLag`, so a resume never has more than about two seconds of
    ///   silence to write at once.
    private func beat() {
        fatalError("not implemented")
    }

    /// Late audio for a time before the pause may still be in flight; silence written past it
    /// would push that audio later. ScreenCaptureKit delivers within a few milliseconds of the
    /// PTS (Experiments/README.md), so half a second is a wide margin.
    static let audioLag: Duration = .milliseconds(500)

    enum Source { case screen, microphone, systemAudio, camera }

    struct Finished: Sendable {
        var duration: Duration
        var microphone: TrackOutcome?
        var systemAudio: TrackOutcome?
        var camera: TrackOutcome?
        var warnings: [RecordingWarning] = []
    }
}

/// One take's writers, configured together and started together. Built from the rig's plan and
/// the layout the take will create.
struct TakeWriters {
    let layout: RecordingLayout
    let screen: MovieWriter
    let microphone: AudioTrackWriter?
    let systemAudio: AudioTrackWriter?
    let camera: CameraTrackWriter?

    /// In memory only. The layout's directory does not exist yet.
    static func configure(_ plan: TakePlan, sources: CaptureSourcesPlan, under parent: URL) throws(RecordingError) -> TakeWriters {
        fatalError("not implemented")
    }

    /// Creates the directory (trying `-2`, `-3` names on a clash, which rebuilds the writers for
    /// the new paths) and starts every writer's session at `origin`.
    mutating func start(at origin: HostTime) throws(RecordingError) {
        fatalError("not implemented")
    }
}

struct HeldFrame {
    let buffer: CMSampleBuffer
    let pts: HostTime

    func restamped(to t: HostTime) throws(RecordingError) -> CMSampleBuffer { fatalError("not implemented") }
}

extension AudioTrackWriter {
    /// Writes silence from `continuity.writtenThrough` to `t` in chunks of at most a second. The
    /// pause path calls it once a beat, so each call writes about one chunk.
    ///
    /// Why not fill the whole pause at resume, as `append` fills a delivery gap: an AAC input in
    /// real-time mode takes 12 one-second buffers back to back and then refuses; a 60 s, 600 s,
    /// or 1800 s gap filled at once kept 12 s and lost the rest, and the audio after it played
    /// that much early (measured in spike/audio-gap-fill). `fill` returns early on a refusal, so
    /// today a gap longer than about 12 s in system-audio delivery has the same fault.
    func fillSilence(through t: HostTime) throws(RecordingError) {
        fatalError("not implemented")
    }
}
