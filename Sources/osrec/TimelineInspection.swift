import ArgumentParser
import Foundation
import Render
import Timeline

/// `--frames <start-ms>:<end-ms>:<step-ms>`, inclusive of the end when the step lands on it.
struct FrameGrid: ExpressibleByArgument {
    let start: OutputTime
    let end: OutputTime
    let step: OutputTime

    init?(argument: String) {
        let fields = argument.split(separator: ":", omittingEmptySubsequences: false).map { Double($0) }
        guard fields.count == 3, let start = fields[0], let end = fields[1], let step = fields[2],
            start >= 0, end >= start, step > 0
        else { return nil }
        self.start = .seconds(start / 1000)
        self.end = .seconds(end / 1000)
        self.step = .seconds(step / 1000)
    }

    var times: [OutputTime] {
        stride(from: start.microseconds, through: end.microseconds, by: Int(step.microseconds))
            .map(OutputTime.init(microseconds:))
    }
}

/// Prints what a renderer would get from the public Timeline API, for a human to check. Reads
/// `project.json` when the take has one, so the cuts and zooms are the editor's.
enum TimelineInspection {
    struct Options {
        var checkDeterminism: Bool
        var frames: FrameGrid?
        var frameRate: Int
    }

    /// Returns false when the determinism check fails.
    static func run(directory: URL, options: Options) async throws -> Bool {
        let project = try Project.open(directory)
        let source = project.source
        let zooms = project.edits.zooms
        let timeline = project.timeline

        print(String(
            format: "timeline: %.0fx%.0f px, duration %@ ms, edits %@", source.frameSize.width, source.frameSize.height,
            ms(source.duration), project.origin == .saved ? "from project.json" : "generated"))
        for warning in source.loadWarnings { print("load warning: \(warning)") }
        print("buttons: \(source.buttons.count)")
        for button in source.buttons {
            print("  \(button.edge) \(button.button) at \(ms(button.time)) ms, \(point(button.position))")
        }
        print("zoom segments: \(zooms.segments.count)")
        for (index, segment) in zooms.segments.enumerated() {
            print(String(
                format: "  %d: %@ ms to %@ ms, scale %.2f, %@", index + 1, ms(segment.range.start), ms(segment.range.end),
                segment.scale, String(describing: segment.focus)))
        }

        let cuts = project.edits.cuts.cuts
        print("cuts: \(cuts.count)")
        for cut in cuts {
            print("  \(ms(cut.range.start)) ms to \(ms(cut.range.end)) ms")
        }
        print("kept: \(timeline.map.segments.count) span(s), output duration \(ms(timeline.map.duration)) ms")
        for segment in timeline.map.segments {
            print("  recording \(ms(segment.source.start)) ms to \(ms(segment.source.end)) ms -> output \(ms(segment.outputStart)) ms")
        }

        if let frames = options.frames {
            print("frames: output t ms | camera scale, center, viewport origin+size | cursor position, opacity, pressed")
            for t in frames.times {
                let frame = timeline.frame(at: t)
                let camera = frame.camera
                let cursor = frame.cursor
                print(String(
                    format: "  %@ | %.4f %@ %@+%.1fx%.1f | %@ %.3f %@", ms(t), camera.scale, point(camera.center),
                    point(camera.viewport.origin), camera.viewport.size.width, camera.viewport.size.height,
                    point(cursor.position), cursor.opacity, cursor.isPressed ? "pressed" : "-"))
            }
        }

        guard options.checkDeterminism else { return true }
        return await checkDeterminism(timeline, frameRate: options.frameRate)
    }

    static func checkDeterminism(_ timeline: Timeline, frameRate: Int) async -> Bool {
        let rate = Int64(max(frameRate, 1))
        let duration = timeline.map.duration.microseconds
        // Integer frame times avoid accumulating a rounded 1/fps step.
        let times = (0...(duration * rate / 1_000_000)).map { OutputTime(microseconds: $0 * 1_000_000 / rate) }

        let forward = times.map { timeline.frame(at: $0).bits }
        let reverse = Array(times.reversed().map { timeline.frame(at: $0).bits }.reversed())

        var generator = SplitMix64(state: 0x6f70_656e_7374_7564)
        let order = times.indices.shuffled(using: &generator)
        var shuffled = [FrameBits?](repeating: nil, count: times.count)
        for index in order { shuffled[index] = timeline.frame(at: times[index]).bits }

        let concurrent = await withTaskGroup(of: (Int, FrameBits).self, returning: [FrameBits?].self) { group in
            for index in order {
                group.addTask { (index, timeline.frame(at: times[index]).bits) }
            }
            var out = [FrameBits?](repeating: nil, count: times.count)
            for await (index, bits) in group { out[index] = bits }
            return out
        }

        var passed = true
        for (name, frames) in [("reverse", reverse), ("shuffled", shuffled.map { $0! }), ("concurrent", concurrent.map { $0! })] {
            if let index = frames.indices.first(where: { frames[$0] != forward[$0] }) {
                print("determinism: \(name) differs from forward first at \(ms(times[index])) ms")
                passed = false
            }
        }
        let distinct = Set(forward).count
        print(String(
            format: "determinism: %d frames at %d fps, forward/reverse/shuffled/concurrent %@, %d distinct",
            times.count, rate, passed ? "bit-identical" : "DIFFER", distinct))
        return passed
    }

    static func ms(_ t: RecordingTime) -> String { String(format: "%.3f", Double(t.microseconds) / 1000) }
    static func ms(_ t: OutputTime) -> String { String(format: "%.3f", Double(t.microseconds) / 1000) }

    static func point(_ p: Point) -> String { String(format: "(%.1f, %.1f)", p.x, p.y) }
}

/// Every Double in a frame as its bit pattern, so -0 against 0 and ulp-level drift both count.
struct FrameBits: Hashable, Sendable {
    var doubles: [UInt64]
    var image: String?
    var isPressed: Bool
    var isVisible: Bool
}

extension FrameState {
    var bits: FrameBits {
        let c = camera
        let u = cursor
        let doubles = [
            c.viewport.origin.x, c.viewport.origin.y, c.viewport.size.width, c.viewport.size.height,
            c.scale, c.center.x, c.center.y, c.centerVelocity.dx, c.centerVelocity.dy, c.scaleVelocity,
            u.position.x, u.position.y, u.velocity.dx, u.velocity.dy, u.pressAmount, u.opacity,
        ]
        return FrameBits(
            doubles: doubles.map(\.bitPattern), image: u.image?.rawValue, isPressed: u.isPressed, isVisible: u.isVisible)
    }
}

/// Seeded so a failing shuffled order can be replayed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
