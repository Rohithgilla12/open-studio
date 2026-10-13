import Testing
@testable import RecordingFormat

@Suite struct FormatContract {
    @Test func manifestRoundTripsAndIgnoresUnknownKeys() {}
    @Test func inputRecordEncodesToOneNewlineTerminatedLine() {}
    @Test func recordingTimeFromCMTimeShapeIsExact() {}
}
