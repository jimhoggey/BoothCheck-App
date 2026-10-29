import Foundation

// 1.26: the deck lights helper. launchd runs it (installed once per Mac with install_helper.sh from
// the Lightkey-Skill repo); Booth Check only watches it and offers Start or Restart. It publishes the
// "Lightkey Feedback" MIDI source the deck's keys read their lights from. Run with tests/run.sh.
var failures = 0
func expect(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print((ok ? "PASS  " : "FAIL  ") + name + (ok ? "" : "   (got: \(got()))"))
    if !ok { failures += 1 }
}

// 1. Reading `launchctl print gui/<uid>/<label>`: the job's own state is the one-tab "state = " line;
//    nested blocks have their own states, and "job state" is something else.
let running = """
gui/501/com.c3b.deckstatehelper = {
\tactive count = 1
\tpath = /Users/me/Library/LaunchAgents/com.c3b.deckstatehelper.plist
\tstate = running

\tprogram = /Users/me/Library/Application Support/DeckStateHelper/deck_state_helper
\tendpoints = {
\t\t"com.example" = {
\t\t\tstate = active
\t\t}
\t}
\tjob state = exited
}
"""
expect("running job", launchdJobState(running) == "running", "\(launchdJobState(running) ?? "nil")")
let nested = "gui/501/x = {\n\t\tstate = active\n\tjob state = running\n\tstate = not running\n}"
expect("nested and job states are skipped", launchdJobState(nested) == "not running", "\(launchdJobState(nested) ?? "nil")")
expect("not loaded: no state", launchdJobState("Bad request.\nCould not find service \"com.c3b.deckstatehelper\" in domain for user gui: 501") == nil)

// 2. The check. Only OK when launchd runs it and its MIDI port is there.
func check(installed: Bool = true, loaded: Bool = true, state: String? = "running", port: Bool = true) -> Check {
    deckHelperCheck(installed: installed, loaded: loaded, state: state, feedbackPort: port)
}
let ok = check()
expect("running with its port: green", ok.status == .ok && ok.action == nil && ok.group == "Stream Deck" && ok.id == "deckLights")
let noPort = check(port: false)
expect("running, port missing: red, Restart", noPort.status == .fail && noPort.action?.label == "Restart\u{2026}", noPort.action?.label ?? "nil")
let stopped = check(state: "not running", port: false)
expect("loaded, not running: red, Restart", stopped.status == .fail && stopped.action?.label == "Restart\u{2026}")
expect("loaded, not running, says launchd's state", stopped.detail.contains("not running"), stopped.detail)
let notLoaded = check(loaded: false, state: nil, port: false)
expect("installed, not loaded: red, Start", notLoaded.status == .fail && notLoaded.action?.label == "Start\u{2026}", notLoaded.action?.label ?? "nil")
let missing = check(installed: false, loaded: false, state: nil, port: false)
expect("not installed: red, Install (1.27)", missing.status == .fail && missing.action?.label == "Install\u{2026}", missing.action?.label ?? "nil")
expect("not installed but a stale port from somewhere: still red", check(installed: false, loaded: false, state: nil, port: true).status == .fail)

// 3. The commands behind the buttons: user-level launchd, no password.
let service = "gui/\(getuid())/com.c3b.deckstatehelper"
expect("Restart is launchd's kickstart -k", deckHelperRestartArgs() == ["kickstart", "-k", service], "\(deckHelperRestartArgs())")
let plist = NSHomeDirectory() + "/Library/LaunchAgents/com.c3b.deckstatehelper.plist"
expect("Start bootstraps the installed plist", deckHelperStartArgs() == ["bootstrap", "gui/\(getuid())", plist], "\(deckHelperStartArgs())")
expect("Start's undo is bootout", deckHelperStopArgs() == ["bootout", service], "\(deckHelperStopArgs())")

// 4. The start-up waits for the helper's port after Lightkey's MIDI input and before Stream Deck,
//    so the deck is listening when the show sends its start states.
let withHelper = startUpOrder(lightkey: true, dmx: true, streamDeck: true, apps: [], checkOnly: false, deckLights: true)
expect("with the helper: wait for it before Stream Deck",
       withHelper == ["dmxWait", "lightkeyApp", "midi", "deckLights", "deck", "lightkey", "dmxLink", "check"], "\(withHelper)")
expect("without the helper: as before",
       startUpOrder(lightkey: true, dmx: true, streamDeck: true, apps: [], checkOnly: false)
           == ["dmxWait", "lightkeyApp", "midi", "deck", "lightkey", "dmxLink", "check"])
expect("helper but no Stream Deck: no wait",
       !startUpOrder(lightkey: true, dmx: true, streamDeck: false, apps: [], checkOnly: false, deckLights: true).contains("deckLights"))

// 5. The This Mac switch: setups saved before 1.26 load with it undecided (nil), so Booth Check can
//    switch it on the first time it finds the helper installed; an explicit choice is kept.
let old = try! JSONDecoder().decode(MacSetup.self, from: Data(#"{"lightkey":true,"dmx":true,"streamDeck":true,"alwaysOn":true,"apps":[]}"#.utf8))
expect("old save: undecided", old.deckLights == nil)
expect("undecided stays out of the save", !String(decoding: try! JSONEncoder().encode(old), as: UTF8.self).contains("deckLights"))
var on = old
on.deckLights = true
let back = try! JSONDecoder().decode(MacSetup.self, from: try! JSONEncoder().encode(on))
expect("ticked survives a save", back.deckLights == true)
expect("found installed, undecided: switch it on", deckLightsAutoOn(setting: nil, installed: true, lightkey: true, streamDeck: true))
expect("unticked by a tech: leave it", !deckLightsAutoOn(setting: false, installed: true, lightkey: true, streamDeck: true))
expect("not installed: leave it", !deckLightsAutoOn(setting: nil, installed: false, lightkey: true, streamDeck: true))
expect("no Stream Deck here: leave it", !deckLightsAutoOn(setting: nil, installed: true, lightkey: true, streamDeck: false))

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
