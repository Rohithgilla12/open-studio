import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import Render
import Timeline

struct AudioMixSpec {
    static let microphone = Fixture.Tone(frequency: 440, from: 0.5, until: 2, channels: 1)
    static let systemAudio = Fixture.Tone(frequency: 1000, from: 1, until: 2, channels: 2)
    static let oneBuffer = 1024.0 / 48_000

    static func take() async throws -> URL {
        let take = try await Fixture.take(color: (40, 40, 40), seconds: 2)
        try await Fixture.addAudio(microphone, as: .microphone, to: take)
        try await Fixture.addAudio(systemAudio, as: .systemAudio, to: take)
        return take
    }

    static func export(_ take: URL, _ change: (inout AudioLevels) -> Void = { _ in }) async throws -> URL {
        var project = try Project.open(take)
        project.edits.format = OutputFormat(size: .hd1080, frameRate: .fps30, codec: .h264)
        change(&project.edits.audio)
        let destination = take.appending(path: "out-\(UUID().uuidString).mp4", directoryHint: .notDirectory)
        let report = try await Export.run(project, to: destination)
        #expect(report.warnings.isEmpty, "\(report.warnings)")
        return destination
    }

    @Test func bothSourcesArePresentAtTheirTimesInBothChannels() async throws {
        let take = try await Self.take()
        defer { try? FileManager.default.removeItem(at: take) }
        let audio = try await Signal.read(try await Self.export(take))

        #expect(audio.channels == 2)
        for channel in 0..<2 {
            #expect(audio.amplitude(440, in: 0.05..<0.45, channel: channel) < 0.01)
            #expect(audio.amplitude(1000, in: 0.05..<0.95, channel: channel) < 0.01)
            #expect(abs(audio.amplitude(440, in: 1.2..<1.8, channel: channel) - 0.4) < 0.08, "channel \(channel)")
            #expect(abs(audio.amplitude(1000, in: 1.2..<1.8, channel: channel) - 0.4) < 0.08, "channel \(channel)")
        }
        let micOnset = audio.onset(440, after: 0.25)
        let systemOnset = audio.onset(1000, after: 0.75)
        #expect(abs(micOnset - 0.5) <= Self.oneBuffer, "microphone starts at \(micOnset) s")
        #expect(abs(systemOnset - 1) <= Self.oneBuffer, "system audio starts at \(systemOnset) s")
    }

    @Test func mutingOneSourceRemovesOnlyItsTone() async throws {
        let take = try await Self.take()
        defer { try? FileManager.default.removeItem(at: take) }
        let noMicrophone = try await Signal.read(try await Self.export(take) { $0.microphone.isMuted = true })
        let noSystemAudio = try await Signal.read(try await Self.export(take) { $0.systemAudio.isMuted = true })

        #expect(noMicrophone.amplitude(440, in: 1.2..<1.8) < 0.01)
        #expect(noMicrophone.amplitude(1000, in: 1.2..<1.8) > 0.3)
        #expect(noSystemAudio.amplitude(1000, in: 1.2..<1.8) < 0.01)
        #expect(noSystemAudio.amplitude(440, in: 1.2..<1.8) > 0.3)
    }

    @Test func halfVolumeIsAbout6DecibelsDown() async throws {
        let take = try await Self.take()
        defer { try? FileManager.default.removeItem(at: take) }
        let full = try await Signal.read(try await Self.export(take))
        let half = try await Signal.read(try await Self.export(take) { $0.microphone.volume = 0.5 })

        let drop = 20 * log10(half.amplitude(440, in: 1.2..<1.8) / full.amplitude(440, in: 1.2..<1.8))
        #expect(abs(drop + 6.02) < 0.5, "the microphone dropped \(drop) dB")
        let untouched = 20 * log10(half.amplitude(1000, in: 1.2..<1.8) / full.amplitude(1000, in: 1.2..<1.8))
        #expect(abs(untouched) < 0.2, "system audio moved \(untouched) dB")
    }

    @Test func everySourceSilentMeansNoAudioTrack() async throws {
        let take = try await Self.take()
        defer { try? FileManager.default.removeItem(at: take) }
        let destination = try await Self.export(take) {
            $0.microphone.isMuted = true
            $0.systemAudio.volume = 0
        }
        #expect(try await AVURLAsset(url: destination).loadTracks(withMediaType: .audio).isEmpty)
    }

