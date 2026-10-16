import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import Recording
@testable import RecordingFormat

struct AudioContinuityTests {
    let start = HostTime(nanoseconds: 100_000_000_000)

    @Test func theFirstBufferNeedsNoSilence() {
        #expect(AudioContinuity().silence(before: start + .seconds(3)) == .zero)
    }

    @Test func jitterUnderTheToleranceIsNotAGap() {
        var continuity = AudioContinuity()
        continuity.wrote(.milliseconds(20), at: start)
        #expect(continuity.silence(before: start + .milliseconds(20) + AudioContinuity.tolerance) == .zero)
        #expect(continuity.silence(before: start + .milliseconds(15)) == .zero, "an overlap is written as it comes")
    }

    @Test func aLateBufferGetsTheMissingTimeAsSilence() {
        var continuity = AudioContinuity()
        continuity.wrote(.milliseconds(20), at: start)
        #expect(continuity.silence(before: start + .seconds(1)) == .milliseconds(980))
    }

    @Test func theFileAdvancesByWhatWasWrittenNotByTimestamps() {
        var continuity = AudioContinuity()
        continuity.wrote(.milliseconds(20), at: start)
        continuity.wrote(.milliseconds(20), at: start + .milliseconds(5))
        #expect(continuity.writtenThrough == start + .milliseconds(40))
    }
}

struct AudioTrackWriterTests {
    let origin = HostTime(nanoseconds: 100_000_000_000)

    @Test(arguments: AudioSamples.Layout.allCases)
    func audioAfterAGapInDeliveryStaysAtItsTime(layout: AudioSamples.Layout) async throws {
        let url = try AudioSamples.temporaryMovieURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try AudioTrackWriter(url: url, channels: 2)
        try writer.start(at: origin)
        try await AudioSamples.deliver(to: writer, origin: origin, layout: layout, during: [0..<1, 2..<3])
        #expect(try await writer.finish(at: origin + .seconds(3)) == .recorded)

        let energy = try await AudioSamples.energy(of: url)
        #expect(energy.isLoud(0.1..<0.9))
        #expect(energy.isQuiet(1.1..<1.9), "the second with no buffers is silence: \(energy)")
        #expect(energy.isLoud(2.1..<2.9), "the audio after the gap is at 2 s, not pulled to 1 s: \(energy)")
        #expect(abs(energy.onset(after: 1.5) - 2) < 0.022, "onset at \(energy.onset(after: 1.5)) s")
    }

    @Test func aLateFirstBufferKeepsItsOffsetAndEarlierOnesAreDropped() async throws {
        let url = try AudioSamples.temporaryMovieURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try AudioTrackWriter(url: url, channels: 2)
        #expect(try writer.append(AudioSamples.tone(at: origin, frames: 1024, layout: .floatInterleaved)) == false)
        try writer.start(at: origin)
        let early = try AudioSamples.tone(at: HostTime(nanoseconds: origin.nanoseconds - 50_000_000), frames: 1024, layout: .floatInterleaved)
        #expect(try writer.append(early) == false)
        try await AudioSamples.deliver(to: writer, origin: origin, layout: .floatInterleaved, during: [0.5..<2])
        #expect(try await writer.finish(at: origin + .seconds(2)) == .recorded)

        let energy = try await AudioSamples.energy(of: url)
        #expect(energy.isQuiet(0..<0.45))
        #expect(abs(energy.onset(after: 0) - 0.5) < 0.022, "onset at \(energy.onset(after: 0)) s")
    }

    @Test func aSourceThatNeverDeliveredLeavesNoMovie() async throws {
        let url = try AudioSamples.temporaryMovieURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try AudioTrackWriter(url: url, channels: 2)
        try writer.start(at: origin)

        #expect(try await writer.finish(at: origin + .seconds(3)) == .removedEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path), "a movie with no samples does not open, so none is left")
    }
}

struct SystemAudioPermissionTests {
    @Test func systemAudioNeedsNothingBeyondScreenRecording() {
        let directory = URL(filePath: "/tmp")
        let granted = PermissionReport(screenRecording: .granted, inputMonitoring: .granted, microphone: .denied, camera: .denied)
        #expect(granted.missing(for: RecordingConfiguration(outputDirectory: directory, systemAudio: true)) == [])
        let denied = PermissionReport(screenRecording: .denied, inputMonitoring: .granted, microphone: .granted, camera: .granted)
        #expect(denied.missing(for: RecordingConfiguration(outputDirectory: directory, systemAudio: true)) == [.screenRecording])
    }
}

