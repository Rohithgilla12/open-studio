import AVFoundation
import Foundation
import Testing
@testable import Render
import Timeline

struct CameraOverlayGeometrySpec {
    let canvas = PixelSize(width: 1920, height: 1080)
    let camera = Size(width: 640, height: 360)

    @Test func theDefaultIsACircleInTheBottomRightCorner() {
        let geometry = CameraOverlayGeometry(overlay: .default, canvas: canvas, camera: camera)
        #expect(geometry.rect == Rect(origin: Point(x: 1618, y: 778), size: Size(width: 270, height: 270)))
        #expect(geometry.cornerRadius == 135)
        #expect(geometry.scale == 0.75, "fills the height; the sides of a wide picture are cut")
        #expect(geometry.mirrored)
    }

    @Test(arguments: [
        (CameraOverlay.Corner.topLeft, Point(x: 32, y: 32)),
        (.topRight, Point(x: 1618, y: 32)),
        (.bottomLeft, Point(x: 32, y: 778)),
        (.bottomRight, Point(x: 1618, y: 778)),
    ])
    func eachCornerIsInsetFromItsTwoEdges(corner: CameraOverlay.Corner, origin: Point) {
        var overlay = CameraOverlay.default
        overlay.corner = corner
        #expect(CameraOverlayGeometry(overlay: overlay, canvas: canvas, camera: camera).rect.origin == origin)
    }

    @Test func aRoundedRectangleShowsTheWholePictureAtItsAspect() {
        var overlay = CameraOverlay.default
        overlay.shape = .roundedRectangle
        let geometry = CameraOverlayGeometry(overlay: overlay, canvas: canvas, camera: camera)
        #expect(geometry.rect == Rect(origin: Point(x: 1408, y: 778), size: Size(width: 480, height: 270)))
        #expect(geometry.scale == 0.75)
        #expect(abs(geometry.cornerRadius - 32.4) < 1e-9)
    }

    @Test func lengthsFollowTheCanvasShorterSide() {
        let small = CameraOverlayGeometry(overlay: .default, canvas: PixelSize(width: 960, height: 540), camera: camera)
        #expect(small.rect == Rect(origin: Point(x: 809, y: 389), size: Size(width: 135, height: 135)))
    }

    @Test func aVeryWidePictureShrinksToFitTheCanvas() {
        var overlay = CameraOverlay.default
        overlay.shape = .roundedRectangle
        let geometry = CameraOverlayGeometry(overlay: overlay, canvas: canvas, camera: Size(width: 3200, height: 360))
        #expect(geometry.rect.size.width == 1856)
        #expect(geometry.rect.minX == 32)
        #expect(abs(geometry.rect.size.width / geometry.rect.size.height - 3200 / 360.0) < 0.05, "to within a pixel of height")
    }
}

struct CameraPixelSpec {
    static let red: Fixture.Color = (255, 0, 0)
    static let yellow: Fixture.Color = (255, 255, 0)
    static let cyan: Fixture.Color = (0, 255, 255)
    static let magenta: Fixture.Color = (255, 0, 255)
    static let camera = Fixture.Camera(before: (yellow, cyan), after: (magenta, magenta))

    func isRed(_ p: (red: Int, green: Int, blue: Int)) -> Bool { p.red > 200 && p.green < 60 && p.blue < 60 }
    func isYellow(_ p: (red: Int, green: Int, blue: Int)) -> Bool { p.red > 200 && p.green > 200 && p.blue < 60 }
    func isCyan(_ p: (red: Int, green: Int, blue: Int)) -> Bool { p.red < 60 && p.green > 200 && p.blue > 200 }
    func isMagenta(_ p: (red: Int, green: Int, blue: Int)) -> Bool { p.red > 200 && p.green < 60 && p.blue > 200 }

    func cameraTake(_ camera: Fixture.Camera = Self.camera) async throws -> URL {
        let take = try await Fixture.take(color: Self.red)
        try await Fixture.addCamera(camera, to: take)
        return take
    }

