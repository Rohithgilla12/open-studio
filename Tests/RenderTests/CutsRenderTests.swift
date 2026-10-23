import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import Render
import Timeline

/// The composition with cuts: every output frame, the audio across a join, and the camera's early
/// end on either side of a cut.
struct CutsRenderSpec {
    static let flat = Style(background: .solid(RGBColor(red: 0, green: 0, blue: 1)), padding: 0, cornerRadius: 0, shadow: .none)

    static func cut(_ start: Double, _ end: Double) -> Cut { Cut(range: TimeRange(start: .seconds(start), end: .seconds(end))!) }

    /// The committed fixture's metadata shortened to 4 s, with a 10 fps screen movie whose frames
    /// code their own index. Short, so these exports do not starve the preview tests running
    /// beside them.
    static func codedTake() async throws -> URL {
        let take = try Fixture.metadataOnlyTake()
        let manifestURL = take.appending(path: "recording.json", directoryHint: .notDirectory)
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        manifest["durationMicros"] = 4_000_000
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        try await Fixture.writeCodedMovie(to: take.appending(path: "screen.mov", directoryHint: .notDirectory), frames: 40, fps: 10)
        return take
    }

    static func project(_ take: URL, cuts: [Cut]) throws -> Project {
        var project = try Project.open(take)
        project.edits.zooms = .empty
        project.edits.style = flat
        project.edits.settings.cursor.smoothing = .none
        project.edits.format = OutputFormat(size: .hd1080, frameRate: .fps30, codec: .hevc)
        project.edits.cuts = try Cuts(validating: cuts, within: project.source.duration)
        return project
    }

    /// Catches the composition carrying the wrong source frame anywhere: a shifted track, an
    /// off-by-one at an unaligned join, a trim applied to the wrong end.
    @Test func everyExportedFrameCarriesTheSourceFrameTheMapPredicts() async throws {
        let take = try await Self.codedTake()
        defer { try? FileManager.default.removeItem(at: take) }
        let project = try Self.project(take, cuts: [Self.cut(0, 0.5), Self.cut(1.5, 2.55), Self.cut(3, 3.2), Self.cut(3.9, 4)])
        let map = project.timeline.map
        #expect(map.duration == .seconds(2.15))
        let destination = take.appending(path: "out.mp4", directoryHint: .notDirectory)
        let report = try await Export.run(project, to: destination)
        #expect(report.duration == map.duration)
        #expect(report.frames == 65, "ceil(2.15 s * 30)")

        let frames = try await Fixture.codedFrames(of: destination)
        #expect(frames.count == 65)
        var mismatches: [String] = []
        for (time, index) in frames {
            let o = OutputTime(compositionTime: time)
            let expected = Int(map.recording(at: o).microseconds / 100_000)
            if index != expected { mismatches.append("output \(o.seconds) s: frame \(index), map says \(expected)") }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(8))")
    }

    /// Catches preview, export, and stills disagreeing: the still at an output time has exactly
    /// the pixels of the uncut take's still at the recording instant the map names.
    @Test func aStillEitherSideOfAJoinIsTheUncutStillAtTheMappedInstant() async throws {
        let take = try await Self.codedTake()
        defer { try? FileManager.default.removeItem(at: take) }
        let cut = try Self.project(take, cuts: [Self.cut(1, 2.55)])
        let uncut = try Self.project(take, cuts: [])
        for o in [OutputTime.seconds(1) - .milliseconds(34), .seconds(1)] {
            let r = cut.timeline.map.recording(at: o)
            let edited = try await Still.png(cut, at: o)
            let plain = try await Still.png(uncut, at: OutputTime(microseconds: r.microseconds))
            #expect(edited == plain, "output \(o.seconds) s against recording \(r.seconds) s")
        }
    }

