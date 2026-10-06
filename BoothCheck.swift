// Booth Check — one window that says whether the lighting booth Mac is ready for a service.
//
// Every check here is something that has actually gone wrong in the booth, or would silently break a
// service: the Stream Deck app being put to sleep, the DMX interface missing, the wrong show version,
// the Mac sleeping, an old show opening at login. Each failed check says what to do about it.
//
// Nothing runs behind your back. Checks only read. A button that changes something first shows the
// exact command or script and waits for Run, and anything that would need the admin password opens
// System Settings instead. The Log window lists every command and its output.
//
// Nothing to install: it only uses what ships with macOS (pmset, defaults, ioreg, CoreMIDI,
// Accessibility, System Events). Build with build.sh; see README.md.

import AppKit
import ApplicationServices
import CoreMIDI
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Constants

enum IDs {
    static let lightkey = "de.monospc.Lightkey"
    static let streamDeck = "com.elgato.StreamDeck"
    static let elgatoVendor = 0x0FD9          // USB vendor ID on every Stream Deck
    static let ftdiVendor = 0x0403            // the chip inside Enttec Open DMX USB and most USB-DMX cables
    static let lightkeyMIDIInput = "Lightkey Input"
    static let showKey = "showPath"
    static let autoStartKey = "startShowAtLogin"
    static let setupKey = "macSetup"
    static let mutedKey = "mutedChecks"
}

/// Any other app a production Mac needs open, such as ProPresenter. Booth Check checks it's running
/// and opens it when the show starts.
struct ExtraApp: Codable, Equatable, Identifiable {
    var bundleID: String
    var name: String
    var on: Bool
    var id: String { bundleID }
}

/// What this Mac looks after. See Booth.applies(_:) for which checks each part covers.
struct MacSetup: Codable, Equatable {
    var lightkey = true         // Lightkey runs the show here
    var dmx = true              // ...with a DMX interface plugged into this Mac
    var streamDeck = true       // a Stream Deck controls Lightkey here
    var alwaysOn = true         // stays on for services: power, sleep, updates, login
    var apps: [ExtraApp] = []   // other apps to keep open, such as ProPresenter

    /// Apps worth offering on a production Mac when they're installed.
    static let knownApps = [("com.renewedvision.propresenter", "ProPresenter")]

    init(lightkey: Bool = true, dmx: Bool = true, streamDeck: Bool = true, alwaysOn: Bool = true, apps: [ExtraApp] = []) {
        (self.lightkey, self.dmx, self.streamDeck, self.alwaysOn, self.apps) = (lightkey, dmx, streamDeck, alwaysOn, apps)
    }

    // Setups saved before extra apps existed have no `apps`; offer the installed known apps then.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lightkey = try c.decodeIfPresent(Bool.self, forKey: .lightkey) ?? true
        dmx = try c.decodeIfPresent(Bool.self, forKey: .dmx) ?? true
        streamDeck = try c.decodeIfPresent(Bool.self, forKey: .streamDeck) ?? true
        alwaysOn = try c.decodeIfPresent(Bool.self, forKey: .alwaysOn) ?? true
        apps = try c.decodeIfPresent([ExtraApp].self, forKey: .apps) ?? MacSetup.suggestedApps(on: false)
    }

    static var saved: MacSetup? {
        UserDefaults.standard.data(forKey: IDs.setupKey).flatMap { try? JSONDecoder().decode(MacSetup.self, from: $0) }
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: IDs.setupKey) }
    }

    static func installed(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static func suggestedApps(on: Bool) -> [ExtraApp] {
        knownApps.filter { installed($0.0) }.map { ExtraApp(bundleID: $0.0, name: $0.1, on: on) }
    }

    /// A first guess for a Mac nobody has set up yet, from what's installed. The sheet confirms it.
    /// A Mac with ProPresenter but neither Lightkey nor Stream Deck is a presentation Mac, so
    /// ProPresenter starts switched on there; elsewhere it's listed, switched off.
    static func detected() -> MacSetup {
        let lightkey = installed(IDs.lightkey), deck = installed(IDs.streamDeck)
        let presentationOnly = !lightkey && !deck
        return MacSetup(lightkey: lightkey, dmx: deck, streamDeck: deck, alwaysOn: deck || presentationOnly,
                        apps: suggestedApps(on: presentationOnly))
    }

    var summary: String {
        ([lightkey ? "Lightkey" : nil, lightkey && dmx ? "DMX interface" : nil, streamDeck ? "Stream Deck" : nil]
            + apps.filter(\.on).map(\.name)
            + [alwaysOn ? "stays on for services" : nil]).compactMap { $0 }.joined(separator: ", ")
    }
}

enum Settings {
    static func url(_ s: String) -> URL { URL(string: s)! }
    static let battery = url("x-apple.systempreferences:com.apple.Battery-Settings.extension")
    static let lockScreen = url("x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")
    static let privacy = url("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")
    static let softwareUpdate = url("x-apple.systempreferences:com.apple.Software-Update-Settings.extension")
    static let loginItems = url("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    static let accessibility = url("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    static let automation = url("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
}

// MARK: - Updates from GitHub

enum Repo {
    static let latestAPI = URL(string: "https://api.github.com/repos/jimhoggey/BoothCheck-App/releases/latest")!
    static let releases = URL(string: "https://github.com/jimhoggey/BoothCheck-App/releases")!
}

/// The newest GitHub release and the zip attached to it.
struct Release {
    let version: String         // tag without the leading "v"
    let tag: String
    let notes: String
    let page: URL
    let zipURL: URL
    let zipName: String
    let size: Int
    let sha256: String?         // GitHub's own checksum of the zip
}

func parseRelease(_ data: Data) -> Release? {
    guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tag = d["tag_name"] as? String,
          let assets = d["assets"] as? [[String: Any]],
          let zip = assets.first(where: { ($0["name"] as? String)?.lowercased().hasSuffix(".zip") == true }),
          let download = (zip["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
    let digest = (zip["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
    return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), tag: tag,
                   notes: (d["body"] as? String) ?? "",
                   page: (d["html_url"] as? String).flatMap(URL.init(string:)) ?? Repo.releases,
                   zipURL: download, zipName: (zip["name"] as? String) ?? "update.zip",
                   size: (zip["size"] as? Int) ?? 0, sha256: digest)
}

/// "1.10" is newer than "1.9"; missing parts count as 0.
func isNewer(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) {
        let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
        if p != q { return p > q }
    }
    return false
}

// MARK: - Log

struct LogEntry: Identifiable {
    let id = UUID()
    let time = Date()
    let title: String
    let language: String        // "Terminal", "AppleScript" or "macOS API"
    let code: String
    let output: String
    let status: Int32?          // exit code; nil when nothing was executed as code
}

/// Collects what one check pass read, so the Log can show it.
final class Pass {
    var entries: [LogEntry] = []

    func sh(_ title: String, _ path: String, _ args: [String]) -> (out: String, code: Int32) {
        let r = shell(path, args)
        entries.append(LogEntry(title: title, language: "Terminal", code: commandLine(path, args),
                                output: r.out, status: r.code))
        return r
    }

    func api(_ title: String, _ what: String, _ result: String) {
        entries.append(LogEntry(title: title, language: "macOS API", code: what, output: result, status: nil))
    }
}

/// How a command is shown to the user: exactly what runs, quoted the way Terminal would need it.
func commandLine(_ path: String, _ args: [String]) -> String {
    ([path] + args).map { a in
        a.rangeOfCharacter(from: .init(charactersIn: " '\"$\\")) == nil ? a : "'" + a.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }.joined(separator: " ")
}

// MARK: - Reading the system

/// Runs a built-in command and returns what it printed. Reads before waiting so a large output can't
/// fill the pipe and hang the command.
func shell(_ path: String, _ args: [String]) -> (out: String, code: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return ("Couldn't start \(path): \(error.localizedDescription)", -1) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), p.terminationStatus)
}

/// One section of `pmset -g custom` output ("AC Power" or "Battery Power") as key -> value.
func pmsetSection(_ output: String, _ name: String) -> [String: String] {
    var dict: [String: String] = [:]
    var inSection = false
    for raw in output.split(separator: "\n") {
        let line = String(raw)
        if !line.hasPrefix(" "), line.hasSuffix(":") {
            inSection = line.dropLast() == name
            continue
        }
        guard inSection else { continue }
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if parts.count >= 2 { dict[parts[0]] = parts[parts.count - 1] }
    }
    return dict
}

struct USBDevice {
    var name = ""
    var vendorID = 0
    var serial = ""
}

/// Every USB device in `ioreg -p IOUSB -l` output.
func usbDevices(_ output: String) -> [USBDevice] {
    var list: [USBDevice] = []
    var current: USBDevice?
    for raw in output.split(separator: "\n") {
        let line = String(raw)
        if line.contains("+-o ") {
            if let c = current { list.append(c) }
            current = USBDevice()
            continue
        }
        guard current != nil, let q1 = line.firstIndex(of: "\""), let eq = line.range(of: "\" = ") else { continue }
        let key = String(line[line.index(after: q1)..<eq.lowerBound])
        var value = String(line[eq.upperBound...]).trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
        switch key {
        case "USB Product Name": current?.name = value
        case "idVendor": current?.vendorID = Int(value) ?? 0
        case "USB Serial Number": current?.serial = value
        default: break
        }
    }
    if let c = current { list.append(c) }
    return list
}

/// "Allow accessory to connect?" only exists on Apple silicon; Intel Macs never ask.
#if arch(arm64)
let hasAccessoryPrompt = true
#else
let hasAccessoryPrompt = false
#endif

func isDMXInterface(_ d: USBDevice) -> Bool {
    d.vendorID == IDs.ftdiVendor || d.name.localizedCaseInsensitiveContains("DMX")
}

/// The processes that drive Lightkey's DMX output, from `ps -axo pid=,comm=` output: Lightkey itself,
/// and its OLA server `olad` (Open Lighting Architecture). Lightkey starts olad from /Library/OLA,
/// and olad opens USB interfaces such as the Open DMX USB through libusb, so the connection is
/// olad's, not Lightkey's. Lightkey comes first.
func dmxDriverPIDs(lightkey: pid_t, psOutput: String) -> [pid_t] {
    [lightkey] + psOutput.split(separator: "\n").compactMap { line in
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let pid = pid_t(parts[0]), pid != lightkey,
              (String(parts[1]) as NSString).lastPathComponent == "olad" else { return nil }
        return pid
    }
}

/// USB driver connections that these processes have open, from `ioreg -l -c IOUserClient` output.
/// Each connection records who opened it ("pid 123, Lightkey"); a USB one opened by Lightkey means
/// Lightkey is driving a USB device, and the DMX interface is the only one it drives.
func usbConnections(_ output: String, pids: [pid_t]) -> [String] {
    var currentClass = ""
    var found: [String] = []
    for raw in output.split(separator: "\n") {
        let line = String(raw)
        if let r = line.range(of: "<class ") {
            currentClass = String(line[r.upperBound...].prefix { $0 != "," && $0 != ">" })
        } else if line.contains("\"IOUserClientCreator\""), pids.contains(where: { line.contains("\"pid \($0),") }),
                  currentClass.localizedCaseInsensitiveContains("USB") {
            found.append("\(currentClass) \u{2014} \(line.components(separatedBy: "= ").last ?? "")")
        }
    }
    return found
}

/// Keeps a CoreMIDI client alive so the endpoint list stays current while the app runs.
final class MIDIWatch {
    static let shared = MIDIWatch()
    private var client = MIDIClientRef()
    private init() { MIDIClientCreateWithBlock("Booth Check" as CFString, &client) { _ in } }

    func destinationNames() -> [String] {
        (0..<MIDIGetNumberOfDestinations()).compactMap { i in
            var name: Unmanaged<CFString>?
            guard MIDIObjectGetStringProperty(MIDIGetDestination(i), kMIDIPropertyName, &name) == noErr,
                  let n = name?.takeRetainedValue() else { return nil }
            return n as String
        }
    }
}

/// Documents (file URLs) and titles of Lightkey's open windows, read through Accessibility.
func windowsOf(pid: pid_t) -> (docs: [URL], titles: [String]) {
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return ([], []) }
    var docs: [URL] = [], titles: [String] = []
    for w in windows {
        var doc: CFTypeRef?, title: CFTypeRef?
        if AXUIElementCopyAttributeValue(w, kAXDocumentAttribute as CFString, &doc) == .success,
           let s = doc as? String, let u = URL(string: s) { docs.append(u) }
        if AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &title) == .success,
           let t = title as? String, !t.isEmpty { titles.append(t) }
    }
    return (docs, titles)
}

/// Whether Lightkey has the chosen show open. Lightkey is a document app, so Accessibility gives each
/// window's file, and then the path decides: a same-named copy from another folder doesn't count.
/// Window titles are only the fallback, and must name the show on its own ("Show", "Show — Edited"),
/// so "Show_v3" can't pass for "Show_v33" and "Show copy" isn't the show.
func showIsOpen(_ showPath: String, docs: [URL], titles: [String]) -> Bool {
    let wanted = URL(fileURLWithPath: showPath).standardizedFileURL
    if !docs.isEmpty { return docs.contains { $0.standardizedFileURL.path == wanted.path } }
    let names = [wanted.lastPathComponent, wanted.deletingPathExtension().lastPathComponent]
    return titles.contains { title in
        ([title] + title.components(separatedBy: " \u{2014} ")).contains {
            names.contains($0.trimmingCharacters(in: .whitespaces))
        }
    }
}

enum ShowOpenNext: Equatable { case done, wait, notShowing }

/// The start-up's next move once Lightkey is running. Lightkey doesn't load the show until someone
/// clicks Authenticate and types the Mac's password (to free the Open DMX USB), so a show that isn't
/// open yet is waited for, for up to two minutes. `isOpen` is nil when Booth Check can't see
/// Lightkey's windows (no Accessibility); then it doesn't guess.
func showOpenNext(isOpen: Bool?, waited: TimeInterval) -> ShowOpenNext {
    switch isOpen {
    case true?, nil: return .done
    case false?: return waited < 120 ? .wait : .notShowing
    }
}

/// Where the replug sign's animation is; `phase` turns through one loop per 1.0. Returns how far the
/// plug is out (0 = in, 1 = all the way out) and which step is lit (1 = unplug, 2 = plug back in).
func replugFrame(_ phase: Double) -> (out: Double, step: Int) {
    let p = phase - phase.rounded(.down)
    func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }
    switch p {
    case ..<0.15: return (0, 1)                                 // in, about to come out
    case ..<0.40: return (ease((p - 0.15) / 0.25), 1)           // sliding out
    case ..<0.55: return (1, 2)                                 // out
    case ..<0.80: return (1 - ease((p - 0.55) / 0.25), 2)       // sliding back in
    default: return (0, 2)                                      // in again
    }
}

/// Whether a finished start-up should settle: it ended with warnings (say, a DMX link Booth Check
/// couldn't confirm while someone was still typing Lightkey's password), but nothing needs fixing now.
/// The panel then turns green and goes, instead of staying up for good (church Mac, 3 Oct 2026).
func startUpSettles(finished: Bool, running: Bool, alreadySettled: Bool, problems: Int) -> Bool {
    finished && !running && !alreadySettled && problems == 0
}

/// Whether a start-up counts as ready for the service: every step went fine, or one warned on the way
/// but every check is green now. The start-up panel's title and the hands-off sign's last word both
/// go by this, so they agree.
func startUpReady(steps: [StepState], problems: Int, unknown: Int, checks: Int) -> Bool {
    steps.allSatisfy { $0 == .done } || (problems == 0 && unknown == 0 && checks > 0)
}

