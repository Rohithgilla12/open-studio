import Foundation
import Testing
@testable import Render
import Timeline

struct CutsProjectSpec {
    static func cut(_ start: Double, _ end: Double, id: UUID = UUID()) -> Cut {
        Cut(id: id, range: TimeRange(start: .seconds(start), end: .seconds(end))!)
    }

    func json(_ take: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: ProjectFile.url(in: take))) as! [String: Any]
    }

    /// Catches a cuts-free save moving to version 2 or gaining a key, which would stop today's
    /// build opening it.
    @Test func noCutsWritesVersionOneWithoutACutsKey() throws {
        let take = try Fixture.metadataOnlyTake()
        defer { try? FileManager.default.removeItem(at: take) }
        try Project.open(take).save()
        let object = try json(take)
        #expect(object["version"] as? Int == 1)
        #expect(Set(object.keys) == ["audio", "format", "output", "recordingID", "settings", "style", "version", "zooms"])
        #expect(try Project.open(take).edits.cuts == .none)
    }

    @Test func cutsWriteVersionTwoAndRoundTripExactly() throws {
        let take = try Fixture.metadataOnlyTake()
        defer { try? FileManager.default.removeItem(at: take) }
        var project = try Project.open(take)
        let cuts = try Cuts(validating: [Self.cut(0, 1.5), Self.cut(4, 6), Self.cut(11, 12)], within: project.source.duration)
        project.edits.cuts = cuts
        #expect(project.timeline.map.duration == .seconds(7.5))
        try project.save()
        let object = try json(take)
        #expect(object["version"] as? Int == 2)
        let written = object["cuts"] as? [[String: Any]]
        #expect(written?.count == 3)
        #expect((written?[1]["range"] as? [String: Any])?["start"] as? [String: Int] == ["microseconds": 4_000_000])
        #expect((written?[1]["id"] as? String) == cuts.cuts[1].id.uuidString)

        let reopened = try Project.open(take)
        #expect(reopened.origin == .saved)
        #expect(reopened.edits == project.edits)
        #expect(reopened.timeline.cuts == cuts)
        #expect(reopened.timeline.map == project.timeline.map)

        var restored = reopened
        restored.edits.cuts = .none
        try restored.save()
        #expect(try json(take)["version"] as? Int == 1, "restoring every cut drops the file back to version 1")
    }

    @Test func aZoomInsideACutIsValid() throws {
        let take = try Fixture.metadataOnlyTake()
        defer { try? FileManager.default.removeItem(at: take) }
        var project = try Project.open(take)
        project.edits.zooms = try ZoomTrack(validating: [
            ZoomSegment(range: TimeRange(start: .seconds(4.5), end: .seconds(5.5))!, scale: 2, focus: .followPointer),
        ])
        project.edits.cuts = try Cuts(validating: [Self.cut(4, 6)], within: project.source.duration)
        try project.save()
        #expect(try Project.open(take).edits == project.edits)
    }

    @Test(arguments: [
        ("overlapping", [cut(1, 3), cut(2, 4)], CutsError.overlap(UUID(), UUID())),
        ("outside", [cut(11, 13)], .outsideRecording(UUID())),
        ("sliver", [cut(1, 2), cut(2.1, 3)], .keptTooShort(after: UUID())),
        ("nothing kept", [cut(0, 12)], .nothingKept),
        ("duplicate id", [cut(1, 2, id: UUID(uuidString: "0B6F1A2C-5D3E-4F70-8A91-B2C3D4E5F601")!), cut(5, 6, id: UUID(uuidString: "0B6F1A2C-5D3E-4F70-8A91-B2C3D4E5F601")!)], .duplicateID(UUID())),
    ])
    func invalidCutsAreRefusedNotRepaired(name: String, cuts: [Cut], expected: CutsError) throws {
        let take = try Fixture.metadataOnlyTake()
        defer { try? FileManager.default.removeItem(at: take) }
        try Project.open(take).save()
        try AudioLevelsProjectSpec.editProjectFile(in: take) { object in
            object["version"] = 2
            object["cuts"] = cuts.map { cut in
                ["id": cut.id.uuidString, "range": [
                    "start": ["microseconds": cut.range.start.microseconds], "end": ["microseconds": cut.range.end.microseconds],
                ]]
            }
        }
        let bytes = try Data(contentsOf: ProjectFile.url(in: take))
        let error = #expect(throws: ProjectError.self) { try Project.open(take) }
        guard case .invalidCuts(let found) = try #require(error) else {
            Issue.record("\(name): expected invalidCuts, got \(String(describing: error))")
            return
        }
        switch (found, expected) {
        case (.overlap, .overlap), (.outsideRecording, .outsideRecording), (.keptTooShort, .keptTooShort),
            (.nothingKept, .nothingKept), (.duplicateID, .duplicateID):
            break
        default:
            Issue.record("\(name): expected \(expected), got \(found)")
        }
        #expect(try Data(contentsOf: ProjectFile.url(in: take)) == bytes, "never rewritten")
    }
}
