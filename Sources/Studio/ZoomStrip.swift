import AppKit
import SwiftUI
import Timeline

struct ZoomStrip: View {
    let editor: Editor
    static let height: CGFloat = 56

    var body: some View {
        GeometryReader { geometry in
            let scale = StripScale(width: geometry.size.width, duration: editor.duration)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.06))
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                editor.selection = nil
                                editor.scrub(to: scale.time(atX: drag.location.x))
                            })
                    .accessibilityLabel(Text("Zoom strip"))
                ForEach(editor.zooms) { segment in
                    ZoomBlock(editor: editor, segment: segment, scale: scale)
                }
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: Self.height + 8)
                    .offset(x: scale.x(at: editor.playhead) - 1, y: -4)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(.named(ZoomBlock.space))
        }
        .frame(height: Self.height)
    }
}

struct ZoomBlock: View {
    let editor: Editor
    let segment: ZoomSegment
    let scale: StripScale
    @State private var dragOrigin: RecordingTime?
    @GestureState private var isDragging = false

    static let space = "zoom-strip"
    static let handleWidth: CGFloat = 8

    var body: some View {
        let x = scale.x(at: segment.range.start)
        let width = max(scale.x(at: segment.range.end) - x, 2)
        let selected = editor.selection == segment.id
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
            .frame(width: width, height: ZoomStrip.height - 8)
            .offset(x: x, y: 4)
            .onTapGesture { editor.selection = segment.id }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
                    .updating($isDragging) { _, dragging, _ in dragging = true }
                    .onChanged { drag in
                        let origin = dragOrigin ?? segment.range.start
                        dragOrigin = origin
                        editor.selection = segment.id
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
                DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                    .updating($isDragging) { _, dragging, _ in dragging = true }
                    .onChanged { drag in
                        let current = edge == .start ? segment.range.start : segment.range.end
                        let origin = dragOrigin ?? current
                        dragOrigin = origin
                        editor.selection = segment.id
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
