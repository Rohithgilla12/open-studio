import Foundation
import Testing
@testable import Timeline

struct ZoomEditSpec {
    let duration = RecordingTime.seconds(20)
    let minimum = ZoomTrack.minimumSegmentDuration

    func segment(_ start: Double, _ end: Double, scale: Double = 2) -> ZoomSegment {
        ZoomSegment(range: TimeRange(start: .seconds(start), end: .seconds(end))!, scale: scale, focus: .followPointer)
    }

    /// [2, 4), [6, 8), [12, 15).
    var three: (ZoomTrack, ZoomSegment, ZoomSegment, ZoomSegment) {
        get throws {
            let a = segment(2, 4), b = segment(6, 8), c = segment(12, 15)
            return (try ZoomTrack(validating: [a, b, c]), a, b, c)
        }
    }

    @Test func removingDropsTheSegmentAndIgnoresUnknownIDs() throws {
        let (track, a, b, c) = try three
        #expect(track.removing(b.id).segments == [a, c])
        #expect(track.removing(UUID()) == track)
    }

    @Test func moveClampsBetweenNeighboursAndKeepsDuration() throws {
        let (track, _, b, _) = try three
        let late = track.moving(b.id, toStart: .seconds(11.5), within: duration)
        #expect(late.segments[1].range == TimeRange(start: .seconds(10), end: .seconds(12)))
        let early = track.moving(b.id, toStart: .seconds(1), within: duration)
        #expect(early.segments[1].range == TimeRange(start: .seconds(4), end: .seconds(6)))
        let free = track.moving(b.id, toStart: .seconds(7), within: duration)
        #expect(free.segments[1].range == TimeRange(start: .seconds(7), end: .seconds(9)))
    }

    @Test func moveOfTheLastSegmentClampsToTheDuration() throws {
        let (track, _, _, c) = try three
        let moved = track.moving(c.id, toStart: .seconds(30), within: duration)
        #expect(moved.segments[2].range == TimeRange(start: .seconds(17), end: .seconds(20)))
    }

    @Test func moveThatCannotFitIsANoOp() throws {
        let track = try ZoomTrack(validating: [segment(0, 5), segment(5, 7), segment(7, 20)])
        #expect(track.moving(track.segments[1].id, toStart: .seconds(1), within: duration) == track)
    }

    @Test func resizeKeepsMinimumDuration() throws {
        let (track, _, b, _) = try three
        let collapsedStart = track.resizing(b.id, edge: .start, to: .seconds(9), within: duration)
        #expect(collapsedStart.segments[1].range == TimeRange(start: .seconds(8) - minimum, end: .seconds(8)))
        let collapsedEnd = track.resizing(b.id, edge: .end, to: .seconds(1), within: duration)
        #expect(collapsedEnd.segments[1].range == TimeRange(start: .seconds(6), end: .seconds(6) + minimum))
    }

    @Test func resizeStopsAtTheNeighbours() throws {
        let (track, _, b, _) = try three
        let start = track.resizing(b.id, edge: .start, to: .seconds(0), within: duration)
        #expect(start.segments[1].range == TimeRange(start: .seconds(4), end: .seconds(8)))
        let end = track.resizing(b.id, edge: .end, to: .seconds(19), within: duration)
        #expect(end.segments[1].range == TimeRange(start: .seconds(6), end: .seconds(12)))
    }

    @Test func insertCentresOnTheTimeAndShrinksToTheGap() throws {
        let (track, _, _, _) = try three
        let (wide, id) = try #require(track.inserting(around: .seconds(10), length: .seconds(2), scale: 2, within: duration))
        #expect(wide.segments.first { $0.id == id }?.range == TimeRange(start: .seconds(9), end: .seconds(11)))
        #expect(wide.segments.map(\.range.start) == [.seconds(2), .seconds(6), .seconds(9), .seconds(12)])

        let (shrunk, shrunkID) = try #require(track.inserting(around: .seconds(5), length: .seconds(10), scale: 2, within: duration))
        #expect(shrunk.segments.first { $0.id == shrunkID }?.range == TimeRange(start: .seconds(4), end: .seconds(6)))

        let (shifted, shiftedID) = try #require(track.inserting(around: .seconds(0.1), length: .seconds(1), scale: 2, within: duration))
        #expect(shifted.segments.first { $0.id == shiftedID }?.range == TimeRange(start: .zero, end: .seconds(1)))
    }

