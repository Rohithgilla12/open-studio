// Proposed additions to Sources/Timeline. Not a sketch target: these use Timeline internals
// (`ZoomTrack.init(sorted:)`, `RecordingLayout`), so they only compile inside the module.
// `Sources/Render/TimelineShims.swift` stands in for them so the sketch type-checks.

import Foundation
internal import RecordingFormat

// MARK: Media URLs through the public API

extension SourceRecording {
    // Stored, set in `init(_ metadata:)` from `RecordingLayout(directory:)`, so file names stay in
    // RecordingFormat and the renderer never spells "screen.mov".
    //
    //     public let screenMovie: URL
    //     public let microphoneMovie: URL?        // nil when the manifest lists no microphone
    //     public var hasMicrophone: Bool { microphoneMovie != nil }   // was stored; now derived
    //
    // `CursorImageInfo.relativePath` stays. The renderer resolves it against `directory`.
}

// MARK: Edits that keep a ZoomTrack valid by construction

/// Every edit the zoom strip can make. Each is total: it clamps instead of throwing, so the
/// editor never holds a rejected edit, and `ZoomTrack(validating:)` stays the only throwing door
/// (used for decoding and for callers that assemble segments themselves).
extension ZoomTrack {
    public static let minimumSegmentDuration = RecordingTime.milliseconds(200)

    public enum Edge: Sendable { case start, end }

    /// Unchanged when `id` is absent.
    public func removing(_ id: ZoomSegment.ID) -> ZoomTrack {
        ZoomTrack(sorted: segments.filter { $0.id != id })
    }

    /// Moves the segment so it starts at `start`, keeping its duration. Clamped to the gap between
    /// its neighbours and to `[0, duration]`.
    public func moving(_ id: ZoomSegment.ID, toStart start: RecordingTime, within duration: RecordingTime) -> ZoomTrack {
        // TODO:
        //   i = index of id, else return self
        //   lo = i > 0 ? segments[i-1].range.end : .zero
        //   hi = i+1 < count ? segments[i+1].range.start : duration
        //   d  = segments[i].range.duration; if hi - lo < d, d stays and the move is a no-op
        //   s  = clamp(start, lo...(hi - d))
        //   replace range with TimeRange(start: s, end: s + d)!; order is unchanged, so sorted holds
        fatalError("not implemented")
    }

    /// Drags one edge. The segment keeps at least `minimumSegmentDuration` and stays between
    /// its neighbours.
    public func resizing(_ id: ZoomSegment.ID, edge: Edge, to t: RecordingTime, within duration: RecordingTime) -> ZoomTrack {
        fatalError("not implemented")
    }

    /// Inserts a generated-looking segment (scale 2, follow pointer) centred on `t`, shrunk to fit
    /// the gap it lands in. Returns nil when the gap is shorter than `minimumSegmentDuration`.
    public func inserting(around t: RecordingTime, length: RecordingTime, scale: Double, within duration: RecordingTime)
        -> (track: ZoomTrack, id: ZoomSegment.ID)?
    {
        fatalError("not implemented")
    }

    public func updating(_ id: ZoomSegment.ID, scale: Double? = nil, focus: ZoomSegment.Focus? = nil) -> ZoomTrack {
        // scale is clamped to >= 1, so the scaleBelowOne invariant holds without a throw.
        fatalError("not implemented")
    }
}

// MARK: Decoding must not bypass the validating initialisers

// Today `TimeRange` and `ZoomTrack` synthesise `init(from:)`, which skips `init?(start:end:)` and
// `init(validating:)`. A hand-edited or older project.json could then build an empty range or an
// overlapping track, the exact states the types promise cannot exist. Both get explicit decoders:
//
//     extension TimeRange {
//         public init(from decoder: Decoder) throws {
//             let c = try decoder.container(keyedBy: CodingKeys.self)
//             guard let r = TimeRange(start: try c.decode(.start), end: try c.decode(.end)) else {
//                 throw DecodingError.dataCorruptedError(forKey: .end, in: c, debugDescription: "empty range")
//             }
//             self = r
//         }
//     }
//     extension ZoomTrack {
//         public init(from decoder: Decoder) throws {
//             try self.init(validating: try [ZoomSegment](from: decoder))   // ZoomTrackError surfaces as-is
//         }
//         public func encode(to encoder: Encoder) throws { try segments.encode(to: encoder) }
//     }
//
// The settings structs (`TimelineSettings`, `AutoZoomSettings`, `CameraSettings`, `CursorSettings`)
// get decoders that use `decodeIfPresent ?? default` per key, so a project saved before a new
// setting existed still opens. Synthesised Codable fails on the first missing key.
