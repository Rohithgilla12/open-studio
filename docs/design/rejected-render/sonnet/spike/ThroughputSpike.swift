import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import ImageIO
import Metal

// Usage: ThroughputSpike <screen.mov> <cursor.png> <outW> <outH> [out.png]
// Decodes 60 frames once, then renders them repeatedly through (a) Core Image and (b) one Metal pass,
// and prints ms per frame. Decode time is reported separately so it is in neither number.

let args = CommandLine.arguments
let movie = URL(filePath: args[1])
let cursorURL = URL(filePath: args[2])
let outW = Int(args[3])!
let outH = Int(args[4])!

func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e6 }

let asset = AVURLAsset(url: movie)
let track = try await asset.loadTracks(withMediaType: .video)[0]
let reader = try AVAssetReader(asset: asset)
let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    kCVPixelBufferMetalCompatibilityKey as String: true,
])
reader.add(out)
reader.startReading()
var frames: [CVPixelBuffer] = []
let d0 = now()
var decoded = 0
while let sb = out.copyNextSampleBuffer() {
    decoded += 1
    if frames.count < 60, let pb = CMSampleBufferGetImageBuffer(sb) { frames.append(pb) }
    if decoded >= 120 { break }
}
print(String(format: "decode: %d frames, %.2f ms/frame (HEVC to 420v)", decoded, (now() - d0) / Double(decoded)))
let srcW = Double(CVPixelBufferGetWidth(frames[0]))
let srcH = Double(CVPixelBufferGetHeight(frames[0]))

func makeOutBuffer() -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, outW, outH, kCVPixelFormatType_32BGRA, [
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ] as CFDictionary, &pb)
    return pb!
}

struct Cam { var vx, vy, vw, vh: Double }
func cam(_ i: Int) -> Cam {
    let s = 1 + Double(i % 60) / 60
    let w = srcW / s
    let h = srcH / s
    let cx = srcW * (0.3 + 0.4 * Double(i % 30) / 30)
    let cy = srcH / 2
    return Cam(vx: min(max(cx - w / 2, 0), srcW - w), vy: min(max(cy - h / 2, 0), srcH - h), vw: w, vh: h)
}

let pad = 0.06
let content = (x: Double(outW) * pad, y: Double(outH) * pad, w: Double(outW) * (1 - 2 * pad), h: Double(outH) * (1 - 2 * pad))
let radius = 0.012 * Double(outW)
let iterations = 300

do {
    let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    let cursor = CIImage(contentsOf: cursorURL)!
    let dst = makeOutBuffer()
    func renderCI(_ i: Int) {
        let c = cam(i)
        var img = CIImage(cvPixelBuffer: frames[i % frames.count])
        let sx = content.w / c.vw
        let sy = content.h / c.vh
        let flippedY = srcH - c.vy - c.vh
        img = img.cropped(to: CGRect(x: c.vx, y: flippedY, width: c.vw, height: c.vh))
            .transformed(by: CGAffineTransform(translationX: -c.vx, y: -flippedY))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: content.x, y: Double(outH) - content.y - content.h))
        let rect = CGRect(x: content.x, y: Double(outH) - content.y - content.h, width: content.w, height: content.h)
        let rr = CIFilter.roundedRectangleGenerator()
        rr.extent = rect
        rr.radius = Float(radius)
        rr.color = .white
        let mask = rr.outputImage!
        let rounded = img.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
        ])
        let full = CGRect(x: 0, y: 0, width: outW, height: outH)
        let shadowMask = mask.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.01 * Double(outW)])
            .transformed(by: CGAffineTransform(translationX: 0, y: -0.01 * Double(outH)))
        let shadow = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.45)).cropped(to: full)
            .applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: shadowMask,
            ])
        let grad = CIFilter.linearGradient()
        grad.point0 = CGPoint(x: 0, y: Double(outH))
        grad.point1 = CGPoint(x: Double(outW), y: 0)
        grad.color0 = CIColor(red: 0.20, green: 0.25, blue: 0.55)
        grad.color1 = CIColor(red: 0.55, green: 0.25, blue: 0.45)
        var comp = rounded.composited(over: shadow.composited(over: grad.outputImage!))
        let cpos = CGPoint(x: content.x + (1000 - c.vx) * sx, y: Double(outH) - (content.y + (600 - c.vy) * sy))
        let curs = cursor.transformed(by: CGAffineTransform(translationX: -10, y: -(80 - 10)))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sx))
            .transformed(by: CGAffineTransform(translationX: cpos.x, y: cpos.y))
        comp = curs.composited(over: comp)
        ctx.render(comp.cropped(to: full), to: dst)
    }
    for i in 0..<20 { renderCI(i) }
    let t0 = now()
    for i in 0..<iterations { renderCI(i) }
    let ms = (now() - t0) / Double(iterations)
    print(String(format: "CoreImage  %dx%d: %.2f ms/frame (%.0f fps)", outW, outH, ms, 1000 / ms))
}

