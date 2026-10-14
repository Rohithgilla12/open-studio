import Foundation
import Testing
@testable import Timeline

/// Decoding must go through the validating initialisers, so a hand-edited or older project file
/// cannot build a state the types promise cannot exist.
struct DecodingSpec {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()

    @Test func invertedTimeRangeFailsToDecode() {
        let json = Data(#"{"start":{"microseconds":2000000},"end":{"microseconds":1000000}}"#.utf8)
        #expect(throws: DecodingError.self) { try decoder.decode(TimeRange.self, from: json) }
    }

    @Test func emptyTimeRangeFailsToDecode() {
        let json = Data(#"{"start":{"microseconds":5},"end":{"microseconds":5}}"#.utf8)
        #expect(throws: DecodingError.self) { try decoder.decode(TimeRange.self, from: json) }
    }

    @Test func overlappingZoomTrackFailsToDecode() throws {
        let a = ZoomSegment(range: TimeRange(start: .seconds(1), end: .seconds(3))!, scale: 2, focus: .followPointer)
        let b = ZoomSegment(range: TimeRange(start: .seconds(2), end: .seconds(4))!, scale: 2, focus: .followPointer)
        let json = try encoder.encode([a, b])
        #expect(throws: ZoomTrackError.overlap(a.id, b.id)) { try decoder.decode(ZoomTrack.self, from: json) }
    }

    @Test func zoomTrackWithScaleBelowOneFailsToDecode() throws {
        let a = ZoomSegment(range: TimeRange(start: .seconds(1), end: .seconds(3))!, scale: 0.5, focus: .followPointer)
        let json = try encoder.encode([a])
        #expect(throws: ZoomTrackError.scaleBelowOne(a.id)) { try decoder.decode(ZoomTrack.self, from: json) }
    }

    @Test func zoomTrackWithDuplicateIDsFailsToDecode() throws {
        let id = UUID()
        let a = ZoomSegment(id: id, range: TimeRange(start: .seconds(1), end: .seconds(2))!, scale: 2, focus: .followPointer)
        let b = ZoomSegment(id: id, range: TimeRange(start: .seconds(3), end: .seconds(4))!, scale: 2, focus: .followPointer)
        #expect(throws: ZoomTrackError.duplicateID(id)) { try decoder.decode(ZoomTrack.self, from: try encoder.encode([a, b])) }
    }

    @Test func zoomTrackRoundTripsAsABareArray() throws {
        let track = try ZoomTrack(validating: [
            ZoomSegment(range: TimeRange(start: .seconds(5), end: .seconds(7))!, scale: 1.5, focus: .fixed(x: 0.2, y: 0.8)),
            ZoomSegment(range: TimeRange(start: .seconds(1), end: .seconds(3))!, scale: 2, focus: .followPointer),
        ])
        let json = try encoder.encode(track)
        #expect(try JSONSerialization.jsonObject(with: json) is [Any])
        #expect(try decoder.decode(ZoomTrack.self, from: json) == track)
    }

    @Test func settingsDecodeMissingKeysToDefaults() throws {
        let json = Data(#"{"camera":{"thinningDistance":25},"cursor":{}}"#.utf8)
        let settings = try decoder.decode(TimelineSettings.self, from: json)
        var expected = TimelineSettings.default
        expected.camera.thinningDistance = 25
        #expect(settings == expected)
        #expect(try decoder.decode(TimelineSettings.self, from: Data("{}".utf8)) == .default)
    }

    @Test func explicitNullKeepsAnOptionalSettingOff() throws {
        var saved = TimelineSettings.default
        saved.camera.leadIn = nil
        saved.cursor.idleHideAfter = nil
        let json = Data(#"{"camera":{"leadIn":null},"cursor":{"idleHideAfter":null}}"#.utf8)
        #expect(try decoder.decode(TimelineSettings.self, from: json) == saved)
    }

    @Test func settingsRoundTrip() throws {
        var settings = TimelineSettings.default
        settings.camera.leadIn = CameraSettings.observedLeadIn
        settings.cursor.idleHideAfter = CursorSettings.observedIdleHide
        settings.cursor.smoothing = .rapid
        settings.autoZoom.scale = 1.75
        #expect(try decoder.decode(TimelineSettings.self, from: try encoder.encode(settings)) == settings)
    }
}
