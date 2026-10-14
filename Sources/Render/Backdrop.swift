import CoreGraphics
import CoreImage
import Foundation
import Timeline

/// The time-independent picture behind the screen content: the background, later the shadow.
enum Backdrop {
    static func background(_ background: Background, canvas: PixelSize, directory: URL) throws(RenderError) -> CIImage {
        let full = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        switch background {
        case .solid(let color):
            return CIImage(color: ciColor(color)).cropped(to: full)
        case .gradient(let gradient):
            // Direction in top-left space, flipped into Core Image's bottom-left space; the line runs
            // through the canvas centre and spans the canvas's projection onto it.
            let radians = gradient.angle * .pi / 180
            let direction = CGPoint(x: cos(radians), y: -sin(radians))
            let half = (abs(full.width * direction.x) + abs(full.height * direction.y)) / 2
            let centre = CGPoint(x: full.midX, y: full.midY)
            return CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: centre.x - direction.x * half, y: centre.y - direction.y * half),
                "inputPoint1": CIVector(x: centre.x + direction.x * half, y: centre.y + direction.y * half),
                "inputColor0": ciColor(gradient.from),
                "inputColor1": ciColor(gradient.to),
            ])!.outputImage!.cropped(to: full)
        case .image(let asset):
            let url = directory.appending(path: asset.fileName, directoryHint: .notDirectory)
            guard asset.fileName.firstIndex(of: "/") == nil, let image = CIImage(contentsOf: url) else {
                throw .backgroundImageUnreadable(asset.fileName)
            }
            let k = max(full.width / image.extent.width, full.height / image.extent.height)
            let scaled = image
                .transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1])
            return scaled
                .transformed(by: CGAffineTransform(
                    translationX: (full.width - scaled.extent.width) / 2, y: (full.height - scaled.extent.height) / 2))
                .cropped(to: full)
        }
    }

    /// Renders the recipe once to 8-bit BT.709 with a deterministic ordered dither, so a gradient
    /// does not band and the compositor reads one texture per frame. The dither is a function of
    /// the pixel position only, so the same style renders the same bytes every time.
    static func dithered(_ image: CIImage, canvas: PixelSize) -> CIImage {
        let width = canvas.width, height = canvas.height
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        var floats = [Float](repeating: 0, count: width * height * 4)
        floats.withUnsafeMutableBytes { bytes in
            RenderDevice.context.render(
                image, toBitmap: bytes.baseAddress!, rowBytes: width * 16, bounds: full, format: .RGBAf,
                colorSpace: RenderDevice.outputColorSpace)
        }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        // Core Image's bitmap rows run top to bottom, so (x, y) here is a top-left position.
        for y in 0..<height {
            for x in 0..<width {
                let noise = Self.noise(x: x, y: y)
                let index = (y * width + x) * 4
                for channel in 0..<3 {
                    let value = min(max(floats[index + channel], 0), 1) * 255 + noise
                    bytes[index + channel] = UInt8(min(max(value.rounded(.down), 0), 255))
                }
            }
        }
        let data = Data(bytes)
        let cgImage = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: RenderDevice.outputColorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)!
        return CIImage(cgImage: cgImage)
    }

    /// Interleaved gradient noise in [0, 1): a hash of the position with no visible structure at
    /// one-code-value amplitude.
    static func noise(x: Int, y: Int) -> Float {
        let v = 0.06711056 * Float(x) + 0.00583715 * Float(y)
        let f = v - v.rounded(.down)
        let g = 52.9829189 * f
        return g - g.rounded(.down)
    }

    static func ciColor(_ color: RGBColor) -> CIColor {
        CIColor(red: color.red, green: color.green, blue: color.blue, colorSpace: RenderDevice.styleColorSpace)!
    }
}
