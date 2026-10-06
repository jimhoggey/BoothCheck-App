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

// 3. Ready for the service: every step went fine, or one warned on the way and every check is green now.
expect("every step done: ready", startUpReady(steps: [.done, .done, .done], problems: 0, unknown: 0, checks: 12))
expect("a step warned, every check green now: ready", startUpReady(steps: [.done, .warn, .done], problems: 0, unknown: 0, checks: 12))
expect("something to fix: not ready", !startUpReady(steps: [.done, .warn, .done], problems: 1, unknown: 0, checks: 12))
expect("a check can't tell yet: not ready", !startUpReady(steps: [.done, .warn, .done], problems: 0, unknown: 1, checks: 12))
expect("a step warned and nothing is checked: not ready", !startUpReady(steps: [.warn], problems: 0, unknown: 0, checks: 0))

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
