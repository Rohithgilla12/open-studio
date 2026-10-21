import AVFoundation
import CoreVideo
import Foundation
import Synchronization
import Testing
@testable import Render
import Timeline

/// Samples what an AVPlayer would display, headless, through an AVPlayerItemVideoOutput.
@MainActor
final class Tap {
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])

    init(_ item: AVPlayerItem) { item.add(output) }

    /// (r, g, b) of the canvas pixel at a top-left position in the frame the player shows now.
    func pixel(x: Int, y: Int, at time: CMTime) -> (red: Int, green: Int, blue: Int)? {
        guard let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let p = base + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (Int(p[2]), Int(p[1]), Int(p[0]))
    }

    /// Polls until `predicate` holds or `timeout` passes. Returns the wait in milliseconds, or nil.
    func wait(_ timeout: Duration = .seconds(5), until predicate: () -> Bool) async -> Int? {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if predicate() { return Int((ContinuousClock.now - start) / .milliseconds(1)) }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// Aborts the test if the item never becomes playable, so no later await can hang on it.
    func ready(_ item: AVPlayerItem) async throws {
        // Under the full parallel suite the GPU and decoders are shared with the export tests.
        let waited = await wait(.seconds(20)) { item.status != .unknown }
        try #require(waited != nil, "item status still unknown after 20 s")
        try #require(item.status == .readyToPlay, "item failed: \(String(describing: item.error))")
    }
}

func isBlue(_ p: (red: Int, green: Int, blue: Int)?) -> Bool { p.map { $0.blue > 200 && $0.red < 60 && $0.green < 60 } ?? false }
func isGreen(_ p: (red: Int, green: Int, blue: Int)?) -> Bool { p.map { $0.green > 200 && $0.red < 60 && $0.blue < 60 } ?? false }

func style(_ color: RGBColor) -> Style {
    Style(background: .solid(color), padding: 0.08, cornerRadius: 0.02, shadow: .none)
}

@MainActor
struct PreviewSpec {
    /// Open question 1, measured: after a paused player shows a frame, swap the item's video
    /// composition for one with a different background and watch the output without seeking.
    @Test func harnessPausedPlayerAndACompositionSwap() async throws {
        let take = try await Fixture.take(color: (255, 0, 0))
        defer { try? FileManager.default.removeItem(at: take) }
        var project = try Project.open(take)
        project.edits.style = style(RGBColor(red: 0, green: 0, blue: 1))
        let movie = MovieComposition(media: try await SourceMedia.load(project.source), map: project.timeline.map)
        let blue = try RenderScene.make(project: project, format: project.edits.format, reusing: nil)
        let item = AVPlayerItem(asset: movie.asset)
        item.videoComposition = movie.videoComposition(scene: blue, frameRate: .fps60)
        let player = AVPlayer(playerItem: item)
        let tap = Tap(item)

        try await tap.ready(item)
        await withCheckedContinuation { c in player.seek(to: CMTime(value: 1, timescale: 1), toleranceBefore: .zero, toleranceAfter: .zero) { _ in c.resume() } }
        let t = player.currentTime()
        let shown = await tap.wait { isBlue(tap.pixel(x: 10, y: 10, at: t)) }
        #expect(shown != nil, "the paused player never showed the first composition")

        project.edits.style = style(RGBColor(red: 0, green: 1, blue: 0))
        let green = try RenderScene.make(project: project, format: project.edits.format, reusing: blue)
        item.videoComposition = movie.videoComposition(scene: green, frameRate: .fps60)
        // No pull for 300 ms, so a new frame here was composed on AVFoundation's initiative.
        try await Task.sleep(for: .milliseconds(300))
        let unprompted = tap.output.hasNewPixelBuffer(forItemTime: player.currentTime())
        let recomposed = await tap.wait(.seconds(2)) { isGreen(tap.pixel(x: 10, y: 10, at: player.currentTime())) }
        print("HARNESS paused swap without seek: new frame unprompted after 300 ms: \(unprompted); green frame: \(recomposed.map { "after a further \($0) ms" } ?? "none within 2 s")")
        #expect(unprompted, "the paused item did not compose a new frame on its own")
        #expect(recomposed != nil)

        await withCheckedContinuation { c in player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { _ in c.resume() } }
        let afterSeek = await tap.wait(.seconds(2)) { isGreen(tap.pixel(x: 10, y: 10, at: player.currentTime())) }
        print("HARNESS paused swap then zero-tolerance seek: \(afterSeek.map { "recomposed after \($0) ms" } ?? "no new frame within 2 s")")
        #expect(afterSeek != nil)
    }

