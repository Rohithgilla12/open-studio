import Foundation
import Testing
@testable import RecordingFormat
@testable import Timeline

/// A take recorded as an area: a 1920 x 1080 display with the area (600, 300, 800, 400) chosen.
struct AreaSpec {
    static let frame = Size(width: 1920, height: 1080)
    static let wireArea = WireRect(x: 600, y: 300, width: 800, height: 400)
    static let area = Rect(origin: Point(x: 600, y: 300), size: Size(width: 800, height: 400))

    static func source(pointer: [(Double, Double, Double)], clicks: [Double]) throws -> SourceRecording {
        try Synthetic.source(duration: 10, frame: frame, area: wireArea, pointer: pointer, clicks: clicks)
    }

    static func camera(_ source: SourceRecording, zooms: ZoomTrack? = nil) -> CameraTrack {
        CameraTrack(source: source, zooms: zooms ?? AutoZoom.track(for: source), settings: CameraSettings())
    }

    static func contains(_ outer: Rect, _ inner: Rect) -> Bool {
        let e = 1e-9
        return inner.minX >= outer.minX - e && inner.minY >= outer.minY - e && inner.maxX <= outer.maxX + e
            && inner.maxY <= outer.maxY + e
    }

    @Test func anEntireScreenTakeShowsTheWholeFrame() throws {
        let source = try Synthetic.source(duration: 10, frame: Self.frame)
        #expect(source.area == nil)
        #expect(source.visibleRect == Rect(origin: Point(x: 0, y: 0), size: Self.frame))
    }

    @Test func scaleOneShowsExactlyTheArea() throws {
        let camera = Self.camera(try Self.source(pointer: [(0, 700, 400)], clicks: []))
        let state = camera.state(at: 1)
        #expect(state.scale == 1)
        #expect(state.viewport == Self.area)
        #expect(state.center == Point(x: 1000, y: 500))
    }

    @Test func clicksOutsideTheAreaDoNotZoom() throws {
        let outside = try Self.source(pointer: [(0, 100, 100)], clicks: [2, 5])
        #expect(AutoZoom.segments(for: outside).isEmpty, "both clicks land on the display beside the area")
        let inside = try Self.source(pointer: [(0, 700, 400)], clicks: [2])
        #expect(AutoZoom.segments(for: inside).count == 1)
        let edge = try Self.source(pointer: [(0, 1400, 400)], clicks: [2])
        #expect(AutoZoom.segments(for: edge).isEmpty, "the area is half-open, so its right edge is outside")
    }

    @Test func theZoomedViewportStaysInsideTheArea() throws {
        let camera = Self.camera(try Self.source(pointer: [(0, 605, 305)], clicks: [2]))
        var zoomed = false
        for t in stride(from: 0.0, through: 10, by: 1.0 / 240) {
            let state = camera.state(at: t)
            #expect(Self.contains(Self.area, state.viewport), "at \(t) s: \(state.viewport)")
            if state.scale > 1.9 { zoomed = true }
        }
        #expect(zoomed)
        let settled = camera.state(at: 4.4)
        #expect(settled.center.x.isApproximately(800, within: 1), "605 clamped to the area's left edge plus half the 400 px viewport")
        #expect(settled.center.y.isApproximately(400, within: 1), "305 clamped to the area's top edge plus half the 200 px viewport")
    }

    @Test func pointerBesideTheAreaDoesNotMoveTheCamera() throws {
        let stayed = Self.camera(try Self.source(pointer: [(0, 700, 400)], clicks: [2]))
        let wandered = Self.camera(try Self.source(pointer: [(0, 700, 400), (3.0, 1700, 400), (3.2, 1800, 900)], clicks: [2]))
        for t in stride(from: 0.0, through: 10, by: 1.0 / 60) {
            #expect(wandered.state(at: t) == stayed.state(at: t), "at \(t) s")
        }
    }

    @Test func fixedFocusIsAFractionOfTheArea() throws {
        let source = try Self.source(pointer: [(0, 700, 400)], clicks: [])
        let centre = ZoomSegment(range: TimeRange(start: .seconds(1), end: .seconds(6))!, scale: 2, focus: .fixed(x: 0.5, y: 0.5))
        let corner = ZoomSegment(range: TimeRange(start: .seconds(1), end: .seconds(6))!, scale: 2, focus: .fixed(x: 1, y: 1))
        let atCentre = Self.camera(source, zooms: try ZoomTrack(validating: [centre])).state(at: 5.9)
        #expect(atCentre.center.x.isApproximately(1000, within: 1))
        #expect(atCentre.center.y.isApproximately(500, within: 1))
        let atCorner = Self.camera(source, zooms: try ZoomTrack(validating: [corner])).state(at: 5.9)
        #expect(atCorner.center.x.isApproximately(1200, within: 1), "the area's right edge minus half the 400 px viewport")
        #expect(atCorner.center.y.isApproximately(600, within: 1))
    }

    @Test func theCursorIsStillDrawnBesideTheArea() throws {
        let source = try Self.source(pointer: [(0, 590, 400)], clicks: [])
        let cursor = Timeline(source: source, zooms: .empty).frame(at: .seconds(1)).cursor
        #expect(cursor.isVisible, "its hotspot is left of the area but the arrow points into it; the renderer's mask clips it")
    }

    @Test(arguments: [
        WireRect(x: -1, y: 0, width: 100, height: 100),
        WireRect(x: 1900, y: 0, width: 100, height: 100),
        WireRect(x: 0, y: 0, width: 0, height: 100),
        WireRect(x: 0, y: .nan, width: 100, height: 100),
    ])
    func anAreaOutsideTheFrameIsCorrupt(area: WireRect) {
        #expect(throws: SourceLoadError.self) {
            try Synthetic.source(duration: 10, frame: Self.frame, area: area)
        }
    }

    @Test func anAreaTakeLoadsFromDisk() throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var generated = try Fixture.generate()
        generated.manifest = try Fixture.editJSON(generated.manifest) {
            $0["formatVersion"] = 2
            $0["area"] = [600, 300, 800, 400]
        }
        try Fixture.write(generated, to: directory)
        #expect(try SourceRecording.load(from: directory).area == Self.area)
    }
}
