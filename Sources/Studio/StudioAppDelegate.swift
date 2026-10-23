import AppKit

public final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    /// The window is hidden while recording, so when Stop removes the menu bar item AppKit sees no
    /// window left and, by SwiftUI's default for a single-window app, quits mid-way through opening
    /// the take (seen in the log as `_scheduleCheckForTerminateAfterLastWindowClosed`).
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
