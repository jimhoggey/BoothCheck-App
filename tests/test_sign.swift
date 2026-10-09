import Foundation

// 1.16: the hands-off sign during the start-up at login, and when a start-up counts as ready.
// Run with tests/run.sh, which compiles this next to a copy of BoothCheck.swift (no @main).
var failures = 0
func expect(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print((ok ? "PASS  " : "FAIL  ") + name + (ok ? "" : "   (got: \(got()))"))
    if !ok { failures += 1 }
}

// 1. Which start-ups get the sign: the one that runs by itself at login and opens something.
let booth = ["dmxWait", "lightkey", "midi", "dmxLink", "deck", "check"]
expect("the start-up at login gets the sign", startUpShowsSign(atLogin: true, steps: booth))
expect("Get the show started by hand: no sign", !startUpShowsSign(atLogin: false, steps: booth))
expect("a check-only start-up opens nothing: no sign", !startUpShowsSign(atLogin: true, steps: ["check"]))

// 2. What it says. Lightkey may ask for the Mac's password from when it opens until it holds the
//    DMX interface; then the sign must not say "don't touch", and must not cover Lightkey's alert.
func sign(replug: Bool = false, asks: Bool = true, opened: Bool, linked: Bool) -> StartSign {
    startSign(replugShowing: replug, asksPassword: asks, lightkeyOpened: opened, dmxLinked: linked)
}
expect("before Lightkey opens: hands off", sign(opened: false, linked: false) == .handsOff, "\(sign(opened: false, linked: false))")
expect("while the replug sign is up: nothing", sign(replug: true, opened: false, linked: false) == .none,
       "\(sign(replug: true, opened: false, linked: false))")
expect("once Lightkey opens: the password", sign(opened: true, linked: false) == .password, "\(sign(opened: true, linked: false))")
expect("once Lightkey holds the DMX interface: hands off again", sign(opened: true, linked: true) == .handsOff,
       "\(sign(opened: true, linked: true))")
expect("no DMX box, so no password to ask for: hands off", sign(asks: false, opened: true, linked: false) == .handsOff,
       "\(sign(asks: false, opened: true, linked: false))")

// 2b. What the banner tells people to do in Lightkey: the two things the booth docs have them do there.
//     With no show chosen in Booth Check, Lightkey opens on its list of projects (the docs' step 4).
let named = passwordSignText(show: "BackupChurch_modular_v33"), unnamed = passwordSignText(show: nil)
expect("the banner says to tap Authenticate", named.contains("Authenticate") && unnamed.contains("Authenticate"), named)
expect("it names the chosen show to click in Lightkey's list", named.contains("click BackupChurch_modular_v33"), named)
expect("with no show chosen, it says to click the most recent project", unnamed.contains("most recent"), unnamed)

// 2c. 1.19: the banner says plainly when Lightkey's Authenticate alert is up, and otherwise how to
//     find Lightkey (church Mac, 9 Oct 2026: nothing on screen until someone clicked Lightkey).
let asking = passwordSign(show: "BackupChurch_modular_v30", asking: true)
let waiting = passwordSign(show: "BackupChurch_modular_v30", asking: false)
expect("alert up: the title says Lightkey is asking", asking.title.contains("asking for the password"), asking.title)
expect("alert up: tap Authenticate", asking.text.contains("Authenticate"), asking.text)
expect("no alert seen: how to find Lightkey", waiting.text.contains("Dock"), waiting.text)
expect("no alert seen: still names the show", waiting.text.contains("BackupChurch_modular_v30"), waiting.text)

// 2d. Bringing Lightkey to the front when it opened behind something, without fighting anyone.
let me = "app.boothcheck.BoothCheck"
func front(_ app: String?, _ tries: Int, _ since: TimeInterval) -> Bool {
    shouldFrontLightkey(frontmost: app, me: me, attempts: tries, sinceLast: since)
}
expect("behind Finder: bring it forward", front("com.apple.finder", 0, 0))
expect("already in front: leave it", !front(IDs.lightkey, 0, 0))
expect("macOS's password box in front: never", !front("com.apple.SecurityAgent", 0, 0))
expect("a permission prompt in front: never", !front("com.apple.UserNotificationCenter", 0, 0))
expect("Booth Check's own window in front: leave it", !front(me, 0, 0))
expect("again only after 10 seconds", !front("com.apple.finder", 1, 5) && front("com.apple.finder", 1, 12))
expect("no more than three times", !front("com.apple.finder", 3, 60))

// 2e. 1.21: Lightkey's DontUnloadFTDIDrivers setting (church Mac, 9 Oct 2026: on, no Authenticate,
//     lights work), read from `defaults read`'s output. With it on, there's no password to ask for.
expect("defaults says 1: on", defaultsSaysOn("1\n"))
expect("defaults says true: on", defaultsSaysOn("true"))
expect("defaults says 0: off", !defaultsSaysOn("0\n"))
expect("not set (defaults prints an error, nothing on stdout): off", !defaultsSaysOn(""))

// 3. Ready for the service: every step went fine, or one warned on the way and every check is green now.
expect("every step done: ready", startUpReady(steps: [.done, .done, .done], problems: 0, unknown: 0, checks: 12))
expect("a step warned, every check green now: ready", startUpReady(steps: [.done, .warn, .done], problems: 0, unknown: 0, checks: 12))
expect("something to fix: not ready", !startUpReady(steps: [.done, .warn, .done], problems: 1, unknown: 0, checks: 12))
expect("a check can't tell yet: not ready", !startUpReady(steps: [.done, .warn, .done], problems: 0, unknown: 1, checks: 12))
expect("a step warned and nothing is checked: not ready", !startUpReady(steps: [.warn], problems: 0, unknown: 0, checks: 0))

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