/// Whether a start-up gets the hands-off sign: only the one that runs by itself at login (the user
/// asked for it there, 6 Oct 2026), and only if it opens something; a check-only start-up opens nothing.
func startUpShowsSign(atLogin: Bool, steps: [String]) -> Bool {
    atLogin && steps.contains { $0 != "check" }
}

enum StartSign: Equatable { case none, handsOff, password }

/// What the hands-off sign says at this point of the start-up. Nothing while the replug sign has the
/// screen. From the moment Lightkey opens until Booth Check sees it holding the DMX interface, Lightkey
/// may be waiting for someone to click Authenticate and type the Mac's password, so then the sign says
/// what to do in Lightkey (and moves out of the way of Lightkey's alert) instead of "don't touch".
func startSign(replugShowing: Bool, asksPassword: Bool, lightkeyOpened: Bool, dmxLinked: Bool) -> StartSign {
    if replugShowing { return .none }
    return asksPassword && lightkeyOpened && !dmxLinked ? .password : .handsOff
}

/// What the password banner tells people to do in Lightkey: the two things the booth docs have them do
/// there, and nothing else. Lightkey opens on its list of projects when no show is chosen in Booth
/// Check (the docs' "click the most recent project"), so then it can't name one.
func passwordSignText(show: String?) -> String {
    "If it asks for the password, tap Authenticate on the Touch Bar (or click it), then type the Mac\u{2019}s password. "
        + "If it shows its list of projects, click \(show ?? "the most recent one"). Nothing else needs touching."
}

// MARK: - Login items (System Events)

struct LoginItem: Identifiable {
    let name: String
    let path: String
    var id: String { path + "|" + name }
    var isShow: Bool { path.lowercased().hasSuffix(".lightkeyproj") }
}

enum LoginRead {
    case items([LoginItem])
    case notAllowed
    case failed(String)
}

func appleScriptQuote(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// Runs AppleScript and returns what it produced, or its error, in the same shape as a command.
func runAppleScript(_ source: String) -> (out: String, code: Int32) {
    var err: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
    if let err {
        return ((err[NSAppleScript.errorMessage] as? String) ?? "Unknown error",
                Int32((err[NSAppleScript.errorNumber] as? Int) ?? 1))
    }
    return (result?.stringValue ?? "Done.", 0)
}

let readLoginItemsScript = "tell application \"System Events\" to get {name, path} of every login item"

func readLoginItems() -> LoginRead {
    var err: NSDictionary?
    guard let desc = NSAppleScript(source: readLoginItemsScript)?.executeAndReturnError(&err) else {
        let code = (err?[NSAppleScript.errorNumber] as? Int) ?? 0
        return code == -1743 ? .notAllowed : .failed((err?[NSAppleScript.errorMessage] as? String) ?? "Unknown error")
    }
    guard desc.numberOfItems == 2, let names = desc.atIndex(1), let paths = desc.atIndex(2),
          names.numberOfItems > 0 else { return .items([]) }
    return .items((1...names.numberOfItems).map {
        LoginItem(name: names.atIndex($0)?.stringValue ?? "", path: paths.atIndex($0)?.stringValue ?? "")
    })
}

/// Removes every show from the login items, then adds this one, so exactly one show opens at login.
func makeLoginShowScript(_ path: String) -> String {
    """
    tell application "System Events"
        set oldNames to name of every login item whose path ends with ".lightkeyproj"
        repeat with n in oldNames
            delete login item (contents of n)
        end repeat
        make login item at end with properties {path:\(appleScriptQuote(path)), hidden:false}
        set AppleScript's text item delimiters to ", "
        return "Login items now: " & (name of every login item as text)
    end tell
    """
}

func addLoginItemScript(_ path: String) -> String {
    """
    tell application "System Events"
        make login item at end with properties {path:\(appleScriptQuote(path)), hidden:false}
        set AppleScript's text item delimiters to ", "
        return "Login items now: " & (name of every login item as text)
    end tell
    """
}

let removeShowLoginItemsScript = """
tell application "System Events"
    set oldNames to name of every login item whose path ends with ".lightkeyproj"
    repeat with n in oldNames
        delete login item (contents of n)
    end repeat
    set AppleScript's text item delimiters to ", "
    return "Login items now: " & (name of every login item as text)
end tell
"""

/// Stops one item opening at login. The app or file itself is untouched.
func removeLoginItemScript(_ path: String) -> String {
    """
    tell application "System Events"
        delete (every login item whose path is \(appleScriptQuote(path)))
        set AppleScript's text item delimiters to ", "
        return "Login items now: " & (name of every login item as text)
    end tell
    """
}

// MARK: - Model

enum Status {
    case ok, warn, fail, unknown, manual

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle"
        case .manual: return "info.circle"
        }
    }

    var color: Color {
        switch self {
        case .ok: return .green
        case .warn: return .orange
        case .fail: return .red
        case .unknown, .manual: return .secondary
        }
    }
}

enum Action {
    case fixAppNap, chooseShow, openShow, launchStreamDeck
    case allowAccessibility, allowAutomation, makeLoginShow, addStreamDeckToLogin, addSelfToLogin
    case removeLoginItem(LoginItem)
    case removeShowLoginItems
    case enableAutoBoot(String?)
    case noStreamDeck
    case openApp(String, String)        // bundle ID, name
    case openSetup
    case open(URL, String)

    var label: String {
        switch self {
        case .fixAppNap: return "Turn App Nap off\u{2026}"
        case .chooseShow: return "Choose show\u{2026}"
        case .openShow: return "Open the show"
        case .launchStreamDeck: return "Open Stream Deck"
        case .allowAccessibility, .allowAutomation: return "Allow access\u{2026}"
        case .makeLoginShow: return "Make it the login show\u{2026}"
        case .addStreamDeckToLogin, .addSelfToLogin: return "Add to login\u{2026}"
        case .removeLoginItem, .removeShowLoginItems: return "Remove\u{2026}"
        case .enableAutoBoot: return "Turn on\u{2026}"
        case .noStreamDeck: return "No Stream Deck on this Mac"
        case .openApp(_, let name): return "Open \(name)"
        case .openSetup: return "This Mac\u{2026}"
        case .open(_, let label): return label
        }
    }
}

struct Check: Identifiable {
    let id: String
    let group: String
    let title: String
    let status: Status
    let detail: String
    var fix: String? = nil
    var action: Action? = nil
    var info: String? = nil         // "what is this?", shown from the row's ⓘ button
}

let autoBootInfo = """
When this MacBook is shut down, plugging in the charger turns it on, without opening the lid or \
pressing the power button. That matters in clamshell mode, where the lid stays closed under a \
monitor: shut down from the Apple menu, and to start again, unplug the charger and plug it back in.

It only acts on a Mac that is shut down. It doesn\u{2019}t wake a sleeping Mac, and it doesn\u{2019}t stop \
you shutting down. Opening the lid starts the Mac too.

It\u{2019}s a firmware setting stored in NVRAM, not in System Settings. Reading it needs no password; \
changing it needs an administrator password. Intel MacBooks from 2016 on call it AutoBoot and have \
it on from the factory. Apple silicon MacBooks call it BootPreference, which can also turn off \
starting when the lid opens.
"""

enum StepState { case waiting, running, done, warn, failed }

/// One step of the start-up order: "Wait for the DMX interface", "Open Stream Deck in the background"…
struct BootStep: Identifiable, Equatable {
    let id: String
    var title: String
    var state: StepState = .waiting
    var detail: String? = nil
}

/// A change waiting for the user to read the code and press Run.
struct PendingChange: Identifiable {
    let id = UUID()
    let key: String
    let title: String
    let explanation: String
    let language: String
    let code: String
    var undo: String? = nil
    let run: () -> (out: String, code: Int32)
}

let groupOrder = ["Lighting", "Stream Deck", "Apps", "Power & sleep", "Start at login", "Updates", "Check these yourself"]

/// Everything read off the main thread in one pass.
struct Snapshot {
    var onAC = true
    var ac: [String: String] = [:]
    var appNapOff = false
    var usb: [USBDevice] = []
    var autoInstall: String?
    var lightkeyUSB: [String] = []          // USB driver connections Lightkey or its olad has open
    var lightkeySerial: [String] = []       // USB serial ports Lightkey has open
    var hasBattery = false                  // a laptop, so starting from the charger applies
    var bootValue: String?                  // the firmware setting; nil = not set = factory setting
    var bootReadFailed = false
}

// MARK: - Starting up from the charger (laptops)

// Intel MacBooks (2016 on) use AutoBoot: %00 off, anything else or unset on.
// Apple silicon uses BootPreference: unset = lid and charger both start it, %01 = charger only,
// %02 = lid only, %00 = neither (Apple support article 120622).
#if arch(arm64)
let bootVariable = "BootPreference"
func startsOnCharger(_ value: String?) -> Bool { value == nil || value == "%01" }
func enableBootArgs(_ value: String?) -> [String] { value == "%00" ? ["BootPreference=%01"] : ["-d", "BootPreference"] }
#else
let bootVariable = "AutoBoot"
func startsOnCharger(_ value: String?) -> Bool { value != "%00" }
func enableBootArgs(_ value: String?) -> [String] { ["AutoBoot=%03"] }
#endif

/// The value from `nvram <name>` output ("AutoBoot\t%03").
func nvramValue(_ output: String) -> String? {
    output.split(separator: "\t").last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
}

func undoBootArgs(_ value: String?) -> [String] {
    value.map { ["\(bootVariable)=\($0)"] } ?? ["-d", bootVariable]
}

/// Apps read the App Nap setting when they open, so only a Stream Deck that was already running
/// when Booth Check switched it off can still be put to sleep; one opened afterwards is fine.
func appNapCheck(appNapOff: Bool, switchedOffAt: Date?, deckLaunched: Date?) -> Check {
    if !appNapOff {
        return Check(id: "nap", group: "Power & sleep", title: "App Nap off", status: .fail,
                     detail: "macOS can put the Stream Deck app to sleep — that's what freezes the keys.",
                     fix: "Turn it off, then restart the Mac.", action: .fixAppNap)
    }
    if let switchedOffAt, let deckLaunched, deckLaunched < switchedOffAt {
        return Check(id: "nap", group: "Power & sleep", title: "App Nap off", status: .warn,
                     detail: "Switched off after the Stream Deck app opened, so that copy can still be put to sleep.",
                     fix: "Quit and reopen Stream Deck once.")
    }
    return Check(id: "nap", group: "Power & sleep", title: "App Nap off", status: .ok,
                 detail: "macOS won't put the Stream Deck app to sleep.")
}

final class Booth: ObservableObject {
    static let shared = Booth()

    @Published var checks: [Check] = []
    @Published var loginItems: [LoginItem] = []
    @Published var loginRead: LoginRead = .items([])
    @Published var lastChecked: Date?
    @Published var message: String?
    @Published var showPath: String? = UserDefaults.standard.string(forKey: IDs.showKey)
    @Published var pending: PendingChange?
    @Published var lastPass: [LogEntry] = []
    @Published var changes: [LogEntry] = []

    @Published var latest: Release?
    @Published var updateStatus = ""
    @Published var showUpdate = false
    @Published var updating = false
    @Published var updateSteps: [String] = []
    @Published var updateError: String?
    @Published var updateLog: [LogEntry] = []

    @Published var starting = false
    @Published var bootSteps: [BootStep] = []
    @Published var bootFinished = false
    /// Set once a finished start-up has turned green late (see `settleStartUp`).
    private var bootSettled = false
    /// The hands-off sign for this start-up (see `startSign`): whether it's up at all, and what it knows.
    private var signOn = false
    private var signLightkeyOpened = false
    private var signDMXLinked = false
    private var timers: [Timer] = []

    /// What this Mac is for. Checks for parts it doesn't use are switched off (and counted).
    @Published var setup: MacSetup = MacSetup.saved ?? MacSetup.detected() {
        didSet {
            setup.save()
            refresh()
        }
    }
    /// True until someone has confirmed the setup sheet once on this Mac.
    @Published var needsSetup = MacSetup.saved == nil
    @Published var showSetup = false
    /// Single checks switched off by hand, by check id.
    @Published var muted: Set<String> = Set(UserDefaults.standard.stringArray(forKey: IDs.mutedKey) ?? []) {
        didSet {
            UserDefaults.standard.set(Array(muted).sorted(), forKey: IDs.mutedKey)
            refresh()
        }
    }
    @Published var mutedChecks: [Check] = []
    @Published var offForThisMac = 0

