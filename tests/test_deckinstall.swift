import Foundation

// 1.27: Booth Check carries the deck lights helper, installs it, and restarts it by itself when it stops
// working (launchd still runs it). Run with tests/run.sh. Two checks compare against the Summit show's
// own files in the Lightkey-Skill repo when that's on this Mac, and say so when it isn't.
var failures = 0
func expect(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print((ok ? "PASS  " : "FAIL  ") + name + (ok ? "" : "   (got: \(got()))"))
    if !ok { failures += 1 }
}

// 1. The LaunchAgent: a valid plist that starts the installed copy with the show's rules, keeps it alive
//    whatever way it stops, and logs where Booth Check reads.
let xml = deckHelperPlistXML()
let plist = (try? PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil)) as? [String: Any] ?? [:]
expect("plist parses", !plist.isEmpty, xml)
expect("label", plist["Label"] as? String == IDs.deckHelper)
expect("runs the installed copy with the show's rules",
       plist["ProgramArguments"] as? [String] == [deckHelperBinary] + deckHelperArgs, "\(plist["ProgramArguments"] ?? "nil")")
expect("starts at login, always kept alive", plist["RunAtLoad"] as? Bool == true && plist["KeepAlive"] as? Bool == true)
expect("restarts within 2 s, not App Napped", plist["ThrottleInterval"] as? Int == 2 && plist["ProcessType"] as? String == "Interactive")
expect("logs to the file Booth Check reads", plist["StandardOutPath"] as? String == deckHelperLog && plist["StandardErrorPath"] as? String == deckHelperLog)

// 2. The script the sheet shows is the one that runs: stop the old copy (and any hand-started one holding
//    the lock), wait for launchd to let go, copy, unquarantine, write the plist, check it, start it.
let script = deckHelperInstallScript(from: "/Applications/Booth Check.app/Contents/Resources/deck_state_helper")
let steps = ["set -eu", "launchctl bootout \(deckHelperService)", "launchctl print \(deckHelperService)", "pkill -x deck_state_helper",
             "cp -f '/Applications/Booth Check.app/Contents/Resources/deck_state_helper'", "chmod 755", "xattr -d com.apple.quarantine",
             "<<'EOF'", "plutil -lint", "launchctl bootstrap \(deckHelperDomain)"]
let at = steps.map { script.range(of: $0)?.lowerBound }
expect("install script has every step", !at.contains(nil), steps.filter { !script.contains($0) }.joined(separator: " | "))
expect("in order", at.compactMap { $0 } == at.compactMap { $0 }.sorted())
expect("paths with spaces are quoted", script.contains("'\(deckHelperBinary)'"))
expect("the plist in the script is the plist", script.contains(xml))
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deckinstall-\(getpid())")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let scriptFile = dir.appendingPathComponent("s.sh")
try? script.write(to: scriptFile, atomically: true, encoding: .utf8)
expect("script is valid bash", shell("/bin/bash", ["-n", scriptFile.path]).code == 0)

// 3. Reading the new copy's start from its log.
let up = "2026-10-29T08:00:00Z  deck_state_helper up: repeating every 0.5 s, watchdog 5.0 s, pid 1\n"
let alias = "x  alias: deck key 5:22 shows what Lightkey reports on 5:40\nx  alias: deck key 5:23 shows what Lightkey reports on 5:41\n"
expect("still starting: no verdict yet", deckHelperStartVerdict("", final: false) == nil)
expect("up without its alias lines yet: wait", deckHelperStartVerdict(up, final: false) == nil)
expect("up with both alias lines: fine", deckHelperStartVerdict(up + alias, final: false)?.ok == true)
expect("up, no alias lines in time: an older helper", deckHelperStartVerdict(up, final: true).map { !$0.ok && $0.text.contains("older") } == true)
let waiting = "x  another deck_state_helper is running; waiting for it to stop\n"
expect("waiting on the lock: says so", deckHelperStartVerdict(waiting, final: true).map { !$0.ok && $0.text.contains("pkill") } == true)
expect("waiting, then took over: fine", deckHelperStartVerdict(waiting + "x  the other copy stopped; taking over\n" + up + alias, final: false)?.ok == true)
expect("could not create the port: fails at once", deckHelperStartVerdict("x  could not create the 'Lightkey Feedback' source (OSStatus -1); exiting\n", final: false)?.ok == false)
expect("bad args: fails at once", deckHelperStartVerdict("bad --alias x\n", final: false)?.ok == false)
expect("nothing at all: didn't start", deckHelperStartVerdict("", final: true)?.text.contains("didn\u{2019}t start") == true)

