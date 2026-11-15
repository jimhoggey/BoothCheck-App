import Foundation

// Nov 2026, "smarter, not more complicated": the start-up's final confirmation, the MIDI-input retry,
// the weekly shutdown's guard, row texts that say what to press, the no-password setting and the login
// rows put back at a login start-up, and Aptabase error reports. Run with tests/run.sh. Nothing here
// talks to the real server or changes this Mac: sending uses an injected transport, in a temporary folder.
var failures = 0
func expect(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print((ok ? "PASS  " : "FAIL  ") + name + (ok ? "" : "   (got: \(got()))"))
    if !ok { failures += 1 }
}

// 1. The panel's heading and its "Check everything" step always say the same number.
for n in 0...7 {
    let step = checkStepWords(problems: n)
    let ready = startUpReady(steps: [.done, .done, step.state], problems: n, unknown: 0, checks: 20)
    let head = bootHeadline(finished: true, ready: ready, problems: n)
    if n == 0 {
        expect("0 problems: step done and the heading says ready", step.state == .done && head == "Ready for the service", head)
    } else {
        expect("\(n) problems: heading and step say the same count", head == thingsToFix(n) && step.detail.hasPrefix(thingsToFix(n) + ".") && step.state == .warn,
               "\(head) / \(step.detail)")
    }
}
expect("1 thing, not 1 things", thingsToFix(1) == "1 thing to fix" && thingsToFix(3) == "3 things to fix")
expect("still running: Starting the show", bootHeadline(finished: false, ready: false, problems: 3) == "Starting the show")
expect("a step warned, nothing to fix now, something unknown: with warnings",
       bootHeadline(finished: true, ready: false, problems: 0) == "Started, with warnings")

// 1b. What Lightkey reported as the show opened: evidence only.
var a = MIDIActivity()
a = midiActivityAdding(a, word: 0x2091_0A7F, at: 10)     // note-on ch 2 note 10, 127: a cue on
a = midiActivityAdding(a, word: 0x2091_0B00, at: 11)     // note-on, velocity 0: off
a = midiActivityAdding(a, word: 0x2081_0C40, at: 12)     // note-off
a = midiActivityAdding(a, word: 0x20B1_0740, at: 13)     // control change
let clock = midiActivityAdding(a, word: 0x10F8_0000, at: 99) // a system message (clock): never counts
expect("channel messages counted, one cue on", a.messages == 4 && a.cuesOn == 1 && a.lastAt == 13, "\(a)")
expect("clock and other system messages don't count", clock == a)
let none = startStateEvidence(mark: nil, now: a, late: false)
expect("not listening: not_listened", none.prop == "not_listened" && none.messages == 0)
let rep = startStateEvidence(mark: MIDIActivity(messages: 1, cuesOn: 0, lastAt: 5), now: a, late: false)
expect("reported: counts since the mark", rep.prop == "reported" && rep.messages == 3 && rep.on == 1 && !rep.text.contains("missed"), rep.text)
let quiet = startStateEvidence(mark: a, now: a, late: true)
expect("nothing since the mark: none, and says it may have missed some", quiet.prop == "none" && quiet.text.contains("missed"), quiet.text)

// 2. Lightkey restarted once at the start-up when its MIDI input never appears.
expect("a Lightkey the start-up opened: once", midiRelaunchAllowed(openedByStartUp: true, alreadyRelaunched: false, shuttingDown: false))
expect("never twice", !midiRelaunchAllowed(openedByStartUp: true, alreadyRelaunched: true, shuttingDown: false))
expect("never a Lightkey that was already open (it may be running the service)",
       !midiRelaunchAllowed(openedByStartUp: false, alreadyRelaunched: false, shuttingDown: false))
expect("never while shutting down", !midiRelaunchAllowed(openedByStartUp: true, alreadyRelaunched: false, shuttingDown: true))

