import Foundation

// DMX self-recovery (1.30): both USB planes, olad left over from a force-quit Lightkey, the start-up's
// reconnect ladder, the row's fix after the start-up, the snapshot's parsing helpers, and the words on
// the big sign while Booth Check fixes something by itself. Reads nothing from this Mac.
// Run with tests/run.sh, which compiles this next to a copy of BoothCheck.swift (no @main).
var failures = 0
func expect(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print((ok ? "PASS  " : "FAIL  ") + name + (ok ? "" : "   (got: \(got()))"))
    if !ok { failures += 1 }
}

// --- Both USB planes -------------------------------------------------------------------------------

// `ioreg -p IOUSB -l -w0` with only a Stream Deck (the FTDI box missing from this plane).
let usbPlane = """
+-o Root  <class IORegistryEntry, id 0x100000100, retain 30>
  +-o AppleUSBXHCI Root Hub Simulation@14000000  <class AppleUSBRootHubDevice, id 0x100000400, registered, matched, active, busy 0 (0 ms), retain 9>
    +-o Stream Deck XL@14100000  <class IOUSBHostDevice, id 0x100000500, registered, matched, active, busy 0 (5 ms), retain 30>
        {
          "USB Product Name" = "Stream Deck XL"
          "idVendor" = 4057
        }
"""

// `ioreg -r -c IOUSBHostDevice -l -w0` listing the Open DMX USB on a hub, with its interface and driver.
let servicePlane = """
+-o USB2.0 Hub@14200000  <class IOUSBHostDevice, id 0x100000600, registered, matched, active, busy 0 (2 ms), retain 20>
  | {
  |   "USB Product Name" = "USB2.0 Hub"
  |   "idVendor" = 1507
  | }
  |
  +-o FT232R USB UART@14210000  <class IOUSBHostDevice, id 0x100000700, registered, matched, active, busy 0 (12 ms), retain 22>
    | {
    |   "USB Product Name" = "FT232R USB UART"
    |   "USB Serial Number" = "A10KXYZ"
    |   "idVendor" = 1027
    |   "idProduct" = 24577
    |   "locationID" = 337707008
    |   "sessionID" = 98765432100
    |   "USBSpeed" = 1
    | }
    |
    +-o FT232R USB UART@0  <class IOUSBHostInterface, id 0x100000701, registered, matched, active, busy 0 (3 ms), retain 8>
      | {
      |   "idVendor" = 1027
      | }
      |
      +-o AppleUSBFTDI  <class AppleUSBFTDI, id 0x100000702, registered, matched, active, busy 0 (1 ms), retain 6>
"""

let planes = dmxPlanes(usbPlane: usbPlane, servicePlane: servicePlane)
expect("seen in the IOService plane only: counts as present", planes.present && !planes.usbPlane && planes.servicePlane, "\(planes)")
expect("the planes disagree, and the text says which saw it", planes.disagree && planes.text.contains("only in the IOService plane"), planes.text)
expect("in neither plane: not present", !dmxPlanes(usbPlane: usbPlane, servicePlane: "").present)
expect("in both: no disagreement", !DMXPlanes(usbPlane: true, servicePlane: true).disagree)

let blocks = ftdiBlocks(servicePlane)
expect("one FTDI block (the device, not its interface too)", blocks.count == 1, "\(blocks.count): \(blocks)")
let b = blocks.first ?? ""
expect("the block names the device and its class", b.hasPrefix("FT232R USB UART@14210000  [IOUSBHostDevice]"), b)
expect("the block keeps serial, locationID, sessionID and speed",
       b.contains("USB Serial Number = \"A10KXYZ\"") && b.contains("locationID = 337707008") && b.contains("sessionID = 98765432100") && b.contains("USBSpeed = 1"), b)
expect("the block gives the parent hub chain", b.contains("Parent chain: USB2.0 Hub@14200000"), b)
expect("the block lists the child driver class", b.contains("[AppleUSBFTDI]") && b.contains("[IOUSBHostInterface]"), b)
expect("no FTDI blocks in the IOUSB plane here", ftdiBlocks(usbPlane).isEmpty)

// --- ps lines and olad ---------------------------------------------------------------------------------

let utc = TimeZone(identifier: "UTC")!
let ps = """
    1     0 Fri Nov 13 09:58:01 2026     12:00 /sbin/launchd
  700     1 Fri Nov 13 10:00:10 2026     09:51 /Applications/Lightkey.app/Contents/MacOS/Lightkey
  812   700 Fri Nov 13 10:00:11 2026     09:50 /Library/OLA/0.10.8/bin/olad --config-dir /Users/booth/Library/Application Support/Lightkey/OLA Configuration --http-port 9011
  901     1 Fri Nov  3 10:00:12 2026     09:49 /Applications/Booth Check.app/Contents/MacOS/BoothCheck
"""
let procs = parsePs(ps, timeZone: utc)
expect("four processes parsed", procs.count == 4, "\(procs.count)")
let olad = procs.first { $0.pid == 812 }
expect("olad: pid, parent, elapsed time", olad?.ppid == 700 && olad?.etime == "09:50" && olad?.isOlad == true, "\(String(describing: olad))")
var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 13; c.hour = 10; c.minute = 0; c.second = 11
var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
expect("olad's start time (lstart)", olad?.started == cal.date(from: c), "\(String(describing: olad?.started))")
expect("a single-digit day (\"Nov  3\") parses", procs.first { $0.pid == 901 }?.started != nil)
expect("the args keep the whole command", olad?.args.contains("--http-port 9011") == true)
expect("Lightkey is recognised", procs.first { $0.pid == 700 }?.isLightkey == true)
expect("Lightkey's olad is its child", lightkeyOlad(procs, lightkeyPID: 700)?.pid == 812)
expect("a garbage line is skipped", parsePsLine("hello world") == nil)

