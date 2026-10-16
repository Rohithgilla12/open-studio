import AppKit
import Recording

public enum AreaSelection: Sendable, Equatable {
    /// Display points, origin top-left of the display.
    case selected(CGRect)
    case cancelled
    case displayUnavailable
}

/// AppKit places every screen in one space, origin bottom-left of the main display, y up. A capture
/// area is in points of one display, origin top-left of that display, y down.
enum DisplaySpace {
    static func displayPoint(fromScreen point: CGPoint, screenFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x - screenFrame.minX, y: screenFrame.maxY - point.y)
    }

    static func screenRect(fromDisplay rect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(x: screenFrame.minX + rect.minX, y: screenFrame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

struct AreaEditor {
    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        enum Edge {
            case min, mid, max

            func pick(_ min: CGFloat, _ mid: CGFloat, _ max: CGFloat) -> CGFloat {
                switch self {
                case .min: min
                case .mid: mid
                case .max: max
                }
            }
        }

        var edges: (x: Edge, y: Edge) {
            switch self {
            case .topLeft: (.min, .min)
            case .top: (.mid, .min)
            case .topRight: (.max, .min)
            case .right: (.max, .mid)
            case .bottomRight: (.max, .max)
            case .bottom: (.mid, .max)
            case .bottomLeft: (.min, .max)
            case .left: (.min, .mid)
            }
        }

        func point(on rect: CGRect) -> CGPoint {
            let (x, y) = edges
            return CGPoint(x: x.pick(rect.minX, rect.midX, rect.maxX), y: y.pick(rect.minY, rect.midY, rect.maxY))
        }
    }

    private enum Gesture {
        case drawing(from: CGPoint, previous: CGRect?)
        case moving(from: CGPoint, original: CGRect)
        case resizing(Handle, original: CGRect)
    }

    static let handleReach: CGFloat = 8
    static let smallestDrawn: CGFloat = 4

    let displaySize: CGSize
    private(set) var selection: CGRect?
    private var gesture: Gesture?

    init(displaySize: CGSize, preset: CGRect?) {
        self.displaySize = displaySize
        let clipped = preset?.standardized.intersection(CGRect(origin: .zero, size: displaySize))
        selection = clipped.flatMap { $0.isNull || $0.isEmpty ? nil : $0 }
    }

    func handle(at point: CGPoint) -> Handle? {
        guard let selection else { return nil }
        return Handle.allCases.first { handle in
            let corner = handle.point(on: selection)
            return abs(corner.x - point.x) <= Self.handleReach && abs(corner.y - point.y) <= Self.handleReach
        }
    }

    mutating func begin(at point: CGPoint) {
        let point = clamped(point)
        if let selection, let handle = handle(at: point) {
            gesture = .resizing(handle, original: selection)
        } else if let selection, selection.contains(point) {
            gesture = .moving(from: point, original: selection)
        } else {
            gesture = .drawing(from: point, previous: selection)
        }
    }

    mutating func drag(to point: CGPoint) {
        let point = clamped(point)
        switch gesture {
        case nil:
            return
        case .drawing(let from, _):
            selection = CGRect(corner: from, opposite: point)
        case .moving(let from, let original):
            let x = min(max(original.minX + point.x - from.x, 0), displaySize.width - original.width)
            let y = min(max(original.minY + point.y - from.y, 0), displaySize.height - original.height)
            selection = CGRect(origin: CGPoint(x: x, y: y), size: original.size)
        case .resizing(let handle, let original):
            var near = CGPoint(x: original.minX, y: original.minY)
            var far = CGPoint(x: original.maxX, y: original.maxY)
            let edges = handle.edges
            switch edges.x {
            case .min: near.x = point.x
            case .max: far.x = point.x
            case .mid: break
            }
            switch edges.y {
            case .min: near.y = point.y
            case .max: far.y = point.y
            case .mid: break
            }
            selection = CGRect(corner: near, opposite: far)
        }
    }

    mutating func end() {
        if case .drawing(_, let previous) = gesture, let drawn = selection,
            drawn.width < Self.smallestDrawn || drawn.height < Self.smallestDrawn
        {
            selection = previous
        }
        gesture = nil
    }

    func pixelSize(scale: CGFloat) -> CGSize? {
        selection.map { Self.pixelSize(of: $0, scale: scale) }
    }

    func isLargeEnough(scale: CGFloat) -> Bool {
        pixelSize(scale: scale).map(Self.isLargeEnough) ?? false
    }

    static func pixelSize(of area: CGRect, scale: CGFloat) -> CGSize {
        CGSize(width: (area.width * scale + 1e-6).rounded(.down), height: (area.height * scale + 1e-6).rounded(.down))
    }

    static func isLargeEnough(_ pixels: CGSize) -> Bool {
        let minimum = CGFloat(CaptureTarget.minimumAreaPixels)
        return pixels.width >= minimum && pixels.height >= minimum
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), displaySize.width), y: min(max(point.y, 0), displaySize.height))
    }
}

