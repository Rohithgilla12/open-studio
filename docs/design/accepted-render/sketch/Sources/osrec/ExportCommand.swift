import ArgumentParser
import Foundation
import Render
import Timeline

// In the implementation this is `Sources/osrec/Export.swift`, registered in OSRec's subcommands.
// It is a thin shell: open the project, override the format from flags, call Export or Still.

@main
struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Render a take with its saved edits (or automatic zooms) to an MP4, or to PNG stills.",
        discussion: """
            Uses <take>/project.json when present, so the file matches what the app shows. \
            Never writes into the take.
            """)

    @Argument(help: "The .osrec directory.") var take: String
    @Option(help: "Output MP4 path. Required unless --still is given.") var out: String?
    @Option(help: "hd1080, uhd2160, or native. Default: the project's format.") var size: CanvasPreset?
    @Option(help: "30 or 60. Default: the project's format.") var fps: Int?
    @Option(help: "hevc or h264. Default: the project's format.") var codec: Codec?
    @Flag(help: "Ignore project.json and use automatic zooms with default settings and style.") var autoZooms = false
    @Option(
        name: .customLong("still"),
        help: "Write the frame at this many milliseconds as <out-dir>/<take>-<ms>.png instead of a movie. Repeatable.")
    var stills: [Int64] = []
    @Option(help: "Directory for --still PNGs. Default: the current directory.") var stillDir: String = "."

    func validate() throws {
        if stills.isEmpty, out == nil { throw ValidationError("--out is required unless --still is given") }
        if let fps, FrameRate(rawValue: fps) == nil { throw ValidationError("--fps must be 30 or 60") }
    }

    func run() async throws {
        // TODO:
        //   var project = try Project.open(URL(filePath: take))
        //   if autoZooms { project.edits = Edits(zooms: AutoZoom.track(for: project.source), settings: .default,
        //                                         style: .default, format: project.edits.format) }
        //   apply size / fps / codec overrides to project.edits.format
        //   print("edits: \(project.origin == .saved ? "project.json" : "generated"), \(zooms.count) zooms")
        //   if !stills.isEmpty: for ms in stills: write Still.png(project, at: .milliseconds(ms)); return
        //   report = try await Export.run(project, to: out) { p in redraw a one-line progress bar on stderr }
        //   print("\(report.frames) frames, \(canvas) @ \(fps), \(wall) s, \(realTimeFactor)x real time")
        // Exit codes: 0 done, 1 export failed, 2 take unreadable or needs `osrec recover`.
        fatalError("not implemented")
    }
}

extension CanvasPreset: ExpressibleByArgument {}
extension Codec: ExpressibleByArgument {}
