import Foundation

// The Stream Deck profile mends itself (Nov 2026): the health check, the last-good copy (made only when
// healthy and changed, one copy), Stream Deck's own launch question, the restore (swap, the broken one kept aside, byte-identical after),
// when it runs by itself and when it waits for a person, and the row's text. Run with tests/run.sh.
// Fixtures are synthetic profile folders in a temporary folder, in the shape Stream Deck 7.6 writes
// (ProfilesV3/<UUID>.sdProfile: manifest.json, Profiles/<PAGE>/manifest.json, Images/); nothing on
// this Mac is read or changed.
var failures = 0
func expect(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print((ok ? "PASS  " : "FAIL  ") + name + (ok ? "" : "   (got: \(got()))"))
    if !ok { failures += 1 }
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("deckrepair-\(getpid())").path
try? fm.removeItem(atPath: root)
let profiles = root + "/ProfilesV3"
let backups = root + "/deck-backups"
let UUIDU = "AAAAAAAA-1111-4111-8111-111111111111"
let uuid = UUIDU.lowercased()
let dir = profiles + "/\(UUIDU).sdProfile"
let store = DeckCopyStore(root: backups, uuid: uuid)
let P1 = "11111111-AAAA-4AAA-8AAA-AAAAAAAAAAA1", P2 = "22222222-AAAA-4AAA-8AAA-AAAAAAAAAAA2", PD = "33333333-AAAA-4AAA-8AAA-AAAAAAAAAAA3"

func midi(_ title: String, note: Int, state: Int = 0) -> String {
    #"{"ActionID":"\#(title)","LinkedTitle":true,"Name":"Generic Midi","Plugin":{"Name":"Midi","UUID":"se.trevligaspel.midi","Version":"4.4.0.0"},"Resources":null,"Settings":{"g02":"Latch","g45":"\#(note)","g47":"1","smi":"Lightkey Output","smo":"Lightkey Input"},"State":\#(state),"States":[{"Image":"Images/k.png","Title":"\#(title)"},{"Image":"Images/k.png","Title":"\#(title)"}],"UUID":"se.trevligaspel.midi.genericmidi"}"#
}
func page(_ keys: [(String, String)]) -> String {
    #"{"Controllers":[{"Actions":{"# + keys.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + #"},"Type":"Keypad"}],"Icon":"","Name":""}"#
}
let emptyPage = #"{"Controllers":[{"Actions":null,"Type":"Keypad"}],"Icon":"","Name":""}"#
let manifest = #"{"Device":{"Model":"20GAT9902","UUID":"@(1)[4057/143/TEST]"},"Name":"Service","Pages":{"Current":"\#(P1.lowercased())","Default":"\#(PD.lowercased())","Pages":["\#(P1.lowercased())","\#(P2.lowercased())"]},"Version":"2.0"}"#
func write(_ rel: String, _ s: String) {
    let path = dir + "/" + rel
    try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    fm.createFile(atPath: path, contents: Data(s.utf8))
}
func text(_ path: String) -> String { String(decoding: fm.contents(atPath: path) ?? Data(), as: UTF8.self) }
let page1 = page([("0,0", midi("Default", note: 0, state: 1)), ("1,0", midi("Prayer", note: 1))])
let page2 = page([("0,0", midi("Lavender", note: 5))])
func makeProfile() {
    try? fm.removeItem(atPath: dir)
    write("manifest.json", manifest)
    write("Profiles/\(P1)/manifest.json", page1)
    write("Profiles/\(P2)/manifest.json", page2)
    write("Profiles/\(PD)/manifest.json", emptyPage)
    write("Images/k.png", "PNG-BYTES")
    write("Profiles/\(P1)/Images/k.png", "PNG-PAGE")
}
makeProfile()

// --- deckProfileHealth -----------------------------------------------------------------------------
guard case .healthy(let hp) = deckProfileHealth(dir: dir, expectKeys: true) else {
    print("FAIL  the fixture profile is healthy: \(deckProfileHealth(dir: dir, expectKeys: true))"); exit(1)
}
expect("a healthy profile reads as healthy, with its 3 MIDI keys and 3 pages", hp.keys.count == 3 && hp.pages == 3 && hp.name == "Service", "\(hp.keys.count) \(hp.pages)")
expect("a missing folder is missing", deckProfileHealth(dir: profiles + "/NOPE.sdProfile", expectKeys: false) == .missing)

// --- the first snapshot -------------------------------------------------------------------------------
var t0 = Date(timeIntervalSince1970: 1_800_000_000)
let s1 = snapshotDeckProfile(dir: dir, store: store, deckRunning: { false }, now: t0)
guard case .saved(let c1, let replaced1) = s1 else { print("FAIL  first snapshot saved: \(s1)"); exit(1) }
expect("healthy → the first copy is saved", replaced1 == nil && c1.keys == 3 && c1.pages == 3 && c1.folder == "\(UUIDU).sdProfile")
expect("…the copy is byte for byte the profile", deckTreesIdentical(store.goodFolder ?? "", dir))
expect("…good.json reads back with its date", store.good == c1 && store.good?.savedAt == t0)

// Unchanged: nothing is copied again.
let goodMtime = (try? fm.attributesOfItem(atPath: store.goodDir))?[.modificationDate] as? Date
let s2 = snapshotDeckProfile(dir: dir, store: store, deckRunning: { false }, now: t0.addingTimeInterval(60))
expect("unchanged → no new copy", s2 == .unchanged(c1), "\(s2)")
expect("…the copy's folder is untouched", ((try? fm.attributesOfItem(atPath: store.goodDir))?[.modificationDate] as? Date) == goodMtime)

// The key reset alone isn't a change (saved lit states count as dark in the hash).
_ = clearDeckKeyStates(profileDir: dir, deckRunning: { false })
expect("the reset did change the file", text(dir + "/Profiles/\(P1)/manifest.json") != page1)
expect("…but the content hash is the same", deckProfileContentHash(dir: dir)?.hash == c1.hash)
expect("…so still no new copy", snapshotDeckProfile(dir: dir, store: store, deckRunning: { false }) == .unchanged(c1))

// Stream Deck running: no copy, nothing written.
expect("Stream Deck running → no snapshot", snapshotDeckProfile(dir: dir, store: store, deckRunning: { true }) == .skipped("Stream Deck is running"))

// --- an edit by the tech: a healthy, changed profile is the new last-good, never "repaired" --------
write("Profiles/\(P2)/manifest.json", page([("0,0", midi("Lavender Haze", note: 5))]))     // a new title, same keys
let edited = deckProfileHealth(dir: dir, expectKeys: true)
expect("an edited profile is healthy", { if case .healthy = edited { return true }; return false }())
expect("…and the decision is keep, not restore, even with a copy", deckMendDecision(health: edited, hasCopy: true, deckRunning: false, automatic: true, restoresSoFar: 0) == .keep)
t0 = t0.addingTimeInterval(3600)
let s3 = snapshotDeckProfile(dir: dir, store: store, deckRunning: { false }, now: t0)
guard case .saved(_, let replaced3) = s3 else { print("FAIL  edit snapshot: \(s3)"); exit(1) }
expect("…its copy replaces the old one", replaced3 == c1)
expect("…the new copy has the edit", text(store.goodFolder! + "/Profiles/\(P2)/manifest.json").contains("Lavender Haze"))

// A second edit: still one copy, nothing else left in its folder.
write("Images/k.png", "PNG-BYTES-2")
t0 = t0.addingTimeInterval(3600)
guard case .saved(let c4, _) = snapshotDeckProfile(dir: dir, store: store, deckRunning: { false }, now: t0) else { print("FAIL  2nd edit"); exit(1) }
let slots = ((try? fm.contentsOfDirectory(atPath: store.dir)) ?? []).sorted()
expect("one copy only: good and good.json", slots == ["good", "good.json"] && store.good == c4 && deckTreesIdentical(store.goodFolder!, dir), "\(slots)")

// --- broken: a page manifest that isn't JSON -------------------------------------------------------
let goodNow = store.goodFolder!
let beforeBreak = text(dir + "/Profiles/\(P1)/manifest.json")
write("Profiles/\(P1)/manifest.json", "{\"Controllers\":[{\"Act")             // cut off half-way
let broken = deckProfileHealth(dir: dir, expectKeys: true)
expect("a cut-off page manifest is broken", { if case .broken(let w) = broken { return w.contains("isn\u{2019}t JSON") }; return false }(), "\(broken)")
expect("…the snapshot refuses it", { if case .skipped(let w) = snapshotDeckProfile(dir: dir, store: store, deckRunning: { false }) { return w.contains("isn\u{2019}t healthy") }; return false }())
expect("…and the copy is untouched", store.good == c4)
expect("broken + copy + Stream Deck closed → restore", deckMendDecision(health: broken, hasCopy: true, deckRunning: false, automatic: true, restoresSoFar: 0) == .restore)
expect("broken + Stream Deck running → no automatic action", deckMendDecision(health: broken, hasCopy: true, deckRunning: true, automatic: true, restoresSoFar: 0) == .leave("Stream Deck is running"))
let runningTry = restoreDeckProfile(uuid: uuid, profilesFolder: profiles, store: store, deckRunning: { true })
expect("…and the restore itself refuses while it runs, changing nothing", !runningTry.ok && text(dir + "/Profiles/\(P1)/manifest.json").hasPrefix("{\"Controllers\":[{\"Act"))

let t5 = t0.addingTimeInterval(60)
let r1 = restoreDeckProfile(uuid: uuid, profilesFolder: profiles, store: store, deckRunning: { false }, now: t5)
expect("the restore works and says so", r1.ok && r1.identical, r1.text)
expect("…the profile is now byte for byte the last-good copy", deckTreesIdentical(dir, goodNow))
expect("…and healthy again", { if case .healthy = deckProfileHealth(dir: dir, expectKeys: true) { return true }; return false }())
expect("…the broken one is kept aside in Booth Check's folder, as it was", r1.setAside.map { text($0 + "/Profiles/\(P1)/manifest.json").hasPrefix("{\"Controllers\":[{\"Act") && $0.hasPrefix(store.setAside) } == true, r1.setAside ?? "nil")
expect("…the rest of the broken one went aside too", r1.setAside.map { text($0 + "/Images/k.png") == "PNG-BYTES-2" } == true)
expect("…no temporary folder left next to the profile", ((try? fm.contentsOfDirectory(atPath: profiles)) ?? []) == ["\(UUIDU).sdProfile"])
expect("…the copy itself is untouched", store.good == c4)
_ = beforeBreak

// Restoring again when it already matches: nothing moves.
let r2 = restoreDeckProfile(uuid: uuid, profilesFolder: profiles, store: store, deckRunning: { false }, now: t5.addingTimeInterval(1))
let asideCount = ((try? fm.contentsOfDirectory(atPath: store.setAside)) ?? []).count
expect("already identical → nothing swapped, nothing set aside", r2.ok && r2.setAside == nil && asideCount == 1, "\(r2) \(asideCount)")

// --- missing folder ----------------------------------------------------------------------------------
try? fm.moveItem(atPath: dir, toPath: root + "/gone.sdProfile")         // "deleted" (kept for the test)
expect("a profile folder that's gone is missing → restore", deckDiskState(uuid: uuid, read: DeckProfilesRead(folder: profiles), root: backups).health == .missing
       && deckMendDecision(health: .missing, hasCopy: true, deckRunning: false, automatic: true, restoresSoFar: 0) == .restore)
let r3 = restoreDeckProfile(uuid: uuid, profilesFolder: profiles, store: store, deckRunning: { false }, now: t5.addingTimeInterval(2))
expect("…it comes back under its own name, byte for byte the copy", r3.ok && r3.setAside == nil && deckTreesIdentical(dir, goodNow), r3.text)

// --- a page folder gone, no keys left, unknown shape ---------------------------------------------------
try? fm.moveItem(atPath: dir + "/Profiles/\(P2)", toPath: root + "/P2-gone")
expect("a listed page folder gone is broken", { if case .broken(let w) = deckProfileHealth(dir: dir, expectKeys: true) { return w.contains("is missing") }; return false }())
_ = restoreDeckProfile(uuid: uuid, profilesFolder: profiles, store: store, deckRunning: { false }, now: t5.addingTimeInterval(3))
write("Profiles/\(P1)/manifest.json", emptyPage)
write("Profiles/\(P2)/manifest.json", emptyPage)
expect("no MIDI keys left when the copy had some: broken", deckProfileHealth(dir: dir, expectKeys: true) == .broken("it has no MIDI keys left"))
expect("…but fine for a profile that never had any", { if case .healthy = deckProfileHealth(dir: dir, expectKeys: false) { return true }; return false }())
write("manifest.json", #"{"Name":"Service","Device":{"UUID":"x"},"Layout":{}}"#)
let odd = deckProfileHealth(dir: dir, expectKeys: true)
expect("JSON in a shape Booth Check doesn't know is unknownShape, never restored",
       { if case .unknownShape = odd { return true }; return false }() && !odd.isBroken
       && { if case .leave = deckMendDecision(health: odd, hasCopy: true, deckRunning: false, automatic: true, restoresSoFar: 0) { return true }; return false }())
write("manifest.json", "")
expect("an empty manifest.json is broken", { if case .broken = deckProfileHealth(dir: dir, expectKeys: false) { return true }; return false }())

// --- the bounds -----------------------------------------------------------------------------------------
expect("automatic restores stop after 3 a session", { if case .leave = deckMendDecision(health: .missing, hasCopy: true, deckRunning: false, automatic: true, restoresSoFar: 3) { return true }; return false }())
expect("…a person's button still can", deckMendDecision(health: .missing, hasCopy: true, deckRunning: false, automatic: false, restoresSoFar: 3) == .restore)
// A tech deleted the service profile in Stream Deck and imported another: Stream Deck no longer names
// it, so it doesn't come back by itself (the row offers Restore…); a lost one it still names does.
expect("missing and Stream Deck still names it → restore", deckStillPreferred(uuid.uppercased(), preferred: ["d": uuid])
       && deckMendDecision(health: .missing, hasCopy: true, deckRunning: false, automatic: true, restoresSoFar: 0, stillPreferred: true) == .restore)
expect("missing and no longer named → left for a person", !deckStillPreferred(uuid, preferred: ["d": "cccc"])
       && { if case .leave = deckMendDecision(health: .missing, hasCopy: true, deckRunning: false, automatic: true, restoresSoFar: 0, stillPreferred: false) { return true }; return false }())
expect("…the Restore… button still can", deckMendDecision(health: .missing, hasCopy: true, deckRunning: false, automatic: false, restoresSoFar: 0, stillPreferred: false) == .restore)
expect("…and a damaged one that's there still comes back", deckMendDecision(health: .broken("x"), hasCopy: true, deckRunning: false, automatic: true, restoresSoFar: 0, stillPreferred: false) == .restore)
expect("no copy → noCopy", deckMendDecision(health: .missing, hasCopy: false, deckRunning: false, automatic: true, restoresSoFar: 0) == .noCopy)
expect("one retry after launch when it broke again", deckRelaunchRetryAllowed(attempt: 0, health: .broken("x"), hasCopy: true))
expect("…never a second", !deckRelaunchRetryAllowed(attempt: 1, health: .broken("x"), hasCopy: true))
expect("…none when it's healthy or there's no copy", !deckRelaunchRetryAllowed(attempt: 0, health: .healthy(hp), hasCopy: true)
       && !deckRelaunchRetryAllowed(attempt: 0, health: .missing, hasCopy: false))

// --- which profiles, and the row ------------------------------------------------------------------------
let choice = DeckProfileChoice(hp)
let readOK = DeckProfilesRead(profiles: [hp], folder: profiles)
expect("chosen and installed: that one", deckProfilesToMend(choice: choice, read: readOK, preferred: [:], hasCopy: { _ in false }).map(\.uuid) == [uuid])
expect("chosen and gone: its own UUID, so its copy can come back",
       deckProfilesToMend(choice: choice, read: DeckProfilesRead(profiles: [], folder: profiles), preferred: [:], hasCopy: { _ in false }).map(\.uuid) == [uuid])
// Dev Mac, 15 Nov 2026: the chosen profile's own folder was there but broken, and another profile had
// the same keys; that other one was taken for it. Its own folder wins.
let twin = DeckProfile(uuid: "bbbbbbbb-2222-4222-8222-222222222222", name: "Twin", device: "d", model: "", pages: 3, keys: hp.keys, pluginVersions: [])
let readTwin = DeckProfilesRead(profiles: [twin], folder: profiles, unreadable: ["\(UUIDU).sdProfile"])
expect("chosen folder there but unreadable, a twin with the same keys: the chosen one, not the twin",
       deckProfilesToMend(choice: choice, read: readTwin, preferred: [:], hasCopy: { _ in true }).map(\.uuid) == [uuid])
expect("…while with its folder really gone, the twin (a re-import) is it",
       deckProfilesToMend(choice: DeckProfileChoice(name: "Service", uuid: "cccccccc-0000-4000-8000-000000000000", sigHash: hp.sigHash),
                          read: readTwin, preferred: [:], hasCopy: { _ in true }).map(\.uuid) == [twin.uuid])
expect("none chosen: each deck's preferred profile that is there or has a copy",
       deckProfilesToMend(choice: nil, read: readOK, preferred: ["d": uuid, "e": "zzzz", "f": "cccc"], hasCopy: { $0 == "cccc" }).map(\.uuid) == [uuid, "cccc"],
       "\(deckProfilesToMend(choice: nil, read: readOK, preferred: ["d": uuid, "e": "zzzz", "f": "cccc"], hasCopy: { $0 == "cccc" }).map(\.uuid))")

let date = deckCopyDateText(c4.savedAt)
let withCopy = deckProfileCheck(choice: choice, read: readOK, preferred: ["@(1)[4057/143/TEST]": uuid], prefsProblem: nil,
                                disk: (uuid, .broken("its page 11111111\u{2019}s manifest.json can\u{2019}t be read (it isn\u{2019}t JSON)"), c4))
expect("broken with a copy: red, says what's wrong", withCopy.status == .fail && withCopy.detail.contains("is damaged"), withCopy.detail)
expect("…the fix says what to press and names the copy's date", (withCopy.fix ?? "").hasPrefix("Click Restore the Stream Deck\u{2019}s keys\u{2026}") && (withCopy.fix ?? "").contains(date), withCopy.fix ?? "")
expect("…its button is Restore the Stream Deck's keys…", { if case .restoreDeckProfile(let u, let n)? = withCopy.action { return u == uuid && n == "Service" }; return false }()
       && withCopy.action?.label == "Restore the Stream Deck\u{2019}s keys\u{2026}")
let failedAgain = deckProfileCheck(choice: choice, read: readOK, preferred: [:], prefsProblem: nil, disk: (uuid, .missing, c4), repairFailed: true)
expect("missing after Booth Check's own try: says so, still offers the button", failedAgain.detail.contains("isn\u{2019}t in Stream Deck any more")
       && failedAgain.detail.contains("damaged again") && { if case .restoreDeckProfile? = failedAgain.action { return true }; return false }())
let noCopy = deckProfileCheck(choice: choice, read: DeckProfilesRead(profiles: [], folder: profiles), preferred: [:], prefsProblem: nil, disk: (uuid, .missing, nil))
expect("no copy: says so plainly and points at importing it again or This Mac", noCopy.status == .fail && noCopy.detail.contains("has no copy of it to put back yet")
       && (noCopy.fix ?? "").contains("Import it again") && { if case .openSetup? = noCopy.action { return true }; return false }(), noCopy.detail)
let healthyRow = deckProfileCheck(choice: choice, read: readOK, preferred: ["@(1)[4057/143/TEST]": uuid], prefsProblem: nil, disk: (uuid, .healthy(hp), c4))
expect("healthy and on it: green, no button", healthyRow.status == .ok && healthyRow.action == nil, healthyRow.detail)
expect("the steps name the copy, the swap and where the old one goes",
       deckRestoreSteps(name: "Service", copy: c4, profilesFolder: profiles, store: store).contains("RENAME_SWAP")
       && deckRestoreSteps(name: "Service", copy: c4, profilesFolder: profiles, store: store).contains(store.setAside))

// --- Stream Deck's own launch question, from its log (lines as Stream Deck 7.6 wrote them, 15 Nov 2026) ---
let verify = "2026-11-15T15:55:23.663+11:00  76268-4710622 StreamDeck  inf int main(int, char **)  Verify loaded data from last session\n"
let loss = "2026-11-15T15:55:23.663+11:00  76268-4710622 StreamDeck  war int main(int, char **)  Restored action count - data loss detected\n"
let propose = "2026-11-15T15:55:24.916+11:00  76268-4710622 StreamDeck  inf int main(int, char **)  Detected data loss - propose restore backup to user\n"
let loop = "2026-11-15T15:56:31.869+11:00  76608-4713483 StreamDeck  inf int main(int, char **)  Application event loop start\n"
expect("the question proposed and not answered yet: asking", streamDeckAsksToRestore(log: verify + loss + propose))
expect("…answered (the event loop started after it): not asking", !streamDeckAsksToRestore(log: verify + loss + propose + "restore finished: success\n" + loop))
expect("a clean launch: not asking", !streamDeckAsksToRestore(log: verify + loop))
expect("an empty log: not asking", !streamDeckAsksToRestore(log: ""))

try? fm.removeItem(atPath: root)
print(failures == 0 ? "test_deckrepair: all pass" : "test_deckrepair: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
