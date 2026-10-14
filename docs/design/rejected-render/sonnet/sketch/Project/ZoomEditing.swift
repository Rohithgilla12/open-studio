public import Timeline

/// Pure edits on a `ZoomTrack`. Each returns a track that is valid by construction: moves and resizes
/// clamp to the neighbours and to `[0, duration]`, so the editor can never produce the overlap that
/// `ZoomTrack(validating:)` would reject, and `Timeline` never needs repairing.
public enum ZoomEditing {
    public static let minimumLength = RecordingTime.milliseconds(300)

    public static func delete(_ id: ZoomSegment.ID, from track: ZoomTrack) -> ZoomTrack { fatalError("not implemented") }

    /// Shifts the whole segment, keeping its length, stopping at the nearest neighbour or the ends.
    public static func move(
        _ id: ZoomSegment.ID, to start: RecordingTime, in track: ZoomTrack, duration: RecordingTime
    ) -> ZoomTrack { fatalError("not implemented") }

    public enum Edge { case start, end }

    /// Moves one edge. Never crosses a neighbour, never shrinks below `minimumLength`.
    public static func resize(
        _ id: ZoomSegment.ID, edge: Edge, to time: RecordingTime, in track: ZoomTrack, duration: RecordingTime
    ) -> ZoomTrack { fatalError("not implemented") }

    /// Adds a default-scale segment at `time` if a gap of at least `minimumLength` exists there, else nil.
    public static func add(at time: RecordingTime, to track: ZoomTrack, duration: RecordingTime) -> ZoomTrack? {
        fatalError("not implemented")
    }
}
