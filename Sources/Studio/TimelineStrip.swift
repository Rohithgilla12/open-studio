import AppKit
import SwiftUI
import Timeline

/// The strip is over recording time: `StripScale(width:duration:)` maps x over the whole
/// recording, so zooms never slide when you cut, and a removed region keeps a width you can tap
/// and restore.
///
///     ruler   |::::|      [drag here to cut]       |:::::::|               |:::|
///     zooms   |::::|  [ 2.0x ]    [ 2.0x ]         |:[2.0x]|  [ 2.0x  ]   |:::|
///             ^trim                                 ^ cut (hatched)        trim^
///             handle                                                        handle
///
/// - Ruler row: dragging across it marks a cut; tapping scrubs.
/// - Removed regions span both rows, hatched and dimmed. Tap selects, Delete restores, the edges
///   resize. Zoom blocks draw above the hatch, so a zoom inside a cut stays visible and editable
///   even though it is inert.
/// - Trim handles sit at the take's trimmed start and end at all times; dragging one inward
///   creates or moves the head or tail cut.
/// - The playhead marker is drawn at `editor.playhead.recording`, so during playback it jumps
///   across each removed region, the way the viewer's time does.
struct TimelineStrip: View {
    let editor: Editor
    static let rulerHeight: CGFloat = 16
    static let zoomsHeight: CGFloat = 56
    static let height = rulerHeight + zoomsHeight
    static let space = "timeline-strip"

    var body: some View {
        GeometryReader { geometry in
            let scale = StripScale(width: geometry.size.width, duration: editor.duration)
            ZStack(alignment: .topLeading) {
                Ruler(editor: editor, scale: scale)
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: Self.zoomsHeight)
                    .offset(y: Self.rulerHeight)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                editor.selection = nil
                                editor.scrub(to: scale.time(atX: drag.location.x))
                            })
                    .accessibilityLabel(Text("Zoom strip"))
                ForEach(editor.cuts) { cut in
                    CutRegion(editor: editor, cut: cut, scale: scale)
                }
                ForEach(editor.zooms) { segment in
                    ZoomBlock(editor: editor, segment: segment, scale: scale)
                }
                TrimHandle(editor: editor, end: .start, scale: scale)
                TrimHandle(editor: editor, end: .end, scale: scale)
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: Self.height + 8)
                    .offset(x: scale.x(at: editor.playhead.recording) - 1, y: -4)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(.named(Self.space))
        }
        .frame(height: Self.height)
    }
}

/// The row above the zooms. A drag marks a cut from where it started to the pointer; a tap scrubs.
struct Ruler: View {
    let editor: Editor
    let scale: StripScale
    @GestureState private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: TimelineStrip.rulerHeight - 2)
            .contentShape(Rectangle())
            .onTapGesture { location in editor.scrub(to: scale.time(atX: location.x)) }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(TimelineStrip.space))
                    .updating($isDragging) { _, dragging, _ in dragging = true }
                    .onChanged { drag in
                        editor.markCut(from: scale.time(atX: drag.startLocation.x), to: scale.time(atX: drag.location.x))
                    })
            .onChange(of: isDragging) { _, dragging in
                if !dragging { editor.endDrag() }
            }
            .pointerStyle(.horizontalText)
            .help("Drag to cut")
            .accessibilityLabel(Text("Cut ruler"))
    }
}

/// A removed range, hatched over both rows. Its inner edges resize it; an edge on the recording's
/// start or end is the trim handle's job.
struct CutRegion: View {
    let editor: Editor
    let cut: Cut
    let scale: StripScale
    @State private var dragOrigin: RecordingTime?
    @GestureState private var isDragging = false

    var body: some View {
        let x = scale.x(at: cut.range.start)
        let width = max(scale.x(at: cut.range.end) - x, 2)
        let selected = editor.selection == .cut(cut.id)
        Hatch()
            .fill(Color.primary.opacity(0.35))
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.55))
            .overlay(Rectangle().strokeBorder(selected ? Color.primary.opacity(0.8) : Color.primary.opacity(0.25), lineWidth: selected ? 2 : 1))
            .overlay(alignment: .leading) { if cut.range.start > .zero { handle(.start) } }
            .overlay(alignment: .trailing) { if cut.range.end < editor.duration { handle(.end) } }
            .frame(width: width, height: TimelineStrip.height)
            .offset(x: x)
            .onTapGesture { editor.selection = .cut(cut.id) }
            .onChange(of: isDragging) { _, dragging in
                guard !dragging else { return }
                dragOrigin = nil
                editor.endDrag()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Cut"))
            .accessibilityValue(Text("\(TimeText.text(cut.range.start)) to \(TimeText.text(cut.range.end))"))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func handle(_ edge: Cuts.End) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: ZoomBlock.handleWidth)
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(TimelineStrip.space))
                    .updating($isDragging) { _, dragging, _ in dragging = true }
                    .onChanged { drag in
                        let current = edge == .start ? cut.range.start : cut.range.end
                        let origin = dragOrigin ?? current
                        dragOrigin = origin
                        editor.selection = .cut(cut.id)
                        editor.resizeCut(cut.id, edge: edge, to: scale.time(atX: scale.x(at: origin) + drag.translation.width))
                    })
    }
}

