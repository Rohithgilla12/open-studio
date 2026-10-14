import Foundation
import Timeline

/// A take plus its edits: the unit the app edits and the unit `osrec export` exports, so the
/// command line renders exactly what the editor shows.
///
/// Edits live in `<take>.osrec/project.json`. The recorder's files are never written: the recorder
/// is the only writer until finalisation, the files are immutable after it, and recovery and the
/// reader ignore names they do not know (checked: neither enumerates the directory). Keeping the
/// edits inside the take means moving, copying, or deleting the take in Finder carries its edits.
public struct Project: Sendable {
    public let source: SourceRecording
    /// The single source of truth for edit state. `timeline` is derived from it.
    public var edits: Edits {
        didSet { timeline = Timeline(source: source, zooms: edits.zooms, settings: edits.settings) }
    }
    public private(set) var timeline: Timeline
    /// Whether `edits` came from project.json or were generated on open.
    public let origin: EditsOrigin

    /// Loads the take's metadata and its saved edits, or generates defaults (automatic zooms,
    /// default settings and style) when there are none. Never writes.
    public static func open(_ take: URL) throws(ProjectError) -> Project {
        let source: SourceRecording
        do {
            source = try SourceRecording.load(from: take)
        } catch {
            throw .source(error)
        }
        return Project(source: source, edits: Edits.generated(for: source), origin: .generated)
    }

    init(source: SourceRecording, edits: Edits, origin: EditsOrigin) {
        self.source = source
        self.edits = edits
        self.origin = origin
        timeline = Timeline(source: source, zooms: edits.zooms, settings: edits.settings)
    }

    /// Replaces the zooms with freshly generated ones from the current auto-zoom settings.
    public mutating func regenerateZooms() {
        edits.zooms = AutoZoom.track(for: source, settings: edits.settings.autoZoom)
    }
}

/// Everything the user can change. A value, so undo is "keep the previous value", autosave is
/// "encode the current value", and export snapshots by copying.
public struct Edits: Sendable, Hashable {
    public var zooms: ZoomTrack
    public var settings: TimelineSettings
    public var style: Style
    public var format: OutputFormat

    public init(zooms: ZoomTrack, settings: TimelineSettings, style: Style, format: OutputFormat) {
        self.zooms = zooms
        self.settings = settings
        self.style = style
        self.format = format
    }

    /// What a take gets before anyone edits it: automatic zooms, default settings and style, 1080p60.
    public static func generated(for source: SourceRecording) -> Edits {
        Edits(zooms: AutoZoom.track(for: source), settings: .default, style: .default, format: .hd1080)
    }
}

public enum EditsOrigin: Sendable, Hashable {
    case saved
    case generated
}

public enum ProjectError: Error, Sendable, Equatable {
    case source(SourceLoadError)
    case projectUnreadable(String)
    case projectFromNewerVersion(found: Int, supported: Int)
    case invalidZooms(ZoomTrackError)
    case saveFailed(String)
}
