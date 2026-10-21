import Foundation
import Timeline

// Signature changes only. The bodies keep their shape; the two builder calls become
//
//     let media = try await SourceMedia.load(project.source)
//     let movie = MovieComposition(media: media, map: project.timeline.map)
//
// and everything derived from `movie.duration` (framesTotal, the still clamp) is now output time
// without further edits.

extension Export {
    // run(_:to:progress:) is unchanged in signature.
}

public struct ExportReport: Sendable, Hashable {
    public let destination: URL
    public let frames: Int
    /// The exported movie's length: the kept duration.
    public let duration: OutputTime
    public let wallSeconds: Double
    public let bytes: Int64
    public let warnings: [String]
}

extension Still {
    /// The frame the exported movie shows at `t`. Clamped to one frame before `map.duration`.
    public static func png(_ project: Project, at t: OutputTime) async throws(ExportError) -> Data {
        fatalError("not implemented")
    }
}

// osrec:
// - `export --still <ms>` reads output milliseconds, the time in the movie `export --out` writes;
//   the help text says so.
// - `inspect --timeline` prints the kept segments (recording range -> output start) and the joins,
//   then samples `frame(at:)` at output times.
