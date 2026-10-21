// Throwaway. Measures the AVFoundation behaviour the cuts design depends on.
//
//   swiftc -O -swift-version 5 docs/design/cuts/candidate/spike/main.swift -o $SCRATCH/cuts-spike
//   $SCRATCH/cuts-spike audio   $SCRATCH            # sine through a composition with removed ranges
//   $SCRATCH/cuts-spike frames  $SCRATCH            # frame-coded video through a composition with removed ranges
//   $SCRATCH/cuts-spike replace <take>.osrec        # AVPlayer item replacement latency on a real take
//   $SCRATCH/cuts-spike seek    <take>.osrec        # control for replace: seek inside one item
//   $SCRATCH/cuts-spike build   <take>.osrec        # composition build cost against cut count

import AVFoundation
import CoreVideo
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: cuts-spike audio|frames|replace|build <dir or take>")
    exit(2)
}
let target = URL(filePath: arguments[2], directoryHint: .isDirectory)

/// Kept ranges in recording seconds. The map under test: output time is the running sum.
struct Kept {
    var ranges: [(Double, Double)]
    var outputDuration: Double { ranges.reduce(0) { $0 + $1.1 - $1.0 } }
    func recording(atOutput o: Double) -> Double {
        var start = 0.0
        for (a, b) in ranges {
            if o < start + (b - a) { return a + (o - start) }
            start += b - a
        }
        return ranges.last!.1
    }
    /// Output times where one kept range meets the next.
    var joins: [Double] {
        var out: [Double] = []
        var start = 0.0
        for (a, b) in ranges.dropLast() { start += b - a; out.append(start) }
        return out
    }
}

func cm(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 1_000_000) }

func insert(_ kept: Kept, of track: AVAssetTrack, into composition: AVMutableCompositionTrack) throws {
    var at = CMTime.zero
    let available = track.timeRange.end
    for (a, b) in kept.ranges {
        let range = CMTimeRange(start: cm(a), end: cm(b))
        let media = CMTimeRangeGetIntersection(range, otherRange: CMTimeRange(start: .zero, end: available))
        if media.duration > .zero { try composition.insertTimeRange(media, of: track, at: at) }
        at = at + range.duration
    }
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }


func writeSine(_ url: URL, seconds: Double, frequency: Double) async throws {
    try? FileManager.default.removeItem(at: url)
    let rate = 48_000
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    var asbd = AudioStreamBasicDescription(
        mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(
        allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &format)
    let frames = 1024
    var frame = 0
    while frame < Int(seconds * Double(rate)) {
        var data = [Float](repeating: 0, count: frames)
        for i in 0..<frames { data[i] = Float(0.5 * sin(2 * .pi * frequency * Double(frame + i) / Double(rate))) }
        var block: CMBlockBuffer?
        let length = frames * 4
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        _ = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: length) }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: frames,
            presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(rate)), packetDescriptions: nil,
            sampleBufferOut: &sample)
        while !input.isReadyForMoreMediaData { usleep(1_000) }
        input.append(sample!)
        frame += frames
    }
    writer.endSession(atSourceTime: cm(seconds))
    input.markAsFinished()
    await writer.finishWriting()
    precondition(writer.status == .completed, "\(writer.error!)")
}

func readMono(_ asset: AVAsset, mix: AVAudioMix?) async throws -> [Float] {
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
    ])
    output.audioMix = mix
    reader.add(output)
    reader.startReading()
    var samples: [Float] = []
    while let buffer = output.copyNextSampleBuffer() {
        let block = CMSampleBufferGetDataBuffer(buffer)!
        let length = CMBlockBufferGetDataLength(block)
        var chunk = [Float](repeating: 0, count: length / 4)
        _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        samples += chunk
    }
    precondition(reader.status == .completed, "\(String(describing: reader.error))")
    return samples
}

