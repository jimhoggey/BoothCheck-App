import Foundation

// The 1.11 fixes: App Nap warning, the exact show file, a missing show, the empty state.
// Run with tests/run.sh, which compiles this next to a copy of BoothCheck.swift (no @main).
var failures = 0
func expect(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print((ok ? "PASS  " : "FAIL  ") + name + (ok ? "" : "   (got: \(got()))"))
    if !ok { failures += 1 }
}

// 1. App Nap: warn only while a Stream Deck that opened before App Nap was switched off is running.
let t0 = Date()
let napThenDeck = appNapCheck(appNapOff: true, switchedOffAt: t0, deckLaunched: t0.addingTimeInterval(5))
expect("App Nap switched off, then Stream Deck opened: ok", napThenDeck.status == .ok, "\(napThenDeck.status): \(napThenDeck.detail)")
let deckThenNap = appNapCheck(appNapOff: true, switchedOffAt: t0, deckLaunched: t0.addingTimeInterval(-60))
expect("Stream Deck already open when App Nap was switched off: warn", deckThenNap.status == .warn, "\(deckThenNap.status)")
let alreadyOff = appNapCheck(appNapOff: true, switchedOffAt: nil, deckLaunched: t0.addingTimeInterval(-60))
expect("App Nap was already off before Booth Check opened: ok", alreadyOff.status == .ok, "\(alreadyOff.status)")
let noDeck = appNapCheck(appNapOff: true, switchedOffAt: t0, deckLaunched: nil)
expect("switched off, Stream Deck not running: ok", noDeck.status == .ok, "\(noDeck.status)")
let napOn = appNapCheck(appNapOff: false, switchedOffAt: nil, deckLaunched: nil)
expect("App Nap still on: fail", napOn.status == .fail, "\(napOn.status)")

// 2. The right show: the file path decides when Lightkey gives one; titles are a strict fallback.
let chosen = "/Users/booth/Shows/BackupChurch_modular_v33.lightkeyproj"
let copyElsewhere = URL(fileURLWithPath: "/Users/booth/Downloads/BackupChurch_modular_v33.lightkeyproj")
expect("the chosen file is open", showIsOpen(chosen, docs: [URL(fileURLWithPath: chosen)], titles: []))
expect("a same-named copy from another folder isn't the show",
       !showIsOpen(chosen, docs: [copyElsewhere], titles: ["BackupChurch_modular_v33"]))
expect("title only: the name on its own", showIsOpen(chosen, docs: [], titles: ["BackupChurch_modular_v33"]))
expect("title only: the name with \u{2014} Edited",
       showIsOpen(chosen, docs: [], titles: ["BackupChurch_modular_v33 \u{2014} Edited"]))
expect("title only: v3 doesn't pass for v33",
       !showIsOpen("/Users/booth/Shows/BackupChurch_modular_v3.lightkeyproj", docs: [], titles: ["BackupChurch_modular_v33"]))
expect("title only: a Finder copy isn't the show", !showIsOpen(chosen, docs: [], titles: ["BackupChurch_modular_v33 copy"]))

// 3. A show file that has gone is a failure straight away, before Lightkey even opens.
let booth = Booth.shared
booth.showPath = "/Users/booth/Shows/Gone_v33.lightkeyproj"
let gone = booth.showCheck(nil, Pass())
expect("missing show file: fail, and says so", gone.status == .fail && gone.detail.contains("Can\u{2019}t find"),
       "\(gone.status): \(gone.detail)")
booth.showPath = CommandLine.arguments[0]              // this test program: a file that exists
let there = booth.showCheck(nil, Pass())
expect("show file there, Lightkey closed: still waiting", there.status == .unknown, "\(there.status): \(there.detail)")

// 4. Window header and menu bar agree before the first pass and when nothing applies.
booth.showPath = nil
expect("before the first pass: Checking\u{2026} and an hourglass",
       booth.summary.title == "Checking\u{2026}" && booth.menuSymbol == "hourglass", "\(booth.summary.title) \(booth.menuSymbol)")
booth.lastChecked = Date()
expect("nothing to check: says so, dashed circle",
       booth.summary.title == "Nothing to check on this Mac" && booth.menuSymbol == "circle.dashed",
       "\(booth.summary.title) \(booth.menuSymbol)")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