    /// At login, open the show, wait for Lightkey, then open Stream Deck. On unless switched off.
    @Published var autoStart: Bool = (UserDefaults.standard.object(forKey: IDs.autoStartKey) as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(autoStart, forKey: IDs.autoStartKey)
            refresh()
        }
    }

    private var busy = false
    /// When Booth Check switched App Nap off, this session. Apps read the setting when they open.
    private var appNapSwitchedOffAt: Date?

    var showName: String? { showPath.map { URL(fileURLWithPath: $0).lastPathComponent } }

    func refresh() {
        guard !busy else { return }
        busy = true
        let lightkeyPID = NSRunningApplication.runningApplications(withBundleIdentifier: IDs.lightkey).first?.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            let pass = Pass()
            var s = Snapshot()
            let batt = pass.sh("Power source", "/usr/bin/pmset", ["-g", "batt"]).out
            s.onAC = batt.contains("'AC Power'")
            s.hasBattery = batt.contains("InternalBattery")
            if s.hasBattery {
                let boot = pass.sh("Starts from the charger", "/usr/sbin/nvram", [bootVariable])
                if boot.code == 0 {
                    s.bootValue = nvramValue(boot.out)
                } else if !boot.out.contains("not found") {
                    s.bootReadFailed = true
                }
            }
            s.ac = pmsetSection(pass.sh("Sleep settings", "/usr/bin/pmset", ["-g", "custom"]).out, "AC Power")
            s.appNapOff = pass.sh("App Nap setting", "/usr/bin/defaults", ["read", "-g", "NSAppSleepDisabled"])
                .out.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
            s.usb = usbDevices(pass.sh("USB devices", "/usr/sbin/ioreg", ["-p", "IOUSB", "-l", "-w0"]).out)
            let upd = pass.sh("Automatic macOS updates", "/usr/bin/defaults",
                              ["read", "/Library/Preferences/com.apple.SoftwareUpdate", "AutomaticallyInstallMacOSUpdates"])
            s.autoInstall = upd.code == 0 ? upd.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil

            // Experimental: is Lightkey actually using the DMX interface? Only worth asking when
            // both are there. Lightkey drives it through its OLA server, olad, so both processes
            // count. Logged filtered to their own entries; the raw output is huge.
            if let pid = lightkeyPID, s.usb.contains(where: isDMXInterface) {
                let psArgs = ["-axo", "pid=,comm="]
                let ps = shell("/bin/ps", psArgs)
                let pids = dmxDriverPIDs(lightkey: pid, psOutput: ps.out)
                let olad = pids.filter { $0 != pid }.map(String.init)
                pass.entries.append(LogEntry(
                    title: "Lightkey's DMX server, olad (experimental)", language: "Terminal",
                    code: commandLine("/bin/ps", psArgs),
                    output: (olad.isEmpty ? "olad isn\u{2019}t running." : "olad is running (pid \(olad.joined(separator: ", "))).")
                        + "\n(Only Lightkey\u{2019}s OLA server is shown.)",
                    status: ps.code))
                let who = "Lightkey (pid \(pid))" + (olad.isEmpty ? "" : " or olad (pid \(olad.joined(separator: ", ")))")
                let ioArgs = ["-l", "-w0", "-c", "IOUserClient"]
                let io = shell("/usr/sbin/ioreg", ioArgs)
                s.lightkeyUSB = usbConnections(io.out, pids: pids)
                pass.entries.append(LogEntry(
                    title: "Lightkey's USB connections (experimental)", language: "Terminal",
                    code: commandLine("/usr/sbin/ioreg", ioArgs),
                    output: (s.lightkeyUSB.isEmpty ? "None opened by \(who)." : s.lightkeyUSB.joined(separator: "\n"))
                        + "\n(Only connections opened by Lightkey or olad are shown.)",
                    status: io.code))
                let lsofArgs = ["-p", pids.map(String.init).joined(separator: ","), "-Fn"]
                let ls = shell("/usr/sbin/lsof", lsofArgs)
                s.lightkeySerial = ls.out.split(separator: "\n").compactMap { line in
                    line.hasPrefix("n/dev/") && (line.contains("usbserial") || line.contains("usbmodem"))
                        ? String(line.dropFirst()) : nil
                }
                pass.entries.append(LogEntry(
                    title: "Lightkey's open serial ports (experimental)", language: "Terminal",
                    code: commandLine("/usr/sbin/lsof", lsofArgs),
                    output: (s.lightkeySerial.isEmpty ? "No USB serial ports open." : s.lightkeySerial.joined(separator: "\n"))
                        + "\n(Only USB serial ports are shown.)",
                    status: ls.code))
            }
            DispatchQueue.main.async {
                self.finish(s, pass)
                self.busy = false
            }
        }
    }

    // Accessibility, NSWorkspace, CoreMIDI and AppleScript all run here on the main thread.
    private func finish(_ s: Snapshot, _ pass: Pass) {
        var out: [Check] = []
        let running = NSWorkspace.shared.runningApplications
        let lightkey = running.first { $0.bundleIdentifier == IDs.lightkey }
        let deckApp = running.first { $0.bundleIdentifier == IDs.streamDeck }
        pass.api("Running apps", "NSWorkspace: list the running apps",
                 "Lightkey: \(lightkey == nil ? "not running" : "running")\nStream Deck: \(deckApp == nil ? "not running" : "running")")

        // Lighting ---------------------------------------------------------------------------
        let dmx = s.usb.first(where: isDMXInterface)
        if let d = dmx {
            let serial = d.serial.isEmpty ? "" : ", serial \(d.serial)"
            out.append(Check(id: "dmx", group: "Lighting", title: "DMX interface plugged in", status: .ok,
                             detail: "\(d.name.isEmpty ? "USB DMX interface" : d.name)\(serial)."))
        } else {
            out.append(Check(id: "dmx", group: "Lighting", title: "DMX interface plugged in", status: .fail,
                             detail: "No USB DMX interface found.",
                             fix: "Unplug the DMX USB cable and plug it back in, then quit and reopen Lightkey."))
        }

        out.append(lightkey != nil
            ? Check(id: "lk", group: "Lighting", title: "Lightkey is running", status: .ok, detail: "Lightkey is open.")
            : Check(id: "lk", group: "Lighting", title: "Lightkey is running", status: .fail,
                    detail: "Lightkey isn't open.", action: showPath != nil ? .openShow : nil))

        out.append(showCheck(lightkey, pass))

        let dmxTitle = "Lightkey is sending DMX (experimental)"
        if dmx == nil {
            out.append(Check(id: "dmxLive", group: "Lighting", title: dmxTitle, status: .unknown,
                             detail: "Waiting for the DMX interface."))
        } else if lightkey == nil {
            out.append(Check(id: "dmxLive", group: "Lighting", title: dmxTitle, status: .unknown,
                             detail: "Waiting for Lightkey to open."))
        } else if !s.lightkeyUSB.isEmpty {
            out.append(Check(id: "dmxLive", group: "Lighting", title: dmxTitle, status: .ok,
                             detail: "Lightkey has the DMX interface open."))
        } else if let port = s.lightkeySerial.first {
            out.append(Check(id: "dmxLive", group: "Lighting", title: dmxTitle, status: .ok,
                             detail: "Lightkey has the DMX interface\u{2019}s port open (\(port))."))
        } else {
            out.append(Check(id: "dmxLive", group: "Lighting", title: dmxTitle, status: .warn,
                             detail: "Lightkey is open, but it doesn\u{2019}t seem to be using the DMX interface.",
                             fix: "In Lightkey, check the interface is chosen for the universe. If it is, unplug and replug the interface, then quit and reopen Lightkey. This check is new: if the lights respond, trust the lights."))
        }

        let midi = MIDIWatch.shared.destinationNames()
        pass.api("Lightkey's MIDI input", "CoreMIDI: list the MIDI destinations", midi.isEmpty ? "(none)" : midi.joined(separator: "\n"))
        if lightkey == nil {
            out.append(Check(id: "midi", group: "Lighting", title: "Lightkey is listening for the Stream Deck",
                             status: .unknown, detail: "Waiting for Lightkey to open."))
        } else if midi.contains(where: { $0.localizedCaseInsensitiveContains(IDs.lightkeyMIDIInput) }) {
            out.append(Check(id: "midi", group: "Lighting", title: "Lightkey is listening for the Stream Deck",
                             status: .ok, detail: "Lightkey's MIDI input is ready."))
        } else {
            out.append(Check(id: "midi", group: "Lighting", title: "Lightkey is listening for the Stream Deck",
                             status: .fail, detail: "Lightkey is open but its MIDI input isn't there.",
                             fix: "Quit and reopen Lightkey."))
        }

        // Stream Deck --------------------------------------------------------------------------
        let deck = s.usb.first { $0.vendorID == IDs.elgatoVendor || $0.name.localizedCaseInsensitiveContains("Stream Deck") }
        out.append(deck != nil
            ? Check(id: "deck", group: "Stream Deck", title: "Stream Deck plugged in", status: .ok,
                    detail: "\(deck!.name.isEmpty ? "Stream Deck" : deck!.name).")
            : Check(id: "deck", group: "Stream Deck", title: "Stream Deck plugged in", status: .fail,
                    detail: "No Stream Deck found on USB.", fix: "Check the Stream Deck's USB cable."))

        let deckInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: IDs.streamDeck) != nil
        if deckApp != nil {
            out.append(Check(id: "deckapp", group: "Stream Deck", title: "Stream Deck app running", status: .ok,
                             detail: "The Stream Deck app is open."))
        } else if deckInstalled {
            out.append(Check(id: "deckapp", group: "Stream Deck", title: "Stream Deck app running", status: .fail,
                             detail: "The Stream Deck app isn't open, so the keys do nothing.", action: .launchStreamDeck))
        } else {
            // Not installed at all is the one case where "this Mac doesn't use one" is a safe guess.
            out.append(Check(id: "deckapp", group: "Stream Deck", title: "Stream Deck app running", status: .fail,
                             detail: "The Stream Deck app isn\u{2019}t installed on this Mac.",
                             fix: "If this Mac doesn\u{2019}t use a Stream Deck, switch its checks off.",
                             action: .noStreamDeck))
        }
        // Other apps this Mac keeps open, such as ProPresenter ---------------------------------------
        for app in setup.apps where app.on {
            let title = "\(app.name) is running"
            if running.contains(where: { $0.bundleIdentifier == app.bundleID }) {
                out.append(Check(id: "app:\(app.bundleID)", group: "Apps", title: title, status: .ok,
                                 detail: "\(app.name) is open."))
            } else if MacSetup.installed(app.bundleID) {
                out.append(Check(id: "app:\(app.bundleID)", group: "Apps", title: title, status: .fail,
                                 detail: "\(app.name) isn\u{2019}t open.", action: .openApp(app.bundleID, app.name)))
            } else {
                out.append(Check(id: "app:\(app.bundleID)", group: "Apps", title: title, status: .fail,
                                 detail: "\(app.name) isn\u{2019}t installed on this Mac.",
                                 fix: "If this Mac doesn\u{2019}t use it, switch it off under This Mac.", action: .openSetup))
            }
        }

        // Power & sleep ------------------------------------------------------------------------
        out.append(s.onAC
            ? Check(id: "ac", group: "Power & sleep", title: "On the charger", status: .ok, detail: "Running on AC power.")
            : Check(id: "ac", group: "Power & sleep", title: "On the charger", status: .fail,
                    detail: "Running on battery.", fix: "Plug the charger in. The Mac only stays awake on power."))

        if s.hasBattery {
            let title = "Starts up when the charger is plugged in"
            if s.bootReadFailed {
                out.append(Check(id: "autoboot", group: "Power & sleep", title: title, status: .unknown,
                                 detail: "Couldn\u{2019}t read the start-up setting.", info: autoBootInfo))
            } else if startsOnCharger(s.bootValue) {
                out.append(Check(id: "autoboot", group: "Power & sleep", title: title, status: .ok,
                                 detail: "If the Mac is shut down with the lid closed, unplugging and replugging the charger starts it"
                                    + (s.bootValue == nil ? " (the factory setting)." : "."),
                                 info: autoBootInfo))
            } else {
                out.append(Check(id: "autoboot", group: "Power & sleep", title: title, status: .warn,
                                 detail: "Plugging in the charger won\u{2019}t start this Mac, so in clamshell mode someone has to open the lid and press the power button.",
                                 fix: "Optional, but it means the Mac can be started without opening it.",
                                 action: .enableAutoBoot(s.bootValue), info: autoBootInfo))
            }
        }

        // Changing sleep needs the admin password, so these send you to System Settings instead.
        if s.ac.isEmpty {
            out.append(Check(id: "sleep", group: "Power & sleep", title: "Never sleeps on the charger",
                             status: .unknown, detail: "Couldn't read the power settings.",
                             action: .open(Settings.battery, "Open Battery settings")))
        } else if s.ac["sleep"] != "0" {
            out.append(Check(id: "sleep", group: "Power & sleep", title: "Never sleeps on the charger", status: .fail,
                             detail: "The Mac goes to sleep after \(s.ac["sleep"] ?? "?") minutes even on the charger.",
                             fix: "In Battery, click Options\u{2026} and turn on \u{201C}Prevent automatic sleeping on power adapter when the display is off\u{201D}.",
                             action: .open(Settings.battery, "Open Battery settings")))
        } else if s.ac["displaysleep"] != "0" {
            out.append(Check(id: "sleep", group: "Power & sleep", title: "Never sleeps on the charger", status: .warn,
                             detail: "The Mac stays awake, but the screen turns off after \(s.ac["displaysleep"] ?? "?") minutes.",
                             fix: "In Lock Screen, set \u{201C}Turn display off on power adapter when inactive\u{201D} to Never.",
                             action: .open(Settings.lockScreen, "Open Lock Screen settings")))
        } else {
            out.append(Check(id: "sleep", group: "Power & sleep", title: "Never sleeps on the charger", status: .ok,
                             detail: "The Mac and its screen stay awake while on the charger."))
        }

        let lowPower = s.ac["lowpowermode"]
        out.append(lowPower == nil || lowPower == "0"
            ? Check(id: "lpm", group: "Power & sleep", title: "Low Power Mode off", status: .ok,
                    detail: "Background apps run at full speed.")
            : Check(id: "lpm", group: "Power & sleep", title: "Low Power Mode off", status: .fail,
                    detail: "Low Power Mode slows background apps, including the Stream Deck app.",
                    fix: "Set Low Power Mode to Never.", action: .open(Settings.battery, "Open Battery settings")))

        out.append(appNapCheck(appNapOff: s.appNapOff, switchedOffAt: appNapSwitchedOffAt, deckLaunched: deckApp?.launchDate))

        // Start at login -----------------------------------------------------------------------
        loginRead = readLoginItems()
        switch loginRead {
        case .items(let items):
            pass.entries.append(LogEntry(title: "What opens at login", language: "AppleScript", code: readLoginItemsScript,
                                         output: items.isEmpty ? "(nothing)" : items.map { "\($0.name) \u{2014} \($0.path)" }.joined(separator: "\n"),
                                         status: 0))
            loginItems = items
            let selfPath = Bundle.main.bundleURL.standardizedFileURL.path
            let selfAtLogin = items.contains {
                URL(fileURLWithPath: $0.path).standardizedFileURL.path == selfPath || $0.name == "Booth Check"
            }
            let deckItem = items.first {
                $0.name.localizedCaseInsensitiveContains("Stream Deck") || $0.path.localizedCaseInsensitiveContains("Stream Deck")
            }
            if selfAtLogin {
                out.append(Check(id: "selfLogin", group: "Start at login", title: "Booth Check opens at login", status: .ok,
                                 detail: autoStart ? "Booth Check opens by itself, starts the show and checks everything."
                                                   : "Booth Check opens by itself and checks everything straight away."))
            } else if let problem = installProblem {
                out.append(Check(id: "selfLogin", group: "Start at login", title: "Booth Check opens at login", status: .warn,
                                 detail: "Booth Check doesn\u{2019}t open at login.", fix: problem))
            } else {
                out.append(Check(id: "selfLogin", group: "Start at login", title: "Booth Check opens at login",
                                 status: autoStart ? .fail : .warn,
                                 detail: autoStart ? "Nothing starts the show after a restart until someone opens Booth Check."
                                                   : "After a restart nobody sees these checks until someone opens Booth Check.",
                                 action: .addSelfToLogin))
            }

            if autoStart {
                // Booth Check starts everything in order, so shows and Stream Deck shouldn't also open on their own.
                if setup.lightkey && showName == nil {
                    out.append(Check(id: "autoShow", group: "Start at login", title: "Booth Check starts the show", status: .warn,
                                     detail: "Choose the show this Mac should run.", action: .chooseShow))
                } else {
                    out.append(Check(id: "autoShow", group: "Start at login", title: "Booth Check starts the show", status: .ok,
                                     detail: "At login it " + startOrder.prefix(1).lowercased() + startOrder.dropFirst()))
                }
                let shows = items.filter(\.isShow)
                out.append(shows.isEmpty
                    ? Check(id: "loginShows", group: "Start at login", title: "No show opens on its own at login", status: .ok,
                            detail: "Only Booth Check opens the show.")
                    : Check(id: "loginShows", group: "Start at login", title: "No show opens on its own at login", status: .warn,
                            detail: "\(shows.map(\.name).joined(separator: ", ")) also open\(shows.count == 1 ? "s" : "") at login, which can race Booth Check or open an older version.",
                            fix: "Booth Check opens the show itself, so take it off the login items.",
                            action: .removeShowLoginItems))
                if let deckItem {
                    out.append(Check(id: "deckLogin", group: "Start at login", title: "Stream Deck waits for Lightkey", status: .warn,
                                     detail: "The Stream Deck app also opens at login on its own, so it can start before Lightkey\u{2019}s MIDI input exists and the keys stay dead.",
                                     fix: "Booth Check opens it after Lightkey, so take it off the login items.",
                                     action: .removeLoginItem(deckItem)))
                } else {
                    out.append(Check(id: "deckLogin", group: "Start at login", title: "Stream Deck waits for Lightkey", status: .ok,
                                     detail: "Booth Check opens the Stream Deck app once Lightkey is ready."))
                }
            } else {
                out.append(loginShowCheck(items))
                out.append(deckItem != nil
                    ? Check(id: "deckLogin", group: "Start at login", title: "Stream Deck opens at login", status: .ok,
                            detail: "The Stream Deck app starts by itself.")
                    : Check(id: "deckLogin", group: "Start at login", title: "Stream Deck opens at login", status: .warn,
                            detail: "After a restart someone has to open the Stream Deck app by hand.",
                            action: .addStreamDeckToLogin))
            }
        case .notAllowed:
            pass.entries.append(LogEntry(title: "What opens at login", language: "AppleScript", code: readLoginItemsScript,
                                         output: "Not allowed to talk to System Events yet.", status: -1743))
            loginItems = []
            out.append(Check(id: "loginShow", group: "Start at login", title: "The right show opens at login",
                             status: .unknown, detail: "Booth Check needs permission to read the login items.",
                             fix: "Turn Booth Check on under System Events, then come back.", action: .allowAutomation))
        case .failed(let msg):
            pass.entries.append(LogEntry(title: "What opens at login", language: "AppleScript", code: readLoginItemsScript,
                                         output: msg, status: 1))
            loginItems = []
            out.append(Check(id: "loginShow", group: "Start at login", title: "The right show opens at login",
                             status: .unknown, detail: "Couldn't read the login items: \(msg)",
                             action: .open(Settings.loginItems, "Open Login Items")))
        }

        // Updates ------------------------------------------------------------------------------
        switch s.autoInstall {
        case "0":
            out.append(Check(id: "upd", group: "Updates", title: "macOS won't update by itself", status: .ok,
                             detail: "Automatic macOS installs are off."))
        case "1":
            out.append(Check(id: "upd", group: "Updates", title: "macOS won't update by itself", status: .warn,
                             detail: "macOS may install an update by itself, which can reset the USB and MIDI setup.",
                             fix: "Under Automatic Updates, turn off \u{201C}Install macOS updates\u{201D}.",
                             action: .open(Settings.softwareUpdate, "Open Software Update")))
        default:
            out.append(Check(id: "upd", group: "Updates", title: "macOS won't update by itself", status: .unknown,
                             detail: "Couldn't read the setting.",
                             fix: "Check that \u{201C}Install macOS updates\u{201D} is off under Automatic Updates.",
                             action: .open(Settings.softwareUpdate, "Open Software Update")))
        }

        // Things macOS won't let an app read ----------------------------------------------------
        out.append(Check(id: "acc", group: "Check these yourself", title: "USB devices connect without asking",
                         status: .manual,
                         detail: "Privacy & Security \u{2192} Allow accessories to connect \u{2192} Always.",
                         action: .open(Settings.privacy, "Open")))
        out.append(Check(id: "lock", group: "Check these yourself", title: "No password after sitting idle",
                         status: .manual,
                         detail: "Lock Screen \u{2192} Require password after screen saver begins \u{2192} Never.",
                         action: .open(Settings.lockScreen, "Open")))

        // Only what this Mac is set up for, minus anything muted. Both are counted, never hidden quietly.
        let relevantChecks = out.filter { applies($0.id) }
        offForThisMac = out.count - relevantChecks.count
        mutedChecks = relevantChecks.filter { muted.contains($0.id) }
        checks = relevantChecks.filter { !muted.contains($0.id) }
        lastPass = pass.entries
        lastChecked = Date()
        settleStartUp()
    }

    /// A start-up can finish with warnings and be fine a minute later, say once Lightkey has the DMX
    /// interface after the password. The panel used to stay up saying "Started, with warnings" for
    /// good (church Mac, 3 Oct 2026). So once nothing needs fixing, turn the last step green and let
    /// the panel go, as an all-green start-up does.
    private func settleStartUp() {
        guard startUpSettles(finished: bootFinished, running: starting, alreadySettled: bootSettled, problems: problemCount),
              BootPanel.shared.isShowing, let last = bootSteps.indices.last, bootSteps[last].id == "check" else { return }
        bootSettled = true
        if bootSteps[last].state != .done { setStep(last, .done, "Everything is green now.") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            if self.bootFinished && !self.starting { BootPanel.shared.hide() }
        }
    }

    private func showCheck(_ lightkey: NSRunningApplication?, _ pass: Pass) -> Check {
        let title = "The right show is open"
        guard let showPath, let showName else {
            return Check(id: "show", group: "Lighting", title: title, status: .warn,
                         detail: "Booth Check doesn't know which show this Mac should run yet.", action: .chooseShow)
        }
        // A show that was moved or renamed can't be opened at all, so this comes before anything else.
        let exists = FileManager.default.fileExists(atPath: showPath)
        pass.api("The show file", "FileManager: is \(showPath) there", exists ? "Found." : "Not there.")
        guard exists else {
            return Check(id: "show", group: "Lighting", title: title, status: .fail,
                         detail: "Can\u{2019}t find \(showName). It was moved, renamed or deleted.",
                         fix: "Choose the show again.", action: .chooseShow)
        }
        guard let lightkey else {
            return Check(id: "show", group: "Lighting", title: title, status: .unknown,
                         detail: "Waiting for Lightkey to open.")
        }
        guard AXIsProcessTrusted() else {
            pass.api("Which show Lightkey has open", "Accessibility: read Lightkey's window titles",
                     "Not allowed yet — Booth Check isn't turned on under Accessibility.")
            return Check(id: "show", group: "Lighting", title: title, status: .unknown,
                         detail: "Booth Check needs permission to read Lightkey's window title.",
                         fix: "Turn Booth Check on under Accessibility. You may need to reopen Booth Check afterwards.",
                         action: .allowAccessibility)
        }
        let (docs, titles) = windowsOf(pid: lightkey.processIdentifier)
        pass.api("Which show Lightkey has open", "Accessibility: read the document and title of each Lightkey window",
                 (docs.map(\.path) + titles).joined(separator: "\n").isEmpty ? "(no windows)"
                    : (docs.map(\.path) + titles).joined(separator: "\n"))
        if showIsOpen(showPath, docs: docs, titles: titles) {
            return Check(id: "show", group: "Lighting", title: title, status: .ok, detail: "\(showName) is open.")
        }
        if let copy = docs.first(where: { $0.lastPathComponent == showName }) {
            let folder = (copy.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            return Check(id: "show", group: "Lighting", title: title, status: .fail,
                         detail: "Lightkey has a different copy of \(showName) open, from \(folder).",
                         fix: "If that copy is the right one, choose it with Change\u{2026} above. Otherwise open the chosen show.",
                         action: .openShow)
        }
        let open = docs.map(\.lastPathComponent) + (docs.isEmpty ? titles : [])
        return Check(id: "show", group: "Lighting", title: title, status: .fail,
                     detail: open.isEmpty ? "Lightkey has no show open."
                                          : "Lightkey has \(open.joined(separator: ", ")) open, not \(showName).",
                     fix: "Open \(showName) in Lightkey (File \u{2192} Open Recent).", action: .openShow)
    }

    private func loginShowCheck(_ items: [LoginItem]) -> Check {
        let title = "The right show opens at login"
        let shows = items.filter(\.isShow)
        guard let showPath, let showName else {
            return Check(id: "loginShow", group: "Start at login", title: title, status: .warn,
                         detail: shows.isEmpty ? "Choose the show this Mac should run."
                                               : "At login the Mac opens \(shows.map(\.name).joined(separator: ", ")).",
                         action: .chooseShow)
        }
        let wanted = URL(fileURLWithPath: showPath).standardizedFileURL.path
        let ours = shows.filter { URL(fileURLWithPath: $0.path).standardizedFileURL.path == wanted }
        let others = shows.filter { URL(fileURLWithPath: $0.path).standardizedFileURL.path != wanted }
        if !ours.isEmpty && others.isEmpty {
            return Check(id: "loginShow", group: "Start at login", title: title, status: .ok,
                         detail: "\(showName) opens at login.")
        }
        if !ours.isEmpty {
            return Check(id: "loginShow", group: "Start at login", title: title, status: .fail,
                         detail: "An older show also opens at login: \(others.map(\.name).joined(separator: ", ")).",
                         fix: "Make \(showName) the only show that opens.", action: .makeLoginShow)
        }
        return Check(id: "loginShow", group: "Start at login", title: title, status: .fail,
                     detail: others.isEmpty ? "No show opens at login."
                                            : "At login the Mac opens \(others.map(\.name).joined(separator: ", ")), not \(showName).",
                     action: .makeLoginShow)
    }

    // MARK: Actions

    func perform(_ action: Action) {
        message = nil
        switch action {
        case .fixAppNap:
            let args = ["write", "-g", "NSAppSleepDisabled", "-bool", "true"]
            pending = PendingChange(
                key: "appnap", title: "Turn App Nap off",
                explanation: "Stops macOS putting apps in the background to sleep, which is what freezes the Stream Deck. It applies to every app on this Mac, from the next time each app opens, so quit and reopen Stream Deck once if it's already open. No password needed. Get the show started also does this automatically before opening Stream Deck.",
                language: "Terminal", code: commandLine("/usr/bin/defaults", args),
                undo: commandLine("/usr/bin/defaults", ["delete", "-g", "NSAppSleepDisabled"]),
                run: { shell("/usr/bin/defaults", args) })
            return
        case .makeLoginShow:
            guard let showPath, let showName else { return }
            let script = makeLoginShowScript(showPath)
            pending = PendingChange(
                key: "loginShow", title: "Make \(showName) the login show",
                explanation: "Removes every Lightkey show from the login items, then adds this one, so exactly one show opens when the Mac starts. macOS may ask to let Booth Check control System Events.",
                language: "AppleScript", code: script, run: { runAppleScript(script) })
            return
        case .addStreamDeckToLogin:
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: IDs.streamDeck) else {
                message = "The Stream Deck app isn't installed on this Mac."
                return
            }
            let script = addLoginItemScript(url.path)
            pending = PendingChange(
                key: "deckLogin", title: "Open the Stream Deck app at login",
                explanation: "Adds the Stream Deck app to the login items so it starts by itself after a restart.",
                language: "AppleScript", code: script, run: { runAppleScript(script) })
            return
        case .removeLoginItem(let item):
            let script = removeLoginItemScript(item.path)
            pending = PendingChange(
                key: "removeLogin", title: "Stop \(item.name) opening at login",
                explanation: "Removes \(item.name) from the login items, so it no longer opens when the Mac starts. \(item.name) itself isn\u{2019}t deleted, and you can add it back in System Settings \u{2192} General \u{2192} Login Items.",
                language: "AppleScript", code: script, run: { runAppleScript(script) })
            return
        case .noStreamDeck:
            setup.streamDeck = false
            logSetting("This Mac has no Stream Deck", "Stream Deck checks switched off; Get the show started no longer opens it.")
        case .openApp(let bundleID, _):
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
        case .openSetup:
            showSetup = true
        case .enableAutoBoot(let current):
            // A firmware setting with no System Settings page, so this is the one change that asks
            // for the admin password. The sheet shows exactly which command it's for.
            let args = enableBootArgs(current)
            let shown = "sudo " + commandLine("/usr/sbin/nvram", args)
            let script = "do shell script \(appleScriptQuote(commandLine("/usr/sbin/nvram", args))) with administrator privileges"
            pending = PendingChange(
                key: "autoboot", title: "Start up when the charger is plugged in",
                explanation: "Changes a firmware setting so that, when the Mac is shut down, plugging in the charger starts it, even with the lid closed. It has no page in System Settings, so macOS asks for an administrator password for this one command. Booth Check never sees the password. You can also copy the command and run it in Terminal yourself.",
                language: "Terminal command (as administrator)", code: shown,
                undo: "sudo " + commandLine("/usr/sbin/nvram", undoBootArgs(current)),
                run: {
                    let r = runAppleScript(script)
                    return r.code == -128 ? ("Cancelled at the password prompt. Nothing changed.", 1)
                                          : (r.code == 0 ? "Done. The Mac now starts when the charger is plugged in." : r.out, r.code)
                })
            return
        case .removeShowLoginItems:
            let script = removeShowLoginItemsScript
            pending = PendingChange(
                key: "removeShows", title: "Stop shows opening at login on their own",
                explanation: "Removes every Lightkey show from the login items. Booth Check opens the chosen show itself at login, in the right order. The show files aren\u{2019}t touched.",
                language: "AppleScript", code: script, run: { runAppleScript(script) })
            return
        case .addSelfToLogin:
            let script = addLoginItemScript(Bundle.main.bundleURL.path)
            pending = PendingChange(
                key: "selfLogin", title: "Open Booth Check at login",
                explanation: "Adds Booth Check to the login items, so it opens by itself after a restart and checks everything straight away.",
                language: "AppleScript", code: script, run: { runAppleScript(script) })
            return
        case .chooseShow:
            chooseShow()
        case .openShow:
            if let showPath, !NSWorkspace.shared.open(URL(fileURLWithPath: showPath)) {
                message = "Couldn\u{2019}t open \(showName ?? "the show"). If it was moved or renamed, choose it again."
            }
        case .launchStreamDeck:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: IDs.streamDeck) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            } else {
                message = "The Stream Deck app isn't installed on this Mac."
            }
        case .allowAccessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            NSWorkspace.shared.open(Settings.accessibility)
        case .allowAutomation:
            NSWorkspace.shared.open(Settings.automation)
        case .open(let url, _):
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.refresh() }
    }

    /// Runs an approved change, logs it, and returns the log entry for the sheet to show.
    func run(_ change: PendingChange) -> LogEntry {
        let r = change.run()
        let entry = LogEntry(title: change.title, language: change.language, code: change.code,
                             output: r.out.isEmpty ? "(no output)" : r.out, status: r.code)
        changes.insert(entry, at: 0)
        if change.key == "appnap", r.code == 0 { appNapSwitchedOffAt = Date() }
        return entry
    }

    func finishChange() {
        pending = nil
        refresh()
    }

    func chooseShow() {
        let panel = NSOpenPanel()
        panel.title = "Choose the show this Mac should run"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let t = UTType(filenameExtension: "lightkeyproj") { panel.allowedContentTypes = [t] }
        if let showPath { panel.directoryURL = URL(fileURLWithPath: showPath).deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        showPath = url.path
        UserDefaults.standard.set(url.path, forKey: IDs.showKey)
        refresh()
    }
}

