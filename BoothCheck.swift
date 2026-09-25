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
        return "Login items now: " & (name of every login item as text)
    end tell
    """
}

func addLoginItemScript(_ path: String) -> String {
    """
    tell application "System Events"
        make login item at end with properties {path:\(appleScriptQuote(path)), hidden:false}
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
    case allowAccessibility, allowAutomation, makeLoginShow, addStreamDeckToLogin
    case open(URL, String)

    var label: String {
        switch self {
        case .fixAppNap: return "Turn App Nap off\u{2026}"
        case .chooseShow: return "Choose show\u{2026}"
        case .openShow: return "Open the show"
        case .launchStreamDeck: return "Open Stream Deck"
        case .allowAccessibility, .allowAutomation: return "Allow access\u{2026}"
        case .makeLoginShow: return "Make it the login show\u{2026}"
        case .addStreamDeckToLogin: return "Add to login\u{2026}"
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

    private var busy = false
    private var appNapSetThisSession = false

    var showName: String? { showPath.map { URL(fileURLWithPath: $0).lastPathComponent } }

    func refresh() {
        guard !busy else { return }
        busy = true
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
        let dmx = s.usb.first { $0.vendorID == IDs.ftdiVendor || $0.name.localizedCaseInsensitiveContains("DMX") }
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

// MARK: - Views

struct CodeBlock: View {
    let text: String

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
                    .padding(.trailing, 44)
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
                    heading("Changes you approved", "Everything Booth Check has changed on this Mac since it opened.")
                    if booth.changes.isEmpty {
                        Text("Nothing changed yet.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(booth.changes) { entryView($0, showOutput: true) }
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
    @StateObject private var booth = Booth()
    @State private var showLog = false
    private let timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

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
                }
                .padding(16)
            }
        }
        .frame(minWidth: 540, idealWidth: 580, minHeight: 560, idealHeight: 820)
        .sheet(item: $booth.pending) { ChangeSheet(change: $0, booth: booth) }
        .sheet(isPresented: $showLog) { LogSheet(booth: booth) }
        .onAppear { booth.refresh() }
        .onReceive(timer) { _ in if booth.pending == nil { booth.refresh() } }
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
            Button { showLog = true } label: { Label("Log", systemImage: "list.bullet.rectangle") }
                .keyboardShortcut("l")
            Button("Check again") { booth.refresh() }.keyboardShortcut("r")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { _ = MIDIWatch.shared }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct BoothCheckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Booth Check") { ContentView() }
            .windowResizability(.contentMinSize)
    }
}
