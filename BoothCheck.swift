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

/// What this Mac is for. Each switch covers a family of checks; see Booth.applies(_:).
struct MacSetup: Codable, Equatable {
    var lightkey = true         // Lightkey runs the show here
    var dmx = true              // a DMX interface is plugged in here
    var streamDeck = true       // a Stream Deck controls Lightkey here
    var alwaysOn = true         // stays on for services: power, sleep, updates, login

    static let booth = MacSetup()
    static let lightkeyOnly = MacSetup(lightkey: true, dmx: false, streamDeck: false, alwaysOn: false)

    static var saved: MacSetup? {
        UserDefaults.standard.data(forKey: IDs.setupKey).flatMap { try? JSONDecoder().decode(MacSetup.self, from: $0) }
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: IDs.setupKey) }
    }

    /// A first guess for a Mac nobody has set up yet: with the Stream Deck app installed it's
    /// probably the booth; without it, probably a Mac for building shows. The sheet confirms.
    static func detected() -> MacSetup {
        let has = { (id: String) in NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil }
        return has(IDs.streamDeck) ? .booth : MacSetup(lightkey: has(IDs.lightkey), dmx: false, streamDeck: false, alwaysOn: false)
    }

    var summary: String {
        [lightkey ? "Lightkey" : nil, dmx ? "DMX interface" : nil, streamDeck ? "Stream Deck" : nil,
         alwaysOn ? "stays on for services" : nil].compactMap { $0 }.joined(separator: ", ")
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

func isDMXInterface(_ d: USBDevice) -> Bool {
    d.vendorID == IDs.ftdiVendor || d.name.localizedCaseInsensitiveContains("DMX")
}

/// USB driver connections that one process has open, from `ioreg -l -c IOUserClient` output. Each
/// connection records who opened it ("pid 123, Lightkey"); a USB one opened by Lightkey means
/// Lightkey is driving a USB device, and the DMX interface is the only one it drives.
func usbConnections(_ output: String, pid: pid_t) -> [String] {
    var currentClass = ""
    var found: [String] = []
    for raw in output.split(separator: "\n") {
        let line = String(raw)
        if let r = line.range(of: "<class ") {
            currentClass = String(line[r.upperBound...].prefix { $0 != "," && $0 != ">" })
        } else if line.contains("\"IOUserClientCreator\""), line.contains("\"pid \(pid),"),
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

let groupOrder = ["Lighting", "Stream Deck", "Power & sleep", "Start at login", "Updates", "Check these yourself"]

/// Everything read off the main thread in one pass.
struct Snapshot {
    var onAC = true
    var ac: [String: String] = [:]
    var appNapOff = false
    var usb: [USBDevice] = []
    var autoInstall: String?
    var lightkeyUSB: [String] = []          // USB driver connections Lightkey has open
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
    @Published var startNotes: [String] = []
    @Published var longestGap: TimeInterval = 0
    private var lastTick: Date?
    private var startCompletion: (() -> Void)?
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
    @Published var detected: [String] = []

    /// At login, open the show, wait for Lightkey, then open Stream Deck. On unless switched off.
    @Published var autoStart: Bool = (UserDefaults.standard.object(forKey: IDs.autoStartKey) as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(autoStart, forKey: IDs.autoStartKey)
            refresh()
        }
    }

    private var busy = false
    private var appNapSetThisSession = false

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
            // both are there. Logged filtered to Lightkey's own entries; the raw output is huge.
            if let pid = lightkeyPID, s.usb.contains(where: isDMXInterface) {
                let ioArgs = ["-l", "-w0", "-c", "IOUserClient"]
                let io = shell("/usr/sbin/ioreg", ioArgs)
                s.lightkeyUSB = usbConnections(io.out, pid: pid)
                pass.entries.append(LogEntry(
                    title: "Lightkey's USB connections (experimental)", language: "Terminal",
                    code: commandLine("/usr/sbin/ioreg", ioArgs),
                    output: (s.lightkeyUSB.isEmpty ? "None opened by Lightkey (pid \(pid))." : s.lightkeyUSB.joined(separator: "\n"))
                        + "\n(Only connections opened by Lightkey are shown.)",
                    status: io.code))
                let lsofArgs = ["-p", String(pid), "-Fn"]
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
                             fix: "Check the DMX USB cable at both ends, then quit and reopen Lightkey."))
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
        detected = [
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: IDs.lightkey) != nil ? "Lightkey installed" : "Lightkey not installed",
            deckInstalled ? "Stream Deck app installed" : "Stream Deck app not installed",
            dmx != nil ? "DMX interface connected" : "no DMX interface connected right now",
            s.hasBattery ? "a laptop" : "a desktop Mac",
        ]

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

        // Booth Check itself: it opts out of App Nap, and proves it by timing its own 15-second checks.
        let optedOut = napActivity != nil || (Bundle.main.infoDictionary?["NSAppSleepDisabled"] as? Bool) == true
        let gap = Int(longestGap.rounded())
        if !optedOut {
            out.append(Check(id: "selfNap", group: "Power & sleep", title: "Booth Check stays awake", status: .fail,
                             detail: "Booth Check could be slowed down while it\u{2019}s in the background.",
                             fix: "Quit and reopen Booth Check."))
        } else if longestGap > 60 {
            out.append(Check(id: "selfNap", group: "Power & sleep", title: "Booth Check stays awake", status: .warn,
                             detail: "Booth Check was held up for \(gap) seconds between checks.",
                             fix: "If this keeps happening, check App Nap and Low Power Mode above."))
        } else {
            out.append(Check(id: "selfNap", group: "Power & sleep", title: "Booth Check stays awake", status: .ok,
                             detail: "Booth Check has opted out of App Nap and checks every 15 seconds, even in the background"
                                + (lastTick == nil || gap == 0 ? "." : " (longest gap so far: \(gap) s).")))
        }

        if s.appNapOff && appNapSetThisSession {
            out.append(Check(id: "nap", group: "Power & sleep", title: "App Nap off", status: .warn,
                             detail: "Switched off just now.", fix: "Restart the Mac for it to take effect."))
        } else if s.appNapOff {
            out.append(Check(id: "nap", group: "Power & sleep", title: "App Nap off", status: .ok,
                             detail: "macOS won't put the Stream Deck app to sleep."))
        } else {
            out.append(Check(id: "nap", group: "Power & sleep", title: "App Nap off", status: .fail,
                             detail: "macOS can put the Stream Deck app to sleep — that's what freezes the keys.",
                             fix: "Turn it off, then restart the Mac.", action: .fixAppNap))
        }

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
                if let showName {
                    out.append(Check(id: "autoShow", group: "Start at login", title: "Booth Check starts the show", status: .ok,
                                     detail: setup.streamDeck
                                        ? "At login it opens \(showName), waits for Lightkey, then opens the Stream Deck app."
                                        : "At login it opens \(showName) in Lightkey."))
                } else {
                    out.append(Check(id: "autoShow", group: "Start at login", title: "Booth Check starts the show", status: .warn,
                                     detail: "Choose the show this Mac should run.", action: .chooseShow))
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
    }

    private func showCheck(_ lightkey: NSRunningApplication?, _ pass: Pass) -> Check {
        let title = "The right show is open"
        guard let showPath, let showName else {
            return Check(id: "show", group: "Lighting", title: title, status: .warn,
                         detail: "Booth Check doesn't know which show this Mac should run yet.", action: .chooseShow)
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
        let wanted = URL(fileURLWithPath: showPath).standardizedFileURL.path
        let stem = (showName as NSString).deletingPathExtension
        if docs.contains(where: { $0.standardizedFileURL.path == wanted }) || titles.contains(where: { $0.contains(stem) }) {
            return Check(id: "show", group: "Lighting", title: title, status: .ok, detail: "\(showName) is open.")
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
                explanation: "Stops macOS putting apps in the background to sleep, which is what freezes the Stream Deck. It applies to every app on this Mac and takes effect after a restart. No password needed.",
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
            if let showPath { NSWorkspace.shared.open(URL(fileURLWithPath: showPath)) }
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
        if change.key == "appnap", r.code == 0 { appNapSetThisSession = true }
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

    /// Icon, colour and headline shared by the window and the menu bar.
    var summary: (symbol: String, color: Color, title: String) {
        if checks.isEmpty { return ("hourglass", .secondary, "Checking\u{2026}") }
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
        if checks.isEmpty { return "hourglass" }
        if problemCount == 0 { return unknownCount == 0 ? "checkmark.circle" : "questionmark.circle" }
        return anyFailing ? "xmark.octagon" : "exclamationmark.triangle"
    }

    /// Starts the checks, the update checks and the wake watcher. They run whether or not the window
    /// is open, so the menu bar icon is always current.
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
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in self?.macDidWake() }
    }

    func showWindow() { MainWindow.shared.show() }

    /// Whether a check belongs to what this Mac is set up for.
    func applies(_ id: String) -> Bool {
        let s = setup
        switch id {
        case "lk", "show": return s.lightkey
        case "dmx": return s.dmx
        case "dmxLive": return s.lightkey && s.dmx
        case "midi": return s.lightkey && s.streamDeck
        case "deck", "deckapp", "nap": return s.streamDeck
        case "ac", "sleep", "lpm", "autoboot", "upd", "lock", "selfLogin": return s.alwaysOn
        case "autoShow", "loginShows", "loginShow": return s.alwaysOn && s.lightkey
        case "deckLogin": return s.alwaysOn && s.streamDeck
        case "acc": return s.alwaysOn && (s.dmx || s.streamDeck)
        default: return true                                  // Booth Check's own checks
        }
    }

    /// Starting the show only makes sense where Lightkey runs.
    var canStartShow: Bool { setup.lightkey }

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

    /// After login has had its chance: if anything needs attention, open the window once so whoever
    /// sits down sees it. Otherwise stay quietly in the menu bar.
    func reviewStartup() {
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if self.problemCount > 0 { self.showWindow() }
        }
    }
}

