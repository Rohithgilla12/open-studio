// Adds a generated camera.mov to a copy of a take, so the camera overlay can be exported, measured,
// and shown in the app without opening a real camera.
//
//     swiftc -O Experiments/synthetic-camera/main.swift -o /tmp/synthetic-camera
//     /tmp/synthetic-camera <take>.osrec [width height]
//
// The picture changes colour every 2 s, carries the recording time in large digits and a bar that
// sweeps once a second, and has a different left and right half so mirroring shows. The manifest
// gets the camera key and format version 3, as the recorder writes them.
import AVFoundation
import CoreText
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 || arguments.count == 4 else {
    print("usage: synthetic-camera <take>.osrec [width height]")
    exit(2)
}
let take = URL(filePath: arguments[1], directoryHint: .isDirectory)
let width = arguments.count == 4 ? Int(arguments[2])! : 1920
let height = arguments.count == 4 ? Int(arguments[3])! : 1080
let fps = 30

let manifestURL = take.appending(path: "recording.json")
var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
let seconds = Double(manifest["durationMicros"] as! Int) / 1e6

let palette: [(CGFloat, CGFloat, CGFloat)] = [(0.85, 0.45, 0.30), (0.25, 0.55, 0.80), (0.35, 0.70, 0.40), (0.70, 0.35, 0.75)]

func frame(at t: Double) -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
    let buffer = pixelBuffer!
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let (r, g, b) = palette[Int(t / 2) % palette.count]
    context.setFillColor(red: r, green: g, blue: b, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    context.setFillColor(red: r * 0.6, green: g * 0.6, blue: b * 0.6, alpha: 1)
    context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.9)
    let sweep = t.truncatingRemainder(dividingBy: 1)
    context.fill(CGRect(x: 0, y: 0, width: Double(width) * sweep, height: Double(height) * 0.04))
    context.fillEllipse(in: CGRect(x: Double(width) * 0.38, y: Double(height) * 0.30, width: Double(width) * 0.24, height: Double(width) * 0.24))
    let text = String(format: "%.1f s", t)
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, Double(height) * 0.16, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    context.textPosition = CGPoint(x: Double(width) * 0.06, y: Double(height) * 0.10)
    CTLineDraw(line, context)
    return buffer
}

let url = take.appending(path: "camera.mov")
try? FileManager.default.removeItem(at: url)
let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: fps * 2, AVVideoQualityKey: 0.85],
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)
let count = Int(seconds * Double(fps))
for index in 0..<count {
    while !input.isReadyForMoreMediaData { usleep(2_000) }
    let image = frame(at: Double(index) / Double(fps))
    var description: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &description)
    var timing = CMSampleTimingInfo(
        duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
        allocator: nil, imageBuffer: image, formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &sample)
    input.append(sample!)
}
writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 1_000_000))
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else {
    print("writing camera.mov failed: \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")")
    exit(1)
}

manifest["formatVersion"] = 3
manifest["camera"] = ["deviceName": "Synthetic Camera", "pixelWidth": width, "pixelHeight": height, "frameRate": fps]
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: manifestURL)
print("wrote \(count) frames, \(width)x\(height) at \(fps) fps, to \(url.path)")
