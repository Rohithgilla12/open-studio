import Foundation
import Testing
@testable import RecordingFormat

struct LayoutTests {
    @Test func directoryNameIsTheLocalStartTime() throws {
        #expect(RecordingLayout.directoryName(for: Fixtures.createdAt, in: TimeZone(identifier: "UTC")!)
            == "20261013-062233.osrec")
        #expect(RecordingLayout.directoryName(for: Fixtures.createdAt, in: TimeZone(identifier: "Asia/Kuala_Lumpur")!)
            == "20261013-142233.osrec")
    }

    @Test func cursorImagesLiveUnderTheirID() throws {
        let layout = RecordingLayout(directory: URL(fileURLWithPath: "/tmp/a.osrec", isDirectory: true))

        #expect(RecordingLayout.cursorImagePath(Fixtures.arrowID) == "cursors/9f2c4e1a7b3d5c60.png")
        #expect(layout.cursorImage(Fixtures.arrowID).path == "/tmp/a.osrec/cursors/9f2c4e1a7b3d5c60.png")
    }

    @Test func theCameraMovieSitsBesideTheScreen() {
        let layout = RecordingLayout(directory: URL(fileURLWithPath: "/tmp/a.osrec", isDirectory: true))

        #expect(layout.camera.path == "/tmp/a.osrec/camera.mov")
        #expect(layout.systemAudio.path == "/tmp/a.osrec/system-audio.mov")
    }

    @Test(arguments: ["../recording.js", "9F2C4E1A7B3D5C60", "9f2c4e1a7b3d5c6", "9f2c4e1a7b3d5c600", "9f2c4e1a7b3d5c6g"])
    func cursorIDsAreSixteenLowercaseHexDigits(raw: String) {
        #expect(CursorImageID(rawValue: raw) == nil)
    }

    @Test func storingACursorIsContentAddressedAndIdempotent() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let layout = RecordingLayout(directory: directory)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        let size = WireSize(width: 34, height: 46)

        let first = try layout.storeCursorImage(png: png, hotspot: WirePoint(x: 8, y: 6), size: size)
        let again = try layout.storeCursorImage(png: png, hotspot: WirePoint(x: 8, y: 6), size: size)
        let otherHotspot = try layout.storeCursorImage(png: png, hotspot: WirePoint(x: 9, y: 6), size: size)

        #expect(first == again)
        #expect(first.id != otherHotspot.id)
        #expect(CursorImageID(rawValue: first.id.rawValue) == first.id)
        #expect(try Data(contentsOf: layout.cursorImage(first.id)) == png)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: layout.cursors.path))
            == ["\(first.id).png", "\(otherHotspot.id).png"])
    }
}
