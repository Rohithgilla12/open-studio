import Foundation
import Timeline

// Changes to Project.swift only. Everything not shown is today's.

public struct Edits: Sendable, Hashable {
    public var zooms: ZoomTrack
    public var settings: TimelineSettings
    public var style: Style
    public var format: OutputFormat
    public var audio: AudioLevels
    /// What the user removed, in recording time. Undo, autosave, and export snapshot it with the
    /// rest of the value, so a cut is undone exactly like a zoom move.
    public var cuts: Cuts
}

extension Project {
    // `edits.didSet` already rebuilds `timeline`; it now passes `cuts: edits.cuts`, and
    // `timeline.map` is the map every renderer reads. There is no `Project.map`: one derived copy.
}

/// The on-disk shape gains one key:
///
///     "cuts": [ { "id": "...", "range": { "start": 0, "end": 2100000 } },
///               { "id": "...", "range": { "start": 31250000, "end": 33900000 } } ]
///
/// Recording microseconds, the same `{id, range}` shape as a zoom. Trims are the cuts that touch 0
/// or the duration. Absent means no cuts.
struct ProjectFile: Codable {
    static let fileName = "project.json"
    static let formatIdentifier = "open-studio.project"
    /// The newest version this build reads.
    static let currentVersion = 2

    var format: String
    var version: Int
    var recordingID: UUID
    var zooms: ZoomTrack
    var settings: TimelineSettings
    var style: Style
    var output: OutputFormat
    var audio: AudioLevels?
    /// Decoded as bare cuts; validated against the duration in `read`, like zooms.
    var cuts: [Cut]?

    /// The lowest version whose reader renders this file correctly. A file without cuts stays
    /// version 1, so today's build keeps opening it. A file with cuts is version 2, because
    /// today's build ignores unknown keys: it would export the removed ranges (the mistake, or the
    /// password typed on screen, comes back) and its autosave would rewrite the file without them.
    /// That changes what the file means, which the file's own rule says bumps the version, and
    /// today's build refuses a newer version without rewriting it. Speed ranges will be version 3,
    /// written only when present, by this same function.
    static func version(for edits: Edits) -> Int {
        edits.cuts.isEmpty ? 1 : 2
    }

    /// Today's header-first checks. After the body decodes:
    /// - `cuts` goes through `Cuts(validating:within: duration)`; a failure is
    ///   `ProjectError.invalidCuts(CutsError)`, so a file with overlapping cuts, cuts outside the
    ///   recording, a kept sliver, or nothing kept is rejected, never repaired;
    /// - zooms keep today's check against the recording duration. A zoom inside a cut is valid: it
    ///   is inert while the cut exists and comes back when the cut is restored.
    static func read(_ url: URL, recordingID: UUID, duration: RecordingTime) throws(ProjectError) -> (file: ProjectFile, cuts: Cuts)? {
        fatalError("not implemented")
    }
}

public enum ProjectError: Error, Sendable, Equatable {
    case source(SourceLoadError)
    case projectUnreadable(String)
    case projectFromNewerVersion(found: Int, supported: Int)
    case invalidZooms(ZoomTrackError)
    case invalidCuts(CutsError)
    case saveFailed(String)
}
