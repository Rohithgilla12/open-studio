import AVFoundation
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3, ["microphone", "system-audio"].contains(arguments[2]) else {
    print("usage: synthetic-audio <take>.osrec microphone|system-audio [frequency-hz] [from-seconds]")
    exit(2)
}
let take = URL(filePath: arguments[1], directoryHint: .isDirectory)
let isSystemAudio = arguments[2] == "system-audio"
let frequency = arguments.count > 3 ? Double(arguments[3])! : (isSystemAudio ? 1000 : 440)
let from = arguments.count > 4 ? Double(arguments[4])! : 0
let channels = isSystemAudio ? 2 : 1
let rate = 48_000

let manifestURL = take.appending(path: "recording.json")
var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
let seconds = Double(manifest["durationMicros"] as! Int) / 1e6

let url = take.appending(path: "\(arguments[2]).mov")
try? FileManager.default.removeItem(at: url)
let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)
let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
    AVEncoderBitRateKey: 96_000 * channels,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

var asbd = AudioStreamBasicDescription(
    mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
    mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
    mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
var format: CMAudioFormatDescription?
CMAudioFormatDescriptionCreate(
    allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
    formatDescriptionOut: &format)

let frames = 1024
var frame = Int(from * Double(rate))
while frame < Int(seconds * Double(rate)) {
    var data = [Float](repeating: 0, count: frames * channels)
    for i in 0..<frames {
        let t = Double(frame + i) / Double(rate)
        let on = t.truncatingRemainder(dividingBy: 1) < 0.5
        let value = on ? Float(0.4 * sin(2 * Double.pi * frequency * t)) : 0
        for channel in 0..<channels { data[i * channels + channel] = value }
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
        presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(rate)), packetDescriptions: nil,
        sampleBufferOut: &sample)
    while !input.isReadyForMoreMediaData { usleep(2_000) }
    input.append(sample!)
    frame += frames
}
writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 1_000_000))
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else {
    print("writing \(url.lastPathComponent) failed: \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")")
    exit(1)
}

if isSystemAudio {
    manifest["formatVersion"] = max(manifest["formatVersion"] as? Int ?? 1, 4)
    manifest["systemAudio"] = ["sampleRate": rate, "channelCount": channels]
} else {
    manifest["microphone"] = ["deviceName": "Synthetic Microphone", "sampleRate": rate, "channelCount": channels]
}
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: manifestURL)
print("wrote \(String(format: "%.3f", seconds - from)) s of \(Int(frequency)) Hz from \(from) s, \(channels) ch, to \(url.path)")
