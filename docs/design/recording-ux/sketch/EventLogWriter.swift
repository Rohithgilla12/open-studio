// Sources/Recording/EventLogWriter.swift (changed), InputCapture.swift (one filter).

actor EventLogWriter {
    // Created at roll, one per take, as today after the first frame. The tap itself
    // (InputCapture) starts with the rig and runs across restarts; events before a take's origin
    // are dropped by the existing `mediaTime(since:)` check.

    /// Pushed by the session on every pause and resume. `drain` drops every event and cursor
    /// change whose time the clock does not admit, so no keystroke, click, or cursor image from a
    /// pause reaches `events.ndjson`.
    func apply(_ clock: HostClock) { fatalError("not implemented") }

    /// On resume at `t`: one `.state` event at `t` with the pointer position, held buttons, and
    /// cursor image as they are now, declaring the image if it is new. The format already allows
    /// a state event mid-log (SourceRecording reads every `.state` as a pointer sample, button
    /// downs, and a cursor change), so the editor knows where the cursor is after the cut without a
    /// format change.
    func resumed(at t: HostTime, snapshot: CapturedSnapshot) throws { fatalError("not implemented") }

    /// Finishes at `end` and drops anything after it, so the click on Stop, or the stop hot key,
    /// never lands in the take.
    func finish(at end: HostTime) async throws -> Int { fatalError("not implemented") }
}

// InputCapture: a mouse down, up, drag, or scroll whose `eventTargetUnixProcessID` is this
// process is a press on the control bar or the bubble, not part of the take, and is not
// buffered. Without it, auto-zoom would zoom into an empty corner where the invisible control bar
// was. Moves are kept so the cursor track has no hole. Inferred: the field is documented for
// mouse events, but whether a listen-only session tap sees it filled was not measured.
