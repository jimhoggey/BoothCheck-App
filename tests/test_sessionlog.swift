import Foundation

// 1.30: the session log (session_summary, session_row, person, shutdown_done timings). Run with
// tests/run.sh, which compiles this next to a copy of BoothCheck.swift. Pure functions only.
var failures = 0
func expect(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print((ok ? "PASS  " : "FAIL  ") + name + (ok ? "" : "   (got: \(got()))"))
    if !ok { failures += 1 }
}

func ck(_ id: String, _ s: Status, _ title: String? = nil) -> Check {
    Check(id: id, group: "g", title: title ?? id.uppercased(), status: s, detail: "d")
}
func newTally() -> SessionTally { SessionTally(session: "s1", version: "1.30", launch: "login_item", startedWall: 1_800_000_000) }
func int(_ v: DiagValue?) -> Int { v.flatMap { Int($0.text) } ?? -999 }
func str(_ v: DiagValue?) -> String { v?.text ?? "<nil>" }

// 1. A row's spells: time not OK, worst, spells, cleared by itself.
var t = newTally()
tallyPass(&t, [ck("dmx", .ok), ck("show", .warn), ck("ac", .ok)], at: 10)
tallyPass(&t, [ck("dmx", .fail), ck("show", .warn), ck("ac", .ok)], at: 25)
var cleared = tallyPass(&t, [ck("dmx", .ok), ck("show", .fail), ck("ac", .ok)], at: 85)
expect("dmx spell ended after 60 s", cleared == [RowCleared(id: "dmx", seconds: 60, by: "by_itself")], "\(cleared)")
expect("dmx: worst fail, 60 s, one spell, ever OK", t.rows["dmx"]?.worst == "fail" && t.rows["dmx"]?.badSeconds == 60 && t.rows["dmx"]?.spells == 1 && t.rows["dmx"]?.everOK == true)
expect("show: warn then fail is one spell, worst fail", t.rows["show"]?.spells == 1 && t.rows["show"]?.worst == "fail" && t.rows["show"]?.badSince == 10)
expect("show never OK", t.rows["show"]?.everOK == false)
expect("ac: no spells", t.rows["ac"]?.spells == 0 && t.rows["ac"]?.everOK == true)
expect("passes counted", t.passes == 3 && t.elapsed == 85)

// 2. Unknown and manual leave a row as it was.
tallyPass(&t, [ck("dmx", .unknown), ck("show", .manual), ck("ac", .ok)], at: 100)
expect("unknown keeps dmx OK, manual keeps show bad", t.rows["dmx"]?.badSince == nil && t.rows["show"]?.badSince == 10)
tallyPass(&t, [ck("dmx", .warn), ck("show", .fail), ck("ac", .ok)], at: 115)
tallyPass(&t, [ck("dmx", .unknown), ck("show", .fail), ck("ac", .ok)], at: 130)
cleared = tallyPass(&t, [ck("dmx", .ok), ck("show", .fail), ck("ac", .ok)], at: 145)
expect("bad -> unknown -> ok ends the spell at the ok", cleared.first?.seconds == 30 && t.rows["dmx"]?.badSeconds == 90 && t.rows["dmx"]?.spells == 2, "\(cleared)")
expect("worst stays fail after a later warn", t.rows["dmx"]?.worst == "fail")

