import Foundation
import Testing
@testable import Timeline

func sample(_ seconds: Double, _ x: Double, _ y: Double) -> PointerSample {
    PointerSample(time: .seconds(seconds), position: Point(x: x, y: y))
}

struct PointerFilterSpec {
    @Test func thinningKeepsSamplesAtLeastTheDistanceApart() {
        let samples = [sample(0, 0, 0), sample(0.1, 4, 3), sample(0.2, 8, 6), sample(0.3, 9, 0), sample(0.4, 20, 0)]
        let thinned = Thinning.apply(samples, distance: 10)
        #expect(thinned.map(\.time.seconds) == [0, 0.2, 0.4], "8,6 is exactly 10 px away and kept; 9,0 is 9 px from 8,6")
    }

    @Test func thinningHonoursAlwaysKeep() {
        let samples = [sample(0, 0, 0), sample(0.1, 1, 1), sample(0.2, 2, 2)]
        #expect(Thinning.apply(samples, distance: 10) { $0 == 2 }.map(\.time.seconds) == [0, 0.2])
    }

    @Test func shakeFilterDropsOneSampleExcursion() {
        let samples = [sample(0, 100, 100), sample(0.1, 110, 100), sample(0.2, 1800, 900), sample(0.3, 120, 100)]
        #expect(ShakeFilter.apply(samples, threshold: 500).map(\.time.seconds) == [0, 0.1, 0.3])
    }

    @Test func shakeFilterKeepsRealFastMove() {
        let samples = [sample(0, 100, 100), sample(0.1, 110, 100), sample(0.2, 1800, 900), sample(0.3, 1810, 900)]
        #expect(ShakeFilter.apply(samples, threshold: 500).count == 4)
    }

    @Test func shakeFilterKeepsAnExcursionAtTheEnd() {
        let samples = [sample(0, 100, 100), sample(0.1, 110, 100), sample(0.2, 1800, 900)]
        #expect(ShakeFilter.apply(samples, threshold: 500).count == 3, "no successor can prove it a glitch")
    }
}

struct PointerGroupSpec {
    let viewport = Size(width: 960, height: 540)

    @Test func groupClosesWhenBoundingBoxExceedsHalfViewport() {
        let samples = [sample(0, 100, 100), sample(0.5, 500, 100), sample(1.0, 600, 100), sample(1.5, 650, 100)]
        let groups = PointerGroups.build(
            samples: samples, segmentEnd: .seconds(2), visibleViewport: viewport, thinning: 0, shakeThreshold: 0)
        #expect(groups.map(\.start.seconds) == [0, 1.0], "a 500 px wide box exceeds the 480 px limit")
        #expect(groups[0].target == Point(x: 300, y: 100), "equal 0.5 s weights")
        #expect(groups[1].target == Point(x: 625, y: 100))
    }

    @Test func groupClosesOnHeightToo() {
        let samples = [sample(0, 100, 100), sample(0.5, 100, 360), sample(1.0, 100, 380)]
        let groups = PointerGroups.build(
            samples: samples, segmentEnd: .seconds(2), visibleViewport: viewport, thinning: 0, shakeThreshold: 0)
        #expect(groups.map(\.start.seconds) == [0, 1.0], "a 280 px tall box exceeds the 270 px limit")
    }

    @Test func centroidWeightsEachSampleByTimeUntilTheNext() {
        let samples = [sample(0, 0, 0), sample(0.1, 100, 0)]
        let groups = PointerGroups.build(
            samples: samples, segmentEnd: .seconds(1), visibleViewport: viewport, thinning: 0, shakeThreshold: 0)
        #expect(groups.count == 1)
        #expect(groups[0].target.x.isApproximately(90), "0.1 s at 0 and 0.9 s at 100")
    }

    @Test func zeroWeightsFallBackToThePlainMean() {
        let samples = [sample(1, 0, 0), sample(1, 100, 0)]
        let groups = PointerGroups.build(
            samples: samples, segmentEnd: .seconds(1), visibleViewport: viewport, thinning: 0, shakeThreshold: 0)
        #expect(groups.map(\.target) == [Point(x: 50, y: 0)])
    }

    @Test func thinningAndShakeFilterRunBeforeGrouping() {
        let samples = [sample(0, 100, 100), sample(0.1, 102, 100), sample(0.2, 1800, 900), sample(0.3, 104, 100)]
        let groups = PointerGroups.build(
            samples: samples, segmentEnd: .seconds(1), visibleViewport: viewport, thinning: 10, shakeThreshold: 500)
        #expect(groups.count == 1, "the warp is dropped and the 2 px moves are thinned, so one group remains")
        #expect(groups[0].target == Point(x: 100, y: 100))
    }
}

struct CameraSpec {
    static let frame = Size(width: 1920, height: 1080)

    /// Pointer at rest at (300, 200); one click at 2 s gives the segment [1.7 s, 4.5 s).
    static func restingSource() throws -> SourceRecording {
        try Synthetic.source(duration: 10, frame: frame, pointer: [(0, 300, 200)], clicks: [2])
    }

    static func camera(_ source: SourceRecording, settings: CameraSettings = CameraSettings()) -> CameraTrack {
        CameraTrack(source: source, zooms: AutoZoom.track(for: source), settings: settings)
    }

