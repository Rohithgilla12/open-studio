import Foundation
@testable import RecordingFormat

enum Fixtures {
    static let createdAt = try! Date("2026-10-13T06:22:33.412Z", strategy: .iso8601)

    static func manifest(status: ManifestStatus = .recording, warnings: [ManifestWarning] = []) -> WireManifest {
        WireManifest(
            id: RecordingID(UUID(uuidString: "8E0C2B9A-6F1D-4C55-9C3E-2D7A9B4F1E10")!),
            createdAt: createdAt,
            recorder: WireRecorderInfo(name: "osrec", version: "0.1.0", osVersion: "27.0"),
            clock: WireClock(originHostTimeNanos: 734_918_273_645_120),
            display: WireDisplay(
                displayID: 1, name: "Built-in Retina Display",
                pointFrame: WireRect(x: 0, y: 0, width: 1512, height: 982), refreshRate: 120),
            screen: WireScreen(pixelWidth: 3024, pixelHeight: 1964, codec: .hevc, maxFrameRate: 60),
            microphone: WireMicrophone(deviceName: "MacBook Pro Microphone", sampleRate: 48_000, channelCount: 1),
            warnings: warnings,
            status: status)
    }

    static let arrowID = CursorImageID(rawValue: "9f2c4e1a7b3d5c60")!

    static let everyKind: [WireEvent] = [
        .cursorImage(CursorImageDeclaration(
            id: arrowID, hotspot: WirePoint(x: 8, y: 6), size: WireSize(width: 34, height: 46))),
        .state(t: .zero, position: WirePoint(x: 1624.5, y: 866), buttons: [.left, .right], cursor: arrowID),
        .move(t: MediaTime(microseconds: 8215), position: WirePoint(x: 1626, y: 865)),
        .down(t: MediaTime(microseconds: 1_203_110), button: .left, position: WirePoint(x: 2210, y: 402.5), clickCount: 2),
        .up(t: MediaTime(microseconds: 1_291_870), button: .other, position: WirePoint(x: 2210, y: 402.5)),
        .scroll(t: MediaTime(microseconds: 4_120_775), position: WirePoint(x: 1012, y: 1388), dx: 0, dy: -6.5),
        .key(t: MediaTime(microseconds: 3_102_236), stroke: KeyStroke(modifiers: [.command, .shift], pressedKeyCode: 1)),
        .cursor(t: MediaTime(microseconds: 2_004_332), id: CursorImageID(rawValue: "41d07be8c2a9f315")!),
    ]

    static func log(_ events: [WireEvent]) throws -> Data {
        try events.reduce(into: Data()) { $0.append(try EventLog.encodeLine($1)) }
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "RecordingFormatTests-\(UUID().uuidString).osrec", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func editJSON(_ data: Data, _ edit: (inout [String: Any]) -> Void) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }
}