    /// Catches a click at a join, and pins the fade length the measurement chose.
    @Test func theAudioDipsAtAJoinInsteadOfClicking() async throws {
        #expect(MovieComposition.joinFade == .milliseconds(30))
        let take = try await Fixture.take(color: (40, 40, 40), seconds: 4)
        defer { try? FileManager.default.removeItem(at: take) }
        try await Fixture.addAudio(Fixture.Tone(frequency: 440, from: 0, until: 4, channels: 1), as: .microphone, to: take)
        // Off zero crossings and off AAC packet boundaries (1024 samples = 21.333 ms).
        let project = try Self.project(take, cuts: [Self.cut(1.0037, 2.5011)])
        let join = 1.0037
        #expect(project.timeline.map.joins == [.seconds(join)])

        let destination = take.appending(path: "out.mp4", directoryHint: .notDirectory)
        _ = try await Export.run(project, to: destination)
        let audio = try await Signal.read(destination)
        let samples = audio.samples[0]
        let j = Int((join * Signal.rate).rounded())
        var largestStep: Float = 0
        for i in (j - 480)..<(j + 480) { largestStep = max(largestStep, abs(samples[i] - samples[i - 1])) }
        let naturalStep = Float(2 * Double.pi * 440 * 0.4 / Signal.rate)
        #expect(largestStep <= naturalStep * 1.25, "largest step at the join \(largestStep) against the tone's own \(naturalStep)")
        #expect(audio.amplitude(440, in: (join - 0.002)..<(join + 0.002)) < 0.06, "silent at the join")
        #expect(abs(audio.amplitude(440, in: (join - 0.25)..<(join - 0.05)) - 0.4) < 0.08, "full before the dip")
        #expect(abs(audio.amplitude(440, in: (join + 0.05)..<(join + 0.25)) - 0.4) < 0.08, "full after the dip")
        #expect(abs(Double(samples.count) / Signal.rate - 2.5) < 0.05, "the kept 2.5 s of audio")
    }

    /// Catches a trimmed start opening at full volume: what the listener hears is a fade in from
    /// silence over the join fade, whatever the mix declares at time zero.
    @Test func aTrimmedStartFadesInFromSilence() async throws {
        let take = try await Fixture.take(color: (40, 40, 40), seconds: 4)
        defer { try? FileManager.default.removeItem(at: take) }
        try await Fixture.addAudio(Fixture.Tone(frequency: 440, from: 0, until: 4, channels: 1), as: .microphone, to: take)
        let project = try Self.project(take, cuts: [Self.cut(0, 1.0037)])
        let destination = take.appending(path: "out.mp4", directoryHint: .notDirectory)
        _ = try await Export.run(project, to: destination)
        let audio = try await Signal.read(destination)
        let samples = audio.samples[0]
        let fade = Int(0.03 * Signal.rate)
        let loudestOpening = samples[0..<Int(0.003 * Signal.rate)].map(abs).max() ?? 0
        #expect(loudestOpening < 0.06, "the first 3 ms are near silence, loudest sample \(loudestOpening)")
        #expect(audio.amplitude(440, in: 0..<0.01) < 0.15, "a third of the way into the fade")
        #expect(audio.amplitude(440, in: 0.01..<0.02) > 0.1 && audio.amplitude(440, in: 0.01..<0.02) < 0.3, "half way")
        #expect(abs(audio.amplitude(440, in: 0.05..<0.25) - 0.4) < 0.08, "full after the fade")
        var largestStep: Float = 0
        for i in 1..<(fade + 480) { largestStep = max(largestStep, abs(samples[i] - samples[i - 1])) }
        let naturalStep = Float(2 * Double.pi * 440 * 0.4 / Signal.rate)
        #expect(largestStep <= naturalStep * 1.25, "no click through the fade, largest step \(largestStep) against the tone's own \(naturalStep)")
    }

    /// Catches a missing ramp: the mix carries a pair at every join and a fade at each trimmed end.
    @Test func theMixRampsAtEveryJoinAndTrimmedEnd() async throws {
        let take = try await Fixture.take(color: (40, 40, 40), seconds: 4)
        defer { try? FileManager.default.removeItem(at: take) }
        try await Fixture.addAudio(Fixture.Tone(frequency: 440, from: 0, until: 4, channels: 1), as: .microphone, to: take)
        let project = try Self.project(take, cuts: [Self.cut(0, 0.5), Self.cut(1.5, 2), Self.cut(3.5, 4)])
        let movie = MovieComposition(media: try await SourceMedia.load(project.source), map: project.timeline.map)
        var levels = AudioLevels.default
        levels.microphone.volume = 0.5
        let parameters = try #require(movie.audioMix(levels)?.inputParameters.first)
        func ramp(at seconds: Double) -> (from: Float, to: Float, start: Double, end: Double)? {
            var from: Float = 0, to: Float = 0
            var range = CMTimeRange()
            guard parameters.getVolumeRamp(for: CMTime(seconds: seconds, preferredTimescale: 1_000_000), startVolume: &from, endVolume: &to, timeRange: &range)
            else { return nil }
            return (from, to, range.start.seconds, range.end.seconds)
        }
        #expect(ramp(at: 0.015).map { $0.from == 0 && $0.to == 0.5 && $0.start == 0 && $0.end == 0.03 } == true, "fade in at the trimmed start")
        #expect(ramp(at: 0.985).map { $0.from == 0.5 && $0.to == 0 && $0.start == 0.97 && $0.end == 1 } == true, "down to the join at 1 s")
        #expect(ramp(at: 1.015).map { $0.from == 0 && $0.to == 0.5 && $0.start == 1 && $0.end == 1.03 } == true, "up from the join")
        #expect(ramp(at: 2.485).map { $0.from == 0.5 && $0.to == 0 && $0.start == 2.47 && $0.end == 2.5 } == true, "fade out at the trimmed end")
    }

