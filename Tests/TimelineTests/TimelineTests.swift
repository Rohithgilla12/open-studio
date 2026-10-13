import Foundation
import Testing
@testable import RecordingFormat
@testable import Timeline

struct TimelineSpec {
    @Test func timesClampToTheRecording() throws {
        let timeline = try Fixture.timeline()
        #expect(timeline.frame(at: .seconds(-5)) == timeline.frame(at: .zero))
        #expect(timeline.frame(at: .seconds(99)) == timeline.frame(at: timeline.source.duration))
        #expect(timeline.frame(at: .seconds(99)) != timeline.frame(at: .seconds(2)))
    }

    @Test func frameCombinesCameraAndCursor() throws {
        let timeline = try Fixture.timeline()
        let frame = timeline.frame(at: .seconds(3))
        #expect(frame.camera.scale > 1.9, "inside the first segment")
        #expect(frame.cursor.image?.rawValue == Fixture.arrow.id.rawValue)
        #expect(frame.cursor.isVisible)
    }

    @Test func defaultSettingsMatchTheTeardown() {
        let settings = TimelineSettings.default
        #expect(settings.camera.spring == Spring(stiffness: 250, damping: 40, mass: 2.25))
        #expect(settings.camera.leadIn == nil)
        #expect(settings.cursor.smoothing == .medium)
        #expect(CursorSmoothing.smooth.spring == Spring(stiffness: 470, damping: 70, mass: 3))
        #expect(CursorSmoothing.medium.spring == Spring(stiffness: 340, damping: 60, mass: 3))
        #expect(CursorSmoothing.rapid.spring == Spring(stiffness: 530, damping: 40, mass: 1))
        #expect(CursorSmoothing.none.spring == nil)
        #expect(settings.cursor.clickSpringLead == .milliseconds(175))
        #expect(settings.cursor.shakeThreshold == 500)
        #expect(settings.cursor.typingKeyCount == 3)
        #expect(settings.cursor.typingWindow == .milliseconds(1800))
        #expect(settings.cursor.idleHideAfter == nil)
        #expect(settings.cursor.pressedScale == 0.9)
    }

    @Test func settingsRoundTripThroughJSON() throws {
        var settings = TimelineSettings()
        settings.camera.leadIn = CameraSettings.observedLeadIn
        settings.cursor.smoothing = .rapid
        settings.cursor.idleHideAfter = CursorSettings.observedIdleHide
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(TimelineSettings.self, from: data) == settings)
    }
}
