import Foundation

// "Lightkey is sending DMX" (1.12). Lightkey drives USB DMX interfaces through its OLA server, olad, a
// separate process it starts from /Library/OLA, so olad's connection has to count as Lightkey's.
// Run with tests/run.sh, which compiles this next to a copy of BoothCheck.swift (no @main).
var failures = 0
func expect(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print((ok ? "PASS  " : "FAIL  ") + name + (ok ? "" : "   (got: \(got()))"))
    if !ok { failures += 1 }
}

// `ps -axo pid=,comm=` on the booth Mac while Lightkey runs (pid 700) with its OLA server (pid 812).
let ps = """
    1 /sbin/launchd
   90 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
  700 /Applications/Lightkey.app/Contents/MacOS/Lightkey
  812 /Library/OLA/0.10.8/bin/olad
  901 /Applications/Booth Check.app/Contents/MacOS/BoothCheck
"""

// `ioreg -l -w0 -c IOUserClient`, trimmed to two clients: WindowServer's HID client, and the Open DMX
// USB opened through libusb by olad.
let ioreg = """
+-o Root  <class IORegistryEntry, id 0x100000100, retain 30>
    | | +-o IOHIDLibUserClient  <class IOHIDLibUserClient, id 0x100000a01, !registered, !matched, active, busy 0, retain 6>
    | | |   {
    | | |     "IOUserClientDefaultLocking" = Yes
    | | |     "IOUserClientCreator" = "pid 90, WindowServer"
    | | |   }
    | | +-o AppleUSBHostDeviceUserClient  <class AppleUSBHostDeviceUserClient, id 0x100000b02, !registered, !matched, active, busy 0, retain 6>
    | | |   {
    | | |     "IOUserClientDefaultLocking" = Yes
    | | |     "IOUserClientCreator" = "pid 812, olad"
    | | |   }
"""

let pids = dmxDriverPIDs(lightkey: 700, psOutput: ps)
expect("Lightkey's OLA server (olad) counts as Lightkey", pids.contains(812), "\(pids)")
expect("Lightkey itself still counts", pids.contains(700), "\(pids)")
expect("nothing else counts", Set(pids) == [700, 812], "\(pids)")
expect("the Open DMX USB held by olad is found", !usbConnections(ioreg, pids: pids).isEmpty,
       "\(usbConnections(ioreg, pids: pids))")
expect("no olad running: just Lightkey", dmxDriverPIDs(lightkey: 700, psOutput: "  700 /Applications/Lightkey.app/Contents/MacOS/Lightkey\n") == [700])
expect("a connection held by some other process doesn't count", usbConnections(ioreg, pids: [700]).isEmpty)
expect("a non-USB client never counts", usbConnections(ioreg, pids: [90]).isEmpty)

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