    @Test func aMicrophoneOnlyTakeExportsItsMicrophoneAlone() async throws {
        let take = try await Fixture.take(color: (40, 40, 40), seconds: 2)
        defer { try? FileManager.default.removeItem(at: take) }
        try await Fixture.addAudio(Self.microphone, as: .microphone, to: take)
        let destination = try await Self.export(take)

        let tracks = try await AVURLAsset(url: destination).loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1)
        let audio = try await Signal.read(destination)
        #expect(audio.sourceChannels == 1, "a mono microphone stays mono")
        #expect(abs(audio.amplitude(440, in: 1.2..<1.8) - 0.4) < 0.08)
        #expect(abs(audio.onset(440, after: 0.25) - 0.5) <= Self.oneBuffer)
    }
}

@MainActor
struct AudioPreviewSpec {
    @Test func thePreviewCarriesTheMixBuiltFromTheEditsAndFollowsAnEdit() async throws {
        let take = try await AudioMixSpec.take()
        defer { try? FileManager.default.removeItem(at: take) }
        var project = try Project.open(take)
        project.edits.audio.microphone.volume = 0.25
        let preview = try await PreviewPlayer(project: project)
        let movie = try await MovieComposition.load(project.source)
        let ids = try #require(movie.audioTracks[.microphone].flatMap { mic in movie.audioTracks[.systemAudio].map { (mic, $0) } })
        #expect(Self.volumes(preview.item.audioMix) == [ids.0: 0.25, ids.1: 1])

        let picture = preview.item.videoComposition
        project.edits.audio.systemAudio.isMuted = true
        preview.show(project)
        let updated = await Self.wait { Self.volumes(preview.item.audioMix) == [ids.0: 0.25, ids.1: 0] }
        #expect(updated, "the mix after muting system audio: \(Self.volumes(preview.item.audioMix))")
        #expect(preview.item.videoComposition === picture, "a level change keeps the video composition")

        project.edits.style.padding = 0.1
        preview.show(project)
        let swapped = await Self.wait { preview.item.videoComposition !== picture }
        #expect(swapped, "a picture change still swaps the video composition")
        #expect(Self.volumes(preview.item.audioMix) == [ids.0: 0.25, ids.1: 0])
    }

    @Test func aTakeWithoutAudioHasNoMix() async throws {
        let take = try await Fixture.take(color: (40, 40, 40), seconds: 1)
        defer { try? FileManager.default.removeItem(at: take) }
        let preview = try await PreviewPlayer(project: try Project.open(take))
        #expect(preview.item.audioMix == nil)
    }

    static func volumes(_ mix: AVAudioMix?) -> [CMPersistentTrackID: Float] {
        var volumes: [CMPersistentTrackID: Float] = [:]
        for parameters in mix?.inputParameters ?? [] {
            var start: Float = -1
            var end: Float = -1
            var range = CMTimeRange()
            _ = parameters.getVolumeRamp(for: CMTime(value: 1, timescale: 1), startVolume: &start, endVolume: &end, timeRange: &range)
            volumes[parameters.trackID] = start
        }
        return volumes
    }

    static func wait(until predicate: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}

struct AudioLevelsProjectSpec {
    @Test func levelsSurviveASaveAndOpen() throws {
        let take = try Fixture.metadataOnlyTake()
        defer { try? FileManager.default.removeItem(at: take) }
        var project = try Project.open(take)
        project.edits.audio = AudioLevels(microphone: AudioLevel(volume: 0.3, isMuted: true), systemAudio: AudioLevel(volume: 0.8))
        try project.save()
        #expect(try Project.open(take).edits.audio == project.edits.audio)
    }

    @Test func aProjectSavedBeforeLevelsOpensAtFullVolume() throws {
        let take = try Fixture.metadataOnlyTake()
        defer { try? FileManager.default.removeItem(at: take) }
        try Project.open(take).save()
        try Self.editProjectFile(in: take) { $0.removeValue(forKey: "audio") }

        let project = try Project.open(take)
        #expect(project.origin == .saved)
        #expect(project.edits.audio == .default)
    }

    @Test func aVolumeOutsideZeroToOneIsRefused() throws {
        let take = try Fixture.metadataOnlyTake()
        defer { try? FileManager.default.removeItem(at: take) }
        try Project.open(take).save()
        try Self.editProjectFile(in: take) { $0["audio"] = ["systemAudio": ["volume": 1.5]] }

        #expect(throws: ProjectError.self) { try Project.open(take) }
    }

    static func editProjectFile(in take: URL, _ change: (inout [String: Any]) -> Void) throws {
        let url = ProjectFile.url(in: take)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        change(&json)
        try JSONSerialization.data(withJSONObject: json).write(to: url)
    }
}

struct Signal {
    var samples: [[Float]]
    var sourceChannels: Int
    static let rate = 48_000.0

