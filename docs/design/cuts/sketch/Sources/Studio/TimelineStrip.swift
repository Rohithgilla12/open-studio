import SwiftUI
import Timeline

/// The strip is over recording time, as today: `StripScale(width:duration:)` keeps mapping x over
/// the whole recording. Cuts are drawn as removed regions you can see, select, resize, and restore.
///
///     ruler   |::::|      [drag here to cut]       |:::::::|               |:::|
///     zooms   |::::|  [ 2.0x ]    [ 2.0x ]         |:[2.0x]|  [ 2.0x  ]   |:::|
///             ^trim                                 ^ cut (hatched)        trim^
///             handle                                                        handle
///
/// - Ruler row (16 pt, new): dragging across it marks a cut (`Editor.markCut`); tapping scrubs.
/// - Removed regions span both rows, hatched and dimmed. Tap selects (`Selection.cut`), Delete
///   restores, the edges resize (`Editor.resizeCut`). Zoom blocks draw above the hatch, so a zoom
///   inside a cut stays visible and editable even though it is inert.
/// - Trim handles sit at both ends of the strip at all times; dragging one inward creates or moves
///   the head or tail cut (`Editor.trim`).
/// - The playhead marker is drawn at `editor.playhead.recording`, so during playback it jumps
///   across each removed region, the way the viewer's time does.
/// - The transport label reads `output / outputDuration`.
struct TimelineStrip: View {
    let editor: Editor

    var body: some View { fatalError("not implemented") }
}

struct CutRegion: View {
    let editor: Editor
    let cut: Cut
    let scale: StripScale

    var body: some View { fatalError("not implemented") }
}

struct TrimHandle: View {
    let editor: Editor
    let end: Cuts.End
    let scale: StripScale

    var body: some View { fatalError("not implemented") }
}