/// Diagonal lines every 8 points.
struct Hatch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step: CGFloat = 8
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            path.addLine(to: CGPoint(x: x + rect.height + 1.5, y: rect.minY))
            path.addLine(to: CGPoint(x: x + 1.5, y: rect.maxY))
            path.closeSubpath()
            x += step
        }
        return path.intersection(Path(rect))
    }
}

/// Sits at the take's trimmed start or end. Dragging it inward creates or moves the head or tail cut.
struct TrimHandle: View {
    let editor: Editor
    let end: Cuts.End
    let scale: StripScale
    @State private var dragOrigin: RecordingTime?
    @GestureState private var isDragging = false

    static let width: CGFloat = 8

    var body: some View {
        let bound = end == .start ? editor.trimmed.lowerBound : editor.trimmed.upperBound
        let x = scale.x(at: bound)
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.primary.opacity(0.7))
            .frame(width: Self.width, height: TimelineStrip.height)
            .offset(x: end == .start ? x - Self.width : x)
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(TimelineStrip.space))
                    .updating($isDragging) { _, dragging, _ in dragging = true }
                    .onChanged { drag in
                        let origin = dragOrigin ?? bound
                        dragOrigin = origin
                        editor.trim(end, to: scale.time(atX: scale.x(at: origin) + drag.translation.width))
                    })
            .onChange(of: isDragging) { _, dragging in
                guard !dragging else { return }
                dragOrigin = nil
                editor.endDrag()
            }
            .help(end == .start ? "Drag to trim the start" : "Drag to trim the end")
            .accessibilityLabel(Text(end == .start ? "Trim start" : "Trim end"))
            .accessibilityValue(Text(TimeText.text(bound)))
    }
}

struct ZoomBlock: View {
    let editor: Editor
    let segment: ZoomSegment
    let scale: StripScale
    @State private var dragOrigin: RecordingTime?
    @GestureState private var isDragging = false

    static let handleWidth: CGFloat = 8

    var body: some View {
        let x = scale.x(at: segment.range.start)
        let width = max(scale.x(at: segment.range.end) - x, 2)
        let selected = editor.selection == .zoom(segment.id)
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor.opacity(selected ? 0.85 : 0.45))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? Color.primary.opacity(0.8) : Color.accentColor, lineWidth: selected ? 2 : 1))
            .overlay {
                Text(String(format: "%.1fx", segment.scale))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, Self.handleWidth)
                    .opacity(width > 44 ? 1 : 0)
            }
            .overlay(alignment: .leading) { handle(.start) }
            .overlay(alignment: .trailing) { handle(.end) }
            .frame(width: width, height: TimelineStrip.zoomsHeight - 8)
            .offset(x: x, y: TimelineStrip.rulerHeight + 4)
            .onTapGesture { editor.selection = .zoom(segment.id) }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(TimelineStrip.space))
                    .updating($isDragging) { _, dragging, _ in dragging = true }
                    .onChanged { drag in
                        let origin = dragOrigin ?? segment.range.start
                        dragOrigin = origin
                        editor.selection = .zoom(segment.id)
                        editor.moveZoom(segment.id, toStart: scale.time(atX: scale.x(at: origin) + drag.translation.width))
                    })
            .onChange(of: isDragging) { _, dragging in
                guard !dragging else { return }
                dragOrigin = nil
                editor.endDrag()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Zoom \(String(format: "%.1fx", segment.scale))"))
            .accessibilityValue(Text("\(TimeText.text(segment.range.start)) to \(TimeText.text(segment.range.end))"))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func handle(_ edge: ZoomTrack.Edge) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: Self.handleWidth)
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(TimelineStrip.space))
                    .updating($isDragging) { _, dragging, _ in dragging = true }
                    .onChanged { drag in
                        let current = edge == .start ? segment.range.start : segment.range.end
                        let origin = dragOrigin ?? current
                        dragOrigin = origin
                        editor.selection = .zoom(segment.id)
                        editor.resizeZoom(segment.id, edge: edge, to: scale.time(atX: scale.x(at: origin) + drag.translation.width))
                    })
    }
}

struct StripScale: Equatable {
    let width: Double
    let duration: RecordingTime

    func time(atX x: Double) -> RecordingTime {
        guard width > 0, duration > .zero else { return .zero }
        let fraction = min(max(x / width, 0), 1)
        return RecordingTime(microseconds: Int64((fraction * Double(duration.microseconds)).rounded()))
    }

    func x(at t: RecordingTime) -> Double {
        guard duration > .zero else { return 0 }
        return Double(t.microseconds) / Double(duration.microseconds) * width
    }
}
