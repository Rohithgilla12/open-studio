import ArgumentParser
import Foundation
import Recording
import RecordingFormat
import Timeline

@main
struct OSRec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "osrec",
        abstract: "Record a display and inspect recordings. Thin shell over the Recording and Timeline libraries.",
        subcommands: [Check.self, Displays.self, Record.self, Inspect.self, Recover.self, Zooms.self, Sample.self, VerifyClock.self]
    )
}

extension OSRec {
    /// Exit 0 when everything needed is granted, 3 otherwise. Prints which permission and where
    /// to grant it, and names the terminal app, since TCC attaches to the responsible process.
    struct Check: AsyncParsableCommand {
        @Flag var mic = false
        func run() async throws { fatalError("not implemented") }
    }

    struct Displays: AsyncParsableCommand {
        func run() async throws { fatalError("not implemented") }
    }

    /// osrec record --out ./out --duration 5 [--mic] [--fps 60] [--display <id>]
    /// SIGINT or SIGTERM calls session.stop() once; a second signal exits immediately and
    /// leaves a recoverable directory. Prints the recording path on stdout, nothing else.
    struct Record: AsyncParsableCommand {
        @Option var out: String = "."
        @Option var duration: Double?
        @Option var fps: Int = 60
        @Option var display: UInt32?
        @Flag var mic = false
        func run() async throws {
            // TODO: build RecordingConfig, Recorder().start, drive signal DispatchSources,
            // stream states to stderr, await stop(), print summary.directory.path
            fatalError("not implemented")
        }
    }

    /// Loads through RecordingReader and prints manifest summary, counts, diagnostics.
    /// Exit 0 valid, 2 needs recovery, 1 invalid. Works on a metadata-only fixture with --no-media.
    struct Inspect: AsyncParsableCommand {
        @Argument var directory: String
        @Flag var noMedia = false
        func run() async throws { fatalError("not implemented") }
    }

    struct Recover: AsyncParsableCommand {
        @Argument var directory: String
        func run() async throws { fatalError("not implemented") }
    }

    /// Prints Timeline's automatic zoom segments as JSON. The check for click windows and merging
    /// on a real take.
    struct Zooms: AsyncParsableCommand {
        @Argument var directory: String
        func run() async throws { fatalError("not implemented") }
    }

    /// osrec sample <dir> --at 1.25 [--step 0.0166 --count 60]
    /// Prints CameraState and CursorState as JSON lines. Run twice with --reverse and diff the
    /// output to check the order-independence contract by hand.
    struct Sample: AsyncParsableCommand {
        @Argument var directory: String
        @Option var at: Double = 0
        @Option var step: Double = 1.0 / 60
        @Option var count: Int = 1
        @Flag var reverse = false
        func run() async throws { fatalError("not implemented") }
    }

    /// Reports the skew between the first input event and the first video frame PTS, and the
    /// event-timestamp unit assumption (ticks versus ns). The hands-on check of the one-clock claim:
    /// click at a flashing frame, expect the click's t within one frame of the flash.
    struct VerifyClock: AsyncParsableCommand {
        @Argument var directory: String
        func run() async throws { fatalError("not implemented") }
    }
}
