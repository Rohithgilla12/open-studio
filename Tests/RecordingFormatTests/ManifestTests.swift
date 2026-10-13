import Foundation
import Synchronization
import Testing
@testable import RecordingFormat

struct ManifestTests {
    static let statuses: [ManifestStatus] = [
        .recording,
        .finalized(duration: MediaTime(microseconds: 5_016_667), termination: .userStopped),
        .finalized(duration: MediaTime(microseconds: 5_016_667), termination: .durationReached),
        .finalized(duration: MediaTime(microseconds: 2_000_000), termination: .streamFailed(message: "display unplugged")),
        .finalized(duration: MediaTime(microseconds: 3_000_000), termination: .recovered(message: "truncated 61 bytes")),
        .finalized(duration: MediaTime(microseconds: 3_000_000), termination: .recovered(message: nil)),
    ]

    @Test(arguments: statuses)
    func roundTrips(status: ManifestStatus) throws {
        let manifest = Fixtures.manifest(
            status: status,
            warnings: [
                .microphoneLost(at: MediaTime(microseconds: 1_500_000), message: "device removed"),
                .inputTapReenabled(at: MediaTime(microseconds: 2_250_000)),
            ])

        #expect(try WireManifest.decode(manifest.encoded()) == manifest)
    }

    @Test(arguments: [1_791_000_000.4119999, 1_791_000_000.123456, 1_791_000_000.9996])
    func createdAtRoundTripsAtMillisecondPrecision(seconds: Double) throws {
        let base = Fixtures.manifest()
        let manifest = WireManifest(
            id: base.id, createdAt: Date(timeIntervalSince1970: seconds), recorder: base.recorder, clock: base.clock,
            display: base.display, screen: base.screen, microphone: base.microphone)

        #expect(try WireManifest.decode(manifest.encoded()) == manifest)
        #expect(abs(manifest.createdAt.timeIntervalSince1970 - seconds) <= 0.0005)
    }

    @Test func roundTripsWithoutMicrophone() throws {
        var manifest = Fixtures.manifest()
        manifest.microphone = nil

        let json = try JSONSerialization.jsonObject(with: manifest.encoded()) as! [String: Any]

        #expect(json["microphone"] == nil)
        #expect(try WireManifest.decode(manifest.encoded()) == manifest)
    }

    @Test func decodesTheDocumentedExample() throws {
        let example = """
        {
          "clock" : { "origin" : "first-screen-frame", "originHostTimeNanos" : 734918273645120, "unit" : "microseconds" },
          "createdAt" : "2026-10-13T06:22:33.412Z",
          "display" : { "displayID" : 1, "name" : "Built-in Retina Display", "pointFrame" : [0, 0, 1512, 982], "refreshRate" : 120 },
          "format" : "open-studio.recording",
          "formatVersion" : 1,
          "id" : "8E0C2B9A-6F1D-4C55-9C3E-2D7A9B4F1E10",
          "microphone" : { "channelCount" : 1, "deviceName" : "MacBook Pro Microphone", "sampleRate" : 48000 },
          "recorder" : { "name" : "osrec", "osVersion" : "27.0", "version" : "0.1.0" },
          "screen" : { "codec" : "hevc", "maxFrameRate" : 60, "pixelHeight" : 1964, "pixelWidth" : 3024 },
          "status" : "recording",
          "warnings" : [ ]
        }
        """

        #expect(try WireManifest.decode(Data(example.utf8)) == Fixtures.manifest())
    }

    @Test func recordingStatusCarriesNoDurationOrTermination() throws {
        let json = try JSONSerialization.jsonObject(with: Fixtures.manifest().encoded()) as! [String: Any]

        #expect(json["status"] as? String == "recording")
        #expect(json["durationMicros"] == nil)
        #expect(json["termination"] == nil)
        #expect(json["format"] as? String == "open-studio.recording")
        #expect(json["formatVersion"] as? Int == 1)
        #expect(json["createdAt"] as? String == "2026-10-13T06:22:33.412Z")
        let clock = json["clock"] as? [String: Any]
        #expect(clock?["unit"] as? String == "microseconds")
        #expect(clock?["origin"] as? String == "first-screen-frame")
    }

    @Test func finalizedStatusCarriesDurationAndTermination() throws {
        let manifest = Fixtures.manifest(
            status: .finalized(duration: MediaTime(microseconds: 3_000_000), termination: .recovered(message: "lost 61 bytes")))

        let json = try JSONSerialization.jsonObject(with: manifest.encoded()) as! [String: Any]

        #expect(json["status"] as? String == "finalized")
        #expect(json["durationMicros"] as? Int == 3_000_000)
        #expect(json["termination"] as? [String: String] == ["reason": "recovered", "message": "lost 61 bytes"])
    }