// 3. What cleared it: a Fix clicked and run during the spell; an action before the spell doesn't count.
var u = newTally()
tallyAction(&u, row: "lkpass", title: "Lightkey without the password", what: "fix:Switch it on\u{2026}", at: 1)
tallyPass(&u, [ck("lkpass", .warn), ck("dmxLive", .fail)], at: 15)
cleared = tallyPass(&u, [ck("lkpass", .ok), ck("dmxLive", .fail)], at: 30)
expect("an action before the spell: by_itself", cleared.first?.by == "by_itself", "\(cleared)")
expect("Fix click counted even before the spell", u.rows["lkpass"]?.fixClicks == 1)
tallyPass(&u, [ck("lkpass", .ok), ck("dmxLive", .fail)], at: 45)
tallyAction(&u, row: "dmxLive", what: "fix:Reconnect the lights\u{2026}", at: 50)
tallyAction(&u, row: "dmxLive", what: "run:dmxReconnect", at: 52)
cleared = tallyPass(&u, [ck("lkpass", .ok), ck("dmxLive", .ok)], at: 60)
expect("cleared by the change that ran", cleared == [RowCleared(id: "dmxLive", seconds: 45, by: "run:dmxReconnect")], "\(cleared)")
expect("its Fix click counted, the run not", u.rows["dmxLive"]?.fixClicks == 1)
expect("self-repair rows", selfRepairRows("deck_profile") == ["deckProfile"] && selfRepairRows("helper_restart") == ["deckLights"] && selfRepairRows("menu_icon").isEmpty)

// 4. Muted while bad, and a row switched off: the spell ends, put down to that.
var m = newTally()
tallyPass(&m, [ck("upd", .warn), ck("nap", .fail), ck("ac", .ok)], at: 15)
tallyAction(&m, row: "upd", what: "mute", at: 20)
cleared = tallyPass(&m, [ck("ac", .ok)], at: 30)
expect("muted and gone end their spells", cleared.contains(RowCleared(id: "upd", seconds: 15, by: "muted")) && cleared.contains(RowCleared(id: "nap", seconds: 15, by: "gone")), "\(cleared)")
expect("muted flag", m.rows["upd"]?.muted == true)
tallyAction(&m, row: "upd", what: "unmute", at: 40)
expect("unmute clears it", m.rows["upd"]?.muted == false)

// 5. session_row: a row bad for the whole session, still bad at the end.
var s = newTally()
tallyPass(&s, [ck("lpm", .warn, "Low Power Mode"), ck("dmx", .ok), ck("ac", .ok)], at: 100)
tallyPass(&s, [ck("lpm", .warn, "Low Power Mode"), ck("dmx", .fail), ck("ac", .ok)], at: 1000)
tallyPass(&s, [ck("lpm", .warn, "Low Power Mode"), ck("dmx", .ok), ck("ac", .ok)], at: 1300)
let lpm = sessionRowProps(s.rows["lpm"]!, at: 10_000, sessionSeconds: 10_000)
expect("lpm: 9900 s not OK", int(lpm["bad_s"]) == 9900, "\(lpm)")
expect("lpm: 99% of the session", int(lpm["share_pct"]) == 99)
expect("lpm: whole session, still bad at the end", int(lpm["whole"]) == 1 && int(lpm["bad_at_end"]) == 1 && str(lpm["cleared_by"]) == "still_bad")
expect("lpm: title, worst, first bad", str(lpm["title"]) == "Low Power Mode" && str(lpm["worst"]) == "warn" && int(lpm["first_bad_s"]) == 100)
let dmx = sessionRowProps(s.rows["dmx"]!, at: 10_000, sessionSeconds: 10_000)
expect("dmx: 300 s, 3%, not whole, cleared by itself", int(dmx["bad_s"]) == 300 && int(dmx["share_pct"]) == 3 && int(dmx["whole"]) == 0 && int(dmx["bad_at_end"]) == 0 && str(dmx["cleared_by"]) == "by_itself", "\(dmx)")
expect("share never over 100", int(sessionRowProps(s.rows["lpm"]!, at: 10_000, sessionSeconds: 5)["share_pct"]) == 100)
expect("no session seconds: share 0", int(sessionRowProps(s.rows["lpm"]!, at: 10_000, sessionSeconds: 0)["share_pct"]) == 0)

