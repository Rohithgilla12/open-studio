// Spike: does a custom AVVideoCompositionInstruction carry an immutable scene to a Core Image
// compositor, and does AVAssetReaderVideoCompositionOutput -> AVAssetWriter sustain 4K60 from a
// real variable-frame-rate 3456x2234 take?
//
// swiftc -O main.swift -o spike && ./spike <take.osrec> <out.mp4> <width> <height> <fps> <bilinear|lanczos> [nowrite]
import AppKit
import AVFoundation
import CoreImage
import Foundation

final class Scene: @unchecked Sendable {
    let sourceSize: CGSize
    let outputSize: CGSize
    let contentRect: CGRect
    let backdrop: CIImage
    let mask: CIImage
    let cursor: CIImage
    let lanczos: Bool

    init(sourceSize: CGSize, outputSize: CGSize, cursorURL: URL, lanczos: Bool, context: CIContext) {
        self.sourceSize = sourceSize
        self.outputSize = outputSize
        self.lanczos = lanczos
        let pad = min(outputSize.width, outputSize.height) * 0.08
        let avail = CGRect(origin: .zero, size: outputSize).insetBy(dx: pad, dy: pad)
        let k = min(avail.width / sourceSize.width, avail.height / sourceSize.height)
        let size = CGSize(width: sourceSize.width * k, height: sourceSize.height * k)
        contentRect = CGRect(x: (outputSize.width - size.width) / 2, y: (outputSize.height - size.height) / 2,
                             width: size.width, height: size.height).integral
        let radius = min(contentRect.width, contentRect.height) * 0.025
        let full = CGRect(origin: .zero, size: outputSize)
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: outputSize.width, y: outputSize.height),
            "inputColor0": CIColor(red: 0.12, green: 0.20, blue: 0.45), "inputColor1": CIColor(red: 0.55, green: 0.25, blue: 0.55),
        ])!.outputImage!.cropped(to: full)
        let shadowShape = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: contentRect.offsetBy(dx: 0, dy: -pad * 0.15)), "inputRadius": radius,
            "inputColor": CIColor(red: 0, green: 0, blue: 0, alpha: 0.45),
        ])!.outputImage!
        let shadow = shadowShape.applyingGaussianBlur(sigma: pad * 0.25).cropped(to: full)
        // Pre-rendered once, so per frame the backdrop is one texture read.
        let cg = context.createCGImage(shadow.composited(over: gradient), from: full)!
        backdrop = CIImage(cgImage: cg)
        mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: contentRect), "inputRadius": radius, "inputColor": CIColor.white,
        ])!.outputImage!
        cursor = CIImage(contentsOf: cursorURL)!
    }

    func image(source: CIImage, t: Double) -> CIImage {
        // A 2x zoom whose centre sweeps across the frame, standing in for Timeline.frame(at:).
        let zoom = 1 + (sin(t * 1.3) * 0.5 + 0.5)
        let vw = sourceSize.width / zoom, vh = sourceSize.height / zoom
        let cx = sourceSize.width / 2 + sin(t * 0.7) * (sourceSize.width - vw) / 2
        let cy = sourceSize.height / 2 + cos(t * 0.9) * (sourceSize.height - vh) / 2
        let viewport = CGRect(x: cx - vw / 2, y: cy - vh / 2, width: vw, height: vh)
        let k = contentRect.width / viewport.width
        var content = source.cropped(to: viewport).transformed(by: CGAffineTransform(translationX: -viewport.minX, y: -viewport.minY))
        if lanczos {
            content = content.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": k, "inputAspectRatio": 1])
        } else {
            content = content.transformed(by: CGAffineTransform(scaleX: k, y: k))
        }
        content = content.transformed(by: CGAffineTransform(translationX: contentRect.minX, y: contentRect.minY))
        let screen = content.applyingFilter("CIBlendWithMask", parameters: ["inputBackgroundImage": backdrop, "inputMaskImage": mask])
        let cursorScale = k * 0.5
        let p = CGPoint(x: contentRect.midX + sin(t * 3) * 300, y: contentRect.midY + cos(t * 2) * 200)
        let c = cursor.transformed(by: CGAffineTransform(scaleX: cursorScale, y: cursorScale))
            .transformed(by: CGAffineTransform(translationX: p.x, y: p.y))
        return c.composited(over: screen).cropped(to: CGRect(origin: .zero, size: outputSize))
    }
}

final class SceneInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let trackID: CMPersistentTrackID
    let scene: Scene

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, scene: Scene) {
        self.timeRange = timeRange
        self.trackID = trackID
        requiredSourceTrackIDs = [NSNumber(value: trackID)]
        self.scene = scene
    }
}

let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates: false])
let outputSpace = CGColorSpace(name: CGColorSpace.itur_709)!
nonisolated(unsafe) var renderNanos: UInt64 = 0
nonisolated(unsafe) var requestCount = 0
nonisolated(unsafe) var sourceTimes: [Double] = []

