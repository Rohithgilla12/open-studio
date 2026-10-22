import AppKit
import AVFoundation
import Render
import SwiftUI
import Timeline

struct EditorView: View {
    let model: StudioModel
    let editor: Editor
    @Environment(\.undoManager) private var undoManager
    @State private var exportOptionsShown = false

    var body: some View {
        VStack(spacing: 0) {
            PlayerSurface(layer: editor.preview.surface)
                .aspectRatio(canvasAspect, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            VStack(spacing: 10) {
                TransportBar(editor: editor)
                TimelineStrip(editor: editor)
                ZoomActions(editor: editor)
            }
            .padding(16)
        }
        .inspector(isPresented: .constant(true)) {
            StyleInspector(editor: editor)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        }
        .navigationTitle(editor.takeName)
        .navigationSubtitle(saveText)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Library", systemImage: "chevron.backward") { model.closeEditor() }
                    .help("Save and go back to the library")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Export…", systemImage: "square.and.arrow.up") { exportOptionsShown = true }
                    .help("Export an MP4")
            }
        }
        .sheet(isPresented: Binding(
            get: { exportOptionsShown || model.exportJob != nil },
            set: { shown in
                guard !shown else { return }
                exportOptionsShown = false
                Task { await model.dismissExport() }
            }
        )) {
            ExportSheet(model: model, editor: editor, isPresented: $exportOptionsShown)
        }
        .onAppear { editor.undoManager = undoManager }
        .onChange(of: undoManager) { editor.undoManager = undoManager }
    }

    private var canvasAspect: CGFloat {
        let canvas = editor.project.canvasSize(for: editor.project.edits.format)
        return CGFloat(canvas.width) / CGFloat(max(canvas.height, 1))
    }

    private var saveText: String {
        switch editor.saveState {
        case .saved: editor.hasSavedEdits ? "Saved" : "Automatic zooms, not edited yet"
        case .pending: "Editing…"
        case .failed(let detail): "Not saved: \(detail)"
        }
    }
}

struct PlayerSurface: NSViewRepresentable {
    let layer: CALayer

    func makeNSView(context: Context) -> PlayerLayerView { PlayerLayerView(layer: layer) }

    func updateNSView(_ view: PlayerLayerView, context: Context) {}
}

final class PlayerLayerView: NSView {
    let surface: CALayer

    init(layer: CALayer) {
        surface = layer
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    override func makeBackingLayer() -> CALayer { surface }
}

struct TransportBar: View {
    let editor: Editor

