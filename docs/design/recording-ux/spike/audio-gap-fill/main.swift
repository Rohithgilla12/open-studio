// How much silence can an AAC AVAssetWriterInput take in one burst, the way AudioTrackWriter.fill
// writes a whole gap when the first buffer after it arrives? A pause makes that gap as long as the
// pause, so the answer decides whether a resume can fill it in one go or the pause must be filled
// as it happens.
//
//   swiftc -O main.swift -o /tmp/audio-gap-fill && /tmp/audio-gap-fill /tmp/gap 60 600
import AVFoundation
import CoreMedia
import Foundation

let sampleRate = 48_000.0
let channels: UInt32 = 2

func makeFormat() -> CMAudioFormatDescription {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: channels, mBitsPerChannel: 32,
        mReserved: 0)
    var description: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(
        allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &description)
    return description!
}

let format = makeFormat()

func buffer(frames: Int, at seconds: Double, tone: Bool) -> CMSampleBuffer {
    let length = frames * 4 * Int(channels)
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(
        allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil,
        offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
    var samples = [Float](repeating: 0, count: frames * Int(channels))
    if tone {
        for i in 0..<frames {
            let v = Float(sin(2 * Double.pi * 440 * (seconds + Double(i) / sampleRate))) * 0.3
            samples[i] = v
            samples[frames + i] = v
        }
    }
    samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: length) }
    var sample: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: nil, dataBuffer: block!, formatDescription: format, sampleCount: frames,
        presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000), packetDescriptions: nil,
        sampleBufferOut: &sample)
    return sample!
}

func run(gapSeconds: Int, directory: URL) async {
    let url = directory.appending(path: "gap-\(gapSeconds).mov")
    try? FileManager.default.removeItem(at: url)
    let writer = try! AVAssetWriter(outputURL: url, fileType: .mov)
    writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
    ])
    input.expectsMediaDataInRealTime = true
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    var t = 0.0
    let chunk = 1024
    func paced(_ seconds: Double) async {
        let end = t + seconds
        while t < end {
            if input.isReadyForMoreMediaData { _ = input.append(buffer(frames: chunk, at: t, tone: true)) }
            t += Double(chunk) / sampleRate
            try? await Task.sleep(for: .microseconds(Int(Double(chunk) / sampleRate * 1e6)))
        }
    }
    await paced(1)

    let burstStart = Date()
    var appended = 0
    var refused = 0
    var firstRefusalAfter: Int?
    for _ in 0..<gapSeconds {
        if input.isReadyForMoreMediaData, input.append(buffer(frames: Int(sampleRate), at: t, tone: false)) {
            appended += 1
            t += 1
        } else {
            refused += 1
            if firstRefusalAfter == nil { firstRefusalAfter = appended }
            break
        }
    }
    let burstMillis = Date().timeIntervalSince(burstStart) * 1000

    var waited = 0
    while appended + refused > 0, !input.isReadyForMoreMediaData, waited < 5000 {
        try? await Task.sleep(for: .milliseconds(1))
        waited += 1
    }
    await paced(1)
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(seconds: t, preferredTimescale: 48_000))
    await writer.finishWriting()
    let duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? .nan
    print(String(
        format: "gap %4d s: burst appended %4d of %4d one-second buffers in %.1f ms; first refusal after %@; ready again after %d ms; file %.3f s, expected %.3f s",
        gapSeconds, appended, gapSeconds, burstMillis, firstRefusalAfter.map(String.init) ?? "none", waited, duration, 2.0 + Double(gapSeconds)))
}

let arguments = CommandLine.arguments
let directory = URL(filePath: arguments.count > 1 ? arguments[1] : NSTemporaryDirectory(), directoryHint: .isDirectory)
try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let gaps = arguments.dropFirst(2).compactMap { Int($0) }
for gap in gaps.isEmpty ? [10, 60, 600] : gaps {
    await run(gapSeconds: gap, directory: directory)
}