final class Compositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    let queue = DispatchQueue(label: "render")
    // SPIKE_INFLIGHT=n renders up to n requests concurrently; CIContext is thread-safe.
    static let inflight = Int(ProcessInfo.processInfo.environment["SPIKE_INFLIGHT"] ?? "1")!
    let renderQueue = DispatchQueue(label: "render.work", attributes: Compositor.inflight > 1 ? .concurrent : [])
    let slots = DispatchSemaphore(value: Compositor.inflight)
    let stats = NSLock()
    var renderContext: AVVideoCompositionRenderContext?
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        queue.sync { renderContext = newRenderContext }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let renderContext = queue.sync { self.renderContext }
        slots.wait()
        renderQueue.async { [self] in
            defer { slots.signal() }
            let start = DispatchTime.now().uptimeNanoseconds
            let instruction = request.videoCompositionInstruction as! SceneInstruction
            let source = request.sourceFrame(byTrackID: instruction.trackID)!
            let out = renderContext!.newPixelBuffer()!
            let t = request.compositionTime.seconds
            let image = instruction.scene.image(source: CIImage(cvPixelBuffer: source), t: t)
            context.render(image, to: out, bounds: CGRect(origin: .zero, size: instruction.scene.outputSize), colorSpace: outputSpace)
            stats.lock()
            renderNanos += DispatchTime.now().uptimeNanoseconds - start
            requestCount += 1
            stats.unlock()
            request.finish(withComposedVideoFrame: out)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}

let args = CommandLine.arguments
let take = URL(filePath: args[1])
let outURL = URL(filePath: args[2])
let outSize = CGSize(width: Double(args[3])!, height: Double(args[4])!)
let fps = Int32(args[5])!
let lanczos = args[6] == "lanczos"
let write = args.count < 8

let asset = AVURLAsset(url: take.appending(path: "screen.mov"))
let track = try await asset.loadTracks(withMediaType: .video)[0]
let duration = try await asset.load(.duration)
let natural = try await track.load(.naturalSize)
let composition = AVMutableComposition()
let compTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)

let cursorURL = try FileManager.default.contentsOfDirectory(at: take.appending(path: "cursors"), includingPropertiesForKeys: nil)[0]
let scene = Scene(sourceSize: natural, outputSize: outSize, cursorURL: cursorURL, lanczos: lanczos, context: context)
let videoComposition = AVMutableVideoComposition()
videoComposition.customVideoCompositorClass = Compositor.self
videoComposition.renderSize = outSize
videoComposition.frameDuration = CMTime(value: 1, timescale: fps)
videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
videoComposition.instructions = [SceneInstruction(timeRange: CMTimeRange(start: .zero, duration: duration), trackID: compTrack.trackID, scene: scene)]

let reader = try AVAssetReader(asset: composition)
let output = AVAssetReaderVideoCompositionOutput(videoTracks: [compTrack], videoSettings: nil)
output.videoComposition = videoComposition
output.alwaysCopiesSampleData = false
reader.add(output)

try? FileManager.default.removeItem(at: outURL)
let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.hevc,
    AVVideoWidthKey: outSize.width, AVVideoHeightKey: outSize.height,
    AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ],
])
writer.add(input)

let wallStart = DispatchTime.now().uptimeNanoseconds
reader.startReading()
var frames = 0
var outTimes: [Double] = []
if write {
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var n = 0
    nonisolated(unsafe) var times: [Double] = []
    input.requestMediaDataWhenReady(on: DispatchQueue(label: "writer")) {
        while input.isReadyForMoreMediaData {
            guard let sample = output.copyNextSampleBuffer() else {
                input.markAsFinished()
                done.signal()
                return
            }
            times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            input.append(sample)
            n += 1
        }
    }
    done.wait()
    await writer.finishWriting()
    frames = n
    outTimes = times
} else {
    while let sample = output.copyNextSampleBuffer() {
        outTimes.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        frames += 1
    }
}
let wall = Double(DispatchTime.now().uptimeNanoseconds - wallStart) / 1e9
let deltas = zip(outTimes, outTimes.dropFirst()).map { $1 - $0 }
print(String(format: "source %.0fx%.0f %.3fs -> out %.0fx%.0f @%d %@ write=%@", natural.width, natural.height, duration.seconds, outSize.width, outSize.height, fps, lanczos ? "lanczos" : "bilinear", write ? "yes" : "no"))
print(String(format: "frames %d, wall %.3fs, %.1f fps (%.2fx real time), compositor mean %.2f ms/frame over %d requests", frames, wall, Double(frames) / wall, duration.seconds / wall, Double(renderNanos) / Double(max(requestCount, 1)) / 1e6, requestCount))
print(String(format: "output PTS delta min %.5f max %.5f", deltas.min() ?? 0, deltas.max() ?? 0))
print("reader status \(reader.status.rawValue) error \(String(describing: reader.error)) writer \(writer.status.rawValue) \(String(describing: writer.error))")

_ = NSApplication.shared
let cursorImage = NSCursor.arrow.image
print("NSCursor.arrow size \(cursorImage.size) reps: " + cursorImage.representations.map { "\($0.className) \($0.pixelsWide)x\($0.pixelsHigh)" }.joined(separator: ", "))
let ibeam = NSCursor.iBeam.image
print("NSCursor.iBeam size \(ibeam.size) reps: " + ibeam.representations.map { "\($0.className) \($0.pixelsWide)x\($0.pixelsHigh)" }.joined(separator: ", "))
