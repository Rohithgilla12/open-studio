import AVFoundation
import CoreVideo
import Foundation

let args = CommandLine.arguments
let width = 1920
let height = 1080
let fps: Int32 = 30

func makeFrame(index: Int, pool: CVPixelBufferPool) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    let pb = buffer!
    CVPixelBufferLockBaseAddress(pb, [])
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pb)
    let shade = UInt8(index * 7 % 256)
    for y in 0..<height {
        let row = base + y * stride
        let bar = (y + index * 8) % height < 120
        memset(row, Int32(bar ? 255 - shade : shade), width * 4)
    }
    CVPixelBufferUnlockBaseAddress(pb, [])
    return pb
}

func write(path: String, fragment: Double, codec: String, seconds: Double) throws {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    if fragment > 0 {
        writer.movieFragmentInterval = CMTime(seconds: fragment, preferredTimescale: 600)
    }
    let settings: [String: Any] = [
        AVVideoCodecKey: codec == "h264" ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2],
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = true
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error! }
    writer.startSession(atSourceTime: .zero)
    let total = Int(seconds * Double(fps))
    let start = Date()
    for i in 0..<total {
        let due = start.addingTimeInterval(Double(i) / Double(fps))
        let wait = due.timeIntervalSinceNow
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
        let frame = makeFrame(index: i, pool: adaptor.pixelBufferPool!)
        adaptor.append(frame, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        if i % Int(fps) == 0 { print("wrote frame \(i)"); fflush(stdout) }
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    print("finished status=\(writer.status.rawValue)")
}

func read(path: String) async {
    let url = URL(fileURLWithPath: path)
    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? -1
    let asset = AVURLAsset(url: url)
    do {
        let (playable, duration) = try await asset.load(.isPlayable, .duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        var decoded = 0
        var lastPTS = CMTime.invalid
        if let track = tracks.first {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output)
            reader.startReading()
            while let sample = output.copyNextSampleBuffer() {
                if CMSampleBufferGetNumSamples(sample) > 0 {
                    decoded += 1
                    lastPTS = CMSampleBufferGetPresentationTimeStamp(sample)
                }
            }
            if reader.status == .failed { print("reader error: \(reader.error!)") }
        }
        print(String(
            format: "bytes=%d playable=%@ duration=%.3fs videoTracks=%d decodedFrames=%d lastPTS=%.3fs",
            size, playable ? "true" : "false", duration.seconds, tracks.count, decoded,
            lastPTS.isValid ? lastPTS.seconds : -1))
    } catch {
        print("bytes=\(size) load failed: \(error)")
    }
}

func spawn(_ arguments: [String]) throws -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = arguments
    p.standardOutput = FileHandle.nullDevice
    try p.run()
    return p
}

func runSuite(workDir: String, killAfter: Double) throws {
    try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    let cases: [(label: String, fragment: Double, codec: String)] = [
        ("hevc-frag1s", 1, "hevc"), ("hevc-frag1s", 1, "hevc"), ("hevc-frag1s", 1, "hevc"),
        ("h264-frag1s", 1, "h264"),
        ("hevc-nofrag", 0, "hevc"), ("hevc-nofrag", 0, "hevc"), ("hevc-nofrag", 0, "hevc"),
    ]
    for (n, c) in cases.enumerated() {
        let path = "\(workDir)/\(n)-\(c.label).mov"
        let child = try spawn(["write", path, String(c.fragment), c.codec, "10"])
        Thread.sleep(forTimeInterval: killAfter)
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
        let reader = Process()
        reader.executableURL = URL(fileURLWithPath: args[0])
        reader.arguments = ["read", path]
        let pipe = Pipe()
        reader.standardOutput = pipe
        try reader.run()
        reader.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
        print("\(c.label) run \(n) killed after \(killAfter)s (signal \(child.terminationReason == .uncaughtSignal ? "SIGKILL" : "?")): \(out.trimmingCharacters(in: .newlines))")
    }
}

switch args.dropFirst().first {
case "write":
    try write(path: args[2], fragment: Double(args[3])!, codec: args[4], seconds: Double(args[5])!)
case "read":
    await read(path: args[2])
case "run":
    try runSuite(workDir: args[2], killAfter: Double(args[3])!)
default:
    print("usage: write|read|run")
    exit(2)
}