// 3. The weekly shutdown waits while the lights are in use.
expect("no cue reported this session: shut down", !lightkeyRecentlyUsed(lastAt: nil, now: 5000))
expect("a cue 9 min 59 s ago: not yet", lightkeyRecentlyUsed(lastAt: 4401, now: 5000))
expect("a cue 10 min ago: shut down", !lightkeyRecentlyUsed(lastAt: 4400, now: 5000))

// 4. Row texts say what to press.
let napFail = appNapCheck(appNapOff: false, switchedOffAt: nil, deckLaunched: nil)
expect("App Nap: no restart of the Mac, names the button", !(napFail.fix ?? "").contains("restart the Mac") && (napFail.fix ?? "").contains("Turn App Nap off"), napFail.fix ?? "")
let napWarn = appNapCheck(appNapOff: true, switchedOffAt: Date(), deckLaunched: Date().addingTimeInterval(-60))
expect("App Nap after Stream Deck opened: says how to quit Stream Deck", (napWarn.fix ?? "").contains("Quit Stream Deck") && (napWarn.fix ?? "").contains("Booth Check opens it again"), napWarn.fix ?? "")
let screen = screenCheck(held: false, onAC: true)
expect("screen: a tech quits Booth Check with Option held", (screen.fix ?? "").hasPrefix("Ask a tech") && (screen.fix ?? "").contains("Option"), screen.fix ?? "")
expect("DMX unconfirmed: says what to do when the lights don't respond",
       !selfRepairWords(.dmxUnconfirmed).detail.contains("all is well") && selfRepairWords(.dmxUnconfirmed).detail.contains("click"))
expect("Stream Deck didn't open: names the button", selfRepairWords(.deckFailed).detail.contains("Open Stream Deck"))
expect("the helper failed: no vague \"see what's wrong\"", !selfRepairWords(.helperFailed).detail.contains("what\u{2019}s wrong"))
expect("replug words name the cable and the row's button", replugDMXWords.contains("USB cable") && replugDMXWords.contains("Lightkey is sending DMX"))

// 5. Lightkey's no-password setting put back at a login start-up.
expect("wanted, off, Lightkey not running: put back", lightkeyNoPasswordRepairNeeded(wanted: true, settingOn: false, lightkeyRunning: false, dmx: true))
expect("a tech switched it off: stays off", !lightkeyNoPasswordRepairNeeded(wanted: false, settingOn: false, lightkeyRunning: false, dmx: true))
expect("not known yet: left alone", !lightkeyNoPasswordRepairNeeded(wanted: nil, settingOn: false, lightkeyRunning: false, dmx: true))
expect("already on: nothing to do", !lightkeyNoPasswordRepairNeeded(wanted: true, settingOn: true, lightkeyRunning: false, dmx: true))
expect("Lightkey running: never", !lightkeyNoPasswordRepairNeeded(wanted: true, settingOn: false, lightkeyRunning: true, dmx: true))
expect("no DMX interface here: never", !lightkeyNoPasswordRepairNeeded(wanted: true, settingOn: false, lightkeyRunning: false, dmx: false))
expect("a ready start-up with it on: wanted", noPasswordWantedAfterStartUp(nil, ready: true, settingOn: true) == true)
expect("not ready, or off: still not known", noPasswordWantedAfterStartUp(nil, ready: false, settingOn: true) == nil
       && noPasswordWantedAfterStartUp(nil, ready: true, settingOn: false) == nil)
expect("a tech's off stays off", noPasswordWantedAfterStartUp(false, ready: true, settingOn: true) == false)
let saved = try! JSONDecoder().decode(MacSetup.self, from: Data("{\"lightkey\":true}".utf8))
expect("an old saved setup loads with it not known", saved.noPasswordWanted == nil)
var withIt = MacSetup(); withIt.noPasswordWanted = true
let back = try! JSONDecoder().decode(MacSetup.self, from: try! JSONEncoder().encode(withIt))
expect("it's saved and read back", back.noPasswordWanted == true)

