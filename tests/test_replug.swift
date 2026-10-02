import Foundation

// 1.15: the replug sign's animation, and a finished start-up settling once nothing needs fixing.
// Run with tests/run.sh, which compiles this next to a copy of BoothCheck.swift (no @main).
var failures = 0
func expect(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print((ok ? "PASS  " : "FAIL  ") + name + (ok ? "" : "   (got: \(got()))"))
    if !ok { failures += 1 }
}

// 1. The replug animation: one loop is plug in → slide out (step 1 lit) → out → slide in (step 2 lit) → in.
let start = replugFrame(0.0), slidingOut = replugFrame(0.3), outThere = replugFrame(0.5)
let slidingIn = replugFrame(0.7), backIn = replugFrame(0.9)
expect("loop starts plugged in, step 1 lit", start.out == 0 && start.step == 1, "\(start)")
expect("then slides out, step 1 lit", slidingOut.out > 0 && slidingOut.out < 1 && slidingOut.step == 1, "\(slidingOut)")
expect("then sits all the way out, step 2 lit", outThere.out == 1 && outThere.step == 2, "\(outThere)")
expect("then slides back in, step 2 lit", slidingIn.out > 0 && slidingIn.out < 1 && slidingIn.step == 2, "\(slidingIn)")
expect("then sits plugged in again", backIn.out == 0 && backIn.step == 2, "\(backIn)")
expect("and loops", replugFrame(1.25) == replugFrame(0.25) && replugFrame(7.5) == replugFrame(0.5))

// 2. A finished start-up that had warnings settles once nothing needs fixing (the panel then goes).
expect("finished, nothing to fix: settles",
       startUpSettles(finished: true, running: false, alreadySettled: false, problems: 0))
expect("still something to fix: stays", !startUpSettles(finished: true, running: false, alreadySettled: false, problems: 1))
expect("still running: not yet", !startUpSettles(finished: false, running: true, alreadySettled: false, problems: 0))
expect("settled already: once only", !startUpSettles(finished: true, running: false, alreadySettled: true, problems: 0))

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
