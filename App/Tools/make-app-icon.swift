import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let output = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "OpenStudio/Assets.xcassets/AppIcon.appiconset", directoryHint: .isDirectory)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func draw(in context: CGContext, size: CGFloat) {
    context.scaleBy(x: size / 1024, y: size / 1024)
    let canvas: CGFloat = 1024
    let gridTileSize: CGFloat = 824
    let gridCornerRadius: CGFloat = 185
    let inset = (canvas - gridTileSize) / 2
    let tile = CGRect(x: inset, y: inset, width: gridTileSize, height: gridTileSize)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: gridCornerRadius, cornerHeight: gridCornerRadius, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
    context.addPath(tilePath)
    context.setFillColor(color(0.2, 0.2, 0.3))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0.36, 0.25, 0.85), color(0.93, 0.42, 0.55)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(
        gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    context.restoreGState()

    let screen = CGRect(x: 230, y: 300, width: 564, height: 400)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0, 0, 0, 0.3))
    context.addPath(CGPath(roundedRect: screen, cornerWidth: 36, cornerHeight: 36, transform: nil))
    context.setFillColor(color(0.98, 0.98, 1))
    context.fillPath()
    context.restoreGState()

    let zoom = CGRect(x: 470, y: 420, width: 250, height: 200)
    context.addPath(CGPath(roundedRect: zoom, cornerWidth: 22, cornerHeight: 22, transform: nil))
    context.setStrokeColor(color(0.36, 0.25, 0.85))
    context.setLineWidth(18)
    context.strokePath()

    context.setFillColor(color(0.95, 0.27, 0.3))
    context.fillEllipse(in: CGRect(x: 290, y: 360, width: 110, height: 110))
}

func writePNG(pixels: Int, to url: URL) {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(in: context, size: CGFloat(pixels))
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination), "could not write \(url.path)")
}

var images: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        writePNG(pixels: points * scale, to: output.appending(path: name))
        images.append("""
                { "filename" : "\(name)", "idiom" : "mac", "scale" : "\(scale)x", "size" : "\(points)x\(points)" }
            """)
    }
}
let contents = """
    {
      "images" : [
    \(images.joined(separator: ",\n"))
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }

    """
try contents.write(to: output.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
