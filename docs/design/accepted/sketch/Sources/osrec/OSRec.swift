import ArgumentParser
import Foundation
import Recording
import Timeline

/// Verification harness. Every subcommand is a thin shell over the public Recording and Timeline
/// APIs, the same ones the SwiftUI app will call, so a passing CLI run exercises the real paths.
///
/// Run from a terminal, TCC charges Screen Recording and Input Monitoring to the terminal app.
@main
struct OSRec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "osrec",
        abstract: "Record a display with input events into an .osrec directory, and inspect recordings.",
        subcommands: [PermissionsCommand.self, Displays.self, Record.self, Recover.self, Inspect.self]
    )
}

/// `osrec permissions [--request]`
/// Prints each permission's status. Exit code 1 if any permission needed for a microphone-less
/// recording is missing. `--request` shows the system prompts.
struct PermissionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "permissions")
    @Flag var request = false
    @Flag(help: "Also require microphone access.") var mic = false

    func run() async throws { fatalError("not implemented") }
}

/// `osrec displays` lists displays (id, name, pixel size, refresh rate, main) and microphones.
struct Displays: AsyncParsableCommand {
    func run() async throws { fatalError("not implemented") }
}

/// `osrec record [--display ID] [--mic default|DEVICE_ID] [--duration 5] [--fps 60] [--codec hevc] [--out DIR]`
///
/// Prints the directory path first, progress once per second, and the summary at the end.
/// Ctrl-C stops cleanly (SIGINT is handled with a DispatchSource and calls `session.stop()`; a second
/// Ctrl-C exits immediately and leaves the directory for `osrec recover`).
///
/// `--abort-after SECONDS` calls abort() mid-recording without finalizing. It exists to verify crash
/// recovery: `osrec record --duration 10 --abort-after 5 && osrec recover <dir> && osrec inspect <dir>`.
struct Record: AsyncParsableCommand {
    @Option var display: UInt32?
    @Option(help: "\"default\" for the system microphone, or a device unique ID from `osrec displays`.")
    var mic: String?
    @Option var duration: Double?
    @Option var fps: Int = 60
    @Option var codec: String = "hevc"
    @Option var out: String = "."
    @Option(name: .customLong("abort-after")) var abortAfter: Double?

    func run() async throws {
        // TODO:
        // let config = RecordingConfiguration(outputDirectory:..., display:..., microphone:..., ...)
        // let missing = Permissions.check().missing(for: config)
        // guard missing.isEmpty else { print(RecordingError.missingPermissions(missing)); throw ExitCode(1) }
        // let session = try await RecordingSession.start(config)
        // print(session.directory.path)
        // install SIGINT handler -> Task { await session.stop() }
        // if let abortAfter { Task { try await Task.sleep(for: .seconds(abortAfter)); abort() } }
        // for await update in session.updates { print progress / warnings; on .ended(let finished): print summary }
        fatalError("not implemented")
    }
}

/// `osrec recover DIR` finalizes a directory whose recorder died. Safe to run repeatedly.
struct Recover: AsyncParsableCommand {
    @Argument var directory: String
    func run() async throws { fatalError("not implemented") }
}

/// `osrec inspect DIR [--sample-hz 10] [--json]`
///
/// Loads the directory through Timeline exactly as an editor would and prints: manifest summary,
/// event counts by kind, generated zoom segments, and camera plus cursor state sampled at
/// `--sample-hz`. This is the end-to-end check that a real recording satisfies the Timeline loader.
///
/// `--check-determinism` evaluates every sample time forward, reversed, and shuffled, and fails if any
/// result differs bitwise.
struct Inspect: AsyncParsableCommand {
    @Argument var directory: String
    @Option(name: .customLong("sample-hz")) var sampleHz: Double = 10
    @Flag var json = false
    @Flag(name: .customLong("check-determinism")) var checkDeterminism = false

    func run() async throws {
        // TODO:
        // let source = try SourceRecording.load(from: url)
        // let zooms = AutoZoom.segments(for: source)
        // let timeline = Timeline(source: source, zooms: zooms)
        // for t in stride(from: 0, to: source.duration.seconds, by: 1 / sampleHz):
        //   print(t, timeline.camera(at: .seconds(t)), timeline.cursor(at: .seconds(t)))
        fatalError("not implemented")
    }
}
