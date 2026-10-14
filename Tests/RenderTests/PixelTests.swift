import Foundation
import Testing
@testable import Render
import Timeline

/// GPU tests through the real composition: Still goes through AVAssetImageGenerator, the
/// compositor, and the scene exactly as an export does.
struct PixelSpec {
    static let blue = Style(
        background: .solid(RGBColor(red: 0, green: 0, blue: 1)), padding: 0.08, cornerRadius: 0.05, shadow: .none)

    func isRed(_ p: (red: Int, green: Int, blue: Int)) -> Bool { p.red > 200 && p.green < 60 && p.blue < 60 }
    func isBlue(_ p: (red: Int, green: Int, blue: Int)) -> Bool { p.blue > 200 && p.red < 60 && p.green < 60 }

    @Test func backgroundPaddingAndContentPixelsMatchGeometry() async throws {
        // Catches a flipped y, a wrong inset, or a missing mask.
        let take = try await Fixture.take(color: (255, 0, 0))
        defer { try? FileManager.default.removeItem(at: take) }
        var project = try Project.open(take)
        project.edits.zooms = .empty
        project.edits.style = Self.blue
        project.edits.format = .hd1080
        // Content at hd1080 with padding 0.08 for a 1920 x 1080 source: k = 907.2 / 1080 = 0.84,
        // content 1613 x 907 at (153, 86); corner radius 54.
        let pixels = Pixels(try await Still.cgImage(project, at: .seconds(1)))
        #expect(pixels.width == 1920 && pixels.height == 1080)
        #expect(isBlue(pixels[10, 10]), "canvas corner \(pixels[10, 10])")
        #expect(isRed(pixels[960, 540]), "content centre \(pixels[960, 540])")
        #expect(isRed(pixels[153 + 2, 86 + 453]), "left edge inside \(pixels[155, 539])")
        #expect(isBlue(pixels[153 - 2, 86 + 453]), "left edge outside \(pixels[151, 539])")
        #expect(isRed(pixels[960, 86 + 907 - 2]), "bottom edge inside \(pixels[960, 991])")
        #expect(isBlue(pixels[960, 86 + 907 + 2]), "bottom edge outside \(pixels[960, 995])")
        #expect(isBlue(pixels[153 + 1, 86 + 1]), "inside the corner cut \(pixels[154, 87])")
        #expect(isRed(pixels[153 + 54, 86 + 54]), "corner arc centre \(pixels[207, 140])")
    }

    @Test func zoomShowsOnlyTheViewport() async throws {
        // A 2x fixed zoom on the top-left corner: the frame is the source's top-left quarter, so
        // content pixels are still red, and the geometry is what FrameGeometry says.
        let take = try await Fixture.take(color: (255, 0, 0))
        defer { try? FileManager.default.removeItem(at: take) }
        var project = try Project.open(take)
        project.edits.zooms = try ZoomTrack(validating: [
            ZoomSegment(range: TimeRange(start: .milliseconds(1), end: .seconds(2))!, scale: 2, focus: .fixed(x: 0, y: 0))
        ])
        project.edits.settings.camera.leadIn = nil
        project.edits.style = Self.blue
        let pixels = Pixels(try await Still.cgImage(project, at: .seconds(1.9)))
        let frame = project.timeline.frame(at: .seconds(1.9))
        #expect(frame.camera.viewport.origin == Point(x: 0, y: 0))
        #expect(isRed(pixels[960, 540]))
        #expect(isBlue(pixels[10, 10]))
    }

    @Test func stillIsBitIdenticalAcrossRuns() async throws {
        let take = try await Fixture.take(color: (0, 255, 0))
        defer { try? FileManager.default.removeItem(at: take) }
        let project = try Project.open(take)
        let first = try await Still.png(project, at: .seconds(1.2))
        let second = try await Still.png(project, at: .seconds(1.2))
        #expect(first == second)
        #expect(first.count > 1000)
    }
}