// MARK: - Running in the background

extension Booth {
    var problemCount: Int { checks.filter { $0.status == .fail || $0.status == .warn }.count }
    var unknownCount: Int { checks.filter { $0.status == .unknown }.count }
    private var anyFailing: Bool { checks.contains { $0.status == .fail } }
    /// Whether the start-up counts as ready for the service (see `startUpReady`).
    var bootReady: Bool {
        startUpReady(steps: bootSteps.map(\.state), problems: problemCount, unknown: unknownCount, checks: checks.count)
    }

    /// Before the first pass, and when nothing applies (nothing switched on under This Mac, or
    /// everything muted), the window and the menu bar say so the same way rather than show a tick.
    private var idle: (symbol: String, title: String)? {
        if lastChecked == nil { return ("hourglass", "Checking\u{2026}") }
        if checks.isEmpty { return ("circle.dashed", "Nothing to check on this Mac") }
        return nil
    }

    /// Icon, colour and headline shared by the window and the menu bar.
    var summary: (symbol: String, color: Color, title: String) {
        if let idle { return (idle.symbol, .secondary, idle.title) }
        if problemCount == 0 && unknownCount == 0 { return ("checkmark.seal.fill", .green, "Ready for the service") }
        if problemCount == 0 {
            return ("questionmark.circle.fill", .secondary,
                    "\(unknownCount) check\(unknownCount == 1 ? "" : "s") couldn\u{2019}t run")
        }
        return (anyFailing ? "xmark.octagon.fill" : "exclamationmark.triangle.fill", anyFailing ? .red : .orange,
                "\(problemCount) thing\(problemCount == 1 ? "" : "s") to fix")
    }