// 6. The login rows a login start-up fixes by itself.
let deckItem = LoginItem(name: "Stream Deck", path: "/Applications/Elgato Stream Deck.app")
func row(_ id: String, _ s: Status, _ a: Action?) -> Check { Check(id: id, group: "Start at login", title: id, status: s, detail: "", action: a) }
let rows = [row("selfLogin", .fail, .addSelfToLogin), row("autoShow", .warn, .chooseShow), row("loginShows", .warn, .removeShowLoginItems),
            row("deckLogin", .warn, .removeLoginItem(deckItem)), row("reopen", .warn, .stopReopeningApps)]
expect("all four, in order", startUpLoginRepairs(rows, selfInApplications: true) == ["selfLogin", "loginShows", "deckLogin", "reopen"],
       "\(startUpLoginRepairs(rows, selfInApplications: true))")
expect("not from a build folder: Booth Check doesn't add itself", startUpLoginRepairs(rows, selfInApplications: false) == ["loginShows", "deckLogin", "reopen"])
expect("green rows: nothing", startUpLoginRepairs([row("reopen", .ok, nil), row("selfLogin", .ok, nil)], selfInApplications: true).isEmpty)
expect("couldn't read the reopen setting: left alone", startUpLoginRepairs([row("reopen", .unknown, .stopReopeningApps)], selfInApplications: true).isEmpty)
expect("a row without its own fix (installed somewhere unwritable): left alone",
       startUpLoginRepairs([row("selfLogin", .warn, nil), row("deckLogin", .warn, .addStreamDeckToLogin)], selfInApplications: true).isEmpty)
expect("login shows as a person fixes them: the start-up's self-repair rows", selfRepairRows("login_reopen") == ["reopen"]
       && selfRepairRows("lightkey_no_password") == ["lkpass"])

// 7. Error reports.
let sys: [String: DiagValue] = ["isDebug": .bool(true), "osName": .string("macOS"), "osVersion": .string("26.1.0"),
                                "appVersion": .string("1.31"), "sdkVersion": .string("boothcheck@1"), "locale": .string("en-AU")]
let err = DiagError(id: "x", time: 1_763_000_000, session: "s-1", errorType: String(repeating: "T", count: 150),
                    errorMessage: String(repeating: "m", count: 6000), stackTrace: String(repeating: "s", count: 12000), severity: "error", kind: "handled")
let eb = (try? JSONSerialization.jsonObject(with: aptabaseErrorBody(err, system: sys))) as? [String: Any] ?? [:]
expect("one JSON object with the spec's keys",
       Set(eb.keys) == ["errorMessage", "errorType", "stackTrace", "timestamp", "platform", "osName", "osVersion", "appVersion", "sdkVersion", "sessionId", "severity", "kind", "isDebug"],
       "\(eb.keys.sorted())")
expect("limits: message 5000, type 100, trace 10000", (eb["errorMessage"] as? String)?.count == 5000 && (eb["errorType"] as? String)?.count == 100
       && (eb["stackTrace"] as? String)?.count == 10000)
expect("platform macOS, the events' sdkVersion, isDebug a bool, session", eb["platform"] as? String == "macOS" && eb["sdkVersion"] as? String == "boothcheck@1"
       && eb["isDebug"] as? Bool == true && eb["sessionId"] as? String == "s-1" && eb["timestamp"] as? String == aptabaseTimestamp(Date(timeIntervalSince1970: 1_763_000_000)))
