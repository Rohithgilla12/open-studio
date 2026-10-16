import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Timeline

/// A take for GPU tests: the committed Timeline fixture's metadata (1920 x 1080, 12 s, two cursor
/// declarations) plus a generated `screen.mov` of one solid colour, so every content pixel is known.
enum Fixture {
    static let committed = "20261013-five-clicks.osrec"

    static func committedDirectory(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/recordings/\(committed)", directoryHint: .isDirectory)
    }

    /// Copies the committed fixture's metadata to a temporary directory. Project.open never reads
    /// media, so persistence tests need no movie.
    static func metadataOnlyTake() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "RenderTests-\(UUID().uuidString).osrec", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: committedDirectory(), to: directory)
        return directory
    }

    static func setArea(_ area: Rect, in take: URL) throws {
        let url = take.appending(path: "recording.json", directoryHint: .notDirectory)
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        manifest["formatVersion"] = 2
        manifest["area"] = [area.minX, area.minY, area.size.width, area.size.height]
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
    }

    typealias Color = (red: UInt8, green: UInt8, blue: UInt8)

    struct Camera {
        var width = 640
        var height = 360
        var before: (left: Color, right: Color)
        var after: (left: Color, right: Color)
        var changeAt = 1.0
        var from = 0.0
        var until = 2.0
        var fps = 10
    }

    static func addCamera(_ camera: Camera, to take: URL) async throws {
        let url = take.appending(path: "camera.mov", directoryHint: .notDirectory)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: camera.width, AVVideoHeightKey: camera.height,
        ])
        writer.add(input)
        let before = halves(width: camera.width, height: camera.height, camera.before)
        let after = halves(width: camera.width, height: camera.height, camera.after)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let fps = camera.fps
        for index in Int((camera.from * Double(fps)).rounded())..<Int((camera.until * Double(fps)).rounded()) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            let seconds = Double(index) / Double(fps)
            let buffer = seconds < camera.changeAt ? before : after
            input.append(try sample(buffer, at: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))))
        }
        writer.endSession(atSourceTime: CMTime(seconds: camera.until, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }

        let manifestURL = take.appending(path: "recording.json", directoryHint: .notDirectory)
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        manifest["formatVersion"] = 3
        manifest["camera"] = ["deviceName": "Fixture Camera", "pixelWidth": camera.width, "pixelHeight": camera.height, "frameRate": fps]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    }

    private static func halves(width: Int, height: Int, _ colors: (left: Color, right: Color)) -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        let buffer = pixelBuffer!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let color = x < width / 2 ? colors.left : colors.right
                let p = base + y * rowBytes + x * 4
                p[0] = color.blue
                p[1] = color.green
                p[2] = color.red
                p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private static func sample(_ buffer: CVPixelBuffer, at pts: CMTime) throws -> CMSampleBuffer {
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &description)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &sample)
        return sample!
    }

    /// Copies the committed fixture to a temporary directory and writes a solid `screen.mov` into it.
    static func take(color: Color, seconds: Double = 2) async throws -> URL {
        try await take(top: color, bottom: color, seconds: seconds)
    }

    /// As `take(color:)`, with the top and bottom halves of the frame in different colours, so a
    /// flipped crop or placement shows up.
    static func take(top: Color, bottom: Color, seconds: Double = 2) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "RenderTests-\(UUID().uuidString).osrec", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: committedDirectory(), to: directory)
        try await writeMovie(
            to: directory.appending(path: "screen.mov", directoryHint: .notDirectory), width: 1920, height: 1080,
            top: top, bottom: bottom, seconds: seconds)
        return directory
    }

    static func writeMovie(to url: URL, width: Int, height: Int, top: Color, bottom: Color, seconds: Double) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        writer.add(input)
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        let buffer = pixelBuffer!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let color = y < height / 2 ? top : bottom
            for x in 0..<width {
                let p = base + y * rowBytes + x * 4
                p[0] = color.blue
                p[1] = color.green
                p[2] = color.red
                p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &description)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let fps = 10
        for index in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
                presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: nil, imageBuffer: buffer, formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &sample)
            input.append(sample!)
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }
}

/// RGBA8 pixels of a CGImage in sRGB, for sampling.
struct Pixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// (r, g, b) at a top-left position.
    subscript(x: Int, y: Int) -> (red: Int, green: Int, blue: Int) {
        let index = (y * width + x) * 4
        return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
    }
}
