import ArgumentParser
import Foundation
import Project
import Render

/// `osrec export <take> --out <file>.mp4`. A thin shell over `Project` and `TakeMedia.export`.
struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Render a take to an MP4 using its saved edits.")

    @Argument(help: "A finalised .osrec directory.") var take: String
    @Option(help: "Output .mp4. Refuses to overwrite without --force.") var out: String
    @Option(help: "1080p30, 1080p60, native60, or 4k60. Default: the take's saved choice.") var preset: OutputChoice?
    @Option(help: "hevc or h264.") var codec: OutputSpec.OutputCodec?
    @Flag(name: .customLong("ignore-edits"), help: "Use auto-zoom and the default style, not studio.json.") var ignoreEdits = false
    @Flag var force = false

    func run() async throws {
        // TODO
        //  var project = try await Project.open(URL(filePath: take))
        //  if ignoreEdits { project = project.with { $0 = .initial(for: project.source) } }
        //  if let preset { project = project.with { $0.output = preset } }
        //  let plan = try project.plan()
        //  once a second print: "12.0 s of 30.0 s  2.9x realtime"
        //  Task cancellation on SIGINT, so Ctrl-C removes the partial file
        //  print final line: path, frames, wall seconds, speed ratio, bytes
        //  exit 1 on failure, naming the next action for .needsRecovery
        fatalError("not implemented")
    }
}

/// `osrec still <take> --at <seconds> --out <file>.png [--size 1920x1080]`. Draws one frame through the
/// same `FrameRenderer` the compositor uses, for inspection and for preview-equals-export checks.
struct Still: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Render one frame to a PNG.")

    @Argument var take: String
    @Option var at: Double
    @Option var out: String
    @Option var size: String?

    func run() async throws {
        // TODO let project = try await Project.open(...); let image = try await project.media.still(plan: try project.plan(), at: .seconds(at))
        // then write the CGImage as PNG with ImageIO. No drawing code here: `still` runs the same renderer.
        fatalError("not implemented")
    }
}

// Registered in OSRec.configuration.subcommands next to Inspect.
