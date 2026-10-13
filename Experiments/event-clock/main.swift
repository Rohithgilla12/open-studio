import CoreGraphics
import Darwin
import Foundation

let marker: Int64 = 0x6F70656E
let count = Int(CommandLine.arguments.dropFirst().first ?? "200")!

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func ticksToNanos(_ t: UInt64) -> UInt64 { t * UInt64(timebase.numer) / UInt64(timebase.denom) }

struct Sample {
    var synthetic: Bool
    var timestamp: UInt64
    var machNow: UInt64
    var uptimeNanosNow: UInt64
    var postedAtMach: UInt64
}

final class State {
    var samples: [Sample] = []
    var postedAt: [Int64: UInt64] = [:]
}
let state = State()

let callback: CGEventTapCallBack = { _, type, event, _ in
    let machNow = mach_absolute_time()
    let uptimeNow = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    guard type == .mouseMoved else { return Unmanaged.passUnretained(event) }
    let tag = event.getIntegerValueField(.eventSourceUserData)
    let synthetic = tag >= marker
    state.samples.append(Sample(
        synthetic: synthetic, timestamp: event.timestamp, machNow: machNow,
        uptimeNanosNow: uptimeNow, postedAtMach: synthetic ? state.postedAt[tag] ?? 0 : 0))
    if state.samples.filter(\.synthetic).count >= count { CFRunLoopStop(CFRunLoopGetCurrent()) }
    return Unmanaged.passUnretained(event)
}

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
    eventsOfInterest: CGEventMask(1 << CGEventType.mouseMoved.rawValue),
    callback: callback, userInfo: nil)
else {
    print("tapCreate failed: Input Monitoring not granted to this process's responsible app")
    exit(1)
}
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

let source = CGEventSource(stateID: .hidSystemState)
let origin = CGEvent(source: nil)!.location
var n: Int64 = 0
let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
    n += 1
    let p = CGPoint(x: origin.x + Double(n % 40), y: origin.y + Double(n % 23))
    let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)!
    event.setIntegerValueField(.eventSourceUserData, value: marker + n)
    state.postedAt[marker + n] = mach_absolute_time()
    event.post(tap: .cghidEventTap)
}
RunLoop.current.add(timer, forMode: .common)
let deadline = DispatchTime.now() + 20
DispatchQueue.main.asyncAfter(deadline: deadline) { CFRunLoopStop(CFRunLoopGetMain()) }
CFRunLoopRun()

func stats(_ name: String, _ values: [Double]) -> String {
    guard !values.isEmpty else { return "\(name): none" }
    let s = values.sorted()
    let p = { (q: Double) in s[min(s.count - 1, Int(Double(s.count - 1) * q))] }
    return String(format: "%@: n=%d min=%.1f p50=%.1f p95=%.1f max=%.1f", name, s.count, s[0], p(0.5), p(0.95), s.last!)
}

print("timebase numer/denom = \(timebase.numer)/\(timebase.denom)")
for synthetic in [true, false] {
    let group = state.samples.filter { $0.synthetic == synthetic }
    print("\(synthetic ? "synthetic (posted)" : "hardware (real mouse)") events: \(group.count)")
    guard !group.isEmpty else { continue }
    let ex = group[group.count / 2]
    print("  example: timestamp=\(ex.timestamp) mach_absolute_time=\(ex.machNow) uptime_raw_ns=\(ex.uptimeNanosNow)")
    print("  " + stats("callback uptime_ns - timestamp, read as nanoseconds (us)",
        group.map { (Double($0.uptimeNanosNow) - Double($0.timestamp)) / 1000 }))
    print("  " + stats("callback mach_ticks - timestamp, read as ticks (us)",
        group.map { (Double(ticksToNanos($0.machNow)) - Double(ticksToNanos($0.timestamp))) / 1000 }))
    if synthetic {
        print("  " + stats("callback - post, mach (us)",
            group.map { Double(ticksToNanos($0.machNow - $0.postedAtMach)) / 1000 }))
    }
}