struct SystemAudioRecoveryTests {
    @Test func recoveryFinalisesASystemAudioTakeWhoseMoviesRead() async throws {
        let take = try await AudioSamples.crashedTake(withSystemAudioMovie: true)
        defer { try? FileManager.default.removeItem(at: take) }

        let finished = try await RecordingSession.recover(at: take)

        guard case .recovered(let message) = finished.termination else {
            Issue.record("expected recovered, got \(finished.termination)")
            return
        }
        #expect(message?.contains("system-audio.mov") == false, "\(message ?? "")")
        let manifest = try WireManifest.decode(Data(contentsOf: RecordingLayout(directory: take).manifest))
        #expect(manifest.systemAudio == WireSystemAudio(sampleRate: 48_000, channelCount: 2))
        #expect(manifest.formatVersion == 4)
        let energy = try await AudioSamples.energy(of: RecordingLayout(directory: take).systemAudio)
        #expect(energy.isLoud(0.1..<0.9), "the crashed movie still reads: \(energy)")
    }

    @Test func recoveryNotesASystemAudioMovieItCannotRead() async throws {
        let take = try await AudioSamples.crashedTake(withSystemAudioMovie: false)
        defer { try? FileManager.default.removeItem(at: take) }

        let finished = try await RecordingSession.recover(at: take)

        guard case .recovered(let message) = finished.termination else {
            Issue.record("expected recovered, got \(finished.termination)")
            return
        }
        #expect(message?.contains("system-audio.mov unreadable: missing") == true, "\(message ?? "")")
    }
}

enum AudioSamples {
    enum Layout: CaseIterable, Sendable {
        case floatInterleaved
        /// What ScreenCaptureKit hands over.
        case floatNonInterleaved
        case int16Interleaved
    }

    static let sampleRate = 48_000
    static let frequency = 1000.0