    @Test func showWhilePausedDisplaysTheEdit() async throws {
        let take = try await Fixture.take(color: (255, 0, 0))
        defer { try? FileManager.default.removeItem(at: take) }
        var project = try Project.open(take)
        project.edits.style = style(RGBColor(red: 0, green: 0, blue: 1))
        let preview = try await PreviewPlayer(project: project)
        let tap = Tap(preview.item)
        try await tap.ready(preview.item)
        preview.scrub(to: .seconds(1))
        // The background pixel is blue at every time, so wait for the seek itself before looking at it.
        #expect(await tap.wait { abs(OutputTime(compositionTime: preview.player.currentTime()).seconds - 1) < 0.001 } != nil)
        #expect(await tap.wait { isBlue(tap.pixel(x: 10, y: 10, at: preview.player.currentTime())) } != nil)

        project.edits.style = style(RGBColor(red: 0, green: 1, blue: 0))
        preview.show(project)
        let shown = await tap.wait { isGreen(tap.pixel(x: 10, y: 10, at: preview.player.currentTime())) }
        #expect(shown != nil, "the edit never reached the paused preview")
        #expect(preview.lastError == nil)
        #expect(abs(OutputTime(compositionTime: preview.player.currentTime()).seconds - 1) < 0.001)
    }

    @Test func scrubChasesTheLatestTime() async throws {
        let take = try await Fixture.take(color: (255, 0, 0))
        defer { try? FileManager.default.removeItem(at: take) }
        let preview = try await PreviewPlayer(project: try Project.open(take))
        let tap = Tap(preview.item)
        try await tap.ready(preview.item)
        for ms in stride(from: 100, through: 1500, by: 100) { preview.scrub(to: .milliseconds(Int64(ms))) }
        #expect(await tap.wait { abs(OutputTime(compositionTime: preview.player.currentTime()).seconds - 1.5) < 0.001 } != nil)
    }

    @Test func playheadStreamsWhilePlaying() async throws {
        let take = try await Fixture.take(color: (255, 0, 0))
        defer { try? FileManager.default.removeItem(at: take) }
        let preview = try await PreviewPlayer(project: try Project.open(take))
        let tap = Tap(preview.item)
        try await tap.ready(preview.item)
        // The observer coalesces under load (measured: three callbacks over a 2 s item while the
        // export tests held the GPU), so the contract is monotonic updates that reach the end.
        let seen = Seen()
        let collector = Task { @MainActor in
            for await t in preview.playhead() { seen.append(t) }
        }
        preview.play()
        let reachedEnd = await tap.wait(.seconds(10)) { seen.times.last.map { $0 >= .seconds(1.9) } ?? false }
        collector.cancel()
        preview.pause()
        let times = seen.times
        #expect(reachedEnd != nil, "playhead reached \(times.map(\.seconds)), rate \(preview.player.rate), item \(String(describing: preview.item.error))")
        #expect(times.count >= 2)
        #expect(zip(times, times.dropFirst()).allSatisfy { $0 <= $1 }, "\(times.map(\.seconds))")
        #expect(preview.player.rate == 0)
    }

    final class Seen: Sendable {
        private let state = Mutex<[RecordingTime]>([])
        var times: [RecordingTime] { state.withLock { $0 } }
        var count: Int { state.withLock { $0.count } }
        func append(_ t: RecordingTime) { state.withLock { $0.append(t) } }
    }
}
