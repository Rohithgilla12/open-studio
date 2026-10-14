// The entire app target. Everything else is the `Studio` library in the package, so `swift build`
// type-checks the UI and `swift test` covers its logic. The target adds only what must belong to a
// bundle: this entry point, Info.plist, entitlements, the icon, and signing.
//
// App/
//   OpenStudio.xcodeproj         one macOS app target; App/OpenStudio is a synchronised folder
//                                (PBXFileSystemSynchronizedRootGroup), so adding a file never
//                                edits project.pbxproj; local package reference ".." -> Studio
//   OpenStudio/OpenStudioApp.swift
//   OpenStudio/Info.plist        NSMicrophoneUsageDescription; bundle id dev.openstudio.OpenStudio
//   OpenStudio/OpenStudio.entitlements
//                                hardened runtime, com.apple.security.device.audio-input; no sandbox
//   Config/Base.xcconfig         checked in; ends with `#include? "Local.xcconfig"`
//   Config/Local.xcconfig        gitignored; DEVELOPMENT_TEAM = <your team id>
//
// TCC keys a grant to the app's designated requirement. An ad hoc ("Sign to Run Locally") build's
// requirement is its cdhash, which changes on every rebuild, so each rebuild loses Screen
// Recording and Input Monitoring. A stable Apple Development identity (a free personal team works)
// makes the requirement "bundle id + team", which survives rebuilds. Without an Apple ID, a
// self-signed code-signing certificate named in Local.xcconfig does the same. To start over:
// `tccutil reset ScreenCapture dev.openstudio.OpenStudio` (and ListenEvent, Microphone).

import Studio
import SwiftUI

@main
struct OpenStudioApp: App {
    var body: some Scene { StudioScene() }
}