// 4. Restarting it by itself: only after 10 s of failing, at most once a minute and 3 times in 30 minutes,
//    so it can never cycle the deck's port.
expect("just failed: wait for launchd's own restart", !deckHelperAutoFix(failingFor: 3, fixes: []))
expect("failing 10 s: fix", deckHelperAutoFix(failingFor: 10, fixes: []))
expect("fixed 30 s ago: wait", !deckHelperAutoFix(failingFor: 60, fixes: [30]))
expect("fixed 2 min ago: again", deckHelperAutoFix(failingFor: 60, fixes: [120]))
expect("3 in 30 min: gave up", !deckHelperAutoFix(failingFor: 60, fixes: [100, 500, 900]) && deckHelperGaveUp(fixes: [100, 500, 900]))
expect("old ones don't count", deckHelperAutoFix(failingFor: 60, fixes: [100, 2000, 2500]) && !deckHelperGaveUp(fixes: [100, 2000, 2500]))

// 5. The row: says when Booth Check carries another version, quotes the log when red, says when it gave up.
let other = deckHelperCheck(installed: true, loaded: true, state: "running", feedbackPort: true, current: false)
expect("green with another version: still green, says so", other.status == .ok && other.detail.contains("different version"), other.detail)
expect("green, same version: quiet", !deckHelperCheck(installed: true, loaded: true, state: "running", feedbackPort: true, current: true).detail.contains("version"))
let red = deckHelperCheck(installed: true, loaded: true, state: "not running", feedbackPort: false, lastLog: "WATCHDOG: main loop silent")
expect("red quotes the log", red.detail.contains("WATCHDOG"), red.detail)
expect("red says Booth Check fixes it", (red.fix ?? "").contains("by itself"), red.fix ?? "nil")
let gave = deckHelperCheck(installed: true, loaded: true, state: "not running", feedbackPort: false, gaveUp: true)
expect("gave up: says what to do", (gave.fix ?? "").contains("3 times") && gave.action?.label == "Restart\u{2026}", gave.fix ?? "nil")

// 6. The copy it carries and the rules it passes are the Summit show's (when that repo is here).
let summit = NSHomeDirectory() + "/Claude/repos/Lightkey-Skill/LightKeyoutputs/summit2026/helper/"
if let installer = try? String(contentsOfFile: summit + "install_helper.sh", encoding: .utf8) {
    func value(_ name: String) -> String? {
        installer.split(separator: "\n").first { $0.hasPrefix("\(name)=\"") }.map { String($0.dropFirst(name.count + 2).dropLast()) }
    }
    expect("args match install_helper.sh", deckHelperArgs == ["--mask", value("MASK") ?? "?", "--while", value("WHILE") ?? "?", "--alias", value("ALIAS") ?? "?"],
           "\(value("MASK") ?? "nil") \(value("WHILE") ?? "nil") \(value("ALIAS") ?? "nil")")
    expect("installer keeps it alive the same way", installer.contains("<key>KeepAlive</key><true/>"))
    let carried = fileSHA256(FileManager.default.currentDirectoryPath + "/helper/deck_state_helper")
    expect("helper/deck_state_helper is the Summit build", carried != nil && carried == fileSHA256(summit + "deck_state_helper"),
           "\(carried ?? "nil") vs \(fileSHA256(summit + "deck_state_helper") ?? "nil")")
} else {
    print("SKIP  the Summit show's helper folder isn't on this Mac")
}

try? FileManager.default.removeItem(at: dir)
print(failures == 0 ? "test_deckinstall: all passed" : "test_deckinstall: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
