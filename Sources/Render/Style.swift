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
    /// Drawn only for a take with a camera.
    public var camera: CameraOverlay

    public init(background: Background, padding: Double, cornerRadius: Double, shadow: Shadow, camera: CameraOverlay = .default) {
        self.background = background
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.camera = camera
    }

    public static let `default` = Style(
        background: .gradient(.dusk), padding: 0.08, cornerRadius: 0.012, shadow: .soft)

    private enum CodingKeys: String, CodingKey {
        case background, padding, cornerRadius, shadow, camera
    }

    /// A project saved before the camera existed has no `camera` key and gets the default overlay.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            background: try c.decode(Background.self, forKey: .background),
            padding: try c.decode(Double.self, forKey: .padding),
            cornerRadius: try c.decode(Double.self, forKey: .cornerRadius),
            shadow: try c.decode(Shadow.self, forKey: .shadow),
            camera: try c.decodeIfPresent(CameraOverlay.self, forKey: .camera) ?? .default)
    }
}

/// Where and how the camera footage sits on the canvas. Lengths are fractions of the canvas's
/// shorter side, like every other style length.
public struct CameraOverlay: Sendable, Hashable {
    public enum Corner: String, Sendable, Hashable, Codable, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    public enum Shape: String, Sendable, Hashable, Codable, CaseIterable {
        /// A circle showing the centre of the camera's picture.
        case circle
        /// The whole picture at the camera's aspect, with rounded corners.
        case roundedRectangle
    }

    public var isVisible: Bool
    public var corner: Corner
    /// The overlay's height: a circle's diameter, or a rounded rectangle's height.
    public var size: Double
    /// Gap between the overlay and the two canvas edges of its corner.
    public var inset: Double
    public var shape: Shape
    /// Flipped left to right, the way people see themselves in a video call.
    public var mirrored: Bool

    public init(isVisible: Bool, corner: Corner, size: Double, inset: Double, shape: Shape, mirrored: Bool) {
        self.isVisible = isVisible
        self.corner = corner
        self.size = size
        self.inset = inset
        self.shape = shape
        self.mirrored = mirrored
    }

    public static let `default` = CameraOverlay(
        isVisible: true, corner: .bottomRight, size: 0.25, inset: 0.03, shape: .circle, mirrored: true)
    public static let sizeRange: ClosedRange<Double> = 0.1...0.5
    public static let insetRange: ClosedRange<Double> = 0...0.25
}

/// Each key defaults when missing, so a hand-edited or older file still opens.
extension CameraOverlay: Codable {
    private enum CodingKeys: String, CodingKey {
        case isVisible, corner, size, inset, shape, mirrored
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = CameraOverlay.default
        self.init(
            isVisible: try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? fallback.isVisible,
            corner: try c.decodeIfPresent(Corner.self, forKey: .corner) ?? fallback.corner,
            size: try c.decodeIfPresent(Double.self, forKey: .size) ?? fallback.size,
            inset: try c.decodeIfPresent(Double.self, forKey: .inset) ?? fallback.inset,
            shape: try c.decodeIfPresent(Shape.self, forKey: .shape) ?? fallback.shape,
            mirrored: try c.decodeIfPresent(Bool.self, forKey: .mirrored) ?? fallback.mirrored)
    }
}

public enum Background: Sendable, Hashable {
    case solid(RGBColor)
    case gradient(Gradient)
    /// An image the user picked. Copied into the take's directory on pick, so the take and its
    /// edits stay self-contained when moved. Drawn aspect-fill.
    case image(ProjectAsset)
}

/// A built-in background the inspector offers. Picking one stores its `background` value, never
/// the name, so retuning a preset later does not recolour a saved project.
public struct BackgroundPreset: Sendable, Hashable, Identifiable {
    public let name: String
    public let background: Background

    public var id: String { name }

    public init(_ name: String, _ background: Background) {
        self.name = name
        self.background = background
    }
}

