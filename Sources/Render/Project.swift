import Darwin
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
    ///
    /// A project.json whose `recordingID` is not this take's is ignored, so a file copied between
    /// takes cannot apply the wrong zooms. One written by a newer build is refused, never rewritten
    /// with its unknown fields dropped.
    public static func open(_ take: URL) throws(ProjectError) -> Project {
        let source: SourceRecording
        do {
            source = try SourceRecording.load(from: take)
        } catch {
            throw .source(error)
        }
        let url = ProjectFile.url(in: take)
        guard FileManager.default.fileExists(atPath: url.path),
            let file = try ProjectFile.read(url, recordingID: source.id, duration: source.duration)
        else {
            return Project(source: source, edits: Edits.generated(for: source), origin: .generated)
        }
        return Project(
            source: source,
            edits: Edits(zooms: file.zooms, settings: file.settings, style: file.style, format: file.output),
            origin: .saved)
    }

    /// The take with generated edits, without reading project.json at all, so `--auto-zooms`
    /// still works when the saved file is unreadable.
    public static func generated(_ take: URL) throws(ProjectError) -> Project {
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

    /// The canvas the format renders at for this take. An entire-screen take keeps the preset's box;
    /// a take with an area gets a canvas of the area's shape.
    public func canvasSize(for format: OutputFormat) -> PixelSize {
        guard let area = source.area else { return format.canvasSize(for: source.frameSize, padding: edits.style.padding) }
        return format.canvasSize(forArea: area.size, padding: edits.style.padding)
    }

    /// Atomic replace of project.json (write to a temporary file in the same directory, then
    /// rename), so a crash mid-save leaves the previous edits. Saving the same edits twice writes
    /// the same bytes (sorted keys). The only file this module ever writes into a take.
    public func save() throws(ProjectError) {
        let file = ProjectFile(
            format: ProjectFile.formatIdentifier, version: ProjectFile.currentVersion, recordingID: source.id,
            zooms: edits.zooms, settings: edits.settings, style: edits.style, output: edits.format)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data: Data
        do {
            data = try encoder.encode(file)
        } catch {
            throw .saveFailed(error.localizedDescription)
        }
        let destination = ProjectFile.url(in: source.directory)
        let temporary = source.directory.appending(
            path: ".\(ProjectFile.fileName).\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        do {
            try data.write(to: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw .saveFailed(error.localizedDescription)
        }
        guard rename(temporary.path, destination.path) == 0 else {
            let message = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw .saveFailed("\(destination.path): \(message)")
        }
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

/// The on-disk shape. Internal, so no caller depends on the file layout.
///
///     { "format": "open-studio.project", "version": 1, "recordingID": "...",
///       "zooms": [ {id, range: {start, end}, scale, focus} ], "settings": {...},
///       "style": {...}, "output": {...} }
///
/// Additive keys keep the version, as in the recording format: the settings decoders default
/// missing keys. A change to the meaning of a field bumps the version.
struct ProjectFile: Codable {
    static let fileName = "project.json"
    static let formatIdentifier = "open-studio.project"
    static let currentVersion = 1

    var format: String
    var version: Int
    var recordingID: UUID
    var zooms: ZoomTrack
    var settings: TimelineSettings
    var style: Style
    var output: OutputFormat

    static func url(in take: URL) -> URL { take.appending(path: fileName, directoryHint: .notDirectory) }

    /// The header is decoded first, so a newer version is refused, and a file from another take
    /// ignored, before the body is parsed or validated.
    private struct Header: Decodable {
        var format: String
        var version: Int
        var recordingID: UUID
    }

    /// nil when the file belongs to another take.
    static func read(_ url: URL, recordingID: UUID, duration: RecordingTime) throws(ProjectError) -> ProjectFile? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .projectUnreadable(error.localizedDescription)
        }
        let decoder = JSONDecoder()
        let header: Header
        do {
            header = try decoder.decode(Header.self, from: data)
        } catch {
            throw .projectUnreadable("\(fileName): \(error)")
        }
        guard header.format == formatIdentifier else {
            throw .projectUnreadable("\(fileName) has format \(header.format), expected \(formatIdentifier)")
        }
        guard header.version <= currentVersion else {
            throw .projectFromNewerVersion(found: header.version, supported: currentVersion)
        }
        guard header.recordingID == recordingID else { return nil }
        let file: ProjectFile
        do {
            file = try decoder.decode(ProjectFile.self, from: data)
        } catch let error as ZoomTrackError {
            throw .invalidZooms(error)
        } catch {
            throw .projectUnreadable("\(fileName): \(error)")
        }
        if let segment = file.zooms.segments.first(where: { $0.range.start < .zero || $0.range.end > duration }) {
            throw .projectUnreadable("\(fileName): zoom \(segment.id) lies outside the recording")
        }
        if let problem = file.style.problem {
            throw .projectUnreadable("\(fileName): style \(problem)")
        }
        return file
    }
}

extension Style {
    /// Why a decoded style cannot be rendered, or nil. The geometry trusts these ranges.
    var problem: String? {
        if !(padding >= 0 && padding < 0.5) { return "padding \(padding) is not in [0, 0.5)" }
        if !(cornerRadius >= 0) { return "cornerRadius \(cornerRadius) is negative" }
        if !(shadow.opacity >= 0 && shadow.opacity <= 1) { return "shadow opacity \(shadow.opacity) is not in [0, 1]" }
        if !(shadow.blur >= 0) { return "shadow blur \(shadow.blur) is negative" }
        if !shadow.offsetY.isFinite { return "shadow offset is not finite" }
        if !CameraOverlay.sizeRange.contains(camera.size) { return "camera size \(camera.size) is not in \(CameraOverlay.sizeRange)" }
        if !CameraOverlay.insetRange.contains(camera.inset) { return "camera inset \(camera.inset) is not in \(CameraOverlay.insetRange)" }
        if case .image(let asset) = background, asset.fileName.isEmpty || asset.fileName.contains("/") {
            return "background image name \(asset.fileName) is not a file name"
        }
        return nil
    }
}
