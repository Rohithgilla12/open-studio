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
    /// Timeline (commit 8e128cb, debug build, as `swift test` runs) over the committed fixture at
    /// 240 Hz, one per settings variant. An -O build of the same code differs at the last bit in 9
    /// of 2880 frames, so this pins the debug build only.
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
