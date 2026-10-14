import Timeline

/// Decoded cursor bitmaps for one take: premultiplied RGBA8 in the display colour space, immutable.
///
/// Memoises a pure function of file contents (the recorder content-addresses cursor PNGs and never
/// rewrites them), so holding it in the plan does not break "no state between frames". The GPU upload
/// is cached by the renderer, keyed by `CursorSprites.identity` plus id.
struct CursorSprites: Sendable {
    struct Sprite: Sendable { let width: Int; let height: Int; let premultipliedRGBA: [UInt8] }

    let identity: UUID      // SourceRecording.id; stable across plans of the same take
    let images: [CursorImageID: Sprite]

    /// Reads and decodes every declared image. Also builds the fallback arrow in code (vector path
    /// rasterised at 4x), used when a take references an undeclared id.
    static func load(for source: SourceRecording) throws(RenderError) -> CursorSprites { fatalError("not implemented") }
}
