import Foundation
import Testing
@testable import RecordingFormat
@testable import Timeline

struct LoadSpec {
    @Test func loadsCommittedFixture() throws {
        let directory = Fixture.directory(Fixture.fiveClicks)
        let generated = try Fixture.generate()
        if ProcessInfo.processInfo.environment["OPEN_STUDIO_REGENERATE_FIXTURES"] == "1" {
            try Fixture.write(generated, to: directory)
        }
        let layout = RecordingLayout(directory: directory)
        #expect(try Data(contentsOf: layout.manifest) == generated.manifest)
        #expect(try Data(contentsOf: layout.events) == generated.events)
        for (path, bytes) in generated.cursors {
            #expect(try Data(contentsOf: directory.appending(path: path)) == bytes)
        }

        let source = try SourceRecording.load(from: directory)
        #expect(source.duration == .seconds(12))
        #expect(source.frameSize == Size(width: 1920, height: 1080))
        #expect(source.termination == .userStopped)
        #expect(source.hasMicrophone == false)
        #expect(source.microphoneMovie == nil)
        #expect(source.screenMovie == layout.screen)
        #expect(source.loadWarnings.isEmpty)
        #expect(source.pointer.count == 12 * 60 + 2 * Fixture.clickSeconds.count)
        #expect(source.pointer.isSorted { $0.time <= $1.time })
        #expect(source.buttons.map(\.edge) == Array(repeating: [.down, .up], count: 5).flatMap { $0 })
        #expect(source.buttons.map(\.time.seconds) == Fixture.clickSeconds.flatMap { [$0, $0 + 0.09] })
        #expect(source.keyDowns.map(\.seconds) == Fixture.keySeconds)
        #expect(source.cursorChanges.map(\.time.seconds) == [0, 5.9, 7.1])
        #expect(
            source.cursorChanges.map(\.image?.rawValue)
                == [Fixture.arrow.id.rawValue, Fixture.iBeam.id.rawValue, Fixture.arrow.id.rawValue])
        let iBeam = try #require(source.cursorImages[CursorImageID(rawValue: Fixture.iBeam.id.rawValue)])
        #expect(iBeam.hotspot == Point(x: 8, y: 16))
        #expect(iBeam.size == Size(width: 16, height: 32))
        #expect(iBeam.relativePath == "cursors/\(Fixture.iBeam.id.rawValue).png")
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: iBeam.relativePath).path))
    }

    @Test func rejectsUnfinalizedRecording() throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var generated = try Fixture.generate()
        generated.manifest = try Fixture.editJSON(generated.manifest) {
            $0["status"] = "recording"
            $0.removeValue(forKey: "durationMicros")
            $0.removeValue(forKey: "termination")
        }
        try Fixture.write(generated, to: directory)
        #expect(throws: SourceLoadError.needsRecovery) { try SourceRecording.load(from: directory) }

        let lock = try #require(try DirectoryLock.acquire(in: RecordingLayout(directory: directory)))
        defer { lock.release() }
        #expect(throws: SourceLoadError.stillRecording) { try SourceRecording.load(from: directory) }
    }

    @Test func microphoneMovieFollowsTheManifest() throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var generated = try Fixture.generate()
        generated.manifest = try Fixture.editJSON(generated.manifest) {
            $0["microphone"] = ["deviceName": "Fixture Mic", "sampleRate": 48000, "channelCount": 1]
        }
        try Fixture.write(generated, to: directory)
        let source = try SourceRecording.load(from: directory)
        #expect(source.hasMicrophone)
        #expect(source.microphoneMovie == RecordingLayout(directory: directory).microphone)
    }

    @Test func rejectsNewerFormatVersion() throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var generated = try Fixture.generate()
        generated.manifest = try Fixture.editJSON(generated.manifest) { $0["formatVersion"] = 2 }
        try Fixture.write(generated, to: directory)
        #expect(throws: SourceLoadError.unsupportedVersion(found: 2, supported: 1)) {
            try SourceRecording.load(from: directory)
        }
    }

    @Test func missingDirectoryIsNotARecording() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).osrec")
        #expect(throws: SourceLoadError.notARecording(missing)) { try SourceRecording.load(from: missing) }
    }

    @Test func ignoresUnknownEventTypesWithAWarning() throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var generated = try Fixture.generate()
        generated.events.append(Data(#"{"t":1000,"type":"focus","app":"Finder"}"#.utf8 + [0x0a]))
        try Fixture.write(generated, to: directory)
        let source = try SourceRecording.load(from: directory)
        #expect(source.loadWarnings == ["skipped 1 event(s) of unknown type focus"])
        #expect(source.pointer.count == 12 * 60 + 2 * Fixture.clickSeconds.count)
    }

    @Test func resortsSlightlyOutOfOrderEvents() throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var generated = try Fixture.generate()
        var lines = generated.events.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        lines.swapAt(20, 21)
        generated.events = lines.reduce(into: Data()) {
            $0.append($1)
            $0.append(0x0a)
        }
        try Fixture.write(generated, to: directory)
        let source = try SourceRecording.load(from: directory)
        #expect(source.loadWarnings == ["events were not in time order; re-sorted"])
        #expect(source.pointer.isSorted { $0.time <= $1.time })
    }

    @Test func undeclaredCursorBecomesNilWithAWarning() throws {
        let ghost = RecordingFormat.CursorImageID(rawValue: "00000000000000aa")!
        let source = try Synthetic.source(
            duration: 2, pointer: [(0, 10, 10)], cursorChanges: [(1, ghost)], declarations: [Fixture.arrow])
        #expect(source.cursorChanges == [CursorChange(time: .seconds(1), image: nil)])
        #expect(
            source.loadWarnings
                == ["cursor 00000000000000aa referenced but never declared; falls back to the default arrow"])
    }

    @Test func stateLineExpandsToPointerButtonsAndCursor() throws {
        let log = try EventLog.decode(try EventLog.encodeLine(
            .state(t: .zero, position: WirePoint(x: 5, y: 6), buttons: [.left, .other], cursor: Fixture.arrow.id)))
        var manifest = try WireManifest.decode(try Fixture.generate().manifest)
        manifest.status = .finalized(duration: MediaTime(microseconds: 1_000_000), termination: .durationReached)
        let source = try SourceRecording(RecordingMetadata(
            layout: RecordingLayout(directory: URL(fileURLWithPath: "/x.osrec")),
            manifest: manifest, events: log, recorderAlive: false))
        #expect(source.pointer == [PointerSample(time: .zero, position: Point(x: 5, y: 6))])
        #expect(source.buttons.map(\.button) == [.left, .other])
        #expect(source.buttons.allSatisfy { $0.edge == .down && $0.time == .zero })
        #expect(source.cursorChanges == [CursorChange(time: .zero, image: nil)])
        #expect(source.termination == .durationReached)
    }

    @Test func nonFiniteCoordinateIsCorrupt() throws {
        let log = DecodedEventLog(
            events: [.move(t: MediaTime(microseconds: 10), position: WirePoint(x: .infinity, y: 2))],
            validByteCount: 0, tornTailByteCount: 0, unknownTypeCounts: [:])
        let error = #expect(throws: SourceLoadError.self) {
            try SourceRecording(RecordingMetadata(
                layout: RecordingLayout(directory: URL(fileURLWithPath: "/x.osrec")),
                manifest: try WireManifest.decode(try Fixture.generate().manifest),
                events: log, recorderAlive: false))
        }
        guard case .corrupt(let detail) = try #require(error) else {
            Issue.record("expected .corrupt")
            return
        }
        #expect(detail.hasPrefix("non-finite coordinate"))
    }
}
