import Foundation
import Testing
@testable import RecordingFormat
@testable import Timeline

struct CursorSpec {
    static func track(_ source: SourceRecording, _ edit: (inout CursorSettings) -> Void = { _ in }) -> CursorTrack {
        var settings = CursorSettings()
        edit(&settings)
        return CursorTrack(source: source, settings: settings, retiming: .identity(for: source))
    }

    /// Pointer at rest from t = 0; three keys 300 ms apart from 1.0 s.
    static func typing(keys: [Double] = [1.0, 1.3, 1.6], pointer: [(Double, Double, Double)] = [(0, 400, 300)]) throws -> CursorTrack {
        track(try Synthetic.source(duration: 10, pointer: pointer, keys: keys))
    }

    @Test func cursorFadesAfterThirdKeyWithinWindow() throws {
        let cursor = try Self.typing()
        #expect(cursor.hidden == [CursorTrack.Interval(start: 1.6, end: 3.4)], "hidden until the last key plus the window")
        #expect(cursor.state(at: 1.5).opacity == 1)
        #expect(cursor.state(at: 1.6).opacity == 1, "the fade starts at the third key")
        #expect(cursor.state(at: 1.675).opacity.isApproximately(0.5))
        #expect(cursor.state(at: 1.75).opacity.isApproximately(0))
        #expect(cursor.state(at: 1.8).opacity == 0)
        #expect(cursor.state(at: 1.8).isVisible == false)
        #expect(cursor.state(at: 3.3).opacity == 0)
        #expect(cursor.state(at: 3.475).opacity.isApproximately(0.5))
        #expect(cursor.state(at: 3.6).opacity == 1)
    }

    @Test func twoKeysDoNotFade() throws {
        let cursor = try Self.typing(keys: [1.0, 1.3])
        #expect(cursor.hidden.isEmpty)
        #expect(cursor.state(at: 1.5).opacity == 1)
    }

    @Test func keysSpreadBeyondTheWindowDoNotFade() throws {
        let cursor = try Self.typing(keys: [1.0, 2.0, 3.0])
        #expect(cursor.hidden.isEmpty, "2 s span exceeds the 1.8 s window")
    }

    @Test func continuedTypingExtendsTheFade() throws {
        let cursor = try Self.typing(keys: [1.0, 1.3, 1.6, 2.5, 4.0])
        #expect(cursor.hidden == [CursorTrack.Interval(start: 1.6, end: 5.8)])
    }

    @Test func pointerMovementEndsTypingFade() throws {
        let cursor = try Self.typing(pointer: [(0, 400, 300), (2.0, 420, 300)])
        #expect(cursor.hidden == [CursorTrack.Interval(start: 1.6, end: 2.0)])
        #expect(cursor.state(at: 1.9).opacity == 0)
        #expect(cursor.state(at: 2.075).opacity.isApproximately(0.5))
        #expect(cursor.state(at: 2.2).opacity == 1)
    }

    @Test func pointerMovementBetweenKeysBreaksTheBurst() throws {
        let cursor = try Self.typing(pointer: [(0, 400, 300), (1.4, 420, 300)])
        #expect(cursor.hidden.isEmpty, "the pointer moved between the second and third key")
    }

    @Test func idleHideIsOffByDefaultAndHidesAfterTheDelayWhenOn() throws {
        let source = try Synthetic.source(duration: 10, pointer: [(0, 400, 300), (5, 500, 300)])
        #expect(Self.track(source).hidden.isEmpty)
        let idle = Self.track(source) { $0.idleHideAfter = CursorSettings.observedIdleHide }
        #expect(idle.hidden == [CursorTrack.Interval(start: 2, end: 5), CursorTrack.Interval(start: 7, end: 10)])
        #expect(idle.state(at: 1.9).opacity == 1)
        #expect(idle.state(at: 2.2).opacity == 0)
        #expect(idle.state(at: 5.2).opacity == 1)
    }

    @Test func rapidSpringTakesOverBeforeAClick() throws {
        let pointer: [(Double, Double, Double)] = [(0, 100, 100), (0.9, 700, 100)]
        let source = try Synthetic.source(duration: 5, pointer: pointer, clicks: [1.0])
        let cursor = Self.track(source)
        let track = try #require(cursor.position.springTrack)
        let rapid = SpringResponse(.cursorRapid)
        let medium = SpringResponse(.cursorMedium)
        #expect(track.knots.map(\.time) == [0, 0.825, 0.9, 1.0, 1.08])
        #expect(track.knots.map(\.response) == [medium, rapid, rapid, medium, medium])
        #expect(track.knots[1].target == Vector2(x: 100, y: 100), "the lead holds the target then in effect")

        let plain = Self.track(source) { $0.clickSpringLead = .zero }
        let plainTrack = try #require(plain.position.springTrack)
        #expect(plainTrack.knots.allSatisfy { $0.response == medium })
        let withRapid = abs(track.evaluate(at: 0.999).position.x - 700)
        let withoutRapid = abs(plainTrack.evaluate(at: 0.999).position.x - 700)
        #expect(withRapid < withoutRapid, "rapid \(withRapid) px short vs medium \(withoutRapid) px short at the click")
    }

