import AVKit
import Recording
import Render
import SwiftUI
import Timeline

/// Display picker, microphone picker, permission rows, Record button, and the library list.
struct SetupView: View {
    let model: AppModel
    var setup: RecordSetup
    var body: some View { fatalError("not implemented") }
}

/// One row per `Permission`: status, and for a missing one an "Open System Settings" button that
/// opens `permission.settingsURL`. Screen Recording and Input Monitoring take effect after a
/// relaunch; the row says so and offers "Relaunch".
struct PermissionsView: View {
    var report: PermissionReport
    var missing: [Permission]
    var body: some View { fatalError("not implemented") }
}

/// Elapsed media time, frame and event counts, warnings, and Stop.
struct RecordingPanel: View {
    let model: AppModel
    var body: some View { fatalError("not implemented") }
}

/// Preview on top (`VideoPlayer(player: editor.preview.player)`), transport, then the zoom strip,
/// with a style inspector on the right and Export in the toolbar.
struct EditorView: View {
    let editor: Editor
    var body: some View { fatalError("not implemented") }
}

/// The timeline strip: a ruler of the take's duration, one block per `ZoomSegment`, a playhead.
///
/// Gestures emit `EditAction`s, nothing else: drag the body -> `.moveZoom(id, by:)`, drag an edge
/// -> `.resizeZoom`, Backspace on the selection -> `.deleteZoom`, click the ruler -> seek. Drags
/// clamp to the neighbours' edges in the view so the reducer's validation is a backstop. The
/// strip is read-only when `editor.mode` is not `.editing` (it still shows the frozen segments).
struct ZoomStripView: View {
    let editor: Editor
    var zooms: ZoomTrack
    var duration: RecordingTime
    var playhead: RecordingTime
    @State private var selection: ZoomSegment.ID?

    var body: some View { fatalError("not implemented") }

    /// Pure: pixel x in the strip to recording time and back. Tested through the preview.
    static func time(atX x: Double, width: Double, duration: RecordingTime) -> RecordingTime { fatalError("not implemented") }
}

/// Background preset, padding, corner radius, shadow, cursor smoothing, output preset.
/// Each control emits `.setStyle` / `.setSettings` / `.setOutput` with the whole value.
struct StyleInspector: View {
    let editor: Editor
    var edit: EditDocument
    var body: some View { fatalError("not implemented") }
}

/// Sheet over the editor: progress bar and Cancel while exporting; "Reveal in Finder" and the
/// real-time factor when done; the error and Retry when failed.
struct ExportSheet: View {
    let editor: Editor
    var body: some View { fatalError("not implemented") }
}