// 6. The events: summary first, then a row each for the rows ever bad, most not-OK time first.
s.startups = 1; s.startupReady = true; s.startupSeconds = 94.6; s.people = 3
let evs = sessionEvents(s, at: 10_000, ended: "shutdown_menu")
expect("summary + 2 rows", evs.map(\.name) == ["session_summary", "session_row", "session_row"], "\(evs.map(\.name))")
expect("rows ordered by not-OK time", str(evs[1].props["check"]) == "lpm" && str(evs[2].props["check"]) == "dmx")
expect("each row carries ended", evs.dropFirst().allSatisfy { str($0.props["ended"]) == "shutdown_menu" })
let sum = evs[0].props
expect("summary: ended, length, how it started", str(sum["ended"]) == "shutdown_menu" && int(sum["session_s"]) == 10_000 && str(sum["launch_how"]) == "login_item" && str(sum["version"]) == "1.30")
expect("summary: start-up ready in 95 s", str(sum["startup"]) == "ready" && int(sum["startup_s"]) == 95 && int(sum["startups"]) == 1)
expect("summary: 3 rows, 1 stayed OK, 2 bad, 1 bad at end", int(sum["rows"]) == 3 && int(sum["rows_ok"]) == 1 && int(sum["rows_bad"]) == 2 && int(sum["bad_at_end"]) == 1, "\(sum)")
expect("summary: people and the bad rows", int(sum["people"]) == 3 && str(sum["bad_rows"]) == "dmx,lpm")
expect("summary: started timestamp", str(sum["started"]) == "2027-01-15T08:00:00Z", str(sum["started"]))
expect("no start-up: none", str(sessionSummaryProps(newTally(), at: 5, ended: "quit")["startup"]) == "none")
expect("a quiet session is one event", sessionEvents(newTally(), at: 5, ended: "quit").count == 1)
// Every event passes Aptabase's rules unchanged (keys ≤ 40, strings ≤ 170).
expect("within Aptabase's limits", evs.allSatisfy { e in e.name.count <= 60 && e.props.allSatisfy { $0.key.count <= 40 && $0.value.text.utf16.count <= 170 } })

// 7. The tallies survive a round trip through session.json (what an unclean end relies on).
let data = try! JSONEncoder().encode(s)
let back = try! JSONDecoder().decode(SessionTally.self, from: data)
expect("session.json round trip", back == s)
let late = sessionEvents(back, at: back.elapsed, ended: "unclean")
expect("unclean: summary from the saved copy", str(late[0].props["ended"]) == "unclean" && int(late[0].props["session_s"]) == 1300, "\(late[0].props)")
expect("a bad decode gives nil, not a crash", (try? JSONDecoder().decode(SessionTally.self, from: Data("{}".utf8))) == nil)

// 8. The diagnostics files: session.json beside running.json, written and read back.
let dir = NSTemporaryDirectory() + "bc-session-\(UUID().uuidString)"
let files = DiagFiles(logDir: dir + "/logs", supportDir: dir + "/support")
expect("session.json path", files.session == dir + "/support/session.json")
let d = Diagnostics(files: files, appKey: "A-US-0000000000", transport: { _, done in done(200, Data("{}".utf8), nil) })
d.writeSession(data)
expect("written and read back", d.readSession() == s)
d.queue.sync {}
d.record("person", ["action": .string("fix"), "check": .string("dmxLive")], time: Date())
d.queue.sync {}
let logText = (try? String(contentsOfFile: files.log, encoding: .utf8)) ?? ""
expect("record writes the event to the log on disk", logText.contains("event person: action=fix check=dmxLive"), logText)
expect("and queues it", d.loadQueue().last?.name == "person")
d.setEnabled(false)
d.record("person", ["action": .string("mute")], time: Date())
d.queue.sync {}
expect("diagnostics off: still on disk, not queued",
       ((try? String(contentsOfFile: files.log, encoding: .utf8)) ?? "").contains("action=mute") && d.loadQueue().count == 1)
try? FileManager.default.removeItem(atPath: dir)

