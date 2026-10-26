// Sources/Recording/Configuration.swift (ResolvedTarget.filter replaced).
//
// Our own windows (the camera bubble, the control bar, the countdown, and the menu bar extra)
// stay out of every take by the filter, not by hiding the app. The decision is a pure value so a
// unit test can pin it for every target; turning it into an SCContentFilter is one switch.

import ScreenCaptureKit

enum CaptureFilterPlan: Equatable {
    /// Display and area targets: the whole display minus every window of this process. Excluding
    /// the application, not a list of windows, also covers a panel opened after the stream
    /// started, such as the bubble shown mid-take or the countdown on a restart.
    case displayExcludingOwnApp
    /// Window targets: only the target app's windows, as today. Ours are not in it, so nothing
    /// to exclude.
    case application(pid_t)
    case window(CGWindowID)

    static func plan(for target: ResolvedTarget.Content) -> CaptureFilterPlan { fatalError("not implemented") }
}

extension ResolvedTarget {
    /// `own` is this process's `SCRunningApplication` from the same `SCShareableContent` the target
    /// was resolved from. nil only in a process with no window (osrec), where there is nothing to
    /// exclude. The Studio puts the control bar on screen, in its "Starting" state, before calling
    /// `start`, so the app is listed by then.
    func filter(_ plan: CaptureFilterPlan, own: SCRunningApplication?) -> SCContentFilter {
        // .displayExcludingOwnApp: SCContentFilter(display:, excludingApplications: own.map { [$0] } ?? [], exceptingWindows: [])
        fatalError("not implemented")
    }
}

// Not relied on: `NSWindow.sharingType = .none`. spike/capture-exclusion tests it on its own,
// next to the application filter and a control that excludes nothing, so a run shows whether the
// check can detect a leak at all.
