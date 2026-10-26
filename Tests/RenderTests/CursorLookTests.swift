import CoreGraphics
import Foundation
import Testing
@testable import Render
import Timeline

struct CursorLookGeometrySpec {
    let arrow = CursorImageInfo(relativePath: "cursors/a.png", hotspot: Point(x: 10, y: 10), size: Size(width: 56, height: 80))

    func look(size: Double) -> CursorLook {
        var settings = CursorSettings()
        settings.size = size
        return CursorLook(settings: settings, frame: source)
    }

    @Test func cursorSizeScalesTheDrawnCursorAroundItsHotspot() throws {
        let position = Point(x: 1000, y: 700)
        let state = frame(viewport: fullFrame, cursor: position)
        let normal = try #require(FrameGeometry(frame: state, layout: layout(), cursorImage: arrow, look: look(size: 1)).cursor)
        let large = try #require(FrameGeometry(frame: state, layout: layout(), cursorImage: arrow, look: look(size: 2)).cursor)
        #expect(abs(large.rect.size.width - 2 * normal.rect.size.width) < 1e-9)
        #expect(abs(large.rect.size.height - 2 * normal.rect.size.height) < 1e-9)
        let tip = { (r: CursorPlacement) in Point(x: r.rect.origin.x + 10 * r.rect.size.width / 56, y: r.rect.origin.y + 10 * r.rect.size.height / 80) }
        #expect(abs(tip(large).x - tip(normal).x) < 1e-9 && abs(tip(large).y - tip(normal).y) < 1e-9)
    }

    @Test func aRingSitsOnTheClickAndZoomsWithTheScreen() throws {
        let click = ClickPulse(position: Point(x: 1000, y: 700), progress: 0.5)
        let half = Rect(origin: Point(x: 800, y: 500), size: Size(width: source.width / 2, height: source.height / 2))
        let whole = FrameGeometry(frame: frame(viewport: fullFrame, clicks: [click]), layout: layout(), cursorImage: nil, look: look(size: 1))
        let zoomed = FrameGeometry(frame: frame(viewport: half, clicks: [click]), layout: layout(), cursorImage: nil, look: look(size: 1))
        let wholeRing = try #require(whole.clicks.first)
        let zoomedRing = try #require(zoomed.clicks.first)
        #expect(wholeRing.center == whole.canvasPoint(click.position))
        #expect(zoomedRing.center == zoomed.canvasPoint(click.position))
        #expect(abs(zoomedRing.radius - 2 * wholeRing.radius) < 1e-9, "a 2x zoom doubles the ring")
        let large = FrameGeometry(frame: frame(viewport: fullFrame, clicks: [click]), layout: layout(), cursorImage: nil, look: look(size: 2))
        #expect(abs(try #require(large.clicks.first).radius - 2 * wholeRing.radius) < 1e-9, "the cursor size scales the ring")
    }

    @Test func aRingGrowsAndFades() {
        let rings = [0, 0.5, 0.99].map { ClickRing(ClickPulse(position: Point(x: 0, y: 0), progress: $0), center: Point(x: 0, y: 0), largest: 40) }
        #expect(rings[0].radius < rings[1].radius && rings[1].radius < rings[2].radius)
        #expect(rings[0].opacity > rings[1].opacity && rings[1].opacity > rings[2].opacity)
        #expect(rings[0].opacity > 0.8 && rings[2].opacity < 0.01)
        #expect(rings[2].radius <= 40)
    }

    @Test func aHiddenCursorStillPlacesItsRings() {
        let click = ClickPulse(position: Point(x: 1000, y: 700), progress: 0.2)
        let g = FrameGeometry(
            frame: frame(viewport: fullFrame, opacity: 0, visible: false, clicks: [click]), layout: layout(), cursorImage: arrow,
            look: look(size: 1))
        #expect(g.cursor == nil)
        #expect(g.clicks.count == 1)
    }
}

