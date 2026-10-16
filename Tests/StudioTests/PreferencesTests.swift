import CoreGraphics
import Foundation
import Recording
@testable import Studio
import Testing

struct ScratchDefaults {
    let name = "StudioTests-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: name)! }
    func remove() { UserDefaults.standard.removePersistentDomain(forName: name) }
}

struct PreferencesSpec {
    @Test func emptyDefaultsRecordTheEntireScreenWithNoAreas() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let loaded = RecordingPreferences.load(from: scratch.defaults)
        #expect(loaded.captureKind == .screen)
        #expect(loaded.areas.isEmpty)
    }

    @Test(arguments: CaptureKind.allCases)
    func targetKindAndAreasPerDisplaySurviveARoundTrip(kind: CaptureKind) {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let saved = RecordingPreferences(
            display: .id(7), microphone: .systemDefault, captureKind: kind,
            areas: [7: CGRect(x: 100, y: 80, width: 1280, height: 720), 9: CGRect(x: 0.5, y: 0, width: 64.25, height: 32)])
        saved.save(to: scratch.defaults)
        #expect(RecordingPreferences.load(from: scratch.defaults) == saved)
    }

    @Test func theMainDisplayIsKeyedByItsDisplayID() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let area = CGRect(x: 10, y: 20, width: 300, height: 200)
        var preferences = RecordingPreferences(display: .main, microphone: .none)
        preferences.setArea(area, on: .main)
        #expect(preferences.areas == [CGMainDisplayID(): area])
        #expect(preferences.area(on: .id(CGMainDisplayID())) == area)

        preferences.save(to: scratch.defaults)
        let loaded = RecordingPreferences.load(from: scratch.defaults)
        #expect(loaded.area(on: .main) == area)
        #expect(loaded.area(on: .id(CGMainDisplayID() &+ 1)) == nil)
    }

    @Test func storedAreasThatAreNotAPositiveRectangleAreDropped() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        scratch.defaults.set(
            ["7": [1, 2, 0, 4], "not-a-display": [1, 2, 3, 4], "8": [1, 2, 3], "9": [1, 2, 3, 4]], forKey: "recording.areas")
        #expect(RecordingPreferences.load(from: scratch.defaults).areas == [9: CGRect(x: 1, y: 2, width: 3, height: 4)])
    }
}