struct PixelSize: CustomStringConvertible {
    let pixels: CGSize

    var description: String { "\(Int(pixels.width)) × \(Int(pixels.height)) px" }
}

extension PixelSize {
    @MainActor
    init(of rect: CGRect, on screen: NSScreen) {
        pixels = AreaEditor.pixelSize(of: rect, scale: screen.backingScaleFactor)
    }
}

extension CGRect {
    init(corner: CGPoint, opposite: CGPoint) {
        self.init(x: min(corner.x, opposite.x), y: min(corner.y, opposite.y), width: abs(opposite.x - corner.x), height: abs(opposite.y - corner.y))
    }
}

@MainActor
enum AreaOverlay {
    private static var current: OverlayWindow?

    static func select(on display: DisplaySelection, preset: CGRect?) async -> AreaSelection {
        guard current == nil else { return .cancelled }
        guard let screen = NSScreen.showing(display) else { return .displayUnavailable }
        let chosen: CGRect? = await withCheckedContinuation { continuation in
            let window = OverlayWindow(screen: screen, preset: preset) { continuation.resume(returning: $0) }
            current = window
            NSApplication.shared.activate()
            window.makeKeyAndOrderFront(nil)
        }
        current = nil
        guard let chosen else { return .cancelled }
        // The overlay has been ordered out; give the window server a refresh to take it off screen
        // before the first frame is captured.
        try? await Task.sleep(for: .milliseconds(100))
        return .selected(chosen)
    }
}

private final class OverlayWindow: NSWindow {
    private var finish: ((CGRect?) -> Void)?

    init(screen: NSScreen, preset: CGRect?, finish: @escaping (CGRect?) -> Void) {
        self.finish = finish
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        contentView = AreaSelectionView(
            editor: AreaEditor(displaySize: screen.frame.size, preset: preset),
            screenFrame: screen.frame, scale: screen.backingScaleFactor,
            done: { [weak self] in self?.close(with: $0) })
    }

    override var canBecomeKey: Bool { true }

    private func close(with area: CGRect?) {
        guard let finish else { return }
        self.finish = nil
        orderOut(nil)
        finish(area)
    }
}

private final class AreaSelectionView: NSView {
    private var editor: AreaEditor
    private let screenFrame: CGRect
    private let scale: CGFloat
    private let done: (CGRect?) -> Void

    private let bar = NSVisualEffectView()
    private let sizeLabel = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let recordButton = NSButton(title: "Record", target: nil, action: nil)

