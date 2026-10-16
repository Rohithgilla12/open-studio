import Foundation
@testable import RecordingFormat
@testable import Timeline

/// The committed fixture under `Fixtures/recordings/`, and the generator that wrote it.
///
/// `loadsCommittedFixture` checks the committed bytes against `generate()`, so the fixture and the
/// generator cannot drift apart. To change the fixture, edit `generate()` and run the tests with
/// `OPEN_STUDIO_REGENERATE_FIXTURES=1`.
enum Fixture {
    static let fiveClicks = "20261013-five-clicks.osrec"

    static func directory(_ name: String, file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/recordings/\(name)", directoryHint: .isDirectory)
    }

    static func timeline(_ name: String = fiveClicks, settings: TimelineSettings = .default) throws -> Timeline {
        let source = try SourceRecording.load(from: directory(name))
        return Timeline(source: source, zooms: AutoZoom.track(for: source, settings: settings.autoZoom), settings: settings)
    }

    struct Generated {
        var manifest: Data
        var events: Data
        var cursors: [String: Data]
    }

    static let frame = WireSize(width: 1920, height: 1080)
    static let duration = MediaTime(microseconds: 12_000_000)
    static let arrow = CursorImageDeclaration(
        id: CursorImageID(png: png, hotspot: WirePoint(x: 4, y: 2)),
        hotspot: WirePoint(x: 4, y: 2), size: WireSize(width: 32, height: 32))
    static let iBeam = CursorImageDeclaration(
        id: CursorImageID(png: png, hotspot: WirePoint(x: 8, y: 16)),
        hotspot: WirePoint(x: 8, y: 16), size: WireSize(width: 16, height: 32))

    /// Clicks (down then up 90 ms later) at these seconds. With the default auto-zoom settings the
    /// first stands alone, the next three merge, and the last falls in the ignored final second, so
    /// the fixture yields two segments: [0.7 s, 3.59 s) and [6.2 s, 11.2 s).
    static let clickSeconds: [Double] = [1.0, 6.5, 9.0, 9.4, 11.5]
    /// Keys at 6.0, 6.2, 6.4, and 6.6 s with the pointer at rest: a typing burst.
    static let keySeconds: [Double] = [6.0, 6.2, 6.4, 6.6]

    /// 60 Hz pointer path: sinusoid, held still from 5.8 s to 7.2 s around the typing burst, with one
    /// warp glitch at 4.0 s that the shake filter should drop.
    static func pointer(at seconds: Double) -> WirePoint {
        let t = (5.8...7.2).contains(seconds) ? 5.8 : seconds
        return WirePoint(
            x: (960 + 600 * sin(0.7 * t)).rounded(.toNearestOrEven),
            y: (540 + 300 * cos(0.5 * t)).rounded(.toNearestOrEven))
    }

    static func generate() throws -> Generated {
        var events: [WireEvent] = [.cursorImage(arrow), .cursorImage(iBeam)]
        events.append(.state(t: .zero, position: pointer(at: 0), buttons: [], cursor: arrow.id))
        var timed: [(MediaTime, WireEvent)] = []
        for frameIndex in 1..<(12 * 60) {
            let seconds = Double(frameIndex) / 60
            let t = MediaTime(microseconds: Int64(seconds * 1_000_000))
            let position = frameIndex == 240 ? WirePoint(x: 1900, y: 1060) : pointer(at: seconds)
            timed.append((t, .move(t: t, position: position)))
        }
        for click in clickSeconds {
            let down = MediaTime(microseconds: Int64(click * 1_000_000))
            let up = MediaTime(microseconds: down.microseconds + 90_000)
            let position = pointer(at: click)
            timed.append((down, .down(t: down, button: .left, position: position, clickCount: 1)))
            timed.append((up, .up(t: up, button: .left, position: position)))
        }
        for key in keySeconds {
            let t = MediaTime(microseconds: Int64(key * 1_000_000))
            timed.append((t, .key(t: t, stroke: KeyStroke(modifiers: [], pressedKeyCode: 0))))
        }
        let toIBeam = MediaTime(microseconds: 5_900_000)
        let toArrow = MediaTime(microseconds: 7_100_000)
        timed.append((toIBeam, .cursor(t: toIBeam, id: iBeam.id)))
        timed.append((toArrow, .cursor(t: toArrow, id: arrow.id)))
        timed.sort { $0.0 < $1.0 }
        events.append(contentsOf: timed.map(\.1))

        let manifest = WireManifest(
            id: RecordingID(UUID(uuidString: "0B6F1A2C-5D3E-4F70-8A91-B2C3D4E5F601")!),
            createdAt: try Date("2026-10-13T09:00:00.000Z", strategy: .iso8601),
            recorder: WireRecorderInfo(name: "fixture", version: "0.1.0", osVersion: "27.0"),
            clock: WireClock(originHostTimeNanos: 100_000_000_000),
            display: WireDisplay(
                displayID: 1, name: "Fixture Display",
                pointFrame: WireRect(x: 0, y: 0, width: 1920, height: 1080), refreshRate: 60),
            screen: WireScreen(pixelWidth: 1920, pixelHeight: 1080, codec: .hevc, maxFrameRate: 60),
            microphone: nil,
            status: .finalized(duration: duration, termination: .userStopped))
        let lines = try events.reduce(into: Data()) { $0.append(try EventLog.encodeLine($1)) }
        return Generated(
            manifest: try manifest.encoded(), events: lines,
            cursors: [RecordingLayout.cursorImagePath(arrow.id): png, RecordingLayout.cursorImagePath(iBeam.id): png])
    }

