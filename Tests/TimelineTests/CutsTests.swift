import Foundation
import Testing
@testable import Timeline

func cut(_ start: Double, _ end: Double, id: UUID = UUID()) -> Cut {
    Cut(id: id, range: TimeRange(start: .seconds(start), end: .seconds(end))!)
}

func range(_ start: Double, _ end: Double) -> TimeRange { TimeRange(start: .seconds(start), end: .seconds(end))! }

struct CutsSpec {
    static let duration = RecordingTime.seconds(10)

    func cuts(_ cuts: [Cut]) throws -> Cuts { try Cuts(validating: cuts, within: Self.duration) }

    @Test func validationSortsAndKeepsTheInvariants() throws {
        let later = cut(5, 6)
        let earlier = cut(1, 2)
        let valid = try cuts([later, earlier])
        #expect(valid.cuts.map(\.id) == [earlier.id, later.id])
        #expect(valid.keptSpans(within: Self.duration) == [range(0, 1), range(2, 5), range(6, 10)])
        #expect(valid.trimmed(within: Self.duration) == RecordingTime.zero...Self.duration)
    }

    @Test func aCutThatLeavesNothingIsRefused() throws {
        #expect(throws: CutsError.nothingKept) { try cuts([cut(0, 10)]) }
        #expect(Cuts.none.cutting(range(0, 10), within: Self.duration) == nil)
        #expect(Cuts.none.cutting(range(0.1, 9.9), within: Self.duration) == nil, "the head and tail slivers are absorbed, leaving nothing")
        let middle = try cuts([cut(4, 6)])
        #expect(middle.cutting(range(0, 4), within: Self.duration)?.cuts.cuts.map(\.range) == [range(0, 6)])
        #expect(middle.cutting(range(0, 10), within: Self.duration) == nil)
    }

    @Test func eachRejectionNamesItsCut() throws {
        let outside = cut(9, 11)
        #expect(throws: CutsError.outsideRecording(outside.id)) { try cuts([outside]) }
        let a = cut(1, 3), b = cut(2, 4)
        #expect(throws: CutsError.overlap(a.id, b.id)) { try cuts([b, a]) }
        let shared = UUID()
        #expect(throws: CutsError.duplicateID(shared)) { try cuts([cut(1, 2, id: shared), cut(5, 6, id: shared)]) }
        let first = cut(1, 2), second = cut(2.1, 3)
        #expect(throws: CutsError.keptTooShort(after: first.id)) { try cuts([first, second]) }
        #expect(throws: CutsError.keptTooShort(after: nil)) { try cuts([cut(0.1, 2)]) }
        #expect(throws: CutsError.keptTooShort(after: first.id)) { try cuts([first, cut(2, 3)]) }
        let last = cut(5, 9.9)
        #expect(throws: CutsError.keptTooShort(after: last.id)) { try cuts([last]) }
        _ = try cuts([cut(0, 2), cut(2.2, 3), cut(9.8, 10)])
    }

    @Test func nearbyCutsMerge() throws {
        let a = cut(1, 2), b = cut(2.05, 3)
        let (merged, id) = try #require(Cuts.none.cutting(a.range, within: Self.duration))
        #expect(merged.cuts == [a].map { Cut(id: id, range: $0.range) })
        let (both, mergedID) = try #require(merged.cutting(b.range, within: Self.duration))
        #expect(mergedID == id, "the earlier id survives")
        #expect(both.cuts.map(\.range) == [range(1, 3)])
        let far = try #require(both.cutting(range(5, 6), within: Self.duration))
        #expect(far.cuts.cuts.map(\.range) == [range(1, 3), range(5, 6)])
        #expect(far.id != id)
    }

    @Test func cuttingAbsorbsSliversAtTheEnds() {
        let head = Cuts.none.cutting(range(0.1, 2), within: Self.duration)
        #expect(head?.cuts.cuts.map(\.range) == [range(0, 2)])
        let tail = Cuts.none.cutting(range(5, 9.95), within: Self.duration)
        #expect(tail?.cuts.cuts.map(\.range) == [range(5, 10)])
        let beyond = Cuts.none.cutting(range(-1, 1), within: Self.duration)
        #expect(beyond?.cuts.cuts.map(\.range) == [range(0, 1)])
    }

