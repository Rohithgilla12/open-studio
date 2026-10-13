import Foundation
import Testing
@testable import RecordingFormat
@testable import Timeline

/// A 30-minute recording with 120 Hz pointer samples, a click every 7 s (so windows do not all merge),
/// and a typing burst every minute, built straight from wire events so JSON never enters the timed
/// regions.
enum LongRecording {
    static let duration = 30 * 60.0
    static let sampleRate = 120.0

    static func source() throws -> SourceRecording {
        var generator = SeededGenerator(state: 0x3001)
        var events: [WireEvent] = []
        events.reserveCapacity(Int(duration * sampleRate) + 2000)
        var x = 960.0
        var y = 540.0
        var vx = 0.0
        var vy = 0.0
        let count = Int(duration * sampleRate)
        for index in 0..<count {
            let t = MediaTime(microseconds: Int64(Double(index) / sampleRate * 1_000_000))
            // A pointer that drifts, with pauses every few seconds so thinning and grouping both get work.
            let paused = (index / 600) % 3 == 2
            if !paused {
                vx += Double.random(in: -300...300, using: &generator)
                vy += Double.random(in: -200...200, using: &generator)
                vx *= 0.98
                vy *= 0.98
                x = min(max(x + vx / sampleRate, 0), 1919)
                y = min(max(y + vy / sampleRate, 0), 1079)
            }
            events.append(.move(t: t, position: WirePoint(x: x.rounded(), y: y.rounded())))
            if index % 840 == 0 {
                events.append(.down(t: t, button: .left, position: WirePoint(x: x, y: y), clickCount: 1))
                events.append(.up(t: MediaTime(microseconds: t.microseconds + 70_000), button: .left, position: WirePoint(x: x, y: y)))
            }
            if index % 7200 == 3000 {
                for key in 0..<8 {
                    let at = MediaTime(microseconds: t.microseconds + Int64(key) * 150_000)
                    events.append(.key(t: at, stroke: KeyStroke(modifiers: [], pressedKeyCode: 0)))
                }
            }
        }
        let manifest = try WireManifest.decode(try Fixture.generate().manifest)
        let finalized = WireManifest(
            id: manifest.id, createdAt: manifest.createdAt, recorder: manifest.recorder, clock: manifest.clock,
            display: manifest.display, screen: manifest.screen, microphone: nil,
            status: .finalized(duration: MediaTime(microseconds: Int64(duration * 1_000_000)), termination: .userStopped))
        let log = DecodedEventLog(events: events, validByteCount: 0, tornTailByteCount: 0, unknownTypeCounts: [:])
        return try SourceRecording(RecordingMetadata(
            layout: RecordingLayout(directory: URL(fileURLWithPath: "/long.osrec")), manifest: finalized, events: log,
            recorderAlive: false))
    }
}

struct PerformanceSpec {
    @Test func thirtyMinuteRecordingBuildsFastAndQueriesInMicroseconds() throws {
        let clock = ContinuousClock()
        let source = try LongRecording.source()
        #expect(source.pointer.count == 216_000 + 2 * 258)

        let buildStart = clock.now
        let zooms = AutoZoom.track(for: source)
        let timeline = Timeline(source: source, zooms: zooms)
        let build = clock.now - buildStart

        var generator = SeededGenerator(state: 0x5EED)
        let queries = (0..<1000).map { _ in RecordingTime.seconds(Double.random(in: 0...LongRecording.duration, using: &generator)) }
        var checksum = 0.0
        for t in queries.prefix(100) { checksum += timeline.frame(at: t).camera.center.x }
        let queryStart = clock.now
        for t in queries { checksum += timeline.frame(at: t).cursor.position.x }
        let query = clock.now - queryStart
        #expect(checksum.isFinite)

        let knots = timeline.knotCounts
        let knotBytes = knots.cameraScale * MemoryLayout<SpringTrack<Double>.Knot>.stride
            + (knots.cameraCenter + knots.cursorPosition) * MemoryLayout<SpringTrack<Vector2>.Knot>.stride
        let averageMicros = Double(query.components.attoseconds) / 1e12 / Double(queries.count)
            + Double(query.components.seconds) * 1e6 / Double(queries.count)
        let buildMillis = Double(build.components.seconds) * 1e3 + Double(build.components.attoseconds) / 1e15
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        print("""
            perf(\(configuration)): zooms=\(zooms.segments.count) build=\(String(format: "%.1f", buildMillis)) ms \
            knots scale=\(knots.cameraScale) center=\(knots.cameraCenter) cursor=\(knots.cursorPosition) \
            (~\(knotBytes / 1024) KiB) query avg=\(String(format: "%.2f", averageMicros)) µs over \(queries.count)
            """)

        #expect(buildMillis < 5000, "build took \(buildMillis) ms")
        #expect(knots.cursorPosition < source.pointer.count, "thinning dropped some samples")
        #if !DEBUG
        #expect(averageMicros < 50, "average query \(averageMicros) µs")
        #expect(buildMillis < 1000, "build took \(buildMillis) ms")
        #endif
    }
}
