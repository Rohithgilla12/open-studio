import AVFoundation
import Foundation
import Testing
@testable import Render
import Timeline

struct ExportSpec {
    @Test func exportWritesEveryFrameAtTheConstantRateAndLeavesNoPartial() async throws {
        let take = try await Fixture.take(color: (255, 0, 0), seconds: 2)
        defer { try? FileManager.default.removeItem(at: take) }
        var project = try Project.open(take)
        project.edits.format = OutputFormat(size: .hd1080, frameRate: .fps30, codec: .hevc)
        let destination = take.appending(path: "out.mp4", directoryHint: .notDirectory)

        let progress = Progress()
        let report = try await Export.run(project, to: destination) { progress.record($0) }
        #expect(report.frames == 60)
        #expect(report.duration == .seconds(2))
        #expect(report.bytes > 0)
        #expect(report.warnings.isEmpty)
        #expect(progress.last == ExportProgress(framesWritten: 60, framesTotal: 60))
        #expect(progress.count == 60)
        let listing = try FileManager.default.contentsOfDirectory(atPath: take.path).sorted()
        #expect(listing == ["cursors", "events.ndjson", "out.mp4", "recording.json", "screen.mov"])

        let asset = AVURLAsset(url: destination)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let (size, rate) = try await track.load(.naturalSize, .nominalFrameRate)
        #expect(size == CGSize(width: 1920, height: 1080))
        #expect(rate == 30)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
    }

    @Test func rerunningReplacesTheFile() async throws {
        let take = try await Fixture.take(color: (0, 0, 255), seconds: 1)
        defer { try? FileManager.default.removeItem(at: take) }
        var project = try Project.open(take)
        project.edits.format = OutputFormat(size: .hd1080, frameRate: .fps30, codec: .h264)
        let destination = take.appending(path: "out.mp4", directoryHint: .notDirectory)
        try Data("not a movie".utf8).write(to: destination)
        let report = try await Export.run(project, to: destination)
        #expect(report.frames == 30)
        #expect(try Data(contentsOf: destination).count == Int(report.bytes))
    }

    @Test func cancellationRemovesThePartialFile() async throws {
        let take = try await Fixture.take(color: (0, 255, 0), seconds: 6)
        defer { try? FileManager.default.removeItem(at: take) }
        var project = try Project.open(take)
        project.edits.format = OutputFormat(size: .uhd2160, frameRate: .fps60, codec: .hevc)
        let destination = take.appending(path: "out.mp4", directoryHint: .notDirectory)
        let started = Progress()
        let export = Task { [project] in try await Export.run(project, to: destination) { started.record($0) } }
        while started.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        export.cancel()
        await #expect(throws: ExportError.cancelled) { try await export.value }
        let listing = try FileManager.default.contentsOfDirectory(atPath: take.path).sorted()
        #expect(listing == ["cursors", "events.ndjson", "recording.json", "screen.mov"], "\(listing)")
    }

    @Test func stillAndExportProduceIdenticalPixels() async throws {
        // Still.png and the export go through one composition. Catches two drawing paths drifting
        // apart. The export frame is decoded without any composition, so the only difference is the
        // HEVC round trip. Calibrated on the first run: 38.9, 40.3, and 40.7 dB at the three times,
        // against 36.7, 37.5, and 38.0 dB for the same frame shifted one pixel.
        let take = try await Fixture.take(color: (40, 200, 90), seconds: 2)
        defer { try? FileManager.default.removeItem(at: take) }
        var project = try Project.open(take)
        project.edits.format = OutputFormat(size: .hd1080, frameRate: .fps30, codec: .hevc)
        let destination = take.appending(path: "out.mp4", directoryHint: .notDirectory)
        _ = try await Export.run(project, to: destination)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: destination))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        for t in [OutputTime.seconds(0.5), .seconds(1.0), .seconds(1.5)] {
            let still = Pixels(try await Still.cgImage(project, at: t))
            let exported = Pixels(try await generator.image(at: t.compositionTime).image)
            let psnr = still.psnr(against: exported, shiftX: 0)
            let shifted = still.psnr(against: exported, shiftX: 1)
            #expect(psnr >= 38, "psnr \(psnr) at \(t.seconds) s")
            #expect(shifted < psnr - 1.5, "shift \(shifted) against \(psnr) at \(t.seconds) s")
        }
    }

    final class Progress: Sendable {
        private let state = Mutex<(last: ExportProgress?, count: Int)>((nil, 0))
        var last: ExportProgress? { state.withLock { $0.last } }
        var count: Int { state.withLock { $0.count } }
        func record(_ p: ExportProgress) {
            state.withLock {
                $0.last = p
                $0.count += 1
            }
        }
    }
}

import Synchronization

extension Pixels {
    /// Peak signal-to-noise ratio over RGB, with `other` sampled `shiftX` pixels to the right.
    func psnr(against other: Pixels, shiftX: Int) -> Double {
        var error = 0.0
        var samples = 0
        for y in 0..<height {
            for x in 0..<(width - shiftX) {
                let a = self[x, y], b = other[x + shiftX, y]
                error += Double((a.red - b.red) * (a.red - b.red) + (a.green - b.green) * (a.green - b.green) + (a.blue - b.blue) * (a.blue - b.blue))
                samples += 3
            }
        }
        let mse = error / Double(samples)
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }
}