let noTrace = (try? JSONSerialization.jsonObject(with: aptabaseErrorBody(DiagError(id: "y", time: 0, session: "s", errorType: "T", errorMessage: "m", stackTrace: nil, severity: "fatal", kind: "crash"), system: [:]))) as? [String: Any] ?? [:]
expect("no trace, no system props: left out", noTrace["stackTrace"] == nil && noTrace["osName"] == nil && noTrace["isDebug"] == nil)
expect("202: sent", aptabaseErrorOutcome(status: 202) == .sent)
expect("403 (quota used up): dropped, not retried", aptabaseErrorOutcome(status: 403) == .drop)
expect("400 and 401: dropped", aptabaseErrorOutcome(status: 400) == .drop && aptabaseErrorOutcome(status: 401) == .drop)
expect("network error, 408, 429, 5xx: kept", aptabaseErrorOutcome(status: nil) == .retry && aptabaseErrorOutcome(status: 408) == .retry
       && aptabaseErrorOutcome(status: 429) == .retry && aptabaseErrorOutcome(status: 503) == .retry)
expect("each type once a session", errorReportAllowed("A", sent: []) && !errorReportAllowed("A", sent: ["A"]))
expect("at most 10 a session", !errorReportAllowed("K", sent: Set((0..<10).map { "T\($0)" })) && errorReportAllowed("K", sent: Set((0..<9).map { "T\($0)" })))
let entries = (1...30).map { LogEntry(title: "entry \($0)", language: "Terminal", code: "cmd", output: "out", status: 0) }
let trace = recentLogLines(Array(entries.reversed()))
expect("the trace: the last 40 lines of the log, newest last", trace.split(separator: "\n", omittingEmptySubsequences: false).count == 40 && trace.contains("entry 30")
       && !trace.contains("entry 1 "), String(trace.suffix(120)))

// 7b. Crash reports: .ips (header line, JSON body) and the older .crash text.
let ips = """
{"app_name":"Booth Check","timestamp":"2026-11-15 10:00:00.00 +1100","bug_type":"309"}
{"exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP","codes":"0x1"},"termination":{"indicator":"Trace/BPT trap: 5"},"asi":{"libswiftCore.dylib":["Fatal error: Index out of range"]},"faultingThread":1,"threads":[{"frames":[{"imageIndex":1,"imageOffset":100}]},{"triggered":true,"frames":[{"imageIndex":0,"symbol":"Booth.finish(_:_:number:)","symbolLocation":42,"imageOffset":4096},{"imageIndex":1,"imageOffset":255}]}],"usedImages":[{"name":"Booth Check"},{"name":"libswiftCore.dylib"}]}
"""
let g = crashReportGist(ips)
expect(".ips: errorType from the exception type", g?.type == "EXC_BREAKPOINT", "\(String(describing: g))")
expect(".ips: message with signal, termination and Swift's last words", (g?.message ?? "").contains("SIGTRAP") && (g?.message ?? "").contains("Index out of range")
       && (g?.message ?? "").contains("Trace/BPT"), g?.message ?? "")
expect(".ips: the crashed thread's frames, with image and symbol", (g?.stack ?? "").contains("Thread 1 crashed") && (g?.stack ?? "").contains("0  Booth Check  Booth.finish(_:_:number:) + 42")
       && (g?.stack ?? "").contains("1  libswiftCore.dylib  0xff"), g?.stack ?? "")
let crash = """
Process:               Booth Check [123]
Exception Type:        EXC_BAD_ACCESS (SIGSEGV)
Exception Codes:       KERN_INVALID_ADDRESS at 0x0000000000000010

Thread 0 Crashed:: Dispatch queue: com.apple.main-thread
0   Booth Check   0x0000000100001000 Booth.refresh() + 12
1   AppKit        0x00000001800ff000 -[NSApplication run] + 100

Thread 1:
0   libsystem     0x1 wait
"""
let c = crashReportGist(crash)
expect(".crash: type, codes and only the crashed thread", c?.type == "EXC_BAD_ACCESS" && (c?.message ?? "").contains("KERN_INVALID_ADDRESS")
       && (c?.stack ?? "").contains("Booth.refresh()") && !(c?.stack ?? "").contains("wait"), "\(String(describing: c))")
