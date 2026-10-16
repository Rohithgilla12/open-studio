import Foundation
import Testing
@testable import Render
import Timeline

struct AreaCanvasSpec {
    @Test func aWideAreaKeepsThePresetWidth() {
        #expect(OutputFormat.hd1080.canvasSize(forArea: Size(width: 800, height: 400), padding: 0.08) == PixelSize(width: 1920, height: 960))
        #expect(OutputFormat.uhd2160.canvasSize(forArea: Size(width: 2560, height: 1080), padding: 0.08) == PixelSize(width: 3840, height: 1620))
    }

    @Test func aTallAreaKeepsThePresetHeight() {
        #expect(OutputFormat.hd1080.canvasSize(forArea: Size(width: 600, height: 1200), padding: 0.08) == PixelSize(width: 540, height: 1080))
    }

    @Test func aSixteenByNineAreaFillsTheBox() {
        #expect(OutputFormat.hd1080.canvasSize(forArea: Size(width: 2560, height: 1440), padding: 0.08) == PixelSize(width: 1920, height: 1080))
    }

    @Test func nativeGrowsTheAreaByThePadding() {
        // Catches native sized from the whole frame: an 800 x 400 area at padding 0.1 is 1000 x 500.
        #expect(OutputFormat.native.canvasSize(forArea: Size(width: 800, height: 400), padding: 0.1) == PixelSize(width: 1000, height: 500))
    }

    @Test func theContentTakesTheAreasAspect() {
        let area = Size(width: 800, height: 400)
        let style = Style(background: .solid(RGBColor(red: 0, green: 0, blue: 1)), padding: 0.08, cornerRadius: 0.05, shadow: .none)
        let canvas = OutputFormat.hd1080.canvasSize(forArea: area, padding: style.padding)
        let layout = CanvasLayout(style: style, canvas: canvas, source: area)
        #expect(abs(layout.content.size.width / layout.content.size.height - 2) < 0.01, "\(layout.content)")
    }

    @Test func projectsSizeEntireScreenTakesAsBefore() throws {
        let take = try Fixture.metadataOnlyTake()
        defer { try? FileManager.default.removeItem(at: take) }
        let project = try Project.open(take)
        #expect(project.source.area == nil)
        #expect(project.canvasSize(for: .hd1080) == PixelSize(width: 1920, height: 1080))
        #expect(project.canvasSize(for: .native) == OutputFormat.native.canvasSize(for: project.source.frameSize, padding: project.edits.style.padding))
    }

    @Test func projectsSizeAreaTakesFromTheArea() throws {
        let take = try Fixture.metadataOnlyTake()
        defer { try? FileManager.default.removeItem(at: take) }
        try Fixture.setArea([400, 440, 800, 400], in: take)
        let project = try Project.open(take)
        #expect(project.canvasSize(for: .hd1080) == PixelSize(width: 1920, height: 960))
    }
}

struct AreaPixelSpec {
    func isRed(_ p: (red: Int, green: Int, blue: Int)) -> Bool { p.red > 200 && p.green < 60 && p.blue < 60 }
    func isGreen(_ p: (red: Int, green: Int, blue: Int)) -> Bool { p.green > 200 && p.red < 60 && p.blue < 60 }
    func isBlue(_ p: (red: Int, green: Int, blue: Int)) -> Bool { p.blue > 200 && p.red < 60 && p.green < 60 }

    @Test func anAreaTakeRendersTheAreaAndNothingElse() async throws {
        // The 1920 x 1080 source is red above y = 540 and green below. The area (400, 440, 800, 400)
        // straddles the edge a quarter of the way down, so the content must be red for its top
        // quarter and green below. Rendering the whole frame would put the edge at the middle and
        // leave the content narrower; ignoring the area's origin would show only red or only green.
        let take = try await Fixture.take(top: (255, 0, 0), bottom: (0, 255, 0))
        defer { try? FileManager.default.removeItem(at: take) }
        try Fixture.setArea([400, 440, 800, 400], in: take)
        var project = try Project.open(take)
        project.edits.zooms = .empty
        project.edits.style = PixelSpec.blue
        project.edits.format = .hd1080
        // Canvas 1920 x 960; inset 0.08 * 960 = 76.8; fit min(1766.4 / 800, 806.4 / 400) = 2.016;
        // content 1613 x 806 at (153, 77). The colour edge is 100 source px down: 77 + 201.6.
        let pixels = Pixels(try await Still.cgImage(project, at: .seconds(1)))
        #expect(pixels.width == 1920 && pixels.height == 960)
        #expect(isBlue(pixels[10, 10]), "canvas corner \(pixels[10, 10])")
        #expect(isRed(pixels[960, 77 + 100]), "above the edge \(pixels[960, 177])")
        #expect(isGreen(pixels[960, 77 + 300]), "below the edge \(pixels[960, 377])")
        #expect(isGreen(pixels[960, 77 + 403]), "content middle \(pixels[960, 480])")
        #expect(isGreen(pixels[153 + 5, 77 + 600]), "left edge inside \(pixels[158, 677])")
        #expect(isBlue(pixels[153 - 3, 77 + 600]), "left edge outside \(pixels[150, 677])")
        #expect(isBlue(pixels[960, 77 + 806 + 3]), "bottom edge outside \(pixels[960, 886])")
    }
}