    @Test func editsClampKeptSpansToTheMinimum() throws {
        let middle = try cuts([cut(3, 4)])
        let trimmed = middle.trimming(.start, to: .seconds(2.9), within: Self.duration)
        #expect(trimmed.cuts.map(\.range) == [range(0, 2.8), range(3, 4)])
        let tailTrimmed = middle.trimming(.end, to: .seconds(4.1), within: Self.duration)
        #expect(tailTrimmed.cuts.map(\.range) == [range(3, 4), range(4.2, 10)])
        let whole = Cuts.none.trimming(.start, to: .seconds(99), within: Self.duration)
        #expect(whole.cuts.map(\.range) == [range(0, 9.8)])
        #expect(whole.trimmed(within: Self.duration) == RecordingTime.seconds(9.8)...Self.duration)

        let resized = middle.resizing(middle.cuts[0].id, edge: .start, to: .seconds(0.1), within: Self.duration)
        #expect(resized.cuts.map(\.range) == [range(0, 4)], "an edge near the start becomes a trim")
        let second = try cuts([cut(1, 2), cut(3, 4)])
        let crowded = second.resizing(second.cuts[1].id, edge: .start, to: .seconds(0.5), within: Self.duration)
        #expect(crowded.cuts.map(\.range) == [range(1, 2), range(2.2, 4)])
        let tail = second.resizing(second.cuts[1].id, edge: .end, to: .seconds(9.9), within: Self.duration)
        #expect(tail.cuts.map(\.range) == [range(1, 2), range(3, 10)])
        let inverted = second.resizing(second.cuts[0].id, edge: .end, to: .seconds(0.5), within: Self.duration)
        #expect(inverted == second, "an edge dragged past the other edge is ignored")
    }

    @Test func trimmingBackToTheEdgeRemovesTheTrim() throws {
        let trimmed = Cuts.none.trimming(.start, to: .seconds(1), within: Self.duration)
        let id = trimmed.cuts[0].id
        #expect(trimmed.trimming(.start, to: .seconds(2), within: Self.duration).cuts.map(\.id) == [id], "a moved trim keeps its id")
        #expect(trimmed.trimming(.start, to: .zero, within: Self.duration) == .none)
        #expect(trimmed.trimming(.start, to: .seconds(-1), within: Self.duration) == .none)
        let tail = Cuts.none.trimming(.end, to: .seconds(9), within: Self.duration)
        #expect(tail.cuts.map(\.range) == [range(9, 10)])
        #expect(tail.trimming(.end, to: Self.duration, within: Self.duration) == .none)
    }

    @Test func restoreIsExact() throws {
        let original = try cuts([cut(1, 2), cut(5, 6)])
        let (more, id) = try #require(original.cutting(range(7, 8), within: Self.duration))
        #expect(more.restoring(id) == original)
        #expect(original.restoring(UUID()) == original)
    }

    @Test func everyTotalEditKeepsTheValidatingInvariants() throws {
        var generator = SeededGenerator(state: 7)
        var cuts = Cuts.none
        for _ in 0..<400 {
            let a = Double.random(in: -1...11, using: &generator)
            let b = Double.random(in: -1...11, using: &generator)
            let edited: Cuts
            switch Int.random(in: 0..<4, using: &generator) {
            case 0:
                guard let range = TimeRange(start: .seconds(min(a, b)), end: .seconds(max(a, b))) else { continue }
                edited = cuts.cutting(range, within: Self.duration)?.cuts ?? cuts
            case 1:
                edited = cuts.trimming(Bool.random(using: &generator) ? .start : .end, to: .seconds(a), within: Self.duration)
            case 2:
                guard let id = cuts.cuts.randomElement(using: &generator)?.id else { continue }
                edited = cuts.resizing(id, edge: Bool.random(using: &generator) ? .start : .end, to: .seconds(a), within: Self.duration)
            default:
                guard let id = cuts.cuts.randomElement(using: &generator)?.id else { continue }
                edited = cuts.restoring(id)
            }
            #expect(throws: Never.self, "\(edited.cuts.map(\.range))") { try Cuts(validating: edited.cuts, within: Self.duration) }
            cuts = edited
        }
    }
}