    func project(_ take: URL, _ change: (inout CameraOverlay) -> Void = { _ in }) throws -> Project {
        var project = try Project.open(take)
        project.edits.zooms = .empty
        project.edits.style = PixelSpec.blue
        change(&project.edits.style.camera)
        return project
    }

    @Test func theOverlaySitsInItsCornerAsACircle() async throws {
        let take = try await cameraTake()
        defer { try? FileManager.default.removeItem(at: take) }
        let pixels = Pixels(try await Still.cgImage(try project(take), at: .seconds(0.5)))
        #expect(pixels.width == 1920 && pixels.height == 1080)
        #expect(!isRed(pixels[1753, 913]), "overlay centre \(pixels[1753, 913])")
        #expect(!isRed(pixels[1753, 783]), "inside the circle near its top \(pixels[1753, 783])")
        #expect(isRed(pixels[1630, 790]), "outside the circle, inside its square: the screen \(pixels[1630, 790])")
        #expect(isRed(pixels[1610, 913]), "left of the overlay: the screen \(pixels[1610, 913])")
        #expect(isRed(pixels[300, 300]), "elsewhere: the screen \(pixels[300, 300])")
    }

    @Test func mirroredFlipsThePicture() async throws {
        let take = try await cameraTake()
        defer { try? FileManager.default.removeItem(at: take) }
        let mirrored = Pixels(try await Still.cgImage(try project(take), at: .seconds(0.5)))
        let plain = Pixels(try await Still.cgImage(try project(take) { $0.mirrored = false }, at: .seconds(0.5)))
        #expect(isCyan(mirrored[1693, 913]), "mirrored: the camera's right half on the left \(mirrored[1693, 913])")
        #expect(isYellow(mirrored[1813, 913]), "\(mirrored[1813, 913])")
        #expect(isYellow(plain[1693, 913]), "not mirrored: the camera's left half on the left \(plain[1693, 913])")
        #expect(isCyan(plain[1813, 913]), "\(plain[1813, 913])")
    }

    @Test func aRoundedRectangleTakesTheCamerasAspect() async throws {
        let take = try await cameraTake()
        defer { try? FileManager.default.removeItem(at: take) }
        let pixels = Pixels(try await Still.cgImage(try project(take) { $0.shape = .roundedRectangle }, at: .seconds(0.5)))
        #expect(isCyan(pixels[1418, 913]), "left end of a 480 px wide rectangle \(pixels[1418, 913])")
        #expect(isYellow(pixels[1878, 913]), "right end \(pixels[1878, 913])")
        #expect(isRed(pixels[1410, 780]), "the rounded corner is cut \(pixels[1410, 780])")
        #expect(isRed(pixels[1400, 913]), "left of the rectangle \(pixels[1400, 913])")
    }

    @Test func theChosenCornerAndSizeMoveTheOverlay() async throws {
        let take = try await cameraTake()
        defer { try? FileManager.default.removeItem(at: take) }
        let topLeft = Pixels(try await Still.cgImage(try project(take) { $0.corner = .topLeft }, at: .seconds(0.5)))
        #expect(!isRed(topLeft[167, 167]), "top-left overlay centre \(topLeft[167, 167])")
        #expect(isRed(topLeft[1753, 913]), "nothing in the default corner \(topLeft[1753, 913])")

        let large = Pixels(try await Still.cgImage(try project(take) { $0.size = 0.4 }, at: .seconds(0.5)))
        let regular = Pixels(try await Still.cgImage(try project(take), at: .seconds(0.5)))
        #expect(!isRed(large[1480, 840]), "inside a 432 px circle \(large[1480, 840])")
        #expect(isRed(regular[1480, 840]), "outside a 270 px circle \(regular[1480, 840])")
    }

