import Testing
import Timeline
@testable import Render

// Pure geometry: exact numbers, no GPU.
@Suite struct GeometryTests {
    @Test func contentRectFitsPaddedCanvasAndKeepsAspect() {
        // 3456x2234 source into 1920x1080 at 6% padding: padding = 64.8 px; fit = min(1790.4/3456, 950.4/2234)
        fatalError("not implemented")
    }

    @Test func viewportAtScaleOneMapsSourceCornersToContentCorners() { fatalError("not implemented") }

    @Test func viewportAtScaleTwoDoublesTheMappedCursorSize() { fatalError("not implemented") }

    @Test func pressAmountShrinksCursorAboutTheHotspot() { fatalError("not implemented") }

    @Test func flipIsAnInvolution() { fatalError("not implemented") }

    @Test func frameTimeBridgeRoundTripsSixtyFpsTicks() { fatalError("not implemented") }
}

// Document reducer: pure, no I/O.
@Suite struct EditDocumentTests {
    @Test func deleteThenMoveNeighbourIntoFreedSpaceIsValid() { fatalError("not implemented") }
    @Test func moveClampsToNeighbourEdges() { fatalError("not implemented") }
    @Test func resizeToEmptyRangeThrows() { fatalError("not implemented") }
    @Test func editFileRoundTripIsByteStable() { fatalError("not implemented") }
    @Test func editFileRefusesNewerVersion() { fatalError("not implemented") }
}

// GPU pixel test: cheap because it renders one small frame from a synthetic source buffer.
@Suite struct PixelTests {
    /// A 64x64 flat-red source at scale 1 with zero padding and no shadow renders red at the
    /// centre and the background colour at the corner (outside the corner radius).
    @Test func flatSourceLandsInContentRect() { fatalError("not implemented") }

    /// The same (source, frame, plan) drawn twice gives identical bytes.
    @Test func drawIsDeterministic() { fatalError("not implemented") }
}
