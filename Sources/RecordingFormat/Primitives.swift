import CryptoKit
public import Foundation

/// A time on the recording's clock: integer microseconds of screen media time, where 0 is the
/// presentation time of the first complete screen frame. Encoded as a bare JSON integer.
public struct MediaTime: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let microseconds: Int64

    public init(microseconds: Int64) { self.microseconds = microseconds }

    public static let zero = MediaTime(microseconds: 0)

    public static func < (lhs: MediaTime, rhs: MediaTime) -> Bool { lhs.microseconds < rhs.microseconds }

    public init(from decoder: any Decoder) throws {
        microseconds = try decoder.singleValueContainer().decode(Int64.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(microseconds)
    }

    public var description: String { "\(microseconds)µs" }
}

/// The identity of one recording, written as `id` in the manifest.
public struct RecordingID: Sendable, Hashable, Codable {
    public let uuid: UUID

    public init(_ uuid: UUID) { self.uuid = uuid }

    public init(from decoder: any Decoder) throws {
        uuid = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuid)
    }
}

/// Content address of a cursor image: the first 16 lowercase hex digits of SHA-256 over the PNG
/// bytes followed by the hotspot. The same cursor seen twice gets the same id and the same file.
public struct CursorImageID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    /// The id becomes a file name under `cursors/`, so anything but 16 lowercase hex digits is
    /// rejected rather than allowed to name a path such as `../recording`.
    public init?(rawValue: String) {
        let hex = rawValue.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
        guard rawValue.utf8.count == 16, hex else { return nil }
        self.rawValue = rawValue
    }

    public init(png: Data, hotspot: WirePoint) {
        var hasher = SHA256()
        hasher.update(data: png)
        for coordinate in [hotspot.x, hotspot.y] {
            withUnsafeBytes(of: coordinate.bitPattern.littleEndian) { hasher.update(bufferPointer: $0) }
        }
        rawValue = hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let id = CursorImageID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "cursor image id must be 16 lowercase hex digits, got \(raw)")
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// A position in screen video pixels: origin top-left of the captured display, y down.
public struct WirePoint: Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A size in screen video pixels.
public struct WireSize: Sendable, Hashable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}