func audio() async throws {
    let url = target.appending(path: "sine.mov")
    let f = 440.0
    try await writeSine(url, seconds: 10, frequency: f)
    let source = AVURLAsset(url: url)
    let track = try await source.loadTracks(withMediaType: .audio).first!
    // Cut points chosen off zero crossings and off AAC packet boundaries (1024 samples = 21.333 ms).
    let kept = Kept(ranges: [(0, 2.0037), (3.5011, 6.2003), (7.9, 10)])
    let composition = AVMutableComposition()
    let ct = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
    try insert(kept, of: track, into: ct)

    let maxStep = Float(2 * .pi * f * 0.5 / 48_000)
    func report(_ label: String, _ s: [Float]) {
        print("\(label): \(s.count) samples, expected \(Int((kept.outputDuration * 48_000).rounded()))")
        var interiorError: Float = 0
        var count = 0
        for i in stride(from: 2_400, to: s.count - 2_400, by: 1) {
            let o = Double(i) / 48_000
            guard kept.joins.allSatisfy({ abs($0 - o) > 0.03 }) else { continue }
            let expected = Float(0.5 * sin(2 * .pi * f * kept.recording(atOutput: o)))
            interiorError = max(interiorError, abs(s[i] - expected))
            count += 1
        }
        print("  max |error| vs analytic sine away from joins (\(count) samples): \(interiorError)")
        for join in kept.joins {
            let j = Int((join * 48_000).rounded())
            var worstStep: Float = 0
            var worstAt = 0
            var nearError: Float = 0
            for i in (j - 480)..<(j + 480) where i > 0 && i < s.count {
                let step = abs(s[i] - s[i - 1])
                if step > worstStep { worstStep = step; worstAt = i - j }
                let expected = Float(0.5 * sin(2 * .pi * f * kept.recording(atOutput: Double(i) / 48_000)))
                nearError = max(nearError, abs(s[i] - expected))
            }
            print(String(format: "  join at %.4f s: largest sample step %.4f at offset %d (a pure sine steps at most %.4f); max |error| within 10 ms %.4f",
                         join, worstStep, worstAt, maxStep, nearError))
        }
    }
    let base = try await readMono(source, mix: nil)
    var baseError: Float = 0
    for i in 2_400..<(base.count - 2_400) {
        baseError = max(baseError, abs(base[i] - Float(0.5 * sin(2 * .pi * f * Double(i) / 48_000))))
    }
    print("uncut source: \(base.count) samples, max |error| vs analytic sine \(baseError)")
    report("cut, no ramps", try await readMono(composition, mix: nil))

    /// Gain per millisecond around a join: one-period RMS of the output over one-period RMS of the sine.
    func envelope(_ s: [Float], around j: Int) -> String {
        let period = 109
        return stride(from: -30, through: 30, by: 3).map { ms -> String in
            let centre = j + ms * 48
            let window = (centre - period / 2)..<(centre + period / 2 + 1)
            let rms = sqrt(window.map { Double(s[$0] * s[$0]) }.reduce(0, +) / Double(window.count))
            return String(format: "%.2f", rms * 2.0.squareRoot() / 0.5)
        }.joined(separator: " ")
    }
    func run(_ label: String, _ configure: (AVMutableAudioMixInputParameters) -> Void) async throws {
        let p = AVMutableAudioMixInputParameters(track: ct)
        configure(p)
        let m = AVMutableAudioMix()
        m.inputParameters = [p]
        let s = try await readMono(composition, mix: m)
        print("\(label):")
        for join in kept.joins + [1.0] {
            let j = Int((join * 48_000).rounded())
            var worst: Float = 0
            for i in (j - 480)..<(j + 480) { worst = max(worst, abs(s[i] - s[i - 1])) }
            print(String(format: "  at %.4f s: largest step %.4f; gain every 3 ms, -30...+30: %@", join, worst, envelope(s, around: j)))
        }
    }
    try await run("no mix") { _ in }
    try await run("one ramp 1 -> 0 over [1.000, 1.010) s, nothing else") { p in
        p.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: cm(1.0), end: cm(1.01)))
    }
    try await run("dip: ramps 1 -> 0 over [join - 5 ms, join), 0 -> 1 over [join, join + 5 ms)") { p in
        for join in kept.joins {
            p.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: cm(join - 0.005), end: cm(join)))
            p.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: cm(join), end: cm(join + 0.005)))
        }
    }
    try await run("dip as above, preceded by setVolume(1, at: 0)") { p in
        p.setVolume(1, at: .zero)
        for join in kept.joins {
            p.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: cm(join - 0.005), end: cm(join)))
            p.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: cm(join), end: cm(join + 0.005)))
        }
    }
    for fade in [0.01, 0.02, 0.03, 0.05] {
        try await run("dip, ramps \(Int(fade * 1000)) ms") { p in
            for join in kept.joins {
                p.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: cm(join - fade), end: cm(join)))
                p.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: cm(join), end: cm(join + fade)))
            }
        }
    }
}


