import Foundation

// 1.30: "Black out the stage first": the shutdown sends the show's Blackout to Lightkey before closing
// it, so the stage lights don't flicker as Lightkey and its DMX server stop. Run with tests/run.sh.
// Synthetic profiles and words only; nothing on this Mac is read, sent or changed.
var failures = 0
func expect(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print((ok ? "PASS  " : "FAIL  ") + name + (ok ? "" : "   (got: \(got()))"))
    if !ok { failures += 1 }
}

let deckID = "@(1)[4057/143/TESTSERIAL01]"
func midiKey(ch: Int, note: Int, mode: String = "Toggle", out: String = "Lightkey Input", title: String = "k") -> String {
    """
    {"Name":"Generic Midi","UUID":"se.trevligaspel.midi.genericmidi","Plugin":{"Name":"Midi","UUID":"se.trevligaspel.midi","Version":"4.3.0.1"},
     "Settings":{"g02":"\(mode)","g47":"\(ch - 1)","g45":"\(note)","smo":"\(out)","smi":"Lightkey Output"},"States":[{"Title":"\(title)"},{}]}
    """
}
func page(_ keys: [String: String]) -> Data {
    Data((#"{"Controllers":[{"Type":"Keypad","Actions":{"# + keys.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",") + "}}],\"Name\":\"\"}").utf8)
}
func manifest(_ name: String) -> Data {
    Data(#"{"Device":{"Model":"20GAT9902","UUID":"\#(deckID)"},"Name":"\#(name)","Pages":{"Pages":["p"]},"Version":"3.0"}"#.utf8)
}
func profile(_ uuid: String, _ name: String, _ keys: [String: String]) -> DeckProfile {
    parseDeckProfile(uuid: uuid, manifest: manifest(name), pages: [page(keys)])!
}

// 1. The deck's Blackout key, as on the Sunday XL profiles (v36c, v36d, v37, v37b: "BLACKOUT", Toggle,
//    channel 2, note 0, out "Lightkey Input").
let sunday = profile("AAAA", "Lightkey XL Service", ["0,0": midiKey(ch: 2, note: 22, title: "Default"),
                                                     "6,3": midiKey(ch: 2, note: 0, title: "BLACKOUT"),
                                                     "7,2": midiKey(ch: 2, note: 45, title: "STAGE OFF")])
expect("the BLACKOUT key is found by its title", sunday.blackoutKeys.count == 1 && sunday.blackoutKeys[0].note == 0, "\(sunday.blackoutKeys)")
expect("its note: channel 2 note 0", deckProfileBlackoutNotes(sunday) == [MIDINote(channel: 2, note: 0)])
expect("blackout keys don't change the profile's signature",
       sunday.sigHash == DeckProfile(uuid: "x", name: "x", device: deckID, model: "", pages: 1, keys: sunday.keys, pluginVersions: []).sigHash)
expect("titles: BLACKOUT, Black out, black-out", isBlackoutTitle("BLACKOUT") && isBlackoutTitle("Black out") && isBlackoutTitle("black-out\n"))
expect("titles: Stage Off and Black aren't", !isBlackoutTitle("STAGE OFF") && !isBlackoutTitle("Black") && !isBlackoutTitle(""))
let summit = profile("BBBB", "Summit 2026", ["0,0": midiKey(ch: 5, note: 3, title: "Verse")])
expect("Summit profile: no Blackout key", deckProfileBlackoutNotes(summit).isEmpty)
let elsewhere = profile("CCCC", "Sniffer", ["0,0": midiKey(ch: 2, note: 0, out: "Deck Sniffer", title: "BLACKOUT")])
expect("a Blackout key sending elsewhere doesn't count", deckProfileBlackoutNotes(elsewhere).isEmpty)
let twice = profile("DDDD", "Two pages", ["0,0": midiKey(ch: 2, note: 0, title: "BLACKOUT"), "1,0": midiKey(ch: 2, note: 0, title: "Blackout")])
expect("the same Blackout on two keys: one note", deckProfileBlackoutNotes(twice) == [MIDINote(channel: 2, note: 0)])
let clash = profile("EEEE", "Clash", ["0,0": midiKey(ch: 2, note: 0, title: "BLACKOUT"), "1,0": midiKey(ch: 3, note: 0, title: "BLACKOUT")])
expect("Blackout keys on two notes: both listed", deckProfileBlackoutNotes(clash).count == 2)

// 2. .deck.json's "blackout".
func deckFile(_ s: String) -> (file: DeckShowFile, warnings: [String]) { parseDeckShowFile(Data(s.utf8)) }
expect("\"2:0\": channel 2 note 0", deckFile(#"{"blackout":"2:0"}"#).file.blackout == .note(MIDINote(channel: 2, note: 0)))
expect("null: this show has none", deckFile(#"{"blackout":null}"#).file.blackout == .none)
expect("left out: not set", deckFile(#"{"profile":"X"}"#).file.blackout == .notSet)
for bad in [#""17:0""#, #""2:128""#, #""2""#, "20", #""a:b""#] {
    let r = deckFile(#"{"blackout":\#(bad)}"#)
    expect("bad \(bad): ignored with a warning", r.file.blackout == .notSet && r.warnings.contains { $0.contains("blackout") }, "\(r)")
}
let withHelper = deckFile(#"{"blackout":"2:0","helper":{"channels":"x"}}"#)
expect("blackout survives a bad helper entry", withHelper.file.blackout == .note(MIDINote(channel: 2, note: 0)) && !withHelper.warnings.isEmpty)
expect("the Log text names it", deckShowFileText((deckFile(#"{"blackout":"2:0","helper":null}"#).file, [], "/x.deck.json")).contains("Blackout: MIDI channel 2, note 0"))
expect("parseMIDINote", parseMIDINote(" 16:127 ") == MIDINote(channel: 16, note: 127) && parseMIDINote("0:1") == nil && parseMIDINote("2:0:1") == nil)

// 3. Where the note comes from: .deck.json, then the chosen profile, then all profiles if they agree.
let two0 = MIDINote(channel: 2, note: 0)
var file = DeckShowFile()
file.blackout = .note(MIDINote(channel: 4, note: 9))
if case .note(let n, let from) = blackoutSource(file: file, chosen: DeckProfileChoice(sunday), profiles: [sunday]) {
    expect(".deck.json wins over the deck", n == MIDINote(channel: 4, note: 9) && from.contains(".deck.json"), from)
} else { expect(".deck.json wins over the deck", false) }
file.blackout = .none
if case .unknown(let why) = blackoutSource(file: file, chosen: DeckProfileChoice(sunday), profiles: [sunday]) {
    expect(".deck.json null: none, said plainly", why.contains("no Blackout"), why)
} else { expect(".deck.json null: none", false) }
if case .note(let n, let from) = blackoutSource(file: nil, chosen: DeckProfileChoice(sunday), profiles: [sunday, summit]) {
    expect("the chosen profile's Blackout key", n == two0 && from.contains("Lightkey XL Service"), from)
} else { expect("the chosen profile's Blackout key", false) }
if case .unknown(let why) = blackoutSource(file: nil, chosen: DeckProfileChoice(summit), profiles: [sunday, summit]) {
    expect("chosen Summit profile: can't tell (no fallback to another deck)", why.contains("Summit 2026") && why.contains("no key"), why)
} else { expect("chosen Summit profile: can't tell", false) }
if case .unknown = blackoutSource(file: nil, chosen: DeckProfileChoice(clash), profiles: [clash]) {
    expect("chosen profile with two Blackout notes: can't tell", true)
} else { expect("chosen profile with two Blackout notes: can't tell", false) }
if case .note(let n, _) = blackoutSource(file: nil, chosen: nil, profiles: [sunday, summit, twice]) {
    expect("nothing chosen, the profiles agree: that note", n == two0)
} else { expect("nothing chosen, the profiles agree", false) }
if case .unknown(let why) = blackoutSource(file: nil, chosen: nil, profiles: [sunday, clash]) {
    expect("nothing chosen, the profiles disagree: can't tell", why.contains("different notes"), why)
} else { expect("nothing chosen, the profiles disagree", false) }
if case .unknown(let why) = blackoutSource(file: DeckShowFile(), chosen: nil, profiles: [summit]) {
    expect("no Blackout key anywhere: can't tell", why.contains("No Stream Deck profile"), why)
} else { expect("no Blackout key anywhere", false) }
let gone = DeckProfileChoice(name: "Old", uuid: "zzzz", sigHash: "0000000000")
if case .note(let n, _) = blackoutSource(file: nil, chosen: gone, profiles: [sunday]) {
    expect("chosen profile no longer installed: the installed ones", n == two0)
} else { expect("chosen profile no longer installed", false) }

// 4. Whether to send at all. Never blind (without Lightkey Output), never without Lightkey.
let found = BlackoutSource.note(two0, from: "deck")
let ins = ["Lightkey Input", "IAC Driver Bus 1"], outs = ["Lightkey Output"]
expect("everything there: send", blackoutPlan(lightkeyRunning: true, destinations: ins, sources: outs, source: found) == .send(two0, from: "deck"))
if case .skip(let why) = blackoutPlan(lightkeyRunning: false, destinations: ins, sources: outs, source: found) {
    expect("Lightkey closed: skip", why.contains("isn\u{2019}t open"), why)
} else { expect("Lightkey closed: skip", false) }
if case .skip(let why) = blackoutPlan(lightkeyRunning: true, destinations: ["IAC Driver Bus 1"], sources: outs, source: found) {
    expect("no Lightkey Input: skip", why.contains("Lightkey Input"), why)
} else { expect("no Lightkey Input: skip", false) }
if case .skip(let why) = blackoutPlan(lightkeyRunning: true, destinations: ins, sources: ["Lightkey Feedback"], source: found) {
    expect("no Lightkey Output: skip, never blind", why.contains("blind"), why)
} else { expect("no Lightkey Output: skip", false) }
expect("source unknown: skip with its reason", blackoutPlan(lightkeyRunning: true, destinations: ins, sources: outs, source: .unknown("why")) == .skip("why"))

// 5. The MIDI: the note-on Booth Check sends, and Lightkey's reports on Lightkey Output.
let word = midiNoteOnWord(two0)
expect("note-on ch2 note 0 vel 127: 91 00 7F", midiBytesText(word) == "91 00 7F" && word >> 28 == 2, String(word, radix: 16))
expect("ch16 note 127: 9F 7F 7F", midiBytesText(midiNoteOnWord(MIDINote(channel: 16, note: 127))) == "9F 7F 7F")
func ump(_ status: UInt32, _ d1: UInt32, _ d2: UInt32) -> UInt32 { 0x2000_0000 | status << 16 | d1 << 8 | d2 }
expect("Lightkey's 127: on", cueReply(ump(0x91, 0, 127), for: two0) == .on)
expect("Lightkey's Note Off: off", cueReply(ump(0x81, 0, 0), for: two0) == .off)
expect("note-on velocity 0: off", cueReply(ump(0x91, 0, 0), for: two0) == .off)
expect("another note: ignored", cueReply(ump(0x91, 22, 127), for: two0) == nil)
expect("another channel: ignored", cueReply(ump(0x92, 0, 127), for: two0) == nil)
expect("a controller: ignored", cueReply(ump(0xB1, 0, 127), for: two0) == nil)
expect("not a MIDI 1.0 word: ignored", cueReply(0x4091_0000, for: two0) == nil)

// 6. After sending: the toggle hazard. A Flash binding (the Sunday show's) reports on, or nothing when
//    Blackout was already on. A toggling binding with Blackout already on reports off: send once more.
expect("just sent: wait", blackoutNext(replies: [], sends: 1, sinceSend: 0.2) == .wait)
if case .done(let on, _) = blackoutNext(replies: [.on], sends: 1, sinceSend: 0.1) { expect("on: done", on == true) } else { expect("on: done", false) }
expect("off after the first send: send again (it toggled an on Blackout off)", blackoutNext(replies: [.off], sends: 1, sinceSend: 0.1) == .sendAgain)
if case .done(let on, let text) = blackoutNext(replies: [.on], sends: 2, sinceSend: 0.1) {
    expect("on again after the second send: done, explained", on == true && text.contains("toggles"), text)
} else { expect("on after the second send", false) }
if case .done(let on, _) = blackoutNext(replies: [.off], sends: 2, sinceSend: 0.1) {
    expect("off after two sends: stop (never a third send)", on == false)
} else { expect("off after two sends: stop", false) }
if case .done(let on, let text) = blackoutNext(replies: [], sends: 1, sinceSend: 1.5) {
    expect("no report in 1.5 s: done, most likely already on", on == nil && text.contains("already"), text)
} else { expect("no report in 1.5 s: done", false) }
expect("still within 1.5 s: wait", blackoutNext(replies: [], sends: 2, sinceSend: 1.4) == .wait)
if case .done(let on, _) = blackoutNext(replies: [.off, .on], sends: 1, sinceSend: 0.3) { expect("off then on (the deck echoed): the last word counts", on == true) }
else { expect("off then on: the last word counts", false) }
expect("worst case: two sends, each waiting 1.5 s, then the 2 s for the lights: at most 5 s",
       2 * blackoutListen + blackoutFade <= 5)

// 7. The switch in This Mac, and the setting.
expect("off: says so", blackoutSwitchDetail(on: false, source: found).hasPrefix("Off"))
expect("on: names the note and where it comes from", blackoutSwitchDetail(on: true, source: found).contains("MIDI channel 2, note 0, from deck"))
expect("can't tell: says so, and that the shutdown carries on",
       blackoutSwitchDetail(on: true, source: .unknown("No key.")).contains("Can\u{2019}t send it: No key. The shutdown carries on"))
let old = try! JSONDecoder().decode(MacSetup.self, from: Data(#"{"lightkey":true,"dmx":true,"streamDeck":true,"alwaysOn":true,"apps":[]}"#.utf8))
expect("a setup saved before 1.30: off", old.blackoutAtShutdown == false)
var on = MacSetup()
expect("a new setup: off by default", on.blackoutAtShutdown == false)
on.blackoutAtShutdown = true
let back = try! JSONDecoder().decode(MacSetup.self, from: try! JSONEncoder().encode(on))
expect("switched on: saved and read back", back.blackoutAtShutdown == true)

print(failures == 0 ? "all shutdown blackout tests pass" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