    @Test func pressAmountEasesInAndOut() throws {
        let source = try Synthetic.source(duration: 5, pointer: [(0, 100, 100)], clicks: [1.0])
        let cursor = Self.track(source)
        #expect(cursor.presses == [CursorTrack.Interval(start: 1.0, end: 1.08)])
        #expect(cursor.state(at: 0.99).isPressed == false)
        #expect(cursor.state(at: 0.99).pressAmount == 0)
        #expect(cursor.state(at: 1.0).isPressed == true)
        #expect(cursor.state(at: 1.04).pressAmount.isApproximately(0.5))
        #expect(cursor.state(at: 1.08).isPressed == false)
        #expect(cursor.state(at: 1.08).pressAmount.isApproximately(1))
        #expect(cursor.state(at: 1.12).pressAmount.isApproximately(0.5))
        #expect(cursor.state(at: 1.2).pressAmount == 0)
    }

    @Test func unmatchedDownRunsToTheEnd() {
        let presses = CursorTrack.pressIntervals(
            [ButtonEvent(time: .seconds(1), button: .right, edge: .down, position: Point(x: 0, y: 0))], end: .seconds(4))
        #expect(presses == [CursorTrack.Interval(start: 1, end: 4)])
    }

    @Test func overlappingButtonsUnionIntoOnePress() {
        let presses = CursorTrack.pressIntervals([
            ButtonEvent(time: .seconds(1), button: .left, edge: .down, position: Point(x: 0, y: 0)),
            ButtonEvent(time: .seconds(1.5), button: .right, edge: .down, position: Point(x: 0, y: 0)),
            ButtonEvent(time: .seconds(2), button: .left, edge: .up, position: Point(x: 0, y: 0)),
            ButtonEvent(time: .seconds(3), button: .right, edge: .up, position: Point(x: 0, y: 0)),
        ], end: .seconds(4))
        #expect(presses == [CursorTrack.Interval(start: 1, end: 3)])
    }

    @Test func cursorImageFollowsChanges() throws {
        let source = try SourceRecording.load(from: Fixture.directory(Fixture.fiveClicks))
        let cursor = Self.track(source)
        let arrow = Fixture.arrow.id.rawValue
        let iBeam = Fixture.iBeam.id.rawValue
        #expect(cursor.state(at: 0).image?.rawValue == arrow)
        #expect(cursor.state(at: 5.899).image?.rawValue == arrow)
        #expect(cursor.state(at: 5.9).image?.rawValue == iBeam)
        #expect(cursor.state(at: 7.1).image?.rawValue == arrow)
    }

    @Test func noCursorChangeMeansNoImage() throws {
        let source = try Synthetic.source(duration: 2, pointer: [(0, 1, 1)])
        #expect(Self.track(source).state(at: 1).image == nil)
    }

    @Test func offDisplayPointerIsInvisible() throws {
        let source = try Synthetic.source(duration: 2, pointer: [(0, -50, 100), (1, 50, 100)])
        let cursor = Self.track(source) { $0.smoothing = .none }
        #expect(cursor.state(at: 0.5).isVisible == false)
        #expect(cursor.state(at: 0.5).opacity == 1, "off display, not faded")
        #expect(cursor.state(at: 1.5).isVisible == true)
    }

    @Test func noSmoothingHoldsTheLastSampleExactly() throws {
        let source = try Synthetic.source(duration: 2, pointer: [(0, 10, 20), (1, 30, 40)])
        let cursor = Self.track(source) { $0.smoothing = .none }
        #expect(cursor.state(at: 0.999).position == Point(x: 10, y: 20))
        #expect(cursor.state(at: 1).position == Point(x: 30, y: 40))
        #expect(cursor.state(at: 1).velocity == .zero)
    }

    @Test func smoothedCursorSettlesOnTheLastSampleDespiteThinning() throws {
        let pointer = stride(from: 0.0, through: 0.5, by: 0.01).map { ($0, 100 + $0 * 400, 100.0) } + [(0.51, 303, 100)]
        let source = try Synthetic.source(duration: 5, pointer: pointer)
        let cursor = Self.track(source)
        let track = try #require(cursor.position.springTrack)
        #expect(track.knots.count < pointer.count, "4 px steps are thinned")
        #expect(track.knots.last?.target == Vector2(x: 303, y: 100), "the final sample is always kept")
        #expect(cursor.state(at: 4.9).position.x.isApproximately(303, within: 0.01))
    }

    @Test func shakeFilterAppliesToTheCursor() throws {
        let source = try Synthetic.source(duration: 2, pointer: [(0, 100, 100), (0.1, 1800, 900), (0.2, 110, 100)])
        let cursor = Self.track(source) { $0.smoothing = .none }
        #expect(cursor.state(at: 0.15).position == Point(x: 100, y: 100))
    }
}

extension CursorTrack {
    /// One clock, as before cuts.
    func state(at seconds: Double) -> CursorState { state(springAt: seconds, recordingAt: seconds) }
}

extension CursorTrack.PositionTrack {
    var springTrack: SpringTrack<Vector2>? {
        if case .spring(let track) = self { return track }
        return nil
    }
}