    static func write(_ generated: Generated, to directory: URL) throws {
        let layout = RecordingLayout(directory: directory)
        try FileManager.default.createDirectory(at: layout.cursors, withIntermediateDirectories: true)
        try generated.manifest.write(to: layout.manifest)
        try generated.events.write(to: layout.events)
        for (path, bytes) in generated.cursors {
            try bytes.write(to: directory.appending(path: path, directoryHint: .notDirectory))
        }
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "TimelineTests-\(UUID().uuidString).osrec", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func editJSON(_ data: Data, _ edit: (inout [String: Any]) -> Void) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// A 2 × 2 RGBA PNG. Timeline never decodes it; the renderer will.
    static let png = Data([
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xb6, 0x0d,
        0x24, 0x00, 0x00, 0x00, 0x11, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x60, 0x60, 0x60, 0xf8,
        0x0f, 0x02, 0x0c, 0x30, 0x06, 0x00, 0x4a, 0xc7, 0x09, 0xf7, 0x40, 0xed, 0x0b, 0x31, 0x00, 0x00,
        0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    ])
}

/// Synthetic metadata for tests that need a `SourceRecording` without a directory.
enum Synthetic {
    static func source(
        duration: Double, frame: Size = Size(width: 1920, height: 1080), area: WireRect? = nil,
        pointer: [(Double, Double, Double)] = [], clicks: [Double] = [], keys: [Double] = [],
        cursorChanges: [(Double, RecordingFormat.CursorImageID?)] = [],
        declarations: [CursorImageDeclaration] = []
    ) throws -> SourceRecording {
        func time(_ s: Double) -> MediaTime { MediaTime(microseconds: Int64((s * 1_000_000).rounded())) }
        var events: [WireEvent] = declarations.map(WireEvent.cursorImage)
        events.append(contentsOf: pointer.map { .move(t: time($0.0), position: WirePoint(x: $0.1, y: $0.2)) })
        for click in clicks {
            let position = pointer.last(where: { $0.0 <= click }).map { WirePoint(x: $0.1, y: $0.2) }
                ?? WirePoint(x: 0, y: 0)
            events.append(.down(t: time(click), button: .left, position: position, clickCount: 1))
            events.append(.up(t: time(click + 0.08), button: .left, position: position))
        }
        events.append(contentsOf: keys.map { .key(t: time($0), stroke: KeyStroke(modifiers: [], pressedKeyCode: 0)) })
        for (at, id) in cursorChanges {
            if let id { events.append(.cursor(t: time(at), id: id)) }
        }
        let manifest = WireManifest(
            id: RecordingID(UUID()), createdAt: Date(timeIntervalSince1970: 0),
            recorder: WireRecorderInfo(name: "synthetic", version: "0", osVersion: "0"),
            clock: WireClock(originHostTimeNanos: 0),
            display: WireDisplay(
                displayID: 1, name: "Synthetic", pointFrame: WireRect(x: 0, y: 0, width: frame.width, height: frame.height),
                refreshRate: 60),
            screen: WireScreen(pixelWidth: Int(frame.width), pixelHeight: Int(frame.height), codec: .hevc, maxFrameRate: 60),
            area: area,
            microphone: nil,
            status: .finalized(duration: time(duration), termination: .userStopped))
        let log = try EventLog.decode(try events.reduce(into: Data()) { $0.append(try EventLog.encodeLine($1)) })
        let metadata = RecordingMetadata(
            layout: RecordingLayout(directory: URL(fileURLWithPath: "/synthetic.osrec")),
            manifest: manifest, events: log, recorderAlive: false)
        return try SourceRecording(metadata)
    }
}
