import Foundation
import Testing
@testable import RecordingFormat

struct EventLogTests {
    @Test func everyEventKindRoundTrips() throws {
        #expect(Set(Fixtures.everyKind.map(\.kind)) == Set(WireEventKind.allCases))
        let data = try Fixtures.log(Fixtures.everyKind)

        let decoded = try EventLog.decode(data)

        #expect(decoded.events == Fixtures.everyKind)
        #expect(decoded.validByteCount == data.count)
        #expect(decoded.tornTailByteCount == 0)
        #expect(decoded.unknownTypeCounts.isEmpty)
    }

    @Test func linesAreFlatSortedObjects() throws {
        let line = try EventLog.encodeLine(
            .down(t: MediaTime(microseconds: 1_203_110), button: .left, position: WirePoint(x: 2210, y: 402.5), clickCount: 1))

        #expect(String(decoding: line, as: UTF8.self)
            == #"{"button":"left","clickCount":1,"t":1203110,"type":"down","x":2210,"y":402.5}"# + "\n")
    }

    @Test func decodesTheDocumentedExampleLines() throws {
        let example = """
        {"type":"cursorImage","id":"9f2c4e1a7b3d5c60","hotspotX":8,"hotspotY":6,"width":34,"height":46}
        {"t":0,"type":"state","x":1624.5,"y":866,"buttons":[],"cursor":"9f2c4e1a7b3d5c60"}
        {"t":2301005,"type":"key","modifiers":[]}
        {"t":3102236,"type":"key","modifiers":["command"],"keyCode":1}

        """

        let decoded = try EventLog.decode(Data(example.utf8))

        #expect(decoded.events == [
            .cursorImage(CursorImageDeclaration(
                id: Fixtures.arrowID, hotspot: WirePoint(x: 8, y: 6), size: WireSize(width: 34, height: 46))),
            .state(t: .zero, position: WirePoint(x: 1624.5, y: 866), buttons: [], cursor: Fixtures.arrowID),
            .key(t: MediaTime(microseconds: 2_301_005), stroke: KeyStroke(modifiers: [], pressedKeyCode: 7)),
            .key(t: MediaTime(microseconds: 3_102_236), stroke: KeyStroke(modifiers: [.command], pressedKeyCode: 1)),
        ])
    }

    @Test(arguments: [#"{"t":5009121,"type":"mo"#, #"{"t":5009121,"type":"move","x":1040.5,"y":1366}"#])
    func unterminatedFinalLineIsATornTail(tail: String) throws {
        let complete = try Fixtures.log(Fixtures.everyKind)
        let data = complete + Data(tail.utf8)

        let decoded = try EventLog.decode(data)

        #expect(decoded.events == Fixtures.everyKind)
        #expect(decoded.validByteCount == complete.count)
        #expect(decoded.tornTailByteCount == tail.utf8.count)
    }

    @Test func malformedTerminatedLineIsAnError() throws {
        let lines = try Fixtures.log([Fixtures.everyKind[1]]) + Data("{\"t\":12,\"type\":\"mo\n".utf8)
            + Fixtures.log([Fixtures.everyKind[2]])

        let error = #expect(throws: FormatError.self) { try EventLog.decode(lines) }

        guard case .eventLineInvalid(let lineNumber, _) = error else {
            Issue.record("expected eventLineInvalid, got \(String(describing: error))")
            return
        }
        #expect(lineNumber == 2)
    }

    @Test func unknownTypeIsCountedAndSkipped() throws {
        let data = try Fixtures.log([Fixtures.everyKind[2]])
            + Data(#"{"t":9000,"type":"zoomHint","scale":2}"#.utf8 + [0x0A])
            + Data(#"{"t":9500,"type":"zoomHint"}"#.utf8 + [0x0A])
            + Fixtures.log([Fixtures.everyKind[3]])

        let decoded = try EventLog.decode(data)

        #expect(decoded.events == [Fixtures.everyKind[2], Fixtures.everyKind[3]])
        #expect(decoded.unknownTypeCounts == ["zoomHint": 2])
        #expect(decoded.validByteCount == data.count)
    }

    @Test func unknownKeysAreIgnored() throws {
        let line = Data(#"{"t":8215,"type":"move","x":1626,"y":865,"pressure":0.5,"source":"tablet"}"#.utf8 + [0x0A])

        #expect(try EventLog.decode(line).events == [.move(t: MediaTime(microseconds: 8215), position: WirePoint(x: 1626, y: 865))])
    }

    @Test func plainTypingNeverStoresTheKeyCode() throws {
        let typed = KeyStroke(modifiers: [.shift], pressedKeyCode: 12)
        let line = try EventLog.encodeLine(.key(t: .zero, stroke: typed))

        #expect(typed.keyCode == nil)
        #expect(!String(decoding: line, as: UTF8.self).contains("keyCode"))
        #expect(KeyStroke(modifiers: [.control], pressedKeyCode: 12).keyCode == 12)
        #expect(KeyStroke(modifiers: [.command], pressedKeyCode: 12).keyCode == 12)
    }

    @Test func aKeyCodeWithoutAShortcutModifierIsRejected() throws {
        let line = Data(#"{"t":10,"type":"key","modifiers":["shift"],"keyCode":12}"#.utf8 + [0x0A])

        let error = #expect(throws: FormatError.self) { try EventLog.decode(line) }

        guard case .eventLineInvalid(lineNumber: 1, _) = error else {
            Issue.record("expected eventLineInvalid on line 1, got \(String(describing: error))")
            return
        }
    }

    @Test func aCursorIDThatIsNotAContentAddressIsRejected() throws {
        let line = Data(#"{"t":10,"type":"cursor","id":"../recording.js"}"#.utf8 + [0x0A])

        #expect(throws: FormatError.self) { try EventLog.decode(line) }
    }

    @Test func emptyLogHasNoEvents() throws {
        let decoded = try EventLog.decode(Data())

        #expect(decoded == DecodedEventLog(events: [], validByteCount: 0, tornTailByteCount: 0, unknownTypeCounts: [:]))
    }
}