    @Test func finalizedWithoutTerminationIsUnreadable() throws {
        let broken = try Fixtures.editJSON(Fixtures.manifest().encoded()) {
            $0["status"] = "finalized"
            $0["durationMicros"] = 1000
        }

        let error = #expect(throws: FormatError.self) { try WireManifest.decode(broken) }

        guard case .manifestUnreadable = error else {
            Issue.record("expected manifestUnreadable, got \(String(describing: error))")
            return
        }
    }

    @Test func newerVersionIsRejectedBeforeItsShapeIsRead() throws {
        let newer = try JSONSerialization.data(withJSONObject: [
            "format": "open-studio.recording", "formatVersion": 2, "timeline": ["clock": "nanoseconds"],
        ])

        #expect(throws: FormatError.unsupportedVersion(found: 2, supported: 1)) { try WireManifest.decode(newer) }
    }

    @Test func otherFormatIsRejected() throws {
        let other = try Fixtures.editJSON(Fixtures.manifest().encoded()) { $0["format"] = "screen-studio.project" }

        #expect(throws: FormatError.wrongFormat(found: "screen-studio.project")) { try WireManifest.decode(other) }
    }

    @Test func aDifferentClockIsRejected() throws {
        let other = try Fixtures.editJSON(Fixtures.manifest().encoded()) {
            $0["clock"] = ["unit": "milliseconds", "origin": "first-screen-frame", "originHostTimeNanos": 1]
        }

        #expect(throws: FormatError.self) { try WireManifest.decode(other) }
    }

    @Test func unknownKeysAndWarningKindsAreIgnored() throws {
        let manifest = Fixtures.manifest(warnings: [.inputTapReenabled(at: MediaTime(microseconds: 40))])
        let extended = try Fixtures.editJSON(manifest.encoded()) {
            $0["editorHint"] = ["lastOpened": "2026-10-14"]
            $0["warnings"] = [
                ["kind": "inputTapReenabled", "at": 40],
                ["kind": "thermalThrottled", "at": 90, "level": "serious"],
            ]
        }

        #expect(try WireManifest.decode(extended) == manifest)
    }

    @Test func writeReplacesTheManifestAndLeavesNoTemporaryFile() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let layout = RecordingLayout(directory: directory)
        let finalized = Fixtures.manifest(
            status: .finalized(duration: MediaTime(microseconds: 5_016_667), termination: .durationReached))

        try Fixtures.manifest().write(to: layout)
        try finalized.write(to: layout)

        #expect(try WireManifest.decode(Data(contentsOf: layout.manifest)) == finalized)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["recording.json"])
    }

    /// A reader polling while the writer flips between two manifests of different sizes must only
    /// ever see one of them whole. A truncate-then-write would expose an empty or partial file.
    @Test func concurrentReaderSeesOldOrNewManifestNeverAMix() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let layout = RecordingLayout(directory: directory)
        let small = Fixtures.manifest()
        let large = Fixtures.manifest(
            status: .finalized(duration: MediaTime(microseconds: 9_000_000), termination: .userStopped),
            warnings: (0..<200).map { .microphoneLost(at: MediaTime(microseconds: Int64($0)), message: "dropout \($0)") })
        try small.write(to: layout)

        let writing = Atomic(true)
        let observations = Mutex<(small: Int, large: Int, other: [String])>((0, 0, []))
        DispatchQueue.concurrentPerform(iterations: 2) { worker in
            if worker == 0 {
                for i in 0..<400 { try! (i.isMultiple(of: 2) ? large : small).write(to: layout) }
                writing.store(false, ordering: .releasing)
                return
            }
            while writing.load(ordering: .acquiring) {
                let seen = Result { try WireManifest.decode(Data(contentsOf: layout.manifest)) }
                observations.withLock {
                    switch seen {
                    case .success(small): $0.small += 1
                    case .success(large): $0.large += 1
                    case .success(let other): $0.other.append("unexpected manifest \(other.status)")
                    case .failure(let error): $0.other.append(String(describing: error))
                    }
                }
            }
        }

        let seen = observations.withLock { $0 }
        #expect(seen.other == [])
        #expect(seen.small > 0)
        #expect(seen.large > 0)
    }
}
