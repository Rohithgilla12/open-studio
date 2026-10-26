import Foundation
import Testing
@testable import Timeline

struct ClickEffectSpec {
    static let first = Point(x: 300, y: 200)
    static let second = Point(x: 900, y: 700)

    static func source(clicks: [Double] = [1, 3]) throws -> SourceRecording {
        try Synthetic.source(duration: 6, pointer: [(0, 300, 200), (2, 900, 700)], clicks: clicks)
    }

    static func timeline(_ source: SourceRecording, cuts: [Cut] = [], showsClicks: Bool = true) throws -> Timeline {
        var settings = TimelineSettings()
        settings.cursor.showsClicks = showsClicks
        return Timeline(source: source, zooms: .empty, settings: settings, cuts: try Cuts(validating: cuts, within: source.duration))
    }

    static func range(_ start: Double, _ end: Double) -> TimeRange {
        TimeRange(start: .seconds(start), end: .seconds(end))!
    }

    @Test func aRingStartsAtTheClickAndGrowsThroughItsDuration() throws {
        let timeline = try Self.timeline(Self.source())
        #expect(timeline.frame(at: .seconds(0.99)).clicks.isEmpty, "before the click")
        #expect(timeline.frame(at: .seconds(1)).clicks == [ClickPulse(position: Self.first, progress: 0)])
        let mid = try #require(timeline.frame(at: .milliseconds(1225)).clicks.first)
        #expect(mid.position == Self.first)
        #expect(abs(mid.progress - 0.5) < 1e-9, "\(mid.progress)")
        #expect(timeline.frame(at: .milliseconds(1449)).clicks.count == 1)
    }

    @Test func aRingIsGoneOnceItsDurationHasPassed() throws {
        let timeline = try Self.timeline(Self.source())
        let end = RecordingTime.seconds(1) + CursorSettings.clickDuration
        #expect(timeline.frame(at: OutputTime(microseconds: end.microseconds)).clicks.isEmpty)
        #expect(timeline.frame(at: .seconds(2)).clicks.isEmpty)
    }

    @Test func noRingsUnlessTheEffectIsOn() throws {
        let timeline = try Self.timeline(Self.source(), showsClicks: false)
        #expect(timeline.frame(at: .seconds(1)).clicks.isEmpty)
        #expect(timeline.frame(at: .seconds(3.1)).clicks.isEmpty)
    }

    @Test func aClickInsideACutNeverDraws() throws {
        let timeline = try Self.timeline(Self.source(), cuts: [Cut(range: Self.range(2.8, 3.2))])
        var shown: [ClickPulse] = []
        for ms in stride(from: Int64(0), through: timeline.map.duration.microseconds / 1000, by: 5) {
            shown.append(contentsOf: timeline.frame(at: .milliseconds(ms)).clicks)
        }
        #expect(!shown.contains { $0.position == Self.second }, "the click at 3 s is inside the cut")
        #expect(shown.contains { $0.position == Self.first }, "the click at 1 s is kept")

        let uncut = try Self.timeline(Self.source())
        #expect(uncut.frame(at: .seconds(3.25)).clicks.map(\.position) == [Self.second], "without the cut the ring shows after 3.2 s")
    }

    @Test func aCutThatBeginsMidRingCutsTheRingWithTheContent() throws {
        // The cut removes [1.2, 2) of the recording, so output 1.2 shows recording 2.0, 1 s after the click.
        let timeline = try Self.timeline(Self.source(), cuts: [Cut(range: Self.range(1.2, 2))])
        #expect(timeline.frame(at: .milliseconds(1190)).clicks.count == 1)
        #expect(timeline.frame(at: .milliseconds(1200)).clicks.isEmpty)
    }

    @Test func overlappingClicksShowOldestFirst() throws {
        let timeline = try Self.timeline(Self.source(clicks: [1, 1.3]))
        let pulses = timeline.frame(at: .milliseconds(1400)).clicks
        #expect(pulses.count == 2)
        #expect(pulses.map(\.progress) == pulses.map(\.progress).sorted(by: >), "\(pulses)")
    }

    @Test func aHiddenCursorIsNeverVisibleButItsClicksStillShow() throws {
        var settings = TimelineSettings()
        settings.cursor.isHidden = true
        settings.cursor.showsClicks = true
        let timeline = Timeline(source: try Self.source(), zooms: .empty, settings: settings)
        for ms in stride(from: Int64(0), through: 6000, by: 50) {
            let cursor = timeline.frame(at: .milliseconds(ms)).cursor
            #expect(!cursor.isVisible && cursor.opacity == 0, "\(ms) ms")
        }
        #expect(timeline.frame(at: .seconds(1.1)).clicks.count == 1)
        #expect(Timeline(source: try Self.source(), zooms: .empty).frame(at: .seconds(1.1)).cursor.isVisible, "visible by default")
    }

    @Test func cursorSettingsFromBeforeTheseControlsDecodeToTheDefaults() throws {
        let saved = Data(#"{"smoothing": "rapid", "pressedScale": 0.8}"#.utf8)
        let settings = try JSONDecoder().decode(CursorSettings.self, from: saved)
        #expect(settings.size == 1 && !settings.isHidden && !settings.showsClicks)
        #expect(settings.smoothing == .rapid)

        var edited = CursorSettings()
        edited.size = 2.5
        edited.isHidden = true
        edited.showsClicks = true
        #expect(try JSONDecoder().decode(CursorSettings.self, from: JSONEncoder().encode(edited)) == edited)
    }
}
