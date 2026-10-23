import Foundation
import Testing
@testable import RecordingFormat
@testable import Timeline

struct TimelineCutSpec {
    static let frame = Size(width: 1920, height: 1080)

    static func timeline(
        _ source: SourceRecording, zooms: [ZoomSegment], cuts: [Cut], settings: TimelineSettings = .default
    ) throws -> Timeline {
        Timeline(
            source: source, zooms: try ZoomTrack(validating: zooms), settings: settings,
            cuts: try Cuts(validating: cuts, within: source.duration))
    }

    static func zoom(_ start: Double, _ end: Double, focus: ZoomSegment.Focus = .fixed(x: 0.2, y: 0.2)) -> ZoomSegment {
        ZoomSegment(range: range(start, end), scale: 2, focus: focus)
    }

    static func frames(_ timeline: Timeline, hz: Int64 = 240) -> [FrameBits] {
        stride(from: Int64(0), through: timeline.map.duration.microseconds, by: Int(1_000_000 / hz))
            .map { timeline.frame(at: OutputTime(microseconds: $0)).bits }
    }

    /// Catches any change to today's frames with no cuts. The hashes were printed by main's own
    /// Timeline (commit 8e128cb, debug build, as `swift test` runs, Apple Swift 6.4 /
    /// swiftlang-6.4.0.34.1 on arm64) over the committed fixture at 240 Hz, one per settings
    /// variant. An -O build of the same code differs at the last bit in 9 of 2880 frames, so this
    /// pins that toolchain's debug build only; `noCutsLeavesEveryTargetChangeWhereItWas` is the
    /// compiler-independent half.
    @Test(arguments: [
        ("default", TimelineSettings.default, UInt64(0x056d_d74c_ad5a_03bd)),
        ("observed", {
            var s = TimelineSettings()
            s.camera.leadIn = CameraSettings.observedLeadIn
            s.cursor.idleHideAfter = CursorSettings.observedIdleHide
            return s
        }(), UInt64(0xc5ac_8feb_7ab2_4862)),
        ("held", { var s = TimelineSettings(); s.cursor.smoothing = .none; return s }(), UInt64(0xf4c8_495a_8c70_e560)),
        ("smooth", {
            var s = TimelineSettings()
            s.cursor.smoothing = .smooth
            s.camera.rescaleShortIntervals = false
            return s
        }(), UInt64(0x1456_8d7b_9a34_c3dd)),
    ])
    func noCutsIsTodaysTimeline(name: String, settings: TimelineSettings, golden: UInt64) throws {
        let timeline = try Fixture.timeline(settings: settings)
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ v: UInt64) {
            h ^= v
            h = h &* 0x100_0000_01b3
        }
        for bits in Self.frames(timeline) {
            for d in bits.doubles { mix(d) }
            for byte in (bits.image ?? "").utf8 { mix(UInt64(byte)) }
            mix(bits.isPressed ? 1 : 2)
            mix(bits.isVisible ? 1 : 2)
        }
        #expect(h == golden, "\(name): \(String(h, radix: 16))")
        #expect(timeline.map.duration.microseconds == timeline.source.duration.microseconds)
    }

    /// Catches a zoom inside a cut leaking a zoom-out tail into the kept frames after it.
    @Test func aZoomWhollyInsideACutHasNoEffect() throws {
        let source = try Synthetic.source(duration: 12, frame: Self.frame, pointer: [(0, 300, 200), (5, 900, 700)], clicks: [1, 5])
        let cut = Cut(range: range(4, 6))
        let inside = Self.zoom(4.5, 5.5, focus: .followPointer)
        let outside = [Self.zoom(1, 3), Self.zoom(7, 9, focus: .followPointer)]
        let with = try Self.timeline(source, zooms: outside + [inside], cuts: [cut])
        let without = try Self.timeline(source, zooms: outside, cuts: [cut])
        #expect(with.map.duration == .seconds(10))
        #expect(Self.frames(with) == Self.frames(without))
        #expect(with.knotCounts.cameraScale == without.knotCounts.cameraScale)

        let uncut = try Self.timeline(source, zooms: outside + [inside], cuts: [])
        #expect(uncut.frame(at: .seconds(5.7)).camera.scale > 1.05, "without the cut the zoom-out tail is visible after 5.5 s")
        #expect(with.frame(at: .seconds(4.3)).camera.scale < 1.01, "with the cut the frame after the join is settled at 1")
    }

    /// Catches a camera jump at a join: a zoom across the cut's edge eases out from the join, and
    /// scale and velocity are continuous across it.
    @Test func aZoomAcrossAnEdgeEasesOutFromTheJoin() throws {
        let source = try Synthetic.source(duration: 12, frame: Self.frame, pointer: [(0, 300, 200)])
        let timeline = try Self.timeline(source, zooms: [Self.zoom(2, 5)], cuts: [Cut(range: range(4, 6))])
        let join = OutputTime.seconds(4)
        #expect(timeline.map.joins == [join])
        let before = timeline.frame(at: join - OutputTime(microseconds: 1_000_000 / 240)).camera
        let at = timeline.frame(at: join).camera
        #expect(before.scale.isApproximately(2, within: 1e-3))
        #expect(at.scale.isApproximately(2, within: 1e-3), "the zoom-out starts at the join, not before")
        #expect(abs(before.scaleVelocity - at.scaleVelocity) < 0.01, "velocity carries across the join")
        #expect(abs(before.center.x - at.center.x) < 0.5)
        #expect(timeline.frame(at: join + .seconds(0.5)).camera.scale < 1.3, "and is well under way half a second later")
        #expect(timeline.frame(at: .seconds(3.9)).camera.scaleVelocity.isApproximately(0, within: 1e-3))
    }

    /// Catches springing in from the recording's start after a head trim: the edited take starts
    /// at rest on the zoom and the pointer in effect at the trim.
    @Test func aTrimmedTakeStartsAtRest() throws {
        let source = try Synthetic.source(duration: 12, frame: Self.frame, pointer: [(0, 300, 200), (0.5, 1200, 700)])
        let timeline = try Self.timeline(source, zooms: [Self.zoom(1, 5)], cuts: [Cut(range: range(0, 2))])
        let first = timeline.frame(at: .zero)
        #expect(first.camera.scale == 2)
        #expect(first.camera.scaleVelocity == 0)
        #expect(first.camera.centerVelocity == .zero)
        let reach = CameraTrack.reachableCenters(bounds: source.visibleRect, scale: 2)
        #expect(first.camera.center == reach.clamp(Vector2(x: 0.2 * 1920, y: 0.2 * 1080)).point)
        #expect(first.cursor.position == Point(x: 1200, y: 700))
        #expect(first.cursor.velocity == .zero)
        let untrimmed = try Self.timeline(source, zooms: [Self.zoom(1, 5)], cuts: [])
        #expect(untrimmed.frame(at: .zero).camera.scale == 1)
    }

    /// Catches the cursor gliding across a join: it starts the kept span at rest on the pointer
    /// position the recording had there, while the image and presses read the recording instant.
    @Test func theCursorSnapsAtAJoinAndStepStateCutsWithTheContent() throws {
        let iBeam = CursorImageDeclaration(id: CursorImageID(png: Fixture.png, hotspot: WirePoint(x: 1, y: 1)), hotspot: WirePoint(x: 1, y: 1), size: WireSize(width: 16, height: 32))
        let pointer = stride(from: 0.0, through: 6, by: 0.05).map { ($0, 100 + $0 * 150, 300.0) }
        let source = try Synthetic.source(
            duration: 12, frame: Self.frame, pointer: pointer, clicks: [4.02],
            cursorChanges: [(3.5, iBeam.id)], declarations: [iBeam])
        let timeline = try Self.timeline(source, zooms: [], cuts: [Cut(range: range(2, 4))])
        let join = OutputTime.seconds(2)
        let at = timeline.frame(at: join).cursor
        #expect(at.position == Point(x: 700, y: 300), "the pointer at recording 4 s")
        #expect(at.velocity == .zero)
        #expect(at.image?.rawValue == iBeam.id.rawValue, "the image change at 3.5 s is in effect at 4 s")
        #expect(timeline.frame(at: join - .milliseconds(1)).cursor.image == nil)
        #expect(timeline.frame(at: .seconds(2.05)).cursor.isPressed, "the click at 4.02 s shows at output 2.02 s")
        #expect(!timeline.frame(at: .seconds(1.95)).cursor.isPressed)
        let uncut = try Self.timeline(source, zooms: [], cuts: [])
        #expect(uncut.frame(at: .seconds(4)).cursor.velocity != .zero, "without the cut the cursor is moving at 4 s")
    }

    /// Catches a removed wait leaving the cursor hidden after the join: idle hiding runs over the
    /// time the viewer sees.
    @Test func anIdleHideDoesNotSurviveARemovedWait() throws {
        var settings = TimelineSettings()
        settings.cursor.idleHideAfter = CursorSettings.observedIdleHide
        let source = try Synthetic.source(duration: 12, frame: Self.frame, pointer: [(0, 400, 300), (5, 500, 300), (5.5, 600, 300)])
        let uncut = try Self.timeline(source, zooms: [], cuts: [], settings: settings)
        #expect(uncut.frame(at: .seconds(3)).cursor.opacity == 0, "a 5 s wait hides the cursor from 2 s")
        let cut = try Self.timeline(source, zooms: [], cuts: [Cut(range: range(1, 4.5))], settings: settings)
        #expect(cut.frame(at: .seconds(1.4)).cursor.opacity == 1, "the wait is now 1.5 s, under the 2 s idle delay")
        #expect(cut.frame(at: .seconds(2)).cursor.opacity == 1)
        #expect(cut.frame(at: .seconds(6)).cursor.opacity == 0, "the tail wait from 5.5 s still hides it after 2 s: output 4 s")
    }

    /// Catches the typing hide ignoring the output clock: keys inside the cut are dropped and the
    /// burst is measured over what remains.
    @Test func typingInsideACutDoesNotHideTheCursor() throws {
        let source = try Synthetic.source(duration: 12, frame: Self.frame, pointer: [(0, 400, 300)], keys: [1.0, 2.5, 2.6, 2.7, 4.0])
        let uncut = try Self.timeline(source, zooms: [], cuts: [])
        #expect(uncut.frame(at: .seconds(3)).cursor.opacity == 0)
        let cut = try Self.timeline(source, zooms: [], cuts: [Cut(range: range(2, 3))])
        #expect(cut.frame(at: .seconds(2.2)).cursor.opacity == 1, "only the keys at 1.0 and 4.0 s remain, 2 s apart")
    }
}

