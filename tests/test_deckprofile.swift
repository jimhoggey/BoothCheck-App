import Foundation

// 1.32: which Stream Deck profile the deck is on, the profile switch's guard and value, the deck lights
// helper's installed arguments, and the show's .deck.json. Run with tests/run.sh. The fixtures are small
// and synthetic, in Stream Deck 7.6's ProfilesV3 shape, written to a temporary folder; nothing on this
// Mac is read or changed.
var failures = 0
func expect(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print((ok ? "PASS  " : "FAIL  ") + name + (ok ? "" : "   (got: \(got()))"))
    if !ok { failures += 1 }
}

let deckID = "@(1)[4057/143/TESTSERIAL01]"

/// A MIDI key as the Trevliga Spel plugin saves it: g47 channel 0-based, g45 note, g02 mode, smo/smi ports.
func midiKey(ch: Int, note: Int, mode: String = "Latch", out: String = "Lightkey Input", inPort: String = "Lightkey Output",
             version: String = "4.3.0.1") -> String {
    """
    {"Name":"Generic Midi","UUID":"se.trevligaspel.midi.genericmidi","Plugin":{"Name":"Midi","UUID":"se.trevligaspel.midi","Version":"\(version)"},
     "Settings":{"g02":"\(mode)","g47":"\(ch - 1)","g45":"\(note)","g49":"\(note)","smo":"\(out)","smi":"\(inPort)"},"States":[{"Title":"k"}]}
    """
}
let textKey = #"{"Name":"Text","UUID":"com.elgato.streamdeck.system.text","Plugin":{"Name":"Text","UUID":"com.elgato.streamdeck.system.text","Version":"1.0"},"Settings":{}}"#
func page(_ keys: [String: String]) -> String {
    #"{"Controllers":[{"Type":"Keypad","Actions":{"# + keys.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",") + "}}],\"Name\":\"\"}"
}
func manifest(_ name: String, pages: [String]) -> String {
    #"{"Device":{"Model":"20GAT9902","UUID":"\#(deckID)"},"Name":"\#(name)","Pages":{"Current":"\#(pages[0].lowercased())","Default":"\#(pages[0].lowercased())","Pages":[\#(pages.map { "\"\($0.lowercased())\"" }.joined(separator: ","))]},"Version":"3.0"}"#
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("deckprofile-\(getpid())").path
let profilesDir = root + "/ProfilesV3"
func writeProfile(_ uuid: String, _ name: String, pages: [(String, String)]) {
    let dir = profilesDir + "/\(uuid).sdProfile"
    for (id, json) in pages {
        try? FileManager.default.createDirectory(atPath: dir + "/Profiles/\(id)", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/Profiles/\(id)/manifest.json", contents: Data(json.utf8))
    }
    FileManager.default.createFile(atPath: dir + "/manifest.json", contents: Data(manifest(name, pages: pages.map(\.0)).utf8))
}

// Fixture A: a channel-2 Latch profile, 4 keys on one page (like the XL service decks, much smaller).
let uuidA = "AAAAAAAA-1111-4111-8111-111111111111"
writeProfile(uuidA, "Lightkey XL Service", pages: [("AAAAAAAA-0000-4000-8000-000000000001",
    page(["0,0": midiKey(ch: 2, note: 1), "1,0": midiKey(ch: 2, note: 2), "2,0": midiKey(ch: 2, note: 3), "3,0": midiKey(ch: 2, note: 4)]))])
// Fixture B: multi-channel, two pages, Hold and Push keys, one key made with plugin 4.2.
let uuidB = "BBBBBBBB-2222-4222-8222-222222222222"
writeProfile(uuidB, "Summit Test", pages: [
    ("BBBBBBBB-0000-4000-8000-000000000001", page(["0,0": midiKey(ch: 5, note: 3), "1,0": midiKey(ch: 6, note: 38, mode: "Hold")])),
    ("BBBBBBBB-0000-4000-8000-000000000002", page(["0,0": midiKey(ch: 13, note: 7, mode: "Push", version: "4.2.0.4")]))])
// Fixture C: the same name as A with A's keys plus a text key and an empty page (Controllers null) and a
// stray key that sends elsewhere.
let uuidC = "CCCCCCCC-3333-4333-8333-333333333333"
writeProfile(uuidC, "Lightkey XL Service", pages: [
    ("CCCCCCCC-0000-4000-8000-000000000001", page(["0,0": midiKey(ch: 2, note: 1), "1,0": textKey, "2,0": midiKey(ch: 2, note: 9, out: "Deck Sniffer")])),
    ("CCCCCCCC-0000-4000-8000-000000000002", #"{"Controllers":null,"Name":""}"#)])
// A folder that isn't a profile Booth Check can read.
try? FileManager.default.createDirectory(atPath: profilesDir + "/DDDDDDDD-4444-4444-8444-444444444444.sdProfile", withIntermediateDirectories: true)
FileManager.default.createFile(atPath: profilesDir + "/DDDDDDDD-4444-4444-8444-444444444444.sdProfile/manifest.json", contents: Data("[1,2]".utf8))

// 1. Reading the profiles: keys, channels, ports, plugin versions, signature.
let read = readDeckProfiles(supportDir: root)
let a = read.profiles.first { $0.uuid == uuidA.lowercased() }, b = read.profiles.first { $0.uuid == uuidB.lowercased() }
let c = read.profiles.first { $0.uuid == uuidC.lowercased() }
expect("three profiles read, the broken one listed as unreadable", read.profiles.count == 3 && read.unreadable.count == 1 && read.problem == nil,
       "\(read.profiles.map(\.name)) \(read.unreadable) \(read.problem ?? "")")
expect("uuid is the folder's, lower case", a != nil && c != nil)
expect("name, device, model", a?.name == "Lightkey XL Service" && a?.device == deckID && a?.model == "20GAT9902")
expect("A: 4 Latch keys on channel 2 (g47 is 0-based)", a?.keys.count == 4 && a?.channels == [2] && a?.keys.allSatisfy { $0.mode == "Latch" } == true,
       "\(a?.keys ?? [])")
expect("A: ports and plugin", a?.inPorts == ["Lightkey Output"] && a?.outPorts == ["Lightkey Input"] && a?.pluginVersions == ["4.3.0.1"])
expect("B: keys across both pages, channels 5, 6, 13", b?.keys.count == 3 && b?.channels == [5, 6, 13], "\(b?.channels ?? [])")
expect("B: both plugin versions seen", b?.pluginVersions == ["4.2.0.4", "4.3.0.1"], "\(b?.pluginVersions ?? [])")
expect("C: the text key and the empty page don't count", c?.keys.count == 2 && c?.pages == 2, "\(c?.keys.count ?? -1)")
expect("signature: sorted channel:note:mode:in>out", a?.signature == "2:1:Latch:Lightkey Output>Lightkey Input;2:2:Latch:Lightkey Output>Lightkey Input;2:3:Latch:Lightkey Output>Lightkey Input;2:4:Latch:Lightkey Output>Lightkey Input",
       a?.signature ?? "")
expect("signature hash: 10 hex, differs between A and C", a?.sigHash.count == 10 && a?.sigHash != c?.sigHash)
// The same keys in another order and on other pages give the same signature; a duplicate key doesn't change it.
let moved = parseDeckProfile(uuid: "x", manifest: Data(manifest("Moved", pages: ["P1"]).utf8),
                             pages: [Data(page(["4,3": midiKey(ch: 2, note: 4), "0,1": midiKey(ch: 2, note: 1)]).utf8),
                                     Data(page(["0,0": midiKey(ch: 2, note: 2), "1,0": midiKey(ch: 2, note: 3), "2,0": midiKey(ch: 2, note: 3)]).utf8)])
expect("moving keys about keeps the signature", moved?.sigHash == a?.sigHash, moved?.signature ?? "nil")
expect("a mode change changes it", parseDeckProfile(uuid: "x", manifest: Data(manifest("M", pages: ["P"]).utf8), pages: [Data(page([
    "0,0": midiKey(ch: 2, note: 1, mode: "Toggle"), "1,0": midiKey(ch: 2, note: 2), "2,0": midiKey(ch: 2, note: 3), "3,0": midiKey(ch: 2, note: 4)]).utf8)])?.sigHash != a?.sigHash)
expect("a manifest without Name or Device: not read", parseDeckProfile(uuid: "x", manifest: Data(#"{"Name":"x"}"#.utf8), pages: []) == nil)
expect("a page that isn't the shape: not read", parseDeckProfile(uuid: "x", manifest: Data(manifest("M", pages: ["P"]).utf8), pages: [Data(#"{"Controllers":"x"}"#.utf8)]) == nil)
expect("no profiles folder: a problem, not a failure", readDeckProfiles(supportDir: root + "/nothing").problem != nil)
let v2root = root + "/v2"
try? FileManager.default.createDirectory(atPath: v2root + "/ProfilesV2/EEEEEEEE-5555-4555-8555-555555555555.sdProfile", withIntermediateDirectories: true)
FileManager.default.createFile(atPath: v2root + "/ProfilesV2/EEEEEEEE-5555-4555-8555-555555555555.sdProfile/manifest.json", contents: Data(#"{"Actions":{}}"#.utf8))
let v2 = readDeckProfiles(supportDir: v2root)
expect("an older Stream Deck in another shape: can't read this version's profiles", v2.problem?.contains("ProfilesV2") == true && v2.profiles.isEmpty, v2.problem ?? "nil")
expect("the profile folder is found whatever the case", deckProfileFolder(uuid: uuidA.lowercased(), in: profilesDir)?.hasSuffix(uuidA + ".sdProfile") == true)
expect("no folder for an unknown uuid", deckProfileFolder(uuid: "00000000-0000-4000-8000-000000000000", in: profilesDir) == nil)

// 2. The picker's hints: duplicates by name are told apart.
let all = read.profiles
expect("hint: name, keys, channel", deckProfileHint(b!, among: all) == "Summit Test \u{00B7} 3 keys \u{00B7} channels 5, 6, 13", deckProfileHint(b!, among: all))
expect("channels as a range", channelsText([5, 6, 7, 8]) == "channels 5\u{2013}8" && channelsText([2]) == "channel 2" && channelsText([]) == "no MIDI channels")
let twin = DeckProfile(uuid: "ffffffff-0000-4000-8000-000000000000", name: a!.name, device: deckID, model: "", pages: 1, keys: a!.keys.reversed(), pluginVersions: [])
expect("same name and hint, different keys: the keys' hash", deckProfileHint(a!, among: all + [DeckProfile(uuid: "z", name: a!.name, device: deckID, model: "", pages: 1, keys: (1...4).map { DeckMIDIKey(channel: 2, note: $0 + 10, mode: "Latch", inPort: "", outPort: "") }, pluginVersions: [])]).contains("keys "))
expect("same keys too: the uuid", deckProfileHint(a!, among: all + [twin]).contains("id aaaaaaaa"))

// 3. Matching the saved choice: uuid, then keys, then name; more than one = can't tell.
let choiceA = DeckProfileChoice(a!)
expect("by uuid", matchDeckProfile(choiceA, in: all) == .found(a!, by: "uuid"))
let reimported = DeckProfileChoice(name: a!.name, uuid: "99999999-0000-4000-8000-000000000000", sigHash: a!.sigHash)
expect("re-imported under a new uuid: by keys", matchDeckProfile(reimported, in: all) == .found(a!, by: "keys"))
let editedElsewhere = DeckProfileChoice(name: "Summit Test", uuid: "99999999-0000-4000-8000-000000000000", sigHash: "0000000000")
expect("new uuid and new keys, one with the name: by name", matchDeckProfile(editedElsewhere, in: all) == .found(b!, by: "name"))
let twoNamed = DeckProfileChoice(name: "Lightkey XL Service", uuid: "99999999-0000-4000-8000-000000000000", sigHash: "0000000000")
if case .ambiguous(let list) = matchDeckProfile(twoNamed, in: all) { expect("two with the name: ambiguous", list.count == 2) } else { expect("two with the name: ambiguous", false) }
expect("two with the keys and the name: ambiguous", { if case .ambiguous = matchDeckProfile(reimported, in: all + [twin]) { return true }; return false }())
expect("gone: missing", matchDeckProfile(DeckProfileChoice(name: "Old", uuid: "99999999-0000-4000-8000-000000000000", sigHash: "1"), in: all) == .missing)

// 4. The preferences: which profile each deck is on.
let devices: [String: Any] = [deckID: ["DeviceName": "XL", "map_dev_brightness": 80,
                                       "ESDProfilesInfo": ["ESDProfilesPreferred": uuidB.lowercased(), "ESDProfilesSorting": "a,b"]],
                              "PreferredDevice": "@" + deckID, "@(0)[]": ["ESDProfilesInfo": ["ESDProfilesPreferred": "x"]]]
let pref = deckPreferredProfiles(devices)
expect("preferred per deck; PreferredDevice (a string) skipped", pref.problem == nil && pref.preferred[deckID] == uuidB.lowercased() && pref.preferred.count == 2, "\(pref)")
expect("upper case is lowered", deckPreferredProfiles([deckID: ["ESDProfilesInfo": ["ESDProfilesPreferred": uuidA]]]).preferred[deckID] == uuidA.lowercased())
expect("no Devices: a problem", deckPreferredProfiles(nil).problem != nil)
expect("Devices not a dictionary: a problem", deckPreferredProfiles(["a", "b"]).problem != nil)
expect("a deck without ESDProfilesInfo: just not listed", deckPreferredProfiles([deckID: ["DeviceName": "XL"]]).preferred.isEmpty)
expect("ESDProfilesPreferred not text: not listed", deckPreferredProfiles([deckID: ["ESDProfilesInfo": ["ESDProfilesPreferred": 3]]]).preferred.isEmpty)

// 5. The row.
func row(_ choice: DeckProfileChoice, _ preferred: [String: String], problem: String? = nil, failed: Bool = false, read r: DeckProfilesRead = read) -> Check {
    deckProfileCheck(choice: choice, read: r, preferred: preferred, prefsProblem: problem, writeFailed: failed)
}
let onA = row(choiceA, [deckID: a!.uuid])
expect("on the chosen profile: green", onA.status == .ok && onA.id == "deckProfile" && onA.group == "Stream Deck" && onA.action == nil, onA.detail)
let onB = row(choiceA, [deckID: b!.uuid])
expect("on another: red, names both", onB.status == .fail && onB.detail.contains("\u{201C}Summit Test\u{201D}") && onB.detail.contains("\u{201C}Lightkey XL Service\u{201D}"), onB.detail)
if case .switchDeckProfile(let dev, let to, let from, let name)? = onB.action {
    expect("its fix switches this deck from B to A", dev == deckID && to == a!.uuid && from == b!.uuid && name == a!.name)
} else { expect("its fix switches this deck from B to A", false, "\(String(describing: onB.action))") }
let stuck = row(choiceA, [deckID: b!.uuid], failed: true)
expect("the switch didn't stick: says to choose it in Stream Deck, no button", stuck.status == .fail && stuck.action == nil && stuck.fix?.contains("choose") == true)
let copyA = DeckProfile(uuid: "12121212-0000-4000-8000-000000000000", name: "Copy", device: deckID, model: "", pages: 1, keys: a!.keys, pluginVersions: ["4.3.0.1"])
var withCopy = read; withCopy.profiles.append(copyA)
let onCopy = row(choiceA, [deckID: copyA.uuid], read: withCopy)
expect("on a copy with the same keys: green", onCopy.status == .ok && onCopy.detail.contains("copy"), onCopy.detail)
expect("unknown preference: unknown, not a failure", row(choiceA, [:]).status == .unknown)
expect("preferences unreadable: unknown", row(choiceA, [deckID: a!.uuid], problem: "x").status == .unknown)
expect("profiles unreadable: unknown", row(choiceA, [deckID: a!.uuid], read: v2).status == .unknown)
let gone = row(DeckProfileChoice(name: "Old", uuid: "99999999-0000-4000-8000-000000000000", sigHash: "1"), [deckID: a!.uuid])
expect("not installed any more: red, This Mac", gone.status == .fail && gone.detail.contains("isn\u{2019}t in Stream Deck"), gone.detail)
expect("can't tell which: unknown", row(twoNamed, [deckID: a!.uuid]).status == .unknown)
let editedChoice = DeckProfileChoice(name: a!.name, uuid: a!.uuid, sigHash: "0123456789")
let edited = row(editedChoice, [deckID: a!.uuid])
expect("keys changed since chosen: orange, Use it as it is now", edited.status == .warn && edited.detail.contains("changed") && edited.action?.label == "Use it as it is now", edited.detail)
let onC = row(DeckProfileChoice(c!), [deckID: c!.uuid])
expect("a key that doesn't send to Lightkey Input: orange on the same row", onC.status == .warn && onC.detail.contains("Deck Sniffer"), onC.detail)
let onBright = row(DeckProfileChoice(b!), [deckID: b!.uuid])
expect("mixed and old plugin versions: orange", onBright.status == .warn && onBright.detail.contains("4.2.0.4") && onBright.detail.contains("older than 4.3"), onBright.detail)
let wrongAndWarn = row(DeckProfileChoice(c!), [deckID: a!.uuid])
expect("wrong profile and a warning: red, with the warning", wrongAndWarn.status == .fail && wrongAndWarn.detail.contains("Deck Sniffer"))
expect("plugin versions compare by number", pluginVersionAtLeast("4.3.0.1", [4, 3]) && pluginVersionAtLeast("4.10", [4, 3]) && !pluginVersionAtLeast("4.2.9", [4, 3]) && pluginVersionAtLeast("4.3", [4, 3]))

// 6. May Booth Check write? Only when the shape is exactly as expected and the target is installed.
expect("as expected: may write, current value given", { let g = deckPrefsWriteGuard(devices: devices, device: deckID, target: a!.uuid, targetFolderExists: true); return g.ok && g.current == uuidB.lowercased() }())
expect("target folder missing: no", !deckPrefsWriteGuard(devices: devices, device: deckID, target: a!.uuid, targetFolderExists: false).ok)
expect("target not a uuid: no", !deckPrefsWriteGuard(devices: devices, device: deckID, target: "Lightkey XL Service", targetFolderExists: true).ok)
expect("no Devices: no", !deckPrefsWriteGuard(devices: nil, device: deckID, target: a!.uuid, targetFolderExists: true).ok)
expect("Devices an array: no", !deckPrefsWriteGuard(devices: [1, 2], device: deckID, target: a!.uuid, targetFolderExists: true).ok)
expect("deck not listed: no", !deckPrefsWriteGuard(devices: devices, device: "@(1)[4057/143/OTHER]", target: a!.uuid, targetFolderExists: true).ok)
expect("ESDProfilesInfo missing: no", !deckPrefsWriteGuard(devices: [deckID: ["DeviceName": "XL"]], device: deckID, target: a!.uuid, targetFolderExists: true).ok)
expect("ESDProfilesPreferred missing: no", !deckPrefsWriteGuard(devices: [deckID: ["ESDProfilesInfo": ["ESDProfilesSorting": "a"]]], device: deckID, target: a!.uuid, targetFolderExists: true).ok)
expect("ESDProfilesPreferred a number: no", !deckPrefsWriteGuard(devices: [deckID: ["ESDProfilesInfo": ["ESDProfilesPreferred": 1]]], device: deckID, target: a!.uuid, targetFolderExists: true).ok)

// 7. The new Devices value: only that one string changes.
let changed = deckDevicesSetting(devices, device: deckID, preferred: uuidA)
let newDeck = changed?[deckID] as? [String: Any], newInfo = newDeck?["ESDProfilesInfo"] as? [String: Any]
expect("the preferred profile is the new one, lower case", newInfo?["ESDProfilesPreferred"] as? String == uuidA.lowercased())
expect("its other keys are kept", newInfo?["ESDProfilesSorting"] as? String == "a,b" && newDeck?["DeviceName"] as? String == "XL" && newDeck?["map_dev_brightness"] as? Int == 80)
expect("the other entries are kept", changed?["PreferredDevice"] as? String == "@" + deckID
       && ((changed?["@(0)[]"] as? [String: Any])?["ESDProfilesInfo"] as? [String: Any])?["ESDProfilesPreferred"] as? String == "x"
       && changed?.count == devices.count)
expect("the same shape as before (round-trips as a plist)", (try? PropertyListSerialization.data(fromPropertyList: changed ?? [:], format: .binary, options: 0)) != nil)
expect("unexpected shape: nothing built", deckDevicesSetting([deckID: ["DeviceName": "XL"]], device: deckID, preferred: uuidA) == nil
       && deckDevicesSetting(devices, device: "@(1)[4057/143/OTHER]", preferred: uuidA) == nil)
let undo = deckDevicesSetting(changed!, device: deckID, preferred: uuidB)
expect("undo with the old uuid gives the first value back",
       ((undo?[deckID] as? [String: Any])?["ESDProfilesInfo"] as? [String: Any])?["ESDProfilesPreferred"] as? String == uuidB.lowercased())
let steps = deckProfileSwitchSteps(device: deckID, to: a!.uuid)
expect("the sheet's steps quit, write the one value, reopen, read back",
       ["Quit Stream Deck", "ESDProfilesPreferred = \"\(a!.uuid)\"", "CFPreferencesSetAppValue", "Open Stream Deck", "read ESDProfilesPreferred back"].allSatisfy(steps.contains))

// 8. Saved setups: the choice survives a save; older saves have none.
var setup = MacSetup()
expect("old save: no profile", (try? JSONDecoder().decode(MacSetup.self, from: Data(#"{"lightkey":true}"#.utf8)))?.deckProfile == nil)
setup.deckProfile = choiceA
let back = try? JSONDecoder().decode(MacSetup.self, from: try! JSONEncoder().encode(setup))
expect("the choice survives a save", back?.deckProfile == choiceA)
expect("a broken choice doesn't lose the rest of the setup",
       (try? JSONDecoder().decode(MacSetup.self, from: Data(#"{"lightkey":false,"deckProfile":{"name":3}}"#.utf8))).map { $0.deckProfile == nil && !$0.lightkey } == true)

// 9. The deck lights helper's installed arguments.
let expected = ["--mask", "5:3-6", "--while", "6:38-39", "--alias", "5:22=5:40"]
let plist = try! PropertyListSerialization.data(fromPropertyList: ["Label": IDs.deckHelper, "ProgramArguments": [deckHelperBinary] + expected], format: .xml, options: 0)
expect("ProgramArguments read from the plist", installedHelperArgs(plist) == [deckHelperBinary] + expected)
expect("the same: current", deckHelperArgsCurrent(installed: installedHelperArgs(plist), expected: expected) == true)
expect("other rules: not current", deckHelperArgsCurrent(installed: installedHelperArgs(plist), expected: deckHelperArgs) == false)
expect("another binary: not current", deckHelperArgsCurrent(installed: ["/tmp/x"] + expected, expected: expected) == false)
expect("no plist: can't tell", deckHelperArgsCurrent(installed: installedHelperArgs(nil), expected: expected) == nil)
expect("what Booth Check writes reads back as current", deckHelperArgsCurrent(installed: installedHelperArgs(Data(deckHelperPlistXML(args: expected).utf8)), expected: expected) == true)
let old = deckHelperCheck(installed: true, loaded: true, state: "running", feedbackPort: true, argsCurrent: false)
expect("running with old settings: orange, Install / update", old.status == .warn && old.detail.contains("old settings") && old.action?.label == "Install\u{2026}", old.detail)
expect("running with the right settings: green", deckHelperCheck(installed: true, loaded: true, state: "running", feedbackPort: true, argsCurrent: true).status == .ok)
expect("not running: still the restart, whatever the settings",
       deckHelperCheck(installed: true, loaded: true, state: "not running", feedbackPort: false, argsCurrent: false).status == .fail)
expect("verdict counts the --alias rules of the args given",
       deckHelperStartVerdict("deck_state_helper up\n", final: false, args: ["--channels", "2"])?.ok == true
       && deckHelperStartVerdict("deck_state_helper up\n", final: false, args: expected) == nil)

// 10. The show's .deck.json.
func parse(_ s: String) -> (file: DeckShowFile, warnings: [String]) { parseDeckShowFile(Data(s.utf8)) }
let full = parse(#"{"helper":{"channels":"2","mask":"2:3-6","while":"2:38-39","alias":"2:22=2:40,2:23=2:41"},"profile":"Lightkey XL Service","notes":"ignored"}"#)
expect("full file: the helper's args in order, the profile", full.file.helperArgs == ["--channels", "2", "--mask", "2:3-6", "--while", "2:38-39", "--alias", "2:22=2:40,2:23=2:41"]
       && full.file.helperFromFile && full.file.profile == "Lightkey XL Service" && full.warnings.isEmpty, "\(full)")
let none = parse(#"{"helper":null,"profile":"Lightkey XL Service"}"#)
expect("helper null: this show doesn't use it", none.file.helperArgs == nil && none.warnings.isEmpty)
let noHelperKey = parse(#"{"profile":"X"}"#)
expect("no helper key: the built-in rules", noHelperKey.file.helperArgs == deckHelperArgs && !noHelperKey.file.helperFromFile && noHelperKey.file.profile == "X")
expect("channels only", parse(#"{"helper":{"channels":"5-13"}}"#).file.helperArgs == ["--channels", "5-13"])
expect("empty strings count as absent", parse(#"{"helper":{"channels":"2","alias":""}}"#).file.helperArgs == ["--channels", "2"])
for (bad, why) in [(#"{"helper":{"channels":"17"}}"#, "channel out of range"), (#"{"helper":{"channels":"9-5"}}"#, "backwards range"),
                   (#"{"helper":{"channels":2}}"#, "a number, not text"), (#"{"helper":{"mask":"5:3-6"}}"#, "mask without while"),
                   (#"{"helper":{"mask":"5:3-6","while":"6:200"}}"#, "note out of range"), (#"{"helper":{"channels":"2","mask":"5:3","while":"2:4"}}"#, "outside the channels"),
                   (#"{"helper":{"alias":"5:22-23=5:40"}}"#, "alias with a range"), (#"{"helper":{"alias":"5:22"}}"#, "alias without ="),
                   (#"{"helper":"yes"}"#, "helper not an object"), ("not json", "not JSON"), ("[1]", "not an object")] {
    let r = parse(bad)
    expect("bad (\(why)): built-in rules, warned", r.file.helperArgs == deckHelperArgs && !r.file.helperFromFile && !r.warnings.isEmpty, "\(r)")
}
expect("profile not text: ignored with a warning", { let r = parse(#"{"profile":5}"#); return r.file.profile == nil && r.warnings.count == 1 }())
expect("the file sits next to the show", deckShowFilePath(forShow: "/S/BackupChurch_modular_v38.lightkeyproj") == "/S/BackupChurch_modular_v38.deck.json")
let showPath = root + "/Show_v1.lightkeyproj"
expect("no file: nothing, so exactly today's behaviour", loadDeckShowFile(forShow: showPath) == nil && loadDeckShowFile(forShow: nil) == nil)
FileManager.default.createFile(atPath: root + "/Show_v1.deck.json", contents: Data(#"{"helper":null}"#.utf8))
expect("a file next to the show is read", loadDeckShowFile(forShow: showPath)?.file.helperArgs == nil)
expect("the log line says the helper isn't used", deckShowFileText(loadDeckShowFile(forShow: showPath)).contains("doesn\u{2019}t use"))

try? FileManager.default.removeItem(atPath: root)
print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
