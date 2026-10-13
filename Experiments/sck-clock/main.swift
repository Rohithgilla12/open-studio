import CoreMedia
import Darwin
import Foundation
import ScreenCaptureKit

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)

// `lines` is written only on the sample handler queue and read only after `done` signals.
final class Output: NSObject, SCStreamOutput, @unchecked Sendable {
    var lines: [String] = []
    let done = DispatchSemaphore(value: 0)

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let uptimeNow = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        let attachments = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
        let status = (attachments?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:))
        let displayTicks = attachments?[.displayTime] as? UInt64 ?? 0
        let displayNanos = displayTicks * UInt64(timebase.numer) / UInt64(timebase.denom)
        let ptsNanos = Double(pts.value) * 1e9 / Double(pts.timescale)
        lines.append(String(
            format: "status=%@ pts.timescale=%d arrival-pts=%.1fus hostclock-pts=%.1fus displayTime(ticks->ns)-pts=%.1fus",
            status == .complete ? "complete" : "\(status.map { "\($0.rawValue)" } ?? "?")",
            pts.timescale,
            (Double(uptimeNow) - ptsNanos) / 1000,
            (hostNow.seconds * 1e9 - ptsNanos) / 1000,
            (Double(displayNanos) - ptsNanos) / 1000))
        if lines.count == 12 { done.signal() }
    }
}

let content = try await SCShareableContent.current
let display = content.displays.first!
let config = SCStreamConfiguration()
config.width = 640
config.height = 400
config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
config.showsCursor = true
let output = Output()
let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "sck"))
try await stream.startCapture()
_ = output.done.wait(timeout: .now() + 10)
try await stream.stopCapture()
print("timebase \(timebase.numer)/\(timebase.denom)")
output.lines.forEach { print($0) }