    init(editor: AreaEditor, screenFrame: CGRect, scale: CGFloat, done: @escaping (CGRect?) -> Void) {
        self.editor = editor
        self.screenFrame = screenFrame
        self.scale = scale
        self.done = done
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))

        sizeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        hint.textColor = .secondaryLabelColor
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        recordButton.target = self
        recordButton.action = #selector(confirm)
        recordButton.keyEquivalent = "\r"

        let stack = NSStackView(views: [sizeLabel, hint, cancelButton, recordButton])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.material = .hudWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 10
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        addSubview(bar)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        changed()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        editor.begin(at: displayPoint(of: event))
        changed()
    }

    override func mouseDragged(with event: NSEvent) {
        editor.drag(to: displayPoint(of: event))
        changed()
    }

    override func mouseUp(with event: NSEvent) {
        editor.drag(to: displayPoint(of: event))
        editor.end()
        changed()
    }

    override func mouseMoved(with event: NSEvent) {
        cursor(at: displayPoint(of: event)).set()
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        let selection = editor.selection.map(viewRect)
        if let selection {
            dim.append(NSBezierPath(rect: selection))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()
        guard let selection, let area = editor.selection else { return }
        let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        NSColor.white.setStroke()
        border.stroke()
        for handle in AreaEditor.Handle.allCases {
            let centre = viewRect(CGRect(origin: handle.point(on: area), size: .zero)).origin
            let knob = NSBezierPath(ovalIn: CGRect(x: centre.x - 4, y: centre.y - 4, width: 8, height: 8))
            NSColor.white.setFill()
            knob.fill()
            NSColor.black.withAlphaComponent(0.5).setStroke()
            knob.lineWidth = 0.5
            knob.stroke()
        }
    }

    override func layout() {
        super.layout()
        let size = bar.fittingSize
        let margin: CGFloat = 12
        let origin: CGPoint
        if let selection = editor.selection.map(viewRect) {
            let x = min(max(selection.midX - size.width / 2, margin), bounds.width - size.width - margin)
            let below = selection.minY - margin - size.height
            let above = selection.maxY + margin
            let y = below >= margin ? below : above + size.height <= bounds.height - margin ? above : selection.minY + margin
            origin = CGPoint(x: x, y: y)
        } else {
            origin = CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        }
        bar.frame = CGRect(origin: origin, size: size)
    }

    @objc private func confirm() {
        guard let area = editor.selection, editor.isLargeEnough(scale: scale) else { return }
        done(area)
    }

    @objc private func cancel() {
        done(nil)
    }

    private func changed() {
        let minimum = CaptureTarget.minimumAreaPixels
        if let pixels = editor.pixelSize(scale: scale) {
            sizeLabel.stringValue = PixelSize(pixels: pixels).description
            sizeLabel.isHidden = false
            hint.stringValue = "At least \(minimum) × \(minimum) pixels"
            hint.isHidden = AreaEditor.isLargeEnough(pixels)
        } else {
            sizeLabel.isHidden = true
            hint.stringValue = "Drag to choose the area to record"
            hint.isHidden = false
        }
        recordButton.isEnabled = editor.isLargeEnough(scale: scale)
        needsDisplay = true
        needsLayout = true
    }

    private func cursor(at point: CGPoint) -> NSCursor {
        if let handle = editor.handle(at: point) {
            return .frameResize(position: handle.cursorPosition, directions: .all)
        }
        return editor.selection?.contains(point) == true ? .openHand : .crosshair
    }

    private func displayPoint(of event: NSEvent) -> CGPoint {
        let onScreen = window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        return DisplaySpace.displayPoint(fromScreen: onScreen, screenFrame: screenFrame)
    }

    private func viewRect(_ area: CGRect) -> CGRect {
        let onScreen = DisplaySpace.screenRect(fromDisplay: area, screenFrame: screenFrame)
        guard let window else { return onScreen }
        return convert(window.convertFromScreen(onScreen), from: nil)
    }
}

extension AreaEditor.Handle {
    fileprivate var cursorPosition: NSCursor.FrameResizePosition {
        switch self {
        case .topLeft: .topLeft
        case .top: .top
        case .topRight: .topRight
        case .right: .right
        case .bottomRight: .bottomRight
        case .bottom: .bottom
        case .bottomLeft: .bottomLeft
        case .left: .left
        }
    }
}
