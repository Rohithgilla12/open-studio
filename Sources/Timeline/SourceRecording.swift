import Foundation
internal import RecordingFormat

/// The validated facts of one finalized recording. Immutable; built only by `load(from:)`.
///
/// Every array is sorted by time and every reference resolves, so code that takes a
/// `SourceRecording` never re-checks the file.
public struct SourceRecording: Sendable {
    public let id: UUID
    public let directory: URL
    public let duration: RecordingTime
    /// Screen video size in pixels. Every `Point` in this model is in this space.
    public let frameSize: Size
    public let hasMicrophone: Bool
    public let termination: SourceTermination

    /// Every pointer position: the t = 0 state, moves, drags, downs, and ups. Sorted by time.
    public let pointer: [PointerSample]
    /// Button transitions. Both downs and ups feed auto-zoom (each up extends the click's window by the
    /// press duration, matching the observed behaviour). Sorted by time.
    public let buttons: [ButtonEvent]
    /// Times of key presses, sorted. Key codes are not exposed; nothing in Timeline needs them.
    public let keyDowns: [RecordingTime]
    /// Which cursor image is showing from each time on. Sorted by time.
    public let cursorChanges: [CursorChange]
    public let cursorImages: [CursorImageID: CursorImageInfo]

    /// Diagnostics found while loading (unknown event types, undeclared cursors, out-of-order lines
    /// that were re-sorted). Loading succeeded despite them.
    public let loadWarnings: [String]

    /// Reads `recording.json` and `events.ndjson` (never the media), then validates into the domain.
    ///
    /// This is the only I/O in Timeline, kept at the edge; everything after it is pure.
    public static func load(from directory: URL) throws(SourceLoadError) -> SourceRecording {
        let metadata: RecordingMetadata
        do {
            metadata = try RecordingReader.read(at: directory)
        } catch {
            throw SourceLoadError(error, directory: directory)
        }
        switch metadata.health {
        case .finalized: break
        case .live: throw .stillRecording
        case .crashed, .unrecoverable: throw .needsRecovery
        }
        return try SourceRecording(metadata)
    }

    /// Pure: wire values in, domain out. Internal so tests can feed synthetic metadata.
    init(_ metadata: RecordingMetadata) throws(SourceLoadError) {
        let manifest = metadata.manifest
        guard case .finalized(let duration, let wireTermination) = manifest.status else {
            throw .needsRecovery
        }
        guard duration > .zero else { throw .corrupt("finalized duration is \(duration)") }
        guard manifest.screen.pixelWidth > 0, manifest.screen.pixelHeight > 0 else {
            throw .corrupt("screen size is \(manifest.screen.pixelWidth)×\(manifest.screen.pixelHeight)")
        }

        var warnings: [String] = []
        for (type, count) in metadata.events.unknownTypeCounts.sorted(by: { $0.key < $1.key }) {
            warnings.append("skipped \(count) event(s) of unknown type \(type)")
        }

        var declared: [CursorImageID: CursorImageInfo] = [:]
        var timed: [(time: MediaTime, event: WireEvent)] = []
        for event in metadata.events.events {
            switch event {
            case .cursorImage(let declaration):
                let info = CursorImageInfo(
                    relativePath: RecordingLayout.cursorImagePath(declaration.id),
                    hotspot: try Point(validating: declaration.hotspot),
                    size: Size(width: declaration.size.width, height: declaration.size.height))
                guard info.size.width.isFinite, info.size.height.isFinite else {
                    throw .corrupt("cursor \(declaration.id) has a non-finite size")
                }
                declared[CursorImageID(declaration.id)] = info
            case .state(let t, _, _, _), .move(let t, _), .down(let t, _, _, _), .up(let t, _, _),
                .scroll(let t, _, _, _), .key(let t, _), .cursor(let t, _):
                guard t >= .zero else { throw .corrupt("event at negative time \(t)") }
                timed.append((t, event))
            }
        }
        if !timed.isSorted(by: { $0.time <= $1.time }) {
            warnings.append("events were not in time order; re-sorted")
            timed.sort { $0.time < $1.time }
        }

        var pointer: [PointerSample] = []
        var buttons: [ButtonEvent] = []
        var keyDowns: [RecordingTime] = []
        var cursorChanges: [CursorChange] = []
        var undeclared: Set<CursorImageID> = []

        func resolve(_ wireID: RecordingFormat.CursorImageID) -> CursorImageID? {
            let id = CursorImageID(wireID)
            if declared[id] != nil { return id }
            undeclared.insert(id)
            return nil
        }

        for (t, event) in timed {
            let time = RecordingTime(t)
            switch event {
            case .cursorImage:
                continue
            case .state(_, let position, let held, let cursor):
                let p = try Point(validating: position)
                pointer.append(PointerSample(time: time, position: p))
                for button in WireButton.allCases where held.contains(button) {
                    buttons.append(ButtonEvent(time: time, button: ButtonEvent.Button(button), edge: .down, position: p))
                }
                cursorChanges.append(CursorChange(time: time, image: cursor.flatMap(resolve)))
            case .move(_, let position):
                pointer.append(PointerSample(time: time, position: try Point(validating: position)))
            case .down(_, let button, let position, _):
                let p = try Point(validating: position)
                pointer.append(PointerSample(time: time, position: p))
                buttons.append(ButtonEvent(time: time, button: ButtonEvent.Button(button), edge: .down, position: p))
            case .up(_, let button, let position):
                let p = try Point(validating: position)
                pointer.append(PointerSample(time: time, position: p))
                buttons.append(ButtonEvent(time: time, button: ButtonEvent.Button(button), edge: .up, position: p))
            case .scroll:
                continue
            case .key:
                keyDowns.append(time)
            case .cursor(_, let id):
                cursorChanges.append(CursorChange(time: time, image: resolve(id)))
            }
        }
        for id in undeclared.sorted(by: { $0.rawValue < $1.rawValue }) {
            warnings.append("cursor \(id.rawValue) referenced but never declared; falls back to the default arrow")
        }

        self.id = manifest.id.uuid
        directory = metadata.layout.directory
        self.duration = RecordingTime(duration)
        frameSize = Size(width: Double(manifest.screen.pixelWidth), height: Double(manifest.screen.pixelHeight))
        hasMicrophone = manifest.microphone != nil
        termination = SourceTermination(wireTermination)
        self.pointer = pointer
        self.buttons = buttons
        self.keyDowns = keyDowns
        self.cursorChanges = cursorChanges
        cursorImages = declared
        loadWarnings = warnings
    }
}

