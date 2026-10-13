import ArgumentParser
import Foundation
import Recording
import Timeline

/// Terminal harness. Links the same `Recording` library the app will, which is the whole
/// point: a 5-second `osrec record` followed by `osrec inspect` verifies the contract
/// end to end without any UI. TCC attributes permissions to the terminal app it runs in.
@main
struct Osrec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "open-studio recorder harness",
        subcommands: [PermissionsCommand.self, Displays.self, Record.self, Inspect.self]
    )
}

struct PermissionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "permissions", abstract: "Check (and optionally request) Screen Recording and Input Monitoring")

    @Flag(help: "Prompt for any missing permission")
    var request = false

    func run() throws {
        // TODO: print Permissions.check(); if request, Permissions.request(each missing); exit 1 if still missing
        fatalError("not implemented")
    }
}

struct Displays: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List displays")

    func run() async throws {
        // TODO: for d in try await DisplayInfo.available() { print(id, name, size, scale, main) }
        fatalError("not implemented")
    }
}

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Record one display into a .osrec directory")

    @Option(name: .shortAndLong, help: "Output directory (default: ./<timestamp>.osrec)")
    var out: String?

    @Option(help: "Display id from `osrec displays` (default: main)")
    var display: UInt32?

    @Option(help: "Stop automatically after this many seconds; otherwise Ctrl-C")
    var seconds: Double?

    @Flag(help: "Capture the default microphone")
    var mic = false

    @Option(help: "Frames per second")
    var fps = 60

    @Flag(help: "Record key codes (off by default for privacy)")
    var keyCodes = false

    func run() async throws {
        // TODO:
        // var config = RecordingConfig(outputDirectory: out ?? defaultName())
        // config.display = display.map { .id($0) } ?? .main; config.microphone = mic ? .systemDefault : .none; ...
        // let session = try await RecordingSession.start(config)
        // print("recording -> \(config.outputDirectory.path)")
        // install SIGINT handler (DispatchSource) -> Task { try await session.stop() }
        // if let seconds { try await Task.sleep(for: .seconds(seconds)); }
        // let result = try await session.stop()      // idempotent with the signal path
        // print(result)
        // on RecordingError.permissionsMissing: print each Permission.settingsURL, exit 2
        fatalError("not implemented")
    }
}

struct Inspect: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Load a .osrec directory with Timeline and summarise it")

    @Argument(help: "Path to a .osrec directory")
    var path: String

    @Flag(help: "Print automatic zoom segments and a few sampled camera/cursor frames")
    var zooms = false

    func run() throws {
        // TODO:
        // let take = try Take.load(from: URL(filePath: path))
        // print display, duration, integrity, counts per track, first/last event time
        // if zooms: let p = Project.automatic(take:); print p.zooms.segments
        //           let s = Sampler(project: p); for t in stride(0, duration, 0.5 s) { print s.frame(at: t) }
        // exit 3 when integrity is .recovered so scripts can tell
        fatalError("not implemented")
    }
}