extension Background {
    public static let presets: [BackgroundPreset] = [
        BackgroundPreset("Dusk", .gradient(.dusk)),
        BackgroundPreset("Mint", .gradient(.mint)),
        BackgroundPreset("Ember", .gradient(.ember)),
        BackgroundPreset("Ocean", .gradient(Gradient(
            from: RGBColor(red: 0.04, green: 0.22, blue: 0.50), to: RGBColor(red: 0.22, green: 0.70, blue: 0.85), angle: 120))),
        BackgroundPreset("Peach", .gradient(Gradient(
            from: RGBColor(red: 0.98, green: 0.72, blue: 0.55), to: RGBColor(red: 0.88, green: 0.40, blue: 0.55), angle: 45))),
        BackgroundPreset("Lavender", .gradient(Gradient(
            from: RGBColor(red: 0.50, green: 0.47, blue: 0.88), to: RGBColor(red: 0.86, green: 0.72, blue: 0.95), angle: 90))),
        BackgroundPreset("Forest", .gradient(Gradient(
            from: RGBColor(red: 0.05, green: 0.20, blue: 0.15), to: RGBColor(red: 0.32, green: 0.52, blue: 0.32), angle: 60))),
        BackgroundPreset("Dawn", .gradient(Gradient(
            from: RGBColor(red: 0.98, green: 0.84, blue: 0.62), to: RGBColor(red: 0.58, green: 0.78, blue: 0.95), angle: 90))),
        BackgroundPreset("Rose", .gradient(Gradient(
            from: RGBColor(red: 0.95, green: 0.55, blue: 0.65), to: RGBColor(red: 0.55, green: 0.22, blue: 0.52), angle: 135))),
        BackgroundPreset("Midnight", .gradient(Gradient(
            from: RGBColor(red: 0.04, green: 0.05, blue: 0.10), to: RGBColor(red: 0.20, green: 0.22, blue: 0.36), angle: 90))),
        BackgroundPreset("Graphite", .solid(RGBColor(red: 0.11, green: 0.12, blue: 0.14))),
        BackgroundPreset("Paper", .solid(RGBColor(red: 0.93, green: 0.93, blue: 0.91))),
        BackgroundPreset("Cobalt", .solid(RGBColor(red: 0.20, green: 0.45, blue: 0.85))),
        BackgroundPreset("Sand", .solid(RGBColor(red: 0.86, green: 0.80, blue: 0.70))),
        BackgroundPreset("Moss", .solid(RGBColor(red: 0.22, green: 0.33, blue: 0.25))),
    ]

    /// Why the background cannot be rendered as stored, or nil.
    var problem: String? {
        switch self {
        case .solid(let color):
            return color.problem
        case .gradient(let gradient):
            if !gradient.angle.isFinite { return "gradient angle is not finite" }
            return gradient.from.problem ?? gradient.to.problem
        case .image(let asset):
            if asset.fileName.isEmpty || asset.fileName.contains("/") { return "image name \(asset.fileName) is not a file name" }
            return nil
        }
    }
}

extension RGBColor {
    var problem: String? {
        let components = [red, green, blue]
        guard components.allSatisfy({ $0 >= 0 && $0 <= 1 }) else { return "colour \(components) is not in [0, 1]" }
        return nil
    }
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

    public init(fileName: String) { self.fileName = fileName }
}

/// `{"type": "solid", "color": {...}}`, `{"type": "gradient", "gradient": {...}}`, or
/// `{"type": "image", "fileName": "..."}`, so a hand-edited project.json reads naturally.
extension Background: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, color, gradient, fileName
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "solid": self = .solid(try c.decode(RGBColor.self, forKey: .color))
        case "gradient": self = .gradient(try c.decode(Gradient.self, forKey: .gradient))
        case "image": self = .image(ProjectAsset(fileName: try c.decode(String.self, forKey: .fileName)))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown background type \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .solid(let color):
            try c.encode("solid", forKey: .type)
            try c.encode(color, forKey: .color)
        case .gradient(let gradient):
            try c.encode("gradient", forKey: .type)
            try c.encode(gradient, forKey: .gradient)
        case .image(let asset):
            try c.encode("image", forKey: .type)
            try c.encode(asset.fileName, forKey: .fileName)
        }
    }
}
