// How long does it take to create the take directory and every writer and start their sessions?
// The design creates them only when the countdown ends, so nothing exists on disk while counting
// down, and this time sits between "1" and the first frame the writers can take.
//
//   swiftc -O main.swift -o /tmp/writer-startup && /tmp/writer-startup /tmp/startup 10
import AVFoundation
import CoreMedia
import Foundation

func video(_ width: Int, _ height: Int, _ rate: Int) -> [String: Any] {
    [
        AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: rate * 2, AVVideoQualityKey: 0.85],
    ]
}

func audio(_ channels: Int) -> [String: Any] {
    [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 96_000 * channels]
}

let plan: [(String, AVMediaType, [String: Any])] = [
    ("screen.mov", .video, video(3456, 2234, 60)),
    ("camera.mov", .video, video(1920, 1080, 30)),
    ("microphone.mov", .audio, audio(1)),
    ("system-audio.mov", .audio, audio(2)),
]

let arguments = CommandLine.arguments
let parent = URL(filePath: arguments.count > 1 ? arguments[1] : NSTemporaryDirectory(), directoryHint: .isDirectory)
let runs = arguments.count > 2 ? Int(arguments[2]) ?? 10 : 10
var totals: [Double] = []
var configures: [Double] = []
var starts: [Double] = []

func milliseconds(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

func summary(_ label: String, _ values: [Double]) -> String {
    let sorted = values.sorted()
    return String(format: "%@ first %.1f ms, median %.1f ms, max %.1f ms", label, values[0], sorted[sorted.count / 2], sorted.last!)
}
for run in 0..<runs {
    let clock = ContinuousClock()
    let started = clock.now
    let directory = parent.appending(path: "take-\(run).osrec", directoryHint: .isDirectory)
    try? FileManager.default.removeItem(at: directory)
    var writers: [AVAssetWriter] = []
    for (name, type, settings) in plan {
        let writer = try! AVAssetWriter(outputURL: directory.appending(path: name), fileType: .mov)
        writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)
        precondition(writer.canApply(outputSettings: settings, forMediaType: type))
        let input = AVAssetWriterInput(mediaType: type, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writers.append(writer)
    }
    let configured = clock.now
    precondition(!FileManager.default.fileExists(atPath: directory.path), "init alone created the directory")
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for writer in writers {
        precondition(writer.startWriting(), "\(writer.outputURL.lastPathComponent): \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
    }
    let finished = clock.now
    totals.append(milliseconds(finished - started))
    configures.append(milliseconds(configured - started))
    starts.append(milliseconds(finished - configured))
    for writer in writers { writer.cancelWriting() }
    try? FileManager.default.removeItem(at: directory)
}
print("\(runs) runs. " + summary("init + add inputs:", configures) + ". " + summary("startWriting + startSession:", starts) + ". " + summary("total:", totals))
