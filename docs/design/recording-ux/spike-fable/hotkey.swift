// Throwaway. Does Carbon `RegisterEventHotKey` work from an accessory (never frontmost) app
// process without a permission prompt, and does its handler run while another app is frontmost?
//
//   swiftc -O -swift-version 5 docs/design/recording-ux/candidate/spike/hotkey.swift -o $SCRATCH/hotkey
//   $SCRATCH/hotkey            # then press ⌃⌥⌘R and ⌃⌥⌘P in any app within eight seconds
//
// Registers the two chords and reports the registration status, the frontmost app before and
// after registering (a prompt would put SecurityAgent there), the Input Monitoring and
// Accessibility grants before and after (a prompt-free API changes neither), and which chords
// were pressed. Posting the chords through CGEvent is not an option: posting keyboard events is
// gated by Accessibility (a first attempt put up its prompt), so the press has to be real.
// Lastly compares `SuspendingClock.now` with CLOCK_UPTIME_RAW, the recorder's host clock.

import AppKit
import Carbon.HIToolbox
import IOKit.hid

var fired: [UInt32: (at: UInt64, frontmost: String)] = [:]

let handler: EventHandlerUPP = { _, event, _ in
    var id = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    fired[id.id] = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW), NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")
    return noErr
}

func grants() -> String {
    "input monitoring \(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted), accessibility \(AXIsProcessTrusted())"
}

func frontmost() -> String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "?" }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
print("before registering: frontmost \(frontmost()); grants: \(grants())")

var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
InstallEventHandler(GetApplicationEventTarget(), handler, 1, &spec, nil, nil)
let chord = UInt32(controlKey | optionKey | cmdKey)
var refs: [EventHotKeyRef?] = [nil, nil]
let statuses = [
    RegisterEventHotKey(UInt32(kVK_ANSI_R), chord, EventHotKeyID(signature: 0x4f53_5455, id: 1), GetApplicationEventTarget(), 0, &refs[0]),
    RegisterEventHotKey(UInt32(kVK_ANSI_P), chord, EventHotKeyID(signature: 0x4f53_5455, id: 2), GetApplicationEventTarget(), 0, &refs[1]),
]
print("RegisterEventHotKey statuses: \(statuses) (0 = noErr)")

Task {
    try await Task.sleep(for: .milliseconds(300))
    print("300 ms after registering: frontmost \(frontmost()); grants: \(grants())")
    print("press ⌃⌥⌘R then ⌃⌥⌘P in any app within 8 s…")
    try await Task.sleep(for: .seconds(8))
    for id: UInt32 in [1, 2] {
        if let hit = fired[id] { print("chord \(id) fired; frontmost at the time: \(hit.frontmost)") } else { print("chord \(id) not pressed") }
    }
    print("after: frontmost \(frontmost()); grants: \(grants())")
    let suspending = SuspendingClock.now
    let raw = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    print("CLOCK_UPTIME_RAW \(raw) ns; SuspendingClock.now \(suspending); CLOCK_MONOTONIC_RAW \(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) ns; ContinuousClock.now \(ContinuousClock.now)")
    for ref in refs.compactMap({ $0 }) { UnregisterEventHotKey(ref) }
    exit(0)
}
app.run()
