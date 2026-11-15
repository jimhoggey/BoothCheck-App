import Foundation

// Resetting Stream Deck's saved key lights (Nov 2026): which keys, the byte-for-byte edit and its proof,
// the per-page write with its backup and guards, and which profiles. Run with tests/run.sh. The
// fixtures are synthetic, in the shape Stream Deck 7.6 writes its ProfilesV3 page manifests (compact,
// sorted keys, "Resources":null), written to a temporary folder; nothing on this Mac is read or changed.
var failures = 0
func expect(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print((ok ? "PASS  " : "FAIL  ") + name + (ok ? "" : "   (got: \(got()))"))
    if !ok { failures += 1 }
}

/// A Trevliga MIDI key as Stream Deck 7.6 saves it, with its saved `State` and its two state titles.
func midi(_ id: String, state: String, titles: [String] = ["Warm", "Warm"], ch: Int = 1, note: Int = 3) -> String {
    #"{"ActionID":"\#(id)","LinkedTitle":true,"Name":"Generic Midi","Plugin":{"Name":"Midi","UUID":"se.trevligaspel.midi","Version":"4.4.0.0"},"Resources":null,"Settings":{"g02":"Latch","g45":"\#(note)","g47":"\#(ch)","smi":"Lightkey Output","smo":"Lightkey Input","x":1.50,"y":1e3},"State":\#(state),"States":["#
        + titles.map { ##"{"FontSize":12,"Image":"Images/k.png","ShowTitle":true,"Title":"\##($0)","TitleColor":"#ffffff"}"## }.joined(separator: ",")
        + #"],"UUID":"se.trevligaspel.midi.genericmidi"}"#
}
let text1 = #"{"ActionID":"t1","LinkedTitle":true,"Name":"Text","Plugin":{"Name":"Text","UUID":"com.elgato.streamdeck.system.text","Version":"1.0"},"Resources":null,"Settings":{"isSendingEnter":false,"pastedText":""},"State":1,"States":[{"Title":"HOUSE\nLIGHTS"},{"Title":"b"}],"UUID":"com.elgato.streamdeck.system.text"}"#
let pageNext = #"{"ActionID":"p1","Name":"Next Page","Plugin":{"Name":"Pages","UUID":"com.elgato.streamdeck.page","Version":"1.0"},"Resources":null,"Settings":{},"State":1,"States":[{"Title":""},{"Title":""}],"UUID":"com.elgato.streamdeck.page.next"}"#
// A multi-action whose inner action has its own "State": deeper than Controllers[].Actions[].State.
let multi = #"{"ActionID":"m1","Name":"Multi","Plugin":{"Name":"Multi","UUID":"com.elgato.streamdeck.multiactions","Version":"1.0"},"Resources":null,"Settings":{"Actions":[{"State":1,"States":[{},{}]}]},"State":0,"States":[{"Title":"M"}],"UUID":"com.elgato.streamdeck.multiactions.routine"}"#
func page(_ actions: [(String, String)], extra: String = "") -> String {
    #"{"Controllers":[{"Actions":{"# + actions.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + #"},"Type":"Keypad"}],"Icon":"","Name":"# + escapedName + extra + "}"
}
/// "Café \"Sunday\"" as JSON text, escapes spelled out (built from plain strings so nothing rewrites them).
let escapedName = "\"Caf" + "\\" + "u00e9 " + "\\" + "\"Sunday" + "\\" + "\"\""

// --- clearDeckPageStates: which keys -----------------------------------------------------------------
let mixed = page([("0,0", midi("a", state: "1", titles: ["Lavender", "Lavender"])), ("1,0", midi("b", state: "0")), ("2,0", text1),
                  ("3,0", pageNext), ("4,0", multi), ("5,0", midi("c", state: "1", titles: ["", #"HOUSE\n10%"#])),
                  ("6,0", midi("d", state: "1", titles: ["Solo"]))], extra: #","Nothing":null,"N":-0.5"#)
let r = clearDeckPageStates(Data(mixed.utf8))
expect("a page with lit MIDI keys gets a new file", r.data != nil && r.problem == nil, "\(r.problem ?? "nil data")")
expect("only the 2-state MIDI keys saved lit are reset (0,0 and 5,0)", r.resets.map(\.position) == ["0,0", "5,0"], "\(r.resets)")
expect("their titles are in the reset list, newline as a space", r.resets.map(\.title) == ["Lavender", "HOUSE 10%"], "\(r.resets.map(\.title))")
expect("the old state is recorded", r.resets.allSatisfy { $0.from == 1 })
// The byte-for-byte proof: the expected file, written by hand, is the input with just those two digits changed.
let expected = page([("0,0", midi("a", state: "0", titles: ["Lavender", "Lavender"])), ("1,0", midi("b", state: "0")), ("2,0", text1),
                     ("3,0", pageNext), ("4,0", multi), ("5,0", midi("c", state: "0", titles: ["", #"HOUSE\n10%"#])),
                     ("6,0", midi("d", state: "1", titles: ["Solo"]))], extra: #","Nothing":null,"N":-0.5"#)
expect("the new file is the old one with only those State digits changed, byte for byte", r.data == Data(expected.utf8),
       String(decoding: r.data ?? Data(), as: UTF8.self))
expect("same length (1 → 0)", r.data?.count == mixed.utf8.count)
let outText = String(decoding: r.data ?? Data(), as: UTF8.self)
expect("the text key's State 1 stays", outText.contains(#""Name":"Text","Plugin""#) && outText.contains(#""pastedText":""},"State":1,"#))
expect("the page key's State 1 stays", outText.contains(#""Settings":{},"State":1,"#))
expect("the multi-action's inner State 1 stays", outText.contains(#"{"Actions":[{"State":1,"#))
expect("a 1-state MIDI key's State stays", outText.contains(#""State":1,"States":[{"FontSize":12,"Image":"Images/k.png","ShowTitle":true,"Title":"Solo""#))
expect("numbers keep their spelling (1.50, 1e3, -0.5) and nulls stay", outText.contains(#""x":1.50,"y":1e3"#) && outText.contains(#""N":-0.5"#)
       && outText.contains(#""Nothing":null"#) && outText.contains(#""Resources":null"#))
expect("escapes stay as written", outText.contains(escapedName) && escapedName.contains("u00e9"))

// A 3-state MIDI key on state 2 is reset too.
let three = clearDeckPageStates(Data(page([("0,0", midi("e", state: "2", titles: ["A", "B", "C"]))]).utf8))
expect("a MIDI key on state 2 of 3 is reset, title of state 2", three.resets == [DeckKeyReset(position: "0,0", title: "C", from: 2)], "\(three.resets)")

// Nothing to do: no new file.
let clean = clearDeckPageStates(Data(page([("0,0", midi("a", state: "0")), ("1,0", text1)]).utf8))
expect("all MIDI keys dark: nothing to write, no problem", clean.data == nil && clean.resets.isEmpty && clean.problem == nil)
let empty = clearDeckPageStates(Data(#"{"Controllers":null,"Name":""}"#.utf8))
expect("an empty page (Controllers null): nothing to write", empty.data == nil && empty.problem == nil)
let emptyActions = clearDeckPageStates(Data(#"{"Controllers":[{"Actions":null,"Type":"Keypad"}],"Name":""}"#.utf8))
expect("a page with Actions null: nothing to write", emptyActions.data == nil && emptyActions.problem == nil)

// Pretty-printed JSON (whitespace, newlines) is edited in place too.
let pretty = "{\n  \"Controllers\" : [\n    {\n      \"Actions\" : {\n        \"0,0\" : " + midi("a", state: "1").replacingOccurrences(of: #""State":1"#, with: "\"State\" :  1") + "\n      }\n    }\n  ]\n}\n"
let pr = clearDeckPageStates(Data(pretty.utf8))
expect("pretty-printed: reset, whitespace kept", pr.resets.count == 1
       && String(decoding: pr.data ?? Data(), as: UTF8.self) == pretty.replacingOccurrences(of: "\"State\" :  1", with: "\"State\" :  0"))

// --- clearDeckPageStates: anything unexpected is left alone --------------------------------------------
func problem(_ s: String) -> String? { clearDeckPageStates(Data(s.utf8)).problem }
expect("not JSON: left alone", problem(#"{"Controllers":["#) != nil)
expect("an array, not an object: left alone", problem("[1,2]") != nil)
expect("a MIDI key's State as true: left alone", problem(page([("0,0", midi("a", state: "true"))])) != nil)
expect("a MIDI key's State as 1.0: left alone", problem(page([("0,0", midi("a", state: "1.0"))])) != nil)
expect("a MIDI key's State as \"1\": left alone", problem(page([("0,0", midi("a", state: "\"1\""))])) != nil)
let dup = page([("0,0", midi("a", state: "1").replacingOccurrences(of: #""State":1,"#, with: #""State":1,"State":0,"#))])
expect("a key with State twice: left alone", problem(dup) != nil)
expect("trailing junk: left alone", problem(page([("0,0", midi("a", state: "1"))]) + "x") != nil)

// The scanner on its own: only the exact path.
let ranges = deckStateValueRanges([UInt8](page([("0,0", multi), ("1,0", midi("a", state: "1"))]).utf8)) ?? []
expect("the scanner finds one State per key, none deeper", ranges.map(\.position).sorted() == ["0,0", "1,0"], "\(ranges.map(\.position))")

// --- clearDeckKeyStates: the files ---------------------------------------------------------------------
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("deckclear-\(getpid())").path
let profile = root + "/ProfilesV3/AAAAAAAA-1111-4111-8111-111111111111.sdProfile"
let backups = root + "/backups"
let litPage = page([("0,0", midi("a", state: "1", titles: ["Lavender", "Lavender"])), ("1,0", text1)])
let darkPage = page([("0,0", midi("b", state: "0"))])
func put(_ id: String, _ s: String) {
    try? fm.createDirectory(atPath: profile + "/Profiles/\(id)", withIntermediateDirectories: true)
    fm.createFile(atPath: profile + "/Profiles/\(id)/manifest.json", contents: Data(s.utf8), attributes: [.posixPermissions: 0o600])
}
func read(_ id: String) -> String { String(decoding: fm.contents(atPath: profile + "/Profiles/\(id)/manifest.json") ?? Data(), as: UTF8.self) }
put("P1", litPage); put("P2", darkPage); put("P3", "{broken")
fm.createFile(atPath: profile + "/manifest.json", contents: Data(#"{"Name":"Test"}"#.utf8))

// Stream Deck running: nothing is written, nor backed up.
let running = clearDeckKeyStates(profileDir: profile, backupDir: backups, deckRunning: { true })
expect("Stream Deck running: page left alone, says why", running.first { $0.page == "P1" }?.skipped == "Stream Deck is running" && read("P1") == litPage)
expect("Stream Deck running: no backup made", !fm.fileExists(atPath: backups))

let res = clearDeckKeyStates(profileDir: profile, backupDir: backups, deckRunning: { false })
let p1 = res.first { $0.page == "P1" }
expect("the lit page is written", p1?.written == true && p1?.resets.map(\.title) == ["Lavender"], "\(res)")
expect("…with only its State changed", read("P1") == litPage.replacingOccurrences(of: #""State":1,"States":[{"FontSize""#, with: #""State":0,"States":[{"FontSize""#))
expect("…its permissions kept", ((try? fm.attributesOfItem(atPath: profile + "/Profiles/P1/manifest.json"))?[.posixPermissions] as? Int) == 0o600)
let backup = backups + "/AAAAAAAA-1111-4111-8111-111111111111.sdProfile/P1/manifest.json"
expect("…and the original kept as the backup", String(decoding: fm.contents(atPath: backup) ?? Data(), as: UTF8.self) == litPage)
expect("the dark page isn't written or backed up", res.first { $0.page == "P2" }.map { !$0.written && $0.skipped == nil } == true
       && read("P2") == darkPage && !fm.fileExists(atPath: backups + "/AAAAAAAA-1111-4111-8111-111111111111.sdProfile/P2"))
expect("the broken page is left as it was, with a reason", res.first { $0.page == "P3" }?.skipped != nil && read("P3") == "{broken")
expect("the profile's own manifest isn't touched", String(decoding: fm.contents(atPath: profile + "/manifest.json") ?? Data(), as: UTF8.self) == #"{"Name":"Test"}"#)

// Run again: nothing left to do, the backup stays the original (not overwritten with the cleared file).
let again = clearDeckKeyStates(profileDir: profile, backupDir: backups, deckRunning: { false })
expect("a second run writes nothing", again.allSatisfy { !$0.written })
expect("…and the backup is still the original", String(decoding: fm.contents(atPath: backup) ?? Data(), as: UTF8.self) == litPage)

// Lit again later: the next run overwrites the one backup with the newer original.
let litPage2 = litPage.replacingOccurrences(of: "Lavender", with: "Blue")
put("P1", litPage2)
_ = clearDeckKeyStates(profileDir: profile, backupDir: backups, deckRunning: { false })
expect("the next run keeps one backup, the newest original", String(decoding: fm.contents(atPath: backup) ?? Data(), as: UTF8.self) == litPage2)

// Stream Deck starts between the plan and the write: the second look stops it.
put("P1", litPage)
var looks = 0
let late = clearDeckKeyStates(profileDir: profile, backupDir: backups, deckRunning: { looks += 1; return looks > 1 })
expect("Stream Deck starting mid-way: page left alone", late.first { $0.page == "P1" }?.skipped == "Stream Deck started" && read("P1") == litPage)

// The log text.
let dp = DeckProfile(uuid: "aaaaaaaa-1111-4111-8111-111111111111", name: "Test", device: "@(1)[4057/143/X]", model: "", pages: 3, keys: [], pluginVersions: [])
let logText = deckClearText(profile: dp, results: res, backupFolder: backups + "/P")
expect("the log names the profile, the count, the keys and the backup", logText.contains("\u{201C}Test\u{201D}") && logText.contains("1 key reset")
       && logText.contains("Lavender (0,0, was 1)") && logText.contains(backups + "/P/<page>/manifest.json") && logText.contains("Page P3: left as it was"), logText)

// --- deckProfilesToClear --------------------------------------------------------------------------------
func prof(_ u: String, _ n: String) -> DeckProfile { DeckProfile(uuid: u, name: n, device: "d", model: "", pages: 1, keys: [], pluginVersions: []) }
let A = prof("aaaa", "Service"), B = prof("bbbb", "Other")
let readAB = DeckProfilesRead(profiles: [A, B], folder: "/x")
let t1 = deckProfilesToClear(choice: DeckProfileChoice(A), read: readAB, preferred: ["d": "aaaa"])
expect("chosen and preferred the same: that one profile", t1.profiles.map(\.uuid) == ["aaaa"] && t1.missing.isEmpty)
let t2 = deckProfilesToClear(choice: DeckProfileChoice(A), read: readAB, preferred: ["d": "bbbb"])
expect("chosen differs from what the deck shows: both", t2.profiles.map(\.uuid) == ["aaaa", "bbbb"])
let t3 = deckProfilesToClear(choice: nil, read: readAB, preferred: ["d": "bbbb", "e": "zzzz"])
expect("none chosen: the preferred ones; a missing one is named", t3.profiles.map(\.uuid) == ["bbbb"] && t3.missing == ["zzzz"])
let t4 = deckProfilesToClear(choice: nil, read: readAB, preferred: [:])
expect("none chosen, no preferred: nothing", t4.profiles.isEmpty)

try? fm.removeItem(atPath: root)
print(failures == 0 ? "test_deckclear: all pass" : "test_deckclear: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
