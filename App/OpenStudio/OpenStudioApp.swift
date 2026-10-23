import Studio
import SwiftUI

@main
struct OpenStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var delegate

    var body: some Scene { StudioScene() }
}
