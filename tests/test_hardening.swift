import Foundation

// 1.30: the menu bar icon stays put, old apps don't reopen at start-up, and the shutdown quits the
// other apps first. Run with tests/run.sh, which compiles this next to a copy of BoothCheck.swift.
var failures = 0
func expect(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print((ok ? "PASS  " : "FAIL  ") + name + (ok ? "" : "   (got: \(got()))"))
    if !ok { failures += 1 }
}

// 1. Reading `defaults read com.apple.loginwindow TALLogoutSavesState` (stdout and stderr together).
let missing = "2026-11-13 23:37:48.366 defaults[83377:3606820] \nThe domain/default pair of (com.apple.loginwindow, TALLogoutSavesState) does not exist\n"
expect("not set: macOS's default, reopens", reopensAppsAtLogin(missing, code: 1) == true)
expect("0: doesn't reopen", reopensAppsAtLogin("0\n", code: 0) == false)
expect("1: reopens", reopensAppsAtLogin("1\n", code: 0) == true)
expect("a timestamp line first, then 0", reopensAppsAtLogin("2026-11-13 23:37:48.361 defaults[1:2] note\n0\n", code: 0) == false)
expect("some other error: can't tell", reopensAppsAtLogin("Couldn't start /usr/bin/defaults", code: -1) == nil)
expect("nonsense: can't tell", reopensAppsAtLogin("hello\n", code: 0) == nil)

let ok = reopenAppsCheck(false), bad = reopenAppsCheck(true), unknown = reopenAppsCheck(nil)
expect("row green when off", ok.status == .ok && ok.action == nil)
expect("row needs fixing when on, with the ChangeSheet fix", bad.status == .warn && bad.action.map { "\($0)" } == "stopReopeningApps",
       "\(bad.status) \(String(describing: bad.action))")
expect("row unknown when unreadable", unknown.status == .unknown)
expect("all three the same row", Set([ok.id, bad.id, unknown.id]) == ["reopen"])

let fix = reopenAppsCommands(reopen: false).map { commandLine("/usr/bin/defaults", $0) }
let undo = reopenAppsCommands(reopen: true).map { commandLine("/usr/bin/defaults", $0) }
expect("the fix: both settings off", fix == ["/usr/bin/defaults write com.apple.loginwindow TALLogoutSavesState -bool false",
                                             "/usr/bin/defaults write com.apple.loginwindow LoginwindowLaunchesRelaunchApps -bool false"], "\(fix)")
expect("the undo: both back on", undo == ["/usr/bin/defaults write com.apple.loginwindow TALLogoutSavesState -bool true",
                                          "/usr/bin/defaults write com.apple.loginwindow LoginwindowLaunchesRelaunchApps -bool true"], "\(undo)")

// 2. Which apps the shutdown asks to quit first.
let me = "app.boothcheck.BoothCheck"
let running: [RunningAppInfo] = [
    ("com.apple.finder", "Finder", true),
    (me, "Booth Check", false),
    (IDs.lightkey, "Lightkey", true),
    (IDs.streamDeck, "Stream Deck", true),
    ("com.google.Chrome", "Google Chrome", true),
    ("com.apple.mail", "Mail", true),
    ("com.apple.dock", "Dock", false),
    ("com.c3b.deckstatehelper", "deck_state_helper", false),
    (nil, "Some tool", true),
]
let quit = appsToQuitBeforeShutdown(running, selfID: me).map { running[$0].name }
expect("quits Chrome, Mail and a regular app without a bundle ID", quit == ["Google Chrome", "Mail", "Some tool"], "\(quit)")
expect("never Finder, Lightkey, Stream Deck or Booth Check", !quit.contains { ["Finder", "Lightkey", "Stream Deck", "Booth Check"].contains($0) })
expect("never background apps", !quit.contains("Dock") && !quit.contains("deck_state_helper"))
let selfRegular: [RunningAppInfo] = [(me, "Booth Check", true)]
expect("Booth Check itself, even with a Dock icon", appsToQuitBeforeShutdown(selfRegular, selfID: me).isEmpty)
expect("nothing else open: nothing to quit", appsToQuitBeforeShutdown([("com.apple.finder", "Finder", true)], selfID: me).isEmpty)