    var channels: Int { samples.count }

    static func read(_ url: URL) async throws -> Signal {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        try #require(tracks.count == 1, "one mixed audio track, found \(tracks.count)")
        let track = tracks[0]
        let descriptions = try await track.load(.formatDescriptions)
        let sourceChannels = Int(descriptions.first?.audioStreamBasicDescription?.mChannelsPerFrame ?? 0)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
        ])
        reader.add(output)
        reader.startReading()
        var samples: [[Float]] = [[], []]
        while let buffer = output.copyNextSampleBuffer() {
            let frames = CMSampleBufferGetNumSamples(buffer)
            let start = Int((CMSampleBufferGetPresentationTimeStamp(buffer).seconds * rate).rounded())
            let block = try #require(CMSampleBufferGetDataBuffer(buffer))
            var interleaved = [Float](repeating: 0, count: frames * 2)
            _ = interleaved.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            for channel in 0..<2 {
                if samples[channel].count < start { samples[channel] += [Float](repeating: 0, count: start - samples[channel].count) }
                samples[channel] += stride(from: channel, to: interleaved.count, by: 2).map { interleaved[$0] }
            }
        }
        return Signal(samples: samples, sourceChannels: sourceChannels)
    }

    func amplitude(_ frequency: Double, in range: Range<Double>, channel: Int = 0) -> Double {
        let lower = Int(range.lowerBound * Self.rate), upper = min(samples[channel].count, Int(range.upperBound * Self.rate))
        guard upper > lower else { return 0 }
        return Self.goertzel(samples[channel][lower..<upper], frequency)
    }

    func onset(_ frequency: Double, after t: Double, channel: Int = 0) -> Double {
        let steady = amplitude(frequency, in: 1.2..<1.8, channel: channel)
        let window = Int(0.01 * Self.rate), hop = Int(0.0025 * Self.rate)
        var start = Int(t * Self.rate)
        while start + window <= samples[channel].count {
            if Self.goertzel(samples[channel][start..<start + window], frequency) > steady / 2 {
                return Double(start) / Self.rate
            }
            start += hop
        }
        return .infinity
    }

    static func goertzel(_ x: ArraySlice<Float>, _ frequency: Double) -> Double {
        let coefficient = 2 * cos(2 * Double.pi * frequency / rate)
        var (s1, s2) = (0.0, 0.0)
        for sample in x {
            let s0 = Double(sample) + coefficient * s1 - s2
            (s2, s1) = (s1, s0)
        }
        let power = s1 * s1 + s2 * s2 - coefficient * s1 * s2
        return 2 * sqrt(max(0, power)) / Double(x.count)
    }
}

extension Fixture {
    struct Tone {
        var frequency: Double
        var amplitude = 0.4
        var from: Double
        var until: Double
        var channels: Int
    }

    static func addAudio(_ tone: Tone, as source: AudioSource, to take: URL) async throws {
        let name = source == .microphone ? "microphone.mov" : "system-audio.mov"
        let writer = try AVAssetWriter(outputURL: take.appending(path: name, directoryHint: .notDirectory), fileType: .mov)
        writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: tone.channels,
            AVEncoderBitRateKey: 96_000 * tone.channels,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * tone.channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * tone.channels),
            mChannelsPerFrame: UInt32(tone.channels), mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format)
        let frames = 1024
        var frame = Int(tone.from * 48_000)
        while frame < Int(tone.until * 48_000) {
            var data = [Float](repeating: 0, count: frames * tone.channels)
            for i in 0..<frames {
                let value = Float(tone.amplitude * sin(2 * Double.pi * tone.frequency * Double(frame + i) / 48_000))
                for channel in 0..<tone.channels { data[i * tone.channels + channel] = value }
            }
            var block: CMBlockBuffer?
            let length = data.count * 4
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            _ = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: length) }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: frames,
                presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: 48_000), packetDescriptions: nil,
                sampleBufferOut: &sample)
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            input.append(sample!)
            frame += frames
        }
        writer.endSession(atSourceTime: CMTime(seconds: tone.until, preferredTimescale: 48_000))
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }

        let manifestURL = take.appending(path: "recording.json", directoryHint: .notDirectory)
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        switch source {
        case .microphone:
            manifest["microphone"] = ["deviceName": "Fixture Microphone", "sampleRate": 48_000, "channelCount": tone.channels]
        case .systemAudio:
            manifest["formatVersion"] = 4
            manifest["systemAudio"] = ["sampleRate": 48_000, "channelCount": tone.channels]
        }
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    }
}
