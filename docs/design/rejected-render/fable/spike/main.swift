// Throughput spike: can Core Image draw the styled frame at 3456x2234, 60 fps, faster than real time?
//
// Reads screen.mov with AVAssetReader (sample-and-hold to a 60 fps grid), draws the backdrop once,
// then per frame crops a moving 1x..2x viewport, scales it into the padded content rect, masks the
// corners, composites a cursor, and either renders to a pooled BGRA buffer (mode "render") or also
// encodes HEVC through AVAssetWriter (mode "export").
//
//   swiftc -O -o spike main.swift
//   ./spike <screen.mov> <out.mp4> render|export [frames]

import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal

let args = CommandLine.arguments
guard args.count >= 4 else {
    print("usage: spike <screen.mov> <out.mp4> render|export [frames]")
    exit(2)
}
let inputURL = URL(fileURLWithPath: args[1])
let outputURL = URL(fileURLWithPath: args[2])
let mode = args[3]
let fps: Int32 = 60

let asset = AVURLAsset(url: inputURL)
let track = try await asset.loadTracks(withMediaType: .video).first!
let duration = try await asset.load(.duration)
let natural = try await track.load(.naturalSize)
let srcW = Int(natural.width), srcH = Int(natural.height)
let outW = srcW, outH = srcH
let frameCount = args.count >= 5 ? Int(args[4])! : Int(duration.seconds * Double(fps))

let reader = try AVAssetReader(asset: asset)
let readerOut = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    kCVPixelBufferMetalCompatibilityKey as String: true,
])
reader.add(readerOut)
reader.startReading()

let device = MTLCreateSystemDefaultDevice()!
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CIContext(mtlDevice: device, options: [
    .workingColorSpace: srgb, .outputColorSpace: srgb, .cacheIntermediates: false, .name: "spike",
])

var pool: CVPixelBufferPool?
CVPixelBufferPoolCreate(nil, nil, [
    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey: outW, kCVPixelBufferHeightKey: outH,
    kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    kCVPixelBufferMetalCompatibilityKey: true,
] as CFDictionary, &pool)

// Geometry: content rect is the source aspect fitted inside a 6% padding, in CI (y-up) coordinates.
let outRect = CGRect(x: 0, y: 0, width: outW, height: outH)
let padding = 0.06 * Double(min(outW, outH))
let fitW = Double(outW) - 2 * padding
let fitH = Double(outH) - 2 * padding
let scaleFit = min(fitW / Double(srcW), fitH / Double(srcH))
let contentW = Double(srcW) * scaleFit, contentH = Double(srcH) * scaleFit
let contentRect = CGRect(x: (Double(outW) - contentW) / 2, y: (Double(outH) - contentH) / 2, width: contentW, height: contentH)
let cornerRadius = 0.012 * Double(min(outW, outH))

func makeBackdrop() -> CIImage {
    let gradient = CIFilter.linearGradient()
    gradient.point0 = CGPoint(x: 0, y: 0)
    gradient.point1 = CGPoint(x: outW, y: outH)
    gradient.color0 = CIColor(red: 0.13, green: 0.16, blue: 0.32)
    gradient.color1 = CIColor(red: 0.55, green: 0.22, blue: 0.42)
    let background = gradient.outputImage!.cropped(to: outRect)

    let rounded = CIFilter.roundedRectangleGenerator()
    rounded.extent = contentRect
    rounded.radius = Float(cornerRadius)
    rounded.color = .white
    let toShadow = CIFilter.colorMatrix()
    toShadow.inputImage = rounded.outputImage!.transformed(by: CGAffineTransform(translationX: 0, y: -0.012 * Double(min(outW, outH))))
        .applyingGaussianBlur(sigma: 0.03 * Double(min(outW, outH)))
    toShadow.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
    toShadow.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
    toShadow.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
    toShadow.aVector = CIVector(x: 0, y: 0, z: 0, w: 0.5)
    let composed = toShadow.outputImage!.composited(over: background).cropped(to: outRect)

    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &buffer)
    context.render(composed, to: buffer!, bounds: outRect, colorSpace: srgb)
    return CIImage(cvPixelBuffer: buffer!)
}

let backdrop = makeBackdrop()
let roundedMask: CIImage = {
    let rounded = CIFilter.roundedRectangleGenerator()
    rounded.extent = contentRect
    rounded.radius = Float(cornerRadius)
    rounded.color = .white
    return rounded.outputImage!.cropped(to: outRect)
}()
let cursorImage = CIImage(color: CIColor(red: 1, green: 0.25, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 56, height: 80))

