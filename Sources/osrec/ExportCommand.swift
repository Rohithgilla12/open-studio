import ArgumentParser
import Foundation
import Render
import Timeline

/// A thin shell: open the project, override the format from flags, call Export or Still.
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
        help: "Write the frame at this many milliseconds as <still-dir>/<take>-<ms>.png instead of a movie. Repeatable.")
    var stills: [Int64] = []
    @Option(help: "Directory for --still PNGs. Default: the current directory.") var stillDir: String = "."

    func validate() throws {
        if stills.isEmpty, out == nil { throw ValidationError("--out is required unless --still is given") }
        if let fps, FrameRate(rawValue: fps) == nil { throw ValidationError("--fps must be 30 or 60") }
    }

    func run() async throws {
        let takeURL = URL(filePath: take, directoryHint: .isDirectory)
        var project: Project
        do {
            project = try Project.open(takeURL)
        } catch {
            print("cannot open \(take): \(error)")
            throw ExitCode(2)
        }
        if autoZooms {
            var generated = Edits.generated(for: project.source)
            generated.format = project.edits.format
            project.edits = generated
        }
        if let size { project.edits.format.size = size }
        if let fps { project.edits.format.frameRate = FrameRate(rawValue: fps)! }
        if let codec { project.edits.format.codec = codec }
        for warning in project.source.loadWarnings { print("load warning: \(warning)") }
        print("edits: \(project.origin == .saved && !autoZooms ? "project.json" : "generated"), \(project.edits.zooms.segments.count) zooms")

        if !stills.isEmpty {
            let directory = URL(filePath: stillDir, directoryHint: .isDirectory)
            let name = takeURL.deletingPathExtension().lastPathComponent
            for ms in stills {
                let png = try await Still.png(project, at: .milliseconds(ms))
                let url = directory.appending(path: "\(name)-\(ms).png", directoryHint: .notDirectory)
                try png.write(to: url)
                print(url.path)
            }
            return
        }
        print("movie export is not implemented yet")
        throw ExitCode(1)
    }
}

extension CanvasPreset: ExpressibleByArgument {}
extension Codec: ExpressibleByArgument {}