expect("not a crash report: nil", crashReportGist("hello\nworld") == nil)
let t0 = Date(timeIntervalSince1970: 1000)
expect("the newest Booth Check report since the run began",
       newestCrashReport([("Booth Check-1.ips", t0.addingTimeInterval(10)), ("Booth Check-2.ips", t0.addingTimeInterval(20)),
                          ("Lightkey-3.ips", t0.addingTimeInterval(30)), ("Booth Check-0.ips", t0.addingTimeInterval(-5))], since: t0) == "Booth Check-2.ips")
expect(".crash files count too", isBoothCheckCrashReport("Booth Check-2026.crash"))
expect("none since: nil", newestCrashReport([("Booth Check-0.ips", t0)], since: t0) == nil)

// 7c. The real queue and sending, with a fake server.
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bc-errors-\(UUID().uuidString)").path
let files = DiagFiles(logDir: dir + "/logs", supportDir: dir + "/support")
var requests: [URLRequest] = []
var answers: [Int?] = []
let d = Diagnostics(files: files, appKey: "A-TEST-1", transport: { req, done in
    requests.append(req)
    let s = answers.isEmpty ? 202 : answers.removeFirst()
    done(s, Data(), s == nil ? NSError(domain: "test", code: 1) : nil)
})
d.systemProps = sys
d.recordError("CheckFailed:dmx", "DMX interface plugged in: No USB DMX interface found. In \(NSHomeDirectory())", stack: "line 1\nline 2",
              severity: "error", kind: "handled", session: nil, time: Date())
d.recordError("CheckFailed:dmx", "the same again", stack: "", severity: "error", kind: "handled", session: nil, time: Date())
let queued: [DiagError] = d.loadLines(files.errors)
expect("the second of a type in a session isn't queued", queued.count == 1, "\(queued.count)")
expect("scrubbed before it's queued", !(queued.first?.errorMessage ?? "").contains(NSHomeDirectory()) && (queued.first?.errorMessage ?? "").contains("~"), queued.first?.errorMessage ?? "")
expect("the session is this launch's", queued.first?.session == d.session)
let disk1 = (try? String(contentsOfFile: files.log, encoding: .utf8)) ?? ""
expect("the log on disk says it wasn't sent again", disk1.contains("error report CheckFailed:dmx: not sent again"), disk1)
answers = [503]
_ = d.flushSync()
expect("one request to the error API, one object, the key", requests.count == 1 && requests[0].url == aptabaseErrorURL
       && requests[0].value(forHTTPHeaderField: "App-Key") == "A-TEST-1" && requests[0].value(forHTTPHeaderField: "Content-Type") == "application/json"
       && ((try? JSONSerialization.jsonObject(with: requests[0].httpBody ?? Data())) as? [String: Any])?["errorType"] as? String == "CheckFailed:dmx")
expect("503: kept for later", (d.loadLines(files.errors) as [DiagError]).count == 1)
answers = [202]
let logs = d.flushSync(ignoreBackoff: true)
expect("202: sent and gone", (d.loadLines(files.errors) as [DiagError]).isEmpty && logs.contains { $0.title == "Diagnostics: sent error report CheckFailed:dmx" },
       logs.map(\.title).joined(separator: "; "))
d.recordError("ShutdownStayedOn", "it stayed on", stack: "", severity: "error", kind: "handled", session: nil, time: Date())
answers = [403]
_ = d.flushSync(ignoreBackoff: true)
expect("403: dropped, not retried", (d.loadLines(files.errors) as [DiagError]).isEmpty)
let off = Diagnostics(files: DiagFiles(logDir: dir + "/l2", supportDir: dir + "/s2"), appKey: nil, transport: { _, done in done(202, nil, nil) })
off.recordError("StartupNotReady", "x", stack: "", severity: "error", kind: "handled", session: nil, time: Date())
expect("no key: nothing queued", (off.loadLines(off.files.errors) as [DiagError]).isEmpty)
try? FileManager.default.removeItem(atPath: dir)

print(failures == 0 ? "test_selfheal: all passed" : "test_selfheal: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
