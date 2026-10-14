/// The shader is a Swift string compiled with `MTLDevice.makeLibrary(source:)` at first use, not a
/// `.metal` file. Reasons, in order: `swift build` and `swift test` need no Metal toolchain (on Xcode 26
/// and later it is a separate download), the SwiftPM resource bundle is not involved so the app and
/// `osrec` find it identically, and the shader is about 70 lines. Measured cost: 298 ms cold, 0.1 ms warm
/// (the system caches the compiled result). Revisit if the shader passes about 300 lines.
///
/// The working spike version is `docs/design/candidate/spike/ThroughputSpike.swift`.
enum Shaders {
    static let source = """
    // TODO port from the spike: vs (fullscreen triangle), fs (background, shadow, screen, cursor, dither),
    // BT.709 video-range decode of the two source planes, Catmull-Rom resample when the screen is
    // upscaled (camera zoom on a 4K canvas), bilinear when it is downscaled.
    """
}

/// Plain-old-data mirror of the shader's uniform block. Field order and padding are asserted equal to
/// the MSL struct by a test that compares `MemoryLayout<ShaderUniforms>` and offsets with
/// `MTLArgumentEncoder` reflection, so the two cannot drift silently.
struct ShaderUniforms {
    // TODO fields as in the spike's `U`
}
