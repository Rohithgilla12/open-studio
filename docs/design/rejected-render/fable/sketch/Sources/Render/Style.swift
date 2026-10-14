import Foundation

/// How the canvas looks. Every length is a fraction of the output's shorter side, so a 1080p and a
/// native render of the same take are the same picture at two sizes, and the preview matches the
/// export without a second set of numbers.
public struct Style: Sendable, Hashable, Codable {
    public var background: Background = .gradient(.dusk)
    /// Space between the canvas edge and the screen content. 0 ..< 0.5.
    public var padding: Fraction = Fraction(0.06)
    public var cornerRadius: Fraction = Fraction(0.012)
    public var shadow: Shadow = Shadow()

    public init() {}
    public static let `default` = Style()
}

public enum Background: Sendable, Hashable, Codable {
    case solid(RGBA)
    case gradient(Gradient)
    /// A user-supplied image, aspect-filled. Stored as a bookmark-free absolute path; a missing file
    /// renders as `.solid(.black)` with a warning rather than failing the frame.
    case image(URL)
}

/// Generated gradients only. Nothing is shipped as an asset.
public struct Gradient: Sendable, Hashable, Codable {
    public var start: RGBA
    public var end: RGBA
    /// Degrees, 0 = left to right, 90 = bottom to top.
    public var angle: Double

    public init(start: RGBA, end: RGBA, angle: Double) {
        self.start = start
        self.end = end
        self.angle = angle
    }

    public static let dusk = Gradient(start: RGBA(0.13, 0.16, 0.32), end: RGBA(0.55, 0.22, 0.42), angle: 45)
    public static let presets: [Gradient] = [.dusk]  // TODO: four or five generated pairs
}

public struct Shadow: Sendable, Hashable, Codable {
    public var opacity: Double = 0.45
    public var blur: Fraction = Fraction(0.03)
    /// Positive moves the shadow down.
    public var offsetY: Fraction = Fraction(0.012)

    public init() {}
}

/// sRGB, unpremultiplied, 0...1. A value type so `Style` is Codable without a framework colour.
public struct RGBA: Sendable, Hashable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(_ red: Double, _ green: Double, _ blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black = RGBA(0, 0, 0)
}

/// A length relative to the output's shorter side. Clamped to 0...1 on init so a style read from
/// disk cannot push the content rect outside the canvas.
public struct Fraction: Sendable, Hashable, Codable {
    public let value: Double

    public init(_ value: Double) { self.value = min(max(value, 0), 1) }

    /// Pixels at a given output size.
    public func pixels(in output: PixelSize) -> Double { value * Double(min(output.width, output.height)) }
}
