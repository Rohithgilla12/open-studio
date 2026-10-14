import ArgumentParser
import Foundation
import Render
import Timeline

// Additions to Sources/osrec/OSRec.swift's subcommand list: Export.self, Frame.self.

/// `osrec export <take.osrec> --out file.mp4 [--size 1080p|native] [--fps 30|60] [--codec h264|hevc]`
///
/// Uses `edit.json` when the app has saved one, so the CLI renders what the editor shows; flags
/// override the output format only. Prints progress once a second and the real-time factor at the end.
struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Render a take to an MP4 through the compositor.")

    @Argument var take: String
    @Option var out: String
    @Option var size: SizePreset?
    @Option var fps: Int?
    @Option var codec: OutputCodec?

    func run() async throws {
        // TODO: project = try await Project.open(URL(filePath: take))
        //   edit = project.edit with overrides applied via .setOutput
        //   job = Exporter.export(project, to: URL(filePath: out))
        //   for await p in job.progress { print once per second }
        //   result = try await job.result.value; print frames, wall clock, realTimeFactor
        fatalError("not implemented")
    }
}

/// `osrec frame <take.osrec> --at <ms> --out frame.png`. The pixel-inspection surface: the same
/// composed frame the export writes at that time, as a PNG.
struct Frame: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Write one composed frame as PNG.")

    @Argument var take: String
    @Option(help: "Milliseconds on the recording clock.") var at: Double
    @Option var out: String
    @Option var size: SizePreset?

    func run() async throws { fatalError("not implemented") }
}

extension SizePreset: ExpressibleByArgument {}
extension OutputCodec: ExpressibleByArgument {}