expect("Lightkey running: no olad is an orphan", orphanOladPIDs(procs).isEmpty)
let orphanPs = parsePs("""
  812     1 Fri Nov 13 10:00:11 2026     09:50 /Library/OLA/0.10.8/bin/olad --config-dir /Users/booth/Library/Application Support/Lightkey/OLA Configuration
  950     1 Fri Nov 13 10:00:11 2026     09:50 /opt/homebrew/bin/olad
  960     1 Fri Nov 13 10:00:11 2026     09:50 /usr/bin/olad-helper
""", timeZone: utc)
expect("no Lightkey: Lightkey's olad is an orphan; someone else's olad and other names aren't",
       orphanOladPIDs(orphanPs) == [812], "\(orphanOladPIDs(orphanPs))")

// --- Suspect link ----------------------------------------------------------------------------------------

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
expect("Lightkey already running and the box not seen at once: suspect",
       dmxLinkSuspect(lightkeyRunningAtStart: true, boxSeenAtStart: false, oladStarted: nil, boxFirstSeen: t0) != nil)
expect("Lightkey already running but the box there at once: not suspect",
       dmxLinkSuspect(lightkeyRunningAtStart: true, boxSeenAtStart: true, oladStarted: t0, boxFirstSeen: t0) == nil)
expect("olad started 10 s before the box appeared: suspect",
       dmxLinkSuspect(lightkeyRunningAtStart: false, boxSeenAtStart: false, oladStarted: t0, boxFirstSeen: t0 + 10)?.contains("olad started") == true)
expect("olad started a second before the box was seen (ps rounds, polls are 1 s): not suspect",
       dmxLinkSuspect(lightkeyRunningAtStart: false, boxSeenAtStart: true, oladStarted: t0, boxFirstSeen: t0 + 1) == nil)
expect("olad after the box: not suspect",
       dmxLinkSuspect(lightkeyRunningAtStart: false, boxSeenAtStart: true, oladStarted: t0 + 5, boxFirstSeen: t0) == nil)

// --- The ladder ------------------------------------------------------------------------------------------

func next(_ l: DMXLadder, box: Bool = true, held: Bool = false, lk: Bool = true, olad: pid_t? = 812, asking: Bool = false, ax: Bool = true) -> DMXRung {
    dmxLadderNext(boxPresent: box, held: held, lightkeyRunning: lk, oladPID: olad, asking: asking, accessibility: ax, ladder: l)
}
var l = DMXLadder()
expect("held: done", next(l, held: true) == .held)
expect("box on neither plane: no ladder (the replug sign's job)", next(l, box: false) == .noBox)
expect("Lightkey not running: say so", next(l, lk: false) == .noLightkey)
expect("Lightkey asking for the password: wait for the person", next(l, asking: true) == .waitForPassword)
expect("first rung: SIGHUP to olad", next(l) == .hup(812))
expect("no olad: the SIGHUP is skipped", next(l, olad: nil) == .skipHup)
l.hupTried = true
expect("second rung: Reset DMX Output", next(l) == .resetOutput)
expect("no Accessibility: Reset DMX Output is skipped", next(l, ax: false) == .skipReset)
l.resetTried = true
expect("third rung: restart Lightkey", next(l) == .relaunch)
l.relaunches = 1; l.hupTried = false; l.resetTried = false
expect("after a relaunch the ladder starts again at SIGHUP", next(l) == .hup(812))
l.hupTried = true; l.resetTried = true
expect("a second relaunch is allowed", next(l) == .relaunch)
l.relaunches = 2
expect("at most two relaunches, then give up", next(l) == .giveUp)
expect("held still wins after giving up", next(l, held: true) == .held)

var tried = DMXLadder()
expect("nothing tried", dmxLadderTriedText(tried) == "Booth Check couldn\u{2019}t try anything.", dmxLadderTriedText(tried))
tried.hupSent = true; tried.resetPressed = true; tried.relaunches = 2
expect("what was tried, in plain words",
       dmxLadderTriedText(tried) == "Booth Check asked Lightkey\u{2019}s DMX server to look for the interface again, pressed Lightkey\u{2019}s Reset DMX Output and restarted Lightkey 2 times.",
       dmxLadderTriedText(tried))