public struct PointerSample: Sendable, Hashable {
    public let time: RecordingTime
    public let position: Point

    public init(time: RecordingTime, position: Point) {
        self.time = time
        self.position = position
    }
}

public struct ButtonEvent: Sendable, Hashable {
    public enum Button: Sendable, Hashable { case left, right, other }
    public enum Edge: Sendable, Hashable { case down, up }

    public let time: RecordingTime
    public let button: Button
    public let edge: Edge
    public let position: Point

    public init(time: RecordingTime, button: Button, edge: Edge, position: Point) {
        self.time = time
        self.button = button
        self.edge = edge
        self.position = position
    }
}

public struct CursorImageID: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct CursorChange: Sendable, Hashable {
    public let time: RecordingTime
    /// nil when the recorder referenced an image it never declared.
    public let image: CursorImageID?

    public init(time: RecordingTime, image: CursorImageID?) {
        self.time = time
        self.image = image
    }
}

public struct CursorImageInfo: Sendable, Hashable {
    /// Relative to `SourceRecording.directory`. The renderer loads it; Timeline never does.
    public let relativePath: String
    /// Screen pixels.
    public let hotspot: Point
    /// Screen pixels: the size to draw at 1x camera zoom.
    public let size: Size
}

public enum SourceTermination: Sendable, Hashable {
    case userStopped
    case durationReached
    case streamFailed(String)
    case recovered(String?)
}

public enum SourceLoadError: Error, Sendable, Equatable {
    case notARecording(URL)
    /// A recorder still holds the directory's lock.
    case stillRecording
    /// The recorder died before finalizing: run `osrec recover` (or `RecordingSession.recover`) first.
    case needsRecovery
    case unsupportedVersion(found: Int, supported: Int)
    case corrupt(String)
}

extension SourceLoadError {
    init(_ error: FormatError, directory: URL) {
        switch error {
        case .notARecordingDirectory(let url), .noManifest(let url):
            self = .notARecording(url)
        case .wrongFormat:
            self = .notARecording(directory)
        case .unsupportedVersion(let found, let supported):
            self = .unsupportedVersion(found: found, supported: supported)
        case .manifestUnreadable(let detail), .eventsUnreadable(let detail), .lockUnreadable(let detail):
            self = .corrupt(detail)
        case .eventLineInvalid(let lineNumber, let detail):
            self = .corrupt("events.ndjson line \(lineNumber): \(detail)")
        case .tornTailInFinalizedRecording(let byteCount):
            self = .corrupt("finalized recording has a torn event tail of \(byteCount) bytes")
        }
    }
}

extension RecordingTime {
    init(_ time: MediaTime) { self.init(microseconds: time.microseconds) }
}

extension Point {
    /// Non-finite coordinates mean a corrupt file rather than a torn one, so they fail the load.
    init(validating point: WirePoint) throws(SourceLoadError) {
        guard point.x.isFinite, point.y.isFinite else { throw .corrupt("non-finite coordinate \(point)") }
        self.init(x: point.x, y: point.y)
    }
}

extension CursorImageID {
    init(_ id: RecordingFormat.CursorImageID) { self.init(rawValue: id.rawValue) }
}

extension ButtonEvent.Button {
    init(_ button: WireButton) {
        switch button {
        case .left: self = .left
        case .right: self = .right
        case .other: self = .other
        }
    }
}

extension SourceTermination {
    init(_ termination: WireTermination) {
        switch termination {
        case .userStopped: self = .userStopped
        case .durationReached: self = .durationReached
        case .streamFailed(let message): self = .streamFailed(message)
        case .recovered(let message): self = .recovered(message)
        }
    }
}

extension Array {
    func isSorted(by inOrder: (Element, Element) -> Bool) -> Bool {
        zip(self, dropFirst()).allSatisfy(inOrder)
    }
}