extension TimelineCutSpec {
    /// Catches a camera flash at a join: the zoom-out collapsed onto the join and the next zoom-in
    /// milliseconds after it must not be squeezed to settle in that gap, and nor must a
    /// follow-centre change a few ms before the join squeeze into the gap before it.
    @Test(arguments: [
        ("zoom-in 50 ms after the join", [(0.0, 300.0, 200.0)], [(2.0, 5.0), (6.05, 8.0)], (4.0, 6.0)),
        ("follow-centre 10 ms after the join", [(0.0, 300.0, 200.0), (6.01, 900.0, 700.0)], [(2.0, 5.0), (6.01, 8.0)], (4.0, 6.0)),
        ("follow-centre 10 ms before the join", [(0.0, 300.0, 200.0), (4.0, 900.0, 700.0)], [(2.0, 5.0), (6.05, 8.0)], (4.01, 6.0)),
    ])
    func aChangeCollapsedOntoAJoinIsNotSqueezedAgainstItsNeighbours(
        name: String, pointer: [(Double, Double, Double)], zooms: [(Double, Double)], cut: (Double, Double)
    ) throws {
        let source = try Synthetic.source(duration: 12, frame: Self.frame, pointer: pointer)
        let segments = zooms.map { Self.zoom($0.0, $0.1, focus: .followPointer) }
        let with = try Self.timeline(source, zooms: segments, cuts: [Cut(range: range(cut.0, cut.1))])
        let without = try Self.timeline(source, zooms: segments, cuts: [])
        let join = OutputTime.seconds(cut.0)
        #expect(with.map.joins == [join])

        func peaks(_ timeline: Timeline, _ window: ClosedRange<Double>) -> (scale: Double, scaleSpeed: Double, centerSpeed: Double) {
            var lowest = Double.infinity, scaleSpeed = 0.0, centerSpeed = 0.0
            for t in stride(from: window.lowerBound, through: window.upperBound, by: 1 / 240) {
                let camera = timeline.frame(at: .seconds(t)).camera
                lowest = min(lowest, camera.scale)
                scaleSpeed = max(scaleSpeed, abs(camera.scaleVelocity))
                centerSpeed = max(centerSpeed, (camera.centerVelocity.dx * camera.centerVelocity.dx + camera.centerVelocity.dy * camera.centerVelocity.dy).squareRoot())
            }
            return (lowest, scaleSpeed, centerSpeed)
        }
        let unsqueezed = peaks(without, 0...without.map.duration.seconds)
        let across = peaks(with, (join.seconds - 0.1)...(join.seconds + 0.3))
        #expect(across.scale >= 1.8, "\(name): the camera stays near 2x through the join, lowest \(across.scale)")
        #expect(across.scaleSpeed <= unsqueezed.scaleSpeed * 1.25, "\(name): scale speed \(across.scaleSpeed) against the unsqueezed spring's \(unsqueezed.scaleSpeed)")
        #expect(across.centerSpeed <= unsqueezed.centerSpeed * 1.25, "\(name): centre speed \(across.centerSpeed) against the unsqueezed spring's \(unsqueezed.centerSpeed)")
    }

