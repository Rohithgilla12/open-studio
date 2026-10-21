import Foundation
import Testing
@testable import Timeline

/// Every Double in a frame as its bit pattern, so -0 vs 0 and ulp-level drift both count as a
/// difference. `==` on Double would hide them.
struct FrameBits: Hashable {
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
        return FrameBits(doubles: doubles.map(\.bitPattern), image: u.image?.rawValue, isPressed: u.isPressed, isVisible: u.isVisible)
    }
}

struct DeterminismSpec {
    @Test func frameIgnoresQueryOrderAndThread() async throws {
        var settings = TimelineSettings()
        settings.camera.leadIn = CameraSettings.observedLeadIn
        settings.cursor.idleHideAfter = CursorSettings.observedIdleHide
        let timeline = try Fixture.timeline(settings: settings)
        let times = stride(from: 0, through: timeline.map.duration.microseconds, by: 1_000_000 / 240)
            .map(OutputTime.init(microseconds:))

        let forward = times.map { timeline.frame(at: $0).bits }
        let reverse = times.reversed().map { timeline.frame(at: $0).bits }.reversed()
        #expect(Array(reverse) == forward)

        var generator = SeededGenerator(state: 42)
        let order = times.indices.shuffled(using: &generator)
        var shuffled = [FrameBits?](repeating: nil, count: times.count)
        for index in order { shuffled[index] = timeline.frame(at: times[index]).bits }
        #expect(shuffled.map { $0! } == forward)

        let concurrent = await withTaskGroup(of: (Int, FrameBits).self, returning: [FrameBits?].self) { group in
            for index in order {
                group.addTask { (index, timeline.frame(at: times[index]).bits) }
            }
            var out = [FrameBits?](repeating: nil, count: times.count)
            for await (index, bits) in group { out[index] = bits }
            return out
        }
        #expect(concurrent.map { $0! } == forward)

        #expect(Set(forward).count > times.count / 2, "the frames actually vary over the recording")
    }

    @Test func rebuildingFromTheSameInputsGivesTheSameFrames() throws {
        let a = try Fixture.timeline()
        let b = try Fixture.timeline()
        for t in stride(from: 0.0, through: 12, by: 0.37) {
            #expect(a.frame(at: .seconds(t)).bits == b.frame(at: .seconds(t)).bits)
        }
    }
}