expect("Lightkey's menu item matches", isResetDMXOutputTitle("Reset DMX Output") && isResetDMXOutputTitle(" reset dmx output "))
expect("other menu items don't", !isResetDMXOutputTitle("Reset") && !isResetDMXOutputTitle("DMX Settings\u{2026}") && !isResetDMXOutputTitle("Quit Lightkey"))

// --- The row after the start-up ---------------------------------------------------------------------------

expect("not held, olad there: Reconnect (SIGHUP) first", dmxRowFix(oladPID: 812, sinceReconnect: nil) == .reconnect(812))
expect("just reconnected: checking, no button", dmxRowFix(oladPID: 812, sinceReconnect: 4) == .checking)
expect("reconnect didn't help: Restart Lightkey", dmxRowFix(oladPID: 812, sinceReconnect: 30) == .restart)
expect("no olad to ask: Restart Lightkey", dmxRowFix(oladPID: nil, sinceReconnect: nil) == .restart)

// --- olad's log, capping, snapshot files --------------------------------------------------------------------

let olaLog = """
olad/Olad.cpp:91: OLA Daemon version 0.10.8
plugins/ftdidmx/FtdiWidget.cpp:133: Found 0 FTDI devices
plugins/ftdidmx/FtdiDmxPlugin.cpp:80: Scanning for FTDI devices
plugins/ftdidmx/FtdiWidget.cpp:133: Found 1 FTDI device
"""
expect("the last \u{201C}Found N FTDI devices\u{201D} line", olaFoundDevices(olaLog)?.count == 1, "\(String(describing: olaFoundDevices(olaLog)))")
expect("the line itself is kept", olaFoundDevices(olaLog)?.line.hasSuffix("Found 1 FTDI device") == true)
expect("no such line: nil", olaFoundDevices("olad started\nFound the config\n") == nil)

let big = String(repeating: "a", count: 30_000) + "THE END"
let capped = capText(big, maxBytes: 20_000)
expect("capped to about the limit", capped.utf8.count < 20_100, "\(capped.utf8.count)")
expect("the cap keeps the end and says what was cut", capped.hasSuffix("THE END") && capped.contains("bytes cut"))
expect("short text is left alone", capText("short", maxBytes: 100) == "short")

var dc = DateComponents(); dc.year = 2026; dc.month = 11; dc.day = 13; dc.hour = 10; dc.minute = 15; dc.second = 3
let name = dmxSnapshotFileName(Calendar(identifier: .gregorian).date(from: dc)!, reason: "before relaunch/1")
expect("snapshot file name", name == "dmx-2026-11-13-101503-before-relaunch-1.txt", name)
let files = (1...33).map { String(format: "dmx-2026-11-%02d-100000-x.txt", $0) } + ["notes.txt"]
let remove = snapshotFilesToRemove(files)
expect("keeps the newest 30: removes the 3 oldest, nothing else",
       Set(remove) == ["dmx-2026-11-01-100000-x.txt", "dmx-2026-11-02-100000-x.txt", "dmx-2026-11-03-100000-x.txt"], "\(remove)")

let summary = dmxSnapshotSummary(planes: planes, held: false, olad: olad, found: olaFoundDevices(olaLog))
expect("the summary says present, held, olad and the OLA line",
       summary.contains("present") && summary.contains("not held") && summary.contains("olad pid 812, running 09:50") && summary.contains("Found 1 FTDI device\u{201D}"), summary)

// --- The big sign's words -----------------------------------------------------------------------------------

expect("not connected", selfRepairWords(.dmxNotConnected) == ("The lights aren\u{2019}t connected", "Reconnecting\u{2026}"))
expect("asking olad", selfRepairWords(.dmxAskingOlad).detail == "Asking Lightkey to look for the lights again.")
expect("restarting says the lights go dark", selfRepairWords(.dmxRestarting(1)).detail.contains("dark for about 20 seconds"))
expect("the second restart says so", selfRepairWords(.dmxRestarting(2)).detail.contains("Second try"))
expect("connected", selfRepairWords(.dmxConnected).title == "The lights are connected")
expect("failed says to replug the blue box", selfRepairWords(.dmxFailed).detail.contains("blue DMX box") && selfRepairWords(.dmxFailed).title.hasPrefix("Couldn\u{2019}t reconnect"))
let all: [SelfRepair] = [.dmxNotConnected, .dmxAskingOlad, .dmxResetOutput, .dmxRestarting(1), .dmxConnected, .dmxFailed, .dmxReconnectFailed,
                         .deckReopening, .deckReopened, .deckRestarting, .deckRestarted, .deckFailed,
                         .helperRestarting, .helperRestarted, .helperFailed]
expect("every self-repair has a title and a line", all.allSatisfy { !selfRepairWords($0).title.isEmpty && !selfRepairWords($0).detail.isEmpty })
expect("no two self-repairs read the same", Set(all.map { selfRepairWords($0).title + selfRepairWords($0).detail }).count == all.count)

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
