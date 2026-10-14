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
        if !stills.isEmpty, out != nil { throw ValidationError("--still and --out are exclusive") }
        if let fps, FrameRate(rawValue: fps) == nil { throw ValidationError("--fps must be 30 or 60") }
    }

    func run() async throws {
        let takeURL = URL(filePath: take, directoryHint: .isDirectory)
        var project: Project
        do {
            project = autoZooms ? try Project.generated(takeURL) : try Project.open(takeURL)
        } catch {
            print("cannot open \(take): \(error)")
            throw ExitCode(2)
        }
        if let size { project.edits.format.size = size }
        if let fps { project.edits.format.frameRate = FrameRate(rawValue: fps)! }
        if let codec { project.edits.format.codec = codec }
        for warning in project.source.loadWarnings { print("load warning: \(warning)") }
        print("edits: \(project.origin == .saved ? "project.json" : "generated"), \(project.edits.zooms.segments.count) zooms")

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
        let destination = URL(filePath: out!, directoryHint: .notDirectory)
        let format = project.edits.format
        let canvas = format.canvasSize(for: project.source.frameSize, padding: project.edits.style.padding)
        let report: ExportReport
        let export = Task { [project] in
            try await Export.run(project, to: destination) { p in
                let width = 30
                let filled = Int(p.fraction * Double(width))
                let bar = String(repeating: "#", count: filled) + String(repeating: "-", count: width - filled)
                FileHandle.standardError.write(Data("\r[\(bar)] \(p.framesWritten)/\(p.framesTotal)".utf8))
            }
        }
        // Ctrl-C cancels the task, which removes the partial file instead of leaving it behind.
        let interrupts = InterruptHandler { export.cancel() }
        interrupts.install()
        do {
            report = try await export.value
        } catch {
            FileHandle.standardError.write(Data("\n".utf8))
            print("export failed: \(error)")
            throw ExitCode(1)
        }
        FileHandle.standardError.write(Data("\n".utf8))
        for warning in report.warnings { print("warning: \(warning)") }
        print(String(
            format: "%d frames, %dx%d @ %d %@, %.2f s wall, %.1f fps, %.2fx real time, %.1f MB -> %@",
            report.frames, canvas.width, canvas.height, format.frameRate.rawValue, format.codec.rawValue,
            report.wallSeconds, Double(report.frames) / report.wallSeconds, report.realTimeFactor,
            Double(report.bytes) / 1e6, destination.path))
    }
}

extension CanvasPreset: ExpressibleByArgument {}
extension Codec: ExpressibleByArgument {}