    var body: some View {
        HStack(spacing: 12) {
            Button(editor.isPlaying ? "Pause" : "Play", systemImage: editor.isPlaying ? "pause.fill" : "play.fill") {
                editor.togglePlayback()
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut(.space, modifiers: [])
            .frame(width: 28)
            Text("\(TimeText.text(editor.playhead.output)) / \(TimeText.text(editor.outputDuration))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

enum TimeText {
    static func text(_ t: RecordingTime) -> String { text(seconds: t.seconds) }
    static func text(_ t: OutputTime) -> String { text(seconds: t.seconds) }

    private static func text(seconds: Double) -> String {
        let tenths = Int((seconds * 10).rounded(.down))
        return String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }
}

struct ZoomActions: View {
    let editor: Editor

    var body: some View {
        HStack(spacing: 12) {
            Button("Add Zoom", systemImage: "plus.magnifyingglass") { editor.addZoom(at: editor.playhead.recording) }
                .disabled(!editor.canAddZoom(at: editor.playhead.recording))
                .help("Add a zoom centred on the playhead")
            Button(deleteTitle, systemImage: "trash") { editor.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(editor.selection == nil)
                .help("Delete the selected zoom, or restore the selected cut")
            Button("Trim Start", systemImage: "arrow.right.to.line") { editor.trimToPlayhead(.start) }
                .keyboardShortcut("[", modifiers: [])
                .help("Trim the start to the playhead ([)")
            Button("Trim End", systemImage: "arrow.left.to.line") { editor.trimToPlayhead(.end) }
                .keyboardShortcut("]", modifiers: [])
                .help("Trim the end to the playhead (])")
            Spacer()
            Button("Regenerate Zooms", systemImage: "wand.and.stars") { editor.regenerateZooms() }
                .help("Replace every zoom with automatic ones from the clicks")
        }
        .controlSize(.small)
    }

    private var deleteTitle: String {
        if case .cut = editor.selection { return "Restore Cut" }
        return "Delete Zoom"
    }
}

struct StyleInspector: View {
    let editor: Editor

    var body: some View {
        Form {
            Section("Background") {
                BackgroundSwatches(editor: editor)
            }
            Section("Frame") {
                EditSlider(
                    editor: editor, title: "Padding", range: 0...0.2, actionName: "Change Padding",
                    value: \.style.padding)
                EditSlider(
                    editor: editor, title: "Corners", range: 0...0.05, actionName: "Change Corner Radius",
                    value: \.style.cornerRadius)
                Toggle("Shadow", isOn: Binding(
                    get: { editor.project.edits.style.shadow.opacity > 0 },
                    set: { on in editor.apply("Change Shadow") { $0.style.shadow = on ? .soft : .none } }))
            }
            if editor.project.source.hasCamera {
                Section("Camera") {
                    CameraControls(editor: editor)
                }
            }
            let sources = AudioSource.recorded(in: editor.project.source)
            if !sources.isEmpty {
                Section("Audio") {
                    ForEach(sources, id: \.self) { source in
                        AudioLevelControls(editor: editor, source: source)
                    }
                }
            }
            Section("Zoom") {
                if case .zoom(let id)? = editor.selection, let segment = editor.zooms.first(where: { $0.id == id }) {
                    LabeledContent("Scale") {
                        Slider(
                            value: Binding(
                                get: { segment.scale },
                                set: { editor.setZoomScale(id, scale: $0) }),
                            in: 1.25...4
                        ) { editing in
                            if !editing { editor.endDrag() }
                        }
                    }
                    Text(String(format: "%.2fx from %@ to %@", segment.scale,
                                TimeText.text(segment.range.start), TimeText.text(segment.range.end)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Select a zoom in the strip.").foregroundStyle(.secondary)
                }
            }
            Section("Output") {
                FormatPicker(editor: editor)
            }
        }
        .formStyle(.grouped)
    }
}

struct CameraControls: View {
    let editor: Editor

    private var overlay: CameraOverlay { editor.project.edits.style.camera }

    var body: some View {
        Toggle("Show camera", isOn: binding(\.isVisible, "Show Camera"))
        Group {
            Picker("Corner", selection: binding(\.corner, "Move Camera")) {
                ForEach(CameraOverlay.Corner.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            EditSlider(
                editor: editor, title: "Size", range: CameraOverlay.sizeRange, actionName: "Resize Camera",
                value: \.style.camera.size)
            Picker("Shape", selection: binding(\.shape, "Change Camera Shape")) {
                ForEach(CameraOverlay.Shape.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Mirror", isOn: binding(\.mirrored, "Mirror Camera"))
        }
        .disabled(!overlay.isVisible)
    }

    private func binding<Value: Equatable>(_ key: WritableKeyPath<CameraOverlay, Value>, _ actionName: String) -> Binding<Value> {
        Binding(
            get: { overlay[keyPath: key] },
            set: { new in editor.apply(actionName) { $0.style.camera[keyPath: key] = new } })
    }
}

struct AudioLevelControls: View {
    let editor: Editor
    let source: AudioSource

    private var level: AudioLevel { editor.project.edits.audio[source] }

    var body: some View {
        LabeledContent(source.name) {
            HStack {
                Slider(
                    value: Binding(
                        get: { level.volume },
                        set: { new in editor.drag("Change \(source.name.capitalized) Level") { $0.audio[source].volume = new } }),
                    in: AudioLevel.volumeRange
                ) { editing in
                    if !editing { editor.endDrag() }
                }
                .disabled(level.isMuted)
                Toggle(isOn: Binding(
                    get: { level.isMuted },
                    set: { muted in editor.apply(muted ? "Mute \(source.name.capitalized)" : "Unmute \(source.name.capitalized)") { $0.audio[source].isMuted = muted } })
                ) {
                    Image(systemName: level.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .toggleStyle(.button)
                .help(level.isMuted ? "Unmute" : "Mute")
                .accessibilityLabel(Text(level.isMuted ? "Unmute \(source.name.lowercased())" : "Mute \(source.name.lowercased())"))
            }
        }
    }
}

extension CameraOverlay.Corner {
    var label: String {
        switch self {
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }
}

extension CameraOverlay.Shape {
    var label: String {
        switch self {
        case .circle: "Circle"
        case .roundedRectangle: "Rectangle"
        }
    }
}

struct EditSlider: View {
    let editor: Editor
    let title: String
    let range: ClosedRange<Double>
    let actionName: String
    let value: WritableKeyPath<Edits, Double>

    var body: some View {
        LabeledContent(title) {
            Slider(
                value: Binding(
                    get: { editor.project.edits[keyPath: value] },
                    set: { new in editor.drag(actionName) { $0[keyPath: value] = new } }),
                in: range
            ) { editing in
                if !editing { editor.endDrag() }
            }
        }
    }
}

struct BackgroundSwatches: View {
    let editor: Editor

    static let presets: [Background] = Render.Gradient.presets.map(Background.gradient) + [
        .solid(RGBColor(red: 0.11, green: 0.12, blue: 0.14)),
        .solid(RGBColor(red: 0.93, green: 0.93, blue: 0.91)),
        .solid(RGBColor(red: 0.20, green: 0.45, blue: 0.85)),
    ]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 10), count: 5), alignment: .leading, spacing: 10) {
            ForEach(Self.presets, id: \.self) { background in
                let selected = editor.project.edits.style.background == background
                Button {
                    editor.apply("Change Background") { $0.style.background = background }
                } label: {
                    Swatch(background: background)
                        .frame(width: 40, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 2.5 : 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(background.name))
            }
        }
        .padding(.vertical, 4)
    }
}

struct Swatch: View {
    let background: Background

    var body: some View {
        switch background {
        case .solid(let color):
            Rectangle().fill(color.swiftUI)
        case .gradient(let gradient):
            let radians = gradient.angle * .pi / 180
            let (dx, dy) = (cos(radians) / 2, sin(radians) / 2)
            LinearGradient(
                colors: [gradient.from.swiftUI, gradient.to.swiftUI],
                startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy), endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy))
        case .image:
            Rectangle().fill(.gray)
        }
    }
}

extension Render.RGBColor {
    var swiftUI: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}

extension Background {
    var name: String {
        switch self {
        case .gradient(let gradient):
            switch gradient {
            case .dusk: "Dusk gradient"
            case .mint: "Mint gradient"
            case .ember: "Ember gradient"
            default: "Gradient"
            }
        case .solid: "Solid colour"
        case .image(let asset): asset.fileName
        }
    }
}

struct FormatPicker: View {
    let editor: Editor

    var body: some View {
        Picker("Size", selection: binding(\.size, "Change Output Size")) {
            ForEach(CanvasPreset.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Picker("Frame rate", selection: binding(\.frameRate, "Change Frame Rate")) {
            ForEach(FrameRate.allCases, id: \.self) { Text("\($0.rawValue) fps").tag($0) }
        }
        Picker("Codec", selection: binding(\.codec, "Change Codec")) {
            ForEach(Codec.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        let canvas = editor.project.canvasSize(for: editor.project.edits.format)
        Text("\(canvas.width) × \(canvas.height)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func binding<Value: Equatable>(_ key: WritableKeyPath<OutputFormat, Value>, _ actionName: String) -> Binding<Value> {
        Binding(
            get: { editor.project.edits.format[keyPath: key] },
            set: { new in editor.apply(actionName) { $0.format[keyPath: key] = new } })
    }
}

extension CanvasPreset {
    var label: String {
        switch self {
        case .hd1080: "1080p"
        case .uhd2160: "4K"
        case .native: "Native"
        }
    }
}

extension Codec {
    var label: String {
        switch self {
        case .hevc: "HEVC"
        case .h264: "H.264"
        }
    }
}
