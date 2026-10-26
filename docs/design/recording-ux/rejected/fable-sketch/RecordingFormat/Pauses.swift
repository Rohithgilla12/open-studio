// Sketch. Module RecordingFormat. Pauses in `recording.json`.
//
//   "pauses": [ { "start": 12_400_000, "end": 31_050_000 }, { "start": 60_000_000 } ]
//
// Recording microseconds on the one clock. The last entry has no `end` only while the status is
// `recording`; a finalized manifest with an open pause is unreadable (`.corrupt` in Timeline).

public import Foundation

extension WireManifest {
    /// Written when a pause begins (open) and again when it ends (closed), through the same atomic
    /// replace the warnings use, so a take killed while paused recovers with every pause.
    public var pauses: [WirePause] { get { fatalError("not implemented") } set { fatalError("not implemented") } }

    /// Version 5 when `pauses` is non-empty. An older reader would ignore the key and export the
    /// paused content, the one thing the person asked to leave out, and an older recovery would
    /// rewrite the manifest without the key and lose the pauses for good. The same two failures
    /// that gave `camera` and `systemAudio` their versions. A take with no pause is written at the
    /// version it would have had, so older builds keep reading it.
    var formatVersion: Int { fatalError("not implemented") }
}

extension FormatVersion {
    /// Added `pauses`.
    static let pauses = 5
    // public static let current = 5
}

extension RecordingSession {
    /// `recover(at:)` gains one step: every open pause is closed at the recovered duration, and a
    /// pause whose start is at or past the duration is dropped. Idempotent with the rest.
    static func closePauses(_ pauses: [WirePause], at duration: MediaTime) -> [WirePause] {
        fatalError("not implemented")
    }
}

// Decoding adds the version gate `version < 5 && contains(.pauses) -> dataCorrupted`, like the
// other keys, and validates order and disjointness so `SourceRecording` can trust the list.
