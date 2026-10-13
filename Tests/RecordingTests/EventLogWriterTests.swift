import CoreGraphics
import Foundation
import Testing
@testable import Recording
@testable import RecordingFormat

struct EventLogWriterTests {
    let origin = HostTime(nanoseconds: 1_000_000_000)
    let mapping = DisplayMapping(
        displayPointFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), pixelSize: CGSize(width: 3024, height: 1964))
    let arrow = CursorImage(png: Data("arrow".utf8), hotspot: WirePoint(x: 8, y: 6), size: WireSize(width: 34, height: 46))
    let ibeam = CursorImage(png: Data("ibeam".utf8), hotspot: WirePoint(x: 9, y: 18), size: WireSize(width: 18, height: 36))

    func at(_ milliseconds: Int64) -> HostTime { origin + .milliseconds(milliseconds) }

    func makeWriter() throws -> (EventLogWriter, RecordingLayout, InputBuffer<CapturedInput>, InputBuffer<CapturedCursor>) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "RecordingTests-\(UUID().uuidString).osrec", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let layout = RecordingLayout(directory: directory)
        let tap = InputBuffer<CapturedInput>()
        let cursors = InputBuffer<CapturedCursor>()
        let writer = EventLogWriter(
            layout: layout, tapBuffer: tap, cursorBuffer: cursors, conversion: EventConversion(origin: origin, mapping: mapping))
        return (writer, layout, tap, cursors)
    }

    @Test func snapshotFirstThenMergedByTimeWithPreOriginEventsDropped() async throws {
        let (writer, layout, tap, cursors) = try makeWriter()
        tap.append(CapturedInput(time: at(-50), location: CGPoint(x: 1, y: 1), kind: .move))
        tap.append(CapturedInput(time: at(10), location: CGPoint(x: 10, y: 20), kind: .move))
        tap.append(CapturedInput(time: at(30), location: CGPoint(x: 11, y: 21), kind: .down(.left, clickCount: 1)))
        cursors.append(CapturedCursor(time: at(-10), image: ibeam))
        cursors.append(CapturedCursor(time: at(20), image: ibeam))

        try await writer.begin(snapshot: CapturedSnapshot(location: CGPoint(x: 5, y: 5), buttons: [], cursor: arrow))
        try await writer.drain()
        let written = try await writer.finish()
        let twice = try await writer.finish()

        let log = try EventLog.decode(Data(contentsOf: layout.events))
        let arrowID = CursorImageID(png: arrow.png, hotspot: arrow.hotspot)
        let ibeamID = CursorImageID(png: ibeam.png, hotspot: ibeam.hotspot)
        #expect(log.events == [
            .cursorImage(CursorImageDeclaration(id: arrowID, hotspot: arrow.hotspot, size: arrow.size)),
            .state(t: .zero, position: WirePoint(x: 10, y: 10), buttons: [], cursor: arrowID),
            .move(t: MediaTime(microseconds: 10_000), position: WirePoint(x: 20, y: 40)),
            .cursorImage(CursorImageDeclaration(id: ibeamID, hotspot: ibeam.hotspot, size: ibeam.size)),
            .cursor(t: MediaTime(microseconds: 20_000), id: ibeamID),
            .down(t: MediaTime(microseconds: 30_000), button: .left, position: WirePoint(x: 22, y: 42), clickCount: 1),
        ])
        #expect(log.tornTailByteCount == 0)
        #expect(written == 6)
        #expect(twice == 6)
        #expect(writer.eventsWritten == 6)
        #expect(FileManager.default.fileExists(atPath: layout.cursorImage(arrowID).path))
        #expect(FileManager.default.fileExists(atPath: layout.cursorImage(ibeamID).path))
        #expect(tap.isEmpty)
    }

    @Test func aCursorSeenTwiceIsDeclaredOnce() async throws {
        let (writer, layout, _, cursors) = try makeWriter()
        try await writer.begin(snapshot: CapturedSnapshot(location: .zero, buttons: [], cursor: nil))
        cursors.append(CapturedCursor(time: at(1), image: ibeam))
        try await writer.drain()
        cursors.append(CapturedCursor(time: at(2), image: arrow))
        cursors.append(CapturedCursor(time: at(3), image: ibeam))
        try await writer.drain()
        _ = try await writer.finish()

        let kinds = try EventLog.decode(Data(contentsOf: layout.events)).events.map(\.kind)
        #expect(kinds == [.state, .cursorImage, .cursor, .cursorImage, .cursor, .cursor])
    }
}
