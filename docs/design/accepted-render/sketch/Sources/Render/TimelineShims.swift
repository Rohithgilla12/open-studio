import Foundation
import Timeline

// Stand-ins for Proposed/Timeline/TimelineAdditions.swift so the sketch type-checks against the
// real Timeline product. Deleted when the additions land inside Timeline.

extension SourceRecording {
    public var screenMovie: URL { fatalError("proposed Timeline addition") }
    public var microphoneMovie: URL? { fatalError("proposed Timeline addition") }
}

extension ZoomTrack {
    public enum Edge: Sendable { case start, end }

    public func removing(_ id: ZoomSegment.ID) -> ZoomTrack { fatalError("proposed Timeline addition") }

    public func moving(_ id: ZoomSegment.ID, toStart start: RecordingTime, within duration: RecordingTime) -> ZoomTrack {
        fatalError("proposed Timeline addition")
    }

    public func resizing(_ id: ZoomSegment.ID, edge: Edge, to t: RecordingTime, within duration: RecordingTime) -> ZoomTrack {
        fatalError("proposed Timeline addition")
    }

    public func inserting(around t: RecordingTime, length: RecordingTime, scale: Double, within duration: RecordingTime)
        -> (track: ZoomTrack, id: ZoomSegment.ID)?
    {
        fatalError("proposed Timeline addition")
    }
}
