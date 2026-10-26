// Sketch. Module Recording. Replaces `RecordingSession.start(_:)`.
//
// The take's life is two types, and holding one tells you what is true:
//   PreparedRecording   capture is warm (stream, input tap, camera feed), nothing is on disk
//   RecordingSession    a directory exists and frames are being written
//
//   prepare(config, camera) ──▶ PreparedRecording ──begin()──▶ RecordingSession ──stop()──▶ FinishedRecording
//                                     │ cancel()                     │ discard()  ──▶ FinishedRecording(.discarded), directory in the Trash
//                                     ▼                              │ pause() / resume()
//                                  nothing                           ▼
//                                                              Studio prepares again for a restart

import AVFoundation
public import Foundation
internal import RecordingFormat

/// Capture that is running but writing nothing: the stream, the input tap, and the camera feed are
/// up, the first screen frame has arrived, and no directory exists. The countdown runs over this, so
/// the warm-up (about 230 ms to the first screen frame, a few hundred ms for a camera, both measured
/// in earlier designs) is hidden under the digits, and a cancelled countdown has nothing to delete.
///
/// A process that dies while prepared leaves no trace: no directory, no lock, no manifest.
public actor PreparedRecording {
    public nonisolated let configuration: RecordingConfiguration

    /// Checks permissions, resolves the target, starts the stream and the input tap, attaches the
    /// recorder to `camera`, and returns once the first complete screen frame has arrived.
    ///
    /// `camera` is the feed for `configuration.camera`; nil only when that selection is `.none`,
    /// otherwise `.cameraNotFound`. One feed serves the preview bubble and the recorder (see
    /// `CameraFeed`). The feed outlives the take; the recorder only attaches an output to it.
    ///
    /// Our own windows are excluded from a display or area capture by excluding this process's
    /// `SCRunningApplication` (`ResolvedTarget.filter`), which covers windows made later too
    /// (inferred from the SCContentFilter documentation, measured by `spike/exclusion.swift` when
    /// run from a terminal with Screen Recording). A window target includes only the target's app,
    /// so ours are out by construction.
    public static func prepare(
        _ configuration: RecordingConfiguration, camera: CameraFeed?
    ) async throws(RecordingError) -> PreparedRecording {
        fatalError("not implemented")
    }

    /// Time zero is now. Creates the directory, takes the lock, starts every writer's session at
    /// this instant, writes `recording.json`, and returns a live session. Never waits for the
    /// display to change: the last warm frame is re-stamped at the origin and appended first, the
    /// way the heartbeat already re-stamps a frame on a still screen, so `screen.mov` has a
    /// picture at media time 0 whatever the screen is doing.
    ///
    /// Everything delivered before the origin is dropped by the rules the writers already have:
    /// audio and camera buffers with a PTS before the session start, and inputs whose
    /// `mediaTime(since: origin)` is nil. A screen frame in flight with a PTS before the origin is
    /// dropped by the same comparison.
    ///
    /// Either returns a live session or throws and removes the half-made directory, as `start` did.
    /// Consumes the prepared capture: a second `begin()` throws `.alreadyBegun`.
    public func begin() async throws(RecordingError) -> RecordingSession {
        fatalError("not implemented")
    }

    /// Stops the stream and the input tap and detaches from the camera feed. Idempotent. Nothing
    /// was ever on disk.
    public func cancel() async {
        fatalError("not implemented")
    }
}

extension RecordingSession {
    /// Stops writing captured content without stopping the clock. From this instant until
    /// `resume()`: screen frames, audio buffers, camera frames, input events, and cursor changes
    /// are dropped at one gate, `PauseLedger.contains(hostTime)`, in the sink and the event log.
    /// The heartbeat keeps ticking once a second so the files stay in lockstep for recovery: the
    /// screen repeats its last pre-pause frame (a tiny P-frame of a picture the viewer never sees
    /// again, because the pause becomes a cut), and each audio writer fills a second of silence,
    /// which `AVAssetWriter` needs because it cannot represent a gap (measured in the system-audio
    /// design). Nothing captured during the pause reaches disk.
    ///
    /// The pause is written to `recording.json` as it begins, open-ended, so a take killed while
    /// paused recovers with the pause intact. Idempotent: pausing a paused session does nothing.
    public func pause() async {
        fatalError("not implemented")
    }

    /// Closes the open pause in the manifest, re-declares the pointer position and the cursor image
    /// in effect now (the user moved during the pause) as a `move` and a `cursor` event at this
    /// instant, and lets captured content through again. Idempotent.
    public func resume() async {
        fatalError("not implemented")
    }

    /// Ends the take and moves its directory to the Trash. Writers are cancelled, not finished, so
    /// no time is spent finalising a take nobody wants; the lock is released before the move. The
    /// session finishes with `Termination.discarded(trashedTo:)`, and `updates` ends as for a stop.
    /// Idempotent with `stop()`: whichever arrives first wins, the other returns the same result.
    public func discard() async -> FinishedRecording {
        fatalError("not implemented")
    }
}

/// The take's clock as the user sees it: elapsed time excludes pauses. A value, emitted with each
/// change through `RecordingUpdate.clock`, so a control bar can tick every second from its own
/// timer without waiting for a frame (`progress` arrives only when the screen changes).
///
/// `SuspendingClock.Instant` is `CLOCK_UPTIME_RAW`, the recorder's host clock (measured:
/// `spike/hotkey.swift` prints both, equal to 0.1 µs in two runs), so `HostTime` converts exactly.
public struct TakeClock: Sendable, Equatable {
    public let startedAt: SuspendingClock.Instant
    /// Closed pauses, in order.
    public let pauses: [Range<SuspendingClock.Instant>]
    /// Set while paused.
    public let pausedSince: SuspendingClock.Instant?

    public var isPaused: Bool { pausedSince != nil }

    /// `now - startedAt - pauses - (now - pausedSince)`. Monotone while paused: it stands still.
    public func elapsed(at now: SuspendingClock.Instant = .now) -> Duration {
        fatalError("not implemented")
    }
}

extension RecordingUpdate {
    /// Emitted at begin, pause, and resume. Added to the existing enum; a `switch` without this
    /// case fails to compile, which is how the app's recording view learns about it.
    public static func clock(_ clock: TakeClock) -> RecordingUpdate { fatalError("not implemented") }
}

extension Termination {
    /// The user restarted or cancelled; the directory is in the Trash at this URL.
    public static func discarded(trashedTo: URL) -> Termination { fatalError("not implemented") }
}

extension RecordingError {
    public static var alreadyBegun: RecordingError { fatalError("not implemented") }
}

// Usage: Studio (countdown drives begin), osrec (no countdown unless asked).
//
//   let feed = try CameraFeed.open(preferences.camera)                // on Home, for the bubble
//   let prepared = try await PreparedRecording.prepare(configuration, camera: feed)
//   ... countdown reaches zero ...
//   let session = try await prepared.begin()                          // time zero = now
//   for await update in session.updates { switch update { case .clock(let c): bar.clock = c; ... } }
//   await session.pause(); await session.resume()
//   let finished = await session.stop()                               // or session.discard()
//
//   osrec record --countdown 3 --camera default   // prints the digits, then the directory
