import AppKit
import CryptoKit
internal import RecordingFormat

/// How one cursor image is stored. `size` and `hotspot` are screen pixels, which is what the
/// declaration means. The PNG is rasterised denser than that, so a zoomed 4K export stays crisp.
struct CursorRaster: Equatable {
    var pixelWidth: Int
    var pixelHeight: Int
    var size: WireSize
    var hotspot: WirePoint

    /// 5× the screen pixels is the arrow's largest representation on a 2× display, and covers a
    /// 2× zoom in a 4K export from any source at least 1536 px wide.
    static let maxScreenPixelMultiple: CGFloat = 5
    /// Bounds the PNG for oversized custom cursors.
    static let maxPixelEdge: CGFloat = 1024

    /// `representationPixelWidths` are the image's reps; a width of 0 is a resolution-independent
    /// rep, which rasterises at the cap.
    init?(pointSize: CGSize, hotSpot: CGPoint, displayScale: CGFloat, representationPixelWidths: [Int]) {
        guard pointSize.width > 0, pointSize.height > 0, displayScale > 0 else { return nil }
        let cap = min(
            displayScale * Self.maxScreenPixelMultiple,
            Self.maxPixelEdge / max(pointSize.width, pointSize.height))
        let offered = representationPixelWidths.map { $0 > 0 ? CGFloat($0) / pointSize.width : cap }
        guard let largest = offered.max() else { return nil }
        let pixelsPerPoint = min(largest, cap)
        pixelWidth = max(1, Int((pointSize.width * pixelsPerPoint).rounded()))
        pixelHeight = max(1, Int((pointSize.height * pixelsPerPoint).rounded()))
        size = WireSize(width: pointSize.width * displayScale, height: pointSize.height * displayScale)
        hotspot = WirePoint(x: hotSpot.x * displayScale, y: hotSpot.y * displayScale)
    }
}

extension CursorImage {
    /// Draws into a bitmap of exactly the planned size, so the cap holds even when `NSImage` would
    /// hand back a larger rep, and the same cursor always yields the same bytes.
    static func render(_ cursor: NSCursor, displayScale: CGFloat) -> (digest: SHA256Digest, image: CursorImage)? {
        let image = cursor.image
        guard let raster = CursorRaster(
            pointSize: image.size, hotSpot: cursor.hotSpot, displayScale: displayScale,
            representationPixelWidths: image.representations.map(\.pixelsWide))
        else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        let pixelsPerPoint = CGFloat(raster.pixelWidth) / image.size.width
        let hints = [NSImageRep.HintKey.ctm: NSAffineTransform(transform: AffineTransform(scale: pixelsPerPoint))]
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: hints),
            let context = CGContext(
                data: nil, width: raster.pixelWidth, height: raster.pixelHeight, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: raster.pixelWidth, height: raster.pixelHeight))
        guard let data = context.data, let drawn = context.makeImage(),
            let png = NSBitmapImageRep(cgImage: drawn).representation(using: .png, properties: [:])
        else { return nil }
        let digest = SHA256.hash(data: UnsafeRawBufferPointer(start: data, count: context.bytesPerRow * raster.pixelHeight))
        return (digest, CursorImage(png: png, hotspot: raster.hotspot, size: raster.size))
    }
}
