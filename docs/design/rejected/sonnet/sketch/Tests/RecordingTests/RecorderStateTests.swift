import Testing
@testable import Recording

/// The reducer is pure, so each of these runs without a display or permissions.
@Suite struct RecorderStateContract {
    @Test func stopTwiceProducesNoSecondEffect() {}
    @Test func lostTapDegradesButKeepsRecording() {}
    @Test func lostStreamEndsTakeWithSalvage() {}
    @Test func secondFirstFrameDoesNotMoveOrigin() {}
    @Test func finalisedIgnoredOutsideStopping() {}
    @Test func lateCallbackAfterFinishedIsNoOp() {}
}
