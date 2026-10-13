/// Timeline's own geometry so the core has no CoreGraphics dependency and compiles in
/// tests on any platform. The renderer converts to CGRect at its boundary.
public struct Point: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let zero = Point(x: 0, y: 0)

    public static func + (a: Point, b: Point) -> Point { Point(x: a.x + b.x, y: a.y + b.y) }
    public static func - (a: Point, b: Point) -> Point { Point(x: a.x - b.x, y: a.y - b.y) }
    public static func * (a: Point, s: Double) -> Point { Point(x: a.x * s, y: a.y * s) }

    public func manhattanDistance(to other: Point) -> Double {
        abs(x - other.x) + abs(y - other.y)
    }
}

public struct Size: Sendable, Hashable, Codable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
    public var center: Point { Point(x: width / 2, y: height / 2) }
}

public struct Rect: Sendable, Hashable, Codable {
    public var origin: Point
    public var size: Size
    public init(origin: Point, size: Size) { self.origin = origin; self.size = size }

    public static func centered(at center: Point, size: Size) -> Rect {
        Rect(origin: Point(x: center.x - size.width / 2, y: center.y - size.height / 2), size: size)
    }

    public func union(_ p: Point) -> Rect {
        fatalError("not implemented")
    }

    /// Translates so that `self` lies inside `bounds`. Used to keep the camera on-screen.
    public func clamped(inside bounds: Rect) -> Rect {
        fatalError("not implemented")
    }
}

extension Duration {
    public var seconds: Double {
        let (s, atto) = components
        return Double(s) + Double(atto) / 1e18
    }
}