    @Test func aHiddenOverlayDrawsExactlyWhatATakeWithoutACameraDraws() async throws {
        let take = try await cameraTake()
        let plainTake = try await Fixture.take(color: Self.red)
        defer {
            try? FileManager.default.removeItem(at: take)
            try? FileManager.default.removeItem(at: plainTake)
        }
        let hidden = Pixels(try await Still.cgImage(try project(take) { $0.isVisible = false }, at: .seconds(0.5)))
        let without = Pixels(try await Still.cgImage(try project(plainTake), at: .seconds(0.5)))
        #expect(isRed(hidden[1753, 913]))
        #expect(hidden.bytes == without.bytes)
    }

    @Test func justAfterTheCameraChangesTheFrameShowsTheNewPicture() async throws {
        let take = try await cameraTake()
        defer { try? FileManager.default.removeItem(at: take) }
        let project = try project(take)
        let before = Pixels(try await Still.cgImage(project, at: .seconds(1 - 1 / 60.0)))
        let after = Pixels(try await Still.cgImage(project, at: .seconds(1 + 1 / 60.0)))
        #expect(isCyan(before[1693, 913]), "the frame before the change \(before[1693, 913])")
        #expect(isMagenta(after[1693, 913]), "the frame after the change \(after[1693, 913])")
    }

    @Test func noCameraFrameAtTDrawsNoOverlay() async throws {
        let take = try await cameraTake(Fixture.Camera(before: (Self.yellow, Self.cyan), after: (Self.yellow, Self.cyan), from: 0.5, until: 1.5))
        defer { try? FileManager.default.removeItem(at: take) }
        let project = try project(take)
        let early = Pixels(try await Still.cgImage(project, at: .seconds(0.25)))
        let during = Pixels(try await Still.cgImage(project, at: .seconds(0.75)))
        let late = Pixels(try await Still.cgImage(project, at: .seconds(1.75)))
        #expect(isRed(early[1753, 913]), "before the camera's first frame \(early[1753, 913])")
        #expect(isCyan(during[1693, 913]), "while the camera runs \(during[1693, 913])")
        #expect(isRed(late[1753, 913]), "after the camera's track ends \(late[1753, 913])")
    }

    @Test func theExportDrawsNoOverlayWhereTheCameraHasNoMedia() async throws {
        let take = try await cameraTake(Fixture.Camera(before: (Self.yellow, Self.cyan), after: (Self.yellow, Self.cyan), from: 0.5, until: 1.5))
        let destination = FileManager.default.temporaryDirectory.appending(path: "camera-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: take)
            try? FileManager.default.removeItem(at: destination)
        }
        _ = try await Export.run(try project(take), to: destination)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: destination))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let early = Pixels(try await generator.image(at: CMTime(value: 15, timescale: 60)).image)
        let during = Pixels(try await generator.image(at: CMTime(value: 45, timescale: 60)).image)
        let late = Pixels(try await generator.image(at: CMTime(value: 105, timescale: 60)).image)
        #expect(isRed(early[1753, 913]), "before the camera's first frame \(early[1753, 913])")
        #expect(isCyan(during[1693, 913]), "while the camera runs \(during[1693, 913])")
        #expect(isRed(late[1753, 913]), "after the camera's track ends, no frozen frame \(late[1753, 913])")
    }

    @Test func theExportShowsTheNewPictureJustAfterTheChange() async throws {
        let take = try await cameraTake()
        let destination = FileManager.default.temporaryDirectory.appending(path: "camera-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: take)
            try? FileManager.default.removeItem(at: destination)
        }
        let report = try await Export.run(try project(take), to: destination)
        #expect(report.frames == 120)
        #expect(report.warnings.isEmpty, "\(report.warnings)")

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: destination))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let before = Pixels(try await generator.image(at: CMTime(value: 59, timescale: 60)).image)
        let after = Pixels(try await generator.image(at: CMTime(value: 61, timescale: 60)).image)
        #expect(isCyan(before[1693, 913]), "exported frame 59 \(before[1693, 913])")
        #expect(isMagenta(after[1693, 913]), "exported frame 61 \(after[1693, 913])")
    }
}