    /// The menu bar shows shape rather than colour, since macOS draws menu bar icons in one colour.
    var menuSymbol: String {
        if let idle { return idle.symbol }
        if problemCount == 0 { return unknownCount == 0 ? "checkmark.circle" : "questionmark.circle" }
        return anyFailing ? "xmark.octagon" : "exclamationmark.triangle"
    }

    /// Starts the checks and the update checks. They run whether or not the window is open, so the
    /// menu bar icon is always current.
    func start() {
        guard timers.isEmpty else { return }
        refresh()
        checkForUpdates(userInitiated: false)
        let checks = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
        let updates = Timer(timeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            self?.checkForUpdates(userInitiated: false)
        }
        for t in [checks, updates] { RunLoop.main.add(t, forMode: .common) }
        timers = [checks, updates]
    }

    /// Someone who opens the window wants the screen, so the hands-off sign gives way.
    func showWindow() {
        dismissStartSign()
        MainWindow.shared.show()
    }

    /// Whether a check belongs to what this Mac is set up for.
    func applies(_ id: String) -> Bool {
        let s = setup
        switch id {
        case "lk", "show": return s.lightkey
        // The DMX interface option sits inside Lightkey's row and hides with it, so it goes with Lightkey.
        case "dmx", "dmxLive": return s.lightkey && s.dmx
        case "midi": return s.lightkey && s.streamDeck
        case "deck", "deckapp", "nap": return s.streamDeck
        case "ac", "sleep", "lpm", "autoboot", "upd", "lock": return s.alwaysOn
        case "selfLogin": return s.alwaysOn || (autoStart && canStartShow)
        case "autoShow": return autoStart && canStartShow
        case "loginShows", "loginShow": return s.alwaysOn && s.lightkey
        case "deckLogin": return s.alwaysOn && s.streamDeck
        case "acc": return hasAccessoryPrompt && s.alwaysOn && ((s.lightkey && s.dmx) || s.streamDeck)
        default: return true                                  // Booth Check's own checks, extra apps
        }
    }

    /// There's something to start when any app is switched on for this Mac.
    var canStartShow: Bool { setup.lightkey || setup.streamDeck || setup.apps.contains(where: \.on) }

    /// What Get the show started opens, in order, in plain words.
    var startOrder: String {
        let steps = setup.apps.filter(\.on).map(\.name)
            + (setup.lightkey ? [showName.map { "Lightkey with \(($0 as NSString).deletingPathExtension)" } ?? "Lightkey"] : [])
            + (setup.streamDeck ? ["Stream Deck"] : [])
        switch steps.count {
        case 0: return "Switch on an app above first."
        case 1: return "Opens \(steps[0])."
        default: return "Opens " + steps.dropLast().joined(separator: ", then ") + ", then \(steps.last!)."
        }
    }

    /// "4 checks off for this Mac · 1 muted", shown wherever the status is, so a trimmed list is
    /// never mistaken for a clean one.
    var offSummary: String? {
        var parts: [String] = []
        if offForThisMac > 0 { parts.append("\(offForThisMac) check\(offForThisMac == 1 ? "" : "s") off for this Mac") }
        if !mutedChecks.isEmpty { parts.append("\(mutedChecks.count) muted") }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    func mute(_ check: Check) {
        muted.insert(check.id)
        logSetting("Muted \u{201C}\(check.title)\u{201D}", "It stays listed under Muted on this Mac, with an Unmute button.")
    }

    func unmute(_ check: Check) {
        muted.remove(check.id)
        logSetting("Unmuted \u{201C}\(check.title)\u{201D}", "It\u{2019}s checked again.")
    }

    /// Adds any app this Mac should keep open. Picking Lightkey or Stream Deck just switches those on.
    func addApp() {
        let panel = NSOpenPanel()
        panel.title = "Add an app Booth Check should keep open"
        panel.prompt = "Add"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url),
              let id = bundle.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        switch id {
        case IDs.lightkey: setup.lightkey = true
        case IDs.streamDeck: setup.streamDeck = true
        default:
            if let i = setup.apps.firstIndex(where: { $0.bundleID == id }) {
                setup.apps[i].on = true
            } else {
                setup.apps.append(ExtraApp(bundleID: id, name: name, on: true))
            }
        }
        logSetting("Added \(name)", "Booth Check checks it\u{2019}s open, and opens it when the show starts.")
    }

    func removeApp(_ app: ExtraApp) {
        setup.apps.removeAll { $0.bundleID == app.bundleID }
        muted.remove("app:\(app.bundleID)")
        logSetting("Removed \(app.name)", "Booth Check no longer checks or opens it.")
    }

    func confirmSetup() {
        setup.save()
        needsSetup = false
        showSetup = false
        logSetting("This Mac: \(setup.summary.isEmpty ? "nothing switched on" : setup.summary)",
                   "\(offForThisMac) check\(offForThisMac == 1 ? "" : "s") off for this Mac.")
    }

    /// Booth Check's own settings go in the Log too, so a silenced check can always be traced.
    func logSetting(_ title: String, _ output: String) {
        changes.insert(LogEntry(title: title, language: "Booth Check setting", code: title, output: output, status: nil), at: 0)
    }
}

// MARK: - Timing and getting the show started

extension Booth {
    /// Called by the 15-second timer. Holds off while a change is waiting for approval.
    func tick() {
        if pending == nil { refresh() }
    }

    /// The start-up order, as numbered steps. The same list is shown in This Mac before anyone
    /// restarts, and ticks off live in the start-up panel while it runs.
    func plannedSteps(checkOnly: Bool = false) -> [BootStep] {
        var steps: [BootStep] = []
        if !checkOnly {
            // Lightkey attaches to the DMX interface when it opens, so the interface comes first.
            if setup.lightkey && setup.dmx { steps.append(BootStep(id: "dmxWait", title: "Wait for the DMX interface")) }
            for app in setup.apps where app.on { steps.append(BootStep(id: "app:\(app.bundleID)", title: "Open \(app.name)")) }
            if setup.lightkey {
                let show = showName.map { ($0 as NSString).deletingPathExtension }
                steps.append(BootStep(id: "lightkey", title: show.map { "Open \($0) in Lightkey" } ?? "Open Lightkey"))
            }
            // The Stream Deck plugin looks for Lightkey's MIDI input when it starts.
            if setup.lightkey && setup.streamDeck { steps.append(BootStep(id: "midi", title: "Wait for Lightkey to be ready for the Stream Deck")) }
            if setup.lightkey && setup.dmx { steps.append(BootStep(id: "dmxLink", title: "Lightkey connects to the DMX interface")) }
            if setup.streamDeck { steps.append(BootStep(id: "deck", title: "Open Stream Deck in the background")) }
        }
        steps.append(BootStep(id: "check", title: "Check everything"))
        return steps
    }

    /// Runs the start-up steps in order, shown live in a small panel that floats over everything,
    /// full-screen Lightkey included. Opens apps only; changes no settings. `checkOnly` is the
    /// login path on a Mac that doesn't start the show: just check, and show the result. `atLogin`
    /// is the start-up that runs by itself at login, which also puts up the hands-off sign.
    func startShow(checkOnly: Bool = false, atLogin: Bool = false) {
        guard !starting else { return }
        starting = true
        bootFinished = false
        bootSettled = false
        bootSteps = plannedSteps(checkOnly: checkOnly)
        signOn = startUpShowsSign(atLogin: atLogin, steps: bootSteps.map(\.id))
        signLightkeyOpened = isRunning(IDs.lightkey)       // reopened by macOS, it may be asking already
        signDMXLinked = false
        ReplugOverlay.shared.onHide = { [weak self] in self?.updateSign() }
        BootPanel.shared.show(steps: bootSteps.count)
        runStep(0)
    }

    /// Keeps the hands-off sign in step with the start-up (see `startSign`). Called when a step starts
    /// and when the replug sign comes or goes; Lightkey holding the DMX interface counts from the next step.
    private func updateSign() {
        guard signOn, starting else { return }
        let sign = startSign(replugShowing: ReplugOverlay.shared.isShowing, asksPassword: setup.lightkey && setup.dmx,
                             lightkeyOpened: signLightkeyOpened, dmxLinked: signDMXLinked)
        let step = bootSteps.firstIndex { $0.state == .running }
            .map { "Step \($0 + 1) of \(bootSteps.count): \(bootSteps[$0].title)" }
        StartSignOverlay.shared.show(sign, step: step ?? "", show: showName.map { ($0 as NSString).deletingPathExtension })
    }

    /// Someone wants the screen (Open Booth Check, or Hide on the start-up panel), so the hands-off sign
    /// goes for the rest of this start-up. The start-up itself carries on.
    func dismissStartSign() {
        signOn = false
        StartSignOverlay.shared.hide()
    }

    private func setStep(_ i: Int, _ state: StepState, _ detail: String? = nil) {
        guard i < bootSteps.count else { return }
        bootSteps[i].state = state
        if let detail { bootSteps[i].detail = detail }
        if state != .running {
            changes.insert(LogEntry(title: "Start-up \(i + 1): \(bootSteps[i].title)", language: "Start-up",
                                    code: bootSteps[i].title, output: bootSteps[i].detail ?? "Done.",
                                    status: state == .done ? 0 : 1), at: 0)
        }
    }

    /// Re-tests `test` every `interval` seconds until it passes, `timeout` runs out, or `stop` says
    /// to give up (checked on the main thread). Shell-based tests run off the main thread.
    private func poll(every interval: TimeInterval = 1, for timeout: TimeInterval, background: Bool = false,
                      _ test: @escaping () -> Bool, stop: @escaping () -> Bool = { false },
                      done: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func attempt() {
            let evaluate = {
                let ok = test()
                DispatchQueue.main.async {
                    if ok { done(true) }
                    else if stop() || Date() > deadline { done(false) }
                    else { DispatchQueue.main.asyncAfter(deadline: .now() + interval) { attempt() } }
                }
            }
            if background { DispatchQueue.global(qos: .userInitiated).async(execute: evaluate) } else { evaluate() }
        }
        attempt()
    }

    private func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private func runStep(_ i: Int) {
        guard i < bootSteps.count else { return finishBoot() }
        let next = { self.runStep(i + 1) }
        setStep(i, .running)
        let id = bootSteps[i].id
        if id == "lightkey" { signLightkeyOpened = true }
        updateSign()

        switch id {
        case "dmxWait":
            // Plugged in all along, the interface sometimes isn't seen until it's unplugged and plugged
            // back in (church Mac, 29 Sept 2026; other restarts found it at once; cause not known yet).
            // Lightkey isn't open yet, so a replug is safe here and is picked up within a second. Only
            // ask when it's really missing: not in the first 10 seconds, which a slow start-up needs.
            // Then a big sign in the middle of the screen says so (the panel's small text got missed),
            // and the wait runs to 90 s so someone can get to the cable; it can also be skipped.
            var skipped = false
            let ask = DispatchWorkItem {
                guard i < self.bootSteps.count, self.bootSteps[i].id == "dmxWait",
                      self.bootSteps[i].state == .running else { return }
                self.setStep(i, .running, "Not found yet: unplug the DMX box\u{2019}s USB cable and plug it back in.")
                ReplugOverlay.shared.show { skipped = true }
                self.updateSign()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: ask)
            poll(for: 90, background: true, {
                usbDevices(shell("/usr/sbin/ioreg", ["-p", "IOUSB", "-l", "-w0"]).out).contains(where: isDMXInterface)
            }, stop: { skipped }, done: { ok in
                ask.cancel()
                if ok { ReplugOverlay.shared.found() } else { ReplugOverlay.shared.hide() }
                self.setStep(i, ok ? .done : .warn,
                             ok ? "Found on USB."
                                : skipped ? "Skipped, so Lightkey opens without it."
                                : "Not found in 90 seconds, so Lightkey opens anyway. No lights? Replug the DMX USB cable, then reopen Lightkey.")
                next()
            })

        case _ where id.hasPrefix("app:"):
            let bundleID = String(id.dropFirst(4))
            if isRunning(bundleID) {
                setStep(i, .done, "Already open.")
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                // On a Lightkey Mac, Lightkey should end up in front, so other apps open behind it.
                let config = NSWorkspace.OpenConfiguration()
                config.activates = !setup.lightkey
                NSWorkspace.shared.openApplication(at: url, configuration: config)
                setStep(i, .done, "Opened.")
            } else {
                setStep(i, .failed, "Not installed on this Mac.")
            }
            next()

        case "lightkey":
            let wasRunning = isRunning(IDs.lightkey)
            // A show that was moved or renamed can't be opened, so open Lightkey on its own and say why.
            let showMissing = showPath.map { !FileManager.default.fileExists(atPath: $0) } ?? false
            if let showPath, !showMissing {
                NSWorkspace.shared.open(URL(fileURLWithPath: showPath))
            } else if !wasRunning, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: IDs.lightkey) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            } else if !wasRunning {
                setStep(i, .failed, "Lightkey isn\u{2019}t installed on this Mac.")
                return next()
            }
            // Two different prompts can appear here: Lightkey asking for the Mac's password to take
            // the DMX interface (any Mac), and macOS asking to allow the accessory (Apple silicon only).
            let hints = [setup.dmx ? "If Lightkey asks, click Authenticate and type the Mac\u{2019}s password." : nil,
                         hasAccessoryPrompt ? "If macOS asks to allow an accessory, click Allow." : nil].compactMap { $0 }
            setStep(i, .running, hints.isEmpty ? nil : hints.joined(separator: " "))
            poll(for: 45, { self.isRunning(IDs.lightkey) }) { ok in
                if !ok {
                    self.setStep(i, .failed, "Lightkey didn\u{2019}t open within 45 seconds.")
                } else if showMissing {
                    self.setStep(i, .failed, "Can\u{2019}t find \(self.showName ?? "the show"): it was moved, renamed or deleted. Open the show from Lightkey\u{2019}s File menu, then choose it again in Booth Check.")
                } else if let showPath = self.showPath {
                    return self.confirmShowOpen(i, showPath, doneText: wasRunning ? "Already open; brought to the front." : "Opened.",
                                                then: next)
                } else {
                    self.setStep(i, .warn, "No show is chosen in Booth Check, so open it in Lightkey.")
                }
                next()
            }

        case "midi":
            poll(every: 0.5, for: 45, {
                MIDIWatch.shared.destinationNames().contains { $0.localizedCaseInsensitiveContains(IDs.lightkeyMIDIInput) }
            }) { ok in
                self.setStep(i, ok ? .done : .warn,
                             ok ? "Lightkey\u{2019}s MIDI input is ready." : "Not ready after 45 seconds. Opening Stream Deck anyway.")
                next()
            }

