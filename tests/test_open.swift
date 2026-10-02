import Foundation

// The start-up's "Open <show> in Lightkey" step (1.14). Lightkey doesn't load the show until someone
// clicks Authenticate and types the Mac's password, so once Lightkey is running the step waits for the
// show, long enough for a person to authenticate, and never re-sends the open request.
// Run with tests/run.sh, which compiles this next to a copy of BoothCheck.swift (no @main).
var failures = 0
func expect(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print((ok ? "PASS  " : "FAIL  ") + name + (ok ? "" : "   (got: \(got()))"))
    if !ok { failures += 1 }
}

// isOpen: true/false when Booth Check can read Lightkey's windows (Accessibility), nil when it can't.
expect("show open at the first look: done", showOpenNext(isOpen: true, waited: 0) == .done)
expect("waiting for Authenticate, 5 s in: keep waiting", showOpenNext(isOpen: false, waited: 5) == .wait,
       "\(showOpenNext(isOpen: false, waited: 5))")
expect("still waiting at 119 s: keep waiting (time to type a password)", showOpenNext(isOpen: false, waited: 119) == .wait,
       "\(showOpenNext(isOpen: false, waited: 119))")
expect("not open after 2 minutes: say it isn't showing", showOpenNext(isOpen: false, waited: 121) == .notShowing,
       "\(showOpenNext(isOpen: false, waited: 121))")
expect("opened after the password, 40 s in: done", showOpenNext(isOpen: true, waited: 40) == .done)
expect("can't see Lightkey's windows: done, no guessing", showOpenNext(isOpen: nil, waited: 0) == .done,
       "\(showOpenNext(isOpen: nil, waited: 0))")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