    @Test func insertInsideASegmentOrATinyGapReturnsNil() throws {
        let (track, _, _, _) = try three
        #expect(track.inserting(around: .seconds(3), length: .seconds(1), scale: 2, within: duration) == nil)
        let tight = try ZoomTrack(validating: [segment(0, 5), segment(5.1, 20)])
        #expect(tight.inserting(around: .seconds(5.05), length: .seconds(1), scale: 2, within: duration) == nil)
    }

    @Test func updatingClampsScaleAndChangesFocus() throws {
        let (track, a, _, _) = try three
        let updated = track.updating(a.id, scale: 0.3, focus: .fixed(x: 0.5, y: 0.5))
        #expect(updated.segments[0].scale == 1)
        #expect(updated.segments[0].focus == .fixed(x: 0.5, y: 0.5))
        #expect(track.updating(a.id).segments[0] == a)
        #expect(track.updating(a.id, scale: .nan).segments[0].scale == 1)
    }

    @Test func everyEditResultPassesValidation() throws {
        var generator = SeededGenerator(state: 0x2004)
        for round in 0..<400 {
            let duration = RecordingTime.seconds(Double.random(in: 1...60, using: &generator))
            var track = randomTrack(within: duration, using: &generator)
            for step in 0..<12 {
                let before = track
                let id = track.segments.randomElement(using: &generator)?.id ?? UUID()
                let t = RecordingTime.seconds(Double.random(in: -5...(duration.seconds + 5), using: &generator))
                switch Int.random(in: 0..<5, using: &generator) {
                case 0: track = track.removing(id)
                case 1: track = track.moving(id, toStart: t, within: duration)
                case 2: track = track.resizing(id, edge: Bool.random(using: &generator) ? .start : .end, to: t, within: duration)
                case 3:
                    if let inserted = track.inserting(
                        around: t, length: .seconds(Double.random(in: 0...8, using: &generator)),
                        scale: Double.random(in: -1...3, using: &generator), within: duration)
                    {
                        track = inserted.track
                    }
                default: track = track.updating(id, scale: Double.random(in: -1...3, using: &generator))
                }
                let context = "round \(round) step \(step) before \(before.segments.map(\.range)) after \(track.segments.map(\.range))"
                #expect(try ZoomTrack(validating: track.segments) == track, Comment(rawValue: context))
                #expect(track.segments.allSatisfy { $0.range.start >= .zero && $0.range.end <= duration }, Comment(rawValue: context))
                #expect(Set(track.segments.map(\.id)).count == track.segments.count, Comment(rawValue: context))
            }
        }
    }

    /// Random non-overlapping segments, some shorter than the minimum, so edits meet tracks that
    /// an older generator or a hand-written file could produce.
    func randomTrack(within duration: RecordingTime, using generator: inout SeededGenerator) -> ZoomTrack {
        let count = Int.random(in: 0...6, using: &generator)
        let cuts = (0..<(count * 2)).map { _ in Double.random(in: 0...duration.seconds, using: &generator) }.sorted()
        var segments: [ZoomSegment] = []
        for pair in stride(from: 0, to: cuts.count, by: 2) {
            guard let range = TimeRange(start: .seconds(cuts[pair]), end: .seconds(cuts[pair + 1])) else { continue }
            segments.append(ZoomSegment(range: range, scale: Double.random(in: 1...3, using: &generator), focus: .followPointer))
        }
        return try! ZoomTrack(validating: segments)
    }
}