let shader = """
#include <metal_stdlib>
using namespace metal;
struct U {
  float2 outSize; float2 pad0; float4 content; float radius; float3 pad1; float4 view; float2 srcSize;
  float shadowSigma; float shadowDy; float shadowAlpha; float3 pad2;
  float3 c0; float pad3; float3 c1; float pad4; float4 cursorRect; float cursorAlpha; float3 pad5;
};
struct VOut { float4 pos [[position]]; };
vertex VOut vs(uint vid [[vertex_id]]) {
  float2 p = float2((vid << 1) & 2, vid & 2);
  VOut o; o.pos = float4(p * 2 - 1, 0, 1); o.pos.y = -o.pos.y; return o;
}
float sdRound(float2 p, float2 c, float2 h, float r) {
  float2 q = abs(p - c) - h + r; return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}
float3 yuv(texture2d<float> ty, texture2d<float> tc, sampler s, float2 uv) {
  float y = ty.sample(s, uv).r; float2 c = tc.sample(s, uv).rg;
  y = (y - 16.0/255) * 255/219; float cb = (c.x - 128.0/255) * 255/224, cr = (c.y - 128.0/255) * 255/224;
  return saturate(float3(y + 1.5748*cr, y - 0.1873*cb - 0.4681*cr, y + 1.8556*cb));
}
float erf_(float x) {
  float t = 1.0/(1.0+0.3275911*fabs(x));
  float y = 1 - (((((1.061405429*t - 1.453152027)*t) + 1.421413741)*t - 0.284496736)*t + 0.254829592)*t*exp(-x*x);
  return x >= 0 ? y : -y;
}
fragment float4 fs(VOut in [[stage_in]], constant U& u [[buffer(0)]],
  texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]], texture2d<float> cur [[texture(2)]]) {
  constexpr sampler s(filter::linear, address::clamp_to_edge);
  float2 p = in.pos.xy;
  float2 ctr = u.content.xy + u.content.zw * 0.5, hs = u.content.zw * 0.5;
  float d = sdRound(p, ctr, hs, u.radius);
  float t = (p.x / u.outSize.x + p.y / u.outSize.y) * 0.5;
  float3 col = mix(u.c0, u.c1, t);
  float ds = sdRound(p - float2(0, u.shadowDy), ctr, hs, u.radius);
  float sh = 0.5 * (1 - erf_(ds / (u.shadowSigma * 1.41421356))) * u.shadowAlpha;
  col = mix(col, float3(0), sh);
  float cover = saturate(0.5 - d);
  if (cover > 0) {
    float2 uvp = (p - u.content.xy) / u.content.zw;
    float2 sp = u.view.xy + uvp * u.view.zw;
    col = mix(col, yuv(ty, tc, s, sp / u.srcSize), cover);
  }
  if (u.cursorAlpha > 0) {
    float2 cp = (p - u.cursorRect.xy) / u.cursorRect.zw;
    if (all(cp >= 0) && all(cp <= 1)) {
      float4 c = cur.sample(s, cp);
      col = col * (1 - c.a * u.cursorAlpha) + c.rgb * u.cursorAlpha;
    }
  }
  float dither = fract(52.9829189 * fract(dot(p, float2(0.06711056, 0.00583715)))) - 0.5;
  return float4(col + dither / 255.0, 1);
}
"""

