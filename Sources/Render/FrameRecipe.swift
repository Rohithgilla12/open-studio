import CoreGraphics
import CoreImage
import Foundation
import Timeline

/// Builds the Core Image recipe for one frame. The only file that knows Core Image's bottom-left
/// origin; everything it receives is in top-left canvas pixels.
enum FrameRecipe {
    static func image(
        source: CIImage, geometry: FrameGeometry, layout: CanvasLayout, assets: SceneAssets,
        camera: (image: CIImage, geometry: CameraOverlayGeometry)? = nil
    ) -> CIImage {
        let canvasHeight = layout.canvas.height
        let canvasRect = CGRect(x: 0, y: 0, width: layout.canvas.width, height: layout.canvas.height)
        let sourceHeight = Int(source.extent.height)
        let viewport = flipped(geometry.viewport, canvasHeight: sourceHeight)
        let contentRect = flipped(layout.content, canvasHeight: canvasHeight)

        // Anchored at the content rect's top edge, like the cursor placement, so the two agree to
        // the pixel and the snap's sub-pixel remainder falls at the bottom edge.
        let drawnHeight = viewport.height * geometry.scale
        var content = source.cropped(to: viewport)
            .transformed(by: CGAffineTransform(translationX: -viewport.minX, y: -viewport.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: geometry.scale, kCIInputAspectRatioKey: 1,
            ])
            .transformed(by: CGAffineTransform(translationX: contentRect.minX, y: contentRect.maxY - drawnHeight))

        if let cursor = geometry.cursor {
            let image = cursor.image.flatMap { assets.cursors[$0] } ?? assets.fallbackCursor
            let rect = flipped(cursor.rect, canvasHeight: canvasHeight)
            var drawn = image
                .transformed(by: CGAffineTransform(
                    scaleX: rect.width / image.extent.width, y: rect.height / image.extent.height))
                .transformed(by: CGAffineTransform(translationX: rect.minX - image.extent.minX, y: rect.minY - image.extent.minY))
            if cursor.opacity < 1 {
                drawn = drawn.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: cursor.opacity),
                ])
            }
            content = drawn.composited(over: content)
        }

        // The content is drawn over the backdrop before masking, so a sub-pixel gap at the snapped
        // edge shows backdrop instead of a transparent (black) seam inside the mask.
        let framed = content.composited(over: assets.backdrop)
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: assets.backdrop, kCIInputMaskImageKey: assets.contentMask,
            ])
        guard let camera else { return framed.cropped(to: canvasRect) }
        return overlay(camera.image, geometry: camera.geometry, canvasHeight: canvasHeight)
            .composited(over: framed)
            .cropped(to: canvasRect)
    }

    /// The camera picture, mirrored if asked, scaled to fill the overlay, centred, and cut to its shape.
    /// Drawn after the content mask, so it is not clipped by the screen's rounded edge.
    private static func overlay(_ camera: CIImage, geometry: CameraOverlayGeometry, canvasHeight: Int) -> CIImage {
        let rect = flipped(geometry.rect, canvasHeight: canvasHeight)
        let extent = camera.extent
        var picture = camera.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        if geometry.mirrored {
            picture = picture.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: extent.width, ty: 0))
        }
        let scaled = Size(width: extent.width * geometry.scale, height: extent.height * geometry.scale)
        let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            kCIInputExtentKey: CIVector(cgRect: rect),
            kCIInputRadiusKey: geometry.cornerRadius,
            kCIInputColorKey: CIColor.white,
        ])!.outputImage!
        return picture
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: geometry.scale, kCIInputAspectRatioKey: 1])
            .transformed(by: CGAffineTransform(translationX: rect.midX - scaled.width / 2, y: rect.midY - scaled.height / 2))
            .cropped(to: rect)
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
            ])
    }

    /// Top-left rect to Core Image's bottom-left space.
    static func flipped(_ rect: Rect, canvasHeight: Int) -> CGRect {
        CGRect(x: rect.minX, y: Double(canvasHeight) - rect.maxY, width: rect.size.width, height: rect.size.height)
    }
}

/// The cursor drawn when the recording references an image it never declared. Drawn from a path
/// written for this project, not copied from any system or third-party asset.
enum FallbackArrow {
    /// Screen pixels at a 2x display, matching the recorded arrow's declaration (hotspot 10, 10,
    /// size 56 x 80, from D3's take).
    static let hotspot = Point(x: 10, y: 10)
    static let size = Size(width: 56, height: 80)

    /// Rasterised at 10x the declared size so it stays crisp when zoomed.
    static func image() -> CIImage {
        let scale = 10.0
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CGContext is bottom-left; the outline below is in the declared top-left space.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        let outline: [CGPoint] = [
            CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 60), CGPoint(x: 22, y: 49), CGPoint(x: 31, y: 70),
            CGPoint(x: 40, y: 66), CGPoint(x: 31, y: 45), CGPoint(x: 46, y: 45),
        ]
        context.move(to: outline[0])
        for point in outline.dropFirst() { context.addLine(to: point) }
        context.closePath()
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(1.5)
        context.setLineJoin(.round)
        context.drawPath(using: .fillStroke)
        return CIImage(cgImage: context.makeImage()!)
    }
}