// MARK: - Timing and getting the show started

extension Booth {
    /// Called by the 15-second timer. Measures the gap since the last tick, so Booth Check can tell
    /// whether it was held up in the background, then checks again.
    func tick() {
        let now = Date()
        if let lastTick { longestGap = max(longestGap, now.timeIntervalSince(lastTick)) }
        lastTick = now
        if pending == nil { refresh() }
    }

    /// The Mac was asleep, so the gap since the last tick says nothing about Booth Check.
    func macDidWake() { lastTick = nil }

    /// The override for when login didn't do its job: open the show, wait for Lightkey's MIDI input,
    /// then make sure the Stream Deck app is open. Opens things only; changes no settings.
    func startShow(then completion: (() -> Void)? = nil) {
        guard !starting else { return }
        starting = true
        startNotes = []
        startCompletion = completion
        let lightkeyWasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: IDs.lightkey).isEmpty
        var waitForLightkey = lightkeyWasRunning

        if let showPath, let showName {
            NSWorkspace.shared.open(URL(fileURLWithPath: showPath))
            startNote(lightkeyWasRunning ? "Brought \(showName) to the front in Lightkey." : "Opening \(showName) in Lightkey\u{2026}",
                      "NSWorkspace: open \(showPath)")
            waitForLightkey = true
        } else if !lightkeyWasRunning, let lk = NSWorkspace.shared.urlForApplication(withBundleIdentifier: IDs.lightkey) {
            NSWorkspace.shared.openApplication(at: lk, configuration: .init())
            startNote("Opening Lightkey. No show is chosen in Booth Check, so open it in Lightkey.", "NSWorkspace: open \(lk.path)")
            waitForLightkey = true
        } else if lightkeyWasRunning {
            startNote("Lightkey is already open. No show is chosen in Booth Check.", "NSWorkspace: list the running apps")
        } else {
            startNote("Lightkey isn\u{2019}t installed on this Mac.", "NSWorkspace: find \(IDs.lightkey)")
        }

