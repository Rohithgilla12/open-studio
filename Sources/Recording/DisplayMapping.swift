import CoreGraphics
internal import RecordingFormat

struct DisplayMapping: Sendable, Equatable {
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