        case "dmxLink":
            guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: IDs.lightkey).first?.processIdentifier else {
                setStep(i, .warn, "Lightkey isn\u{2019}t open.")
                return next()
            }
            // A minute, so a person has time to type the password Lightkey asks for.
            setStep(i, .running, "If Lightkey asks, click Authenticate and type the Mac\u{2019}s password.")
            poll(every: 2, for: 60, background: true, {
                // Asked again each time: olad, which holds the interface for Lightkey, can start late.
                let pids = dmxDriverPIDs(lightkey: pid, psOutput: shell("/bin/ps", ["-axo", "pid=,comm="]).out)
                return !usbConnections(shell("/usr/sbin/ioreg", ["-l", "-w0", "-c", "IOUserClient"]).out, pids: pids).isEmpty
                    || shell("/usr/sbin/lsof", ["-p", pids.map(String.init).joined(separator: ","), "-Fn"]).out.split(separator: "\n").contains {
                        $0.hasPrefix("n/dev/") && ($0.contains("usbserial") || $0.contains("usbmodem"))
                    }
            }) { ok in
                if ok { self.signDMXLinked = true }     // it has the interface, so it's past its password
                self.setStep(i, ok ? .done : .warn,
                             ok ? "Lightkey has the interface open."
                                : "Couldn\u{2019}t confirm (this check is experimental). If the lights respond, all is well.")
                next()
            }

        case "deck":
            // Out of sight is exactly what App Nap puts to sleep, so switch it off before Stream Deck
            // opens. Apps read the setting when they launch, so this takes effect for Stream Deck
            // straight away, with no restart. No password needed; the command goes in the Log.
            let napOff = shell("/usr/bin/defaults", ["read", "-g", "NSAppSleepDisabled"])
                .out.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
            var napSwitched = false
            if !napOff {
                let args = ["write", "-g", "NSAppSleepDisabled", "-bool", "true"]
                let r = shell("/usr/bin/defaults", args)
                changes.insert(LogEntry(title: "Start-up: switched App Nap off for Stream Deck", language: "Terminal",
                                        code: commandLine("/usr/bin/defaults", args),
                                        output: r.out.isEmpty ? "(no output)" : r.out, status: r.code), at: 0)
                napSwitched = r.code == 0
                if napSwitched { appNapSwitchedOffAt = Date() }
            }

            if isRunning(IDs.streamDeck) {
                if napSwitched {
                    setStep(i, .warn, "Already open, but it started before App Nap was switched off. Quit and reopen Stream Deck once so it stays awake in the background.")
                } else {
                    setStep(i, .done, "Already open.")
                }
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: IDs.streamDeck) {
                // In the background, so Lightkey stays in front and full screen isn't interrupted.
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: config)
                setStep(i, .done, napSwitched
                    ? "Switched App Nap off, then opened it behind Lightkey, so it keeps running there."
                    : "Opened behind Lightkey. App Nap is off, so it keeps running there.")
            } else {
                setStep(i, .failed, "Not installed on this Mac.")
            }
            next()

        default:        // "check"
            refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                let n = self.problemCount
                self.setStep(i, n == 0 ? .done : .warn,
                             n == 0 ? "Everything is green." : "\(n) thing\(n == 1 ? "" : "s") to fix. Open Booth Check to see what.")
                next()
            }
        }
    }

    /// Lightkey doesn't load the show until someone clicks Authenticate and types the Mac's password
    /// (it unloads the Mac's FTDI driver to reach the Open DMX USB), and until then it sits on its
    /// project screen (church Mac, 29 Sept 2026). So with Accessibility, wait for the show and say what
    /// to do, so the MIDI and DMX steps don't run ahead. Nothing is re-sent: another open request while
    /// Lightkey's alert is up could only confuse it. Without Accessibility there's nothing to look at.
    private func confirmShowOpen(_ i: Int, _ showPath: String, doneText: String, then next: @escaping () -> Void) {
        let name = URL(fileURLWithPath: showPath).deletingPathExtension().lastPathComponent
        let started = Date()
        func look() {
            var isOpen: Bool?
            if AXIsProcessTrusted() {
                let pid = NSRunningApplication.runningApplications(withBundleIdentifier: IDs.lightkey).first?.processIdentifier
                isOpen = pid.map { let (docs, titles) = windowsOf(pid: $0); return showIsOpen(showPath, docs: docs, titles: titles) } ?? false
            }
            switch showOpenNext(isOpen: isOpen, waited: Date().timeIntervalSince(started)) {
            case .done:
                self.setStep(i, .done, doneText)
                next()
            case .notShowing:
                self.setStep(i, .warn, "\(name) isn\u{2019}t open after 2 minutes. Click Authenticate if Lightkey asks, or open it from File \u{2192} Open Recent.")
                next()
            case .wait:
                self.setStep(i, .running, "Waiting for \(name). If Lightkey asks, click Authenticate and type the Mac\u{2019}s password.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { look() }
            }
        }
        look()
    }

    /// All green: the panel hides itself shortly after. Anything else: it stays until dismissed. The
    /// hands-off sign says which it was for a moment, then goes.
    private func finishBoot() {
        starting = false
        bootFinished = true
        if signOn { StartSignOverlay.shared.finish(ready: bootReady) }
        if bootSteps.allSatisfy({ $0.state == .done }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                if self.bootFinished && !self.starting { BootPanel.shared.hide() }
            }
        }
    }
}

// MARK: - Updating

extension Booth {
    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var updateAvailable: Bool { latest.map { isNewer($0.version, than: currentVersion) } ?? false }

    /// Why this copy can't replace itself where it is, if it can't.
    var installProblem: String? {
        let app = Bundle.main.bundleURL
        if app.path.contains("/AppTranslocation/") {
            return "macOS is running this copy from a temporary location. Drag Booth Check into Applications, open it from there, then update."
        }
        let folder = app.deletingLastPathComponent().path
        if !FileManager.default.isWritableFile(atPath: folder) {
            return "Booth Check can't write to \(folder). Move it into Applications first."
        }
        return nil
    }

    /// Asks GitHub for the newest release. Only reads; installing is a separate, approved step.
    func checkForUpdates(userInitiated: Bool) {
        var request = URLRequest(url: Repo.latestAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BoothCheck/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        updateStatus = "Checking for updates\u{2026}"
        URLSession.shared.dataTask(with: request) { data, response, error in
            let http = (response as? HTTPURLResponse)?.statusCode ?? 0
            let release = data.flatMap(parseRelease)
            DispatchQueue.main.async {
                let summary: String
                if let error {
                    summary = error.localizedDescription
                } else if let release {
                    summary = "Newest release: \(release.tag)\nDownload: \(release.zipName), \(release.size) bytes\nSHA-256: \(release.sha256 ?? "not given")"
                } else {
                    summary = "HTTP \(http): no release with a zip attached."
                }
                self.updateLog.insert(LogEntry(title: "Check for updates", language: "Network",
                                               code: "GET \(Repo.latestAPI.absoluteString)",
                                               output: summary, status: release == nil ? 1 : 0), at: 0)
                if self.updateLog.count > 20 { self.updateLog.removeLast(self.updateLog.count - 20) }
                guard let release else {
                    self.updateStatus = "Couldn\u{2019}t reach GitHub to check for updates."
                    return
                }
                self.latest = release
                if self.updateAvailable {
                    self.updateStatus = "Version \(release.version) is available."
                    if userInitiated { self.showUpdate = true }
                } else {
                    self.updateStatus = "Up to date."
                }
            }
        }.resume()
    }

    /// Downloads, checks and installs a release, then reopens. Stops before touching anything if a
    /// check fails, and puts the old copy back if the swap itself fails.
    func installUpdate(_ r: Release) {
        updating = true
        updateError = nil
        updateSteps = []
        let current = Bundle.main.bundleURL
        let bundleID = Bundle.main.bundleIdentifier ?? ""

        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("BoothCheckUpdate-\(UUID().uuidString)")

            func step(_ s: String) { DispatchQueue.main.async { self.updateSteps.append(s) } }
            func log(_ title: String, _ language: String, _ code: String, _ output: String, _ status: Int32) {
                let e = LogEntry(title: title, language: language, code: code, output: output, status: status)
                DispatchQueue.main.async { self.changes.insert(e, at: 0) }
            }
            func fail(_ s: String) {
                try? fm.removeItem(at: work)
                DispatchQueue.main.async {
                    self.updateError = s
                    self.updating = false
                }
            }

            do { try fm.createDirectory(at: work, withIntermediateDirectories: true) } catch {
                return fail("Couldn\u{2019}t make a temporary folder: \(error.localizedDescription)")
            }

            // 1. Download
            let zip = work.appendingPathComponent(r.zipName)
            let done = DispatchSemaphore(value: 0)
            var body: Data?
            var problem: String?
            URLSession.shared.dataTask(with: URLRequest(url: r.zipURL, timeoutInterval: 120)) { data, response, error in
                if let error { problem = error.localizedDescription }
                else if let http = response as? HTTPURLResponse, http.statusCode != 200 { problem = "HTTP \(http.statusCode)" }
                else { body = data }
                done.signal()
            }.resume()
            done.wait()
            guard let data = body, (try? data.write(to: zip)) != nil else {
                log("Update: download", "Network", "GET \(r.zipURL.absoluteString)", problem ?? "No data", 1)
                return fail("The download failed: \(problem ?? "no data").")
            }
            log("Update: download", "Network", "GET \(r.zipURL.absoluteString)", "\(data.count) bytes saved to \(zip.path)", 0)
            step("Downloaded \(r.zipName) (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))")

            // 2. Checksum
            guard let expected = r.sha256 else {
                return fail("GitHub didn\u{2019}t give a checksum for this download, so it wasn\u{2019}t installed.")
            }
            let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            log("Update: check the download", "macOS API", "CryptoKit: SHA-256 of \(r.zipName)",
                "GitHub says \(expected)\nDownload is \(got)", got == expected ? 0 : 1)
            guard got == expected else {
                return fail("The download doesn\u{2019}t match GitHub\u{2019}s checksum, so it wasn\u{2019}t installed.")
            }
            step("Checksum matches GitHub\u{2019}s")

            // 3. Unzip
            let unzipped = work.appendingPathComponent("unzipped")
            let unzipArgs = ["-x", "-k", zip.path, unzipped.path]
            let u = shell("/usr/bin/ditto", unzipArgs)
            log("Update: unzip", "Terminal", commandLine("/usr/bin/ditto", unzipArgs), u.out.isEmpty ? "(no output)" : u.out, u.code)
            guard u.code == 0,
                  let newApp = (try? fm.contentsOfDirectory(at: unzipped, includingPropertiesForKeys: nil))?
                    .first(where: { $0.pathExtension == "app" }) else {
                return fail("Couldn\u{2019}t unzip the update.")
            }
            step("Unzipped")

            // 4. Is it really Booth Check at that version, with an intact signature?
            let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
            let newID = info?["CFBundleIdentifier"] as? String
            let newVersion = info?["CFBundleShortVersionString"] as? String
            guard newID == bundleID, newVersion == r.version else {
                return fail("The download isn\u{2019}t Booth Check \(r.version) (it says \(newID ?? "?") \(newVersion ?? "?")), so it wasn\u{2019}t installed.")
            }
            let sigArgs = ["--verify", "--deep", "--strict", newApp.path]
            let sig = shell("/usr/bin/codesign", sigArgs)
            log("Update: check the app", "Terminal", commandLine("/usr/bin/codesign", sigArgs),
                sig.out.isEmpty ? "Signature is intact." : sig.out, sig.code)
            guard sig.code == 0 else {
                return fail("The new app\u{2019}s signature is broken, so it wasn\u{2019}t installed.")
            }
            step("It\u{2019}s Booth Check \(r.version), signature intact")

            // 5. Swap: old copy to the Trash (recoverable), new copy into its place.
            var trashed: NSURL?
            do { try fm.trashItem(at: current, resultingItemURL: &trashed) } catch {
                return fail("Couldn\u{2019}t move the old copy to the Trash: \(error.localizedDescription)")
            }
            do { try fm.moveItem(at: newApp, to: current) } catch {
                if let t = trashed as URL? { try? fm.moveItem(at: t, to: current) }
                return fail("Couldn\u{2019}t put the new version in place, so the old one was put back: \(error.localizedDescription)")
            }
            log("Update: replace", "macOS API",
                "FileManager: move \(current.path) to the Trash, then move the new app to \(current.path)",
                "The old copy is in the Trash: \((trashed as URL?)?.path ?? "?")", 0)
            step("Installed \(r.version). The old copy is in the Trash")
            try? fm.removeItem(at: work)

            // 6. Reopen the new copy once this one has quit. The helper waits for this process to be
            //    gone so two copies never run side by side. AppKit won't quit while a sheet is open,
            //    so close it first, and fall back to exit() if quitting is still refused.
            DispatchQueue.main.async {
                self.updateSteps.append("Reopening\u{2026}")
                let pid = String(ProcessInfo.processInfo.processIdentifier)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", "while /bin/kill -0 \"$2\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$1\"",
                               "sh", current.path, pid]
                try? p.run()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.showUpdate = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { exit(0) }
                }
            }
        }
    }
}

// MARK: - Views

struct UpdateSheet: View {
    @ObservedObject var booth: Booth
    let release: Release