/// Each frame codes its index i in two flat fields: left = (i % 32) * 8, right = (i / 32) * 24.
func writeCoded(_ url: URL, frames: Int, fps: Int) async throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320,
        kCVPixelBufferHeightKey as String: 180,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for i in 0..<frames {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        CVPixelBufferLockBaseAddress(buffer!, [])
        let base = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer!)
        let low = UInt8((i % 32) * 8), high = UInt8((i / 32) * 24)
        for y in 0..<180 {
            for x in 0..<320 {
                let v = x < 160 ? low : high
                let p = base + y * row + x * 4
                p[0] = v; p[1] = v; p[2] = v; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        while !input.isReadyForMoreMediaData { usleep(1_000) }
        adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(fps)))
    await writer.finishWriting()
    precondition(writer.status == .completed, "\(writer.error!)")
}

func decodeIndex(_ buffer: CVPixelBuffer) -> Int {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let row = CVPixelBufferGetBytesPerRow(buffer)
    let low = Double(base[90 * row + 80 * 4 + 1]), high = Double(base[90 * row + 240 * 4 + 1])
    return Int((low / 8).rounded()) + 32 * Int((high / 24).rounded())
}

final class Instruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let trackID: CMPersistentTrackID
    init(_ range: CMTimeRange, _ id: CMPersistentTrackID) {
        timeRange = range
        trackID = id
        requiredSourceTrackIDs = [NSNumber(value: id)]
    }
}

/// Records (composition time, source frame index) for every request and passes the frame through.
final class RecordingCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    nonisolated(unsafe) static var log: [(Double, Int)] = []
    nonisolated(unsafe) static var bgra = true
    static let lock = NSLock()
    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: Self.bgra ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: Self.bgra ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    }
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let instruction = request.videoCompositionInstruction as! Instruction
        guard let frame = request.sourceFrame(byTrackID: instruction.trackID) else {
            request.finish(with: NSError(domain: "spike", code: 1))
            return
        }
        if Self.bgra {
            let index = decodeIndex(frame)
            Self.lock.withLock { Self.log.append((request.compositionTime.seconds, index)) }
        }
        request.finish(withComposedVideoFrame: frame)
    }
}

func videoComposition(_ asset: AVAsset, trackID: CMPersistentTrackID, duration: CMTime, fps: Int32) -> AVVideoComposition {
    let vc = AVMutableVideoComposition()
    vc.customVideoCompositorClass = RecordingCompositor.self
    vc.frameDuration = CMTime(value: 1, timescale: fps)
    let size = asset.tracks(withMediaType: .video).first!.naturalSize
    vc.renderSize = size
    vc.instructions = [Instruction(CMTimeRange(start: .zero, duration: duration), trackID)]
    return vc
}

