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
        case .removeLoginItem: return "Remove\u{2026}"
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
}

final class Booth: ObservableObject {
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
            s.onAC = pass.sh("Power source", "/usr/bin/pmset", ["-g", "batt"]).out.contains("'AC Power'")
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

        out.append(deckApp != nil
            ? Check(id: "deckapp", group: "Stream Deck", title: "Stream Deck app running", status: .ok,
                    detail: "The Stream Deck app is open.")
            : Check(id: "deckapp", group: "Stream Deck", title: "Stream Deck app running", status: .fail,
                    detail: "The Stream Deck app isn't open, so the keys do nothing.", action: .launchStreamDeck))

        // Power & sleep ------------------------------------------------------------------------
        out.append(s.onAC
            ? Check(id: "ac", group: "Power & sleep", title: "On the charger", status: .ok, detail: "Running on AC power.")
            : Check(id: "ac", group: "Power & sleep", title: "On the charger", status: .fail,
                    detail: "Running on battery.", fix: "Plug the charger in. The Mac only stays awake on power."))

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
            out.append(loginShowCheck(items))
            let deckAtLogin = items.contains {
                $0.name.localizedCaseInsensitiveContains("Stream Deck") || $0.path.localizedCaseInsensitiveContains("Stream Deck")
            }
            out.append(deckAtLogin
                ? Check(id: "deckLogin", group: "Start at login", title: "Stream Deck opens at login", status: .ok,
                        detail: "The Stream Deck app starts by itself.")
                : Check(id: "deckLogin", group: "Start at login", title: "Stream Deck opens at login", status: .warn,
                        detail: "After a restart someone has to open the Stream Deck app by hand.",
                        action: .addStreamDeckToLogin))
            let selfPath = Bundle.main.bundleURL.standardizedFileURL.path
            let selfAtLogin = items.contains {
                URL(fileURLWithPath: $0.path).standardizedFileURL.path == selfPath || $0.name == "Booth Check"
            }
            if selfAtLogin {
                out.append(Check(id: "selfLogin", group: "Start at login", title: "Booth Check opens at login", status: .ok,
                                 detail: "Booth Check opens by itself and checks everything straight away."))
            } else if let problem = installProblem {
                out.append(Check(id: "selfLogin", group: "Start at login", title: "Booth Check opens at login", status: .warn,
                                 detail: "Booth Check doesn\u{2019}t open at login.", fix: problem))
            } else {
                out.append(Check(id: "selfLogin", group: "Start at login", title: "Booth Check opens at login", status: .warn,
                                 detail: "After a restart nobody sees these checks until someone opens Booth Check.",
                                 action: .addSelfToLogin))
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

        checks = out
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
    func startShow() {
        guard !starting else { return }
        starting = true
        startNotes = []
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

        if waitForLightkey {
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
        if !NSRunningApplication.runningApplications(withBundleIdentifier: IDs.streamDeck).isEmpty {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh() }
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: check.status.symbol)
                .font(.system(size: 16))
                .foregroundStyle(check.status.color)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).font(.system(size: 13, weight: .semibold))
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
        }
        .padding(.vertical, 5)
    }
}

struct ContentView: View {
    @ObservedObject var booth: Booth
    @State private var showLog = false
    private let timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    private let updateTimer = Timer.publish(every: 6 * 60 * 60, on: .main, in: .common).autoconnect()

    private var problems: Int { booth.checks.filter { $0.status == .fail || $0.status == .warn }.count }
    private var unknowns: Int { booth.checks.filter { $0.status == .unknown }.count }
    private var failing: Bool { booth.checks.contains { $0.status == .fail } }

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
                    showRow
                    ForEach(groupOrder, id: \.self) { group in
                        let rows = booth.checks.filter { $0.group == group }
                        if !rows.isEmpty {
                            section(group) {
                                ForEach(rows) { check in
                                    CheckRow(check: check, perform: booth.perform)
                                    if check.id != rows.last?.id { Divider() }
                                }
                            }
                        }
                        if group == "Start at login" { loginList }
                    }
                    footer
                }
                .padding(16)
            }
        }
        .frame(minWidth: 700, idealWidth: 720, minHeight: 560, idealHeight: 820)
        .sheet(item: $booth.pending) { ChangeSheet(change: $0, booth: booth) }
        .sheet(isPresented: $showLog) { LogSheet(booth: booth) }
        .sheet(isPresented: $booth.showUpdate) {
            if let release = booth.latest { UpdateSheet(booth: booth, release: release) }
        }
        .onAppear {
            booth.refresh()
            booth.checkForUpdates(userInitiated: false)
        }
        .onReceive(updateTimer) { _ in booth.checkForUpdates(userInitiated: false) }
        .onReceive(timer) { _ in booth.tick() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            booth.macDidWake()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if booth.pending == nil { booth.refresh() }
        }
    }

    private var header: some View {
        let (symbol, color, title): (String, Color, String) = {
            if booth.checks.isEmpty { return ("hourglass", .secondary, "Checking\u{2026}") }
            if problems == 0 && unknowns == 0 { return ("checkmark.seal.fill", .green, "Ready for the service") }
            if problems == 0 { return ("questionmark.circle.fill", .secondary, "\(unknowns) check\(unknowns == 1 ? "" : "s") couldn\u{2019}t run") }
            return (failing ? "xmark.octagon.fill" : "exclamationmark.triangle.fill", failing ? .red : .orange,
                    "\(problems) thing\(problems == 1 ? "" : "s") to fix")
        }()
        return HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 20, weight: .bold))
                Text(booth.lastChecked.map { "Checked at \($0.formatted(date: .omitted, time: .standard)) \u{00B7} checks again every 15 seconds" }
                     ?? "Booth Check")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if booth.updateAvailable, let release = booth.latest {
                Button("Update to \(release.version)") { booth.showUpdate = true }
            }
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
            .help("Opens the show in Lightkey, waits for it, then opens the Stream Deck app")
            Button { showLog = true } label: { Label("Log", systemImage: "list.bullet.rectangle") }
                .keyboardShortcut("l")
            Button("Check again") { booth.refresh() }.keyboardShortcut("r")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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

/// Held for the app's whole life. Opts Booth Check out of App Nap so its checks keep running while
/// Lightkey is in front; it still lets the Mac itself sleep, which is the charger settings' job.
var napActivity: NSObjectProtocol?

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = MIDIWatch.shared
        napActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                            reason: "Booth Check watches the booth in the background")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct BoothCheckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var booth = Booth()

    var body: some Scene {
        WindowGroup("Booth Check") { ContentView(booth: booth) }
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates\u{2026}") { booth.checkForUpdates(userInitiated: true) }
                }
            }
    }
}