struct TimeMapSpec {
    static let duration = RecordingTime.seconds(10)

    /// Head trim [0, 1), cut [4, 6), tail trim [9, 10): kept [1, 4) and [6, 9), output 6 s.
    static func map() throws -> TimeMap {
        TimeMap(cuts: try Cuts(validating: [cut(0, 1), cut(4, 6), cut(9, 10)], within: duration), duration: duration)
    }

    @Test func segmentsLayTheKeptSpansEndToEnd() throws {
        let map = try Self.map()
        #expect(map.segments.map(\.source) == [range(1, 4), range(6, 9)])
        #expect(map.segments.map(\.outputStart) == [.zero, .seconds(3)])
        #expect(map.duration == .seconds(6))
        #expect(map.joins == [.seconds(3)])
        #expect(map.trims(within: Self.duration) == (true, true))
        let identity = TimeMap.identity(duration: Self.duration)
        #expect(identity.segments.map(\.source) == [range(0, 10)])
        #expect(identity.joins.isEmpty)
        #expect(identity.trims(within: Self.duration) == (false, false))
    }

    @Test func joinShowsTheFirstKeptInstantAfterTheCut() throws {
        let map = try Self.map()
        #expect(map.recording(at: .seconds(3)) == .seconds(6))
        #expect(map.recording(at: OutputTime(microseconds: 2_999_999)) == RecordingTime(microseconds: 3_999_999))
        #expect(map.recording(at: .zero) == .seconds(1))
        #expect(map.recording(at: .seconds(6)) == .seconds(9), "the end of the output is the end of the last kept span")
        #expect(map.recording(at: .seconds(-1)) == .seconds(1))
        #expect(map.recording(at: .seconds(99)) == .seconds(9))
    }

    @Test func roundTripsEveryKeptInstantExactly() throws {
        let map = try Self.map()
        for microseconds in stride(from: Int64(0), through: Self.duration.microseconds, by: 997) {
            let r = RecordingTime(microseconds: microseconds)
            let kept = (1_000_000..<4_000_000).contains(microseconds) || (6_000_000..<9_000_000).contains(microseconds)
            if let o = map.output(at: r) {
                #expect(kept, "\(microseconds) µs is inside a cut")
                #expect(map.recording(at: o) == r)
                #expect(map.output(collapsing: r) == o)
            } else {
                #expect(!kept, "\(microseconds) µs is kept")
            }
        }
        let identity = TimeMap.identity(duration: Self.duration)
        #expect(identity.output(at: .seconds(2.5)) == .seconds(2.5))
        #expect(identity.recording(at: .seconds(2.5)) == .seconds(2.5))
    }

    @Test func collapsingIsMonotoneAndLandsOnTheJoin() throws {
        let map = try Self.map()
        #expect(map.output(collapsing: .zero) == .zero)
        #expect(map.output(collapsing: .seconds(0.5)) == .zero, "inside the head trim")
        #expect(map.output(collapsing: .seconds(5)) == .seconds(3), "inside the cut: its join")
        #expect(map.output(collapsing: .seconds(4)) == .seconds(3))
        #expect(map.output(collapsing: .seconds(9.5)) == .seconds(6), "inside the tail trim")
        #expect(map.output(collapsing: Self.duration) == .seconds(6))
        var previous = OutputTime.zero
        for microseconds in stride(from: Int64(0), through: Self.duration.microseconds, by: 1_003) {
            let o = map.output(collapsing: RecordingTime(microseconds: microseconds))
            #expect(o >= previous)
            previous = o
        }
    }
}
