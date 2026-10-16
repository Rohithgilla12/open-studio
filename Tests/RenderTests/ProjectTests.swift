import Foundation
import Testing
@testable import Render
import Timeline

struct ProjectSpec {
    func listing(_ take: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: take.path).sorted()
    }

    var edited: Edits {
        get throws {
            var edits = Edits(
                zooms: try ZoomTrack(validating: [
                    ZoomSegment(range: TimeRange(start: .seconds(1), end: .seconds(3))!, scale: 1.5, focus: .fixed(x: 0.25, y: 0.75)),
                    ZoomSegment(range: TimeRange(start: .seconds(5), end: .seconds(9))!, scale: 2, focus: .followPointer),
                ]),
                settings: .default,
                style: Style(
                    background: .gradient(.ember), padding: 0.05, cornerRadius: 0.02, shadow: .none,
                    camera: CameraOverlay(isVisible: false, corner: .topLeft, size: 0.3, inset: 0.05, shape: .roundedRectangle, mirrored: false)),
                format: OutputFormat(size: .uhd2160, frameRate: .fps30, codec: .h264))
            edits.settings.camera.leadIn = CameraSettings.observedLeadIn
            edits.settings.cursor.smoothing = .none
            return edits
        }
    }

    @Test func openWithoutProjectFileGeneratesAutoZoomsAndWritesNothing() throws {
        // Catches: open() saving defaults into the take.
        let take = try Fixture.metadataOnlyTake()
        defer { try? FileManager.default.removeItem(at: take) }
        let before = try listing(take)
        let project = try Project.open(take)
        #expect(project.origin == .generated)
        #expect(project.edits == Edits.generated(for: project.source))
        #expect(project.edits.zooms.segments.count == 2)
        #expect(try listing(take) == before)
    }

    @Test func saveThenOpenRoundTripsEditsExactly() throws {
        let take = try Fixture.metadataOnlyTake()
        defer { try? FileManager.default.removeItem(at: take) }
        var project = try Project.open(take)
        project.edits = try edited
        try project.save()
        #expect(try listing(take) == ["cursors", "events.ndjson", "project.json", "recording.json"])
        let reopened = try Project.open(take)
        #expect(reopened.origin == .saved)
        #expect(reopened.edits == project.edits)
        #expect(reopened.timeline.zooms == project.edits.zooms)
    }

    @Test func savingTwiceWritesIdenticalBytes() throws {
        let take = try Fixture.metadataOnlyTake()
        defer { try? FileManager.default.removeItem(at: take) }
        var project = try Project.open(take)
        project.edits = try edited
        try project.save()
        let first = try Data(contentsOf: ProjectFile.url(in: take))
        try project.save()
        #expect(try Data(contentsOf: ProjectFile.url(in: take)) == first)
        #expect(try listing(take) == ["cursors", "events.ndjson", "project.json", "recording.json"])
    }

    @Test func editsRebuildTheTimeline() throws {
        let take = try Fixture.metadataOnlyTake()
        defer { try? FileManager.default.removeItem(at: take) }
        var project = try Project.open(take)
        let before = project.timeline.frame(at: .seconds(2)).camera.scale
        project.edits.zooms = .empty
        #expect(project.timeline.frame(at: .seconds(2)).camera.scale == 1)
        #expect(before > 1)
        project.regenerateZooms()
        #expect(project.timeline.zooms.segments.count == 2)
    }

    func writeProjectJSON(_ take: URL, edit: (inout [String: Any]) -> Void) throws {
        var project = try Project.open(take)
        project.edits = try edited
        try project.save()
        var object = try JSONSerialization.jsonObject(with: try Data(contentsOf: ProjectFile.url(in: take))) as! [String: Any]
        edit(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: ProjectFile.url(in: take))
    }

    @Test func overlappingZoomsInProjectFileAreRejected() throws {
        // Catches: synthesised ZoomTrack decoding that bypasses validation.
        let take = try Fixture.metadataOnlyTake()
        defer { try? FileManager.default.removeItem(at: take) }
        try writeProjectJSON(take) { object in
            var zooms = object["zooms"] as! [[String: Any]]
            zooms[1]["range"] = ["start": ["microseconds": 2_000_000], "end": ["microseconds": 4_000_000]]
            object["zooms"] = zooms
        }
        let error = #expect(throws: ProjectError.self) { try Project.open(take) }
        guard case .invalidZooms(.overlap) = try #require(error) else {
            Issue.record("expected invalidZooms(.overlap), got \(String(describing: error))")
            return
        }
    }

    @Test func zoomOutsideTheRecordingIsUnreadable() throws {
        let take = try Fixture.metadataOnlyTake()
        defer { try? FileManager.default.removeItem(at: take) }
        try writeProjectJSON(take) { object in
            var zooms = object["zooms"] as! [[String: Any]]
            zooms[1]["range"] = ["start": ["microseconds": 5_000_000], "end": ["microseconds": 13_000_000]]
            object["zooms"] = zooms
        }
        let error = #expect(throws: ProjectError.self) { try Project.open(take) }
        guard case .projectUnreadable(let detail) = try #require(error) else {
            Issue.record("expected projectUnreadable")
            return
        }
        #expect(detail.contains("outside the recording"))
    }

    @Test func projectFileMissingANewerSettingStillOpens() throws {
        let take = try Fixture.metadataOnlyTake()
        defer { try? FileManager.default.removeItem(at: take) }
        try writeProjectJSON(take) { object in
            var settings = object["settings"] as! [String: Any]
            var cursor = settings["cursor"] as! [String: Any]
            cursor.removeValue(forKey: "pressedScale")
            cursor.removeValue(forKey: "smoothing")
            settings["cursor"] = cursor
            settings.removeValue(forKey: "autoZoom")
            object["settings"] = settings
        }
        let project = try Project.open(take)
        #expect(project.origin == .saved)
        #expect(project.edits.settings.cursor.pressedScale == CursorSettings().pressedScale)
        #expect(project.edits.settings.cursor.smoothing == CursorSettings().smoothing)
        #expect(project.edits.settings.autoZoom == AutoZoomSettings())
        #expect(project.edits.settings.camera.leadIn == CameraSettings.observedLeadIn)
    }

    @Test func projectFileFromBeforeTheCameraOpensWithTheDefaultOverlay() throws {
        let take = try Fixture.metadataOnlyTake()
        defer { try? FileManager.default.removeItem(at: take) }
        try writeProjectJSON(take) { object in
            var style = object["style"] as! [String: Any]
            style.removeValue(forKey: "camera")
            object["style"] = style
        }
        let project = try Project.open(take)
        #expect(project.origin == .saved)
        #expect(project.edits.style.camera == .default)
    }

    @Test func cameraSizeOutOfRangeIsUnreadable() throws {
        let take = try Fixture.metadataOnlyTake()
        defer { try? FileManager.default.removeItem(at: take) }
        try writeProjectJSON(take) { object in
            var style = object["style"] as! [String: Any]
            style["camera"] = ["size": 0.9]
            object["style"] = style
        }
        let error = #expect(throws: ProjectError.self) { try Project.open(take) }
        guard case .projectUnreadable(let detail) = try #require(error) else {
            Issue.record("expected projectUnreadable")
            return
        }
        #expect(detail.contains("camera size"))
    }

    @Test func newerVersionIsRefusedAndNeverRewritten() throws {
        let take = try Fixture.metadataOnlyTake()
        defer { try? FileManager.default.removeItem(at: take) }
        try writeProjectJSON(take) { object in
            object["version"] = 2
            object["futureKey"] = "kept"
        }
        let bytes = try Data(contentsOf: ProjectFile.url(in: take))
        #expect(throws: ProjectError.projectFromNewerVersion(found: 2, supported: 1)) { try Project.open(take) }
        #expect(try Data(contentsOf: ProjectFile.url(in: take)) == bytes)
    }

    @Test func wrongFormatIdentifierIsUnreadable() throws {
        let take = try Fixture.metadataOnlyTake()
        defer { try? FileManager.default.removeItem(at: take) }
        try writeProjectJSON(take) { $0["format"] = "something.else" }
        let error = #expect(throws: ProjectError.self) { try Project.open(take) }
        guard case .projectUnreadable = try #require(error) else {
            Issue.record("expected projectUnreadable")
            return
        }
    }

    @Test func styleOutOfRangeIsUnreadable() throws {
        let take = try Fixture.metadataOnlyTake()
        defer { try? FileManager.default.removeItem(at: take) }
        try writeProjectJSON(take) { object in
            var style = object["style"] as! [String: Any]
            style["padding"] = 0.6
            object["style"] = style
        }
        let error = #expect(throws: ProjectError.self) { try Project.open(take) }
        guard case .projectUnreadable(let detail) = try #require(error) else {
            Issue.record("expected projectUnreadable")
            return
        }
        #expect(detail.contains("padding"))
    }

    @Test func projectFileFromAnotherTakeIsIgnored() throws {
        // Catches: a project.json copied between takes applying the wrong zooms, or being
        // validated against this take and refusing to open it.
        let take = try Fixture.metadataOnlyTake()
        defer { try? FileManager.default.removeItem(at: take) }
        try writeProjectJSON(take) { object in
            object["recordingID"] = UUID().uuidString
            var zooms = object["zooms"] as! [[String: Any]]
            zooms[1]["range"] = ["start": ["microseconds": 5_000_000], "end": ["microseconds": 30_000_000]]
            object["zooms"] = zooms
        }
        let bytes = try Data(contentsOf: ProjectFile.url(in: take))
        let project = try Project.open(take)
        #expect(project.origin == .generated)
        #expect(project.edits == Edits.generated(for: project.source))
        #expect(try Data(contentsOf: ProjectFile.url(in: take)) == bytes)
    }

    @Test func backgroundEncodesWithAReadableDiscriminator() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let solid = String(decoding: try encoder.encode(Background.solid(RGBColor(red: 1, green: 0, blue: 0))), as: UTF8.self)
        #expect(solid == #"{"color":{"blue":0,"green":0,"red":1},"type":"solid"}"#)
        let image = String(decoding: try encoder.encode(Background.image(ProjectAsset(fileName: "bg.png"))), as: UTF8.self)
        #expect(image == #"{"fileName":"bg.png","type":"image"}"#)
        for background in [Background.gradient(.mint), .solid(RGBColor(red: 0.5, green: 0.25, blue: 0)), .image(ProjectAsset(fileName: "x.jpg"))] {
            #expect(try JSONDecoder().decode(Background.self, from: try encoder.encode(background)) == background)
        }
    }
}