func loadCursorTexture(_ dev: MTLDevice, _ url: URL) -> MTLTexture {
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let w = img.width
    let h = img.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let cg = CGContext(
        data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    cg.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
    let t = dev.makeTexture(descriptor: d)!
    t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
    return t
}

struct U {
    var outSize: SIMD2<Float>
    var pad0: SIMD2<Float> = .zero
    var content: SIMD4<Float>
    var radius: Float
    var pad1: SIMD3<Float> = .zero
    var view: SIMD4<Float>
    var srcSize: SIMD2<Float>
    var shadowSigma: Float
    var shadowDy: Float
    var shadowAlpha: Float
    var pad2: SIMD3<Float> = .zero
    var c0: SIMD3<Float>
    var pad3: Float = 0
    var c1: SIMD3<Float>
    var pad4: Float = 0
    var cursorRect: SIMD4<Float>
    var cursorAlpha: Float
    var pad5: SIMD3<Float> = .zero
}

do {
    let dev = MTLCreateSystemDefaultDevice()!
    let q = dev.makeCommandQueue()!
    let lt0 = now()
    let lib = try dev.makeLibrary(source: shader, options: nil)
    print(String(format: "metal runtime compile: %.1f ms", now() - lt0))
    let pd = MTLRenderPipelineDescriptor()
    pd.vertexFunction = lib.makeFunction(name: "vs")
    pd.fragmentFunction = lib.makeFunction(name: "fs")
    pd.colorAttachments[0].pixelFormat = .bgra8Unorm
    let pso = try dev.makeRenderPipelineState(descriptor: pd)
    var cacheOut: CVMetalTextureCache?
    CVMetalTextureCacheCreate(nil, nil, dev, nil, &cacheOut)
    let cache = cacheOut!
    func tex(_ pb: CVPixelBuffer, _ fmt: MTLPixelFormat, _ plane: Int) -> MTLTexture {
        var t: CVMetalTexture?
        let w = plane < 0 ? CVPixelBufferGetWidth(pb) : CVPixelBufferGetWidthOfPlane(pb, plane)
        let h = plane < 0 ? CVPixelBufferGetHeight(pb) : CVPixelBufferGetHeightOfPlane(pb, plane)
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, fmt, w, h, max(plane, 0), &t)
        return CVMetalTextureGetTexture(t!)!
    }
    let cursorTex = loadCursorTexture(dev, cursorURL)
    let dst = makeOutBuffer()
    func renderMetal(_ i: Int) {
        let c = cam(i)
        let sx = content.w / c.vw
        var u = U(
            outSize: [Float(outW), Float(outH)],
            content: [Float(content.x), Float(content.y), Float(content.w), Float(content.h)],
            radius: Float(radius), view: [Float(c.vx), Float(c.vy), Float(c.vw), Float(c.vh)],
            srcSize: [Float(srcW), Float(srcH)],
            shadowSigma: Float(0.01 * Double(outW)), shadowDy: Float(0.01 * Double(outH)), shadowAlpha: 0.45,
            c0: [0.20, 0.25, 0.55], c1: [0.55, 0.25, 0.45],
            cursorRect: [
                Float(content.x + (1000 - c.vx) * sx - 10 * sx), Float(content.y + (600 - c.vy) * sx - 10 * sx),
                Float(56 * sx), Float(80 * sx),
            ],
            cursorAlpha: 1)
        let pb = frames[i % frames.count]
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = tex(dst, .bgra8Unorm, -1)
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        let cb = q.makeCommandBuffer()!
        let enc = cb.makeRenderCommandEncoder(descriptor: rpd)!
        enc.setRenderPipelineState(pso)
        enc.setFragmentBytes(&u, length: MemoryLayout<U>.size, index: 0)
        enc.setFragmentTexture(tex(pb, .r8Unorm, 0), index: 0)
        enc.setFragmentTexture(tex(pb, .rg8Unorm, 1), index: 1)
        enc.setFragmentTexture(cursorTex, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        CVMetalTextureCacheFlush(cache, 0)
    }
    for i in 0..<20 { renderMetal(i) }
    let t0 = now()
    for i in 0..<iterations { renderMetal(i) }
    let ms = (now() - t0) / Double(iterations)
    print(String(format: "Metal      %dx%d: %.2f ms/frame (%.0f fps), serial commit and wait", outW, outH, ms, 1000 / ms))
    if args.count > 5 {
        renderMetal(30)
        let cx = CIContext()
        try cx.writePNGRepresentation(
            of: CIImage(cvPixelBuffer: dst), to: URL(filePath: args[5]), format: .BGRA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}
