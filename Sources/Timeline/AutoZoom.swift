import Foundation

/// A span of the recording during which the camera is zoomed in.
///
/// Zoom segments are edit state: generated once when a project is created, then owned and edited by
/// the editor. `Timeline` takes them as input and never generates them itself, so a user's edits are
/// never silently replaced.
public struct ZoomSegment: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var range: TimeRange
    /// Camera scale while the segment is active. 2 for generated segments.
    public var scale: Double
    public var focus: Focus

    public enum Focus: Sendable, Hashable, Codable {
        /// Follow the time-weighted centroid of pointer groups inside the segment.
        case followPointer
        /// Hold on a fixed point, normalized to the frame (0...1, origin top-left).
        case fixed(x: Double, y: Double)
    }

    public init(id: UUID = UUID(), range: TimeRange, scale: Double, focus: Focus) {
        self.id = id
        self.range = range
        self.scale = scale
        self.focus = focus
    }
}

/// Zoom segments the camera can run: sorted by start and non-overlapping. Built only by
/// `init(validating:)`, so `Timeline` never repairs an editor's mistake silently.
public struct ZoomTrack: Sendable, Hashable, Codable {
    public let segments: [ZoomSegment]

    public static let empty = ZoomTrack(sorted: [])

    public init(validating segments: [ZoomSegment]) throws(ZoomTrackError) {
        let sorted = segments.sorted { $0.range.start < $1.range.start }
        for (earlier, later) in zip(sorted, sorted.dropFirst()) where later.range.start < earlier.range.end {
            throw .overlap(earlier.id, later.id)
        }
        for segment in sorted where !(segment.scale >= 1) {
            throw .scaleBelowOne(segment.id)
        }
        var ids: Set<UUID> = []
        for segment in sorted where !ids.insert(segment.id).inserted {
            throw .duplicateID(segment.id)
        }
        self.init(sorted: sorted)
    }

    init(sorted segments: [ZoomSegment]) { self.segments = segments }

    /// Encoded as the bare segment array. Decoding validates, so a file cannot build an overlapping
    /// track; a `ZoomTrackError` surfaces unchanged.
    public init(from decoder: any Decoder) throws {
        try self.init(validating: try [ZoomSegment](from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        try segments.encode(to: encoder)
    }
}

public enum ZoomTrackError: Error, Sendable, Equatable {
    /// `second` starts before `first` ends.
    case overlap(UUID, UUID)
    case scaleBelowOne(UUID)
    /// Edits address segments by id, so two segments cannot share one.
    case duplicateID(UUID)
}

public enum AutoZoom {
    /// The automatic segments for a recording, sorted and non-overlapping.
    public static func segments(for source: SourceRecording, settings: AutoZoomSettings = AutoZoomSettings()) -> [ZoomSegment] {
        segments(
            clickTimes: source.buttons.filter { source.frameSize.contains($0.position) }.map(\.time),
            duration: source.duration, settings: settings)
    }

    public static func track(for source: SourceRecording, settings: AutoZoomSettings = AutoZoomSettings()) -> ZoomTrack {
        ZoomTrack(sorted: segments(for: source, settings: settings))
    }

    /// Pure core, exposed for tests and for the editor's "regenerate zooms" action.
    ///
    /// Generated ids are derived from the segment's range, not random, so generating twice from the
    /// same input yields equal arrays.
    public static func segments(
        clickTimes: [RecordingTime], duration: RecordingTime, settings: AutoZoomSettings
    ) -> [ZoomSegment] {
        let lastAllowed = duration - settings.ignoreClicksInFinal
        let latestEnd = duration - settings.endMargin
        let windows = clickTimes
            .filter { $0 < lastAllowed }
            .compactMap { t in
                TimeRange(start: max(t - settings.windowBefore, .milliseconds(1)), end: min(t + settings.windowAfter, latestEnd))
            }
            .sorted { $0.start < $1.start }

        // After sorting by start, a window can only merge with the most recent merged segment: any
        // earlier merged segment ends more than mergeGap before the most recent one starts, else the
        // two would have merged already, and starts only grow. So "merge repeatedly until stable"
        // reaches the same fixed point as this single sweep. The property test checks it.
        var merged: [TimeRange] = []
        for window in windows {
            if let last = merged.last, window.start - last.end <= settings.mergeGap {
                merged[merged.count - 1] = TimeRange(start: last.start, end: max(last.end, window.end))!
            } else {
                merged.append(window)
            }
        }
        return merged.map {
            ZoomSegment(id: stableID(for: $0), range: $0, scale: settings.scale, focus: .followPointer)
        }
    }

    /// The 16 bytes of (start, end) as little-endian microseconds, read as a UUID.
    static func stableID(for range: TimeRange) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: range.start.microseconds.littleEndian) { bytes.replaceSubrange(0..<8, with: $0) }
        withUnsafeBytes(of: range.end.microseconds.littleEndian) { bytes.replaceSubrange(8..<16, with: $0) }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
