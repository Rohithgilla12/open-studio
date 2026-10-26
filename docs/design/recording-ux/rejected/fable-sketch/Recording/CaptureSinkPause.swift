// Sketch. Module Recording. The sink across prepare, begin, pause, resume, stop, and discard.
//
//   SCStream ─┐                        CaptureSink actor (executor = the SCK queue)
//   camera ───┼─▶ receive(buffer) ──▶  Take? ── nil: warm, keep lastFrame only
//   microphone┘                          │ some: pauses.contains(pts) ? drop : writer.append
//                                        │
//   heartbeat (1 s) ──▶ beat() ─────────▶ screen: repeat lastFrame at now    (as today, also while paused)
//                                         audio:  fill silence to now        (new, only while paused)
//
// `Take` holds everything that exists only between begin and stop: the writers, the origin, and
// the pause ledger. The sink without a take is a warm stream. That is the whole prepare/begin
// split inside the sink: `arm` makes a take, `finish`/`abandon` take it away.

import CoreMedia
import Foundation
internal import RecordingFormat

/// Host-time ranges during which captured content is dropped. The one gate for every source: the
/// sink asks it before appending a screen, audio, or camera buffer, and the event log asks it for
/// every input and cursor change it drains. Pure, so the drop rule is tested without capture.
///
/// Invariants: closed pauses are sorted and disjoint; at most one open pause, after every closed
/// one. Microsecond media times for the manifest derive from here through the origin.
struct PauseLedger: Sendable, Equatable {
    private(set) var closed: [Range<HostTime>]
    private(set) var openSince: HostTime?

    static let none = PauseLedger(closed: [], openSince: nil)

    var isPaused: Bool { openSince != nil }

    /// Ignored while already paused, and `at` is clamped to after the last closed pause so a
    /// pause can never be reordered by a late input.
    mutating func pause(at: HostTime) { fatalError("not implemented") }

    /// Ignored while not paused. A resume before the pause began (clock skew between the UI's
    /// instant and the sink's) closes a zero-length pause, which the manifest then omits.
    mutating func resume(at: HostTime) { fatalError("not implemented") }

    /// Whether content stamped at `time` falls in a pause, open or closed.
    func contains(_ time: HostTime) -> Bool { fatalError("not implemented") }

    /// For the manifest and the clock. The open pause is reported with `end == nil`.
    func wire(since origin: HostTime) -> [WirePause] { fatalError("not implemented") }

    /// Total paused time at `now`, including the open pause. The elapsed clock subtracts this.
    func pausedDuration(at now: HostTime) -> Duration { fatalError("not implemented") }
}

extension CaptureSink {
    /// Per-take state. `pauses` is the single source of paused-ness inside the sink.
    struct Take {
        var origin: HostTime
        var screen: MovieWriter
        var microphone: AudioTrackWriter?
        var systemAudio: AudioTrackWriter?
        var camera: CameraTrackWriter?
        var pauses: PauseLedger
        var lastProgress: HostTime
    }

    /// Starts the stream and the camera attachment and waits for the first complete frame, which
    /// is kept as `lastFrame` but written nowhere. Replaces today's `startCapture` + `firstFrame`.
    func warmUp(timeout: Duration) async throws(RecordingError) {
        fatalError("not implemented")
    }

    /// Makes the take: creates the writers for `layout`, starts their sessions at `origin`, appends
    /// `lastFrame` re-stamped at `origin` (so media time 0 has a frame on a still screen), and
    /// starts the heartbeat. Throws `.noFramesDelivered` if no warm frame exists, which `prepare`
    /// rules out by waiting for one.
    func arm(at origin: HostTime, layout: RecordingLayout) throws(RecordingError) {
        fatalError("not implemented")
    }

    func pause(at: HostTime) { fatalError("not implemented") }

    func resume(at: HostTime) { fatalError("not implemented") }

    /// `receive` for every source becomes: no take -> remember the screen frame, drop audio and
    /// camera; take -> `pauses.contains(pts)` -> drop; else append as today.
    ///
    /// `beat()` while paused also calls `keepUp(to: now)` on each audio writer so the silence is
    /// written a second at a time during the pause rather than in one burst at resume (a 30 min
    /// pause is 1 800 appends; spread out they cost nothing, together they would stall the
    /// capture queue at the moment the user wants frames again).

    /// A stop while paused ends every writer at the pause's start (see `StopWhilePaused`), so the
    /// heartbeat frames and silence written during the pause fall after `endSession` and are
    /// dropped by `AVAssetWriter`. The manifest's last pause is then omitted: it ends where the
    /// take ends.
    func finish(at end: HostTime) async throws(RecordingError) -> Finished {
        fatalError("not implemented")
    }

    /// Cancels every writer (files released, not finalised), stops the heartbeat, detaches from
    /// the camera feed, stops the stream. For `discard` and for a failed `begin`. Idempotent.
    func abandon() async { fatalError("not implemented") }
}

extension AudioTrackWriter {
    /// Fills silence from `continuity.writtenThrough` to `now` (minus the usual tolerance), in
    /// chunks of at most one second. The pause heartbeat calls it; the next real buffer after
    /// resume fills whatever is left, as today's gap rule already does.
    func keepUp(to now: HostTime) throws(RecordingError) { fatalError("not implemented") }
}

extension EventLogWriter {
    /// `drain()` filters every input and cursor change through `pauses.contains(time)`. Because
    /// the gate is the stamp, not the drain time, an event stamped before the pause that is
    /// drained after `pause()` is kept, and one stamped inside the pause that happens to be drained
    /// before the ledger is read is still dropped on the next drain (the ledger is read per
    /// drain). Keystrokes during a pause never reach disk.
    func setPauses(_ pauses: PauseLedger) { fatalError("not implemented") }

    /// Writes `move(t:position:)` and, if the image differs from the last declared one,
    /// `cursor(t:id:)` at `at`, from a fresh `InputCapture.snapshot()`. The pointer moved and the
    /// cursor may have changed during the pause; without this the first kept frame after the
    /// pause would show the pointer where it was before.
    func resume(at: HostTime, snapshot: CapturedSnapshot) throws { fatalError("not implemented") }
}

extension ResolvedTarget {
    /// `.display` becomes `SCContentFilter(display:excludingApplications: [self], exceptingWindows: [])`
    /// when this process is listed in the shareable content (it is whenever it has a window on
    /// screen, which it does during a countdown), else today's filter. `.application` and
    /// `.window` already exclude everything that is not the target. A pure `FilterPlan` value
    /// (display, excluded pids, included app or window) is what the unit test checks; the
    /// `SCContentFilter` is built from it in one place.
    var filter: SCContentFilter { fatalError("not implemented") }
}

/// Owned by RecordingFormat in the real change; here so the sketch reads top to bottom.
struct WirePause: Sendable, Equatable, Codable {
    var start: MediaTime
    /// nil only while the take is being recorded. Recovery closes it at the recovered duration, or
    /// drops the pause when its start is at or past the duration.
    var end: MediaTime?
}
