import CoreGraphics
internal import RecordingFormat

/// Global display points (CGEvent's space, origin top-left of the main display, y down) to screen
/// video pixels of the captured display. The one coordinate conversion in the recorder.
struct DisplayMapping: Sendable, Equatable {
    /// `CGDisplayBounds` of the captured display.
    var displayPointFrame: CGRect
    var pixelSize: CGSize

    var scale: CGSize {
        CGSize(width: pixelSize.width / displayPointFrame.width, height: pixelSize.height / displayPointFrame.height)
    }

    func pixels(fromGlobalPoint point: CGPoint) -> WirePoint {
        WirePoint(
            x: (point.x - displayPointFrame.minX) * scale.width,
            y: (point.y - displayPointFrame.minY) * scale.height)
    }

    func pixels(fromPoints size: CGSize) -> WireSize {
        WireSize(width: size.width * scale.width, height: size.height * scale.height)
    }
}
