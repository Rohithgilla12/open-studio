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
    @Option(help: "fit, 16:9, 9:16, 1:1, 4:3, or 4:5. Native ignores it. Default: the project's format.") var aspect: CanvasAspect?
    @Option(help: "30 or 60. Default: the project's format.") var fps: Int?
    @Option(help: "hevc or h264. Default: the project's format.") var codec: Codec?
    @Flag(help: "Ignore project.json and use automatic zooms with default settings and style.") var autoZooms = false
    @Flag(help: "Leave the camera out, whatever project.json says.") var noCamera = false
    @Flag(help: "Leave the microphone out of the mix, whatever project.json says.") var muteMic = false
    @Flag(help: "Leave system audio out of the mix, whatever project.json says.") var muteSystem = false
    @Option(help: "Scale the redrawn cursor, 0.5 to 3. Default: the project's setting.") var cursorSize: Double?
    @Flag(help: "Leave the cursor out, whatever project.json says.") var hideCursor = false
    @Flag(help: "Draw a ring at each click, whatever project.json says.") var showClicks = false
    @Option(
        name: .customLong("still"),
        help: "Write the frame at this many milliseconds into the exported movie (output time, after cuts) as <still-dir>/<take>-<ms>.png instead of a movie. Repeatable.")
    var stills: [Int64] = []
    @Option(help: "Directory for --still PNGs. Default: the current directory.") var stillDir: String = "."

    func validate() throws {
        if stills.isEmpty, out == nil { throw ValidationError("--out is required unless --still is given") }
        if !stills.isEmpty, out != nil { throw ValidationError("--still and --out are exclusive") }
        if let fps, FrameRate(rawValue: fps) == nil { throw ValidationError("--fps must be 30 or 60") }
        if let cursorSize, !CursorSettings.sizeRange.contains(cursorSize) { throw ValidationError("--cursor-size must be in 0.5...3") }
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
        if let aspect { project.edits.format.aspect = aspect }
        if let fps { project.edits.format.frameRate = FrameRate(rawValue: fps)! }
        if let codec { project.edits.format.codec = codec }
        if noCamera { project.edits.style.camera.isVisible = false }
        if muteMic { project.edits.audio.microphone.isMuted = true }
        if muteSystem { project.edits.audio.systemAudio.isMuted = true }
        if let cursorSize { project.edits.settings.cursor.size = cursorSize }
        if hideCursor { project.edits.settings.cursor.isHidden = true }
        if showClicks { project.edits.settings.cursor.showsClicks = true }
        for warning in project.source.loadWarnings { print("load warning: \(warning)") }
        let camera = !project.source.hasCamera ? "no camera" : project.edits.style.camera.isVisible ? "camera shown" : "camera hidden"
        let audio = AudioSource.recorded(in: project.source).map { source in
            let level = project.edits.audio[source]
            return "\(source.name.lowercased()) \(level.isMuted ? "muted" : String(format: "at %.2f", level.volume))"
        }
        let cuts = project.edits.cuts.cuts.count
        print("edits: \(project.origin == .saved ? "project.json" : "generated"), \(project.edits.zooms.segments.count) zooms, "
            + "\(cuts) cut\(cuts == 1 ? "" : "s") (output \(String(format: "%.3f", project.timeline.map.duration.seconds)) s), \(camera), "
            + (audio.isEmpty ? "no audio" : audio.joined(separator: ", ")))

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
        let canvas = project.canvasSize(for: format)
        let report: ExportReport
        // A redrawn bar is noise in a log or a pipe, so it only draws on a terminal.
        let drawsProgress = isatty(STDERR_FILENO) == 1
        let export = Task { [project] in
            try await Export.run(project, to: destination) { p in
                guard drawsProgress else { return }
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
            if drawsProgress { FileHandle.standardError.write(Data("\n".utf8)) }
            print("export failed: \(error)")
            throw ExitCode(1)
        }
        if drawsProgress { FileHandle.standardError.write(Data("\n".utf8)) }
        for warning in report.warnings { print("warning: \(warning)") }
        print(String(
            format: "%d frames, %dx%d @ %d %@, %.2f s wall, %.1f fps, %.2fx real time, %.1f MB -> %@",
            report.frames, canvas.width, canvas.height, format.frameRate.rawValue, format.codec.rawValue,
            report.wallSeconds, Double(report.frames) / report.wallSeconds, report.realTimeFactor,
            Double(report.bytes) / 1e6, destination.path))
    }
}

extension CanvasPreset: ExpressibleByArgument {}
extension CanvasAspect: ExpressibleByArgument {}
extension Codec: ExpressibleByArgument {}
