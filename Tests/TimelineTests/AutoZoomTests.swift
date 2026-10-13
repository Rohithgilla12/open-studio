import Foundation
import Testing
@testable import Timeline

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct AutoZoomSpec {
    let settings = AutoZoomSettings()

    func ranges(clicks: [Double], duration: Double) -> [(Double, Double)] {
        AutoZoom.segments(clickTimes: clicks.map(RecordingTime.seconds), duration: .seconds(duration), settings: settings)
            .map { ($0.range.start.seconds, $0.range.end.seconds) }
    }

    func expect(_ actual: [(Double, Double)], _ expected: [(Double, Double)], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.count == expected.count, "\(actual) vs \(expected)", sourceLocation: sourceLocation)
        for (a, e) in zip(actual, expected) {
            #expect(a.0.isApproximately(e.0), "start \(a.0) vs \(e.0)", sourceLocation: sourceLocation)
            #expect(a.1.isApproximately(e.1), "end \(a.1) vs \(e.1)", sourceLocation: sourceLocation)
        }
    }

    @Test func singleClickProducesWindowAroundIt() {
        expect(ranges(clicks: [5], duration: 20), [(4.7, 7.5)])
        let segment = AutoZoom.segments(clickTimes: [.seconds(5)], duration: .seconds(20), settings: settings)[0]
        #expect(segment.scale == 2)
        #expect(segment.focus == .followPointer)
    }

    @Test func clicksOnAnotherDisplayStartNoZoom() throws {
        let source = try Synthetic.source(
            duration: 20, pointer: [(0, 300, 200), (1.5, -1500, 400), (5.5, 300, 200)], clicks: [2, 6])
        let ranges = AutoZoom.segments(for: source).map { ($0.range.start.seconds, $0.range.end.seconds) }
        expect(ranges, [(5.7, 8.58)])
    }

    @Test func windowsWithinMergeGapMerge() {
        expect(ranges(clicks: [5, 10], duration: 20), [(4.7, 12.5)])
    }

    @Test func windowsBeyondMergeGapStaySeparate() {
        expect(ranges(clicks: [5, 10.5], duration: 20), [(4.7, 7.5), (10.2, 13)])
    }

    @Test func gapExactlyAtMergeGapMerges() {
        expect(ranges(clicks: [5, 10.3], duration: 20), [(4.7, 12.8)])
    }

    @Test func clicksInFinalSecondAreIgnoredAndEndsAreClamped() {
        expect(ranges(clicks: [9.2], duration: 10), [])
        expect(ranges(clicks: [8.5], duration: 10), [(8.2, 9.2)])
        expect(ranges(clicks: [8.99], duration: 10), [(8.69, 9.2)])
    }

    @Test func clickNearStartClampsToOneMillisecond() {
        expect(ranges(clicks: [0.1], duration: 10), [(0.001, 2.6)])
    }

    @Test func clickWhoseWindowCollapsesIsDropped() {
        var short = AutoZoomSettings()
        short.endMargin = .milliseconds(1500)
        let segments = AutoZoom.segments(clickTimes: [.seconds(8.9)], duration: .seconds(10), settings: short)
        #expect(segments.isEmpty, "window [8.6, 8.5) is empty so TimeRange's failable init drops it")
    }

    @Test func mouseUpExtendsTheWindowByThePressDuration() {
        expect(ranges(clicks: [5, 5.6], duration: 20), [(4.7, 8.1)])
    }

    @Test func unsortedClicksAreSorted() {
        expect(ranges(clicks: [10.5, 5], duration: 20), [(4.7, 7.5), (10.2, 13)])
    }

    @Test func generationIsReproducibleAndIdsDeriveFromTheRange() {
        let first = AutoZoom.segments(clickTimes: [.seconds(5), .seconds(10.5)], duration: .seconds(20), settings: settings)
        let second = AutoZoom.segments(clickTimes: [.seconds(10.5), .seconds(5)], duration: .seconds(20), settings: settings)
        #expect(first == second)
        #expect(first[0].id != first[1].id)
        #expect(first[0].id == AutoZoom.stableID(for: first[0].range))
        let same = AutoZoom.segments(clickTimes: [.seconds(5)], duration: .seconds(10), settings: settings)
        #expect(same[0].id == first[0].id, "same range in a different recording, same id")
        let clamped = AutoZoom.segments(clickTimes: [.seconds(5)], duration: .seconds(7), settings: settings)
        #expect(clamped[0].range.end == .seconds(6.2))
        #expect(clamped[0].id != first[0].id, "different end, different id")
    }

    @Test func fixtureClicksYieldTwoSegments() throws {
        let source = try SourceRecording.load(from: Fixture.directory(Fixture.fiveClicks))
        let segments = AutoZoom.segments(for: source)
        expect(segments.map { ($0.range.start.seconds, $0.range.end.seconds) }, [(0.7, 3.59), (6.2, 11.2)])
        #expect(AutoZoom.track(for: source).segments == segments)
    }

    /// "Merge repeatedly until stable", the observed algorithm, as an oracle.
    func naiveMerge(_ windows: [TimeRange], gap: RecordingTime) -> [TimeRange] {
        var intervals = windows
        var changed = true
        while changed {
            changed = false
            outer: for i in intervals.indices {
                for j in intervals.indices where j != i {
                    let a = intervals[i]
                    let b = intervals[j]
                    if max(a.start, b.start) - min(a.end, b.end) <= gap {
                        intervals[i] = TimeRange(start: min(a.start, b.start), end: max(a.end, b.end))!
                        intervals.remove(at: j)
                        changed = true
                        break outer
                    }
                }
            }
        }
        return intervals.sorted { $0.start < $1.start }
    }

    @Test func singlePassMergeMatchesRepeatedMergeOnRandomInput() {
        var generator = SeededGenerator(state: 0x5EED)
        for _ in 0..<1000 {
            let duration = Double.random(in: 3...60, using: &generator)
            let clicks = (0..<Int.random(in: 0...12, using: &generator)).map { _ in
                Double.random(in: 0...duration, using: &generator)
            }
            let times = clicks.map(RecordingTime.seconds)
            let sweep = AutoZoom.segments(clickTimes: times, duration: .seconds(duration), settings: settings).map(\.range)
            let windows = times
                .filter { $0 < .seconds(duration) - settings.ignoreClicksInFinal }
                .compactMap {
                    TimeRange(
                        start: max($0 - settings.windowBefore, .milliseconds(1)),
                        end: min($0 + settings.windowAfter, .seconds(duration) - settings.endMargin))
                }
            #expect(sweep == naiveMerge(windows, gap: settings.mergeGap), "clicks \(clicks) duration \(duration)")
        }
    }
}

struct ZoomTrackSpec {
    func segment(_ start: Double, _ end: Double, scale: Double = 2) -> ZoomSegment {
        ZoomSegment(range: TimeRange(start: .seconds(start), end: .seconds(end))!, scale: scale, focus: .followPointer)
    }

    @Test func rejectsOverlaps() {
        let a = segment(1, 4)
        let b = segment(3, 6)
        #expect(throws: ZoomTrackError.overlap(a.id, b.id)) { try ZoomTrack(validating: [b, a]) }
    }

    @Test func acceptsTouchingSegmentsAndSortsThem() throws {
        let a = segment(1, 4)
        let b = segment(4, 6)
        let track = try ZoomTrack(validating: [b, a])
        #expect(track.segments == [a, b])
    }

    @Test func rejectsScaleBelowOne() {
        let a = segment(1, 4, scale: 0.5)
        #expect(throws: ZoomTrackError.scaleBelowOne(a.id)) { try ZoomTrack(validating: [a]) }
    }

    @Test func emptyIsValid() throws {
        #expect(try ZoomTrack(validating: []) == .empty)
    }
}