/// A viewport that breathes between 1x and 2x and drifts, in source pixels, y-down.
func viewport(at t: Double) -> (rect: CGRect, scale: Double) {
    let s = 1 + 0.5 * (1 - cos(2 * .pi * t / 4))
    let w = Double(srcW) / s, h = Double(srcH) / s
    var cx = Double(srcW) / 2 + 400 * sin(t), cy = Double(srcH) / 2 + 300 * cos(1.3 * t)
    cx = min(max(cx, w / 2), Double(srcW) - w / 2)
    cy = min(max(cy, h / 2), Double(srcH) - h / 2)
    return (CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h), s)
}

func compose(source: CVPixelBuffer, t: Double) -> CIImage {
    let (vp, _) = viewport(at: t)
    // Timeline is y-down; Core Image is y-up. One flip at this boundary.
    let crop = CGRect(x: vp.minX, y: Double(srcH) - vp.maxY, width: vp.width, height: vp.height)
    let s = contentRect.width / vp.width
    let toContent = CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
        .concatenating(CGAffineTransform(scaleX: s, y: s))
        .concatenating(CGAffineTransform(translationX: contentRect.minX, y: contentRect.minY))
    let content = CIImage(cvPixelBuffer: source).cropped(to: crop).transformed(by: toContent)

    let blend = CIFilter.blendWithMask()
    blend.inputImage = content
    blend.backgroundImage = backdrop
    blend.maskImage = roundedMask
    let masked = blend.outputImage!

    // Cursor hotspot at a point moving inside the viewport; drawn in source space then mapped.
    let hot = CGPoint(x: vp.midX + 200 * sin(3 * t), y: vp.midY + 150 * cos(2 * t))
    let hotCI = CGPoint(x: hot.x, y: Double(srcH) - hot.y)
    let cursorToOutput = CGAffineTransform(translationX: hotCI.x - 10, y: hotCI.y - 70)
        .concatenating(toContent)
    let cursor = cursorImage.transformed(by: cursorToOutput)
    return cursor.composited(over: masked).cropped(to: outRect)
}

var writer: AVAssetWriter?
var writerInput: AVAssetWriterInput?
var adaptor: AVAssetWriterInputPixelBufferAdaptor?
if mode == "export" {
    try? FileManager.default.removeItem(at: outputURL)
    let w = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.hevc,
        AVVideoWidthKey: outW, AVVideoHeightKey: outH,
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
    ])
    input.expectsMediaDataInRealTime = false
    adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    w.add(input)
    w.startWriting()
    w.startSession(atSourceTime: .zero)
    writer = w
    writerInput = input
}

var current: CVPixelBuffer?
var pending = readerOut.copyNextSampleBuffer()
var sourceFrames = 0
var renderSeconds = 0.0
let started = CFAbsoluteTimeGetCurrent()
for k in 0..<frameCount {
    let t = CMTime(value: Int64(k), timescale: fps)
    while let sample = pending, CMSampleBufferGetPresentationTimeStamp(sample) <= t {
        current = CMSampleBufferGetImageBuffer(sample)
        sourceFrames += 1
        pending = readerOut.copyNextSampleBuffer()
    }
    guard let source = current else { continue }
    var out: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &out)
    let image = compose(source: source, t: t.seconds)
    let r0 = CFAbsoluteTimeGetCurrent()
    context.render(image, to: out!, bounds: outRect, colorSpace: srgb)
    renderSeconds += CFAbsoluteTimeGetCurrent() - r0
    if k == 90 {
        let png = context.pngRepresentation(of: CIImage(cvPixelBuffer: out!), format: .BGRA8, colorSpace: srgb)!
        try png.write(to: outputURL.deletingPathExtension().appendingPathExtension("\(mode)-frame90.png"))
    }
    if let writerInput, let adaptor {
        while !writerInput.isReadyForMoreMediaData { usleep(500) }
        adaptor.append(out!, withPresentationTime: t)
    }
}
if let writer, let writerInput {
    writerInput.markAsFinished()
    await writer.finishWriting()
    if writer.status != .completed { print("writer failed: \(String(describing: writer.error))") }
}
let elapsed = CFAbsoluteTimeGetCurrent() - started
print(String(
    format: "%@: %dx%d, %d output frames from %d source frames in %.2f s = %.1f fps (%.2fx real time); ci render %.2f ms/frame",
    mode, outW, outH, frameCount, sourceFrames, elapsed, Double(frameCount) / elapsed,
    (Double(frameCount) / Double(fps)) / elapsed, renderSeconds * 1000 / Double(frameCount)))
