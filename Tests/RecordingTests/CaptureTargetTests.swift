import CoreGraphics
import Foundation
import Testing
@testable import Recording

struct CaptureAreaTests {
    let retina = (points: CGSize(width: 1728, height: 1117), pixels: CGSize(width: 3456, height: 2234))

    func pixels(_ rect: CGRect) throws(RecordingError) -> CGRect {
        try CaptureArea.pixels(of: rect, displayPointSize: retina.points, pixelSize: retina.pixels)
    }

    @Test func pointsBecomeScreenPixels() throws {
        #expect(try pixels(CGRect(x: 100, y: 80, width: 1280, height: 720)) == CGRect(x: 200, y: 160, width: 2560, height: 1440))
    }

    @Test func anAreaPastTheEdgeIsClippedToTheDisplay() throws {
        #expect(try pixels(CGRect(x: 1600, y: -50, width: 400, height: 300)) == CGRect(x: 3200, y: 0, width: 256, height: 500))
    }

    @Test func fractionalPointsGrowToWholePixels() throws {
        #expect(try pixels(CGRect(x: 10.3, y: 20.6, width: 100.2, height: 50.1)) == CGRect(x: 20, y: 41, width: 201, height: 101))
    }

    @Test func aDraggedRectWithNegativeSizeIsStandardised() throws {
        #expect(try pixels(CGRect(x: 300, y: 200, width: -200, height: -100)) == CGRect(x: 200, y: 200, width: 400, height: 200))
    }

    @Test func anAreaOffTheDisplayIsRefused() {
        #expect(throws: RecordingError.areaOutsideDisplay) { try pixels(CGRect(x: 2000, y: 0, width: 300, height: 300)) }
        #expect(throws: RecordingError.areaOutsideDisplay) { try pixels(CGRect(x: 1728, y: 0, width: 300, height: 300)) }
    }

    @Test func theMinimumIsInScreenPixelsAfterClipping() throws {
        #expect(try pixels(CGRect(x: 0, y: 0, width: 32, height: 32)).size == CGSize(width: 64, height: 64))
        #expect(throws: RecordingError.areaTooSmall(width: 62, height: 400)) {
            try pixels(CGRect(x: 0, y: 0, width: 31, height: 200))
        }
        #expect(throws: RecordingError.areaTooSmall(width: 40, height: 400)) {
            try pixels(CGRect(x: 1708, y: 0, width: 300, height: 200))
        }
    }

    @Test func aOneToOneDisplayKeepsPoints() throws {
        let area = try CaptureArea.pixels(
            of: CGRect(x: 0, y: 0, width: 1920, height: 1080), displayPointSize: CGSize(width: 1920, height: 1080),
            pixelSize: CGSize(width: 1920, height: 1080))
        #expect(area == CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }
}

struct WindowListTests {
    let displays: [(id: CGDirectDisplayID, frame: CGRect)] = [
        (1, CGRect(x: 0, y: 0, width: 1728, height: 1117)),
        (2, CGRect(x: 1728, y: 0, width: 1920, height: 1080)),
    ]

    func entry(
        number: Int = 42, pid: Int32 = 500, layer: Int = 0, owner: String? = "Finder", name: String? = "Downloads",
        bounds: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600)
    ) -> [String: Any] {
        var entry: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: number),
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowBounds as String: bounds.dictionaryRepresentation,
        ]
        if let owner { entry[kCGWindowOwnerName as String] = owner }
        if let name { entry[kCGWindowName as String] = name }
        return entry
    }

    func info(_ entry: [String: Any]) -> WindowInfo? {
        CaptureSources.windowInfo(from: entry, displays: displays, ownProcess: 99)
    }

    @Test func aNormalWindowIsListedWithItsDisplay() {
        #expect(info(entry()) == WindowInfo(
            id: 42, appName: "Finder", title: "Downloads", processID: 500,
            frame: CGRect(x: 100, y: 100, width: 800, height: 600), displayID: 1))
    }

    @Test func ownWindowsAndOtherLayersAreLeftOut() {
        #expect(info(entry(pid: 99)) == nil)
        #expect(info(entry(layer: 25)) == nil)
    }

    @Test func aWithheldTitleFallsBackToTheAppName() {
        let window = info(entry(name: nil))
        #expect(window?.appName == "Finder")
        #expect(window?.title == nil)
        #expect(info(entry(name: ""))?.title == nil)
    }

    @Test func aWindowWithNoNameAtAllIsLeftOut() {
        #expect(info(entry(owner: nil, name: nil)) == nil)
        #expect(info(entry(owner: "", name: "")) == nil)
    }

    @Test func aWindowSpanningDisplaysBelongsToTheOneHoldingMostOfIt() {
        #expect(info(entry(bounds: CGRect(x: 1500, y: 0, width: 800, height: 400)))?.displayID == 2)
        #expect(info(entry(bounds: CGRect(x: 1500, y: 0, width: 400, height: 400)))?.displayID == 1)
    }

    @Test func aWindowOffEveryDisplayIsLeftOut() {
        #expect(info(entry(bounds: CGRect(x: -5000, y: 0, width: 400, height: 400))) == nil)
    }
}