        // Waiting for Lightkey's MIDI input only matters when a Stream Deck is going to look for it.
        if waitForLightkey && setup.streamDeck {
            waitForMIDI(until: Date().addingTimeInterval(30), lightkeyWasRunning: lightkeyWasRunning)
        } else {
            finishStart(lightkeyWasRunning: lightkeyWasRunning)
        }
    }

    private func startNote(_ text: String, _ code: String) {
        startNotes.append(text)
        changes.insert(LogEntry(title: "Get the show started", language: "macOS API", code: code, output: text, status: 0), at: 0)
    }

    /// The Stream Deck plugin looks for "Lightkey Input" when it starts, so Lightkey goes first.
    private func waitForMIDI(until deadline: Date, lightkeyWasRunning: Bool) {
        if MIDIWatch.shared.destinationNames().contains(where: { $0.localizedCaseInsensitiveContains(IDs.lightkeyMIDIInput) }) {
            startNote("Lightkey\u{2019}s MIDI input is ready.", "CoreMIDI: look for \u{201C}\(IDs.lightkeyMIDIInput)\u{201D}")
            finishStart(lightkeyWasRunning: lightkeyWasRunning)
        } else if Date() > deadline {
            startNote("Lightkey\u{2019}s MIDI input didn\u{2019}t appear within 30 seconds. Opening the Stream Deck app anyway.",
                      "CoreMIDI: look for \u{201C}\(IDs.lightkeyMIDIInput)\u{201D}")
            finishStart(lightkeyWasRunning: lightkeyWasRunning)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.waitForMIDI(until: deadline, lightkeyWasRunning: lightkeyWasRunning)
            }
        }
    }

    private func finishStart(lightkeyWasRunning: Bool) {
        if !setup.streamDeck {
            // This Mac has no Stream Deck, so there's nothing more to open.
        } else if !NSRunningApplication.runningApplications(withBundleIdentifier: IDs.streamDeck).isEmpty {
            startNote(lightkeyWasRunning ? "The Stream Deck app is already open."
                                         : "The Stream Deck app was already open. If the keys don\u{2019}t respond, quit and reopen it so it finds Lightkey.",
                      "NSWorkspace: list the running apps")
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: IDs.streamDeck) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
            startNote("Opening the Stream Deck app.", "NSWorkspace: open \(url.path)")
        } else {
            startNote("The Stream Deck app isn\u{2019}t installed on this Mac.", "NSWorkspace: find \(IDs.streamDeck)")
        }
        starting = false
        let completion = startCompletion
        startCompletion = nil
        // Give Stream Deck a moment to appear before checking again or reviewing the startup.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if let completion { completion() } else { self.refresh() }
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

