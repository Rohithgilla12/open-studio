import Foundation
import Testing
@testable import Timeline

/// Fixture: Fixtures/recordings/five-seconds.osrec, a real 5 s take with three clicks,
/// committed with `display.mov` removed (Timeline never opens it).
private let fixtureURL = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/recordings/five-seconds.osrec")

@Suite struct SamplerDeterminismTests {
    @Test func sameValueRegardlessOfQueryOrder() throws {
        // TODO:
        // let take = try Take.load(from: fixtureURL)
        // let sampler = Sampler(project: .automatic(take: take))
        // let times = stride(from: 0, to: take.duration.seconds, by: 1/60).map(Duration.seconds)
        // let forward = times.map(sampler.frame(at:))
        // let shuffled = times.shuffled(); let backward = Dictionary(uniqueKeysWithValues: shuffled.map { ($0, sampler.frame(at: $0)) })
        // #expect(forward == times.map { backward[$0]! })
        fatalError("not implemented")
    }

    @Test func sameValueAcrossThreads() async throws {
        // TODO: query the same t from a TaskGroup of 8 tasks; all results equal
        fatalError("not implemented")
    }
}

@Suite struct AutoZoomTests {
    @Test func windowsMergeWhenGapIsAtMost2500ms() {
        // TODO: clicks at 1.0 s and 5.9 s (gap after merge threshold: 1.0+2.5=3.5, 5.9-0.3=5.6, gap 2.1 s) -> one segment
        //       clicks at 1.0 s and 6.5 s -> two segments
        fatalError("not implemented")
    }

    @Test func clicksNearTheEndAreIgnored() {
        fatalError("not implemented")
    }
}

@Suite struct TakeParsingTests {
    @Test func recoveredTakeWithoutFinishLoads() throws {
        // TODO: build from literals with finish: nil and truncatedTail: true -> integrity == .recovered(true)
        fatalError("not implemented")
    }

    @Test func unknownCursorIDIsRejected() {
        fatalError("not implemented")
    }
}
