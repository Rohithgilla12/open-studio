// Sources/RecordingFormat/Manifest.swift, Layout.swift, Reader.swift; Sources/Recording/Recovery.swift.

/// `"pauses": [{"start": 4200000, "end": 9100000}, {"start": 15000000}]`
///
/// Media time, microseconds from the origin, like every other time in the directory. An absent
/// `end` means the pause was still open when this manifest was written: legal while `status` is
/// `recording`, and closed by recovery.
public struct WirePause: Sendable, Equatable, Codable {
    public var start: MediaTime
    public var end: MediaTime?
}

extension WireManifest {
    // public var pauses: [WirePause]      // encoded only when non-empty

    var formatVersion: Int {
        // if !pauses.isEmpty { return FormatVersion.pauses }   // 5
        // ...then today's rules, so a take with no pause keeps the version it has today.
        fatalError("not implemented")
    }
}

extension FormatVersion {
    /// Added `pauses`. An older reader would play the paused ranges: a held frame and silence where
    /// the person asked for nothing. It must refuse instead, and an older recovery must not rewrite
    /// the manifest without the key.
    static let pauses = 5
}

// Reader validation, at the boundary, so nothing downstream re-checks:
// - pauses sorted by start, disjoint, start >= 0, end > start when present;
// - only the last pause may be open, and only while status is `recording`;
// - a finalized manifest with an open pause is `manifestUnreadable`.

// RecordingSession.recover(at:), added steps, after probing the screen's duration d:
// - close an open pause at d;
// - clamp every end to d and drop a pause that starts at or after d, because the last fragment of
//   `screen.mov` can end up to a second before a pause the manifest already recorded.
// A take killed while paused therefore opens with the paused tail removed. The heartbeat keeps
// writing the held frame during a pause, so d reaches the moment of death, not the pause's start.
