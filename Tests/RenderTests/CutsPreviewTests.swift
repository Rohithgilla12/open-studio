import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import Render
import Timeline

/// The preview over a frame-coded take: frame i shows a white bar at x = i * 14, so the pixel at
/// (i * 14 + 5, 100) says which source frame is up.
@MainActor
struct CutsPreviewSpec {
    static func isWhite(_ p: (red: Int, green: Int, blue: Int)?) -> Bool { p.map { $0.red > 200 && $0.green > 200 && $0.blue > 200 } ?? false }

    func shows(_ tap: Tap, frame: Int, at output: Double, in preview: PreviewPlayer) async -> Bool {
        await tap.wait(.seconds(10)) {
            abs(OutputTime(compositionTime: preview.player.currentTime()).seconds - output) < 0.001
                && Self.isWhite(tap.pixel(x: frame * 14 + 5, y: 100, at: preview.player.currentTime()))
        } != nil
    }

    /// Catches a cut edit reaching the same item (which would play the removed range), and a
    /// landing that keeps the output time instead of the recording instant under the playhead.
    @Test func aCutReplacesTheItemAndLandsOnTheJoinWhileAPictureEditKeepsIt() async throws {
        let take = try await CutsRenderSpec.codedTake()
        defer { try? FileManager.default.removeItem(at: take) }
        var project = try CutsRenderSpec.project(take, cuts: [])
        let preview = try await PreviewPlayer(project: project)
        let first = preview.item
        var tap = Tap(first)
        try await tap.ready(first)
        preview.scrub(to: .seconds(1))
        #expect(await shows(tap, frame: 10, at: 1, in: preview), "frame 10 at output 1 s before the cut")

        let composition = first.videoComposition
        project.edits.style.background = .solid(RGBColor(red: 0, green: 1, blue: 0))
        preview.show(project)
        #expect(await tap.wait(.seconds(10)) { first.videoComposition !== composition } != nil)
        #expect(preview.item === first, "a picture edit swaps the composition on the same item")

        project.edits.cuts = try Cuts(validating: [CutsRenderSpec.cut(0.5, 1.5)], within: project.source.duration)
        preview.show(project)
        #expect(await tap.wait(.seconds(10)) { preview.item !== first } != nil, "a cut replaces the item")
        tap = Tap(preview.item)
        try await tap.ready(preview.item)
        #expect(await shows(tap, frame: 15, at: 0.5, in: preview), "recording 1 s was cut, so the playhead lands on the join: output 0.5 s, frame 15")
        #expect(preview.lastError == nil)
    }

    /// Catches a drag that rebuilds per step, or one that leaves the uncut take showing: the
    /// source item is swapped in once, seeks follow, and `show` brings the edit back.
    @Test func showSourceScrubsTheUncutTakeOnceAndShowReturnsToTheEdit() async throws {
        let take = try await CutsRenderSpec.codedTake()
        defer { try? FileManager.default.removeItem(at: take) }
        let project = try CutsRenderSpec.project(take, cuts: [CutsRenderSpec.cut(0.5, 1.5)])
        let preview = try await PreviewPlayer(project: project)
        let edited = preview.item
        try await Tap(edited).ready(edited)

        preview.showSource(at: .seconds(1))
        let source = preview.item
        #expect(source !== edited)
        let tap = Tap(source)
        try await tap.ready(source)
        #expect(await shows(tap, frame: 10, at: 1, in: preview), "a frame inside the cut, visible only on the uncut take")
        preview.showSource(at: .seconds(1.2))
        #expect(preview.item === source, "the next step is a seek, not a swap")
        #expect(await shows(tap, frame: 12, at: 1.2, in: preview))

        preview.show(project)
        #expect(await tap.wait(.seconds(10)) { preview.item !== source } != nil, "show returns to the edited item")
        let back = Tap(preview.item)
        try await back.ready(preview.item)
        #expect(await shows(back, frame: 15, at: 0.5, in: preview), "recording 1.2 s is inside the cut, so it lands on the join")
    }

    /// Catches a tick converted with the wrong map: every playhead carries the recording instant
    /// its output time shows, and none lies inside the cut.
    @Test func playheadTicksCarryBothClocks() async throws {
        let take = try await CutsRenderSpec.codedTake()
        defer { try? FileManager.default.removeItem(at: take) }
        let project = try CutsRenderSpec.project(take, cuts: [CutsRenderSpec.cut(0.5, 1.5)])
        let preview = try await PreviewPlayer(project: project)
        let tap = Tap(preview.item)
        try await tap.ready(preview.item)
        let seen = Seen()
        let collector = Task { @MainActor in
            for await playhead in preview.playhead() { seen.append(playhead) }
        }
        preview.play()
        let reachedEnd = await tap.wait(.seconds(15)) { seen.ticks.last.map { $0.output >= .seconds(2) } ?? false }
        collector.cancel()
        preview.pause()
        let ticks = seen.ticks
        #expect(reachedEnd != nil, "\(ticks.map(\.output.seconds))")
        #expect(ticks.count >= 2)
        let map = project.timeline.map
        for tick in ticks {
            #expect(tick.recording == map.recording(at: tick.output))
            #expect(!(RecordingTime.seconds(0.5)..<RecordingTime.seconds(1.5)).contains(tick.recording), "\(tick)")
        }
        #expect(ticks.contains { $0.recording >= .seconds(1.5) }, "playback crossed the cut")
    }

    final class Seen: Sendable {
        private let state = Mutex<[Playhead]>([])
        var ticks: [Playhead] { state.withLock { $0 } }
        func append(_ t: Playhead) { state.withLock { $0.append(t) } }
    }
}
