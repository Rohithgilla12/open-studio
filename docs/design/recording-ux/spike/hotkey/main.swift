// Can an AppKit process register Carbon global hot keys with no permission, what does a clash
// return, and are the times a hot key event carries on the recorder's clock (CLOCK_UPTIME_RAW)?
// Opens no window: the process runs as an accessory app for about a second.
//
//   swiftc -O main.swift -o /tmp/hotkey && /tmp/hotkey
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin

func uptimeRawSeconds() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

print("permissions: listen \(CGPreflightListenEventAccess()), post \(CGPreflightPostEventAccess()), accessibility \(AXIsProcessTrusted())")

var fired: [(id: UInt32, eventTime: Double, uptimeRaw: Double)] = []
var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
    var id = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                      MemoryLayout<EventHotKeyID>.size, nil, &id)
    fired.append((id.id, GetEventTime(event), uptimeRawSeconds()))
    return noErr
}, 1, &spec, nil, nil)
print("InstallEventHandler: \(handlerStatus)")

let signature = OSType(0x6F_73_74_64)
func register(_ keyCode: Int, _ modifiers: Int, id: UInt32, _ label: String) -> EventHotKeyRef? {
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: signature, id: id),
                                     GetApplicationEventTarget(), 0, &ref)
    print("RegisterEventHotKey \(label): \(status)")
    return status == noErr ? ref : nil
}

let hyper = controlKey | optionKey | cmdKey
let record = register(kVK_ANSI_R, hyper, id: 1, "ctrl-opt-cmd-R")
let pause = register(kVK_ANSI_P, hyper, id: 2, "ctrl-opt-cmd-P")
let clash = register(kVK_ANSI_R, hyper, id: 3, "ctrl-opt-cmd-R again (clash)")
let escape = register(kVK_Escape, 0, id: 4, "Escape, no modifiers")
let screenshot = register(kVK_ANSI_3, cmdKey | shiftKey, id: 5, "cmd-shift-3 (system screenshot)")

print(String(format: "clocks: GetCurrentEventTime %.6f, ProcessInfo.systemUptime %.6f, CLOCK_UPTIME_RAW %.6f, CLOCK_MONOTONIC_RAW %.6f",
             GetCurrentEventTime(), ProcessInfo.processInfo.systemUptime, uptimeRawSeconds(),
             Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9))
let suspending = SuspendingClock.now
let continuous = ContinuousClock.now
print("SuspendingClock.now \(suspending), ContinuousClock.now \(continuous)")

if CGPreflightPostEventAccess() {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_P), keyDown: down)
        event?.flags = [.maskControl, .maskAlternate, .maskCommand]
        event?.post(tap: .cghidEventTap)
    }
} else {
    print("cannot post a synthetic key press without Post Event access; firing is not measured")
}

DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
    for f in fired {
        print(String(format: "fired id %u: event time %.6f, CLOCK_UPTIME_RAW in handler %.6f, lag %.3f ms", f.id, f.eventTime, f.uptimeRaw, (f.uptimeRaw - f.eventTime) * 1000))
    }
    if fired.isEmpty { print("no hot key fired") }
    for ref in [record, pause, clash, escape, screenshot] { if let ref { UnregisterEventHotKey(ref) } }
    exit(0)
}
app.run()