    static func temporaryMovieURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AudioTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "system-audio.mov", directoryHint: .notDirectory)
    }

    static func tone(at pts: HostTime, frames: Int, layout: Layout) throws -> CMSampleBuffer {
        let channels = 2
        let float = layout != .int16Interleaved
        let bytesPerSample = float ? 4 : 2
        let nonInterleaved = layout == .floatNonInterleaved
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: (float ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) | kAudioFormatFlagIsPacked
                | (nonInterleaved ? kAudioFormatFlagIsNonInterleaved : 0),
            mBytesPerPacket: UInt32(nonInterleaved ? bytesPerSample : bytesPerSample * channels), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(nonInterleaved ? bytesPerSample : bytesPerSample * channels), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: UInt32(bytesPerSample * 8), mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format)
        let seconds = Double(pts.nanoseconds) / 1e9
        let values = (0..<frames).map { 0.5 * sin(2 * Double.pi * frequency * (seconds + Double($0) / Double(sampleRate))) }
        var bytes = Data()
        func put(_ value: Double) {
            if float {
                withUnsafeBytes(of: Float(value)) { bytes.append(contentsOf: $0) }
            } else {
                withUnsafeBytes(of: Int16(value * 32_767)) { bytes.append(contentsOf: $0) }
            }
        }
        if nonInterleaved {
            for _ in 0..<channels { values.forEach(put) }
        } else {
            for value in values { for _ in 0..<channels { put(value) } }
        }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        let data = try #require(block)
        _ = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: bytes.count) }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: data, formatDescription: try #require(format), sampleCount: frames,
            presentationTimeStamp: pts.cmTime, packetDescriptions: nil, sampleBufferOut: &sample)
        return try #require(sample)
    }

    static func deliver(to writer: AudioTrackWriter, origin: HostTime, layout: Layout, during ranges: [Range<Double>]) async throws {
        for range in ranges {
            var frame = Int(range.lowerBound * Double(sampleRate))
            while frame < Int(range.upperBound * Double(sampleRate)) {
                let pts = origin + .nanoseconds(Int64(frame) * 1_000_000_000 / Int64(sampleRate))
                let buffer = try tone(at: pts, frames: 1024, layout: layout)
                var accepted = false
                for _ in 0..<500 {
                    if try writer.append(buffer) { accepted = true; break }
                    try await Task.sleep(for: .milliseconds(2))
                }
                #expect(accepted, "the writer never accepted the buffer at \(pts)")
                frame += 1024
            }
        }
    }

    struct Energy: CustomStringConvertible {
        var bins: [Double]
        static let binSeconds = 0.01

        func mean(_ range: Range<Double>) -> Double {
            let slice = bins[Int(range.lowerBound / Self.binSeconds)..<min(bins.count, Int(range.upperBound / Self.binSeconds))]
            return slice.reduce(0, +) / Double(max(1, slice.count))
        }

        static let audible = 0.05

        func isLoud(_ range: Range<Double>) -> Bool { mean(range) > 0.1 }
        func isQuiet(_ range: Range<Double>) -> Bool { mean(range) < 0.001 }

        func onset(after t: Double) -> Double {
            let first = bins.indices.first { Double($0) * Self.binSeconds >= t && bins[$0] > Self.audible }
            return first.map { Double($0) * Self.binSeconds } ?? .infinity
        }

        var description: String {
            stride(from: 0, to: bins.count, by: 10).map { String(format: "%.1f:%.3f", Double($0) * Self.binSeconds, bins[$0]) }
                .joined(separator: " ")
        }
    }

    static func energy(of url: URL) async throws -> Energy {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
        ])
        reader.add(output)
        reader.startReading()
        let seconds = try await asset.load(.duration).seconds
        var sums = [Double](repeating: 0, count: Int((seconds / Energy.binSeconds).rounded(.up)) + 1)
        var counts = sums
        while let buffer = output.copyNextSampleBuffer() {
            let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            let frames = CMSampleBufferGetNumSamples(buffer)
            let block = try #require(CMSampleBufferGetDataBuffer(buffer))
            var copy = [Float](repeating: 0, count: frames * 2)
            _ = copy.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            for i in 0..<frames {
                let bin = Int((start + Double(i) / Double(sampleRate)) / Energy.binSeconds)
                guard bin >= 0, bin < sums.count else { continue }
                sums[bin] += Double(copy[2 * i] * copy[2 * i])
                counts[bin] += 1
            }
        }
        return Energy(bins: zip(sums, counts).map { $1 > 0 ? $0 / $1 * 8 : 0 })
    }

    static func crashedTake(withSystemAudioMovie: Bool) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AudioTests-\(UUID().uuidString).osrec", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let layout = RecordingLayout(directory: directory)
        let origin = HostTime(nanoseconds: 50_000_000_000)
        let screen = try CameraTrackWriter(url: layout.screen, codec: .h264, plan: CameraFormat.Plan(formatIndex: 0, width: 64, height: 48, frameRate: 30))
        try screen.start(at: origin)
        for index in 0..<30 {
            try await CameraSamples.appendWhenWriterReady(at: origin + .nanoseconds(Int64(index) * 33_333_333), to: screen)
        }
        _ = try await screen.finish(at: origin + .seconds(1))
        if withSystemAudioMovie {
            let audio = try AudioTrackWriter(url: layout.systemAudio, channels: 2)
            try audio.start(at: origin)
            try await deliver(to: audio, origin: origin, layout: .floatNonInterleaved, during: [0..<2.5])
            try await Task.sleep(for: .milliseconds(200))
        }
        let manifest = WireManifest(
            id: RecordingID(UUID()), createdAt: Date(),
            recorder: WireRecorderInfo(name: "test", version: "0", osVersion: "27.0"),
            clock: WireClock(originHostTimeNanos: origin.nanoseconds),
            display: WireDisplay(displayID: 1, name: "Test", pointFrame: WireRect(x: 0, y: 0, width: 64, height: 48), refreshRate: 60),
            screen: WireScreen(pixelWidth: 64, pixelHeight: 48, codec: .h264, maxFrameRate: 30),
            microphone: nil,
            systemAudio: WireSystemAudio(sampleRate: 48_000, channelCount: 2))
        try manifest.write(to: layout)
        return directory
    }
}