    private var notes: AttributedString {
        (try? AttributedString(markdown: release.notes,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(release.notes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Update to Booth Check \(release.version)").font(.system(size: 17, weight: .bold))
                    Text("You have \(booth.currentVersion).").font(.system(size: 12)).foregroundStyle(.secondary)
                    if !release.notes.isEmpty {
                        Text("What\u{2019}s new").font(.system(size: 12, weight: .semibold))
                        ScrollView {
                            Text(notes).font(.system(size: 12)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                        .frame(maxHeight: 110)
                        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                    }
                    Text("What happens when you press Update").font(.system(size: 12, weight: .semibold))
                    stepRow(1, "Download \(release.zipName) (\(ByteCountFormatter.string(fromByteCount: Int64(release.size), countStyle: .file))) from GitHub:",
                            release.zipURL.absoluteString)
                    stepRow(2, "Check it matches the SHA-256 checksum GitHub gives for it:",
                            release.sha256 ?? "GitHub gave no checksum, so the update will stop here.")
                    stepRow(3, "Unzip it into a temporary folder:",
                            "/usr/bin/ditto -x -k <download> <temporary folder>")
                    stepRow(4, "Check it\u{2019}s Booth Check \(release.version) and its signature is intact:",
                            "/usr/bin/codesign --verify --deep --strict <new app>")
                    stepRow(5, "Move this copy to the Trash and put the new one in its place:",
                            Bundle.main.bundleURL.path)
                    stepRow(6, "Reopen Booth Check. macOS asks for the System Events and Accessibility permissions again, because it\u{2019}s a new build.", nil)
                    Text("If any check fails, nothing is changed.").font(.system(size: 11)).foregroundStyle(.secondary)

                    if !booth.updateSteps.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(booth.updateSteps, id: \.self) { s in
                                Label(s, systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
                            }
                        }
                    }
                    if let err = booth.updateError {
                        Label(err, systemImage: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let problem = booth.installProblem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12))
                            .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Button("Release page") { NSWorkspace.shared.open(release.page) }
                Spacer()
                Button("Cancel") { booth.showUpdate = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(booth.updating)
                Button(booth.updating ? "Updating\u{2026}" : "Update") { booth.installUpdate(release) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(booth.updating || booth.installProblem != nil || release.sha256 == nil)
            }
            .padding(16)
        }
        .frame(width: 560, height: 600)
    }

    private func stepRow(_ n: Int, _ text: String, _ code: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary).frame(width: 14, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                if let code { CodeBlock(text: code) }
            }
        }
    }
}

/// "This Mac": which apps this Mac runs, and how it starts. Switching an app on switches on every
/// check that belongs to it, deep ones included (DMX in use, Lightkey listening for the deck).
struct SetupSheet: View {
    @ObservedObject var booth: Booth

    private let indent: CGFloat = 46       // lines content up under the app name, past the icon

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("This Mac").font(.system(size: 20, weight: .bold))
                        Text("Booth Check looks after the apps switched on here.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }

                    group("Apps on this Mac") {
                        AppRow(bundleID: IDs.lightkey, name: "Lightkey",
                               detail: "Runs the show. Checks it\u{2019}s open with the right show.",
                               isOn: $booth.setup.lightkey) {
                            if booth.setup.lightkey { lightkeyOptions }
                        }
                        Divider().padding(.leading, indent)
                        AppRow(bundleID: IDs.streamDeck, name: "Stream Deck",
                               detail: booth.setup.lightkey
                                ? "Controls Lightkey. Checks the deck, its app, and that Lightkey is listening for it."
                                : "Checks the deck is plugged in and its app is open.",
                               isOn: $booth.setup.streamDeck) { EmptyView() }
                        ForEach($booth.setup.apps) { $app in
                            Divider().padding(.leading, indent)
                            AppRow(bundleID: app.bundleID, name: app.name, detail: "Checks it\u{2019}s open.",
                                   isOn: $app.on, remove: { booth.removeApp(app) }) { EmptyView() }
                        }
                        Divider().padding(.leading, indent)
                        Button { booth.addApp() } label: { Label("Add an app\u{2026}", systemImage: "plus") }
                            .buttonStyle(.borderless)
                            .padding(.leading, indent)
                            .padding(.vertical, 10)
                    }

                    group("Power and startup") {
                        SettingRow(symbol: "powerplug.fill", tint: .gray, title: "Stays on for services",
                                   detail: "Checks the charger, sleep, updates and what opens at login.",
                                   isOn: $booth.setup.alwaysOn)
                        Divider().padding(.leading, indent)
                        SettingRow(symbol: "play.fill", tint: .green, title: "Start the show when the Mac starts",
                                   detail: !booth.canStartShow ? "Switch on an app above first."
                                    : booth.autoStart ? "Booth Check opens at login and does this, in order, instead of macOS:"
                                    : "Off: macOS login items open whatever they\u{2019}re set to, in no set order.",
                                   isOn: $booth.autoStart)
                            .disabled(!booth.canStartShow)
                        if booth.autoStart && booth.canStartShow {
                            BootStepsList(steps: booth.plannedSteps(), live: false)
                                .padding(.leading, indent)
                                .padding(.bottom, 10)
                        }
                        let others = booth.loginItems.filter { !$0.name.localizedCaseInsensitiveContains("Booth Check") }
                        if !others.isEmpty {
                            Divider().padding(.leading, indent)
                            HStack(alignment: .firstTextBaseline) {
                                Text("Also opened by macOS at login: " + others.map(\.name).joined(separator: ", "))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Button("Login Items\u{2026}") { NSWorkspace.shared.open(Settings.loginItems) }
                                    .buttonStyle(.link).font(.system(size: 11))
                            }
                            .padding(.leading, indent)
                            .padding(.vertical, 10)
                        }
                    }

                    if !booth.mutedChecks.isEmpty {
                        group("Muted") {
                            ForEach(booth.mutedChecks) { check in
                                HStack {
                                    Label(check.title, systemImage: "bell.slash").font(.system(size: 12))
                                    Spacer()
                                    Button("Unmute") { booth.unmute(check) }.controlSize(.small)
                                }
                                .padding(.vertical, 8)
                            }
                        }
                    }
                }
                .padding(22)
            }
            Divider()
            HStack {
                Text(booth.offSummary ?? "Everything switched on here is checked.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { booth.confirmSetup() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 540, height: 640)
    }

    /// The DMX interface belongs to Lightkey, so it sits inside its row. The show itself is chosen
    /// on the main window, the one place people look for it.
    private var lightkeyOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $booth.setup.dmx) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("A DMX interface is plugged in here").font(.system(size: 12))
                    Text("Checks it\u{2019}s connected and that Lightkey is using it.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
        }
        .padding(.leading, indent)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        }
    }
}

/// One app: its own icon, what Booth Check does for it, and a switch.
struct AppRow<Extra: View>: View {
    let bundleID: String
    let name: String
    let detail: String
    @Binding var isOn: Bool
    var remove: (() -> Void)? = nil
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) }
                      ?? NSWorkspace.shared.icon(for: .applicationBundle))
                    .resizable()
                    .frame(width: 34, height: 34)
                    .opacity(url == nil ? 0.45 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(name).font(.system(size: 13, weight: .semibold))
                        if url == nil {
                            Text("Not installed")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }
                    }
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let remove {
                    Button("Remove", action: remove).buttonStyle(.borderless).font(.system(size: 11))
                }
                Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden()
            }
            extra()
        }
        .padding(.vertical, 10)
    }
}

/// A Mac-wide setting, with a small symbol tile the size of an app icon so the rows line up.
struct SettingRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.gradient)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden()
        }
        .padding(.vertical, 10)
    }
}

struct CodeBlock: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
            }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .controlSize(.mini)
            .padding(6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
    }
}

struct OutputBlock: View {
    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let status = entry.status {
                Label(status == 0 ? "Finished" : "Failed (code \(status))",
                      systemImage: status == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(status == 0 ? Color.green : Color.red)
            }
            ScrollView {
                Text(entry.output.count > 6000 ? String(entry.output.prefix(6000)) + "\n\u{2026}" : entry.output)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 180)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
        }
    }
}

struct ChangeSheet: View {
    let change: PendingChange
    @ObservedObject var booth: Booth
    @State private var result: LogEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(change.title).font(.system(size: 17, weight: .bold))
            Text(change.explanation)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(result == nil ? "Booth Check will run this \(change.language):" : "Ran this \(change.language):")
                .font(.system(size: 12, weight: .semibold))
            CodeBlock(text: change.code)
            if let undo = change.undo {
                Text("To undo it later, run:").font(.system(size: 11)).foregroundStyle(.secondary)
                CodeBlock(text: undo)
            }
            if let result { OutputBlock(entry: result) }
            HStack {
                Spacer()
                if result == nil {
                    Button("Cancel") { booth.finishChange() }.keyboardShortcut(.cancelAction)
                    Button("Run") { result = booth.run(change) }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { booth.finishChange() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}

struct LogSheet: View {
    @ObservedObject var booth: Booth
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log").font(.system(size: 17, weight: .bold))
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    heading("What you asked Booth Check to do", "Changes you approved, apps it opened for you, and updates, since it opened.")
                    if booth.changes.isEmpty {
                        Text("Nothing changed yet.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(booth.changes) { entryView($0, showOutput: true) }
                    Divider().padding(.vertical, 4)
                    heading("Update checks", "Booth Check asks GitHub for the newest release when it opens, every six hours, and when you ask. This only reads.")
                    if booth.updateLog.isEmpty {
                        Text("No update check yet.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(booth.updateLog) { entryView($0, showOutput: true) }
                    Divider().padding(.vertical, 4)
                    heading("Last check", "What was read to fill in the checks, at "
                            + (booth.lastChecked?.formatted(date: .omitted, time: .standard) ?? "\u{2014}")
                            + ". These only read; they change nothing.")
                    ForEach(booth.lastPass) { entryView($0, showOutput: false) }
                }
                .padding(16)
            }
        }
        .frame(width: 640, height: 640)
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func entryView(_ e: LogEntry, showOutput: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(e.title).font(.system(size: 12, weight: .semibold))
                Text(e.language)
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                Spacer()
                Text(e.time.formatted(date: .omitted, time: .standard)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            CodeBlock(text: e.code)
            if showOutput {
                OutputBlock(entry: e)
            } else {
                DisclosureGroup("Output") { OutputBlock(entry: e) }.font(.system(size: 11))
            }
        }
    }
}

struct CheckRow: View {
    let check: Check
    let perform: (Action) -> Void
    var mute: ((Check) -> Void)? = nil
    @State private var showInfo = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: check.status.symbol)
                .font(.system(size: 16))
                .foregroundStyle(check.status.color)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(check.title).font(.system(size: 13, weight: .semibold))
                    if let info = check.info {
                        Button { showInfo.toggle() } label: {
                            Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("What this does")
                        .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(check.title).font(.system(size: 13, weight: .bold))
                                Text(info).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            .padding(14)
                            .frame(width: 380)
                        }
                    }
                }
                Text(check.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if check.status != .ok, let fix = check.fix {
                    Text(fix).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if check.status != .ok, let action = check.action {
                Button(action.label) { perform(action) }.controlSize(.small)
            }
            if check.status != .ok, let mute {
                Button { mute(check) } label: { Image(systemName: "bell.slash").font(.system(size: 11)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Mute this check on this Mac. It stays listed under Muted, with Unmute.")
                    .accessibilityLabel("Mute \(check.title)")
            }
        }
        .padding(.vertical, 5)
        .contextMenu {
            if let mute { Button("Mute \u{201C}\(check.title)\u{201D} on this Mac") { mute(check) } }
        }
    }
}

struct ContentView: View {
    @ObservedObject var booth: Booth
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let message = booth.message {
                        Label(message, systemImage: "exclamationmark.bubble")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if !booth.bootSteps.isEmpty { startPanel }
                    if booth.setup.lightkey { showRow }
                    ForEach(groupOrder, id: \.self) { group in
                        let rows = booth.checks.filter { $0.group == group }
                        if !rows.isEmpty {
                            section(group) {
                                ForEach(rows) { check in
                                    CheckRow(check: check, perform: booth.perform, mute: booth.mute)
                                    if check.id != rows.last?.id { Divider() }
                                }
                            }
                        }
                    }
                    if !booth.mutedChecks.isEmpty { mutedList }
                    footer
                }
                .padding(16)
            }
        }
        .frame(minWidth: 780, idealWidth: 780, minHeight: 560, idealHeight: 820)
        .sheet(item: $booth.pending) { ChangeSheet(change: $0, booth: booth) }
        .sheet(isPresented: $showLog) { LogSheet(booth: booth) }
        .sheet(isPresented: $booth.showUpdate) {
            if let release = booth.latest { UpdateSheet(booth: booth, release: release) }
        }
        .sheet(isPresented: $booth.showSetup) { SetupSheet(booth: booth) }
        .onAppear { if booth.needsSetup { booth.showSetup = true } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if booth.pending == nil { booth.refresh() }
        }
    }

    private var header: some View {
        let (symbol, color, title) = booth.summary
        return HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 20, weight: .bold))
                Text(booth.lastChecked.map { "Checked at \($0.formatted(date: .omitted, time: .shortened))" } ?? "Booth Check")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let off = booth.offSummary {
                    Button { booth.showSetup = true } label: {
                        Label(off, systemImage: "slider.horizontal.3").font(.system(size: 11))
                    }
                    .buttonStyle(.link)
                    .help("Change what this Mac is set up for")
                }
            }
            Spacer()
            if booth.updateAvailable, let release = booth.latest {
                Button("Update to \(release.version)") { booth.showUpdate = true }
            }
            if booth.canStartShow {
                Button { booth.startShow() } label: {
                    if booth.starting {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Starting\u{2026}") }
                    } else {
                        Label("Get the show started", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(booth.starting)
                .help(booth.startOrder)
            }
            Button { booth.showSetup = true } label: { Label("This Mac", systemImage: "gearshape") }
                .help("Which apps this Mac runs, how it starts, and which checks are muted")
            Button { showLog = true } label: { Label("Log", systemImage: "list.bullet.rectangle") }
                .keyboardShortcut("l")
            Button("Check again") { booth.refresh() }.keyboardShortcut("r")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var mutedList: some View {
        section("Muted on this Mac") {
            ForEach(booth.mutedChecks) { check in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "bell.slash").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(check.title).font(.system(size: 12, weight: .medium))
                        Text(check.status == .ok ? "Fine right now." : check.detail)
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button("Unmute") { booth.unmute(check) }.controlSize(.small)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var startPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(booth.starting ? "Starting the show" : "Start-up").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !booth.starting {
                    Button("Dismiss") { booth.bootSteps = [] }.controlSize(.small)
                }
            }
            BootStepsList(steps: booth.bootSteps)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.1)))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Booth Check \(booth.currentVersion)").font(.system(size: 11, weight: .medium))
            Text(booth.updateStatus).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            if booth.updateAvailable {
                Button("See update\u{2026}") { booth.showUpdate = true }.controlSize(.small)
            } else {
                Button("Check for updates") { booth.checkForUpdates(userInitiated: true) }.controlSize(.small)
            }
        }
        .padding(.top, 4)
    }

    private var showRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Show for this Mac").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(booth.showName ?? "Not chosen yet")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
            }
            Spacer()
            Button(booth.showPath == nil ? "Choose show\u{2026}" : "Change\u{2026}") { booth.chooseShow() }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.22)))
        }
    }
}

/// The start-up steps, numbered because they run in this order. `live` adds each step's state and
/// what happened; without it the list is just the plan.
struct BootStepsList: View {
    let steps: [BootStep]
    var live = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { n, step in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(n + 1)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 12, alignment: .trailing)
                    if live { icon(step.state).frame(width: 16, height: 16) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title)
                            .font(.system(size: 12, weight: live && step.state == .running ? .semibold : .regular))
                            .foregroundStyle(live && step.state == .waiting ? .secondary : .primary)
                        if live, let detail = step.detail {
                            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func icon(_ state: StepState) -> some View {
        switch state {
        case .waiting: Image(systemName: "circle").font(.system(size: 12)).foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(.green)
        case .warn: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.red)
        }
    }
}

/// What the floating start-up panel shows.
struct BootView: View {
    @ObservedObject var booth: Booth

    var body: some View {
        let n = booth.problemCount
        let (symbol, color, title): (String, Color, String) =
            !booth.bootFinished ? ("play.circle.fill", .green, "Starting the show")
            : booth.bootReady ? ("checkmark.seal.fill", .green, "Ready for the service")
            : n > 0 ? ("exclamationmark.triangle.fill", .orange, "\(n) thing\(n == 1 ? "" : "s") to fix")
            : ("exclamationmark.triangle.fill", .orange, "Started, with warnings")
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(color)
                Text(title).font(.system(size: 15, weight: .bold))
                Spacer(minLength: 0)
            }
            BootStepsList(steps: booth.bootSteps)
            Spacer(minLength: 0)
            HStack {
                Button("Open Booth Check") { booth.showWindow() }
                Spacer()
                Button("Hide") {
                    BootPanel.shared.hide()
                    booth.dismissStartSign()
                }
            }
            .controlSize(.small)
        }
        .padding(16)
    }
}

/// A small panel in the top-right corner that floats over every app, full-screen Lightkey included,
/// without taking focus. It's the only way to show the start-up while Lightkey fills the screen:
/// Booth Check's own window would pull you out of Lightkey's full-screen space.
final class BootPanel {
    static let shared = BootPanel()
    private var panel: NSPanel?

    func show(steps: Int) {
        let size = NSSize(width: 360, height: 104 + CGFloat(steps) * 44)
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isFloatingPanel = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = true
            p.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: BootView(booth: Booth.shared))
            host.sizingOptions = []            // the panel's size is set here, from the number of steps
            p.contentViewController = host
            panel = p
        }
        guard let panel else { return }
        panel.setContentSize(size)
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - panel.frame.width - 16, y: screen.maxY - 16))
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    var isShowing: Bool { panel?.isVisible ?? false }
}

/// The replug sign's state: the start-up sets `found` when the DMX box is back.
final class ReplugModel: ObservableObject {
    @Published var found = false
    var skip: (() -> Void)?
}

