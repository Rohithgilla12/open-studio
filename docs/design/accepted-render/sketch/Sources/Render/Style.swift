import Foundation

/// How the canvas around the screen looks. Part of a project's edits, persisted in project.json.
///
/// Every length is a fraction of the canvas's shorter side, never pixels. So a 1080p export, a
/// native export, and the preview at any size are the same picture at different resolutions, and
/// changing the output preset never changes the look.
public struct Style: Sendable, Hashable, Codable {
    public var background: Background
    /// Gap between the canvas edge and the screen content. 0 disables the frame entirely.
    public var padding: Double
    /// Corner radius of the screen content.
    public var cornerRadius: Double
    public var shadow: Shadow

    public init(background: Background, padding: Double, cornerRadius: Double, shadow: Shadow) {
        self.background = background
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
    }

    public static let `default` = Style(
        background: .gradient(.dusk), padding: 0.08, cornerRadius: 0.012, shadow: .soft)
}

public enum Background: Sendable, Hashable, Codable {
    case solid(RGBColor)
    case gradient(Gradient)
    /// An image the user picked. Copied into the take's directory on pick, so the take and its
    /// edits stay self-contained when moved. Drawn aspect-fill.
    case image(ProjectAsset)
}

/// sRGB components, 0...1. The renderer converts into its working space; nothing else interprets
/// these numbers.
public struct RGBColor: Sendable, Hashable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// A linear gradient across the canvas. Generated, never a bundled bitmap, so nothing ships that
/// could resemble another product's wallpapers.
public struct Gradient: Sendable, Hashable, Codable {
    public var from: RGBColor
    public var to: RGBColor
    /// Degrees, 0 = left to right, 90 = top to bottom.
    public var angle: Double

    public init(from: RGBColor, to: RGBColor, angle: Double) {
        self.from = from
        self.to = to
        self.angle = angle
    }

    public static let dusk = Gradient(
        from: RGBColor(red: 0.12, green: 0.20, blue: 0.45), to: RGBColor(red: 0.55, green: 0.25, blue: 0.55), angle: 35)
    public static let mint = Gradient(
        from: RGBColor(red: 0.10, green: 0.45, blue: 0.40), to: RGBColor(red: 0.70, green: 0.90, blue: 0.70), angle: 120)
    public static let ember = Gradient(
        from: RGBColor(red: 0.55, green: 0.12, blue: 0.10), to: RGBColor(red: 0.95, green: 0.60, blue: 0.25), angle: 60)
    /// The presets the style inspector offers.
    public static let presets: [Gradient] = [.dusk, .mint, .ember]
}

public struct Shadow: Sendable, Hashable, Codable {
    /// 0 disables the shadow.
    public var opacity: Double
    /// Gaussian sigma, as a fraction of the canvas's shorter side.
    public var blur: Double
    /// Downward offset, same unit.
    public var offsetY: Double

    public init(opacity: Double, blur: Double, offsetY: Double) {
        self.opacity = opacity
        self.blur = blur
        self.offsetY = offsetY
    }

    public static let soft = Shadow(opacity: 0.45, blur: 0.02, offsetY: 0.012)
    public static let none = Shadow(opacity: 0, blur: 0, offsetY: 0)
}

/// A file inside the take directory that the project owns, such as a background image. Stored
/// as a name, never a path, so it cannot point outside the take.
public struct ProjectAsset: Sendable, Hashable, Codable {
    public let fileName: String
}
