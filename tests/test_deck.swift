import Foundation

// 1.22: Stream Deck opens by itself, and the start-up opens it before the show so its keys show the
// show's start state. Run with tests/run.sh, which compiles this next to a copy of BoothCheck.swift.
var failures = 0
func expect(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print((ok ? "PASS  " : "FAIL  ") + name + (ok ? "" : "   (got: \(got()))"))
    if !ok { failures += 1 }
}

// 1. The start-up order. Lightkey sends every cue's state once, when the show opens (rig, 9 Oct 2026),
//    so with a Stream Deck: Lightkey without the show, its MIDI input, Stream Deck, then the show.
func order(lightkey: Bool = true, dmx: Bool = true, deck: Bool = true, apps: [String] = [], checkOnly: Bool = false) -> [String] {
    startUpOrder(lightkey: lightkey, dmx: dmx, streamDeck: deck, apps: apps, checkOnly: checkOnly)
}
let full = order(apps: ["app:com.renewedvision.propresenter"])
expect("the booth: deck before the show", full == ["dmxWait", "app:com.renewedvision.propresenter", "lightkeyApp", "midi", "deck", "lightkey", "dmxLink", "check"],
       "\(full)")
expect("no Stream Deck: Lightkey with the show, as before", order(deck: false) == ["dmxWait", "lightkey", "dmxLink", "check"], "\(order(deck: false))")
expect("no DMX box: no DMX steps", order(dmx: false) == ["lightkeyApp", "midi", "deck", "lightkey", "check"], "\(order(dmx: false))")
expect("Stream Deck without Lightkey", order(lightkey: false) == ["deck", "check"], "\(order(lightkey: false))")
expect("check only", order(checkOnly: true) == ["check"], "\(order(checkOnly: true))")

// 2. Opening Stream Deck outside the start-up: switched on here, its app not running.
func open(on: Bool = true, installed: Bool = true, running: Bool = false, busy: Bool = false,
          lightkeyMac: Bool = true, ready: Bool = true, since: TimeInterval = 999) -> Bool {
    shouldOpenStreamDeck(enabled: on, installed: installed, running: running, busy: busy,
                         needsLightkey: lightkeyMac, lightkeyReady: ready, sinceLast: since)
}
expect("switched on, not running, Lightkey ready: open it", open())
expect("already running: leave it", !open(running: true))
expect("switched off: leave it", !open(on: false))
expect("not installed: nothing to open", !open(installed: false))
expect("during a start-up or shutdown: they handle it", !open(busy: true))
expect("Lightkey's MIDI input not there yet: wait", !open(ready: false))
expect("no Lightkey on this Mac: open it anyway", open(lightkeyMac: false, ready: false))
expect("opened 20 seconds ago: not again yet", !open(since: 20))
expect("a minute later: again", open(since: 70))

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
