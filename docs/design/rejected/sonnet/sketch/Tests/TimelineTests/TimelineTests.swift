import Testing
import RecordingFormat
@testable import Timeline

/// Test list the implementation must satisfy. Bodies are intentionally empty.
@Suite struct TimelineContract {
    @Test func autoZoomMergesWindowsWithinGap() {}
    @Test func autoZoomIgnoresClicksInLastSecond() {}
    @Test func autoZoomWindowEndsClampToDurationMinusInset() {}

    @Test func focusGroupClosesWhenBoxExceedsHalfViewport() {}
    @Test func shakeFilterDropsOutAndBackJumpOverThreshold() {}

    @Test func springMatchesFineGrainedReferenceIntegrator() {}
    @Test func springClosedFormCoversUnderCriticalOverDamped() {}

    @Test func cameraIsIdenticalForShuffledQueryOrder() {}
    @Test func cameraIsIdenticalAcrossConcurrentQueries() async {}
    @Test func cameraNeverShowsOutsideFrame() {}

    @Test func cursorFadesAfterThreeKeysWithin1800ms() {}
    @Test func cursorShowsPressedBetweenDownAndUp() {}
    @Test func cursorFallsBackToArrowForUnknownImage() {}
}

@Suite struct RecordingReaderContract {
    @Test func tornFinalLineIsDroppedWithDiagnostic() {}
    @Test func unknownLineKindIsSkipped() {}
    @Test func crashedDirectoryThrowsNeedsRecovery() {}
    @Test func newerMajorVersionIsRejected() {}
    @Test func strayButtonUpIsDropped() {}
}