/// The big "unplug and replug" card. Volunteers missed the small text in the top-right panel, so
/// this one is meant to be impossible to miss: large words, the same names as the booth docs (the
/// blue ENTTEC box), and the plug moving out and back in.
struct ReplugCard: View {
    @ObservedObject var model: ReplugModel

    var body: some View {
        VStack(spacing: 22) {
            if model.found {
                Spacer(minLength: 0)
                Image(systemName: "checkmark.circle.fill").font(.system(size: 110)).foregroundStyle(.green)
                Text("Found it").font(.system(size: 40, weight: .bold))
                Text("Carrying on with the start-up.").font(.system(size: 20)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                Text("Unplug the USB cable from the DMX box, then plug it back in")
                    .font(.system(size: 34, weight: .bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                TimelineView(.animation) { context in
                    ReplugAnimation(phase: context.date.timeIntervalSinceReferenceDate / 3.2)
                }
                .frame(height: 190)
                Text("The blue ENTTEC box that runs the lights. Booth Check carries on by itself as soon as it sees it again.")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Carry on without it") { model.skip?() }
                    .controlSize(.large)
            }
        }
        .padding(44)
        .frame(width: 700, height: 600)
        .background(RoundedRectangle(cornerRadius: 28).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }
}

/// One frame of a USB plug coming out of the blue DMX box and going back in, with the two steps
/// lighting up in turn. `phase` turns through one loop per 1.0 (see `replugFrame`).
struct ReplugAnimation: View {
    let phase: Double

    var body: some View {
        let frame = replugFrame(phase)
        VStack(spacing: 22) {
            // The plug sits under the box, so its metal tip disappears into the socket when it's in.
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.92), Color(white: 0.55)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 36, height: 16)
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(white: 0.96))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.black.opacity(0.3), lineWidth: 1.5))
                        .frame(width: 84, height: 44)
                    Capsule().fill(Color(white: 0.35)).frame(width: 200, height: 14)
                }
                .offset(x: 150 - 36 + frame.out * 110)
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(red: 0.13, green: 0.40, blue: 0.85))
                    .overlay(Text("DMX").font(.system(size: 24, weight: .heavy)).foregroundStyle(.white.opacity(0.92)))
                    .overlay(alignment: .trailing) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.8))
                            .frame(width: 10, height: 24).padding(.trailing, 8)
                    }
                    .frame(width: 150, height: 112)
            }
            .frame(width: 570, height: 120, alignment: .leading)
            HStack(spacing: 36) {
                step(1, "Unplug", lit: frame.step == 1)
                step(2, "Plug back in", lit: frame.step == 2)
            }
        }
    }

    private func step(_ n: Int, _ label: String, lit: Bool) -> some View {
        HStack(spacing: 10) {
            Text("\(n)")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(lit ? Color.accentColor : Color.secondary.opacity(0.45)))
            Text(label)
                .font(.system(size: 22, weight: lit ? .bold : .regular))
                .foregroundStyle(lit ? Color.primary : Color.secondary)
        }
    }
}

/// A borderless panel can't become key, so its first click could be spent on the window instead of the
/// button. This one can; being non-activating, it still doesn't bring Booth Check to the front.
final class ClickablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A borderless window over a whole screen that dims what's behind it and lets every click through,
/// on every Space, full-screen apps included. The big signs sit on one.
func dimmingBackdrop(level: NSWindow.Level) -> NSWindow {
    let b = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    b.backgroundColor = NSColor.black.withAlphaComponent(0.45)
    b.isOpaque = false
    b.ignoresMouseEvents = true
    b.level = level
    b.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    b.isReleasedWhenClosed = false
    return b
}

/// Sets up a borderless, non-activating panel for one of the big signs: above the floating start-up
/// panel, on every Space (full-screen apps included), clear around the sign's rounded card.
func setUpSignPanel(_ p: NSPanel, showing content: some View) {
    p.isFloatingPanel = true
    p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    p.hidesOnDeactivate = false
    p.isReleasedWhenClosed = false
    p.backgroundColor = .clear
    p.isOpaque = false
    p.hasShadow = true
    let host = NSHostingController(rootView: content)
    host.sizingOptions = []
    p.contentViewController = host
}

/// The replug sign on screen: the card in the middle of the main screen over a dimmed backdrop, above
/// everything, full-screen apps included. Neither takes focus, and the backdrop lets clicks through.
/// The start-up shows it when the DMX box isn't seen and takes it away once it is.
final class ReplugOverlay {
    static let shared = ReplugOverlay()
    private let model = ReplugModel()
    private var backdrop: NSWindow?
    private var card: NSPanel?
    /// Called each time the sign goes, so the hands-off sign can come back.
    var onHide: (() -> Void)?

    var isShowing: Bool { card?.isVisible ?? false }

    func show(onSkip: @escaping () -> Void) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        model.found = false
        model.skip = onSkip
        if backdrop == nil { backdrop = dimmingBackdrop(level: .floating) }
        if card == nil {
            let p = ClickablePanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            setUpSignPanel(p, showing: ReplugCard(model: model))
            card = p
        }
        backdrop?.setFrame(screen.frame, display: true)
        backdrop?.orderFrontRegardless()
        card?.setContentSize(NSSize(width: 700, height: 600))
        card?.setFrameOrigin(NSPoint(x: screen.frame.midX - 350, y: screen.frame.midY - 300))
        card?.orderFrontRegardless()
    }

    /// The box is back: show "Found it" for a moment, then go.
    func found() {
        guard card?.isVisible == true else { return }
        model.found = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.hide() }
    }

    func hide() {
        card?.orderOut(nil)
        backdrop?.orderOut(nil)
        onHide?()
    }
}

/// The hands-off sign's faces: two while the start-up runs (see `startSign`), and how it ended.
enum SignFace: Equatable { case handsOff, password, ready, needsLook }

/// What the hands-off sign shows. `banner` puts it along the bottom of the screen instead of the middle;
/// `show` is the show's name, as Lightkey lists it among its projects.
final class StartSignModel: ObservableObject {
    @Published var face: SignFace = .handsOff
    @Published var banner = false
    @Published var step = ""
    @Published var show: String?
}

/// The hands-off sign (the user asked for it, 6 Oct 2026): while Booth Check opens everything at
/// login, "Please don't touch the Mac" in the middle of the screen, so nobody clicks around in a
/// half-open Lightkey. While Lightkey may be asking for the Mac's password, a banner along the bottom
/// says what to do there and nothing more, clear of Lightkey's alert and macOS's password box. At the
/// end it says how the start-up went, which is also when the Mac is free to use.
struct StartSignCard: View {
    @ObservedObject var model: StartSignModel

    private var look: (symbol: String, color: Color, title: String, text: String) {
        switch model.face {
        case .handsOff:
            return ("hand.raised.fill", .orange, "Please don\u{2019}t touch the Mac",
                    "Booth Check is getting the lights ready. This sign goes away by itself when it\u{2019}s done.")
        case .password:
            return ("key.fill", .blue, "Lightkey may need you", passwordSignText(show: model.show))
        case .ready:
            return ("checkmark.seal.fill", .green, "Ready for the service", "You can use the Mac now.")
        case .needsLook:
            return ("exclamationmark.triangle.fill", .orange, "Started, but something needs a look",
                    "The panel at the top right says what. You can use the Mac now.")
        }
    }

    /// Still starting up, as opposed to saying how it went.
    private var busy: Bool { model.face == .handsOff || model.face == .password }

    var body: some View {
        let look = self.look
        Group {
            if model.banner {
                HStack(spacing: 22) {
                    badge(look.symbol, look.color, size: 80)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(look.title).font(.system(size: 30, weight: .bold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(look.text).font(.system(size: 18)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if busy { stepLine(size: 14) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 30)
                .frame(width: StartSignOverlay.bannerSize.width, height: StartSignOverlay.bannerSize.height)
            } else {
                VStack(spacing: 20) {
                    Spacer(minLength: 0)
                    badge(look.symbol, look.color, size: 120)
                    Text(look.title).font(.system(size: 42, weight: .bold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(look.text).font(.system(size: 20)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if busy { stepLine(size: 17) }
                    if model.face == .handsOff && hasAccessoryPrompt {
                        Text("If macOS asks to allow an accessory, click Allow.")
                            .font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(44)
                .frame(width: StartSignOverlay.cardSize.width, height: StartSignOverlay.cardSize.height)
            }
        }
        .background(RoundedRectangle(cornerRadius: 28).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

    /// The symbol on a coloured disc. While Booth Check is busy, a ring keeps pulsing out of it.
    private func badge(_ symbol: String, _ color: Color, size: CGFloat) -> some View {
        ZStack {
            if busy {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
                    Circle().stroke(color.opacity(0.55 * (1 - t)), lineWidth: 5)
                        .frame(width: size, height: size)
                        .scaleEffect(1 + 0.4 * t)
                }
            }
            Circle().fill(color).frame(width: size, height: size)
            Image(systemName: symbol).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: size * 1.45, height: size * 1.45)
    }

    private func stepLine(size: CGFloat) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(model.step).font(.system(size: size, weight: .medium))
        }
    }
}

/// The hands-off sign on screen (see `startSign`): in the middle over a dimmed backdrop while Booth
/// Check opens things, or along the bottom with nothing dimmed while Lightkey may be asking for its
/// password. It never takes focus and lets every click through: it's a sign, not a lock. Its backdrop
/// sits just under the floating start-up panel, which stays bright.
final class StartSignOverlay {
    static let shared = StartSignOverlay()
    static let cardSize = NSSize(width: 760, height: 500)
    static let bannerSize = NSSize(width: 900, height: 190)
    private let model = StartSignModel()
    private var backdrop: NSWindow?
    private var card: NSPanel?
    private var ending: DispatchWorkItem?

    func show(_ sign: StartSign, step: String, show: String?) {
        guard sign != .none, let screen = NSScreen.main ?? NSScreen.screens.first else { return hide() }
        ending?.cancel()
        model.face = sign == .password ? .password : .handsOff
        model.banner = sign == .password
        model.step = step
        model.show = show
        if backdrop == nil { backdrop = dimmingBackdrop(level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)) }
        if card == nil {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.cardSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            setUpSignPanel(p, showing: StartSignCard(model: model))
            p.ignoresMouseEvents = true
            card = p
        }
        guard let backdrop, let card else { return }
        if model.banner {
            // Lightkey's alert and macOS's password box come up in the middle and nearer the top.
            backdrop.orderOut(nil)
            card.setContentSize(Self.bannerSize)
            card.setFrameOrigin(NSPoint(x: screen.frame.midX - Self.bannerSize.width / 2, y: screen.visibleFrame.minY + 40))
        } else {
            backdrop.setFrame(screen.frame, display: true)
            backdrop.orderFrontRegardless()
            card.setContentSize(Self.cardSize)
            card.setFrameOrigin(NSPoint(x: screen.frame.midX - Self.cardSize.width / 2,
                                        y: screen.frame.midY - Self.cardSize.height / 2))
        }
        card.orderFrontRegardless()
    }

    /// The start-up is over: say how it went, where the sign already is, then go.
    func finish(ready: Bool) {
        guard card?.isVisible == true else { return }
        model.face = ready ? .ready : .needsLook
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        ending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (ready ? 3 : 6), execute: work)
    }

    func hide() {
        ending?.cancel()
        card?.orderOut(nil)
        backdrop?.orderOut(nil)
    }
}

/// The full window, made on demand and kept for reuse. Built in AppKit rather than as a SwiftUI
/// scene so it never opens by itself at login.
final class MainWindow {
    static let shared = MainWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 820),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Booth Check"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: ContentView(booth: Booth.shared))
            w.setContentSize(NSSize(width: 780, height: 820))
            w.contentMinSize = NSSize(width: 780, height: 560)
            w.setFrameAutosaveName("BoothCheckMain")
            if !w.setFrameUsingName("BoothCheckMain") { w.center() }
            // A frame saved by an older, narrower version would clip the header buttons.
            if w.contentLayoutRect.width < 780 { w.setContentSize(NSSize(width: 780, height: max(w.contentLayoutRect.height, 560))) }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The menu bar icon: its shape shows the state, and a count appears when something needs attention.
struct StatusLabel: View {
    @ObservedObject var booth: Booth

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: booth.menuSymbol)
            if booth.problemCount > 0 { Text("\(booth.problemCount)") }
        }
    }
}

/// What drops down from the menu bar: only what needs attention, and the two things you'd reach for.
struct MenuPanel: View {
    @ObservedObject var booth: Booth

    var body: some View {
        let s = booth.summary
        let issues = booth.checks.filter { $0.status == .fail || $0.status == .warn }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: s.symbol).font(.system(size: 22)).foregroundStyle(s.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.title).font(.system(size: 14, weight: .bold))
                    Text(booth.lastChecked.map { "Checked at \($0.formatted(date: .omitted, time: .shortened))" } ?? "Checking\u{2026}")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(issues.prefix(8)) { check in
                        Button { booth.showWindow() } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: check.status.symbol).foregroundStyle(check.status.color)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(check.title).font(.system(size: 12, weight: .semibold))
                                    Text(check.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open Booth Check to fix this")
                    }
                    if issues.count > 8 {
                        Text("and \(issues.count - 8) more\u{2026}").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            } else if !booth.checks.isEmpty {
                Text("Everything Booth Check looks at is fine.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if booth.starting {
                BootStepsList(steps: booth.bootSteps)
            }
            if booth.updateAvailable, let release = booth.latest {
                Button("Booth Check \(release.version) is available\u{2026}") {
                    booth.showWindow()
                    booth.showUpdate = true
                }
                .controlSize(.small)
            }
            if let off = booth.offSummary {
                Label(off, systemImage: "slider.horizontal.3").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Divider()
            if booth.canStartShow {
                Button { booth.startShow() } label: {
                    Label(booth.starting ? "Starting\u{2026}" : "Get the show started", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .disabled(booth.starting)
            }
            HStack {
                Button("Open Booth Check") { booth.showWindow() }
                Button("Check again") { booth.refresh() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 360)
    }
}

/// Held for the app's whole life. Opts Booth Check out of App Nap so its checks keep running while
/// Lightkey is in front; it still lets the Mac itself sleep, which is the charger settings' job.
var napActivity: NSObjectProtocol?

/// True when macOS opened Booth Check as a login item, rather than someone opening it by hand.
/// `--login` forces it, for testing.
func launchedAsLoginItem() -> Bool {
    if CommandLine.arguments.contains("--login") { return true }
    if let event = NSAppleEventManager.shared().currentAppleEvent,
       event.eventID == AEEventID(kAEOpenApplication),
       event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
        return true
    }
    return ProcessInfo.processInfo.systemUptime < 180      // just after a restart
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = MIDIWatch.shared
        napActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                            reason: "Booth Check watches the booth in the background")
        let booth = Booth.shared
        let atLogin = launchedAsLoginItem()
        booth.start()
        if !atLogin {
            booth.showWindow()                       // someone opened it on purpose
        } else if booth.autoStart, booth.canStartShow {
            booth.startShow(atLogin: true)
        } else {
            // Give the other login items time to open before judging.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { booth.startShow(checkOnly: true) }
        }
    }

    /// Opening Booth Check again while it's running (Finder, Spotlight, Dock) shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Booth.shared.showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct BoothCheckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var booth = Booth.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(booth: booth)
        } label: {
            StatusLabel(booth: booth)
        }
        .menuBarExtraStyle(.window)
    }
}