    @Test func cameraReachesTheClampedGroupCentroidInsideALongSegment() throws {
        let camera = Self.camera(try Self.restingSource())
        let state = camera.state(at: 4.4)
        #expect(state.scale.isApproximately(2, within: 1e-3))
        #expect(state.center.x.isApproximately(480, within: 1), "300 clamped to half the 960 px viewport")
        #expect(state.center.y.isApproximately(270, within: 1), "200 clamped to half the 540 px viewport")
        #expect(state.viewport.size.width.isApproximately(960, within: 0.1))
        #expect(state.viewport.size.height.isApproximately(540, within: 0.1))
        #expect(state.viewport.origin.x.isApproximately(state.center.x - state.viewport.size.width / 2))
        #expect(state.viewport.origin.y.isApproximately(state.center.y - state.viewport.size.height / 2))
    }

    @Test func cameraIsAtRestOutsideSegments() throws {
        let camera = Self.camera(try Self.restingSource())
        let before = camera.state(at: 1.0)
        #expect(before.scale == 1)
        #expect(before.center == Point(x: 960, y: 540))
        #expect(before.viewport == Rect(origin: Point(x: 0, y: 0), size: Self.frame))
        let after = camera.state(at: 9.5)
        #expect(after.scale == 1)
        #expect(after.center.x.isApproximately(960, within: 1e-3))
    }

    @Test func scaleNeverBelowOneAndViewportNeverLeavesFrame() throws {
        let camera = Self.camera(try Self.restingSource())
        var sawOvershoot = false
        for t in stride(from: 0.0, through: 10, by: 1.0 / 240) {
            let state = camera.state(at: t)
            #expect(state.scale >= 1)
            #expect(state.viewport.minX >= 0 && state.viewport.minY >= 0)
            #expect(state.viewport.maxX <= Self.frame.width + 1e-9 && state.viewport.maxY <= Self.frame.height + 1e-9)
            if camera.scale.evaluate(at: t).position < 1 { sawOvershoot = true }
        }
        #expect(sawOvershoot, "the underdamped camera spring does dip below 1 while zooming out, and the clamp hides it")
    }

    @Test func groupSplitMovesTheCameraMidSegment() throws {
        var pointer: [(Double, Double, Double)] = [(0, 200, 200)]
        pointer.append(contentsOf: stride(from: 3.0, through: 3.5, by: 0.05).map { ($0, 200 + ($0 - 3) * 2000, 200) })
        let source = try Synthetic.source(duration: 10, frame: Self.frame, pointer: pointer, clicks: [2])
        let camera = Self.camera(source)
        #expect(camera.center.knots.count > 3, "zoom-in, at least two groups, zoom-out")
        let early = camera.state(at: 2.9).center.x
        let late = camera.state(at: 4.4).center.x
        #expect(early.isApproximately(480, within: 5), "settled on the first group")
        #expect(late > early + 400, "the pointer ran 1000 px to the right and the camera followed")
    }

    @Test func pointerOnAnotherDisplayDoesNotMoveTheCamera() throws {
        let stayed = Self.camera(try Self.restingSource())
        let left = Self.camera(try Synthetic.source(
            duration: 10, frame: Self.frame, pointer: [(0, 300, 200), (3.0, -800, 200), (3.2, -1600, 900)], clicks: [2]))
        for t in stride(from: 0.0, through: 10, by: 1.0 / 60) {
            #expect(left.state(at: t) == stayed.state(at: t), "at \(t) s")
        }
    }

    @Test func leadInStartsTheZoomBeforeTheSegment() throws {
        let source = try Self.restingSource()
        let plain = Self.camera(source)
        var settings = CameraSettings()
        settings.leadIn = CameraSettings.observedLeadIn
        let led = Self.camera(source, settings: settings)
        #expect(plain.state(at: 1.6).scale == 1)
        #expect(led.state(at: 1.6).scale > 1.2)
        #expect(led.scale.knots[1].time.isApproximately(1.35))
    }

    @Test func backToBackSegmentsDoNotDipToOne() throws {
        let source = try Self.restingSource()
        let a = ZoomSegment(range: TimeRange(start: .seconds(1), end: .seconds(3))!, scale: 2, focus: .followPointer)
        let b = ZoomSegment(range: TimeRange(start: .seconds(3), end: .seconds(5))!, scale: 2, focus: .followPointer)
        let camera = CameraTrack(source: source, zooms: try ZoomTrack(validating: [a, b]), settings: CameraSettings())
        #expect(camera.scale.knots.map(\.target) == [1, 2, 2, 1], "no target of 1 at the 3 s boundary")
        #expect(camera.scale.knots.map(\.time) == [0, 1, 3, 5])
        #expect(camera.state(at: 3.2).scale.isApproximately(2, within: 1e-3))
    }

    @Test func fixedFocusTargetsThePointClampedToTheFrame() throws {
        let source = try Self.restingSource()
        let corner = ZoomSegment(range: TimeRange(start: .seconds(1), end: .seconds(6))!, scale: 2, focus: .fixed(x: 1, y: 1))
        let camera = CameraTrack(source: source, zooms: try ZoomTrack(validating: [corner]), settings: CameraSettings())
        let state = camera.state(at: 5.9)
        #expect(state.center.x.isApproximately(1440, within: 1))
        #expect(state.center.y.isApproximately(810, within: 1))
    }
}