    /// Catches the camera's instruction split landing on the recording instant instead of the
    /// output one, which would freeze or drop the overlay around a cut.
    @Test(arguments: [("before", 0.5, 0.5), ("inside", 1.5, 1.0), ("after", 2.5, 1.5)])
    func theCameraEndSplitsTheInstructionsInOutputTime(name: String, until: Double, split: Double) async throws {
        let take = try await Fixture.take(color: (255, 0, 0), seconds: 3)
        defer { try? FileManager.default.removeItem(at: take) }
        try await Fixture.addCamera(Fixture.Camera(before: ((255, 255, 0), (0, 255, 255)), after: ((255, 255, 0), (0, 255, 255)), until: until), to: take)
        var project = try Self.project(take, cuts: [Self.cut(1, 2)])
        project.edits.style = PixelSpec.blue
        let movie = MovieComposition(media: try await SourceMedia.load(project.source), map: project.timeline.map)
        let scene = try RenderScene.make(project: project, format: project.edits.format, reusing: nil)
        let ranges = movie.videoComposition(scene: scene, frameRate: .fps30).instructions.map { ($0.timeRange.start.seconds, $0.timeRange.end.seconds) }
        #expect(ranges.map(\.0) == [0, split] && ranges.map(\.1) == [split, 2], "\(name): \(ranges)")

        func isCyan(_ p: (red: Int, green: Int, blue: Int)) -> Bool { p.red < 60 && p.green > 200 && p.blue > 200 }
        func isRed(_ p: (red: Int, green: Int, blue: Int)) -> Bool { p.red > 200 && p.green < 60 && p.blue < 60 }
        let before = Pixels(try await Still.cgImage(project, at: .seconds(split - 0.1)))
        let after = Pixels(try await Still.cgImage(project, at: .seconds(split + 0.1)))
        #expect(isCyan(before[1693, 913]), "\(name): overlay just before the split \(before[1693, 913])")
        #expect(isRed(after[1753, 913]), "\(name): no overlay just after it \(after[1753, 913])")

        // The export's reader hands over the last camera frame past the track's end (the D9
        // measurement), so the inside case also checks the exported movie.
        guard name == "inside" else { return }
        let destination = take.appending(path: "out.mp4", directoryHint: .notDirectory)
        _ = try await Export.run(project, to: destination)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: destination))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let exported = Pixels(try await generator.image(at: CMTime(seconds: split + 0.1, preferredTimescale: 30)).image)
        #expect(isRed(exported[1753, 913]), "\(name): the export draws no frozen camera frame after the split \(exported[1753, 913])")
    }
}

extension Fixture {
    /// A movie whose frame i is black with a white bar at x = i * 14, so a decoded frame names its
    /// own index after two codec round trips whatever they do to grey levels.
    static func writeCodedMovie(to url: URL, frames: Int, fps: Int) async throws {
        let width = 1920, height = 1080
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frames {
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
            let buffer = pixelBuffer!
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let bar = index * 14
            for y in 0..<height {
                let row = base + y * rowBytes
                memset(row, 0, width * 4)
                memset(row + bar * 4, 255, 10 * 4)
                for x in 0..<width { row[x * 4 + 3] = 255 }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            var description: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &description)
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
                presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: nil, imageBuffer: buffer, formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &sample)
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            input.append(sample!)
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }

    /// (presentation time, decoded source index) for every frame of an exported movie drawn with
    /// `CutsRenderSpec.flat`, where the content fills the canvas 1:1 and the cursor never reaches
    /// the sampled row.
    static func codedFrames(of url: URL) async throws -> [(CMTime, Int)] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        var frames: [(CMTime, Int)] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(buffer)
            let start = (0..<1920).first { base[100 * row + $0 * 4 + 1] > 128 } ?? -100
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            frames.append((CMSampleBufferGetPresentationTimeStamp(sample), (start + 7) / 14))
        }
        return frames
    }
}
