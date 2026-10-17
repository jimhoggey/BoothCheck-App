import Foundation

// 1.25: the screen stays on. On the church Mac (Oct 2026), with the screen set never to turn off, it
// still went to the screen saver after a while untouched, and the Stream Deck went with it. Booth
// Check now holds macOS's "keep the display awake" (what a video player holds) on the charger.
// Run with tests/run.sh, which compiles this next to a copy of BoothCheck.swift (no @main).
var failures = 0
func expect(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print((ok ? "PASS  " : "FAIL  ") + name + (ok ? "" : "   (got: \(got()))"))
    if !ok { failures += 1 }
}

// 1. When to hold it: Stays on for services switched on, and on the charger.
expect("Stays on for services, on the charger: keep the screen on", keepsScreenOn(alwaysOn: true, onAC: true))
expect("on battery (say a power cut): let it turn off", !keepsScreenOn(alwaysOn: true, onAC: false))
expect("Stays on for services off: leave the screen to macOS", !keepsScreenOn(alwaysOn: false, onAC: true))

// 2. Reading it back from `pmset -g assertions` (format from macOS 26.6, 17 Oct 2026).
let ours = "   pid 412(BoothCheck): [0x0000567b0005a12c] 00:12:03 PreventUserIdleDisplaySleep named: \"\(screenAssertionName)\"  "
let caffeinate = "   pid 17963(caffeinate): [0x0000567b0005a12b] 00:00:01 PreventUserIdleDisplaySleep named: \"caffeinate command-line tool\"  "
expect("Booth Check's in the list: held", holdsScreenAssertion("Listed by owning process:\n" + caffeinate + "\n" + ours))
expect("only someone else's (caffeinate): not Booth Check's", !holdsScreenAssertion("Listed by owning process:\n" + caffeinate))
expect("Booth Check's name on a different kind of assertion: not held",
       !holdsScreenAssertion(ours.replacingOccurrences(of: "PreventUserIdleDisplaySleep", with: "PreventUserIdleSystemSleep")))
expect("nothing read: not held", !holdsScreenAssertion(""))

// 3. The row in Power & sleep.
expect("held: green", screenCheck(held: true, onAC: true).status == .ok)
expect("on battery: orange, plug in the charger", screenCheck(held: false, onAC: false).status == .warn
       && screenCheck(held: false, onAC: false).fix?.contains("charger") == true)
expect("on the charger but not held: red", screenCheck(held: false, onAC: true).status == .fail)

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
