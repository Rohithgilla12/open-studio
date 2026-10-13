import CoreMedia
import Darwin
import Testing
@testable import Recording
@testable import RecordingFormat

struct HostTimeTests {
    @Test func nanosecondsBecomeMicrosecondsSinceOrigin() {
        let origin = HostTime(nanoseconds: 734_918_273_645_120)
        let later = HostTime(nanoseconds: 734_918_273_645_120 + 8_215_999)
        #expect(later.mediaTime(since: origin) == MediaTime(microseconds: 8215))
        #expect(origin.mediaTime(since: origin) == .zero)
    }

    @Test func timesBeforeOriginHaveNoMediaTime() {
        let origin = HostTime(nanoseconds: 1_000_000)
        #expect(HostTime(nanoseconds: 999_999).mediaTime(since: origin) == nil)
    }

    @Test func ptsOnTheHostClockIsReadAsNanoseconds() {
        #expect(HostTime(CMTime(value: 734_918_273_645_120, timescale: 1_000_000_000)).nanoseconds == 734_918_273_645_120)
        #expect(HostTime(CMTime(value: 3, timescale: 1000)).nanoseconds == 3_000_000)
        #expect(HostTime(nanoseconds: 42).cmTime == CMTime(value: 42, timescale: 1_000_000_000))
    }

    /// `mach_absolute_time` converted through the timebase lands on `CLOCK_UPTIME_RAW`. Reading
    /// ticks as nanoseconds would be off by a factor of about 41 on Apple Silicon.
    @Test func machTicksConvertWithTimebase() {
        let before = HostTime.now()
        let ticks = HostTime(machTicks: mach_absolute_time())
        let after = HostTime.now()
        #expect(before <= ticks && ticks <= after)
    }

    @Test func durationArithmetic() {
        let origin = HostTime(nanoseconds: 5_000_000_000)
        #expect((origin + .milliseconds(1500)).duration(since: origin) == .milliseconds(1500))
        #expect(Duration.milliseconds(1500).nanoseconds == 1_500_000_000)
    }
}

struct DisplayMappingTests {
    /// A secondary 2x display placed to the left of and above the main display.
    let mapping = DisplayMapping(
        displayPointFrame: CGRect(x: -1512, y: -200, width: 1512, height: 982),
        pixelSize: CGSize(width: 3024, height: 1964))

    @Test func globalPointsMapToScreenPixelsOnSecondaryDisplay() {
        #expect(mapping.pixels(fromGlobalPoint: CGPoint(x: -1512, y: -200)) == WirePoint(x: 0, y: 0))
        #expect(mapping.pixels(fromGlobalPoint: CGPoint(x: -700, y: 233)) == WirePoint(x: 1624, y: 866))
    }

    @Test func pointsOnAnotherDisplayLandOutsideThePixelFrame() {
        let point = mapping.pixels(fromGlobalPoint: CGPoint(x: 10, y: 10))
        #expect(point.x >= 3024)
    }

    @Test func sizesScaleWithoutTranslation() {
        #expect(mapping.pixels(fromPoints: CGSize(width: 17, height: 23)) == WireSize(width: 34, height: 46))
    }
}

struct EventConversionTests {
    let conversion = EventConversion(
        origin: HostTime(nanoseconds: 1_000_000_000),
        mapping: DisplayMapping(
            displayPointFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), pixelSize: CGSize(width: 3024, height: 1964)))

    @Test func everyKindConvertsClockAndSpace() {
        let at = HostTime(nanoseconds: 1_000_000_000 + 1_203_110_500)
        let t = MediaTime(microseconds: 1_203_110)
        let location = CGPoint(x: 1105, y: 201.25)
        let position = WirePoint(x: 2210, y: 402.5)
        func convert(_ kind: CapturedInput.Kind) -> WireEvent? {
            conversion.event(CapturedInput(time: at, location: location, kind: kind))
        }
        #expect(convert(.move) == .move(t: t, position: position))
        #expect(convert(.down(.left, clickCount: 2)) == .down(t: t, button: .left, position: position, clickCount: 2))
        #expect(convert(.up(.right)) == .up(t: t, button: .right, position: position))
        #expect(convert(.scroll(dx: 0, dy: -6.5)) == .scroll(t: t, position: position, dx: 0, dy: -6.5))
        let stroke = KeyStroke(modifiers: [.command], pressedKeyCode: 1)
        #expect(convert(.key(stroke)) == .key(t: t, stroke: stroke))
    }

    @Test func eventsBeforeOriginAreDropped() {
        let early = CapturedInput(time: HostTime(nanoseconds: 999_999_999), location: .zero, kind: .move)
        #expect(conversion.event(early) == nil)
    }

    @Test func stateSnapshotIsAtTimeZero() {
        let snapshot = CapturedSnapshot(location: CGPoint(x: 756, y: 491), buttons: [.left], cursor: nil)
        let id = CursorImageID(rawValue: "9f2c4e1a7b3d5c60")!
        #expect(conversion.state(snapshot, cursor: id)
            == .state(t: .zero, position: WirePoint(x: 1512, y: 982), buttons: [.left], cursor: id))
    }
}
