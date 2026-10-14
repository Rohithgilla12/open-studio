import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Timeline
import UniformTypeIdentifiers

/// Single frames through the same composition, for `osrec export --still`, the pixel test, and
/// later the zoom strip's thumbnails.
public enum Still {
    /// PNG bytes of the frame at `t`. Uses `AVAssetImageGenerator` with the project's video
    /// composition and zero tolerances, so the compositor and scene are exactly the export's.
    public static func png(_ project: Project, at t: RecordingTime) async throws(ExportError) -> Data {
        let image = try await cgImage(project, at: t)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw .readerFailed("could not create a PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw .readerFailed("could not encode the PNG") }
        return data as Data
    }

    static func cgImage(_ project: Project, at t: RecordingTime) async throws(ExportError) -> CGImage {
        let movie: MovieComposition
        let scene: RenderScene
        do {
            movie = try await MovieComposition.load(project.source)
            scene = try RenderScene.make(project: project, format: project.edits.format, reusing: nil)
        } catch {
            throw .render(error)
        }
        let generator = AVAssetImageGenerator(asset: movie.asset)
        generator.videoComposition = movie.videoComposition(scene: scene, frameRate: project.edits.format.frameRate)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            return try await generator.image(at: t.clamped(to: project.source.duration).cmTime).image
        } catch {
            throw .readerFailed(error.localizedDescription)
        }
    }
}

extension RecordingTime {
    func clamped(to duration: RecordingTime) -> RecordingTime {
        min(max(self, .zero), duration)
    }
}