    /// Catches the camera's collapsed-change drop running for the cursor: the pointer moved inside
    /// the cut and came back 100 ms after it, so the join snaps to where the recording shows it and
    /// the cursor then returns, rather than the snap pinning it on a target nothing undoes. The
    /// pointer rests at 5.5 s so the shake filter keeps the move as real.
    @Test func aCursorMoveUndoneJustAfterAJoinStillReturns() throws {
        let pointer: [(Double, Double, Double)] = [(0, 300, 200), (5, 900, 700), (5.5, 900, 700), (6.1, 300, 200)]
        let source = try Synthetic.source(duration: 12, frame: Self.frame, pointer: pointer)
        let timeline = try Self.timeline(source, zooms: [], cuts: [Cut(range: range(4, 6))])
        #expect(timeline.frame(at: .seconds(4)).cursor.position == Point(x: 900, y: 700), "the pointer at recording 6 s")
        let later = timeline.frame(at: .seconds(6)).cursor.position
        #expect(abs(later.x - 300) < 1 && abs(later.y - 200) < 1, "back where the recording put it at 6.1 s: \(later)")
    }

    /// Catches `Retiming` touching a change when there is nothing to retime, independently of the
    /// compiler the hash above was pinned on: with no cuts the camera and cursor builders' changes
    /// come back exactly as they went in.
    @Test(arguments: ["default", "observed", "smooth"])
    func noCutsLeavesEveryTargetChangeWhereItWas(name: String) throws {
        var settings = TimelineSettings()
        switch name {
        case "observed":
            settings.camera.leadIn = CameraSettings.observedLeadIn
            settings.cursor.idleHideAfter = CursorSettings.observedIdleHide
        case "smooth": settings.cursor.smoothing = .smooth
        default: break
        }
        let source = try SourceRecording.load(from: Fixture.directory(Fixture.fiveClicks))
        let retiming = Retiming.identity(for: source)
        let camera = CameraTrack.targetChanges(source: source, zooms: AutoZoom.track(for: source, settings: settings.autoZoom), settings: settings.camera)
        #expect(camera.scale.count > 2 && camera.center.count > 2)
        let scale = retiming.apply(initial: 1, camera.scale)
        #expect(scale.initial == 1 && scale.changes == camera.scale)
        let center = retiming.apply(initial: camera.frameCenter, camera.center)
        #expect(center.initial == camera.frameCenter && center.changes == camera.center)
        let spring = try #require(settings.cursor.smoothing.spring)
        let cursor = CursorTrack.positionChanges(source: source, spring: spring, settings: settings.cursor)
        #expect(cursor.changes.count > 10)
        let position = retiming.apply(initial: cursor.initial, cursor.changes, snapsAtJoins: true)
        #expect(position.initial == cursor.initial && position.changes == cursor.changes)
    }
}