func frames() async throws {
    let url = target.appending(path: "coded.mov")
    let fps = 30
    try await writeCoded(url, frames: 300, fps: fps)
    let source = AVURLAsset(url: url)
    let track = try await source.loadTracks(withMediaType: .video).first!
    // One cut on frame boundaries, one off them, plus a head and tail trim.
    let kept = Kept(ranges: [(0.5, 2.0), (3.0 + 1.0 / 90, 6.25), (7.0, 9.6)])
    let composition = AVMutableComposition()
    let ct = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    try insert(kept, of: track, into: ct)
    let duration = composition.duration
    print("composition duration \(duration.seconds) s, expected \(kept.outputDuration)")
    let reader = try AVAssetReader(asset: composition)
    let output = AVAssetReaderVideoCompositionOutput(videoTracks: [ct], videoSettings: nil)
    output.videoComposition = videoComposition(composition, trackID: ct.trackID, duration: duration, fps: 60)
    reader.add(output)
    reader.startReading()
    var count = 0
    while output.copyNextSampleBuffer() != nil { count += 1 }
    let log = RecordingCompositor.log.sorted { $0.0 < $1.0 }
    print("frames out \(count), expected \(Int((kept.outputDuration * 60).rounded(.up)))")
    var mismatches = 0
    for (o, index) in log {
        let expected = Int((kept.recording(atOutput: o) * Double(fps) + 1e-6).rounded(.down))
        if index != expected {
            mismatches += 1
            if mismatches <= 8 { print(String(format: "  mismatch at output %.4f: source frame %d, map says %d", o, index, expected)) }
        }
    }
    print("compositor requests \(log.count); source frame == map.recording(output) for \(log.count - mismatches), mismatches \(mismatches)")
    for join in kept.joins {
        let around = log.filter { abs($0.0 - join) < 0.04 }.map { String(format: "%.4f->%d", $0.0, $0.1) }
        print("  around join \(String(format: "%.4f", join)): \(around.joined(separator: " "))")
    }
}


/// Holds the assets as well as their tracks: a track does not keep its asset alive, and inserting
/// from a track whose asset is gone fails with -11800 / -12780.
struct Take {
    let assets: [AVURLAsset]
    let screen: AVAssetTrack
    let mic: AVAssetTrack?
    let duration: Double
}

func loadTake() async throws -> Take {
    let screen = AVURLAsset(url: target.appending(path: "screen.mov"))
    let video = try await screen.loadTracks(withMediaType: .video).first!
    let micURL = target.appending(path: "microphone.mov")
    let micAsset = FileManager.default.fileExists(atPath: micURL.path) ? AVURLAsset(url: micURL) : nil
    let mic = try await micAsset?.loadTracks(withMediaType: .audio).first
    // Kept a millisecond inside the track, so a microsecond-rounded end never runs past its media.
    let duration = min(try await video.load(.timeRange).end.seconds, try await screen.load(.duration).seconds) - 0.001
    print("screen track \(duration) s, microphone \(mic == nil ? "absent" : "present")")
    return Take(assets: [screen] + (micAsset.map { [$0] } ?? []), screen: video, mic: mic, duration: duration)
}

func build(_ take: Take, _ kept: Kept) throws -> (AVComposition, CMPersistentTrackID) {
    let composition = AVMutableComposition()
    let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    try insert(kept, of: take.screen, into: v)
    if let mic = take.mic {
        let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try insert(kept, of: mic, into: a)
    }
    return (composition.copy() as! AVComposition, v.trackID)
}

func cutSets(_ d: Double) -> [Kept] {
    [
        Kept(ranges: [(0, d)]),
        Kept(ranges: [(0.3, 1.5), (2.0, d - 0.2)]),
        Kept(ranges: [(0, 1.0), (1.4, 2.5), (3.1, d)]),
        Kept(ranges: [(0.8, d)]),
    ]
}

