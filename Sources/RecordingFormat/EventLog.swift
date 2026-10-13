public import Foundation

/// NDJSON framing for `events.ndjson`.
///
/// A line is a record only once its terminating newline is written.
public enum EventLog {
    /// One line, terminated by a newline. Keys are sorted, so equal events give equal bytes.
    public static func encodeLine(_ event: WireEvent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(event)
        line.append(newline)
        return line
    }

    /// Bytes after the last newline are the torn tail, reported and skipped. Any terminated line
    /// that does not decode is a hard error. A line with a `type` this reader does not know is
    /// counted and skipped.
    public static func decode(_ data: Data) throws(FormatError) -> DecodedEventLog {
        let decoder = JSONDecoder()
        var events: [WireEvent] = []
        var unknownTypeCounts: [String: Int] = [:]
        var lineStart = data.startIndex
        var lineNumber = 0
        while let lineEnd = data[lineStart...].firstIndex(of: newline) {
            lineNumber += 1
            do {
                switch try decoder.decode(DecodedLine.self, from: data[lineStart..<lineEnd]) {
                case .event(let event): events.append(event)
                case .unknown(let type): unknownTypeCounts[type, default: 0] += 1
                }
            } catch {
                throw .eventLineInvalid(lineNumber: lineNumber, detail: String(describing: error))
            }
            lineStart = data.index(after: lineEnd)
        }
        let validByteCount = data.distance(from: data.startIndex, to: lineStart)
        return DecodedEventLog(
            events: events,
            validByteCount: validByteCount,
            tornTailByteCount: data.count - validByteCount,
            unknownTypeCounts: unknownTypeCounts)
    }

    private static let newline = UInt8(ascii: "\n")
}

public struct DecodedEventLog: Sendable, Equatable {
    public let events: [WireEvent]
    /// Length of the newline-terminated prefix.
    public let validByteCount: Int
    /// Bytes after the last newline, from a line the recorder was writing when it died.
    public let tornTailByteCount: Int
    /// Lines whose `type` this reader does not know, counted by type.
    public let unknownTypeCounts: [String: Int]
}

private enum DecodedLine: Decodable {
    case event(WireEvent)
    case unknown(type: String)

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: WireEventKey.self)
        let type = try container.decode(String.self, forKey: .type)
        guard let kind = WireEventKind(rawValue: type) else {
            self = .unknown(type: type)
            return
        }
        self = .event(try WireEvent(kind: kind, container: container))
    }
}
