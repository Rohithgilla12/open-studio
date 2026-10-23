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

    /// Catches a style edit that decided "same map" before its scene build and found the uncut
    /// item up after it: a trim drag that starts during the build must not trap, and the next
    /// `show` leaves the edited item up, landed on the join.
    @Test func aSourceScrubDuringAStyleEditsBuildDoesNotTrap() async throws {
        let take = try await CutsRenderSpec.codedTake()
        defer { try? FileManager.default.removeItem(at: take) }
        var project = try CutsRenderSpec.project(take, cuts: [CutsRenderSpec.cut(0.5, 1.5)])
        let preview = try await PreviewPlayer(project: project)
        let edited = preview.item
        try await Tap(edited).ready(edited)

        project.edits.style.background = .solid(RGBColor(red: 0, green: 1, blue: 0))
        preview.show(project)
        // Lets the edit run as far as its detached scene build before the drag begins.
        await Task.yield()
        preview.showSource(at: .seconds(1))
        let source = preview.item
        #expect(source !== edited)
        preview.show(project)
        #expect(await Tap(edited).wait(.seconds(10)) { preview.item !== source } != nil, "show returns to an edited item")
        let back = Tap(preview.item)
        try await back.ready(preview.item)
        #expect(await shows(back, frame: 15, at: 0.5, in: preview), "recording 1 s is inside the cut, so it lands on the join")
        #expect(preview.lastError == nil)
    }

    /// Catches a build in flight when a drag begins swapping the uncut item back out: the drag
    /// keeps scrubbing the uncut take until its own `show`, which brings the edit back.
    @Test func aDragThatBeginsDuringABuildKeepsTheUncutItemUp() async throws {
        let take = try await CutsRenderSpec.codedTake()
        defer { try? FileManager.default.removeItem(at: take) }
        var project = try CutsRenderSpec.project(take, cuts: [CutsRenderSpec.cut(0.5, 1.5)])
        let preview = try await PreviewPlayer(project: project)
        let edited = preview.item
        try await Tap(edited).ready(edited)

        project.edits.style.background = .solid(RGBColor(red: 0, green: 1, blue: 0))
        preview.show(project)
        // Lets the edit run as far as its detached scene build before the drag begins.
        await Task.yield()
        #expect(preview.applyTask != nil, "the style edit is still building")
        preview.showSource(at: .seconds(1))
        let source = preview.item
        let tap = Tap(source)
        try await tap.ready(source)
        #expect(await tap.wait(.seconds(10)) { preview.applyTask == nil } != nil)
        #expect(preview.item === source, "the finished build leaves the drag's item up")
        #expect(await shows(tap, frame: 10, at: 1, in: preview), "still on the frame the drag scrubbed to, inside the cut")

        preview.show(project)
        #expect(await tap.wait(.seconds(10)) { preview.item !== source } != nil, "show returns to the edited item")
        let back = Tap(preview.item)
        try await back.ready(preview.item)
        #expect(await shows(back, frame: 15, at: 0.5, in: preview))
        #expect(preview.lastError == nil)
    }

    /// Catches a tick from the replaced item read with the new map, and the new item's first
    /// tick at 0 before its landing seek: a cut applied during playback keeps every tick on the
    /// map of the item that produced it. The expectation is the cut's own arithmetic (output
    /// before 0.5 s is the recording; after it, the recording less the removed second), not the
    /// map the player converts with.
    @Test func ticksAcrossACutAppliedDuringPlaybackNeverFlashToTheStart() async throws {
        let take = try await CutsRenderSpec.codedTake()
        defer { try? FileManager.default.removeItem(at: take) }
        var project = try CutsRenderSpec.project(take, cuts: [])
        let preview = try await PreviewPlayer(project: project)
        let first = preview.item
        let tap = Tap(first)
        try await tap.ready(first)
        let seen = Seen()
        let collector = Task { @MainActor in
            for await playhead in preview.playhead() { seen.append(playhead) }
        }
        preview.play()
        #expect(await tap.wait(.seconds(15)) { seen.ticks.last.map { $0.output >= .seconds(0.9) } ?? false } != nil)
        project.edits.cuts = try Cuts(validating: [CutsRenderSpec.cut(0.5, 1.5)], within: project.source.duration)
        preview.show(project)
        #expect(await tap.wait(.seconds(10)) { preview.item !== first } != nil, "the cut replaces the item")
        // A tick that reads the cut map, a second of playback past the join: the uncut item's
        // ticks can reach any output time on their own while the swap is still being built.
        let crossed = await tap.wait(.seconds(15)) {
            seen.ticks.last.map { $0.recording.microseconds == $0.output.microseconds + 1_000_000 && $0.output >= .seconds(1.5) } ?? false
        }
        collector.cancel()
        preview.pause()
        let ticks = seen.ticks
        #expect(crossed != nil, "\(ticks.map(\.output.seconds))")

        var split = 0
        while split < ticks.count, ticks[split].recording.microseconds == ticks[split].output.microseconds,
            split == 0 || ticks[split].output >= ticks[split - 1].output
        {
            split += 1
        }
        #expect(split > 0 && ticks[split - 1].output >= .seconds(0.9), "ticks before the swap read the uncut take")
        #expect(split < ticks.count, "ticks after the swap")
        for tick in ticks[split...] {
            #expect(tick.output >= .seconds(0.5), "a tick at the new item's start before it landed on the join: \(tick)")
            let removed: Int64 = tick.output.microseconds < 500_000 ? 0 : 1_000_000
            #expect(tick.recording.microseconds == tick.output.microseconds + removed, "\(tick)")
        }
    }

    /// Catches an edit reading the player's time while the previous swap's landing seek is still
    /// in flight: an undo right after a cut lands where the cut had landed, not at 0.
    @Test func anEditDuringTheLandingSeekLandsWhereTheLastEditWasHeading() async throws {
        let take = try await CutsRenderSpec.codedTake()
        defer { try? FileManager.default.removeItem(at: take) }
        let uncut = try CutsRenderSpec.project(take, cuts: [])
        var cut = uncut
        cut.edits.cuts = try Cuts(validating: [CutsRenderSpec.cut(0.5, 1.5)], within: uncut.source.duration)
        let preview = try await PreviewPlayer(project: uncut)
        let first = preview.item
        let tap = Tap(first)
        try await tap.ready(first)
        preview.scrub(to: .seconds(1))
        #expect(await shows(tap, frame: 10, at: 1, in: preview))

        preview.show(cut)
        #expect(await tap.wait(.seconds(10)) { preview.item !== first } != nil)
        let second = preview.item
        // Inside the landing seek, which the measured first replacement gives 230 ms.
        preview.show(uncut)
        #expect(await tap.wait(.seconds(10)) { preview.item !== second } != nil, "the undo replaces the item again")
        let back = Tap(preview.item)
        try await back.ready(preview.item)
        #expect(await shows(back, frame: 15, at: 1.5, in: preview), "the cut landed on the join, recording 1.5 s; the undo stays there")
    }

    final class Seen: Sendable {
        private let state = Mutex<[Playhead]>([])
        var ticks: [Playhead] { state.withLock { $0 } }
        func append(_ t: Playhead) { state.withLock { $0.append(t) } }
    }
}