// 9. The previous session's events go out under its own session id.
let dir2 = NSTemporaryDirectory() + "bc-session-\(UUID().uuidString)"
let d2 = Diagnostics(files: DiagFiles(logDir: dir2 + "/l", supportDir: dir2 + "/s"), appKey: "A-US-0000000000", transport: { _, done in done(200, Data("{}".utf8), nil) })
d2.queue.sync { d2.record("session_summary", ["ended": .string("unclean")], time: Date(), session: "old-session") }
let q = d2.loadQueue().last
expect("old session id and launch", q?.session == "old-session" && q?.props["launch"] == .string("old-session"), "\(String(describing: q))")
try? FileManager.default.removeItem(atPath: dir2)

// 10. eventLogLine: one line, keys sorted, spaces quoted, newlines folded.
let line = eventLogLine("check_failed", ["title": .string("Lightkey is sending DMX"), "check": .string("dmxLive"), "n": .int(2), "detail": .string("a\nb")], time: Date(timeIntervalSince1970: 0))
expect("log line", line.hasSuffix("  event check_failed: check=dmxLive detail=\"a / b\" n=2 title=\"Lightkey is sending DMX\"\n") && !line.dropLast().contains("\n"), line)
expect("empty string quoted", eventLogLine("x", ["apps": .string("")], time: Date()).contains("apps=\"\""))

// 11. markDurations: the shutdown's steps.
let marks: [(name: String, at: Double)] = [("start", 100), ("countdown", 110.04), ("other_apps", 110.5), ("blackout", 113.5), ("stream_deck", 115), ("lightkey", 131)]
let dur = markDurations(marks)
expect("countdown 10 s, lightkey 16 s, total 31 s", dur["countdown_s"] == .double(10) && dur["lightkey_s"] == .double(16) && dur["total_s"] == .double(31), "\(dur)")
expect("blackout 3 s, other apps 0.5 s", dur["blackout_s"] == .double(3) && dur["other_apps_s"] == .double(0.5), "\(dur)")
expect("one mark: total 0", markDurations([("start", 5)]) == ["total_s": .double(0)])
expect("no marks: nothing", markDurations([]).isEmpty)

// 12. startupStepCounts, dmxRungsRun, shutdownTrigger, launchKind.
let counts = startupStepCounts([.done, .done, .warn, .failed, .waiting])
expect("step counts", int(counts["steps"]) == 5 && int(counts["steps_ok"]) == 2 && int(counts["steps_warn"]) == 1 && int(counts["steps_failed"]) == 1 && int(counts["steps_not_run"]) == 1, "\(counts)")
var ladder = DMXLadder()
expect("no rungs", dmxRungsRun(ladder) == 0)
ladder.hupTried = true; ladder.hupSent = true; ladder.resetTried = true; ladder.relaunches = 2
expect("sighup + 2 relaunches = 3 (reset tried, not pressed)", dmxRungsRun(ladder) == 3)
expect("triggers", shutdownTrigger(.button) == "menu" && shutdownTrigger(.timed) == "weekly_time" && shutdownTrigger(.powerOff) == "power_off")
expect("launch kinds", launchKind(flag: true, loginItemEvent: false, uptime: 9999) == "login_flag"
       && launchKind(flag: false, loginItemEvent: true, uptime: 9999) == "login_item"
       && launchKind(flag: false, loginItemEvent: false, uptime: 60) == "after_restart"
       && launchKind(flag: false, loginItemEvent: false, uptime: 600) == "by_hand")

// 13. changedSetupKeys: which This Mac settings changed.
var a = MacSetup(), b = MacSetup()
expect("same setup: nothing", changedSetupKeys(a, b).isEmpty)
b.dmx = false; b.blackoutAtShutdown = !a.blackoutAtShutdown
expect("two switches", changedSetupKeys(a, b) == ["blackoutAtShutdown", "dmx"], "\(changedSetupKeys(a, b))")
a.deckLights = nil; b = a; b.deckLights = true
expect("nil to a value counts", changedSetupKeys(a, b) == ["deckLights"], "\(changedSetupKeys(a, b))")

print(failures == 0 ? "test_sessionlog: all passed" : "test_sessionlog: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