@MainActor
func replace() async throws {
    RecordingCompositor.bgra = false
    let take = try await loadTake()
    let player = AVPlayer()
    player.actionAtItemEnd = .pause
    let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    var rows: [String] = []
    for playing in [false, true] {
        var totals: [Double] = []
        for iteration in 0..<24 {
            let kept = cutSets(take.duration)[iteration % 4]
            let t0 = now()
            let (asset, trackID) = try build(take, kept)
            let item = AVPlayerItem(asset: asset)
            item.videoComposition = videoComposition(asset, trackID: trackID, duration: asset.duration, fps: 60)
            let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
            item.add(videoOutput)
            let t1 = now()
            player.replaceCurrentItem(with: item)
            let land = min(1.2, kept.outputDuration / 2)
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                item.seek(to: cm(land), toleranceBefore: .zero, toleranceAfter: .zero) { _ in c.resume() }
            }
            let t2 = now()
            if playing { player.rate = 1 }
            // First pixel buffer the item can hand to a display at or after the landing time.
            var t3 = 0.0
            while now() - t2 < 3_000 {
                let host = CACurrentMediaTime()
                let itemTime = videoOutput.itemTime(forHostTime: host)
                if itemTime.seconds >= land - 0.001, videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
                    videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) != nil
                {
                    t3 = now()
                    break
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            player.pause()
            if iteration >= 4 { totals.append(t3 - t0) }
            rows.append(String(format: "%@ #%02d build %.2f ms, replace+seek %.1f ms, first frame %.1f ms, total %.1f ms",
                               playing ? "playing" : "paused ", iteration, t1 - t0, t2 - t1, t3 - t2, t3 - t0))
        }
        totals.sort()
        print(String(format: "%@: total build to first frame over 20 runs: median %.1f ms, p90 %.1f ms, max %.1f ms",
                     playing ? "playing" : "paused", totals[10], totals[18], totals[19]))
    }
    rows.forEach { print("  " + $0) }
}

/// Control for `replace`: the same zero-tolerance seek and first-frame wait inside one item that is never replaced.
@MainActor
func seekOnly() async throws {
    RecordingCompositor.bgra = false
    let take = try await loadTake()
    let player = AVPlayer()
    let (asset, trackID) = try build(take, cutSets(take.duration)[2])
    let item = AVPlayerItem(asset: asset)
    item.videoComposition = videoComposition(asset, trackID: trackID, duration: asset.duration, fps: 60)
    let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
    item.add(videoOutput)
    player.replaceCurrentItem(with: item)
    var totals: [Double] = []
    for iteration in 0..<24 {
        let land = [0.4, 1.9, 2.8, 1.1][iteration % 4]
        let t0 = now()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            item.seek(to: cm(land), toleranceBefore: .zero, toleranceAfter: .zero) { _ in c.resume() }
        }
        var t1 = 0.0
        while now() - t0 < 3_000 {
            let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
            if abs(itemTime.seconds - land) < 0.001, videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
                videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) != nil
            {
                t1 = now()
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        if iteration >= 4 { totals.append(t1 - t0) }
    }
    totals.sort()
    print(String(format: "seek within one item, seek to first frame over 20 runs: median %.1f ms, p90 %.1f ms, max %.1f ms",
                 totals[10], totals[18], totals[19]))
}


func buildCost() async throws {
    let take = try await loadTake()
    for cuts in [0, 10, 100, 500] {
        let d = take.duration
        var ranges: [(Double, Double)] = []
        let step = d / Double(cuts + 1)
        for i in 0...cuts { ranges.append((Double(i) * step, Double(i) * step + step * 0.8)) }
        let kept = Kept(ranges: ranges)
        var samples: [Double] = []
        for _ in 0..<20 {
            let t0 = now()
            _ = try build(take, kept)
            samples.append(now() - t0)
        }
        samples.sort()
        print(String(format: "%3d cuts: build median %.3f ms, max %.3f ms", cuts, samples[10], samples[19]))
    }
}

let mode = arguments[1]
Task { @MainActor in
    do {
        switch mode {
        case "audio": try await audio()
        case "frames": try await frames()
        case "replace": try await replace()
        case "build": try await buildCost()
        case "seek": try await seekOnly()
        default: print("unknown mode \(mode)")
        }
    } catch {
        print("failed: \(error)")
        exit(1)
    }
    exit(0)
}
dispatchMain()