// 3. The start-up's "already open" list: everything with a Dock icon but Finder and Booth Check.
let open = otherRegularApps(running, selfID: me, skip: ["com.apple.finder"]).map { running[$0].name }
expect("already open at login: Lightkey and Stream Deck included", open == ["Lightkey", "Stream Deck", "Google Chrome", "Mail", "Some tool"], "\(open)")

// 4. The menu bar icon.
let saved: [String: Any] = ["NSStatusItem Visible Item-0": false, "NSStatusItem Visible Item-1": true,
                            "NSStatusItem Preferred Position Item-0": 1200, "showPath": "/x.lightkeyproj"]
expect("only a hidden icon's key is cleared", hiddenStatusItemKeys(saved) == ["NSStatusItem Visible Item-0"], "\(hiddenStatusItemKeys(saved))")
expect("nothing hidden: nothing cleared", hiddenStatusItemKeys(["NSStatusItem Visible Item-0": true]).isEmpty)

let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
let item = CGRect(x: 1200, y: 958, width: 30, height: 24)
expect("there, sized, on a screen: shown", menuIconShown(windowFound: true, frame: item, screens: [screen]))
expect("no status bar window: not shown", !menuIconShown(windowFound: false, frame: item, screens: [screen]))
expect("zero size: not shown", !menuIconShown(windowFound: true, frame: CGRect(x: 1200, y: 958, width: 0, height: 24), screens: [screen]))
expect("off every screen: not shown", !menuIconShown(windowFound: true, frame: CGRect(x: -5000, y: 958, width: 30, height: 24), screens: [screen]))
expect("no screens (clamshell, display off): not shown", !menuIconShown(windowFound: true, frame: item, screens: []))

expect("a window the size of the screen: full screen", coversAScreen([CGSize(width: 800, height: 600), CGSize(width: 1512, height: 982)],
                                                                      screens: [CGSize(width: 1512, height: 982)]))
expect("smaller windows: not full screen", !coversAScreen([CGSize(width: 1512, height: 950)], screens: [CGSize(width: 1512, height: 982)]))

var w = IconWatch()
var r = iconPass(w, shown: true)
expect("first pass, shown: logged once", r.log && !r.reinsert)
w = r.watch
r = iconPass(w, shown: true)
expect("still shown: not logged again", !r.log && !r.reinsert)
w = r.watch
r = iconPass(w, shown: false)
expect("gone: logged, not re-inserted yet", r.log && !r.reinsert && r.watch.missingPasses == 1)
w = r.watch
r = iconPass(w, shown: false)
expect("gone two passes running: re-insert, not logged again", !r.log && r.reinsert)
w = r.watch
r = iconPass(w, shown: false)
expect("still gone: re-inserted only once", !r.log && !r.reinsert && r.watch.missingPasses == 3)
w = r.watch
r = iconPass(w, shown: true)
expect("back: logged, count reset", r.log && !r.reinsert && r.watch == IconWatch(lastShown: true, missingPasses: 0, reinsertTried: false))
w = r.watch
_ = iconPass(w, shown: false)
r = iconPass(iconPass(w, shown: false).watch, shown: false)
expect("gone again later: one more try", r.reinsert)

// 1.31: SwiftUI writing the same isInserted back must not be stored (it looped the main thread).
expect("same value: not stored", !menuIconWriteNeeded(true, current: true) && !menuIconWriteNeeded(false, current: false))
expect("a real change: stored", menuIconWriteNeeded(false, current: true) && menuIconWriteNeeded(true, current: false))
expect("first 30 s: just Checking…", checkingTitle(waited: 29, waitingFor: "/usr/sbin/ioreg") == "Checking\u{2026}")
expect("after 30 s: says what it waits for", checkingTitle(waited: 31, waitingFor: "/usr/sbin/ioreg -p IOUSB") == "Still checking after 31 s: waiting for \u{201C}/usr/sbin/ioreg -p IOUSB\u{201D}",
       checkingTitle(waited: 31, waitingFor: "/usr/sbin/ioreg -p IOUSB"))

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