/// "What does this Mac do?" Each switch turns a family of checks on or off.
struct SetupSheet: View {
    @ObservedObject var booth: Booth

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What does this Mac do?").font(.system(size: 17, weight: .bold))
                        Text("Booth Check only checks what this Mac is set up for. Switched-off checks are counted at the top of the window, so a shorter list is never mistaken for a clean one.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 8) {
                        preset("Booth Mac", "Runs services: everything on", .booth)
                        preset("Lightkey only", "Building shows, no hardware", .lightkeyOnly)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        toggle($booth.setup.lightkey, "Lightkey runs the show on this Mac",
                               "Lightkey running, the right show open, and Get the show started.")
                        toggle($booth.setup.dmx, "A DMX interface is plugged into this Mac",
                               "The interface is connected, and Lightkey is using it.")
                        toggle($booth.setup.streamDeck, "A Stream Deck controls Lightkey here",
                               "The deck and its app, Lightkey\u{2019}s MIDI input, App Nap, and opening Stream Deck after Lightkey.")
                        toggle($booth.setup.alwaysOn, "This Mac stays on for services",
                               "Charger, sleep, Low Power Mode, starting from the charger, macOS updates, and what opens at login.")
                        toggle($booth.autoStart, "Start the show when the Mac starts",
                               "At login, open the show" + (booth.setup.streamDeck ? ", wait for Lightkey, then open Stream Deck." : "."))
                            .disabled(!(booth.setup.lightkey && booth.setup.alwaysOn))
                            .opacity(booth.setup.lightkey && booth.setup.alwaysOn ? 1 : 0.45)
                    }

                    if !booth.detected.isEmpty {
                        Label("Found on this Mac: " + booth.detected.joined(separator: " \u{00B7} "), systemImage: "magnifyingglass")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }

