import Foundation
import Testing
@testable import Render
import Timeline

struct BackgroundPresetSpec {
    @Test func everyPresetRoundTripsThroughProjectJSON() throws {
        let take = try Fixture.metadataOnlyTake()
        defer { try? FileManager.default.removeItem(at: take) }
        var project = try Project.open(take)
        for preset in Background.presets {
            project.edits.style.background = preset.background
            try project.save()
            let reopened = try Project.open(take)
            #expect(reopened.origin == .saved)
            #expect(reopened.edits.style.background == preset.background, "\(preset.name)")
        }
    }

    @Test func presetsAreDistinctGeneratedAndValid() {
        let presets = Background.presets
        #expect(Set(presets.map(\.name)).count == presets.count)
        #expect(Set(presets.map(\.background)).count == presets.count)
        #expect(presets.contains { if case .solid = $0.background { true } else { false } })
        #expect(presets.contains { if case .gradient = $0.background { true } else { false } })
        for preset in presets {
            if case .image = preset.background { Issue.record("\(preset.name) ships an image") }
            #expect(preset.background.problem == nil, "\(preset.name): \(preset.background.problem ?? "")")
        }
        #expect(presets.first?.background == Style.default.background, "the default background leads the row")
    }

    @Test func aColourOutsideTheUnitRangeIsUnreadable() throws {
        let take = try Fixture.metadataOnlyTake()
        defer { try? FileManager.default.removeItem(at: take) }
        var project = try Project.open(take)
        project.edits.style.background = .solid(RGBColor(red: 0.2, green: 0.4, blue: 0.6))
        try project.save()
        let url = ProjectFile.url(in: take)
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var style = object["style"] as! [String: Any]
        style["background"] = ["type": "solid", "color": ["red": 1.5, "green": 0.4, "blue": 0.6]]
        object["style"] = style
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let error = #expect(throws: ProjectError.self) { try Project.open(take) }
        guard case .projectUnreadable(let detail) = try #require(error) else {
            Issue.record("expected projectUnreadable")
            return
        }
        #expect(detail.contains("background colour"), "\(detail)")
    }

    @Test func aGradientEndOutsideTheUnitRangeIsAProblem() {
        let gradient = Gradient(from: RGBColor(red: 0, green: 0, blue: 0), to: RGBColor(red: 0, green: -0.1, blue: 0), angle: 0)
        #expect(Background.gradient(gradient).problem != nil)
        #expect(Background.gradient(Gradient(from: gradient.from, to: gradient.from, angle: .infinity)).problem != nil)
        #expect(Background.image(ProjectAsset(fileName: "../escape.png")).problem != nil)
    }
}
