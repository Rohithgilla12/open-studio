public import Foundation

/// The look of the canvas. Every length is a fraction of the output canvas width, so the same
/// `Style` gives the same picture at a 1920 px preview and a 3840 px export. Codable: Project persists it.
public struct Style: Sendable, Hashable, Codable {
    public var background: Background
    /// Inset on every side, as a fraction of canvas width.
    public var padding: Double
    public var cornerRadius: Double
    public var shadow: Shadow
    public var cursor: CursorStyle

    public static let `default` = Style(
        background: .gradient(.dusk), padding: 0.06, cornerRadius: 0.012,
        shadow: Shadow(opacity: 0.45, blur: 0.010, offsetY: 0.010), cursor: CursorStyle(sizeMultiplier: 1))

    /// Clamps to the ranges the shader is tested over (padding 0...0.25, radius 0...0.1, and so on).
    /// `RenderPlan.init` is the only consumer, so the renderer never branches on out-of-range input.
    public func validated() -> Style { fatalError("not implemented") }
}

public enum Background: Sendable, Hashable, Codable {
    case solid(RGB)
    case gradient(Gradient)
    /// Relative to the project directory. Project copies the picked file in, so it travels with the take.
    case image(relativePath: String)
}

public struct RGB: Sendable, Hashable, Codable {
    /// 0...1, in the same encoded space as the video (see "Colour" in the rationale).
    public var r: Double
    public var g: Double
    public var b: Double
}

public struct Gradient: Sendable, Hashable, Codable {
    public var from: RGB
    public var to: RGB
    /// Degrees clockwise from "top to bottom".
    public var angle: Double

    /// Generated defaults only. No third-party wallpapers.
    public static let dusk = Gradient(from: RGB(r: 0.20, g: 0.25, b: 0.55), to: RGB(r: 0.55, g: 0.25, b: 0.45), angle: 135)
    public static let mint = Gradient(from: RGB(r: 0.10, g: 0.45, b: 0.40), to: RGB(r: 0.75, g: 0.90, b: 0.70), angle: 160)
    public static let graphite = Gradient(from: RGB(r: 0.10, g: 0.11, b: 0.13), to: RGB(r: 0.28, g: 0.30, b: 0.34), angle: 180)
}

public struct Shadow: Sendable, Hashable, Codable {
    public var opacity: Double
    /// Gaussian sigma.
    public var blur: Double
    public var offsetY: Double
}

public struct CursorStyle: Sendable, Hashable, Codable {
    /// Multiplies the recorded cursor size on top of camera zoom. 1 = as recorded.
    public var sizeMultiplier: Double
}
