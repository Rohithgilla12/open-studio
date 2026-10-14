public import Foundation
public import Render
public import Timeline

/// Everything the user can change about a take, in one Codable value. The single source of truth for
/// "what the video looks like"; a `RenderPlan` and a `Timeline` are derived from it, never the reverse.
public struct EditState: Sendable, Hashable, Codable {
    public var zooms: ZoomTrack
    public var timeline: TimelineSettings
    public var style: Style
    public var output: OutputChoice

    /// What `AutoZoom` would give: the state of a take nobody has edited. Deterministic (stable ids),
    /// so computing it twice, or on two machines, gives equal values and no file is needed until the
    /// first real edit.
    public static func initial(for source: SourceRecording) -> EditState { fatalError("not implemented") }
}

/// A preset by name, resolved against the source when a plan is built (`native` depends on style and source).
public enum OutputChoice: String, Sendable, Hashable, Codable, CaseIterable {
    case p1080at30, p1080at60, native60, uhd4kAt60
    public func spec(for source: SourceRecording, style: Style) -> OutputSpec { fatalError("not implemented") }
}
