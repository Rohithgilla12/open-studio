import AppKit
import Testing
@testable import Recording
@testable import RecordingFormat

struct CursorRasterTests {
    private let arrowReps = [28, 56, 140, 280]

    @Test func arrowOnARetinaDisplayStoresItsLargestRepUnderTheScreenPixelDeclaration() throws {
        let raster = try #require(CursorRaster(
            pointSize: CGSize(width: 28, height: 40), hotSpot: CGPoint(x: 5, y: 5), displayScale: 2,
            representationPixelWidths: arrowReps))
        #expect(raster.pixelWidth == 280 && raster.pixelHeight == 400)
        #expect(raster.size == WireSize(width: 56, height: 80))
        #expect(raster.hotspot == WirePoint(x: 10, y: 10))
    }

    @Test func arrowOnANonRetinaDisplayIsCappedAtFiveTimesItsScreenPixels() throws {
        let raster = try #require(CursorRaster(
            pointSize: CGSize(width: 28, height: 40), hotSpot: CGPoint(x: 5, y: 5), displayScale: 1,
            representationPixelWidths: arrowReps))
        #expect(raster.pixelWidth == 140 && raster.pixelHeight == 200)
        #expect(raster.size == WireSize(width: 28, height: 40))
        #expect(raster.hotspot == WirePoint(x: 5, y: 5))
    }

    @Test func anAbsurdRepIsCappedAtFiveTimesTheScreenPixels() throws {
        let raster = try #require(CursorRaster(
            pointSize: CGSize(width: 32, height: 32), hotSpot: .zero, displayScale: 2,
            representationPixelWidths: [32, 64, 4096]))
        #expect(raster.pixelWidth == 320)
        #expect(raster.pixelHeight == 320)
    }

    @Test func anOversizedCursorIsCappedAtTheMaximumPixelEdge() throws {
        let raster = try #require(CursorRaster(
            pointSize: CGSize(width: 128, height: 256), hotSpot: .zero, displayScale: 2,
            representationPixelWidths: [128, 256, 1280]))
        #expect(raster.pixelWidth == 512)
        #expect(raster.pixelHeight == 1024)
        #expect(raster.size == WireSize(width: 256, height: 512))
    }

    @Test func aResolutionIndependentRepRasterisesAtTheCap() throws {
        let raster = try #require(CursorRaster(
            pointSize: CGSize(width: 24, height: 24), hotSpot: .zero, displayScale: 2, representationPixelWidths: [0]))
        #expect(raster.pixelWidth == 240)
    }

    @Test func aLowResolutionCursorKeepsItsPixelsButDeclaresScreenPixels() throws {
        let raster = try #require(CursorRaster(
            pointSize: CGSize(width: 16, height: 16), hotSpot: CGPoint(x: 3, y: 4), displayScale: 2,
            representationPixelWidths: [16]))
        #expect(raster.pixelWidth == 16 && raster.pixelHeight == 16)
        #expect(raster.size == WireSize(width: 32, height: 32))
        #expect(raster.hotspot == WirePoint(x: 6, y: 8))
    }

    @Test func anEmptyImageHasNoRaster() {
        #expect(CursorRaster(pointSize: .zero, hotSpot: .zero, displayScale: 2, representationPixelWidths: [56]) == nil)
        #expect(CursorRaster(
            pointSize: CGSize(width: 28, height: 40), hotSpot: .zero, displayScale: 2, representationPixelWidths: []) == nil)
    }

    @Test func renderingStoresTheLargestRepAndIsStableAcrossCalls() throws {
        let cursor = NSCursor(image: Self.image(points: 32, reps: [32, 64, 320]), hotSpot: NSPoint(x: 4, y: 6))
        let first = try #require(CursorImage.render(cursor, displayScale: 2))
        let second = try #require(CursorImage.render(cursor, displayScale: 2))
        let png = try #require(NSBitmapImageRep(data: first.image.png))
        #expect(png.pixelsWide == 320)
        #expect(png.pixelsHigh == 320)
        #expect(first.image.size == WireSize(width: 64, height: 64))
        #expect(first.image.hotspot == WirePoint(x: 8, y: 12))
        #expect(first.digest == second.digest)
        #expect(first.image == second.image)
    }

    @Test func renderingHonoursTheCapWhenTheImageOffersMore() throws {
        let cursor = NSCursor(image: Self.image(points: 32, reps: [64, 640]), hotSpot: .zero)
        let rendered = try #require(CursorImage.render(cursor, displayScale: 2))
        let png = try #require(NSBitmapImageRep(data: rendered.image.png))
        #expect(png.pixelsWide == 320)
        #expect(rendered.image.size == WireSize(width: 64, height: 64))
    }

    private static func image(points: CGFloat, reps: [Int]) -> NSImage {
        let image = NSImage(size: NSSize(width: points, height: points))
        for pixels in reps {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: pixels, height: pixels)).fill()
            NSGraphicsContext.restoreGraphicsState()
            rep.size = NSSize(width: points, height: points)
            image.addRepresentation(rep)
        }
        return image
    }
}