                    if !booth.mutedChecks.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("MUTED ON THIS MAC").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                            ForEach(booth.mutedChecks) { check in
                                HStack {
                                    Label(check.title, systemImage: "bell.slash").font(.system(size: 12))
                                    Spacer()
                                    Button("Unmute") { booth.unmute(check) }.controlSize(.small)
                                }
                            }
                        }
                    }

                    Text("To mute a single check instead, use the \(Image(systemName: "bell.slash")) button on its row. The DMX interface can only be switched off here, never from its row: at church, a cable falling out looks exactly like a Mac without one.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            Divider()
            HStack {
                Text(booth.offSummary ?? "Everything is checked on this Mac.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { booth.confirmSetup() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
    }

    private func preset(_ title: String, _ subtitle: String, _ value: MacSetup) -> some View {
        let selected = booth.setup == value
        return Button { booth.setup = value } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ value: Binding<Bool>, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: value).toggleStyle(.switch).labelsHidden().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
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
                    if !booth.startNotes.isEmpty { startPanel }
                    if booth.setup.lightkey { showRow }
                    if booth.setup.lightkey && booth.setup.alwaysOn { autoStartRow }
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
                        if group == "Start at login" && booth.setup.alwaysOn { loginList }
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
                Text(booth.lastChecked.map { "Checked at \($0.formatted(date: .omitted, time: .shortened)) \u{00B7} every 15 seconds" }
                     ?? "Booth Check")
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
                .help(booth.setup.streamDeck ? "Opens the show in Lightkey, waits for it, then opens the Stream Deck app"
                                             : "Opens the show in Lightkey")
            }
            Button { booth.showSetup = true } label: { Label("This Mac", systemImage: "gearshape") }
                .help("What this Mac is set up for, and which checks are muted")
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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("GET THE SHOW STARTED").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                Spacer()
                if !booth.starting {
                    Button("Dismiss") { booth.startNotes = [] }.controlSize(.small)
                }
            }
            ForEach(Array(booth.startNotes.enumerated()), id: \.offset) { _, line in
                Label(line, systemImage: "arrow.right.circle.fill")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if booth.starting {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Waiting for Lightkey\u{2026}").font(.system(size: 12)) }
            }
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

    private var autoStartRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $booth.autoStart).toggleStyle(.switch).labelsHidden().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Start the show when the Mac starts").font(.system(size: 13, weight: .medium))
                Text("At login, Booth Check opens the show, waits for Lightkey, then opens the Stream Deck app, in that order. It needs Booth Check itself to open at login.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var loginList: some View {
        if case .items(let items) = booth.loginRead {
            section("Everything that opens at login") {
                if items.isEmpty {
                    Text("Nothing opens at login.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 4)
                }
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).font(.system(size: 12, weight: .medium))
                            Text(item.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                        Spacer()
                        if item.isShow { badge(for: item) }
                        Button("Remove\u{2026}") { booth.perform(.removeLoginItem(item)) }
                            .controlSize(.small)
                            .help("Stop \(item.name) opening at login. Shows the script first.")
                    }
                    .padding(.vertical, 3)
                }
                HStack {
                    Spacer()
                    Button("Open Login Items\u{2026}") { NSWorkspace.shared.open(Settings.loginItems) }.controlSize(.small)
                }
                .padding(.top, 4)
            }
        }
    }

    private func badge(for item: LoginItem) -> some View {
        let isOurs = booth.showPath.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path == URL(fileURLWithPath: item.path).standardizedFileURL.path
        } ?? false
        return Text(isOurs ? "This show" : "Other show")
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(isOurs ? Color.green : Color.red)
            .background(Capsule().fill((isOurs ? Color.green : Color.red).opacity(0.14)))
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
            if !booth.startNotes.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(booth.startNotes.suffix(4).enumerated()), id: \.offset) { _, line in
                        Label(line, systemImage: "arrow.right.circle.fill").font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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
        } else if booth.autoStart, booth.canStartShow, booth.setup.alwaysOn, booth.showPath != nil {
            booth.startShow { booth.reviewStartup() }
        } else {
            // Give the other login items time to open before judging.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { booth.reviewStartup() }
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