/// Through the real composition, with the five-clicks fixture's first click at 1 s at (1347, 803).
struct CursorLookPixelSpec {
    static let onBlue = Style(
        background: .solid(RGBColor(red: 0, green: 0, blue: 1)), padding: 0.08, cornerRadius: 0, shadow: .none)
    /// The content rect at hd1080 for the 1920 x 1080 fixture, from PixelSpec.
    static let content = (x: 153, y: 86, width: 1613, height: 907)

    func isGreen(_ p: (red: Int, green: Int, blue: Int)) -> Bool { p.green > 200 && p.red < 60 && p.blue < 60 }

    /// Pixels inside the content that are not the screen's green: the cursor and any rings.
    func marked(_ pixels: Pixels, near centre: (x: Int, y: Int)? = nil, within radius: Int = 0) -> Int {
        let c = Self.content
        var count = 0
        for y in (c.y + 3)..<(c.y + c.height - 3) {
            for x in (c.x + 3)..<(c.x + c.width - 3) {
                if let centre, abs(x - centre.x) > radius || abs(y - centre.y) > radius { continue }
                if !isGreen(pixels[x, y]) { count += 1 }
            }
        }
        return count
    }

    func project(_ take: URL, _ edit: (inout CursorSettings) -> Void) throws -> Project {
        var project = try Project.open(take)
        project.edits.zooms = .empty
        project.edits.style = Self.onBlue
        project.edits.format = .hd1080
        edit(&project.edits.settings.cursor)
        return project
    }

    @Test func cursorSizeAndHideShowInAStill() async throws {
        let take = try await Fixture.take(color: (0, 255, 0), seconds: 2)
        defer { try? FileManager.default.removeItem(at: take) }
        let normal = marked(Pixels(try await Still.cgImage(try project(take) { _ in }, at: .seconds(0.5))))
        let large = marked(Pixels(try await Still.cgImage(try project(take) { $0.size = 2 }, at: .seconds(0.5))))
        let hidden = marked(Pixels(try await Still.cgImage(try project(take) { $0.isHidden = true }, at: .seconds(0.5))))
        #expect(normal > 100, "the cursor draws \(normal) px")
        #expect(Double(large) > 3 * Double(normal) && Double(large) < 5 * Double(normal), "twice the size is four times the area: \(normal) -> \(large)")
        #expect(hidden == 0, "\(hidden) px with the cursor hidden")
    }

    @Test func aClickRingShowsAfterTheClickAndNotOutsideItsDuration() async throws {
        let take = try await Fixture.take(color: (0, 255, 0), seconds: 2)
        defer { try? FileManager.default.removeItem(at: take) }
        let shown = try project(take) {
            $0.isHidden = true
            $0.showsClicks = true
        }
        // (1347, 803) * 0.84 + (153, 86).
        let click = (x: 1284, y: 760)
        let during = Pixels(try await Still.cgImage(shown, at: .seconds(1.1)))
        let after = Pixels(try await Still.cgImage(shown, at: .seconds(1.5)))
        let before = Pixels(try await Still.cgImage(shown, at: .seconds(0.95)))
        #expect(marked(during, near: click, within: 40) > 200, "a ring around the click")
        #expect(marked(during) == marked(during, near: click, within: 40), "and nothing elsewhere")
        #expect(marked(after) == 0, "gone 500 ms after the click")
        #expect(marked(before) == 0, "nothing before the click")
        #expect(isGreen(during[click.x, click.y]), "a ring, not a disc: the click point itself stays clear")
    }

    @Test func aClickInsideACutDrawsNoRing() async throws {
        let take = try await Fixture.take(color: (0, 255, 0), seconds: 2)
        defer { try? FileManager.default.removeItem(at: take) }
        var cut = try project(take) {
            $0.isHidden = true
            $0.showsClicks = true
        }
        cut.edits.cuts = try Cuts(
            validating: [Cut(range: TimeRange(start: .milliseconds(900), end: .milliseconds(1100))!)], within: cut.source.duration)
        // Output 0.9 s shows recording 1.1 s, which would be 100 ms into the ring without the cut.
        let joined = Pixels(try await Still.cgImage(cut, at: .seconds(0.9)))
        #expect(marked(joined) == 0, "\(marked(joined)) px at the join")
    }
}
