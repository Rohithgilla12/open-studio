import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Timeline
import UniformTypeIdentifiers

/// Single frames through the same composition, for `osrec export --still`, the pixel test, and
/// later the zoom strip's thumbnails.
public enum Still {
    /// PNG bytes of the frame at output time `t`, the time in the exported movie. Uses `AVAssetImageGenerator` with the project's video
    /// composition and zero tolerances, so the compositor and scene are exactly the export's.
    public static func png(_ project: Project, at t: OutputTime) async throws(ExportError) -> Data {
        let image = try await cgImage(project, at: t)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw .writerFailed("could not create a PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw .writerFailed("could not encode the PNG") }
        return data as Data
    }

    static func cgImage(_ project: Project, at t: OutputTime) async throws(ExportError) -> CGImage {
        let movie: MovieComposition
        let scene: RenderScene
        do {
            movie = MovieComposition(media: try await SourceMedia.load(project.source), map: project.timeline.map)
            scene = try RenderScene.make(project: project, format: project.edits.format, reusing: nil)
        } catch {
            throw .render(error)
        }
        let generator = AVAssetImageGenerator(asset: movie.asset)
        generator.videoComposition = movie.videoComposition(scene: scene, frameRate: project.edits.format.frameRate)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // The instruction covers [0, duration), so a request at the duration itself is moved
        // inside it by one frame.
        let last = OutputTime(compositionTime: movie.duration) - .seconds(1 / Double(project.edits.format.frameRate.rawValue))
        let time = min(max(t, .zero), max(last, .zero))
        do {
            return try await generator.image(at: time.compositionTime).image
        } catch {
            throw .readerFailed(error.localizedDescription)
        }
    }
}
