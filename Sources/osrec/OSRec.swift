import ArgumentParser
import Recording
import Timeline

@main
struct OSRec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "osrec",
        abstract: "Record a display with input events into an .osrec directory, and inspect recordings."
    )
}
