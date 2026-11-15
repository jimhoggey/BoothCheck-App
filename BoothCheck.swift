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
import IOKit.ps
import IOKit.pwr_mgt
import SwiftUI
import SystemConfiguration
import UniformTypeIdentifiers

// MARK: - Constants

enum IDs {
    static let lightkey = "de.monospc.Lightkey"
    static let streamDeck = "com.elgato.StreamDeck"
    static let elgatoVendor = 0x0FD9          // USB vendor ID on every Stream Deck
    static let ftdiVendor = 0x0403            // the chip inside Enttec Open DMX USB and most USB-DMX cables
    static let lightkeyMIDIInput = "Lightkey Input"
    static let lightkeyMIDIOutput = "Lightkey Output"     // where Lightkey reports each cue's on/off
    static let deckHelper = "com.c3b.deckstatehelper"     // the deck lights helper's launchd label
    static let deckFeedback = "Lightkey Feedback"         // the MIDI source it publishes for the deck's keys
    static let showKey = "showPath"
    static let autoStartKey = "startShowAtLogin"
    static let setupKey = "macSetup"
    static let mutedKey = "mutedChecks"
    static let autoShutdownKey = "shutDownByItself"
    static let shutdownDaysKey = "shutDownDays"
    static let shutdownMinuteKey = "shutDownMinute"
    static let powerOffKey = "shutDownWhenPowerGoesOff"
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
    /// The deck's key lights come from the deck lights helper here. Nil until decided: Booth Check
    /// switches it on the first time it finds the helper installed (see `deckLightsAutoOn`) or installs
    /// it; until then it's checked as on, so a Mac without the helper shows it red with Install….
    var deckLights: Bool? = nil
    /// Send diagnostics (events and the scrubbed log) to the developer through Aptabase (1.31; on by
    /// default, the owner chose "everything, always"). Off: nothing is queued or sent; the log on disk
    /// is still written.
    var diagnostics = true
    /// The Stream Deck profile that goes with the show (1.32), picked once by a tech in This Mac. Nil:
    /// "Don't check". Booth Check puts Stream Deck on it at the start-up and checks it stays there.
    var deckProfile: DeckProfileChoice? = nil
    /// Black out the stage first (1.30, off by default; the owner asked for it optional): every shutdown
    /// sends the show's Blackout before Stream Deck and Lightkey close (see `blackoutBeforeClosing`).
    var blackoutAtShutdown = false
    /// Whether Lightkey should connect without the password here (Nov 2026, see
    /// `lightkeyNoPasswordRepairNeeded`): true once Booth Check switched DontUnloadFTDIDrivers on, or a
    /// start-up ended ready with it on; false once a tech switched it off in This Mac. Nil: not known yet.
    /// A login start-up puts the setting back when it's true and the setting went missing.
    var noPasswordWanted: Bool? = nil

    /// Apps worth offering on a production Mac when they're installed.
    static let knownApps = [("com.renewedvision.propresenter", "ProPresenter")]

    init(lightkey: Bool = true, dmx: Bool = true, streamDeck: Bool = true, alwaysOn: Bool = true, apps: [ExtraApp] = [],
         deckLights: Bool? = nil) {
        (self.lightkey, self.dmx, self.streamDeck, self.alwaysOn, self.apps) = (lightkey, dmx, streamDeck, alwaysOn, apps)
        self.deckLights = deckLights
    }

    // Setups saved before extra apps existed have no `apps`; offer the installed known apps then.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lightkey = try c.decodeIfPresent(Bool.self, forKey: .lightkey) ?? true
        dmx = try c.decodeIfPresent(Bool.self, forKey: .dmx) ?? true
        streamDeck = try c.decodeIfPresent(Bool.self, forKey: .streamDeck) ?? true
        alwaysOn = try c.decodeIfPresent(Bool.self, forKey: .alwaysOn) ?? true
        apps = try c.decodeIfPresent([ExtraApp].self, forKey: .apps) ?? MacSetup.suggestedApps(on: false)
        deckLights = try c.decodeIfPresent(Bool.self, forKey: .deckLights)
        diagnostics = try c.decodeIfPresent(Bool.self, forKey: .diagnostics) ?? true
        deckProfile = try? c.decodeIfPresent(DeckProfileChoice.self, forKey: .deckProfile)
        blackoutAtShutdown = try c.decodeIfPresent(Bool.self, forKey: .blackoutAtShutdown) ?? false
        noPasswordWanted = try c.decodeIfPresent(Bool.self, forKey: .noPasswordWanted)
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
        ([lightkey ? "Lightkey" : nil, lightkey && dmx ? "DMX interface" : nil, streamDeck ? "Stream Deck" : nil,
          lightkey && streamDeck && deckLights == true ? "deck lights helper" : nil]
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

/// What the running check pass is reading right now, for a first pass that takes long (`checkingTitle`).
final class PassProgress {
    static let shared = PassProgress()
    private let lock = NSLock()
    private var current: String?
    var now: String? {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
}

/// Collects what one check pass read, so the Log can show it.
final class Pass {
    var entries: [LogEntry] = []

    func sh(_ title: String, _ path: String, _ args: [String]) -> (out: String, code: Int32) {
        PassProgress.shared.now = commandLine(path, args)
        defer { PassProgress.shared.now = nil }
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

/// lsof's arguments for the files these processes have open: no DNS or port-name lookups (-n -P),
/// which can stall it for many seconds.
func lsofArgs(_ pids: [pid_t]) -> [String] {
    ["-n", "-P", "-p", pids.map(String.init).joined(separator: ","), "-Fn"]
}

/// The exit code `shell` returns when it stopped a command that ran too long.
let shellTimedOutCode: Int32 = -2

/// What `shell` adds to a command's output when it had to stop it.
func shellTimeoutText(_ seconds: TimeInterval) -> String {
    "Timed out after \(Int(seconds.rounded())) s: Booth Check stopped the command."
}

/// Runs a built-in command and returns what it printed. Reads before waiting so a large output can't
/// fill the pipe and hang the command. A command still running after `timeout` seconds is stopped
/// (SIGTERM, then SIGKILL 2 s later) and the result says it timed out, so nothing waits forever.
func shell(_ path: String, _ args: [String], timeout: TimeInterval = 20) -> (out: String, code: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return ("Couldn't start \(path): \(error.localizedDescription)", -1) }
    let lock = NSLock()
    var data = Data()
    let read = DispatchSemaphore(value: 0)
    let deadline = Date().addingTimeInterval(timeout)
    DispatchQueue.global(qos: .utility).async {
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock(); data = d; lock.unlock()
        read.signal()
    }
    guard read.wait(timeout: .now() + timeout) == .success else {
        p.terminate()
        if read.wait(timeout: .now() + 2) == .timedOut {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            _ = read.wait(timeout: .now() + 2)
        }
        lock.lock(); let got = String(decoding: data, as: UTF8.self); lock.unlock()
        return ((got.isEmpty ? "" : got + "\n") + shellTimeoutText(timeout), shellTimedOutCode)
    }
    // Output closed; the command itself may take a moment more to exit (or have left a child behind).
    while p.isRunning && Date() < deadline { usleep(5_000) }
    if p.isRunning {
        p.terminate()
        lock.lock(); let got = String(decoding: data, as: UTF8.self); lock.unlock()
        return ((got.isEmpty ? "" : got + "\n") + shellTimeoutText(timeout), shellTimedOutCode)
    }
    lock.lock(); let out = String(decoding: data, as: UTF8.self); lock.unlock()
    return (out, p.terminationStatus)
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

    /// MIDI sources: what apps send from, such as the deck lights helper's "Lightkey Feedback".
    func sourceNames() -> [String] {
        (0..<MIDIGetNumberOfSources()).compactMap { i in
            var name: Unmanaged<CFString>?
            guard MIDIObjectGetStringProperty(MIDIGetSource(i), kMIDIPropertyName, &name) == noErr,
                  let n = name?.takeRetainedValue() else { return nil }
            return n as String
        }
    }

    private func endpoint(named want: String, count: Int, get: (Int) -> MIDIEndpointRef) -> MIDIEndpointRef? {
        (0..<count).map(get).first { e in
            var name: Unmanaged<CFString>?
            return MIDIObjectGetStringProperty(e, kMIDIPropertyName, &name) == noErr && (name?.takeRetainedValue() as String?) == want
        }
    }

    private var outPort = MIDIPortRef()

    /// Sends one MIDI 1.0 note-on to a destination by name (1.30: the shutdown's Blackout, see
    /// `blackoutBeforeClosing`), as the Stream Deck's MIDI plugin does. Returns what happened, for the Log.
    func sendNoteOn(_ n: MIDINote, velocity: Int = 127, to destination: String) -> (ok: Bool, detail: String) {
        guard let dest = endpoint(named: destination, count: MIDIGetNumberOfDestinations(), get: MIDIGetDestination) else {
            return (false, "There\u{2019}s no MIDI destination called \u{201C}\(destination)\u{201D}.")
        }
        if outPort == 0 {
            let s = MIDIOutputPortCreate(client, "Booth Check out" as CFString, &outPort)
            guard s == noErr else { return (false, "CoreMIDI couldn\u{2019}t make an output port (\(s)).") }
        }
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        var word = midiNoteOnWord(n, velocity: velocity)
        guard MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word) != nil else {
            return (false, "CoreMIDI couldn\u{2019}t build the message.")
        }
        let s = MIDISendEventList(outPort, dest, &list)
        return (s == noErr, s == noErr ? "Sent note-on, \(n.text), velocity \(velocity) (bytes \(midiBytesText(word))) to \u{201C}\(destination)\u{201D}."
                                       : "CoreMIDI didn\u{2019}t send it (\(s)).")
    }

    /// The source called `name` as CoreMIDI has it now: a new ref each time its app makes it again.
    func sourceRef(named name: String) -> MIDIEndpointRef? {
        endpoint(named: name, count: MIDIGetNumberOfSources(), get: MIDIGetSource)
    }

    /// Listens to a source by name (read only) and hands each MIDI 1.0 channel-voice word to `onWord`,
    /// on the main thread, or (`onMain` false) straight on CoreMIDI's own thread, for a listener that
    /// only counts. Returns the way to stop listening, or nil when there's no such source.
    func listen(to source: String, onMain: Bool = true, onWord: @escaping (UInt32) -> Void) -> (() -> Void)? {
        guard let src = sourceRef(named: source) else { return nil }
        var port = MIDIPortRef()
        let s = MIDIInputPortCreateWithProtocol(client, "Booth Check in" as CFString, ._1_0, &port) { list, _ in
            var words: [UInt32] = []
            for packet in list.unsafeSequence() {           // walk the pointers; never copy a packet and step past it
                let n = Int(packet.pointee.wordCount)
                words += withUnsafeBytes(of: packet.pointee.words) { Array($0.bindMemory(to: UInt32.self).prefix(n)) }
            }
            if onMain { DispatchQueue.main.async { words.forEach(onWord) } } else { words.forEach(onWord) }
        }
        guard s == noErr, MIDIPortConnectSource(port, src, nil) == noErr else {
            if port != 0 { MIDIPortDispose(port) }
            return nil
        }
        return { MIDIPortDisconnectSource(port, src); MIDIPortDispose(port) }
    }
}

/// What Lightkey has reported on "Lightkey Output" so far (see `LightkeyOutputWatch`): its MIDI 1.0
/// channel-voice messages (cue states), how many said a cue is on, and when the last came (uptime).
struct MIDIActivity: Equatable {
    var messages = 0
    var cuesOn = 0
    var lastAt: TimeInterval?
}

/// One word from "Lightkey Output" counted. Only MIDI 1.0 channel-voice messages count (Lightkey's
/// cue reports); clock and other system messages don't, so they can never hold up a shutdown.
func midiActivityAdding(_ a: MIDIActivity, word: UInt32, at: TimeInterval) -> MIDIActivity {
    guard word >> 28 == 2 else { return a }
    var n = a
    n.messages += 1
    n.lastAt = at
    if (word >> 16) & 0xF0 == 0x90 && word & 0x7F > 0 { n.cuesOn += 1 }
    return n
}

/// Lightkey was used in the last `window` seconds (the weekly shutdown's guard, Nov 2026): it reported a
/// cue changing on "Lightkey Output", which happens when someone presses a cue on the deck or in Lightkey.
func lightkeyRecentlyUsed(lastAt: TimeInterval?, now: TimeInterval, window: TimeInterval = 600) -> Bool {
    lastAt.map { now - $0 < window } ?? false
}

/// Listens passively to Lightkey's "Lightkey Output" while Lightkey runs on a Lightkey Mac (Nov 2026):
/// read only, counted on CoreMIDI's thread under a lock, nothing published and no UI per message. The
/// start-up reads it for whether Lightkey reported the show's start states; the weekly shutdown for
/// whether the lights were used in the last 10 minutes. `keepListening` (main thread, each 15-second
/// tick and at the start-up's show step) connects to the current source, again after Lightkey restarts.
final class LightkeyOutputWatch {
    static let shared = LightkeyOutputWatch()
    private let lock = NSLock()
    private var activity = MIDIActivity()
    private var stop: (() -> Void)?
    private var source: MIDIEndpointRef = 0

    var listening: Bool { stop != nil }

    func keepListening(_ wanted: Bool) {
        let ref = wanted ? MIDIWatch.shared.sourceRef(named: IDs.lightkeyMIDIOutput) : nil
        if let ref, ref == source, stop != nil { return }
        stop?()
        stop = nil
        source = 0
        guard let ref else { return }
        stop = MIDIWatch.shared.listen(to: IDs.lightkeyMIDIOutput, onMain: false) { [weak self] word in self?.heard(word) }
        if stop != nil { source = ref }
    }

    private func heard(_ word: UInt32) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        activity = midiActivityAdding(activity, word: word, at: now)
        lock.unlock()
    }

    func now() -> MIDIActivity {
        lock.lock()
        defer { lock.unlock() }
        return activity
    }
}

/// How long an Accessibility call into another app may wait for it to answer (macOS's default is
/// about 6 s, and these calls run on the main thread: a busy Lightkey would freeze Booth Check).
let axMessagingTimeout: Float = 1.0

/// An app's Accessibility element with the short timeout. Every application element is made here.
func axApp(_ pid: pid_t) -> AXUIElement {
    axTimed(AXUIElementCreateApplication(pid))
}

/// The same short timeout on an element read from an app (windows, buttons, menu items): set
/// locally, no message to the app. Used before every call that asks the app something.
@discardableResult
func axTimed(_ element: AXUIElement) -> AXUIElement {
    AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
    return element
}

/// Documents (file URLs) and titles of Lightkey's open windows, read through Accessibility.
func windowsOf(pid: pid_t) -> (docs: [URL], titles: [String]) {
    let app = axApp(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return ([], []) }
    var docs: [URL] = [], titles: [String] = []
    for w in windows {
        axTimed(w)
        var doc: CFTypeRef?, title: CFTypeRef?
        if AXUIElementCopyAttributeValue(w, kAXDocumentAttribute as CFString, &doc) == .success,
           let s = doc as? String, let u = URL(string: s) { docs.append(u) }
        if AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &title) == .success,
           let t = title as? String, !t.isEmpty { titles.append(t) }
    }
    return (docs, titles)
}

/// Whether the Mac is running on the charger (or has no battery), read straight from macOS.
func onACPower() -> Bool {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
    return (type as String) != "Battery Power"
}

/// Whether the Mac has a battery of its own: a MacBook.
func macHasBattery() -> Bool {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
    return sources.contains { source in
        (IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any])?["Type"] as? String == "InternalBattery"
    }
}

private func axAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(axTimed(element), name as CFString, &value) == .success ? value : nil
}

private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    axAttribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

/// An app's dialogs and its windows' sheets, not the show's own big window (Accessibility).
private func axQuestions(pid: pid_t) -> [AXUIElement] {
    let windows = axAttribute(axApp(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
    return windows.flatMap { window -> [AXUIElement] in
        let subrole = axAttribute(window, kAXSubroleAttribute) as? String
        if subrole == kAXDialogSubrole || subrole == kAXSystemDialogSubrole { return [window] }
        return axChildren(window).filter { axAttribute($0, kAXRoleAttribute) as? String == kAXSheetRole }
    }
}

/// Whether an app is showing a button titled Authenticate: Lightkey's alert before it takes the DMX
/// interface (Accessibility). Only dialogs and sheets are searched, not the show's own big window.
func asksToAuthenticate(pid: pid_t) -> Bool {
    func hasButton(_ element: AXUIElement, depth: Int) -> Bool {
        if axAttribute(element, kAXRoleAttribute) as? String == kAXButtonRole,
           (axAttribute(element, kAXTitleAttribute) as? String)?.localizedCaseInsensitiveContains("authenticate") == true { return true }
        return depth > 0 && axChildren(element).contains { hasButton($0, depth: depth - 1) }
    }
    return axQuestions(pid: pid).contains { hasButton($0, depth: 3) }
}

/// Presses Quit on Lightkey's "Are you sure you want to quit Lightkey?" if it's up (see `quitButton`),
/// through Accessibility. It's Lightkey's own question, not a macOS security prompt: a sheet on the
/// show's window with the question and Cancel and Quit (dev Mac, Lightkey 6.0.2, 17 Oct 2026; pressing
/// Quit there closed Lightkey cleanly). Returns whether it pressed.
func pressQuitIfAsked(pid: pid_t, message: String, quit: String) -> Bool {
    func collect(_ element: AXUIElement, depth: Int, texts: inout [String], buttons: inout [AXUIElement]) {
        let role = axAttribute(element, kAXRoleAttribute) as? String
        if role == kAXStaticTextRole {
            texts += [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].compactMap { axAttribute(element, $0) as? String }
        }
        if role == kAXButtonRole { buttons.append(element) }
        if depth > 0 { axChildren(element).forEach { collect($0, depth: depth - 1, texts: &texts, buttons: &buttons) } }
    }
    for question in axQuestions(pid: pid) {
        var texts: [String] = [], buttons: [AXUIElement] = []
        collect(question, depth: 3, texts: &texts, buttons: &buttons)
        let titles = buttons.map { axAttribute($0, kAXTitleAttribute) as? String ?? "" }
        if let i = quitButton(texts: texts, buttons: titles, message: message, quit: quit) {
            return AXUIElementPerformAction(axTimed(buttons[i]), kAXPressAction as CFString) == .success
        }
    }
    return false
}

/// The `defaults` arguments that switch Lightkey's DontUnloadFTDIDrivers on, or remove it again: the
/// same command the Terminal test on the church Mac used (9 Oct 2026), and its undo.
func lightkeyPasswordCommand(on: Bool) -> [String] {
    on ? ["write", IDs.lightkey, "DontUnloadFTDIDrivers", "-bool", "true"]
       : ["delete", IDs.lightkey, "DontUnloadFTDIDrivers"]
}

/// Whether `defaults read` printed a true boolean. A key that isn't set prints nothing on stdout.
func defaultsSaysOn(_ output: String) -> Bool {
    ["1", "true", "yes"].contains(output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
}

// MARK: - Old apps reopening at login, other apps at the shutdown, the menu bar icon (1.30)

/// The commands that stop macOS reopening the apps that were open at shutdown, and their undo.
/// TALLogoutSavesState is the "Reopen windows when logging back in" tick in the shutdown dialog; macOS
/// treats it as on when it isn't set.
func reopenAppsCommands(reopen: Bool) -> [[String]] {
    let value = reopen ? "true" : "false"
    return [["write", "com.apple.loginwindow", "TALLogoutSavesState", "-bool", value],
            ["write", "com.apple.loginwindow", "LoginwindowLaunchesRelaunchApps", "-bool", value]]
}

/// Whether macOS reopens the apps that were open at shutdown, from
/// `defaults read com.apple.loginwindow TALLogoutSavesState` (output with stderr, and its exit code).
/// Not set means on (macOS's default). nil: the output made no sense, so the row says it couldn't tell.
func reopensAppsAtLogin(_ output: String, code: Int32) -> Bool? {
    if output.contains("does not exist") { return true }
    guard code == 0 else { return nil }
    // `defaults` can print a timestamped line first; the value is the last line.
    let last = output.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    switch last {
    case "0", "false", "no": return false
    case "1", "true", "yes": return true
    default: return nil
    }
}

/// A running app as the shutdown and the start-up's log see it.
typealias RunningAppInfo = (bundleID: String?, name: String, regular: Bool)

/// Apps the shutdown leaves to its own steps or never asks to quit: Finder (it always relaunches),
/// and Lightkey and Stream Deck, which close afterwards with their own handling (see `close`).
let shutdownLeavesOpen: Set<String> = ["com.apple.finder", IDs.lightkey, IDs.streamDeck]

/// Which of `apps` (by index) count as other apps someone opened: ordinary apps with a Dock icon
/// (activation policy .regular), not Booth Check itself and not any bundle ID in `skip`.
func otherRegularApps(_ apps: [RunningAppInfo], selfID: String?, skip: Set<String>) -> [Int] {
    apps.indices.filter { i in
        let a = apps[i]
        guard a.regular else { return false }
        if let id = a.bundleID {
            if id == selfID || skip.contains(id) { return false }
        }
        return true
    }
}

/// The apps the shutdown asks to quit before Stream Deck and Lightkey close.
func appsToQuitBeforeShutdown(_ apps: [RunningAppInfo], selfID: String?) -> [Int] {
    otherRegularApps(apps, selfID: selfID, skip: shutdownLeavesOpen)
}

/// Saved "NSStatusItem Visible …" keys that hide a menu bar icon (someone ⌘-dragged it off), so the
/// launch can clear them and the icon comes back.
func hiddenStatusItemKeys(_ defaults: [String: Any]) -> [String] {
    defaults.compactMap { key, value in
        key.hasPrefix("NSStatusItem Visible") && (value as? Bool) == false ? key : nil
    }.sorted()
}

/// Whether Booth Check's own menu bar icon is showing: its status bar window exists, has a size, and
/// sits on a screen.
/// Whether SwiftUI's write to MenuBarExtra's isInserted should be stored: only when it changes. Storing
/// every write republishes Booth and loops the main thread (see `BoothCheckApp.body`).
func menuIconWriteNeeded(_ new: Bool, current: Bool) -> Bool { new != current }

/// The header's words while the first pass hasn't finished: after 30 s it says what it's waiting for.
func checkingTitle(waited: TimeInterval, waitingFor: String?) -> String {
    guard waited >= 30 else { return "Checking\u{2026}" }
    return "Still checking after \(Int(waited)) s" + (waitingFor.map { ": waiting for \u{201C}\($0)\u{201D}" } ?? "")
}

func menuIconShown(windowFound: Bool, frame: CGRect, screens: [CGRect]) -> Bool {
    windowFound && frame.width > 0 && frame.height > 0 && screens.contains { $0.intersects(frame) }
}

/// Whether one of the front app's window sizes covers a whole screen (a full-screen app hides the menu bar).
func coversAScreen(_ windows: [CGSize], screens: [CGSize]) -> Bool {
    windows.contains { w in screens.contains { $0.width == w.width && $0.height == w.height } }
}

/// The menu bar icon's watch from pass to pass (see `watchMenuIcon`).
struct IconWatch: Equatable {
    var lastShown: Bool? = nil      // nil before the first pass
    var missingPasses = 0
    var reinsertTried = false       // once per time it goes missing
}

/// One 15-second pass of the icon's watch: the new state, whether to log (only when shown/not shown
/// changes), and whether to try putting the icon back (missing two passes in a row, once).
func iconPass(_ w: IconWatch, shown: Bool) -> (watch: IconWatch, log: Bool, reinsert: Bool) {
    var n = w
    let log = w.lastShown != shown
    n.lastShown = shown
    if shown {
        n.missingPasses = 0
        n.reinsertTried = false
        return (n, log, false)
    }
    n.missingPasses += 1
    let reinsert = n.missingPasses >= 2 && !n.reinsertTried
    if reinsert { n.reinsertTried = true }
    return (n, log, reinsert)
}

/// Apps whose window must keep the keyboard: macOS's password box, permission prompts, the login window.
let promptApps: Set<String> = ["com.apple.SecurityAgent", "com.apple.UserNotificationCenter", "com.apple.coreservices.uiagent",
                               "com.apple.accessibility.universalAccessAuthWarn", "com.apple.loginwindow"]

/// Whether the start-up should bring Lightkey to the front. Behind another app, its Authenticate alert
/// can't be seen and the Touch Bar doesn't offer it (church Mac, 9 Oct 2026: nothing on screen until
/// someone clicked Lightkey). Never over macOS's password box or a permission prompt, never over
/// Booth Check's own window, and at most three times, ten seconds apart, so it doesn't fight anyone.
func shouldFrontLightkey(frontmost: String?, me: String?, attempts: Int, sinceLast: TimeInterval) -> Bool {
    if let app = frontmost, app == IDs.lightkey || app == me || promptApps.contains(app) { return false }
    return attempts == 0 || (attempts < 3 && sinceLast >= 10)
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

/// "3 things to fix": the one wording for a problem count, in the header, the start-up panel's heading
/// and its "Check everything" step.
func thingsToFix(_ n: Int) -> String { "\(n) thing\(n == 1 ? "" : "s") to fix" }

/// The start-up's last step from the problem count now. The panel's heading counts the same rows, and
/// the step is kept in step with each pass while the panel is up (`syncCheckStep`), so the two always
/// say the same number (the owner saw "3 things to fix" over a step saying 2, Nov 2026).
func checkStepWords(problems n: Int) -> (state: StepState, detail: String) {
    n == 0 ? (.done, "Everything is green.") : (.warn, thingsToFix(n) + ". Open Booth Check to see what.")
}

/// The start-up panel's heading (see `BootView`).
func bootHeadline(finished: Bool, ready: Bool, problems n: Int) -> String {
    !finished ? "Starting the show" : ready ? "Ready for the service" : n > 0 ? thingsToFix(n) : "Started, with warnings"
}

/// Whether Lightkey reported the show's start states on "Lightkey Output" while the show opened (Nov
/// 2026): `mark` is what had come before (nil: Booth Check wasn't listening), `now` what has come by
/// the end of the start-up. Evidence for the Log and `startup_done`'s `start_state` (reported, none,
/// not_listened), never for "Ready": a show with no MIDI-mapped cue on at start reports nothing.
func startStateEvidence(mark: MIDIActivity?, now: MIDIActivity, late: Bool) -> (prop: String, messages: Int, on: Int, text: String) {
    guard let mark else {
        return ("not_listened", 0, 0, "Booth Check couldn\u{2019}t listen to \u{201C}\(IDs.lightkeyMIDIOutput)\u{201D} while the show opened (Lightkey\u{2019}s MIDI output wasn\u{2019}t there).")
    }
    let n = now.messages - mark.messages, on = now.cuesOn - mark.cuesOn
    let lateNote = late ? " Booth Check only began listening once Lightkey had opened with the show, so it may have missed some." : ""
    if n > 0 {
        return ("reported", n, on, "Lightkey reported \(n) cue state\(n == 1 ? "" : "s") on \u{201C}\(IDs.lightkeyMIDIOutput)\u{201D} as the show opened, \(on) of them on." + lateNote)
    }
    return ("none", 0, 0, "Lightkey reported no cue states on \u{201C}\(IDs.lightkeyMIDIOutput)\u{201D} while the show opened (a show already open sends none)." + lateNote)
}

/// Whether the start-up may quit and reopen Lightkey once because its MIDI input never appeared (Nov
/// 2026): only a Lightkey this start-up opened itself, without the show (so nothing is on stage yet), once.
func midiRelaunchAllowed(openedByStartUp: Bool, alreadyRelaunched: Bool, shuttingDown: Bool) -> Bool {
    openedByStartUp && !alreadyRelaunched && !shuttingDown
}

/// Whether a login start-up puts Lightkey's no-password setting back before Lightkey opens (Nov 2026):
/// it's wanted here (`MacSetup.noPasswordWanted`), it's off now, Lightkey isn't running (it reads its
/// settings when it opens, and would write its own back), and this Mac has a DMX interface.
func lightkeyNoPasswordRepairNeeded(wanted: Bool?, settingOn: Bool, lightkeyRunning: Bool, dmx: Bool) -> Bool {
    wanted == true && !settingOn && !lightkeyRunning && dmx
}

/// What `noPasswordWanted` becomes at the end of a start-up: a choice made stays; not known yet, a ready
/// start-up with the setting on makes it wanted.
func noPasswordWantedAfterStartUp(_ current: Bool?, ready: Bool, settingOn: Bool) -> Bool? {
    current ?? (ready && settingOn ? true : nil)
}

/// The login rows a login start-up fixes by itself (Nov 2026, the owner's call): Booth Check not at
/// login, a show or Stream Deck opening by itself, macOS reopening old apps. Only rows shown (switched
/// on in This Mac, not muted) that are warn or fail and carry their own fix's button; "couldn't read"
/// never counts. Booth Check adds itself only from Applications (a copy run from a build folder or a
/// download must not become the login item). Returns their ids, in the order the rows come.
func startUpLoginRepairs(_ checks: [Check], selfInApplications: Bool) -> [String] {
    checks.compactMap { c in
        guard c.status == .warn || c.status == .fail else { return nil }
        switch (c.id, c.action) {
        case ("selfLogin", .addSelfToLogin?):
            return selfInApplications ? c.id : nil
        case ("loginShows", .removeShowLoginItems?), ("deckLogin", .removeLoginItem?), ("reopen", .stopReopeningApps?):
            return c.id
        default: return nil
        }
    }
}

/// The start-up's steps, by id, in order. The DMX interface first (Lightkey attaches when it opens),
/// then other apps. With a Stream Deck on a Lightkey Mac: Lightkey without the show, its MIDI input
/// (the Stream Deck plugin looks for it when it starts), Stream Deck, and only then the show. Lightkey
/// sends every cue's state once, the moment a show opens, and opening the show again sends nothing;
/// a deck that wasn't listening yet showed Default off while it was on (rig-tested, 9 Oct 2026).
/// With the deck lights helper, its "Lightkey Feedback" port too before Stream Deck: the deck's keys
/// read their lights from it, so it has to be up to hear the states the show sends.
func startUpOrder(lightkey: Bool, dmx: Bool, streamDeck: Bool, apps: [String], checkOnly: Bool,
                  deckLights: Bool = false) -> [String] {
    if checkOnly { return ["check"] }
    let deckFirst = lightkey && streamDeck
    var steps: [String] = []
    if lightkey && dmx { steps.append("dmxWait") }
    steps += apps
    if deckFirst { steps += ["lightkeyApp", "midi"] + (deckLights ? ["deckLights"] : []) + ["deck"] }
    if lightkey { steps.append("lightkey") }
    if lightkey && dmx { steps.append("dmxLink") }
    if streamDeck && !deckFirst { steps.append("deck") }
    return steps + ["check"]
}

// MARK: - DMX self-recovery (pure parts)

// Church Mac, Booth Check 1.29: after quick restarts the DMX box wasn't picked up; a replug alone
// didn't help, a replug plus quitting and reopening Lightkey did. Lightkey's OLA server, olad 0.10.8,
// scans for FTDI devices once, when it starts (no hot-plug), and an olad left running on port 9011
// from a force-quit Lightkey is reused by the next Lightkey, with no devices. So: the box counts if
// either USB plane lists it; an orphaned olad goes before Lightkey opens; and during the start-up only,
// a ladder of retries (olad rescans on SIGHUP, Lightkey's Reset DMX Output, then restarting Lightkey).
// After the start-up nothing happens by itself: the row offers Reconnect, then Restart Lightkey.

/// Where the DMX interface was seen: `ioreg -p IOUSB` (the IOUSB plane) and
/// `ioreg -r -c IOUSBHostDevice` (the IOService plane). Either one counts.
struct DMXPlanes: Equatable {
    var usbPlane = false
    var servicePlane = false
    var present: Bool { usbPlane || servicePlane }
    var disagree: Bool { usbPlane != servicePlane }
    var text: String {
        switch (usbPlane, servicePlane) {
        case (true, true): return "seen in both USB planes"
        case (true, false): return "seen only in the IOUSB plane (ioreg -p IOUSB), not in the IOService plane (ioreg -r -c IOUSBHostDevice)"
        case (false, true): return "seen only in the IOService plane (ioreg -r -c IOUSBHostDevice), not in the IOUSB plane (ioreg -p IOUSB)"
        case (false, false): return "in neither USB plane"
        }
    }
}

let ioUSBPlaneArgs = ["-p", "IOUSB", "-l", "-w0"]
let ioServicePlaneArgs = ["-r", "-c", "IOUSBHostDevice", "-l", "-w0"]

func dmxPlanes(usbPlane: String, servicePlane: String) -> DMXPlanes {
    DMXPlanes(usbPlane: usbDevices(usbPlane).contains(where: isDMXInterface),
              servicePlane: usbDevices(servicePlane).contains(where: isDMXInterface))
}

/// One line of `ps -axo pid=,ppid=,lstart=,etime=,args=`.
struct PsProcess: Equatable {
    var pid: pid_t
    var ppid: pid_t
    var started: Date?
    var etime: String
    var args: String
    var name: String { ((args.split(separator: " ").first.map(String.init) ?? "") as NSString).lastPathComponent }
    var isOlad: Bool { name == "olad" }
    var isLightkey: Bool { args.contains("Lightkey.app/Contents/MacOS/Lightkey") }
}

let psDMXArgs = ["-axo", "pid=,ppid=,lstart=,etime=,args="]

/// Parses a `ps -axo pid=,ppid=,lstart=,etime=,args=` line: "812 700 Fri Nov 13 10:02:03 2026 00:35 /Library/OLA/…/olad …".
func parsePsLine(_ line: String, timeZone: TimeZone = .current) -> PsProcess? {
    let t = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    guard t.count >= 9, let pid = pid_t(t[0]), let ppid = pid_t(t[1]) else { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = timeZone
    f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    return PsProcess(pid: pid, ppid: ppid, started: f.date(from: t[2...6].joined(separator: " ")),
                     etime: t[7], args: t[8...].joined(separator: " "))
}

func parsePs(_ output: String, timeZone: TimeZone = .current) -> [PsProcess] {
    output.split(separator: "\n").compactMap { parsePsLine(String($0), timeZone: timeZone) }
}

/// Lightkey's olad processes left running with no Lightkey: the next Lightkey would reuse one as an
/// "external server", and it found its devices before the box was there. None while Lightkey runs.
func orphanOladPIDs(_ procs: [PsProcess]) -> [pid_t] {
    guard !procs.contains(where: \.isLightkey) else { return [] }
    return procs.filter { $0.isOlad && ($0.args.contains("Lightkey") || $0.args.hasPrefix("/Library/OLA/")) }.map(\.pid)
}

/// Whether `pid`, in a `ps` read just now, is still the olad Booth Check meant to signal. Lightkey's
/// server (Reconnect, the ladder's SIGHUP): an olad whose parent is Lightkey, or the only olad
/// running. A left-over one (`orphan`): still an olad left without Lightkey (`orphanOladPIDs`).
/// Anything else (gone, a new pid, another process now holding the number) is not signalled.
func oladStillTarget(_ procs: [PsProcess], pid: pid_t, orphan: Bool) -> Bool {
    guard let p = procs.first(where: { $0.pid == pid }), p.isOlad else { return false }
    if orphan { return orphanOladPIDs(procs).contains(pid) }
    let lightkeys = Set(procs.filter(\.isLightkey).map(\.pid))
    return lightkeys.contains(p.ppid) || procs.filter(\.isOlad).count == 1
}

/// What the Log and the sheet say when the olad has changed since its pid was read.
let oladChangedText = "Lightkey\u{2019}s DMX server has changed; check again. Booth Check sent nothing."

/// Re-reads `ps` and sends `signal` (e.g. "-HUP") to `pid` only if it's still the olad meant
/// (`oladStillTarget`); otherwise sends nothing and says so. The output shows the ps read and kill's.
func signalOladIfStill(_ signal: String, pid: pid_t, orphan: Bool) -> (out: String, code: Int32, sent: Bool) {
    let ps = shell("/bin/ps", psDMXArgs)
    let procs = parsePs(ps.out)
    let found = procs.first { $0.pid == pid }
    let seen = "$ " + commandLine("/bin/ps", psDMXArgs) + "\n"
        + (found.map { "pid \($0.pid): \($0.name), parent \($0.ppid), running \($0.etime)" } ?? "pid \(pid) isn\u{2019}t running.")
    guard ps.code == 0, oladStillTarget(procs, pid: pid, orphan: orphan) else {
        return (seen + "\n" + oladChangedText, 3, false)
    }
    let k = shell("/bin/kill", [signal, String(pid)])
    return (seen + "\n$ " + commandLine("/bin/kill", [signal, String(pid)]) + (k.out.isEmpty ? "" : "\n" + k.out), k.code, k.code == 0)
}

/// The olad serving this Lightkey: its child if there is one, else any olad (an external one it reused).
func lightkeyOlad(_ procs: [PsProcess], lightkeyPID: pid_t?) -> PsProcess? {
    procs.first { $0.isOlad && $0.ppid == lightkeyPID } ?? procs.first(where: \.isOlad)
}

/// Why the start-up shouldn't wait before trying to reconnect, or nil. Only two things make the link
/// suspect: at a login start-up, macOS reopened Lightkey before the box was seen; or the box really
/// appeared during this start-up (not at the first look) after olad had started, so olad's one scan
/// missed it. When the box was there at the first look, when olad started says nothing (an olad that
/// has run for an hour during a service is fine). Two seconds' slack: ps gives whole seconds, polls are 1 s apart.
func dmxLinkSuspect(atLogin: Bool, lightkeyRunningAtStart: Bool, boxSeenAtStart: Bool, oladStarted: Date?, boxFirstSeen: Date?) -> String? {
    if boxSeenAtStart { return nil }
    if atLogin && lightkeyRunningAtStart {
        return "macOS reopened Lightkey at login, before the DMX interface was seen."
    }
    if let o = oladStarted, let b = boxFirstSeen, o.addingTimeInterval(2) < b {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return "olad started at \(f.string(from: o)), before the DMX interface first appeared at \(f.string(from: b))."
    }
    return nil
}

/// What the start-up's DMX recovery has tried so far.
struct DMXLadder: Equatable {
    var started = false         // a rung ran (the sign went up, a snapshot was taken)
    var hupTried = false        // since the last relaunch
    var resetTried = false
    var hupSent = false         // ever, for the summary
    var resetPressed = false
    var relaunches = 0
    var unconfirmed = false     // stopped without restarting: no evidence olad missed the box
}

enum DMXRung: Equatable { case held, noLightkey, noBox, waitForPassword, hup(pid_t), skipHup, resetOutput, skipReset, relaunch, giveUp, unconfirmed }

/// The DMX link step's next move. Held: done. Box on neither USB plane: nothing to reconnect (that's
/// the replug sign's job). Lightkey asking for the password: wait for the person. Otherwise, in
/// order: SIGHUP to olad (it reloads its plugins and scans again), Lightkey's Reset DMX Output
/// (Accessibility), restarting Lightkey, at most `maxRelaunches` times per start-up; then give up.
/// The "held" check is experimental, so restarting Lightkey (the lights go dark) needs positive
/// evidence that olad hasn't got the box (`dmxRelaunchJustified`); without it the ladder stops at
/// `.unconfirmed` and nothing is restarted.
func dmxLadderNext(boxPresent: Bool, held: Bool, lightkeyRunning: Bool, oladPID: pid_t?, asking: Bool,
                   accessibility: Bool, ladder: DMXLadder, olaFound: Int?, suspect: Bool, suspectCounts: Bool, maxRelaunches: Int = 2) -> DMXRung {
    if held { return .held }
    if !lightkeyRunning { return .noLightkey }
    if !boxPresent { return .noBox }
    if asking { return .waitForPassword }
    if !ladder.hupTried { return oladPID.map { .hup($0) } ?? .skipHup }
    if !ladder.resetTried { return accessibility ? .resetOutput : .skipReset }
    guard dmxRelaunchJustified(olaFound: olaFound, oladRunning: oladPID != nil, suspect: suspect, suspectCounts: suspectCounts) else { return .unconfirmed }
    return ladder.relaunches < maxRelaunches ? .relaunch : .giveUp
}

/// Whether restarting Lightkey for the DMX link is backed by evidence, not just the experimental
/// "is holding the interface" check: olad's log says "Found 0 FTDI devices", or olad isn't running,
/// or the link was suspect (olad started before the box appeared, or macOS reopened Lightkey). An
/// OLA log that found a device, or says nothing, isn't enough. A suspect link doesn't count on its own
/// (`suspectCounts` false) for a Get the show started by hand while Lightkey was already running:
/// that's during a service, so only olad's log or a missing olad may restart Lightkey.
func dmxRelaunchJustified(olaFound: Int?, oladRunning: Bool, suspect: Bool, suspectCounts: Bool) -> Bool {
    olaFound == 0 || !oladRunning || (suspect && suspectCounts)
}

/// Whether a suspect link may justify restarting Lightkey: not for a start-up by hand (not at login)
/// that began with Lightkey already running.
func dmxSuspectCounts(atLogin: Bool, lightkeyRunningAtStart: Bool) -> Bool {
    atLogin || !lightkeyRunningAtStart
}

/// What the recovery did, in plain words, for the step's warning.
func dmxLadderTriedText(_ l: DMXLadder) -> String {
    var parts: [String] = []
    if l.hupSent { parts.append("asked Lightkey\u{2019}s DMX server to look for the interface again") }
    if l.resetPressed { parts.append("pressed Lightkey\u{2019}s Reset DMX Output") }
    if l.relaunches > 0 { parts.append("restarted Lightkey " + (l.relaunches == 1 ? "once" : "\(l.relaunches) times")) }
    guard !parts.isEmpty else { return "Booth Check couldn\u{2019}t try anything." }
    let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    return "Booth Check " + list + "."
}

/// Whether a menu item is Lightkey's "Reset DMX Output": that exact title (any case, spaces around
/// it, an optional trailing ellipsis), nothing else that mentions reset and DMX.
func isResetDMXOutputTitle(_ title: String) -> Bool {
    var t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if t.hasSuffix("\u{2026}") { t = String(t.dropLast()) } else if t.hasSuffix("...") { t = String(t.dropLast(3)) }
    return t.trimmingCharacters(in: .whitespaces) == "reset dmx output"
}

enum DMXRowFix: Equatable { case reconnect(pid_t), checking, restart }

/// After the start-up, the "Lightkey is sending DMX" row's button when the box is plugged in but not
/// held: Reconnect (SIGHUP to olad) first; for 10 s after it ran, just checking; then Restart Lightkey.
/// No olad to ask: Restart straight away. A person always presses it; nothing runs by itself.
func dmxRowFix(oladPID: pid_t?, sinceReconnect: TimeInterval?) -> DMXRowFix {
    if let s = sinceReconnect { return s < 10 ? .checking : .restart }
    return oladPID.map { .reconnect($0) } ?? .restart
}

/// What to do when Booth Check can't confirm Lightkey holds the DMX interface: try the lights.
let dmxUnconfirmedWords = "Press a key on the Stream Deck: if the lights don\u{2019}t respond, open Booth Check and click the button on the \u{201C}Lightkey is sending DMX\u{201D} row."

/// What Booth Check is fixing by itself, for the big sign (see `selfRepairWords`).
enum SelfRepair: Equatable {
    case dmxNotConnected, dmxAskingOlad, dmxResetOutput, dmxRestarting(Int), dmxConnected, dmxFailed, dmxReconnectFailed, dmxUnconfirmed
    case deckReopening, deckReopened, deckRestarting, deckRestarted, deckFailed
    case helperRestarting, helperRestarted, helperFailed
    case deckProfileSwitching(String), deckProfileSwitched(String), deckProfileFailed(String)
    case deckKeysRestoring, deckKeysRestored, deckKeysRestoreFailed
}

/// The sign's words for each self-repair: a title and one plain line.
func selfRepairWords(_ r: SelfRepair) -> (title: String, detail: String) {
    switch r {
    case .dmxNotConnected: return ("The lights aren\u{2019}t connected", "Reconnecting\u{2026}")
    case .dmxAskingOlad: return ("Reconnecting the lights", "Asking Lightkey to look for the lights again.")
    case .dmxResetOutput: return ("Reconnecting the lights", "Resetting Lightkey\u{2019}s DMX output.")
    case .dmxRestarting(let n):
        return ("Restarting Lightkey", "The lights go dark for about 20 seconds." + (n > 1 ? " (Second try.)" : ""))
    case .dmxConnected: return ("The lights are connected", "You can use the Mac now.")
    case .dmxFailed: return ("Couldn\u{2019}t reconnect the lights", replugDMXWords)
    case .dmxReconnectFailed:
        return ("The lights still aren\u{2019}t connected", "Open Booth Check and click Restart Lightkey\u{2026} (the lights go dark for about 20 seconds).")
    case .dmxUnconfirmed: return ("Couldn\u{2019}t confirm the lights are connected", dmxUnconfirmedWords)
    case .deckReopening: return ("Stream Deck closed", "Opening it again\u{2026}")
    case .deckReopened: return ("Stream Deck is open again", "Its keys work again.")
    case .deckRestarting: return ("Restarting Stream Deck", "So its keys start clean.")
    case .deckRestarted: return ("Stream Deck restarted", "Its keys start clean.")
    case .deckFailed: return ("Couldn\u{2019}t open Stream Deck", "Open Booth Check and click Open Stream Deck on its row.")
    case .helperRestarting: return ("The deck\u{2019}s key lights stopped", "Restarting the deck lights helper\u{2026}")
    case .helperRestarted: return ("The deck\u{2019}s key lights are back", "The deck lights helper is running again.")
    case .helperFailed: return ("Couldn\u{2019}t restart the deck lights helper", "The keys still work, and Booth Check tries again by itself shortly.")
    case .deckProfileSwitching(let name): return ("Putting Stream Deck on the \u{201C}\(name)\u{201D} profile", "Its keys go dark for a few seconds.")
    case .deckProfileSwitched(let name): return ("Stream Deck is on \u{201C}\(name)\u{201D}", "Its keys work again.")
    case .deckProfileFailed(let name): return ("Couldn\u{2019}t switch Stream Deck\u{2019}s profile", "In Stream Deck, choose \u{201C}\(name)\u{201D} at the top of its window.")
    case .deckKeysRestoring: return ("Putting the Stream Deck\u{2019}s keys back\u{2026}", "Its keys go dark for a few seconds.")
    case .deckKeysRestored: return ("The Stream Deck\u{2019}s keys are back", "They work again.")
    case .deckKeysRestoreFailed: return ("Couldn\u{2019}t put the Stream Deck\u{2019}s keys back", "Open Booth Check to see what to press.")
    }
}

let olaLogPath = NSHomeDirectory() + "/Library/Logs/Lightkey OLA.log"

/// The last "Found N FTDI devices" line in olad's log (`~/Library/Logs/Lightkey OLA.log`).
func olaFoundDevices(_ log: String) -> (count: Int, line: String)? {
    for raw in log.split(separator: "\n").reversed() {
        let line = String(raw)
        guard let r = line.range(of: "Found ") else { continue }
        let rest = line[r.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        if let n = Int(digits), rest.dropFirst(digits.count).hasPrefix(" FTDI device") {
            return (n, line.trimmingCharacters(in: .whitespaces))
        }
    }
    return nil
}

/// Text kept to `maxBytes`: the start and the end, with a note of how much was cut.
func capText(_ s: String, maxBytes: Int) -> String {
    let bytes = Array(s.utf8)
    guard bytes.count > maxBytes else { return s }
    let half = maxBytes / 2
    return String(decoding: bytes[..<half], as: UTF8.self)
        + "\n\u{2026} (\(bytes.count - 2 * half) bytes cut) \u{2026}\n"
        + String(decoding: bytes[(bytes.count - half)...], as: UTF8.self)
}

/// The blocks for one USB vendor (FTDI by default) in `ioreg -l` output of either plane: the device's
/// name and class, its key properties, its parent chain and its children's classes (the driver).
func ftdiBlocks(_ output: String, vendor: Int = IDs.ftdiVendor) -> [String] {
    struct Node { var depth: Int; var header: String; var props: [(String, String)] = []; var parent: Int? }
    var nodes: [Node] = [], stack: [Int] = []
    for raw in output.split(separator: "\n") {
        let line = String(raw)
        if let r = line.range(of: "+-o ") {
            let depth = line.distance(from: line.startIndex, to: r.lowerBound)
            while let last = stack.last, nodes[last].depth >= depth { stack.removeLast() }
            nodes.append(Node(depth: depth, header: String(line[r.upperBound...]), parent: stack.last))
            stack.append(nodes.count - 1)
        } else if let cur = stack.last, let q1 = line.firstIndex(of: "\""), let eq = line.range(of: "\" = "), q1 < eq.lowerBound {
            nodes[cur].props.append((String(line[line.index(after: q1)..<eq.lowerBound]),
                                     String(line[eq.upperBound...]).trimmingCharacters(in: .whitespaces)))
        }
    }
    func name(_ n: Node) -> String { n.header.components(separatedBy: "  <class").first ?? n.header }
    func cls(_ n: Node) -> String {
        guard let r = n.header.range(of: "<class ") else { return "?" }
        return String(n.header[r.upperBound...].prefix { $0 != "," && $0 != ">" })
    }
    func isVendor(_ n: Node) -> Bool { n.props.contains { $0.0 == "idVendor" && Int($0.1) == vendor } }
    let keys: Set = ["USB Product Name", "USB Vendor Name", "USB Serial Number", "kUSBSerialNumberString", "locationID",
                     "sessionID", "idVendor", "idProduct", "USB Address", "IOCFPlugInTypes"]
    var blocks: [String] = []
    for (i, n) in nodes.enumerated() where isVendor(n) && !(n.parent.map { isVendor(nodes[$0]) } ?? false) {
        var lines = ["\(name(n))  [\(cls(n))]"]
        for (k, v) in n.props where keys.contains(k) || k.localizedCaseInsensitiveContains("speed") { lines.append("  \(k) = \(v)") }
        var chain: [String] = [], p = n.parent
        while let j = p { if !nodes[j].header.hasPrefix("Root") { chain.insert(name(nodes[j]), at: 0) }; p = nodes[j].parent }
        lines.append("  Parent chain: " + (chain.isEmpty ? "(top level)" : chain.joined(separator: " > ")))
        var kids: [String] = []
        var j = i + 1
        while j < nodes.count, nodes[j].depth > n.depth { kids.append("\(name(nodes[j])) [\(cls(nodes[j]))]"); j += 1 }
        lines.append("  Children: " + (kids.isEmpty ? "(none)" : kids.joined(separator: ", ")))
        blocks.append(lines.joined(separator: "\n"))
    }
    return blocks
}

/// The snapshot's file name: dmx-2026-11-13-101503-ladder.txt.
func dmxSnapshotFileName(_ date: Date, reason: String) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd-HHmmss"
    let safe = String(reason.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
    return "dmx-\(f.string(from: date))-\(safe).txt"
}

/// Which snapshot files to remove so only the newest `keep` remain (the names sort by time).
func snapshotFilesToRemove(_ names: [String], keep: Int = 30) -> [String] {
    Array(names.filter { $0.hasPrefix("dmx-") && $0.hasSuffix(".txt") }.sorted(by: >).dropFirst(keep))
}

/// The snapshot's one-line summary for the Log.
func dmxSnapshotSummary(planes: DMXPlanes, held: Bool, olad: PsProcess?, found: (count: Int, line: String)?) -> String {
    [planes.present ? "DMX interface present (\(planes.text))" : "DMX interface not on USB",
     held ? "held by Lightkey/olad" : "not held",
     olad.map { "olad pid \($0.pid), running \($0.etime)" } ?? "no olad",
     found.map { "OLA log: \u{201C}Found \($0.count) FTDI device\($0.count == 1 ? "" : "s")\u{201D}" } ?? "OLA log: no \u{201C}Found N FTDI devices\u{201D} line"
    ].joined(separator: " \u{00B7} ")
}

// MARK: - DMX self-recovery (reading the system; safe off the main thread)

/// Both USB planes, read now.
func readDMXPlanes() -> (planes: DMXPlanes, usbOut: String, serviceOut: String) {
    let usb = shell("/usr/sbin/ioreg", ioUSBPlaneArgs).out
    let service = shell("/usr/sbin/ioreg", ioServicePlaneArgs).out
    return (dmxPlanes(usbPlane: usb, servicePlane: service), usb, service)
}

/// The DMX picture now: the planes, Lightkey's and olad's processes, and whether either holds the
/// interface (a USB user client they opened, or a USB serial port they have open), as the
/// "Lightkey is sending DMX" row reads it.
struct DMXState {
    var planes = DMXPlanes()
    var usbOut = "", serviceOut = ""
    var procs: [PsProcess] = []
    var olad: PsProcess?
    var held = false
}

func readDMXState(lightkeyPID: pid_t?) -> DMXState {
    var s = DMXState()
    (s.planes, s.usbOut, s.serviceOut) = readDMXPlanes()
    s.procs = parsePs(shell("/bin/ps", psDMXArgs).out)
    s.olad = lightkeyOlad(s.procs, lightkeyPID: lightkeyPID)
    guard let lk = lightkeyPID else { return s }
    let pids = [lk] + s.procs.filter(\.isOlad).map(\.pid)
    s.held = !usbConnections(shell("/usr/sbin/ioreg", ["-l", "-w0", "-c", "IOUserClient"]).out, pids: pids).isEmpty
        || shell("/usr/sbin/lsof", lsofArgs(pids)).out.split(separator: "\n").contains {
            $0.hasPrefix("n/dev/") && ($0.contains("usbserial") || $0.contains("usbmodem"))
        }
    return s
}

/// Presses a menu item of an app's menu bar through Accessibility. Returns whether it pressed, and
/// the item's menu path if found ("Lightkey > Reset DMX Output").
func pressMenuItem(pid: pid_t, matching: (String) -> Bool) -> (pressed: Bool, path: String?) {
    guard let bar = axAttribute(axApp(pid), kAXMenuBarAttribute) else { return (false, nil) }
    func search(_ e: AXUIElement, depth: Int, path: [String]) -> (AXUIElement, String)? {
        for c in axChildren(e) {
            let title = axAttribute(c, kAXTitleAttribute) as? String ?? ""
            let p = title.isEmpty ? path : path + [title]
            if axAttribute(c, kAXRoleAttribute) as? String == kAXMenuItemRole, matching(title) { return (c, p.joined(separator: " > ")) }
            if depth > 0, let found = search(c, depth: depth - 1, path: p) { return found }
        }
        return nil
    }
    guard let (item, path) = search(bar as! AXUIElement, depth: 4, path: []) else { return (false, nil) }
    let enabled = axAttribute(item, kAXEnabledAttribute) as? Bool ?? true
    return (enabled && AXUIElementPerformAction(axTimed(item), kAXPressAction as CFString) == .success, path)
}

// MARK: - The deck lights helper (pure parts)

// A small command-line helper (Lightkey-Skill repo, tools/deck_state_helper.swift) listens to
// "Lightkey Output", keeps which cues are on, and repeats it every 0.5 s on its own MIDI source,
// "Lightkey Feedback", which the deck's keys use as MIDI In. Without it the key lights stop following
// Lightkey; presses still work, they go straight to "Lightkey Input". launchd runs it for the
// logged-in user, so it keeps running while Booth Check is quit or updated. Booth Check carries a copy
// and installs it (1.27; what install_helper.sh does), checks it, and restarts it by itself when it
// stops working, but never runs it itself.

var deckHelperDomain: String { "gui/\(getuid())" }
var deckHelperService: String { "\(deckHelperDomain)/\(IDs.deckHelper)" }
var deckHelperPlist: String { NSHomeDirectory() + "/Library/LaunchAgents/\(IDs.deckHelper).plist" }
var deckHelperBinary: String { NSHomeDirectory() + "/Library/Application Support/DeckStateHelper/deck_state_helper" }
var deckHelperLog: String { NSHomeDirectory() + "/Library/Logs/DeckStateHelper.log" }
/// The copy Booth Check carries: build.sh puts helper/deck_state_helper in the app's Resources.
let deckHelperBundled = Bundle.main.path(forResource: "deck_state_helper", ofType: nil)
let deckHelperBundledSHA = deckHelperBundled.flatMap(fileSHA256)

/// What it's started with: the Summit show's rules, from the show's installer (Lightkey-Skill
/// LightKeyoutputs/summit2026/helper/install_helper.sh: MASK, WHILE, ALIAS; that folder's
/// tests/test_helper_args.py checks them against the show, tests/test_deckinstall.swift checks these match).
let deckHelperArgs = ["--mask", "5:3-6", "--while", "6:38-39,8:38-39,10:38-39,13:38-39", "--alias", "5:22=5:40,5:23=5:41"]

func fileSHA256(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// The LaunchAgent: start at login, restart within 2 s whenever it stops, log to ~/Library/Logs.
/// `args`: the show's rules (the built-in Summit ones, or a `.deck.json`'s: see `parseDeckShowFile`).
func deckHelperPlistXML(args: [String] = deckHelperArgs) -> String {
    let esc = { (s: String) in s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
    let program = ([deckHelperBinary] + args).map { "<string>\(esc($0))</string>" }.joined()
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key><string>\(IDs.deckHelper)</string>
        <key>ProgramArguments</key><array>\(program)</array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><true/>
        <key>ThrottleInterval</key><integer>2</integer>
        <key>ProcessType</key><string>Interactive</string>
        <key>StandardOutPath</key><string>\(esc(deckHelperLog))</string>
        <key>StandardErrorPath</key><string>\(esc(deckHelperLog))</string>
    </dict>
    </plist>
    """
}

/// Install or update, as the script the sheet shows and runs: stop the old copy (and any started by
/// hand, which would hold the helper's lock), copy the new one in, write the LaunchAgent, start it.
func deckHelperInstallScript(from source: String, args: [String] = deckHelperArgs) -> String {
    let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let home = NSHomeDirectory()
    return """
    set -eu
    launchctl bootout \(deckHelperService) 2>/dev/null || true
    for _ in $(seq 20); do launchctl print \(deckHelperService) >/dev/null 2>&1 || break; sleep 0.25; done
    pkill -x deck_state_helper || true
    mkdir -p \(q((deckHelperBinary as NSString).deletingLastPathComponent)) \(q(home + "/Library/LaunchAgents")) \(q(home + "/Library/Logs"))
    cp -f \(q(source)) \(q(deckHelperBinary))
    chmod 755 \(q(deckHelperBinary))
    xattr -d com.apple.quarantine \(q(deckHelperBinary)) 2>/dev/null || true
    cat > \(q(deckHelperPlist)) <<'EOF'
    \(deckHelperPlistXML(args: args))
    EOF
    plutil -lint \(q(deckHelperPlist))
    launchctl bootstrap \(deckHelperDomain) \(q(deckHelperPlist))
    """
}

/// What the helper's log says about a copy just started, from the lines written since: nil while it's
/// still starting, unless `final`. Fine once it's up with one alias line per --alias pair (an older
/// helper ignores --alias without a word).
func deckHelperStartVerdict(_ log: String, final: Bool, args: [String] = deckHelperArgs) -> (ok: Bool, text: String)? {
    let lines = log.split(separator: "\n").map(String.init)
    if let bad = lines.last(where: { $0.contains("could not") || $0.contains("WATCHDOG") || $0.contains("bad --") }) {
        return (false, "Its log says: \(bad)")
    }
    let up = lines.contains { $0.contains("deck_state_helper up") }
    let aliases = args.firstIndex(of: "--alias").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }?
        .split(separator: ",").count ?? 0
    if up && lines.filter({ $0.contains("alias: deck key") }).count >= aliases {
        return (true, aliases == 0 ? "It started." : "It started and its log shows all \(aliases) --alias rules.")
    }
    guard final else { return nil }
    if lines.contains(where: { $0.contains("waiting for it to stop") }) {
        return (false, "Another copy of the helper holds its lock, so the new one is waiting for it. Quit that copy (Terminal: pkill -x deck_state_helper) and it takes over.")
    }
    return (false, up ? "It started without its --alias rules, so it\u{2019}s an older helper."
                      : "It didn\u{2019}t start within 6 seconds.")
}

/// Runs the install script, then watches the log and launchd for up to 6 s to see the new copy start.
func runDeckHelperInstall(_ script: String, args: [String] = deckHelperArgs) -> (out: String, code: Int32) {
    let logSize = { (try? FileManager.default.attributesOfItem(atPath: deckHelperLog)[.size] as? Int) ?? 0 }
    let from = logSize()
    let r = shell("/bin/bash", ["-c", script], timeout: 60)
    guard r.code == 0 else { return (r.out + "\nThe install stopped there; nothing was started.", r.code) }
    var verdict: (ok: Bool, text: String)?
    for i in 1...24 where verdict == nil {
        Thread.sleep(forTimeInterval: 0.25)
        let data = FileManager.default.contents(atPath: deckHelperLog) ?? Data()
        verdict = deckHelperStartVerdict(String(decoding: data.dropFirst(data.count < from ? 0 : from), as: UTF8.self), final: i == 24, args: args)
    }
    let state = launchdJobState(shell("/bin/launchctl", ["print", deckHelperService]).out)
    let ok = verdict?.ok == true && state == "running"
    return (r.out + "\nlaunchd: \(state ?? "not loaded"). " + (verdict?.text ?? "") + (ok ? "" : " Not working yet: look at \(deckHelperLog)."),
            ok ? 0 : 1)
}

/// Whether Booth Check restarts a failing helper by itself now: it has been failing for 10 s (launchd
/// restarts a crash within 2), and Booth Check hasn't already done so in the last minute or 3 times in
/// 30 minutes, so it can never cycle it (each restart remakes the deck's port, and many in a row lose
/// the deck: rig, 28 Oct 2026). `fixes` = seconds since each earlier one.
func deckHelperAutoFix(failingFor: TimeInterval, fixes: [TimeInterval]) -> Bool {
    failingFor >= 10 && !deckHelperGaveUp(fixes: fixes) && fixes.allSatisfy { $0 >= 60 }
}
func deckHelperGaveUp(fixes: [TimeInterval]) -> Bool { fixes.filter { $0 < 1800 }.count >= 3 }

/// `launchctl` arguments behind the buttons. All for this user's own launchd: no password.
/// Restart stops and starts it in one go; the deck picks its port up again by itself (rig, 28 Oct
/// 2026), so Stream Deck needn't restart. Start loads the installed plist; Stop is Start's undo.
func deckHelperRestartArgs() -> [String] { ["kickstart", "-k", deckHelperService] }
func deckHelperStartArgs() -> [String] { ["bootstrap", deckHelperDomain, deckHelperPlist] }
func deckHelperStopArgs() -> [String] { ["bootout", deckHelperService] }

/// The job's own state ("running", "not running") from `launchctl print` output: the line one tab in.
/// Deeper blocks have states of their own, and "job state" is something else.
func launchdJobState(_ output: String) -> String? {
    for line in output.split(separator: "\n") where line.hasPrefix("\tstate = ") {
        return line.dropFirst("\tstate = ".count).trimmingCharacters(in: .whitespaces)
    }
    return nil
}

/// Whether to switch the This Mac setting on by itself: never decided here, and the helper's plist is
/// there. From then on it's a plain setting, so a removed helper shows red instead of vanishing.
func deckLightsAutoOn(setting: Bool?, installed: Bool, lightkey: Bool, streamDeck: Bool) -> Bool {
    setting == nil && installed && lightkey && streamDeck
}

/// "Deck lights helper running": launchd runs it and its "Lightkey Feedback" port is there. `current`:
/// the installed copy is the one Booth Check carries (nil: unknown). `lastLog`: the log's last line,
/// shown when it fails. `gaveUp`: Booth Check's own restarts didn't fix it (see `deckHelperAutoFix`).
func deckHelperCheck(installed: Bool, loaded: Bool, state: String?, feedbackPort: Bool,
                     current: Bool? = nil, lastLog: String? = nil, gaveUp: Bool = false, argsCurrent: Bool? = nil) -> Check {
    let title = "Deck lights helper running"
    // Running, but its LaunchAgent starts it with other rules than Booth Check would install for this
    // show (see `deckHelperArgsCurrent`): the key lights may follow the wrong cues. Presses still work.
    if loaded && state == "running" && feedbackPort && argsCurrent == false {
        return Check(id: "deckLights", group: "Stream Deck", title: title, status: .warn,
                     detail: "It\u{2019}s running, but installed with old settings: its rules aren\u{2019}t the ones Booth Check would install for this show, so some key lights may not follow Lightkey. Presses still work.",
                     fix: "Install / update puts the right ones in (no password).", action: .installDeckHelper)
    }
    let effect = "so the deck\u{2019}s key lights may not follow Lightkey. Presses still work."
    let log = lastLog.map { " Its log: \u{201C}\($0)\u{201D}" } ?? ""
    let selfFix = "Booth Check fixes this by itself within half a minute."
    // Its own restarts didn't help: putting it in again (which also restarts Stream Deck) is the one press left.
    let gaveUpFix = "Booth Check restarted it 3 times in 30 minutes without luck: click Install\u{2026} to put it in again (no password)."
    if loaded && state == "running" && feedbackPort {
        return Check(id: "deckLights", group: "Stream Deck", title: title, status: .ok,
                     detail: "Its \u{201C}\(IDs.deckFeedback)\u{201D} MIDI port is there, so the deck\u{2019}s key lights follow Lightkey."
                        + (current == false ? " (Booth Check carries a different version: This Mac \u{2192} Stream Deck \u{2192} Install / update.)" : ""))
    }
    if loaded {
        return Check(id: "deckLights", group: "Stream Deck", title: title, status: .fail,
                     detail: (state == "running"
                        ? "It\u{2019}s running, but its \u{201C}\(IDs.deckFeedback)\u{201D} MIDI port isn\u{2019}t there, \(effect)"
                        : "It\u{2019}s set up but not running (launchd says \u{201C}\(state ?? "no state")\u{201D}), \(effect)") + log,
                     fix: gaveUp ? gaveUpFix : selfFix + " Or restart it now: Stream Deck picks it up again by itself.",
                     action: gaveUp ? .installDeckHelper : .restartDeckHelper)
    }
    if installed {
        return Check(id: "deckLights", group: "Stream Deck", title: title, status: .fail,
                     detail: "It\u{2019}s installed but not started, \(effect)" + log,
                     fix: gaveUp ? gaveUpFix : selfFix + " Or start it now. From then on it starts by itself at every login.",
                     action: gaveUp ? .installDeckHelper : .startDeckHelper)
    }
    return Check(id: "deckLights", group: "Stream Deck", title: title, status: .fail,
                 detail: "It isn\u{2019}t installed on this Mac, \(effect)",
                 fix: "Install it (no password). If this Mac doesn\u{2019}t use it, untick Deck lights helper in This Mac.",
                 action: .installDeckHelper)
}

/// The ProgramArguments in the installed LaunchAgent plist (nil: no plist, or not one Booth Check can read).
func installedHelperArgs(_ plist: Data?) -> [String]? {
    guard let plist, let d = (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any] else { return nil }
    return d["ProgramArguments"] as? [String]
}

/// Whether the installed LaunchAgent starts the helper exactly as Booth Check would install it: the
/// installed copy, then this show's rules in the same order. nil: couldn't read it.
func deckHelperArgsCurrent(installed: [String]?, binary: String = deckHelperBinary, expected: [String]) -> Bool? {
    installed.map { $0 == [binary] + expected }
}

// MARK: - The show's deck file (1.32)

// A show may carry `<show name>.deck.json` next to it, saying how its deck is meant to work:
//   {"helper": {"channels": "2", "mask": "2:3-6", "while": "2:38-39", "alias": "2:22=2:40"} | null,
//    "profile": "Lightkey XL Service", "blackout": "2:0"}
// `helper`: the deck lights helper's rules for this show (null: this show doesn't use the helper);
// `profile`: the Stream Deck profile name suggested in This Mac; `blackout` (1.30, optional): the
// show's Blackout as channel:note for the shutdown's "Black out the stage first" (null: this show has
// none; left out: the deck profile's Blackout key). No file: the built-in Summit rules.

struct DeckShowFile: Equatable {
    /// The helper's arguments; nil when the file says `"helper": null` (the helper rows don't apply).
    var helperArgs: [String]? = deckHelperArgs
    /// The arguments came from the file (false: the built-in Summit ones).
    var helperFromFile = false
    var profile: String? = nil
    var blackout: DeckFileBlackout = .notSet
}

/// "<show folder>/<show name>.deck.json" for a show file.
func deckShowFilePath(forShow show: String) -> String {
    ((show as NSString).deletingPathExtension) + ".deck.json"
}

/// A list of channel:note or channel:first-last, as the helper's --mask and --while take it.
private func helperKeyList(_ s: String, channels: ClosedRange<Int>) -> Bool {
    let items = s.split(separator: ",", omittingEmptySubsequences: false)
    return !items.isEmpty && items.allSatisfy { item in
        let p = item.split(separator: ":", omittingEmptySubsequences: false)
        guard p.count == 2, let ch = Int(p[0]), channels.contains(ch) else { return false }
        let n = p[1].split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...2).contains(n.count), n.allSatisfy({ $0.map { (0...127).contains($0) } == true }) else { return false }
        return n.count == 1 || n[0]! <= n[1]!
    }
}

/// Reads a `.deck.json` strictly: unknown keys are ignored; a bad value means the built-in rules are
/// used, with a warning for the Log. Never throws.
func parseDeckShowFile(_ data: Data) -> (file: DeckShowFile, warnings: [String]) {
    var file = DeckShowFile(), warnings: [String] = []
    guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return (file, ["It isn\u{2019}t a JSON object, so the built-in deck lights helper rules are used."])
    }
    if let p = d["profile"] {
        if let name = p as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty { file.profile = name }
        else if !(p is NSNull) { warnings.append("\u{201C}profile\u{201D} isn\u{2019}t a name, so it\u{2019}s ignored.") }
    }
    if let b = d["blackout"] {
        if b is NSNull { file.blackout = .none }
        else if let s = b as? String, let n = parseMIDINote(s) { file.blackout = .note(n) }
        else { warnings.append("\u{201C}blackout\u{201D} isn\u{2019}t channel:note like \u{201C}2:0\u{201D} (or null), so it\u{2019}s ignored and the deck\u{2019}s Blackout key is used.") }
    }
    guard let h = d["helper"] else { return (file, warnings) }
    if h is NSNull {
        file.helperArgs = nil
        return (file, warnings)
    }
    guard let helper = h as? [String: Any] else {
        return (file, warnings + ["\u{201C}helper\u{201D} isn\u{2019}t an object or null, so the built-in rules are used."])
    }
    var values: [String: String] = [:]
    for key in ["channels", "mask", "while", "alias"] {
        guard let v = helper[key], !(v is NSNull) else { continue }
        guard let s = v as? String else {
            return (file, warnings + ["helper.\(key) isn\u{2019}t text, so the built-in rules are used."])
        }
        let t = s.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { values[key] = t }
    }
    func bad(_ why: String) -> (file: DeckShowFile, warnings: [String]) {
        (file, warnings + [why + ", so the built-in rules are used."])
    }
    var channels = 5...13                                          // the helper's own default
    if let c = values["channels"] {
        let n = c.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...2).contains(n.count), n.allSatisfy({ $0.map { (1...16).contains($0) } == true }), n.first!! <= n.last!! else {
            return bad("helper.channels \u{201C}\(c)\u{201D} isn\u{2019}t a channel or a range of channels 1\u{2013}16 (like 2 or 5-13)")
        }
        channels = n.first!!...n.last!!
    }
    for key in ["mask", "while"] {
        if let v = values[key], !helperKeyList(v, channels: channels) {
            return bad("helper.\(key) \u{201C}\(v)\u{201D} isn\u{2019}t a list like 5:3-6,6:7 inside the helper\u{2019}s channels")
        }
    }
    if (values["mask"] == nil) != (values["while"] == nil) { return bad("helper.mask and helper.while go together") }
    if let a = values["alias"] {
        let ok = a.split(separator: ",", omittingEmptySubsequences: false).allSatisfy { pair in
            let sides = pair.split(separator: "=", omittingEmptySubsequences: false)
            return sides.count == 2 && sides.allSatisfy { !$0.contains("-") && helperKeyList(String($0), channels: channels) }
        }
        if !ok { return bad("helper.alias \u{201C}\(a)\u{201D} isn\u{2019}t a list like 5:22=5:40 inside the helper\u{2019}s channels") }
    }
    file.helperArgs = ["channels", "mask", "while", "alias"].flatMap { k in values[k].map { ["--\(k)", $0] } ?? [] }
    file.helperFromFile = true
    return (file, warnings)
}

/// Stream Deck's Devices preference, read through cfprefsd (synchronised first, so it's what Stream
/// Deck itself last wrote). Read only.
func readStreamDeckDevices() -> Any? {
    CFPreferencesAppSynchronize(IDs.streamDeck as CFString)
    return CFPreferencesCopyAppValue("Devices" as CFString, IDs.streamDeck as CFString)
}

/// Writes the whole Devices value back through cfprefsd (never the plist file itself). Only ever
/// called with Stream Deck closed, with a value from `deckDevicesSetting` (see `setPreferredProfile`).
func writeStreamDeckDevices(_ devices: [String: Any]) -> Bool {
    CFPreferencesSetAppValue("Devices" as CFString, devices as CFDictionary, IDs.streamDeck as CFString)
    return CFPreferencesAppSynchronize(IDs.streamDeck as CFString)
}

/// The steps the profile switch's sheet shows (and its undo, with the old UUID).
func deckProfileSwitchSteps(device: String, to uuid: String) -> String {
    """
    1. Quit Stream Deck (NSRunningApplication.terminate; made to quit after 5 s)
    2. With Stream Deck closed, change one value in its settings:
       CFPreferencesCopyAppValue("Devices", "\(IDs.streamDeck)")
       Devices \u{2192} "\(device)" \u{2192} ESDProfilesInfo \u{2192} ESDProfilesPreferred = "\(uuid)"
       CFPreferencesSetAppValue("Devices", <the same Devices, that one value changed>, "\(IDs.streamDeck)")
       CFPreferencesAppSynchronize("\(IDs.streamDeck)")
    3. Open Stream Deck in the background
    4. 10 s after it opens, read ESDProfilesPreferred back
    """
}

/// The show's deck file, if there is one: nil when there's no file next to the show.
func loadDeckShowFile(forShow show: String?) -> (file: DeckShowFile, warnings: [String], path: String)? {
    guard let show else { return nil }
    let path = deckShowFilePath(forShow: show)
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    let r = parseDeckShowFile(data)
    return (r.file, r.warnings, path)
}

/// What the deck file means, in one plain paragraph for the Log.
func deckShowFileText(_ r: (file: DeckShowFile, warnings: [String], path: String)?) -> String {
    guard let r else { return "No .deck.json next to the show: the built-in deck lights helper rules (" + deckHelperArgs.joined(separator: " ") + ")." }
    let helper = r.file.helperArgs == nil ? "This show doesn\u{2019}t use the deck lights helper, so its rows don\u{2019}t apply."
        : r.file.helperFromFile ? "Deck lights helper rules: " + (r.file.helperArgs!.isEmpty ? "(none: the helper\u{2019}s defaults)" : r.file.helperArgs!.joined(separator: " ")) + "."
        : "Deck lights helper rules: the built-in ones (" + deckHelperArgs.joined(separator: " ") + ")."
    let blackout: String
    switch r.file.blackout {
    case .notSet: blackout = ""
    case .none: blackout = "\nBlackout: none in this show."
    case .note(let n): blackout = "\nBlackout: \(n.text)."
    }
    return "\(r.path)\n\(helper)" + (r.file.profile.map { "\nSuggested Stream Deck profile: \u{201C}\($0)\u{201D}." } ?? "") + blackout
        + r.warnings.map { "\nWarning: \($0)" }.joined()
}

// MARK: - Stream Deck profiles (1.32)

// Stream Deck keeps each profile in ~/Library/Application Support/com.elgato.StreamDeck/ProfilesV3/
// <UUID>.sdProfile: manifest.json (Name, Device, Pages) and Profiles/<PAGE>/manifest.json, whose
// Controllers[].Actions["col,row"] are the keys. The keys that drive Lightkey are the Trevliga Spel
// MIDI plugin's (settings g02 mode, g47 channel 0-based, g45 note, smo out port, smi in port). Which
// profile each deck shows is in its preferences: Devices → "@(1)[vendor/product/serial]" →
// ESDProfilesInfo → ESDProfilesPreferred (the folder's UUID, lowercased). Elgato's private format: read
// strictly, and anything unexpected is "can't tell", never a failure.

let trevligaPlugin = "se.trevligaspel.midi"
var streamDeckSupportDir: String { NSHomeDirectory() + "/Library/Application Support/com.elgato.StreamDeck" }

/// One MIDI key as Lightkey sees it. The set of these over a profile is its signature: names and
/// UUIDs don't identify a version (an import makes a new UUID; versions share a name).
struct DeckMIDIKey: Hashable, Comparable {
    let channel: Int        // 1-based, as Lightkey shows it
    let note: Int
    let mode: String        // Latch, Toggle, Hold, Push
    let inPort: String      // smi: where its light comes from
    let outPort: String     // smo: where its press goes
    var text: String { "\(channel):\(note):\(mode):\(inPort)>\(outPort)" }
    static func < (a: DeckMIDIKey, b: DeckMIDIKey) -> Bool {
        (a.channel, a.note, a.mode, a.inPort, a.outPort) < (b.channel, b.note, b.mode, b.inPort, b.outPort)
    }
}

struct DeckProfile: Equatable, Identifiable {
    let uuid: String                // the folder's UUID, lowercased, as the preferences write it
    let name: String
    let device: String              // "@(1)[4057/143/<serial>]"
    let model: String
    let pages: Int
    let keys: [DeckMIDIKey]         // every MIDI key with a channel and a note
    let pluginVersions: [String]    // every MIDI plugin version its keys were made with, sorted
    /// The MIDI keys whose title says Blackout (1.30, for the shutdown's Blackout). Not in the signature.
    var blackoutKeys: [DeckMIDIKey] = []
    var id: String { uuid }
    var signatureKeys: [DeckMIDIKey] { Array(Set(keys)).sorted() }
    var signature: String { signatureKeys.map(\.text).joined(separator: ";") }
    var sigHash: String { String(SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined().prefix(10)) }
    var channels: [Int] { Array(Set(keys.map(\.channel))).sorted() }
    var inPorts: [String] { Array(Set(keys.map(\.inPort))).sorted() }
    var outPorts: [String] { Array(Set(keys.map(\.outPort))).sorted() }
}

private func settingInt(_ v: Any?) -> Int? {
    if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
    if let n = v as? NSNumber, !(v is Bool) { return n.intValue }
    return nil
}

/// A key's MIDI side, or nil when it isn't a MIDI plugin key with a channel and a note. `version`:
/// the plugin version it was made with, for any MIDI plugin key.
func deckMIDIKey(_ action: [String: Any]) -> (key: DeckMIDIKey?, version: String?)? {
    let plugin = action["Plugin"] as? [String: Any]
    let isMIDI = plugin?["UUID"] as? String == trevligaPlugin || (action["UUID"] as? String)?.hasPrefix(trevligaPlugin + ".") == true
    guard isMIDI else { return nil }
    let version = plugin?["Version"] as? String
    guard let s = action["Settings"] as? [String: Any], let ch = settingInt(s["g47"]), let note = settingInt(s["g45"]) else {
        return (nil, version)
    }
    return (DeckMIDIKey(channel: ch + 1, note: note, mode: s["g02"] as? String ?? "?",
                        inPort: s["smi"] as? String ?? "", outPort: s["smo"] as? String ?? ""), version)
}

/// One profile from its manifest and its pages' manifests; nil when they aren't the shape above.
func parseDeckProfile(uuid: String, manifest: Data, pages: [Data]) -> DeckProfile? {
    guard let m = (try? JSONSerialization.jsonObject(with: manifest)) as? [String: Any],
          let name = m["Name"] as? String,
          let device = m["Device"] as? [String: Any], let deviceID = device["UUID"] as? String else { return nil }
    var keys: [DeckMIDIKey] = [], blackout: [DeckMIDIKey] = [], versions = Set<String>()
    for page in pages {
        guard let p = (try? JSONSerialization.jsonObject(with: page)) as? [String: Any] else { return nil }
        guard let controllers = p["Controllers"] else { return nil }
        if controllers is NSNull { continue }                       // an empty page
        guard let list = controllers as? [[String: Any]] else { return nil }
        for c in list {
            guard let actions = c["Actions"], !(actions is NSNull) else { continue }
            guard let byPos = actions as? [String: Any] else { return nil }
            for pos in byPos.keys.sorted() {
                guard let a = byPos[pos] as? [String: Any], let midi = deckMIDIKey(a) else { continue }
                if let v = midi.version { versions.insert(v) }
                if let k = midi.key {
                    keys.append(k)
                    let titles = (a["States"] as? [[String: Any]] ?? []).compactMap { $0["Title"] as? String }
                    if titles.contains(where: isBlackoutTitle) { blackout.append(k) }
                }
            }
        }
    }
    return DeckProfile(uuid: uuid.lowercased(), name: name, device: deviceID, model: device["Model"] as? String ?? "",
                       pages: pages.count, keys: keys, pluginVersions: versions.sorted(), blackoutKeys: blackout)
}

struct DeckProfilesRead: Equatable {
    var profiles: [DeckProfile] = []
    var folder: String?             // ProfilesV3 (or ProfilesV2) that was read
    var unreadable: [String] = []   // profile folders that weren't the expected shape
    var problem: String?            // nothing could be read: the row says "can't tell"
}

/// Every profile in Stream Deck's support folder: ProfilesV3, or ProfilesV2 for an older Stream Deck
/// (read only if its files have the same shape; otherwise that's "can't read", not a failure).
func readDeckProfiles(supportDir: String = streamDeckSupportDir) -> DeckProfilesRead {
    let fm = FileManager.default
    var r = DeckProfilesRead()
    guard let folder = ["ProfilesV3", "ProfilesV2"].map({ supportDir + "/" + $0 }).first(where: { fm.fileExists(atPath: $0) }) else {
        r.problem = "Stream Deck has no profiles folder here (ProfilesV3 or ProfilesV2)."
        return r
    }
    r.folder = folder
    let names = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".sdProfile") }.sorted()
    for n in names {
        let dir = folder + "/" + n
        let pagesDir = dir + "/Profiles"
        let pages = ((try? fm.contentsOfDirectory(atPath: pagesDir)) ?? []).sorted()
            .compactMap { fm.contents(atPath: pagesDir + "/" + $0 + "/manifest.json") }
        guard let manifest = fm.contents(atPath: dir + "/manifest.json"),
              let p = parseDeckProfile(uuid: String(n.dropLast(".sdProfile".count)), manifest: manifest, pages: pages) else {
            r.unreadable.append(n)
            continue
        }
        r.profiles.append(p)
    }
    if r.profiles.isEmpty && !r.unreadable.isEmpty {
        r.problem = "Can\u{2019}t read this Stream Deck version\u{2019}s profiles (\((folder as NSString).lastPathComponent))."
    }
    return r
}

/// The profile folder for a UUID, whatever its case (folders are upper case, preferences lower).
func deckProfileFolder(uuid: String, in folder: String?) -> String? {
    guard let folder else { return nil }
    let want = uuid.lowercased() + ".sdprofile"
    return ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
        .first { $0.lowercased() == want }.map { folder + "/" + $0 }
}

/// For the log: one line per profile.
func deckProfilesText(_ r: DeckProfilesRead) -> String {
    if let p = r.problem { return p }
    return r.profiles.map { p in
        "\u{201C}\(p.name)\u{201D} \(p.uuid): \(p.keys.count) MIDI keys, " + channelsText(p.channels)
            + ", in \(p.inPorts.joined(separator: "/")), out \(p.outPorts.joined(separator: "/")), plugin \(p.pluginVersions.joined(separator: "/")), keys \(p.sigHash), deck \(p.device)"
    }.joined(separator: "\n") + (r.unreadable.isEmpty ? "" : "\nCouldn\u{2019}t read: " + r.unreadable.joined(separator: ", "))
}

/// "channel 2", "channels 5–13", "channels 2, 5, 9", "no channels".
func channelsText(_ ch: [Int]) -> String {
    guard let first = ch.first, let last = ch.last else { return "no MIDI channels" }
    if ch.count == 1 { return "channel \(first)" }
    return ch == Array(first...last) ? "channels \(first)\u{2013}\(last)" : "channels " + ch.map(String.init).joined(separator: ", ")
}

/// The picker's hint for a profile: "Lightkey XL Service · 44 keys · channel 2". Two profiles that
/// share a name and a hint also get their keys' hash, or their UUID when even that's the same.
func deckProfileHint(_ p: DeckProfile, among all: [DeckProfile]) -> String {
    let base = { (q: DeckProfile) in "\(q.name) \u{00B7} \(q.keys.count) keys \u{00B7} \(channelsText(q.channels))" }
    let twins = all.filter { $0.uuid != p.uuid && base($0) == base(p) }
    if twins.isEmpty { return base(p) }
    return base(p) + (twins.contains { $0.sigHash == p.sigHash } ? " \u{00B7} id \(p.uuid.prefix(8))" : " \u{00B7} keys \(p.sigHash.prefix(6))")
}

/// The profile the tech chose in This Mac. Name, UUID and the keys' hash, so it's still found after a
/// re-import under a new UUID (see `matchDeckProfile`).
struct DeckProfileChoice: Codable, Equatable {
    var name: String
    var uuid: String
    var sigHash: String
    init(_ p: DeckProfile) { (name, uuid, sigHash) = (p.name, p.uuid, p.sigHash) }
    init(name: String, uuid: String, sigHash: String) { (self.name, self.uuid, self.sigHash) = (name, uuid, sigHash) }
}

enum DeckProfileMatch: Equatable {
    case found(DeckProfile, by: String)     // "uuid", "keys" or "name"
    case missing
    case ambiguous([DeckProfile])
}

/// Which installed profile is the chosen one: the same UUID; else the one with the same keys (the same
/// name breaks a tie); else the one with the same name. More than one left: can't tell.
func matchDeckProfile(_ c: DeckProfileChoice, in profiles: [DeckProfile]) -> DeckProfileMatch {
    if let p = profiles.first(where: { $0.uuid == c.uuid.lowercased() }) { return .found(p, by: "uuid") }
    let sameKeys = profiles.filter { $0.sigHash == c.sigHash }
    if sameKeys.count == 1 { return .found(sameKeys[0], by: "keys") }
    if sameKeys.count > 1 {
        let named = sameKeys.filter { $0.name == c.name }
        return named.count == 1 ? .found(named[0], by: "keys") : .ambiguous(named.isEmpty ? sameKeys : named)
    }
    let sameName = profiles.filter { $0.name == c.name }
    if sameName.count == 1 { return .found(sameName[0], by: "name") }
    return sameName.isEmpty ? .missing : .ambiguous(sameName)
}

/// Each deck's preferred profile from the preferences' Devices value (device ID → lowercased UUID).
/// Entries that aren't a deck dictionary (PreferredDevice is a string) are skipped.
func deckPreferredProfiles(_ devices: Any?) -> (preferred: [String: String], problem: String?) {
    guard let devices else { return ([:], "Stream Deck\u{2019}s settings have no Devices list yet.") }
    guard let d = devices as? [String: Any] else { return ([:], "Stream Deck\u{2019}s Devices setting isn\u{2019}t the shape Booth Check knows.") }
    var out: [String: String] = [:]
    for (k, v) in d {
        guard let dev = v as? [String: Any], let info = dev["ESDProfilesInfo"] as? [String: Any],
              let pref = info["ESDProfilesPreferred"] as? String else { continue }
        out[k] = pref.lowercased()
    }
    return (out, nil)
}

/// Whether Booth Check may write `target` as `device`'s preferred profile: only when the format is
/// exactly as expected (Devices → device → ESDProfilesInfo → ESDProfilesPreferred is a string), the
/// target is a UUID and its profile folder exists. `current`: the value there now.
func deckPrefsWriteGuard(devices: Any?, device: String, target: String, targetFolderExists: Bool) -> (ok: Bool, current: String?, why: String) {
    guard let d = devices as? [String: Any] else { return (false, nil, "Stream Deck\u{2019}s Devices setting is missing or not a dictionary.") }
    guard let dev = d[device] as? [String: Any] else { return (false, nil, "Stream Deck\u{2019}s settings have no entry for the deck \(device).") }
    guard let info = dev["ESDProfilesInfo"] as? [String: Any] else { return (false, nil, "The deck\u{2019}s entry has no ESDProfilesInfo dictionary.") }
    guard let current = info["ESDProfilesPreferred"] as? String else { return (false, nil, "ESDProfilesPreferred is missing or not text.") }
    guard UUID(uuidString: target) != nil else { return (false, current, "\u{201C}\(target)\u{201D} isn\u{2019}t a profile UUID.") }
    guard targetFolderExists else { return (false, current, "The profile \(target) isn\u{2019}t in Stream Deck\u{2019}s profiles folder.") }
    return (true, current, "The format is as expected.")
}

/// The Devices value with only `device`'s ESDProfilesPreferred changed; every other key kept as it
/// was. nil when the shape isn't the expected one.
func deckDevicesSetting(_ devices: [String: Any], device: String, preferred: String) -> [String: Any]? {
    guard var dev = devices[device] as? [String: Any], var info = dev["ESDProfilesInfo"] as? [String: Any],
          info["ESDProfilesPreferred"] is String else { return nil }
    info["ESDProfilesPreferred"] = preferred.lowercased()
    dev["ESDProfilesInfo"] = info
    var out = devices
    out[device] = dev
    return out
}

/// 4.3.0.1 >= 4.3: compares numerically, part by part.
func pluginVersionAtLeast(_ v: String, _ min: [Int]) -> Bool {
    let parts = v.split(separator: ".").map { Int($0) ?? 0 }
    for (i, m) in min.enumerated() {
        let p = i < parts.count ? parts[i] : 0
        if p != m { return p > m }
    }
    return true
}

/// The extra warnings for a profile, on the same row: keys that don't send to Lightkey, and mixed or
/// old MIDI plugin versions.
func deckProfileWarnings(_ p: DeckProfile) -> [String] {
    var w: [String] = []
    let stray = p.keys.filter { $0.outPort != IDs.lightkeyMIDIInput }
    if !stray.isEmpty {
        w.append("\(stray.count) of its \(p.keys.count) MIDI keys don\u{2019}t send to \u{201C}\(IDs.lightkeyMIDIInput)\u{201D} ("
                 + Array(Set(stray.map { $0.outPort.isEmpty ? "no port" : $0.outPort })).sorted().joined(separator: ", ") + "), so Lightkey won\u{2019}t hear them.")
    }
    if p.pluginVersions.count > 1 {
        w.append("Its keys were made with different MIDI plugin versions (\(p.pluginVersions.joined(separator: ", "))).")
    }
    let old = p.pluginVersions.filter { !pluginVersionAtLeast($0, [4, 3]) }
    if !old.isEmpty { w.append("Some keys were made with MIDI plugin \(old.joined(separator: ", ")), older than 4.3.") }
    return w
}

/// "Stream Deck is on the right profile". `writeFailed`: Booth Check's switch didn't stick, so the row
/// says how to choose it by hand instead of offering the switch again.
/// `disk`: the service profile's folder as checked on disk (`deckProfileHealth`) and its last-good copy;
/// broken or missing, the row offers the copy back (`repairFailed`: Booth Check's own restore didn't hold).
func deckProfileCheck(choice: DeckProfileChoice, read: DeckProfilesRead, preferred: [String: String], prefsProblem: String?,
                      writeFailed: Bool = false, disk: (uuid: String, health: DeckProfileHealth, copy: DeckCopyInfo?)? = nil,
                      repairFailed: Bool = false) -> Check {
    let title = "Stream Deck is on the right profile"
    let want = "\u{201C}\(choice.name)\u{201D}"
    func row(_ status: Status, _ detail: String, fix: String? = nil, action: Action? = nil) -> Check {
        Check(id: "deckProfile", group: "Stream Deck", title: title, status: status, detail: detail, fix: fix, action: action)
    }
    if let disk, disk.health.isBroken {
        let detail = "The service profile \(want) " + (disk.health == .missing ? "isn\u{2019}t in Stream Deck any more." : "is damaged: \(disk.health.why).")
            + (repairFailed ? " Booth Check put it back by itself, but it was damaged again after Stream Deck opened." : "")
        if let copy = disk.copy {
            return row(.fail, detail, fix: "Click Restore the Stream Deck\u{2019}s keys\u{2026} to put back Booth Check\u{2019}s copy from \(deckCopyDateText(copy.savedAt)) (Stream Deck closes for a few seconds).",
                       action: .restoreDeckProfile(uuid: disk.uuid, name: choice.name))
        }
        return row(.fail, detail + " Booth Check has no copy of it to put back yet.",
                   fix: "Import it again in Stream Deck (double-click its .streamDeckProfile file), or pick the profile for the service in This Mac.",
                   action: .openSetup)
    }
    if let problem = read.problem {
        return row(.unknown, "Can\u{2019}t tell which profile it\u{2019}s on: \(problem)", fix: "In Stream Deck, choose \(want) at the top of its window.")
    }
    let target: DeckProfile
    switch matchDeckProfile(choice, in: read.profiles) {
    case .missing:
        return row(.fail, "The service needs \(want), but it isn\u{2019}t in Stream Deck any more.",
                   fix: "Import it again in Stream Deck (double-click its .streamDeckProfile file), or pick the profile for the service in This Mac.",
                   action: .openSetup)
    case .ambiguous(let list):
        return row(.unknown, "\(list.count) profiles could be \(want) (" + list.map { deckProfileHint($0, among: read.profiles) }.joined(separator: "; ") + "), so Booth Check can\u{2019}t tell which one the service needs.",
                   fix: "Pick it again in This Mac.", action: .openSetup)
    case .found(let p, _):
        target = p
    }
    var extras = deckProfileWarnings(target)
    let edited = target.sigHash != choice.sigHash
    if edited { extras.insert("Its keys changed since it was chosen (it was edited, or another version was imported).", at: 0) }
    let extraText = extras.isEmpty ? "" : " " + extras.joined(separator: " ")
    guard prefsProblem == nil, let current = preferred[target.device] else {
        return row(.unknown, "Can\u{2019}t tell which profile Stream Deck is on: " + (prefsProblem ?? "its settings don\u{2019}t list the deck this profile is for.") + extraText,
                   fix: "In Stream Deck, choose \(want) at the top of its window.")
    }
    let onIt = current == target.uuid
    let copy = onIt ? nil : read.profiles.first(where: { $0.uuid == current && $0.sigHash == target.sigHash })
    if onIt || copy != nil {
        let detail = "It\u{2019}s on \(want)" + (copy != nil ? " (a copy with the same keys)" : "") + ", \(target.keys.count) MIDI keys, \(channelsText(target.channels))." + extraText
        if edited {
            return row(.warn, detail, fix: "If the change was meant, keep it as it is now; otherwise import the right version in Stream Deck.",
                       action: .acceptDeckProfile)
        }
        return row(extras.isEmpty ? .ok : .warn, detail)
    }
    let currentName = read.profiles.first { $0.uuid == current }.map { "\u{201C}\($0.name)\u{201D}" } ?? "a profile Booth Check can\u{2019}t find"
    let detail = "Stream Deck is on \(currentName), the service needs \(want), so the keys may not match the show." + extraText
    if writeFailed {
        return row(.fail, detail, fix: "In Stream Deck, choose \(want) at the top of its window.")
    }
    return row(.fail, detail, fix: "Booth Check can switch it: Stream Deck closes for a few seconds and its keys go dark meanwhile.",
               action: .switchDeckProfile(device: target.device, to: target.uuid, from: current, name: target.name))
}

/// Whether to open Stream Deck now, outside the start-up (the user, 9 Oct 2026: switched on in This
/// Mac, it didn't open). Switched on, installed and not running; not while a start-up or a shutdown
/// is opening or closing apps; on a Lightkey Mac only once Lightkey's MIDI input exists, since the
/// plugin looks for it when it starts; and at most once a minute, so a crashing app isn't hammered.
func shouldOpenStreamDeck(enabled: Bool, installed: Bool, running: Bool, busy: Bool,
                          needsLightkey: Bool, lightkeyReady: Bool, sinceLast: TimeInterval) -> Bool {
    enabled && installed && !running && !busy && (!needsLightkey || lightkeyReady) && sinceLast >= 60
}

/// Whether Booth Check is busy with Stream Deck itself, so the 15-second checks leave it closed: a
/// start-up, the shutdown, or a restart or profile switch that closed it on purpose.
func streamDeckBusy(starting: Bool, shuttingDown: Bool, closedOnPurpose: Bool) -> Bool {
    starting || shuttingDown || closedOnPurpose
}

/// Whether to restart a running Stream Deck so its keys start clean. A latch key (a colour, a house
/// level) lights when Lightkey says a cue is on but ignores "off", so a key left lit stays lit after
/// Lightkey restarts (church Mac, 9 Oct 2026: Lavender lit, Lightkey fresh). So: when the start-up
/// reaches Stream Deck and it's already running, and when Lightkey starts outside a start-up.
/// A restart alone isn't enough: Stream Deck 7 saves each key's state (`"State": 1`) in the profile's
/// page manifests, and a key saved lit comes up lit (church Mac, 15 Nov 2026, at boot). So while it's
/// closed, Booth Check also resets the MIDI keys' saved state (`clearDeckPageStates`, Nov 2026).
func shouldRestartStreamDeck(enabled: Bool, deckRunning: Bool, startUpDeckStep: Bool,
                             lightkeyJustLaunched: Bool, busy: Bool) -> Bool {
    guard enabled && deckRunning else { return false }
    return startUpDeckStep || (lightkeyJustLaunched && !busy)
}

// MARK: Stream Deck's saved key lights (15 Nov 2026)
//
// Each page's manifest.json keeps, per action, "State" (the state it shows, 0 = the first) next to its
// "States" array. A Trevliga MIDI key has two states, and Stream Deck saves the lit one (1) as it was
// when it last ran, so the key comes up lit before Lightkey has said anything. Booth Check sets those
// back to 0, only while Stream Deck is closed, by replacing just the digits of each such "State" value
// in the file's bytes: everything else stays byte for byte as Stream Deck wrote it. The edit is then
// proven by parsing the result and comparing it with the original, with only those States changed.

/// One key whose saved state was (or would be) reset: its position ("col,row"), title and old state.
struct DeckKeyReset: Equatable {
    let position: String
    let title: String
    let from: Int
}

/// Where each `Controllers[c].Actions[pos].State` value sits in a page manifest's bytes. Only that exact
/// path counts (a "State" deeper down, in a multi-action's settings, is left alone). nil when the bytes
/// aren't JSON this simple scanner follows, or an action has "State" twice.
func deckStateValueRanges(_ bytes: [UInt8]) -> [(controller: Int, position: String, range: Range<Int>)]? {
    enum Step: Equatable { case key(String), index(Int) }
    var i = 0
    var found: [(controller: Int, position: String, range: Range<Int>)] = []
    func ws() { while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 } }
    func string() -> String? {
        guard i < bytes.count, bytes[i] == 0x22 else { return nil }
        let start = i
        i += 1
        while i < bytes.count {
            if bytes[i] == 0x5C { i += 2; continue }            // backslash: skip the escaped byte
            if bytes[i] == 0x22 { i += 1; break }
            i += 1
        }
        guard i <= bytes.count, bytes[i - 1] == 0x22, i - start >= 2 else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(bytes[start..<i]), options: .fragmentsAllowed)) as? String
    }
    func value(_ path: [Step], depth: Int) -> Bool {
        guard depth < 64 else { return false }
        ws()
        guard i < bytes.count else { return false }
        let start = i
        switch bytes[i] {
        case 0x7B:                                              // {
            i += 1; ws()
            if i < bytes.count, bytes[i] == 0x7D { i += 1; return true }
            while true {
                ws()
                guard let k = string() else { return false }
                ws()
                guard i < bytes.count, bytes[i] == 0x3A else { return false }
                i += 1
                guard value(path + [.key(k)], depth: depth + 1) else { return false }
                ws()
                guard i < bytes.count else { return false }
                if bytes[i] == 0x2C { i += 1; continue }
                if bytes[i] == 0x7D { i += 1; return true }
                return false
            }
        case 0x5B:                                              // [
            i += 1; ws()
            if i < bytes.count, bytes[i] == 0x5D { i += 1; return true }
            var n = 0
            while true {
                guard value(path + [.index(n)], depth: depth + 1) else { return false }
                n += 1
                ws()
                guard i < bytes.count else { return false }
                if bytes[i] == 0x2C { i += 1; continue }
                if bytes[i] == 0x5D { i += 1; return true }
                return false
            }
        default:                                                // string, number, true, false, null
            if bytes[i] == 0x22 {
                guard string() != nil else { return false }
            } else {
                while i < bytes.count, !([0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D].contains(bytes[i])) { i += 1 }
                guard i > start else { return false }
            }
            if path.count == 5, path[0] == .key("Controllers"), case .index(let c) = path[1], path[2] == .key("Actions"),
               case .key(let pos) = path[3], path[4] == .key("State") {
                found.append((c, pos, start..<i))
            }
            return true
        }
    }
    guard value([], depth: 0) else { return nil }
    ws()
    guard i == bytes.count else { return nil }
    // A key with "State" twice: which one Stream Deck reads is anyone's guess, so don't edit.
    guard Set(found.map { "\($0.controller)/\($0.position)" }).count == found.count else { return nil }
    return found
}

/// What resetting one page's saved key lights would do. `data`: the new file, nil when nothing needs
/// changing or something was unexpected (`problem` says what; the page is then left alone).
struct DeckPageClear {
    var data: Data?
    var resets: [DeckKeyReset] = []
    var problem: String?
}

/// For one page manifest: every MIDI plugin key (`deckMIDIKey`) with two or more states whose saved
/// State isn't 0 gets State 0. Text keys, page keys and keys already at 0 aren't touched. The result
/// is proven: it parses, and it equals the original parsed with only those States set to 0 (compared
/// through JSONSerialization with sorted keys, so a number turned into a bool or a lost null shows).
func clearDeckPageStates(_ input: Data) -> DeckPageClear {
    guard let parsed = (try? JSONSerialization.jsonObject(with: input, options: [.mutableContainers])) as? NSMutableDictionary else {
        return DeckPageClear(problem: "isn\u{2019}t a JSON object")
    }
    let bytes = [UInt8](input)
    guard let ranges = deckStateValueRanges(bytes) else { return DeckPageClear(problem: "isn\u{2019}t JSON in the shape Booth Check can edit safely") }
    var resets: [DeckKeyReset] = []
    var edits: [Range<Int>] = []
    for r in ranges {
        guard let controllers = parsed["Controllers"] as? NSArray, r.controller < controllers.count,
              let actions = (controllers[r.controller] as? NSDictionary)?["Actions"] as? NSMutableDictionary,
              let action = actions[r.position] as? NSMutableDictionary else {
            return DeckPageClear(problem: "the scan and the parse disagree about key \(r.position)")
        }
        guard deckMIDIKey(action as? [String: Any] ?? [:]) != nil, let states = action["States"] as? NSArray, states.count >= 2 else { continue }
        let token = bytes[r.range]
        // The digits in the file are the proof it's a number, not true/false (NSNumber can't tell).
        guard let state = action["State"] as? NSNumber, !token.isEmpty, token.allSatisfy({ (0x30...0x39).contains($0) }), Int(String(decoding: token, as: UTF8.self)) == state.intValue else {
            return DeckPageClear(problem: "key \(r.position)\u{2019}s State isn\u{2019}t a plain whole number")
        }
        guard state.intValue != 0 else { continue }
        let titles = states.compactMap { ($0 as? NSDictionary)?["Title"] as? String }
        let pick = state.intValue < titles.count && !titles[state.intValue].isEmpty ? titles[state.intValue] : titles.first { !$0.isEmpty } ?? ""
        let title = pick.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        resets.append(DeckKeyReset(position: r.position, title: title.isEmpty ? "(no title)" : title, from: state.intValue))
        edits.append(r.range)
        action["State"] = NSNumber(value: 0)
    }
    guard !edits.isEmpty else { return DeckPageClear() }
    var out = bytes
    for r in edits.sorted(by: { $0.lowerBound > $1.lowerBound }) { out.replaceSubrange(r, with: [0x30]) }
    let data = Data(out)
    guard let reparsed = try? JSONSerialization.jsonObject(with: data),
          let a = try? JSONSerialization.data(withJSONObject: reparsed, options: [.sortedKeys]),
          let b = try? JSONSerialization.data(withJSONObject: parsed, options: [.sortedKeys]), a == b else {
        return DeckPageClear(problem: "the edited file didn\u{2019}t check out, so it was left as it was")
    }
    return DeckPageClear(data: data, resets: resets.sorted { $0.position < $1.position })
}

/// One page's outcome, for the log.
struct DeckPageClearResult: Equatable {
    let page: String            // the page folder's name
    var resets: [DeckKeyReset] = []
    var written = false
    var skipped: String?        // why it was left alone; nil when it was written or needed nothing
}

/// Resets the saved key lights on every page of one profile folder (`clearDeckPageStates`). Each page
/// that changes is written atomically, with its permissions kept. The backup is the whole profile's
/// last-good copy (`snapshotDeckProfile`), which the caller makes first: Booth Check doesn't reset a
/// profile it has no copy of as it is now. Before each write it checks `deckRunning` (Stream Deck would
/// write its own copy back) and that the file is still what was read. Anything unexpected leaves that
/// page as it was and says why.
func clearDeckKeyStates(profileDir: String, deckRunning: () -> Bool) -> [DeckPageClearResult] {
    let fm = FileManager.default
    let pagesDir = profileDir + "/Profiles"
    let pages = ((try? fm.contentsOfDirectory(atPath: pagesDir)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    var results: [DeckPageClearResult] = []
    for page in pages {
        let path = pagesDir + "/" + page + "/manifest.json"
        var r = DeckPageClearResult(page: page)
        guard let original = fm.contents(atPath: path) else {
            if fm.fileExists(atPath: pagesDir + "/" + page + "/manifest.json") { r.skipped = "couldn\u{2019}t read its manifest.json" ; results.append(r) }
            continue
        }
        let plan = clearDeckPageStates(original)
        r.resets = plan.resets
        if let p = plan.problem { r.skipped = p; results.append(r); continue }
        guard let new = plan.data else { results.append(r); continue }
        if deckRunning() { r.skipped = "Stream Deck is running"; results.append(r); continue }
        guard fm.contents(atPath: path) == original else { r.skipped = "the file changed while Booth Check read it"; results.append(r); continue }
        if deckRunning() { r.skipped = "Stream Deck started"; results.append(r); continue }
        let perms = (try? fm.attributesOfItem(atPath: path))?[.posixPermissions]
        do {
            try new.write(to: URL(fileURLWithPath: path), options: .atomic)
            if let perms { try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: path) }
        } catch {
            r.skipped = "couldn\u{2019}t write it (\(error.localizedDescription))"; results.append(r); continue
        }
        if fm.contents(atPath: path) == new {
            r.written = true
        } else {
            r.skipped = "it didn\u{2019}t read back as written (the last-good copy has it as it was)"
        }
        results.append(r)
    }
    return results
}

/// Which profiles to reset at a start-up: the one chosen in This Mac (when it's clearly one installed
/// profile) and each deck's preferred profile, the one it will show, once each. With a profile chosen
/// and the switch made, they're the same; when the switch couldn't be made, the deck shows the
/// preferred one, so that's cleared too. `missing`: preferred UUIDs with no profile folder.
func deckProfilesToClear(choice: DeckProfileChoice?, read: DeckProfilesRead, preferred: [String: String]) -> (profiles: [DeckProfile], missing: [String]) {
    var out: [DeckProfile] = []
    if let choice, case .found(let p, _) = matchDeckProfile(choice, in: read.profiles) { out.append(p) }
    var missing: [String] = []
    for uuid in Set(preferred.values).sorted() {
        if let p = read.profiles.first(where: { $0.uuid == uuid }) {
            if !out.contains(where: { $0.uuid == p.uuid }) { out.append(p) }
        } else {
            missing.append(uuid)
        }
    }
    return (out, missing)
}

/// The log's text for one profile's reset.
func deckClearText(profile: DeckProfile, results: [DeckPageClearResult], backupFolder: String) -> String {
    let changed = results.filter(\.written)
    let n = changed.reduce(0) { $0 + $1.resets.count }
    var lines = ["\u{201C}\(profile.name)\u{201D} (\(profile.uuid)), \(results.count) page\(results.count == 1 ? "" : "s") read: "
                 + (n == 0 ? "no MIDI key had a lit state saved" : "\(n) key\(n == 1 ? "" : "s") reset to dark on \(changed.count) page\(changed.count == 1 ? "" : "s")") + "."]
    for r in results {
        if r.written {
            lines.append("  Page \(r.page): " + r.resets.map { "\($0.title) (\($0.position), was \($0.from))" }.joined(separator: ", "))
        } else if let why = r.skipped {
            lines.append("  Page \(r.page): left as it was: \(why)."
                         + (r.resets.isEmpty ? "" : " It has \(r.resets.count) key\(r.resets.count == 1 ? "" : "s") saved lit: " + r.resets.map(\.title).joined(separator: ", ") + "."))
        }
    }
    if !changed.isEmpty { lines.append("  The profile as it was is in Booth Check\u{2019}s last-good copy: \(backupFolder)") }
    return lines.joined(separator: "\n")
}

// MARK: Stream Deck profile: last-good copy and self-repair (Nov 2026)
//
// The owner: "the app should mend itself". Whenever Booth Check has Stream Deck closed (the start-up,
// the restart after Lightkey starts), it keeps a complete copy of each profile it looks after, as long
// as that profile is healthy on disk, and puts the copy back if the profile is objectively broken
// (gone, a file missing or not JSON, a page folder gone, no MIDI keys left when the copy had some).
// A healthy profile is never "repaired": an edit the tech made becomes the new last-good copy instead.
// JSON in a shape Booth Check doesn't know (a new Stream Deck version) is never touched. While Stream
// Deck runs, nothing is written; mid-service the row offers the restore instead.
//
// Stream Deck's own guard (tested on the dev Mac, 15 Nov 2026, Stream Deck 7.6): at launch, after a
// clean last session, it compares its action count with the last session's, and when it's lower (a
// page manifest that isn't JSON, a profile folder gone) it puts up "Stream Deck detected an error
// restoring the last session… restore the backup from today?" and does nothing until someone answers.
// Putting a broken profile back BEFORE Stream Deck opens is what keeps that question away; the key
// reset (State digits only) and swapping in an identical folder don't raise it. Booth Check never
// removes a profile. Its daily backups (BackupV3/*.streamDeckProfilesBackup, all profiles at once,
// only at the first launch of a day after a clean quit) are what its Restore button uses.
//
// One scheme, in `~/Library/Application Support/Booth Check/deck-backups/<profile uuid>/`:
//   good/<UUID>.sdProfile, good.json         the last good copy and what it is (one copy; Stream
//                                            Deck's daily backups are the history)
//   set-aside/<yyyy-MM-dd HHmmss>/<UUID>.sdProfile  what a restore replaced (the newest 3; older ones go to the Trash)

/// What a profile folder on disk looks like.
enum DeckProfileHealth: Equatable {
    case healthy(DeckProfile)
    case missing                    // its folder isn't there
    case broken(String)             // objectively damaged; the reason, in plain words
    case unknownShape(String)       // JSON, but not the shape Booth Check knows: never repaired
    var isBroken: Bool {
        switch self { case .missing, .broken: return true; default: return false }
    }
    var why: String {
        switch self {
        case .healthy: return "it\u{2019}s healthy"
        case .missing: return "its folder is gone"
        case .broken(let w), .unknownShape(let w): return w
        }
    }
}

/// Checks one `.sdProfile` folder: its manifest is JSON with Name, Device and Pages; every page it lists
/// (and its Default page) has a folder with a manifest that's JSON; every other page manifest there is
/// JSON too; it parses as a profile (`parseDeckProfile`). `expectKeys`: its last-good copy had MIDI
/// keys, so a profile with none left counts as broken. Reads only.
func deckProfileHealth(dir: String, expectKeys: Bool) -> DeckProfileHealth {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return .missing }
    guard let manifest = fm.contents(atPath: dir + "/manifest.json") else { return .broken("its manifest.json is missing") }
    guard let m = (try? JSONSerialization.jsonObject(with: manifest)) as? [String: Any] else {
        return .broken("its manifest.json can\u{2019}t be read (it isn\u{2019}t JSON)")
    }
    guard let pagesInfo = m["Pages"] as? [String: Any], let listed = pagesInfo["Pages"] as? [String] else {
        return .unknownShape("its manifest.json has no Pages list Booth Check knows")
    }
    let pagesDir = dir + "/Profiles"
    let folders = ((try? fm.contentsOfDirectory(atPath: pagesDir)) ?? []).filter { !$0.hasPrefix(".") }
    var wanted = listed
    if let d = pagesInfo["Default"] as? String, !wanted.contains(where: { $0.lowercased() == d.lowercased() }) { wanted.append(d) }
    if wanted.isEmpty { return .broken("it has no pages") }
    for id in wanted where !folders.contains(where: { $0.lowercased() == id.lowercased() }) {
        return .broken("its page \(id.uppercased().prefix(8)) is missing")
    }
    var pages: [Data] = []
    for f in folders.sorted() {
        let path = pagesDir + "/" + f + "/manifest.json"
        let isListed = wanted.contains { $0.lowercased() == f.lowercased() }
        guard let data = fm.contents(atPath: path) else {
            if isListed { return .broken("its page \(f.prefix(8)) has no manifest.json") }
            continue
        }
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            return .broken("its page \(f.prefix(8))\u{2019}s manifest.json can\u{2019}t be read (it isn\u{2019}t JSON)")
        }
        pages.append(data)
    }
    let name = (dir as NSString).lastPathComponent
    guard name.lowercased().hasSuffix(".sdprofile"),
          let p = parseDeckProfile(uuid: String(name.dropLast(".sdProfile".count)), manifest: manifest, pages: pages) else {
        return .unknownShape("its files aren\u{2019}t the shape Booth Check knows")
    }
    if expectKeys && p.keys.isEmpty { return .broken("it has no MIDI keys left") }
    return .healthy(p)
}

/// Every regular file under `dir`, as sorted paths relative to it (`.DS_Store` left out).
func deckTreeFiles(_ dir: String) -> [String]? {
    let fm = FileManager.default
    guard let e = fm.enumerator(atPath: dir) else { return nil }
    var out: [String] = []
    while let rel = e.nextObject() as? String {
        if (rel as NSString).lastPathComponent == ".DS_Store" { continue }
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dir + "/" + rel, isDirectory: &isDir), !isDir.boolValue { out.append(rel) }
    }
    return out.sorted()
}

/// A profile folder's content hash: every file's path and bytes, with each page manifest's saved key
/// lights counted as dark (`clearDeckPageStates`), so the reset alone isn't a change. Nil if unreadable.
func deckProfileContentHash(dir: String) -> (hash: String, bytes: Int, files: Int)? {
    guard let files = deckTreeFiles(dir) else { return nil }
    var h = SHA256()
    var bytes = 0
    for rel in files {
        guard var data = FileManager.default.contents(atPath: dir + "/" + rel) else { return nil }
        let parts = rel.split(separator: "/")
        if parts.count == 3, parts[0] == "Profiles", parts[2] == "manifest.json", let dark = clearDeckPageStates(data).data { data = dark }
        bytes += data.count
        h.update(data: Data(rel.utf8 + [0]))
        h.update(data: Data(String(data.count).utf8 + [0]))
        h.update(data: data)
    }
    return (h.finalize().map { String(format: "%02x", $0) }.joined(), bytes, files.count)
}

/// Whether two folders hold exactly the same files, byte for byte.
func deckTreesIdentical(_ a: String, _ b: String) -> Bool {
    guard let fa = deckTreeFiles(a), let fb = deckTreeFiles(b), fa == fb else { return false }
    let fm = FileManager.default
    return fa.allSatisfy { rel in
        guard let x = fm.contents(atPath: a + "/" + rel), let y = fm.contents(atPath: b + "/" + rel) else { return false }
        return x == y
    }
}

/// What the kept copy is: written next to it as good.json.
struct DeckCopyInfo: Codable, Equatable {
    var uuid: String            // lowercased
    var name: String
    var folder: String          // the .sdProfile folder's own name, as Stream Deck spelled it
    var sigHash: String
    var hash: String            // `deckProfileContentHash`
    var keys: Int
    var pages: Int
    var bytes: Int
    var savedAt: Date
}

/// Where a profile's copy lives.
struct DeckCopyStore {
    let root: String            // …/Booth Check/deck-backups
    let uuid: String
    var dir: String { root + "/" + uuid.lowercased() }
    var goodDir: String { dir + "/good" }
    var goodInfo: String { dir + "/good.json" }
    var setAside: String { dir + "/set-aside" }

    /// The copy, when both its info and its folder are there.
    var good: DeckCopyInfo? {
        guard let data = FileManager.default.contents(atPath: goodInfo) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let c = try? d.decode(DeckCopyInfo.self, from: data),
              FileManager.default.fileExists(atPath: goodDir + "/" + c.folder + "/manifest.json") else { return nil }
        return c
    }
    var goodFolder: String? { good.map { goodDir + "/" + $0.folder } }
}

func writeDeckCopyInfo(_ c: DeckCopyInfo, to path: String) -> Bool {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? e.encode(c) else { return false }
    return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
}

/// The log's line for a snapshot.
func deckSnapshotText(name: String, _ r: DeckSnapshotResult, store: DeckCopyStore) -> String {
    switch r {
    case .unchanged(let c):
        return "\u{201C}\(name)\u{201D}: healthy, unchanged since Booth Check\u{2019}s copy from \(deckCopyDateText(c.savedAt)) (\(store.goodDir)); no new copy."
    case .saved(let c, let old):
        return "\u{201C}\(name)\u{201D}: healthy" + (old == nil ? "; Booth Check\u{2019}s first copy of it" : ", changed since the copy from \(deckCopyDateText(old!.savedAt)); a new copy replaces it")
            + " (\(c.pages) pages, \(c.keys) MIDI keys, \(c.bytes / 1024) KB) in \(store.goodDir)."
    case .skipped(let why):
        return "\u{201C}\(name)\u{201D}: no new copy: \(why)."
    }
}

/// "15 Nov, 09:12": when a copy was made, for the row.
func deckCopyDateText(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_GB")
    f.dateFormat = "d MMM, HH:mm"
    return f.string(from: d)
}

enum DeckSnapshotResult: Equatable {
    case unchanged(DeckCopyInfo)
    case saved(DeckCopyInfo, replaced: DeckCopyInfo?)
    case skipped(String)
    var copy: DeckCopyInfo? {
        switch self { case .unchanged(let c), .saved(let c, _): return c; case .skipped: return nil }
    }
}

/// Keeps a last-good copy of a healthy profile folder: nothing when its content hash is the copy's
/// (nothing changed), else a fresh copy, checked (healthy, same hash) before it replaces the old one.
/// A healthy profile that changed (the tech edited it) simply becomes the new copy. Only reads Stream
/// Deck's files, and only while it's closed. Anything unexpected keeps the old copy as it was.
func snapshotDeckProfile(dir: String, store: DeckCopyStore, deckRunning: () -> Bool, now: Date = Date()) -> DeckSnapshotResult {
    let fm = FileManager.default
    if deckRunning() { return .skipped("Stream Deck is running") }
    let old = store.good
    let health = deckProfileHealth(dir: dir, expectKeys: (old?.keys ?? 0) > 0)
    guard case .healthy(let p) = health else { return .skipped("it isn\u{2019}t healthy (\(health.why))") }
    guard let h = deckProfileContentHash(dir: dir) else { return .skipped("its files couldn\u{2019}t all be read") }
    if let old, old.hash == h.hash { return .unchanged(old) }
    let folder = (dir as NSString).lastPathComponent
    let tmp = store.dir + "/incoming"
    try? fm.removeItem(atPath: tmp)                 // Booth Check's own half-made copy, if any
    do {
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        try fm.copyItem(atPath: dir, toPath: tmp + "/" + folder)
    } catch {
        try? fm.removeItem(atPath: tmp)
        return .skipped("the copy failed (\(error.localizedDescription))")
    }
    guard case .healthy = deckProfileHealth(dir: tmp + "/" + folder, expectKeys: false),
          deckProfileContentHash(dir: tmp + "/" + folder)?.hash == h.hash, !deckRunning() else {
        try? fm.removeItem(atPath: tmp)
        return .skipped("it changed while it was copied")
    }
    let info = DeckCopyInfo(uuid: p.uuid, name: p.name, folder: folder, sigHash: p.sigHash, hash: h.hash, keys: p.keys.count,
                            pages: p.pages, bytes: h.bytes, savedAt: now)
    // The new copy swaps places with the old one in one step, then the old one (Booth Check's own) goes.
    let swapped = fm.fileExists(atPath: store.goodDir)
        ? renamex_np(tmp, store.goodDir, UInt32(RENAME_SWAP)) == 0
        : rename(tmp, store.goodDir) == 0
    guard swapped, writeDeckCopyInfo(info, to: store.goodInfo) else {
        try? fm.removeItem(atPath: tmp)
        return .skipped("the copy couldn\u{2019}t be put in place")
    }
    try? fm.removeItem(atPath: tmp)
    return .saved(info, replaced: old)
}

struct DeckRestoreResult: Equatable {
    var ok = false
    var text: String
    var setAside: String?       // where the folder it replaced went
    var identical = false       // the profile is now byte for byte the copy
}

/// Puts a profile's last-good copy back, only while Stream Deck is closed: the copy goes into a hidden
/// folder next to the profile, is checked identical, then swaps places with it in one step
/// (`renamex_np` RENAME_SWAP; a plain rename when it's gone). What it replaced is moved aside into
/// Booth Check's folder, never deleted. Then the profile is re-checked against the copy.
func restoreDeckProfile(uuid: String, profilesFolder: String, store: DeckCopyStore, deckRunning: () -> Bool,
                        now: Date = Date()) -> DeckRestoreResult {
    let fm = FileManager.default
    guard let copy = store.good, let source = store.goodFolder else { return DeckRestoreResult(text: "Booth Check has no copy of it.") }
    if deckRunning() { return DeckRestoreResult(text: "Stream Deck is running, so nothing was changed.") }
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: profilesFolder, isDirectory: &isDir), isDir.boolValue else {
        return DeckRestoreResult(text: "Stream Deck\u{2019}s profiles folder isn\u{2019}t there (\(profilesFolder)), so nothing was changed.")
    }
    let target = deckProfileFolder(uuid: uuid, in: profilesFolder) ?? profilesFolder + "/" + copy.folder
    if deckTreesIdentical(target, source) {
        return DeckRestoreResult(ok: true, text: "It already matches the copy from \(deckCopyDateText(copy.savedAt)) byte for byte; nothing changed.", identical: true)
    }
    let tmp = profilesFolder + "/." + (target as NSString).lastPathComponent + ".boothcheck-restore"
    try? fm.removeItem(atPath: tmp)                 // Booth Check's own, from a restore that stopped half-way
    do { try fm.copyItem(atPath: source, toPath: tmp) } catch {
        try? fm.removeItem(atPath: tmp)
        return DeckRestoreResult(text: "Couldn\u{2019}t copy it next to the profile (\(error.localizedDescription)). Nothing was changed.")
    }
    guard deckTreesIdentical(tmp, source) else {
        try? fm.removeItem(atPath: tmp)
        return DeckRestoreResult(text: "The copy didn\u{2019}t come out identical, so nothing was changed.")
    }
    if deckRunning() {
        try? fm.removeItem(atPath: tmp)
        return DeckRestoreResult(text: "Stream Deck started, so nothing was changed.")
    }
    var r = DeckRestoreResult(text: "")
    if fm.fileExists(atPath: target) {
        guard renamex_np(tmp, target, UInt32(RENAME_SWAP)) == 0 else {
            let e = String(cString: strerror(errno))
            try? fm.removeItem(atPath: tmp)
            return DeckRestoreResult(text: "Couldn\u{2019}t swap it in (\(e)). Nothing was changed.")
        }
        // `tmp` now holds what was there: aside into Booth Check's folder.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        var aside = store.setAside + "/" + f.string(from: now)
        var n = 2
        while fm.fileExists(atPath: aside) { aside = store.setAside + "/" + f.string(from: now) + " \(n)"; n += 1 }
        do {
            try fm.createDirectory(atPath: aside, withIntermediateDirectories: true)
            try fm.moveItem(atPath: tmp, toPath: aside + "/" + (target as NSString).lastPathComponent)
            r.setAside = aside + "/" + (target as NSString).lastPathComponent
        } catch {
            r.setAside = tmp
        }
        pruneDeckSetAside(store.setAside, keep: 3)
    } else {
        guard rename(tmp, target) == 0 else {
            let e = String(cString: strerror(errno))
            try? fm.removeItem(atPath: tmp)
            return DeckRestoreResult(text: "Couldn\u{2019}t move it into place (\(e)). Nothing was changed.")
        }
    }
    r.identical = deckTreesIdentical(target, source)
    let health = deckProfileHealth(dir: target, expectKeys: copy.keys > 0)
    if case .healthy = health { r.ok = r.identical } else { r.ok = false }
    r.text = "Put back the copy from \(deckCopyDateText(copy.savedAt)) (\(copy.pages) pages, \(copy.keys) MIDI keys) into \(target)."
        + (r.identical ? " It now matches the copy byte for byte." : " It doesn\u{2019}t match the copy afterwards.")
        + (r.ok ? "" : " Re-check: \(health.why).")
        + (r.setAside.map { " What was there is kept in \($0)." } ?? "")
    return r
}

/// Keeps the newest `keep` set-aside folders; older ones go to the Trash (they came from Stream Deck's folder).
func pruneDeckSetAside(_ dir: String, keep: Int) {
    let fm = FileManager.default
    let names = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    for n in names.dropLast(keep) { try? fm.trashItem(at: URL(fileURLWithPath: dir + "/" + n), resultingItemURL: nil) }
}

var deckBackupsRoot: String { DiagFiles.standard.supportDir + "/deck-backups" }
var streamDeckLogPath: String { NSHomeDirectory() + "/Library/Logs/ElgatoStreamDeck/StreamDeck.log" }

/// Whether Stream Deck is stuck on its own launch question ("Stream Deck detected an error restoring the
/// last session… restore the backup from today?"): its current log proposed the restore and its event
/// loop hasn't started since (it only starts once someone answers; dev Mac, 15 Nov 2026).
func streamDeckAsksToRestore(log: String) -> Bool {
    guard let r = log.range(of: "propose restore backup to user", options: .backwards) else { return false }
    return !log[r.upperBound...].contains("Application event loop start")
}

/// One profile's folder (where it is, or where it would be), its health and its last-good copy.
func deckDiskState(uuid: String, read: DeckProfilesRead, root: String = deckBackupsRoot)
    -> (uuid: String, dir: String, health: DeckProfileHealth, copy: DeckCopyInfo?) {
    let store = DeckCopyStore(root: root, uuid: uuid)
    let copy = store.good
    let dir = deckProfileFolder(uuid: uuid, in: read.folder)
        ?? (read.folder ?? streamDeckSupportDir + "/ProfilesV3") + "/" + (copy?.folder ?? uuid.uppercased() + ".sdProfile")
    return (uuid.lowercased(), dir, deckProfileHealth(dir: dir, expectKeys: (copy?.keys ?? 0) > 0), copy)
}

/// Which profiles Booth Check looks after: the one chosen in This Mac (by `matchDeckProfile`; its own
/// UUID when it's missing, so its copy can come back; none when it's ambiguous), else each deck's
/// preferred profile that is there or has a copy (`hasCopy`).
func deckProfilesToMend(choice: DeckProfileChoice?, read: DeckProfilesRead, preferred: [String: String],
                        hasCopy: (String) -> Bool) -> [(uuid: String, name: String)] {
    if let choice {
        // Its own folder is there but can't be read: that's the one, even when another profile has the
        // same keys (dev Mac, 15 Nov 2026: a broken copy's keys matched another profile, which was
        // then taken for it). Matching by keys or name is for a re-import under a new UUID.
        let own = choice.uuid.lowercased()
        if deckProfileFolder(uuid: own, in: read.folder) != nil, !read.profiles.contains(where: { $0.uuid == own }) {
            return [(own, choice.name)]
        }
        switch matchDeckProfile(choice, in: read.profiles) {
        case .found(let p, _): return [(p.uuid, p.name)]
        case .missing: return [(choice.uuid.lowercased(), choice.name)]
        case .ambiguous: return []
        }
    }
    return Set(preferred.values).sorted().compactMap { uuid in
        let folder = deckProfileFolder(uuid: uuid, in: read.folder)
        guard folder != nil || hasCopy(uuid) else { return nil }
        return (uuid, read.profiles.first { $0.uuid == uuid }?.name ?? "the deck\u{2019}s profile")
    }
}

/// What to do for one profile, before Stream Deck opens.
enum DeckMendAction: Equatable {
    case keep                   // healthy: (copy it if it changed)
    case restore                // broken or missing, and there's a copy
    case noCopy                 // broken or missing, and no copy to put back
    case leave(String)          // don't touch it, and why
}

/// Automatic restores only while Stream Deck is closed, only for a profile that's objectively broken
/// or missing, at most `maxAutomatic` a session (the post-launch retry counts too). A person's
/// Restore… button (`automatic` false) is only held back by Stream Deck running.
func deckMendDecision(health: DeckProfileHealth, hasCopy: Bool, deckRunning: Bool, automatic: Bool,
                      restoresSoFar: Int, maxAutomatic: Int = 3) -> DeckMendAction {
    if deckRunning { return .leave("Stream Deck is running") }
    switch health {
    case .healthy: return .keep
    case .unknownShape(let w): return .leave("\(w), so Booth Check leaves it alone")
    case .missing, .broken:
        guard hasCopy else { return .noCopy }
        if automatic && restoresSoFar >= maxAutomatic {
            return .leave("Booth Check already put it back \(restoresSoFar) times this session, so it leaves it for a person")
        }
        return .restore
    }
}

/// After Stream Deck opens: one more automatic try (quit, restore, reopen) when the profile broke again,
/// never more (attempt 0 is the first launch).
func deckRelaunchRetryAllowed(attempt: Int, health: DeckProfileHealth, hasCopy: Bool) -> Bool {
    attempt == 0 && health.isBroken && hasCopy
}

/// The steps the Restore sheet shows.
func deckRestoreSteps(name: String, copy: DeckCopyInfo, profilesFolder: String, store: DeckCopyStore) -> String {
    """
    1. Quit Stream Deck (NSRunningApplication.terminate; made to quit after 5 s)
    2. With Stream Deck closed, put back Booth Check\u{2019}s copy of \u{201C}\(name)\u{201D} from \(deckCopyDateText(copy.savedAt)) (\(copy.pages) pages, \(copy.keys) MIDI keys):
       copy \(store.goodDir)/\(copy.folder)
         \u{2192} \(profilesFolder)/.\(copy.folder).boothcheck-restore, check it\u{2019}s identical
       renamex_np(RENAME_SWAP) it with \(profilesFolder)/\(copy.folder)
       move what was there to \(store.setAside)/<date and time>/\(copy.folder)
    3. Reset its saved key lights, then open Stream Deck in the background
    4. About 10 s later, check the profile is still healthy and Stream Deck is on it
    """
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
        + "If it lists its projects, click \(show ?? "the most recent one"). Can\u{2019}t see Lightkey? Click its icon in the Dock."
}

/// The password banner's title and words: plain when Lightkey's Authenticate alert is up (seen
/// through Accessibility), otherwise what it may ask for and how to find Lightkey.
func passwordSign(show: String?, asking: Bool) -> (title: String, text: String) {
    asking ? ("Lightkey is asking for the password",
              "Tap Authenticate on the Touch Bar (or click it on screen), then type the Mac\u{2019}s password. "
                + "Can\u{2019}t see it? Click Lightkey\u{2019}s icon in the Dock.")
           : ("Lightkey may need you", passwordSignText(show: show))
}

// MARK: - Shutting the booth down (pure parts)

/// When the booth next shuts down by itself: the first of `days` (Calendar weekdays, 1 = Sunday) at
/// `minute` minutes after midnight that's after `now`. Nil with no days.
func nextShutdown(after now: Date, days: Set<Int>, minute: Int, calendar: Calendar = .current) -> Date? {
    let today = calendar.startOfDay(for: now)
    for offset in 0...7 {
        guard let day = calendar.date(byAdding: .day, value: offset, to: today),
              days.contains(calendar.component(.weekday, from: day)),
              let time = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day),
              time > now else { continue }
        return time
    }
    return nil
}

enum ShutdownDue: Equatable { case notYet, now, missed }

/// Whether a shutdown set for `at` is due. Only within `grace` of the time: a Mac that was off or
/// asleep then mustn't shut down the moment it comes back, say for an evening event.
func shutdownDue(now: Date, at: Date, grace: TimeInterval = 30 * 60) -> ShutdownDue {
    now < at ? .notYet : now < at.addingTimeInterval(grace) ? .now : .missed
}

enum QuitNext: Equatable { case done, wait, force, giveUp }

/// While an app closes for the shutdown: done once it's gone. Still open after `forceAfter` seconds
/// (Stream Deck 5, Lightkey 15, by when its quit question has had Quit pressed, so it's probably
/// asking to save the show) it's made to quit, like Force Quit; still there 15 seconds after that,
/// give up and leave the Mac on. Nothing waits for a person any more (1.25: on the church Mac,
/// Lightkey asked "Are you sure you want to quit Lightkey?" and the Mac stayed on).
func quitNext(running: Bool, waited: TimeInterval, forceAfter: TimeInterval) -> QuitNext {
    if !running { return .done }
    return waited < forceAfter ? .wait : waited < forceAfter + 15 ? .force : .giveUp
}

/// Which button to press on a sheet or dialog while Lightkey closes for the shutdown: Quit, and only
/// on Lightkey's own "Are you sure you want to quit Lightkey?" (`message`). Never Save, Don't Save or
/// Cancel, and nothing at all on any other question. `texts` and `buttons` are what the sheet shows.
func quitButton(texts: [String], buttons: [String], message: String, quit: String) -> Int? {
    guard texts.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == message }) else { return nil }
    return buttons.firstIndex(of: quit)
}

/// Lightkey's own words for its quit question and its Quit button, read from Lightkey in the Mac's
/// language; English if they can't be read. Lightkey 6 asks only in Live mode, when it's the front
/// app (read from its code, 17 Oct 2026), which is how the booth runs it.
func lightkeyQuitWords(_ app: URL?) -> (message: String, quit: String) {
    let bundle = app.flatMap { Bundle(url: $0) }
    func word(_ key: String, _ english: String) -> String {
        guard let w = bundle?.localizedString(forKey: key, value: nil, table: nil), w != key, !w.isEmpty else { return english }
        return w
    }
    return (word("QuitConfirmationAlert-MessageText", "Are you sure you want to quit Lightkey?"),
            word("QuitConfirmationAlert-QuitButton", "Quit"))
}

/// The name Booth Check's keep-the-screen-on request has in `pmset -g assertions`.
let screenAssertionName = "Booth Check keeps the booth screen on"

/// Whether Booth Check should keep the screen on: Stays on for services switched on, and on the
/// charger. On battery (say a power cut) the screen may turn off as usual.
func keepsScreenOn(alwaysOn: Bool, onAC: Bool) -> Bool { alwaysOn && onAC }

/// Whether `pmset -g assertions` lists Booth Check's keep-the-screen-on request.
func holdsScreenAssertion(_ output: String) -> Bool {
    output.split(separator: "\n").contains {
        $0.contains("PreventUserIdleDisplaySleep") && $0.contains("named: \"\(screenAssertionName)\"")
    }
}

/// The screen stays on: Booth Check's keep-the-screen-on request (`keepScreenOn`), as macOS lists it.
func screenCheck(held: Bool, onAC: Bool) -> Check {
    let title = "The screen stays on"
    if held {
        return Check(id: "screen", group: "Power & sleep", title: title, status: .ok,
                     detail: "Booth Check keeps the screen awake while it runs on the charger, so the screen saver and lock screen don\u{2019}t start.")
    }
    if !onAC {
        return Check(id: "screen", group: "Power & sleep", title: title, status: .warn,
                     detail: "On battery, Booth Check lets the screen turn off.", fix: "Plug in the charger.")
    }
    return Check(id: "screen", group: "Power & sleep", title: title, status: .fail,
                 detail: "macOS isn\u{2019}t keeping the screen awake for Booth Check, so the screen saver can start after a while untouched, and Stream Deck with it.",
                 fix: "Ask a tech: quit Booth Check (hold Option, click its menu bar icon, then Quit) and open it again.")
}

/// The shutdown warning's countdown: "4:59".
func countdownText(_ seconds: Int) -> String {
    "\(seconds / 60):" + String(format: "%02d", seconds % 60)
}

/// What started a shutdown: the menu button, the set time each week, or the power going off.
enum ShutdownReason: Equatable { case button, timed, powerOff }

/// The shutdown's trigger as diagnostics name it: menu, weekly_time or power_off.
func shutdownTrigger(_ r: ShutdownReason) -> String {
    switch r { case .button: return "menu"; case .timed: return "weekly_time"; case .powerOff: return "power_off" }
}

/// Seconds of warning, with Not yet, before the booth shuts down.
func shutdownWarning(_ reason: ShutdownReason) -> Int {
    switch reason {
    case .button: return 10
    case .timed: return 5 * 60
    case .powerOff: return 60
    }
}

/// The countdown's words: why the booth is shutting down, and what happens.
func shutdownWhy(_ reason: ShutdownReason) -> String {
    switch reason {
    case .button: return "Stream Deck and Lightkey close, then the Mac shuts down. Leave everything plugged in."
    case .timed: return "It\u{2019}s the set time. Stream Deck and Lightkey close, then the Mac shuts down."
    case .powerOff: return "The power went off. Stream Deck and Lightkey close, then the Mac shuts down. Plug it back in to stop this."
    }
}

enum PowerNext: Equatable { case nothing, warn, powerBack }

/// What to do about the charger's power (the user asked for it, 9 Oct 2026: power off at the wall
/// shuts the booth down, as power on starts it). `outage` means the power went off while Booth Check
/// was running: a Mac started on battery on purpose is left alone. One warning per power cut, and
/// none while a start-up or another shutdown is under way (it comes once that's done).
func powerNext(enabled: Bool, onAC: Bool, outage: Bool, handled: Bool, busy: Bool) -> PowerNext {
    if onAC { return .powerBack }
    return enabled && outage && !handled && !busy ? .warn : .nothing
}

// MARK: - Blackout before the shutdown (1.30)

// The stage lights flickered as Lightkey and its DMX server stopped with the lights still on (the
// owner asked for this, optional, off by default). With "Black out the stage first" on, the shutdown
// sends the show's Blackout to "Lightkey Input" exactly as the deck's Blackout key does (a note-on,
// velocity 127), waits for Lightkey to report it on "Lightkey Output", then 2 seconds, and only then
// closes Stream Deck and Lightkey. The Sunday show's Blackout is a Flash trigger (ch 2 note 0, "while
// held", fade 0): a note-on only ever switches it on. If a show's binding toggled instead, a note-on
// to an already-on Blackout would switch it off; Lightkey then reports it off, and Booth Check sends
// once more to switch it back on (`blackoutNext`). It never sends without Lightkey's output to listen to.

/// A MIDI channel (1–16, as Lightkey and the deck show it) and note.
struct MIDINote: Hashable {
    let channel: Int
    let note: Int
    var text: String { "MIDI channel \(channel), note \(note)" }
}

/// "2:0" (channel:note) as `.deck.json` writes it; nil when it isn't one.
func parseMIDINote(_ s: String) -> MIDINote? {
    let p = s.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
    guard p.count == 2, let ch = Int(p[0]), (1...16).contains(ch), let note = Int(p[1]), (0...127).contains(note) else { return nil }
    return MIDINote(channel: ch, note: note)
}

/// The UMP word for a MIDI 1.0 note-on (group 0).
func midiNoteOnWord(_ n: MIDINote, velocity: Int = 127) -> UInt32 {
    0x2000_0000 | UInt32(0x90 | (n.channel - 1)) << 16 | UInt32(n.note) << 8 | UInt32(max(0, min(127, velocity)))
}

/// "90 00 7F": the MIDI 1.0 bytes in a UMP word, for the Log.
func midiBytesText(_ word: UInt32) -> String {
    [(word >> 16) & 0xFF, (word >> 8) & 0xFF, word & 0xFF].map { String(format: "%02X", $0) }.joined(separator: " ")
}

/// What `.deck.json` says about Blackout: nothing, `"blackout": null` (this show has none), or a note.
enum DeckFileBlackout: Equatable { case notSet, none, note(MIDINote) }

/// A deck key's title says Blackout ("BLACKOUT", "Black out"…).
func isBlackoutTitle(_ title: String) -> Bool {
    title.lowercased().filter { !$0.isWhitespace && $0 != "-" }.contains("blackout")
}

/// The notes a profile's Blackout keys send to Lightkey (a key called Blackout whose MIDI out is
/// "Lightkey Input"), each once.
func deckProfileBlackoutNotes(_ p: DeckProfile) -> [MIDINote] {
    var seen: [MIDINote] = []
    for k in p.blackoutKeys where k.outPort == IDs.lightkeyMIDIInput {
        let n = MIDINote(channel: k.channel, note: k.note)
        if !seen.contains(n) { seen.append(n) }
    }
    return seen
}

enum BlackoutSource: Equatable {
    case note(MIDINote, from: String)
    case unknown(String)        // why Booth Check can't tell, in plain words
}

/// Where the shutdown's Blackout comes from, needing nothing from a tech when the deck has a Blackout
/// key: the show's `.deck.json` (`"blackout": "2:0"`, or null for a show without one) wins; then the
/// Stream Deck profile chosen in This Mac; then every profile on this Mac, if their Blackout keys agree.
func blackoutSource(file: DeckShowFile?, chosen: DeckProfileChoice?, profiles: [DeckProfile]) -> BlackoutSource {
    switch file?.blackout ?? .notSet {
    case .note(let n): return .note(n, from: "the show\u{2019}s .deck.json")
    case .none: return .unknown("The show\u{2019}s .deck.json says this show has no Blackout.")
    case .notSet: break
    }
    if let chosen, case .found(let p, _) = matchDeckProfile(chosen, in: profiles) {
        let notes = deckProfileBlackoutNotes(p)
        if notes.count == 1 { return .note(notes[0], from: "the Blackout key on the Stream Deck profile \u{201C}\(p.name)\u{201D}") }
        return .unknown(notes.isEmpty
            ? "The Stream Deck profile \u{201C}\(p.name)\u{201D} has no key called Blackout that sends to Lightkey."
            : "The Stream Deck profile \u{201C}\(p.name)\u{201D} has Blackout keys on different notes (" + notes.map { "\($0.channel):\($0.note)" }.joined(separator: ", ") + ").")
    }
    let withKey = profiles.filter { !deckProfileBlackoutNotes($0).isEmpty }
    var notes: [MIDINote] = []
    for n in withKey.flatMap(deckProfileBlackoutNotes) where !notes.contains(n) { notes.append(n) }
    if notes.count == 1 {
        let names = Array(Set(withKey.map(\.name))).sorted().map { "\u{201C}\($0)\u{201D}" }
        return .note(notes[0], from: "the Blackout key on the Stream Deck profile" + (names.count == 1 ? " " : "s ") + names.joined(separator: ", "))
    }
    if notes.isEmpty {
        return .unknown("No Stream Deck profile on this Mac has a key called Blackout, and the show has no .deck.json naming one.")
    }
    return .unknown("Stream Deck profiles here use different notes for Blackout (" + notes.map { "\($0.channel):\($0.note)" }.joined(separator: ", ")
                    + "). Choose the deck\u{2019}s profile under Stream Deck above.")
}

enum BlackoutPlan: Equatable {
    case skip(String)
    case send(MIDINote, from: String)
}

/// Whether the shutdown sends Blackout. Never blind: without "Lightkey Output" Booth Check couldn't see
/// a toggling Blackout go off, so it doesn't send.
func blackoutPlan(lightkeyRunning: Bool, destinations: [String], sources: [String], source: BlackoutSource) -> BlackoutPlan {
    guard lightkeyRunning else { return .skip("Lightkey isn\u{2019}t open, so there are no lights to black out.") }
    guard destinations.contains(IDs.lightkeyMIDIInput) else {
        return .skip("Lightkey\u{2019}s MIDI input \u{201C}\(IDs.lightkeyMIDIInput)\u{201D} isn\u{2019}t there (no show open?), so nothing was sent.")
    }
    guard sources.contains(IDs.lightkeyMIDIOutput) else {
        return .skip("Lightkey\u{2019}s MIDI output \u{201C}\(IDs.lightkeyMIDIOutput)\u{201D} isn\u{2019}t there, so Booth Check couldn\u{2019}t see whether Blackout went on, and doesn\u{2019}t send it blind.")
    }
    switch source {
    case .unknown(let why): return .skip(why)
    case .note(let n, let from): return .send(n, from: from)
    }
}

enum CueReply: Equatable { case on, off }

/// Lightkey's report for one note in a UMP word from "Lightkey Output": 127 (any velocity) = on, a
/// Note Off or a note-on with velocity 0 = off. Other notes and messages: nil.
func cueReply(_ word: UInt32, for n: MIDINote) -> CueReply? {
    guard word >> 28 == 2 else { return nil }                       // MIDI 1.0 channel voice
    let status = (word >> 16) & 0xFF, note = Int((word >> 8) & 0x7F), value = word & 0x7F
    guard Int(status & 0x0F) + 1 == n.channel, note == n.note else { return nil }
    switch status & 0xF0 {
    case 0x90: return value > 0 ? .on : .off
    case 0x80: return .off
    default: return nil
    }
}

enum BlackoutNext: Equatable {
    case wait
    case sendAgain
    case done(on: Bool?, String)
}

/// Seconds to wait for Lightkey's report after each send, and for the lights after it.
let blackoutListen: TimeInterval = 1.5
let blackoutFade: TimeInterval = 2

/// What to do after sending Blackout, from Lightkey's reports since the last send. On: done. Off: the
/// binding toggles and Blackout was already on, so one more send puts it back on (never more than two
/// sends). No report within `blackoutListen`: a note-on to a Flash cue that's already on changes
/// nothing, so it's left as it is.
func blackoutNext(replies: [CueReply], sends: Int, sinceSend: TimeInterval) -> BlackoutNext {
    switch replies.last {
    case .on?:
        return .done(on: true, sends < 2 ? "Lightkey reported Blackout on."
                     : "Lightkey reported Blackout off after the first send (its binding toggles, so it had been on already); sent once more, and Lightkey reported it on again.")
    case .off?:
        if sends < 2 { return .sendAgain }
        return .done(on: false, "Lightkey still reported Blackout off after a second send, so Booth Check left it there.")
    case nil:
        guard sinceSend >= blackoutListen else { return .wait }
        return .done(on: nil, sends < 2
                     ? "No report from Lightkey within \(blackoutListen) s: Blackout was most likely on already (a note-on leaves the show\u{2019}s Blackout on)."
                     : "No report from Lightkey after the second send.")
    }
}

/// The switch's words in This Mac.
func blackoutSwitchDetail(on: Bool, source: BlackoutSource) -> String {
    guard on else { return "Off: the stage lights stay as they are while Lightkey closes, and may flicker." }
    switch source {
    case .note(let n, let from):
        return "Every shutdown, before Lightkey closes: the show\u{2019}s Blackout (\(n.text), from \(from)), then \(Int(blackoutFade)) seconds for the lights to go dark."
    case .unknown(let why):
        return "Can\u{2019}t send it: \(why) The shutdown carries on without it."
    }
}

/// The days the booth shuts down by itself, in words: "Sundays and Wednesdays".
func shutdownDaysText(_ days: Set<Int>) -> String {
    if days.count == 7 { return "every day" }
    let names = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays"]
    let list = days.sorted().filter { (1...7).contains($0) }.map { names[$0 - 1] }
    return list.count < 2 ? list.joined() : list.dropLast().joined(separator: ", ") + " and " + list.last!
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
/// NSAppleScript belongs on the main thread; anywhere else (the start-up's login fixes) the script goes
/// through `osascript`, with the shell's 20-second limit, so it can never wait for good.
func runAppleScript(_ source: String) -> (out: String, code: Int32) {
    guard Thread.isMainThread else {
        let r = shell("/usr/bin/osascript", ["-e", source])
        return (r.out.trimmingCharacters(in: .whitespacesAndNewlines), r.code)
    }
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
    case fixAppNap, chooseShow, openShow, launchStreamDeck, lightkeyNoPassword, stopReopeningApps
    case startDeckHelper, restartDeckHelper, installDeckHelper
    case reconnectDMX(pid_t), restartLightkeyForDMX
    case allowAccessibility, allowAutomation, makeLoginShow, addStreamDeckToLogin, addSelfToLogin
    case removeLoginItem(LoginItem)
    case removeShowLoginItems
    case enableAutoBoot(String?)
    case noStreamDeck
    case switchDeckProfile(device: String, to: String, from: String, name: String)
    case acceptDeckProfile
    case restoreDeckProfile(uuid: String, name: String)
    case openApp(String, String)        // bundle ID, name
    case openSetup
    case open(URL, String)

    var label: String {
        switch self {
        case .fixAppNap: return "Turn App Nap off\u{2026}"
        case .chooseShow: return "Choose show\u{2026}"
        case .openShow: return "Open the show"
        case .launchStreamDeck: return "Open Stream Deck"
        case .lightkeyNoPassword: return "Switch it on\u{2026}"
        case .stopReopeningApps: return "Switch it off\u{2026}"
        case .startDeckHelper: return "Start\u{2026}"
        case .restartDeckHelper: return "Restart\u{2026}"
        case .installDeckHelper: return "Install\u{2026}"
        case .reconnectDMX: return "Reconnect the lights\u{2026}"
        case .restartLightkeyForDMX: return "Restart Lightkey\u{2026}"
        case .allowAccessibility, .allowAutomation: return "Allow access\u{2026}"
        case .makeLoginShow: return "Make it the login show\u{2026}"
        case .addStreamDeckToLogin, .addSelfToLogin: return "Add to login\u{2026}"
        case .removeLoginItem, .removeShowLoginItems: return "Remove\u{2026}"
        case .enableAutoBoot: return "Turn on\u{2026}"
        case .noStreamDeck: return "No Stream Deck on this Mac"
        case .switchDeckProfile: return "Switch Stream Deck to it\u{2026}"
        case .acceptDeckProfile: return "Use it as it is now"
        case .restoreDeckProfile: return "Restore the Stream Deck\u{2019}s keys\u{2026}"
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
    var dmxDevice: USBDevice?               // the DMX interface, from either USB plane
    var dmxPlanes = DMXPlanes()
    var oladPIDs: [pid_t] = []              // Lightkey's olad, when Lightkey and the interface are both there
    var autoInstall: String?
    var lightkeyUSB: [String] = []          // USB driver connections Lightkey or its olad has open
    var lightkeySerial: [String] = []       // USB serial ports Lightkey has open
    var hasBattery = false                  // a laptop, so starting from the charger applies
    var lightkeyNoPassword = false          // Lightkey's DontUnloadFTDIDrivers is on
    var reopensApps: Bool? = true           // macOS reopens the apps open at shutdown; nil = couldn't tell
    var screenKeptOn = false                // macOS lists Booth Check's keep-the-screen-on request
    var deckHelperRead = false              // the deck lights helper was looked at this pass
    var deckHelperInstalled = false         // its LaunchAgents plist is there
    var deckHelperLoaded = false            // launchd has the job
    var deckHelperState: String?            // launchd's state for it: "running", "not running"…
    var deckHelperSHA: String?              // the installed binary's
    var deckHelperLastLog: String?          // the last line of its log
    var deckHelperProgramArgs: [String]?    // what its installed LaunchAgent starts it with
    var deckShow: (file: DeckShowFile, warnings: [String], path: String)?   // the show's .deck.json, if any
    var deckProfiles: DeckProfilesRead?     // Stream Deck's profiles (nil: Stream Deck is off here)
    var deckPreferred: [String: String] = [:]   // each deck's preferred profile, from its preferences
    var deckPrefsProblem: String?
    /// The service profile on disk and its last-good copy (Nov 2026), when a profile is chosen.
    var deckDisk: (uuid: String, health: DeckProfileHealth, copy: DeckCopyInfo?)?
    var deckAsksToRestore = false           // Stream Deck's "restore the backup from today?" is up (its log)
    var bootValue: String?                // the firmware setting; nil = not set = factory setting
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

/// How a volunteer restarts Stream Deck by hand: quitting it is enough, since Booth Check opens it again
/// (`keepStreamDeckOpen`, at most once a minute).
let quitStreamDeckWords = "Quit Stream Deck (its menu bar icon \u{2192} Quit Stream Deck); Booth Check opens it again by itself within a minute."

/// What a volunteer does when the DMX box isn't seen: replug it; the DMX row then offers the reconnect.
let replugDMXWords = "Unplug the blue DMX box\u{2019}s USB cable and plug it back in; if the lights stay off, click the button on the \u{201C}Lightkey is sending DMX\u{201D} row."

/// Apps read the App Nap setting when they open, so only a Stream Deck that was already running
/// when Booth Check switched it off can still be put to sleep; one opened afterwards is fine.
func appNapCheck(appNapOff: Bool, switchedOffAt: Date?, deckLaunched: Date?) -> Check {
    if !appNapOff {
        return Check(id: "nap", group: "Power & sleep", title: "App Nap off", status: .fail,
                     detail: "macOS can put the Stream Deck app to sleep — that's what freezes the keys.",
                     fix: "Click Turn App Nap off\u{2026} (no password).", action: .fixAppNap)
    }
    if let switchedOffAt, let deckLaunched, deckLaunched < switchedOffAt {
        return Check(id: "nap", group: "Power & sleep", title: "App Nap off", status: .warn,
                     detail: "Switched off after the Stream Deck app opened, so that copy can still be put to sleep.",
                     fix: quitStreamDeckWords)
    }
    return Check(id: "nap", group: "Power & sleep", title: "App Nap off", status: .ok,
                 detail: "macOS won't put the Stream Deck app to sleep.")
}

/// macOS reopening the apps that were open at shutdown (see `reopensAppsAtLogin`): they open before
/// Booth Check's start-up, in no order, Lightkey included.
func reopenAppsCheck(_ reopens: Bool?) -> Check {
    let title = "Old apps don\u{2019}t reopen at start-up"
    switch reopens {
    case false?:
        return Check(id: "reopen", group: "Start at login", title: title, status: .ok,
                     detail: "macOS doesn\u{2019}t reopen the apps that were open at shutdown.")
    case true?:
        return Check(id: "reopen", group: "Start at login", title: title, status: .warn,
                     detail: "macOS reopens the apps that were open at shutdown, before Booth Check\u{2019}s start-up and in no order.",
                     fix: "Switch off reopening windows when logging back in.", action: .stopReopeningApps)
    case nil:
        return Check(id: "reopen", group: "Start at login", title: title, status: .unknown,
                     detail: "Couldn\u{2019}t read the setting.",
                     fix: "When shutting down from the Apple menu, untick \u{201C}Reopen windows when logging back in\u{201D}.",
                     action: .stopReopeningApps)
    }
}

final class Booth: ObservableObject {
    static let shared = Booth()

    @Published var checks: [Check] = []
    @Published var loginItems: [LoginItem] = []
    @Published var loginRead: LoginRead = .items([])
    @Published var lastChecked: Date?
    /// "Checking…" until the first pass is in; after 30 s it says what it's waiting for (`watchFirstPass`).
    @Published var checkingNote = "Checking\u{2026}"
    @Published var message: String?
    @Published var showPath: String? = UserDefaults.standard.string(forKey: IDs.showKey)
    @Published var pending: PendingChange?
    @Published var lastPass: [LogEntry] = []
    /// Every change and start-up step, newest first: each new one also goes to the log on disk in
    /// full (`logNewChanges`), and only the newest 500 stay in memory.
    @Published var changes: [LogEntry] = [] {
        didSet { logNewChanges(oldValue) }
    }
    /// Diagnostics (1.31): the last definite check results and since when each has been failing, the
    /// checks whose incident went, the pass log's state, each start-up step's start, and more.
    var diagBaseline: [Check]?
    var diagFailingSince: [String: Date] = [:]
    var diagIncidentSent: Set<String> = []
    var lastPassSignature: String?
    var lastFullPass: Date?
    var diagReplugShown = false
    var diagStartupDone = false
    var shutdownStartedAt: Date?
    /// The session log (1.30, see `SessionTally`): plain storage, never @Published, so the 15-second
    /// passes and the person events never ask SwiftUI for an update. Session seconds count from
    /// `sessionUptime0` (monotonic).
    var tally = SessionTally(session: "", version: "", launch: "", startedWall: Date().timeIntervalSince1970)
    let sessionUptime0 = ProcessInfo.processInfo.systemUptime
    var sessionEnded = false
    /// Why Booth Check is quitting, when something other than a plain quit (see `endSession`).
    var quitReason: String?
    /// The row whose Fix opened the change sheet, as it was then (for the person events).
    var pendingRow: (id: String, title: String, status: String)?
    /// Lightkey's Authenticate: since when it has been asking (uptime), and how long it asked this start-up.
    var authAskingSince: TimeInterval?
    var authWaitTotal: Double = 0
    /// This start-up: its start (uptime), whether someone started it, whether it's the check-only one,
    /// person events during it, each step's start (uptime).
    var bootStartedUptime: TimeInterval?
    var bootByHand = false
    var bootCheckOnly = false
    var bootPeople = 0
    var stepStartedUptime: [Int: TimeInterval] = [:]
    /// The shutdown's timing marks (uptime) and how its apps closed.
    var shutdownMarks: [(name: String, at: Double)] = []
    var shutdownClosed: [String: DiagValue] = [:]
    /// This Mac settings changed in the last 2 seconds, sent together as one settings_changed.
    var settingKeysPending: Set<String> = []
    var settingKeysWork: DispatchWorkItem?

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
    /// Times this start-up brought Lightkey to the front, and when last (see `shouldFrontLightkey`).
    private var frontAttempts = 0
    private var lastFront: Date?
    /// When Booth Check last opened Stream Deck (see `keepStreamDeckOpen`), and its watch for Lightkey
    /// starting outside a start-up (see `watchLightkeyLaunches`).
    private var lastDeckOpen: Date?
    private var lightkeyLaunchWatch: NSObjectProtocol?
    /// The deck lights helper (see `keepDeckHelperRunning`): its installed copy, since when it has been
    /// failing, when Booth Check restarted it by itself, and whether the window came up for it.
    @Published var deckHelperSHA: String?
    private var deckHelperFailingSince: Date?
    private var deckHelperFixes: [Date] = []
    private var deckHelperAlerted = false
    var deckHelperFixesAgo: [TimeInterval] { deckHelperFixes.map { Date().timeIntervalSince($0) } }
    /// The show's .deck.json (1.32, see `parseDeckShowFile`): nil = no file, the built-in Summit rules.
    @Published var deckShow: DeckShowFile? = loadDeckShowFile(forShow: UserDefaults.standard.string(forKey: IDs.showKey))?.file
    var deckShowText: String?
    var deckShowTextLogged = false
    /// The helper's arguments for this show, and whether this show uses the helper at all.
    var helperArgsInUse: [String] { deckShow?.helperArgs ?? deckHelperArgs }
    var showUsesHelper: Bool { deckShow.map { $0.helperArgs != nil } ?? true }
    /// Where the shutdown's Blackout would come from now, for This Mac (the shutdown reads it afresh).
    var blackoutSourceNow: BlackoutSource {
        blackoutSource(file: deckShow, chosen: setup.deckProfile, profiles: deckProfiles.profiles)
    }
    /// Stream Deck's profiles as last read (for This Mac's picker); whether Booth Check's switch of
    /// the profile didn't stick (then the row says how to choose it by hand); the last deck_profile event.
    @Published var deckProfiles = DeckProfilesRead()
    var deckProfileWriteFailed = false
    var lastDeckProfileDiag: String?
    var deckProfileSwitching = false
    /// Automatic restores of a Stream Deck profile this session (`deckMendDecision` caps them), whether
    /// the last automatic one didn't hold after Stream Deck opened (the row says so), and a restore by
    /// the button under way.
    var deckAutoRestores = 0
    var deckRepairFailed = false
    var deckRestoring = false
    /// Stream Deck restarts under way (`restartStreamDeck`: the start-up, a Lightkey launch, the helper
    /// install, a profile switch). See `streamDeckClosedOnPurpose`.
    var deckRestartsRunning = 0
    /// Booth Check has closed Stream Deck on purpose (or is about to): a restart or a profile switch
    /// under way. The shutdown has `shuttingDown`. Nothing may reopen it meanwhile.
    var streamDeckClosedOnPurpose: Bool { deckRestartsRunning > 0 || deckProfileSwitching || deckRestoring }
    /// Whether Lightkey may ask for the Mac's password this start-up: it has a DMX interface to take,
    /// and its DontUnloadFTDIDrivers setting is off. Read when the start-up begins.
    private var lightkeyMayAsk = true
    /// This start-up opened Lightkey itself, without the show (the `lightkeyApp` step), and whether it
    /// has quit and reopened it once because its MIDI input didn't appear (`midiRelaunchAllowed`).
    private var lightkeyOpenedByStartUp = false
    private var midiRelaunched = false
    /// What "Lightkey Output" had reported as the show began to open (nil: Booth Check wasn't listening
    /// then), for whether Lightkey reported the show's start states (`startStateEvidence`).
    private var startStateMark: MIDIActivity?
    private var startStateLate = false
    /// Lightkey was running when Booth Check started at login: macOS reopened it (see `logAppsOpenAtLogin`).
    var lightkeyReopenedByMacOS = false
    /// DMX self-recovery (1.30, see `dmxLadderNext`): when this start-up began and what each step did
    /// (for the snapshots), whether Lightkey was running then, when the box was first seen and whether
    /// at the first look, what the ladder tried, and, after the start-up, when Reconnect last ran.
    var bootStartedAt: Date?
    var bootTimeline: [String] = []
    var lightkeyRunningAtStart = false
    /// Whether this start-up is the login one (a suspect link may then restart Lightkey; see `dmxSuspectCounts`).
    var bootAtLogin = false
    var dmxFirstSeen: Date?
    var dmxSeenAtStart = false
    var dmxLadder = DMXLadder()
    /// The current DMX link was suspect (see `dmxLinkSuspect`; or macOS reopened Lightkey), which
    /// justifies restarting Lightkey without olad's log saying it found nothing (`dmxRelaunchJustified`).
    var dmxSuspect = false
    var dmxReconnectAt: Date?
    var dmxRestartingByHand = false
    var lastDMXPresent: Bool?
    var lastDMXRows: String?
    var lastMonitorSnapshot: Date?
    /// The big sign is showing a self-repair (see `showWorkingSign`): `workingActive` while the work
    /// goes on, `workingSignUp` until its last word has gone too.
    var workingActive = false
    var workingSignUp = false
    /// The menu bar icon: kept inserted (see `keepMenuIcon`), and its 15-second self-check (`watchMenuIcon`).
    @Published var menuIconInserted = true {
        didSet { if !menuIconInserted && !reinsertingIcon { keepMenuIcon() } }
    }
    var reinsertingIcon = false
    var iconWatch = IconWatch()
    private var timers: [Timer] = []

    /// What this Mac is for. Checks for parts it doesn't use are switched off (and counted).
    @Published var setup: MacSetup = MacSetup.saved ?? MacSetup.detected() {
        didSet {
            setup.save()
            noteSettings(changedSetupKeys(oldValue, setup))
            if setup.deckProfile != oldValue.deckProfile { deckProfileWriteFailed = false }
            refresh()
            if setup.streamDeck && !oldValue.streamDeck { keepStreamDeckOpen() }    // switched on just now
        }
    }
    /// True until someone has confirmed the setup sheet once on this Mac.
    @Published var needsSetup = MacSetup.saved == nil
    @Published var showSetup = false
    /// Run once This Mac has closed: a change it asked for, whose sheet can't open over it.
    var afterSetup: (() -> Void)?
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
            if autoStart != oldValue { noteSettings(["autoStart"]) }
            refresh()
        }
    }

    /// Shut the booth down by itself at a set time each week, after a 5-minute warning (see
    /// `shutDownBooth`). Off until someone sets it up in This Mac.
    @Published var autoShutdown: Bool = UserDefaults.standard.bool(forKey: IDs.autoShutdownKey) {
        didSet {
            UserDefaults.standard.set(autoShutdown, forKey: IDs.autoShutdownKey)
            if autoShutdown != oldValue { noteSettings(["autoShutdown"]) }
            armShutdown()
        }
    }
    /// The days (Calendar weekdays, 1 = Sunday) and the time (minutes after midnight). Sundays at 1 pm to start with.
    @Published var shutdownDays: Set<Int> = Set(UserDefaults.standard.array(forKey: IDs.shutdownDaysKey) as? [Int] ?? [1]) {
        didSet {
            UserDefaults.standard.set(shutdownDays.sorted(), forKey: IDs.shutdownDaysKey)
            if shutdownDays != oldValue { noteSettings(["shutdownDays"]) }
            armShutdown()
        }
    }
    @Published var shutdownMinute: Int = UserDefaults.standard.object(forKey: IDs.shutdownMinuteKey) as? Int ?? 13 * 60 {
        didSet {
            UserDefaults.standard.set(shutdownMinute, forKey: IDs.shutdownMinuteKey)
            if shutdownMinute != oldValue { noteSettings(["shutdownMinute"]) }
            armShutdown()
        }
    }
    /// Lightkey's DontUnloadFTDIDrivers, as last read (each check pass): on, it connects to the DMX
    /// interface without asking for the Mac's password. Its This Mac switch calls `setLightkeyNoPassword`.
    @Published var lightkeyNoPassword = defaultsSaysOn(shell("/usr/bin/defaults", ["read", IDs.lightkey, "DontUnloadFTDIDrivers"]).out)

    /// Switches Lightkey's DontUnloadFTDIDrivers on or off from This Mac, with the same `defaults`
    /// command the Terminal test used (no password; it's Lightkey's own setting for this account). The
    /// switch's description shows the command; the run and its output go in the Log.
    func setLightkeyNoPassword(_ on: Bool) {
        let args = lightkeyPasswordCommand(on: on)
        let r = shell("/usr/bin/defaults", args)
        changes.insert(LogEntry(title: on ? "This Mac: Lightkey connects without the password" : "This Mac: Lightkey asks for the password again",
                                language: "Terminal", code: commandLine("/usr/bin/defaults", args),
                                output: r.out.isEmpty ? "(no output)" : r.out, status: r.code), at: 0)
        lightkeyNoPassword = defaultsSaysOn(shell("/usr/bin/defaults", ["read", IDs.lightkey, "DontUnloadFTDIDrivers"]).out)
        if r.code == 0 { setup.noPasswordWanted = on }      // a tech's choice: the start-up keeps to it
        noteSettings(["lightkeyNoPassword"])
        refresh()
    }

    /// A login start-up, before Lightkey opens (Nov 2026, owner-approved, see `lightkeyNoPasswordRepairNeeded`):
    /// the no-password setting went missing (Lightkey's settings reset, say) though it's wanted here, so
    /// it's written back with the same `defaults` command as This Mac's switch, then read back. Logged
    /// with the command, its output and the undo, and a `self_repair` event.
    func putBackNoPasswordSetting() {
        let read = ["read", IDs.lightkey, "DontUnloadFTDIDrivers"]
        guard lightkeyNoPasswordRepairNeeded(wanted: setup.noPasswordWanted, settingOn: defaultsSaysOn(shell("/usr/bin/defaults", read).out),
                                             lightkeyRunning: isRunning(IDs.lightkey), dmx: setup.lightkey && setup.dmx) else { return }
        let args = lightkeyPasswordCommand(on: true)
        let r = shell("/usr/bin/defaults", args)
        let on = defaultsSaysOn(shell("/usr/bin/defaults", read).out)
        lightkeyNoPassword = on
        changes.insert(LogEntry(title: "Start-up: put back \u{201C}Lightkey connects without the password\u{201D}", language: "Terminal",
                                code: commandLine("/usr/bin/defaults", args) + "\n" + commandLine("/usr/bin/defaults", read) + "   # read back",
                                output: (r.out.isEmpty ? "" : r.out + "\n")
                                    + "DontUnloadFTDIDrivers was off, though Lightkey connected without the password here before, so Booth Check switched it back on before Lightkey opens. Read back: \(on ? "on" : "still off").\n"
                                    + "Undo (with Lightkey quit), or untick it in This Mac: " + commandLine("/usr/bin/defaults", lightkeyPasswordCommand(on: false)),
                                status: on ? 0 : 1), at: 0)
        diagEvent("self_repair", ["what": .string("lightkey_no_password"), "why": .string("setting missing at login"), "result": .string(on ? "ok" : "failed")])
    }

    /// Shut the booth down when the charger's power goes off, after a 1-minute warning (see
    /// `powerNext`). Off unless switched on in This Mac.
    @Published var shutdownOnPowerOff: Bool = UserDefaults.standard.bool(forKey: IDs.powerOffKey) {
        didSet {
            UserDefaults.standard.set(shutdownOnPowerOff, forKey: IDs.powerOffKey)
            if shutdownOnPowerOff != oldValue { noteSettings(["shutdownOnPowerOff"]) }
        }
    }
    /// When the set time next comes round (see `armShutdown`), and whether a shutdown is under way.
    @Published var shutdownAt: Date?
    @Published var shuttingDown = false
    private var shutdownReason: ShutdownReason = .button
    private var countdownTimer: Timer?
    private var closingApps = false
    /// The power, as last read; whether it went off while Booth Check was running; and whether that
    /// power cut has had its warning.
    private var powerWasAC = true
    private var powerOutage = false
    private var powerOutageWarned = false
    private var powerWatch: CFRunLoopSource?

    private var busy = false
    /// Check passes started and the last one finished, numbered from 1, and a request that came while
    /// one ran (see `refresh`). Plain values, never published.
    private var refreshAsked = false
    private(set) var passesStarted = 0
    private(set) var passesFinished = 0
    /// The login rows a login start-up just fixed by itself (`repairLoginAtStartUp`), confirmed by the
    /// first pass numbered above `after` (`confirmLoginRepairs`).
    var loginRepairsToConfirm: (ids: [String], after: Int, ran: [String: Int32])?
    /// When Booth Check switched App Nap off, this session. Apps read the setting when they open.
    private var appNapSwitchedOffAt: Date?
    /// Booth Check's keep-the-screen-on request while it's held (see `keepScreenOn`), and whether
    /// macOS turned it down (logged once, not every 15 seconds).
    private var screenAssertion: IOPMAssertionID = 0
    private var screenAssertionRefused = false

    var showName: String? { showPath.map { URL(fileURLWithPath: $0).lastPathComponent } }

    /// Asks for a check pass. One already running started too early to see what the caller just did,
    /// so the request is kept and a fresh pass follows it (one at most, however many asked meanwhile).
    func refresh() {
        guard !busy else { refreshAsked = true; return }
        busy = true
        passesStarted += 1
        let passNumber = passesStarted
        let lightkeyPID = NSRunningApplication.runningApplications(withBundleIdentifier: IDs.lightkey).first?.processIdentifier
        let deckHelperSwitchedOn = setup.lightkey && setup.streamDeck && setup.deckLights != false
        let deckOn = setup.streamDeck
        let deckChoice = setup.deckProfile
        let show = showPath
        DispatchQueue.global(qos: .userInitiated).async {
            let pass = Pass()
            var s = Snapshot()
            // The show's .deck.json (1.32): the helper's rules and the suggested profile. None: built-in.
            s.deckShow = loadDeckShowFile(forShow: show)
            if show != nil {
                pass.api("The show's deck file", "FileManager: read \(show.map(deckShowFilePath) ?? "")", deckShowFileText(s.deckShow))
            }
            let helperArgs = s.deckShow?.file.helperArgs ?? deckHelperArgs
            let deckHelperOn = deckHelperSwitchedOn && (s.deckShow.map { $0.file.helperArgs != nil } ?? true)
            // Stream Deck's profiles and which one each deck is on (1.32). Read only.
            if deckOn {
                let read = readDeckProfiles()
                s.deckProfiles = read
                pass.api("Stream Deck profiles", "FileManager: read \(read.folder ?? streamDeckSupportDir)/*.sdProfile/manifest.json and Profiles/*/manifest.json",
                         deckProfilesText(read))
                let prefs = deckPreferredProfiles(readStreamDeckDevices())
                s.deckPreferred = prefs.preferred
                s.deckPrefsProblem = prefs.problem
                pass.api("Stream Deck's profile per deck", "CFPreferencesCopyAppValue(\"Devices\", \"\(IDs.streamDeck)\") \u{2192} each deck \u{2192} ESDProfilesInfo \u{2192} ESDProfilesPreferred",
                         prefs.problem ?? (prefs.preferred.isEmpty ? "(no decks listed)" : prefs.preferred.sorted { $0.key < $1.key }.map { k, v in
                            "\(k): \(v)" + (read.profiles.first { $0.uuid == v }.map { " (\u{201C}\($0.name)\u{201D})" } ?? "")
                         }.joined(separator: "\n")))
                // Stream Deck's own "restore the backup?" question, from its log (Nov 2026). Read only.
                if let log = try? String(contentsOfFile: streamDeckLogPath, encoding: .utf8) {
                    s.deckAsksToRestore = streamDeckAsksToRestore(log: log)
                    if s.deckAsksToRestore {
                        pass.api("Stream Deck's question at launch", "FileManager: read \(streamDeckLogPath)",
                                 "Its log says \u{201C}Detected data loss - propose restore backup to user\u{201D} and it hasn\u{2019}t started since: its window asks whether to restore its backup from today.")
                    }
                }
                // The service profile's files and Booth Check's last-good copy of it (Nov 2026). Read only.
                if let choice = deckChoice, read.folder != nil,
                   let t = deckProfilesToMend(choice: choice, read: read, preferred: prefs.preferred, hasCopy: { _ in true }).first {
                    let d = deckDiskState(uuid: t.uuid, read: read)
                    s.deckDisk = (d.uuid, d.health, d.copy)
                    pass.api("The service profile on disk", "FileManager: read \(d.dir)/manifest.json and Profiles/*/manifest.json; \(DeckCopyStore(root: deckBackupsRoot, uuid: t.uuid).goodInfo)",
                             "\u{201C}\(t.name)\u{201D}: \(d.health.why)." + (d.copy.map { " Last-good copy from \(deckCopyDateText($0.savedAt)) (\($0.pages) pages, \($0.keys) MIDI keys)." } ?? " No last-good copy yet."))
                }
            }
            // The deck lights helper: switched on here, or not decided yet (then it's looked for).
            if deckHelperOn {
                s.deckHelperRead = true
                s.deckHelperInstalled = FileManager.default.fileExists(atPath: deckHelperPlist)
                pass.api("Deck lights helper installed", "FileManager: is \(deckHelperPlist) there",
                         s.deckHelperInstalled ? "Found." : "Not there.")
                let job = pass.sh("Deck lights helper in launchd", "/bin/launchctl", ["print", deckHelperService])
                s.deckHelperLoaded = job.code == 0
                s.deckHelperState = s.deckHelperLoaded ? launchdJobState(job.out) : nil
                s.deckHelperSHA = fileSHA256(deckHelperBinary)
                let tail = FileHandle(forReadingAtPath: deckHelperLog).map { h -> Data in
                    defer { try? h.close() }
                    let end = (try? h.seekToEnd()) ?? 0
                    try? h.seek(toOffset: end > 2048 ? end - 2048 : 0)
                    return (try? h.readToEnd()) ?? Data()
                }
                s.deckHelperLastLog = tail.flatMap { String(decoding: $0, as: UTF8.self).split(separator: "\n").last.map(String.init) }
                pass.api("Deck lights helper's copy and log", "SHA-256 of \(deckHelperBinary); the last line of \(deckHelperLog)",
                         "Installed: \(s.deckHelperSHA ?? "none"). Booth Check carries: \(deckHelperBundledSHA ?? "none").\nLast log line: \(s.deckHelperLastLog ?? "(no log)")")
                s.deckHelperProgramArgs = installedHelperArgs(FileManager.default.contents(atPath: deckHelperPlist))
                if s.deckHelperInstalled {
                    let same = deckHelperArgsCurrent(installed: s.deckHelperProgramArgs, expected: helperArgs)
                    pass.api("Deck lights helper's settings", "Read ProgramArguments from \(deckHelperPlist)",
                             "Installed: \(s.deckHelperProgramArgs?.dropFirst().joined(separator: " ") ?? "(couldn\u{2019}t read)")\nBooth Check would install: \(helperArgs.joined(separator: " "))\n"
                                + (same == true ? "The same." : same == false ? "Different: installed with old settings." : "Can\u{2019}t tell."))
                }
            }
            let batt = pass.sh("Power source", "/usr/bin/pmset", ["-g", "batt"]).out
            s.onAC = batt.contains("'AC Power'")
            s.hasBattery = batt.contains("InternalBattery")
            s.lightkeyNoPassword = defaultsSaysOn(pass.sh("Lightkey connects without the password", "/usr/bin/defaults",
                                                          ["read", IDs.lightkey, "DontUnloadFTDIDrivers"]).out)
            let reopen = pass.sh("Old apps reopen at start-up", "/usr/bin/defaults",
                                 ["read", "com.apple.loginwindow", "TALLogoutSavesState"])
            s.reopensApps = reopensAppsAtLogin(reopen.out, code: reopen.code)
            if s.hasBattery {
                let boot = pass.sh("Starts from the charger", "/usr/sbin/nvram", [bootVariable])
                if boot.code == 0 {
                    s.bootValue = nvramValue(boot.out)
                } else if !boot.out.contains("not found") {
                    s.bootReadFailed = true
                }
            }
            s.ac = pmsetSection(pass.sh("Sleep settings", "/usr/bin/pmset", ["-g", "custom"]).out, "AC Power")
            s.screenKeptOn = holdsScreenAssertion(pass.sh("What keeps the screen on", "/usr/bin/pmset", ["-g", "assertions"]).out)
            s.appNapOff = pass.sh("App Nap setting", "/usr/bin/defaults", ["read", "-g", "NSAppSleepDisabled"])
                .out.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
            let usbOut = pass.sh("USB devices", "/usr/sbin/ioreg", ioUSBPlaneArgs).out
            s.usb = usbDevices(usbOut)
            // The DMX interface counts if either plane lists it (1.30): the IOUSB plane alone may miss it.
            let serviceOut = pass.sh("USB devices (IOService plane)", "/usr/sbin/ioreg", ioServicePlaneArgs).out
            s.dmxPlanes = dmxPlanes(usbPlane: usbOut, servicePlane: serviceOut)
            s.dmxDevice = s.usb.first(where: isDMXInterface) ?? usbDevices(serviceOut).first(where: isDMXInterface)
            if s.dmxPlanes.disagree {
                pass.api("DMX interface: the two USB planes disagree", "Compare the IOUSB and IOService planes",
                         "The DMX interface was \(s.dmxPlanes.text). It counts as plugged in.")
            }
            let upd = pass.sh("Automatic macOS updates", "/usr/bin/defaults",
                              ["read", "/Library/Preferences/com.apple.SoftwareUpdate", "AutomaticallyInstallMacOSUpdates"])
            s.autoInstall = upd.code == 0 ? upd.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil

            // Experimental: is Lightkey actually using the DMX interface? Only worth asking when
            // both are there. Lightkey drives it through its OLA server, olad, so both processes
            // count. Logged filtered to their own entries; the raw output is huge.
            if let pid = lightkeyPID, s.dmxPlanes.present {
                let psArgs = ["-axo", "pid=,comm="]
                let ps = shell("/bin/ps", psArgs)
                let pids = dmxDriverPIDs(lightkey: pid, psOutput: ps.out)
                s.oladPIDs = pids.filter { $0 != pid }
                let olad = s.oladPIDs.map(String.init)
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
                let lsofArgs = lsofArgs(pids)
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
                self.finish(s, pass, number: passNumber)
                self.passesFinished = passNumber
                self.busy = false
                if self.refreshAsked {
                    self.refreshAsked = false
                    self.refresh()
                }
            }
        }
    }

    // Accessibility, NSWorkspace, CoreMIDI and AppleScript all run here on the main thread.
    private func finish(_ s: Snapshot, _ pass: Pass, number: Int) {
        var out: [Check] = []
        // The show's .deck.json: noted in the Log whenever what it says changes (and at the first pass).
        let showText = deckShowFileText(s.deckShow)
        if showText != deckShowText {
            deckShowText = showText
            if s.deckShow?.file != deckShow { deckShow = s.deckShow?.file }
            if s.deckShow != nil || deckShowTextLogged {
                logSetting("The show\u{2019}s deck file", showText)
            }
            deckShowTextLogged = true
        }
        let running = NSWorkspace.shared.runningApplications
        let lightkey = running.first { $0.bundleIdentifier == IDs.lightkey }
        let deckApp = running.first { $0.bundleIdentifier == IDs.streamDeck }
        pass.api("Running apps", "NSWorkspace: list the running apps",
                 "Lightkey: \(lightkey == nil ? "not running" : "running")\nStream Deck: \(deckApp == nil ? "not running" : "running")")

        // Lighting ---------------------------------------------------------------------------
        let dmx = s.dmxDevice
        if let d = dmx {
            let serial = d.serial.isEmpty ? "" : ", serial \(d.serial)"
            out.append(Check(id: "dmx", group: "Lighting", title: "DMX interface plugged in", status: .ok,
                             detail: "\(d.name.isEmpty ? "USB DMX interface" : d.name)\(serial)."
                                + (s.dmxPlanes.disagree ? " (\(s.dmxPlanes.text.prefix(1).uppercased() + s.dmxPlanes.text.dropFirst()).)" : "")))
        } else {
            out.append(Check(id: "dmx", group: "Lighting", title: "DMX interface plugged in", status: .fail,
                             detail: "No USB DMX interface found.",
                             fix: replugDMXWords))
        }

        out.append(lightkey != nil
            ? Check(id: "lk", group: "Lighting", title: "Lightkey is running", status: .ok, detail: "Lightkey is open.")
            : Check(id: "lk", group: "Lighting", title: "Lightkey is running", status: .fail,
                    detail: "Lightkey isn't open.",
                    fix: showPath != nil ? "Click Open the show." : "Click Open Lightkey.",
                    action: showPath != nil ? .openShow : .openApp(IDs.lightkey, "Lightkey")))

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
            // Never fixed by itself once the booth is ready (the owner's call): a person presses the button.
            let detail = "Lightkey is open, but it doesn\u{2019}t seem to be using the DMX interface."
            switch dmxRowFix(oladPID: s.oladPIDs.first, sinceReconnect: dmxReconnectAt.map { Date().timeIntervalSince($0) }) {
            case .reconnect(let pid):
                out.append(Check(id: "dmxLive", group: "Lighting", title: dmxTitle, status: .fail, detail: detail,
                                 fix: "Reconnect asks Lightkey\u{2019}s DMX server to look for the interface again; the lights should not change. If the lights respond, trust the lights.",
                                 action: .reconnectDMX(pid)))
            case .checking:
                out.append(Check(id: "dmxLive", group: "Lighting", title: dmxTitle, status: .fail, detail: detail,
                                 fix: "Asked Lightkey\u{2019}s DMX server to look again; checking\u{2026}"))
            case .restart:
                out.append(Check(id: "dmxLive", group: "Lighting", title: dmxTitle, status: .fail, detail: detail,
                                 fix: (dmxReconnectAt != nil ? "Reconnecting didn\u{2019}t help. " : "")
                                    + "Restarting Lightkey makes it look for the interface again; the lights go dark for about 20 seconds.",
                                 action: .restartLightkeyForDMX))
            }
        }
        if dmx == nil || lightkey == nil || !s.lightkeyUSB.isEmpty || !s.lightkeySerial.isEmpty { dmxReconnectAt = nil }
        if setup.lightkey && setup.dmx { watchDMXRows(present: dmx != nil, planes: s.dmxPlanes, rows: out.filter { $0.id == "dmx" || $0.id == "dmxLive" }) }

        // Lightkey asks for the Mac's password (Authenticate) before it takes the DMX interface, unless
        // its hidden DontUnloadFTDIDrivers setting is on. On the church Mac (Intel, Open DMX USB) the
        // lights work with it on and nothing asks (9 Oct 2026).
        let passTitle = "Lightkey connects without the password"
        out.append(s.lightkeyNoPassword
            ? Check(id: "lkpass", group: "Lighting", title: passTitle, status: .ok,
                    detail: "Lightkey\u{2019}s DontUnloadFTDIDrivers setting is on, so it doesn\u{2019}t ask to Authenticate.")
            : Check(id: "lkpass", group: "Lighting", title: passTitle, status: .warn,
                    detail: "Lightkey asks for the Mac\u{2019}s password (Authenticate) each time it connects to the DMX interface.",
                    fix: "Switch on Lightkey\u{2019}s DontUnloadFTDIDrivers setting, and it stops asking. Tested on the church Mac with its Open DMX USB.",
                    action: .lightkeyNoPassword))

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
                             status: .fail, detail: "Lightkey is open but its MIDI input isn't there, so the Stream Deck's keys do nothing.",
                             fix: "Click Restart Lightkey\u{2026} (the lights go dark for about 20 seconds).",
                             action: .restartLightkeyForDMX))
        }

        // Stream Deck --------------------------------------------------------------------------
        let deck = s.usb.first { $0.vendorID == IDs.elgatoVendor || $0.name.localizedCaseInsensitiveContains("Stream Deck") }
        out.append(deck != nil
            ? Check(id: "deck", group: "Stream Deck", title: "Stream Deck plugged in", status: .ok,
                    detail: "\(deck!.name.isEmpty ? "Stream Deck" : deck!.name).")
            : Check(id: "deck", group: "Stream Deck", title: "Stream Deck plugged in", status: .fail,
                    detail: "No Stream Deck found on USB.",
                    fix: "Unplug the Stream Deck\u{2019}s USB cable and plug it back in."))

        let deckInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: IDs.streamDeck) != nil
        if deckApp != nil && s.deckAsksToRestore {
            // Nov 2026: Stream Deck's own question at launch blocks it (and its keys) until answered.
            out.append(Check(id: "deckapp", group: "Stream Deck", title: "Stream Deck app running", status: .fail,
                             detail: "Stream Deck is waiting for an answer: it asks whether to restore its backup from today, and its keys don\u{2019}t work until someone answers.",
                             fix: "In Stream Deck\u{2019}s window, click Restore."))
        } else if deckApp != nil {
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
        if s.deckHelperRead {
            if deckLightsAutoOn(setting: setup.deckLights, installed: s.deckHelperInstalled,
                                lightkey: setup.lightkey, streamDeck: setup.streamDeck) {
                setup.deckLights = true
                logSetting("This Mac: deck lights helper found", "It\u{2019}s installed here, so Booth Check now checks it\u{2019}s running (This Mac \u{2192} Stream Deck \u{2192} Deck lights helper).")
            }
            let sources = MIDIWatch.shared.sourceNames()
            pass.api("The deck lights helper's MIDI port", "CoreMIDI: list the MIDI sources",
                     sources.isEmpty ? "(none)" : sources.joined(separator: "\n"))
            deckHelperSHA = s.deckHelperSHA
            let check = deckHelperCheck(installed: s.deckHelperInstalled, loaded: s.deckHelperLoaded, state: s.deckHelperState,
                                        feedbackPort: sources.contains { $0.localizedCaseInsensitiveContains(IDs.deckFeedback) },
                                        current: s.deckHelperSHA.flatMap { sha in deckHelperBundledSHA.map { $0 == sha } },
                                        lastLog: s.deckHelperLastLog, gaveUp: deckHelperGaveUp(fixes: deckHelperFixesAgo),
                                        argsCurrent: s.deckHelperInstalled ? deckHelperArgsCurrent(installed: s.deckHelperProgramArgs, expected: helperArgsInUse) : nil)
            out.append(check)
            keepDeckHelperRunning(check)
        }
        if let read = s.deckProfiles {
            if read != deckProfiles { deckProfiles = read }
            // Plain values set here, in the pass's finish, never from a view (see the MenuBarExtra gotcha).
            if let d = s.deckDisk, !d.health.isBroken { deckRepairFailed = false }
            if let choice = setup.deckProfile {
                let check = deckProfileCheck(choice: choice, read: read, preferred: s.deckPreferred, prefsProblem: s.deckPrefsProblem,
                                             writeFailed: deckProfileWriteFailed, disk: s.deckDisk, repairFailed: deckRepairFailed)
                out.append(check)
                diagDeckProfile(choice: choice, read: read, preferred: s.deckPreferred, check: check)
            }
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
        out.append(screenCheck(held: s.screenKeptOn, onAC: s.onAC))

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
        out.append(reopenAppsCheck(s.reopensApps))

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
        if lightkeyNoPassword != s.lightkeyNoPassword { lightkeyNoPassword = s.lightkeyNoPassword }
        offForThisMac = out.count - relevantChecks.count
        mutedChecks = relevantChecks.filter { muted.contains($0.id) }
        checks = relevantChecks.filter { !muted.contains($0.id) }
        diagPass(pass.entries, checks)
        lastPass = pass.entries
        lastChecked = Date()
        if deckApp != nil && s.deckAsksToRestore {
            reportError("StreamDeckRestoreDialog", "Stream Deck is asking whether to restore its backup from today (its log: \u{201C}Detected data loss - propose restore backup to user\u{201D}); its keys don\u{2019}t work until someone answers.")
        }
        confirmLoginRepairs(pass: number)
        settleStartUp()         // first, so turning green is still logged as a step
        syncCheckStep()
    }

    /// While the finished start-up's panel is up, its "Check everything" step follows each pass, so it
    /// says the same number as the panel's heading (`checkStepWords`). Written only when it changes.
    private func syncCheckStep() {
        guard bootFinished, !starting, BootPanel.shared.isShowing, let last = bootSteps.indices.last,
              bootSteps[last].id == "check", bootSteps[last].state != .waiting, bootSteps[last].state != .running else { return }
        let words = checkStepWords(problems: problemCount)
        guard bootSteps[last].state != words.state || bootSteps[last].detail != words.detail else { return }
        bootSteps[last].state = words.state
        bootSteps[last].detail = words.detail
    }

    /// A start-up can finish with warnings and be fine a minute later, say once Lightkey has the DMX
    /// interface after the password. The panel used to stay up saying "Started, with warnings" for
    /// good (church Mac, 3 Oct 2026). So once nothing needs fixing, turn the last step green and let
    /// the panel go, as an all-green start-up does.
    private func settleStartUp() {
        guard startUpSettles(finished: bootFinished, running: starting, alreadySettled: bootSettled, problems: problemCount),
              BootPanel.shared.isShowing, let last = bootSteps.indices.last, bootSteps[last].id == "check" else { return }
        bootSettled = true
        if bootSteps[last].state != .done { setStep(last, .done, checkStepWords(problems: 0).detail) }
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
            // macOS ties the permission to the app's signature. Builds before 1.21 were signed ad hoc, a
            // new signature every time, so after an update the old entry stayed switched on in the list
            // but didn't count (church Mac, 9 Oct 2026).
            return Check(id: "show", group: "Lighting", title: title, status: .unknown,
                         detail: "Booth Check needs permission to read Lightkey's window title.",
                         fix: "Ask a tech: click Allow access\u{2026} and switch Booth Check on in the list (README, \u{201C}Putting it on the booth Mac\u{201D}, step 5).",
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
                         fix: "Click Open the show to open the chosen one (if that other copy is the right one, ask a tech to choose it with Change\u{2026}).",
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
        case .lightkeyNoPassword:
            let args = lightkeyPasswordCommand(on: true)
            pending = PendingChange(
                key: "lkpass", title: "Lightkey without the password",
                explanation: "Lightkey normally unloads the Mac\u{2019}s FTDI driver before it takes the DMX interface, and that needs the Mac\u{2019}s password (Authenticate). This hidden Lightkey setting skips that step. On the church Mac, with its Open DMX USB, the lights work with it on and nothing asks (9 Oct 2026). It\u{2019}s saved in Lightkey\u{2019}s settings for this account and survives restarts. Quit Lightkey first, or it applies from the next time Lightkey opens. If the lights ever stop working, run the undo command. No password needed.",
                language: "Terminal", code: commandLine("/usr/bin/defaults", args),
                undo: commandLine("/usr/bin/defaults", lightkeyPasswordCommand(on: false)),
                run: { shell("/usr/bin/defaults", args) })
            return
        case .stopReopeningApps, .removeLoginItem, .removeShowLoginItems, .addSelfToLogin:
            pending = loginChange(for: action)
            return
        case .reconnectDMX(let pid):
            let args = ["-HUP", String(pid)]
            pending = PendingChange(
                key: "dmxReconnect", title: "Reconnect the lights",
                explanation: "Sends a hang-up signal to olad (pid \(pid)), Lightkey\u{2019}s DMX server: it asks Lightkey\u{2019}s DMX server to look for the interface again (olad reloads its plugins and scans USB once more). The lights should not change. Booth Check first checks that pid \(pid) is still Lightkey\u{2019}s olad, and sends nothing if it has changed. Booth Check shows a sign while it checks for about 12 seconds; if this row is still red afterwards, it offers Restart Lightkey instead. No password needed.",
                language: "Terminal", code: commandLine("/bin/ps", psDMXArgs) + "   # still Lightkey\u{2019}s olad?\n" + commandLine("/bin/kill", args),
                run: { let r = signalOladIfStill("-HUP", pid: pid, orphan: false); return (r.out, r.code) })
            return
        case .restartLightkeyForDMX:
            pending = PendingChange(
                key: "dmxRestart", title: "Restart Lightkey",
                explanation: "The lights go dark for about 20 seconds. Booth Check quits Lightkey (it presses Quit if Lightkey asks, and makes it quit after 15 seconds, so changes to the show since it opened aren\u{2019}t saved, as with Don\u{2019}t Save), stops Lightkey\u{2019}s DMX server if it\u{2019}s still running, then runs Get the show started: Lightkey, its MIDI input, Stream Deck restarted, then the show. Each step goes in the Log, and a sign says what\u{2019}s happening. No password needed.",
                language: "Booth Check steps", code: dmxRestartStepsText(), run: { ("Restarting Lightkey now. Each step goes in the Log.", 0) })
            return
        case .restartDeckHelper:
            let args = deckHelperRestartArgs()
            pending = PendingChange(
                key: "deckHelper", title: "Restart the deck lights helper",
                explanation: "Asks macOS\u{2019}s launchd to stop the deck lights helper and start it again straight away. Its \u{201C}\(IDs.deckFeedback)\u{201D} MIDI port comes back within a few seconds, and the Stream Deck picks it up by itself, so Stream Deck doesn\u{2019}t need restarting. The helper only listens to Lightkey; it sends nothing to it, so the lights don\u{2019}t change. No password needed.",
                language: "Terminal", code: commandLine("/bin/launchctl", args),
                run: { shell("/bin/launchctl", args) })
            return
        case .installDeckHelper:
            guard let source = deckHelperBundled, let sha = deckHelperBundledSHA else {
                message = "This copy of Booth Check doesn\u{2019}t carry the deck lights helper."
                return
            }
            let args = helperArgsInUse
            let script = deckHelperInstallScript(from: source, args: args)
            pending = PendingChange(
                key: "deckInstall", title: "Install the deck lights helper",
                explanation: "Copies the helper Booth Check carries (version \(sha.prefix(8))) to this Mac and hands it to macOS\u{2019}s launchd for this account, which starts it now and at every login, and restarts it within 2 seconds whenever it stops. Any older copy is stopped and replaced. It publishes the \u{201C}\(IDs.deckFeedback)\u{201D} MIDI port the deck\u{2019}s key lights follow, and sends nothing to Lightkey. Then Booth Check watches it start (a few seconds), and restarts Stream Deck if it\u{2019}s open, so the keys pick the new port up. No password needed. Its rules for this show: "
                    + (args.isEmpty ? "none (the helper\u{2019}s defaults)" : args.joined(separator: " "))
                    + (deckShow?.helperFromFile == true ? ", from the show\u{2019}s .deck.json." : ", the built-in ones."),
                language: "Terminal", code: script,
                undo: commandLine("/bin/launchctl", deckHelperStopArgs()) + "; rm " + commandLine(deckHelperPlist, []),
                run: { runDeckHelperInstall(script, args: args) })
            return
        case .startDeckHelper:
            let args = deckHelperStartArgs()
            pending = PendingChange(
                key: "deckHelper", title: "Start the deck lights helper",
                explanation: "Hands the helper a tech installed to macOS\u{2019}s launchd for this account, which starts it now and at every login, and restarts it if it ever stops. It publishes the \u{201C}\(IDs.deckFeedback)\u{201D} MIDI port the deck\u{2019}s key lights follow, and sends nothing to Lightkey. No password needed.",
                language: "Terminal", code: commandLine("/bin/launchctl", args),
                undo: commandLine("/bin/launchctl", deckHelperStopArgs()),
                run: { shell("/bin/launchctl", args) })
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
        case .switchDeckProfile(let device, let target, let from, let name):
            let fromName = deckProfiles.profiles.first { $0.uuid == from }.map { "\u{201C}\($0.name)\u{201D}" } ?? "the profile it\u{2019}s on now"
            pending = PendingChange(
                key: "deckProfile", title: "Put Stream Deck on \u{201C}\(name)\u{201D}",
                explanation: "Stream Deck closes for a few seconds and its keys go dark meanwhile; then it opens again in the background on \u{201C}\(name)\u{201D} instead of \(fromName). Booth Check changes the one setting Stream Deck reads at start for which profile this deck shows, only while Stream Deck is closed, and leaves everything else in its settings as it is. About 10 seconds after Stream Deck opens, Booth Check reads it back: if Stream Deck put its old choice back, the row says how to choose the profile in Stream Deck instead. No password needed. Each step goes in the Log.",
                language: "Booth Check steps", code: deckProfileSwitchSteps(device: device, to: target),
                undo: deckProfileSwitchSteps(device: device, to: from),
                run: {
                    DispatchQueue.main.async { self.switchDeckProfile(device: device, to: target, name: name, during: "Switch the profile") { _ in } }
                    return ("Switching now. Each step goes in the Log.", 0)
                })
            return
        case .acceptDeckProfile:
            guard let choice = setup.deckProfile, case .found(let p, _) = matchDeckProfile(choice, in: deckProfiles.profiles) else { return }
            setup.deckProfile = DeckProfileChoice(p)
            logSetting("This Mac: \u{201C}\(p.name)\u{201D} kept as it is now",
                       "Its keys changed since it was chosen (keys \(choice.sigHash) \u{2192} \(p.sigHash)); Booth Check now expects them as they are.")
        case .restoreDeckProfile(let uuid, let name):
            let store = DeckCopyStore(root: deckBackupsRoot, uuid: uuid)
            guard let copy = store.good else {
                message = "Booth Check has no copy of \u{201C}\(name)\u{201D} yet: import its .streamDeckProfile file again in Stream Deck."
                return
            }
            let folder = deckProfiles.folder ?? streamDeckSupportDir + "/ProfilesV3"
            pending = PendingChange(
                key: "deckRestore", title: "Put back the Stream Deck\u{2019}s keys (\u{201C}\(name)\u{201D})",
                explanation: "Stream Deck closes for a few seconds and its keys go dark meanwhile. Booth Check puts back its copy of \u{201C}\(name)\u{201D} from \(deckCopyDateText(copy.savedAt)), the last time it found the profile healthy, resets its saved key lights and opens Stream Deck again in the background; about 10 seconds later it checks the profile is still healthy. Nothing is deleted: the profile as it is now is moved aside into Booth Check\u{2019}s folder. No password needed. Each step goes in the Log.",
                language: "Booth Check steps", code: deckRestoreSteps(name: name, copy: copy, profilesFolder: folder, store: store),
                undo: "Quit Stream Deck, then move the folder kept in \(store.setAside)/<date and time>/\(copy.folder) back into \(folder) in place of the restored one, and open Stream Deck.",
                run: {
                    DispatchQueue.main.async { self.restoreDeckProfileByHand(uuid: uuid, name: name) }
                    return ("Putting the keys back now. Each step goes in the Log.", 0)
                })
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

    /// The change sheets of the login rows (Booth Check at login, shows and Stream Deck opening by
    /// themselves, macOS reopening old apps). A login start-up runs the very same changes by itself
    /// (`repairLoginAtStartUp`), so each is defined once.
    func loginChange(for action: Action) -> PendingChange? {
        switch action {
        case .stopReopeningApps:
            let off = reopenAppsCommands(reopen: false), on = reopenAppsCommands(reopen: true)
            return PendingChange(
                key: "reopen", title: "Don\u{2019}t reopen old apps at start-up",
                explanation: "Switches off macOS reopening the apps that were open at shutdown (the \u{201C}Reopen windows when logging back in\u{201D} tick when you shut down from the Apple menu). They\u{2019}d open before Booth Check\u{2019}s start-up and in no order, Lightkey included. Booth Check still opens what this Mac needs, in order. It applies from the next shutdown, for this account. No password needed.",
                language: "Terminal",
                code: off.map { commandLine("/usr/bin/defaults", $0) }.joined(separator: "\n"),
                undo: on.map { commandLine("/usr/bin/defaults", $0) }.joined(separator: "\n"),
                run: {
                    var outs: [String] = [], code: Int32 = 0
                    for args in off {
                        let r = shell("/usr/bin/defaults", args)
                        outs.append("$ " + commandLine("/usr/bin/defaults", args) + (r.out.isEmpty ? "" : "\n" + r.out))
                        if r.code != 0 { code = r.code }
                    }
                    return (outs.joined(separator: "\n"), code)
                })
        case .removeLoginItem(let item):
            let script = removeLoginItemScript(item.path)
            return PendingChange(
                key: "removeLogin", title: "Stop \(item.name) opening at login",
                explanation: "Removes \(item.name) from the login items, so it no longer opens when the Mac starts. \(item.name) itself isn\u{2019}t deleted, and you can add it back in System Settings \u{2192} General \u{2192} Login Items.",
                language: "AppleScript", code: script, undo: addLoginItemScript(item.path), run: { runAppleScript(script) })
        case .removeShowLoginItems:
            let script = removeShowLoginItemsScript
            let shows = loginItems.filter(\.isShow)
            return PendingChange(
                key: "removeShows", title: "Stop shows opening at login on their own",
                explanation: "Removes every Lightkey show from the login items. Booth Check opens the chosen show itself at login, in the right order. The show files aren\u{2019}t touched.",
                language: "AppleScript", code: script,
                undo: shows.isEmpty ? nil : shows.map { addLoginItemScript($0.path) }.joined(separator: "\n\n"),
                run: { runAppleScript(script) })
        case .addSelfToLogin:
            let script = addLoginItemScript(Bundle.main.bundleURL.path)
            return PendingChange(
                key: "selfLogin", title: "Open Booth Check at login",
                explanation: "Adds Booth Check to the login items, so it opens by itself after a restart and checks everything straight away.",
                language: "AppleScript", code: script, undo: removeLoginItemScript(Bundle.main.bundleURL.path), run: { runAppleScript(script) })
        default:
            return nil
        }
    }

    /// A login start-up, once its apps are open (Nov 2026, owner-approved exception to "changes wait for
    /// you"): the login rows `startUpLoginRepairs` picks are fixed with their own change sheet's command,
    /// off the main thread (AppleScript then goes through osascript, see `runAppleScript`), so a slow or
    /// asking System Events never holds anything up. Only when the last pass could read the login items
    /// (System Events allowed); otherwise the rows stay as they are. Each run is logged with its command,
    /// output and undo; the next pass confirms it (`confirmLoginRepairs`). Takes effect at the next login.
    func repairLoginAtStartUp() {
        guard case .items = loginRead else { return }
        let ids = startUpLoginRepairs(checks, selfInApplications: Bundle.main.bundlePath.hasPrefix("/Applications/"))
        let fixes = ids.compactMap { id in checks.first { $0.id == id }?.action.flatMap(loginChange).map { (id, $0) } }
        guard !fixes.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let results = fixes.map { (id: $0.0, change: $0.1, result: $0.1.run()) }
            DispatchQueue.main.async {
                for r in results {
                    self.changes.insert(LogEntry(title: "Start-up: fixed by itself: \(r.change.title)", language: r.change.language,
                                                 code: r.change.code,
                                                 output: (r.result.out.isEmpty ? "(no output)" : r.result.out)
                                                    + "\nIt takes effect from the next login. Booth Check checks it at the next pass."
                                                    + (r.change.undo.map { "\nUndo:\n" + $0 } ?? ""),
                                                 status: r.result.code), at: 0)
                }
                self.loginRepairsToConfirm = (results.map(\.id), self.passesStarted, Dictionary(results.map { ($0.id, $0.result.code) }) { a, _ in a })
                self.refresh()
            }
        }
    }

    /// The first pass after the start-up's login fixes ran: did each row turn OK? Logged, and one
    /// `self_repair` event each (result ok, not_confirmed, or failed when its command did).
    func confirmLoginRepairs(pass number: Int) {
        guard let r = loginRepairsToConfirm, number > r.after else { return }
        loginRepairsToConfirm = nil
        var lines: [String] = []
        for id in r.ids {
            let row = checks.first { $0.id == id }
            let ok = row?.status == .ok
            let result = r.ran[id] != 0 ? "failed" : ok ? "ok" : "not_confirmed"
            lines.append("\(row?.title ?? id): " + (ok ? "OK now." : "still \(row.map { statusWord($0.status) } ?? "not shown")" + (r.ran[id] != 0 ? " (its command failed)." : ".")))
            diagEvent("self_repair", ["what": .string("login_\(id)"), "why": .string("login start-up"), "result": .string(result)])
        }
        changes.insert(LogEntry(title: "Start-up: checked the login fixes", language: "Booth Check", code: "The next check pass",
                                output: lines.joined(separator: "\n"), status: lines.allSatisfy { $0.hasSuffix("OK now.") } ? 0 : 1), at: 0)
    }

    /// Runs an approved change, logs it, and returns the log entry for the sheet to show.
    func run(_ change: PendingChange) -> LogEntry {
        let r = change.run()
        let entry = LogEntry(title: change.title, language: change.language, code: change.code,
                             output: r.out.isEmpty ? "(no output)" : r.out, status: r.code)
        changes.insert(entry, at: 0)
        person("run", row: pendingRow, ["key": .string(change.key), "code": .int(Int(r.code))])
        if let row = pendingRow?.id { tallyAction(&tally, row: row, what: "run:\(change.key)", at: sessionNow) }
        if change.key == "appnap", r.code == 0 { appNapSwitchedOffAt = Date() }
        if change.key == "lkpass", r.code == 0 { setup.noPasswordWanted = true }
        if change.key == "dmxReconnect", r.code == 0 { watchDMXReconnect() }
        if change.key == "dmxRestart" { DispatchQueue.main.async { self.restartLightkeyForDMX() } }
        if change.key == "deckInstall", r.code == 0 {
            if setup.deckLights != true {
                setup.deckLights = true
                logSetting("This Mac: deck lights helper installed", "Booth Check now checks it\u{2019}s running.")
            }
            // A new copy makes a new port: a fresh Stream Deck connects to it for sure.
            if isRunning(IDs.streamDeck) && !starting && !shuttingDown {
                restartStreamDeck(during: "Deck lights helper installed") { _ in }
            }
        }
        return entry
    }

    func finishChange() {
        pending = nil
        pendingRow = nil
        refresh()
    }

    /// Cancel on the change sheet: nothing ran.
    func cancelChange(_ change: PendingChange) {
        person("cancel", row: pendingRow, ["key": .string(change.key)])
        finishChange()
    }

    /// A row's Fix button (Reconnect the lights…, Restart Lightkey…, Install…): the person event, the
    /// row's tally, then the action as before.
    func rowAction(_ check: Check, _ action: Action) {
        let row = (id: check.id, title: check.title, status: statusWord(check.status))
        pendingRow = row
        person("fix", row: row, ["button": .string(action.label)])
        tallyAction(&tally, row: check.id, title: check.title, what: "fix:\(action.label)", at: sessionNow)
        perform(action)
    }

    /// Check again, from the window or the menu.
    func checkAgain() {
        person("check_again", ["problems": .int(problemCount)])
        refresh()
    }

    /// Get the show started, clicked: the rows not OK now are put down to it if they clear.
    func startShowByHand() {
        guard !starting else { return }
        person("start_show", ["problems": .int(problemCount)])
        let at = sessionNow
        for c in checks where statusIsBad(c.status) { tallyAction(&tally, row: c.id, title: c.title, what: "startup", at: at) }
        startShow(byHand: true)
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
        if lastChecked == nil { return ("hourglass", checkingNote) }
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
                thingsToFix(problemCount))
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
        keepScreenOn()
        refresh()
        watchFirstPass()
        armShutdown()
        watchPower()
        watchLightkeyLaunches()
        checkForUpdates(userInitiated: false)
        let checks = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
        let updates = Timer(timeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            self?.checkForUpdates(userInitiated: false)
        }
        for t in [checks, updates] { RunLoop.main.add(t, forMode: .common) }
        timers = [checks, updates]
    }

    /// Every 5 s until the first pass is in: past 30 s, the header says what it's waiting for, and the
    /// Log says so once. (On the main thread: the pass's main-thread part, AppleScript included, can
    /// only be named by what it read last.)
    func watchFirstPass() {
        let began = Date()
        var logged = false
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            guard self.lastChecked == nil else { self.checkingNote = "Checking\u{2026}"; return timer.invalidate() }
            let waited = Date().timeIntervalSince(began)
            let what = PassProgress.shared.now ?? (self.busy ? "the checks that run on the main thread" : "the next check pass")
            let note = checkingTitle(waited: waited, waitingFor: what)
            if note != self.checkingNote { self.checkingNote = note }
            if waited >= 30 && !logged {
                logged = true
                self.changes.insert(LogEntry(title: "The first check is taking long", language: "Booth Check", code: "Waiting for: \(what)",
                                             output: note, status: 1), at: 0)
            }
        }
        RunLoop.main.add(t, forMode: .common)
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
        case "dmx", "dmxLive", "lkpass": return s.lightkey && s.dmx
        case "midi": return s.lightkey && s.streamDeck
        case "deck", "deckapp", "nap": return s.streamDeck
        // Undecided counts too (1.27): a Mac that hasn't got the helper yet shows the row red with Install…
        // A show whose .deck.json says "helper": null doesn't use it (1.32).
        case "deckLights": return s.lightkey && s.streamDeck && s.deckLights != false && showUsesHelper
        case "deckProfile": return s.streamDeck && s.deckProfile != nil
        case "ac", "sleep", "screen", "lpm", "autoboot", "upd", "lock", "reopen": return s.alwaysOn
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
        person("mute", row: (check.id, check.title, statusWord(check.status)))
        tallyAction(&tally, row: check.id, title: check.title, what: "mute", at: sessionNow)
        persistTally()
        muted.insert(check.id)
        logSetting("Muted \u{201C}\(check.title)\u{201D}", "It stays listed under Muted on this Mac, with an Unmute button.")
    }

    func unmute(_ check: Check) {
        person("unmute", row: (check.id, check.title, statusWord(check.status)))
        tallyAction(&tally, row: check.id, title: check.title, what: "unmute", at: sessionNow)
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

    /// This Mac's "Profile for the service" picker: a profile's UUID, or "" for Don't check.
    func chooseDeckProfile(_ tag: String) {
        if tag == "missing" { return }
        if tag.isEmpty {
            guard setup.deckProfile != nil else { return }
            setup.deckProfile = nil
            logSetting("This Mac: Stream Deck profile not checked", "Booth Check no longer checks which profile Stream Deck is on, or switches it at the start-up.")
            return
        }
        guard let p = deckProfiles.profiles.first(where: { $0.uuid == tag }), setup.deckProfile != DeckProfileChoice(p) else { return }
        setup.deckProfile = DeckProfileChoice(p)
        logSetting("This Mac: Stream Deck profile for the service: \u{201C}\(p.name)\u{201D}",
                   "\(deckProfileHint(p, among: deckProfiles.profiles)); keys \(p.sigHash), profile \(p.uuid), deck \(p.device). Booth Check checks Stream Deck is on it, and puts it on it at the start-up while Stream Deck is closed.")
    }

    /// Booth Check's own settings go in the Log too, so a silenced check can always be traced.
    func logSetting(_ title: String, _ output: String) {
        changes.insert(LogEntry(title: title, language: "Booth Check setting", code: title, output: output, status: nil), at: 0)
        diagEvent("setting", ["key": .string(title), "value": .string(output)])
    }
}

// MARK: - The menu bar icon (1.30)

/// "NSStatusItem Visible …" keys found false and cleared at launch (see `BoothCheckApp.init`).
var clearedStatusItemKeys: [String] = []

extension Booth {
    /// At launch: the icon is inserted, and any saved setting that hid it was cleared.
    func logMenuIconLaunch() {
        changes.insert(LogEntry(title: "Menu bar icon: put in the menu bar at launch", language: "macOS API",
                                code: "MenuBarExtra(isInserted: true); UserDefaults: remove any \u{201C}NSStatusItem Visible \u{2026}\u{201D} key set to false",
                                output: clearedStatusItemKeys.isEmpty ? "No saved setting hid it."
                                    : "Cleared: " + clearedStatusItemKeys.joined(separator: ", ") + " (it had been dragged off the menu bar).",
                                status: 0), at: 0)
    }

    /// The icon was taken out (⌘-dragged off the menu bar): put it straight back, and say so.
    func keepMenuIcon() {
        DispatchQueue.main.async {
            guard !self.menuIconInserted, !self.reinsertingIcon else { return }
            self.menuIconInserted = true
            self.diagEvent("self_repair", ["what": .string("menu_icon"), "why": .string("taken out of the menu bar"), "result": .string("put back")])
            self.changes.insert(LogEntry(title: "Menu bar icon: put back", language: "macOS API",
                                         code: "MenuBarExtra isInserted false \u{2192} true",
                                         output: "The icon had been taken out of the menu bar, so Booth Check put it back.",
                                         status: 0), at: 0)
        }
    }

    /// Read-only, each 15-second pass: is Booth Check's own status bar window there, sized and on a
    /// screen? Logged only when that changes. Missing two passes running, it's re-inserted once.
    func watchMenuIcon() {
        let (shown, about) = menuIconState()
        let r = iconPass(iconWatch, shown: shown)
        iconWatch = r.watch
        if r.log {
            changes.insert(LogEntry(title: "Menu bar icon: \(shown ? "shown" : "not shown")", language: "macOS API",
                                    code: "NSApp.windows: Booth Check\u{2019}s NSStatusBarWindow, its frame and screen; CGWindowList: the front app\u{2019}s window sizes",
                                    output: about, status: shown ? 0 : 1), at: 0)
        }
        guard r.reinsert else { return }
        reinsertingIcon = true
        menuIconInserted = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.menuIconInserted = true
            self.reinsertingIcon = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let (back, about) = self.menuIconState()
                self.diagEvent("self_repair", ["what": .string("menu_icon"), "why": .string("missing two checks running"), "result": .string(back ? "shown" : "still missing")])
                self.changes.insert(LogEntry(title: "Menu bar icon: re-inserted (missing two checks running)", language: "macOS API",
                                             code: "MenuBarExtra isInserted true \u{2192} false \u{2192} true",
                                             output: (back ? "Shown again. " : "Still not shown. ") + about, status: back ? 0 : 1), at: 0)
            }
        }
    }

    private func menuIconState() -> (Bool, String) {
        let window = NSApp.windows.first { $0.className.contains("NSStatusBarWindow") }
        let frame = window?.frame ?? .zero
        let shown = menuIconShown(windowFound: window != nil, frame: frame, screens: NSScreen.screens.map(\.frame))
        let front = NSWorkspace.shared.frontmostApplication
        let about = (window == nil ? "No status bar window." : "Frame: \(NSStringFromRect(frame)).")
            + " Screen: " + (window?.screen?.localizedName ?? "none") + "."
            + " Front app: \(front?.localizedName ?? "none"), " + (frontAppFullScreen(front) ? "full screen." : "not full screen.")
        return (shown, about)
    }

    private func frontAppFullScreen(_ app: NSRunningApplication?) -> Bool {
        guard let pid = app?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let sizes = list.compactMap { w -> CGSize? in
            guard (w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b) else { return nil }
            return rect.size
        }
        return coversAScreen(sizes, screens: NSScreen.screens.map(\.frame.size))
    }
}

// MARK: - Timing and getting the show started

extension Booth {
    /// Called by the 15-second timer. Holds off while a change is waiting for approval.
    func tick() {
        watchMenuIcon()
        keepScreenOn()
        LightkeyOutputWatch.shared.keepListening(setup.lightkey)
        if pending == nil { refresh() }
        checkShutdownTime()
        checkPower()
        keepStreamDeckOpen()
    }

    /// The start-up order, as numbered steps. The same list is shown in This Mac before anyone
    /// restarts, and ticks off live in the start-up panel while it runs.
    func plannedSteps(checkOnly: Bool = false) -> [BootStep] {
        let apps = setup.apps.filter(\.on)
        let ids = startUpOrder(lightkey: setup.lightkey, dmx: setup.dmx, streamDeck: setup.streamDeck,
                               apps: apps.map { "app:\($0.bundleID)" }, checkOnly: checkOnly,
                               deckLights: setup.deckLights == true && showUsesHelper)
        let show = showName.map { ($0 as NSString).deletingPathExtension }
        return ids.map { id in
            let title: String
            switch id {
            case "dmxWait": title = "Wait for the DMX interface"
            case "lightkeyApp": title = "Open Lightkey"
            case "midi": title = "Wait for Lightkey to be ready for the Stream Deck"
            case "deckLights": title = "Wait for the deck lights helper"
            case "deck": title = "Open Stream Deck in the background"
            case "lightkey": title = show.map { "Open \($0) in Lightkey" } ?? "Open Lightkey"
            case "dmxLink": title = "Lightkey connects to the DMX interface"
            case "check": title = "Check everything"
            default: title = "Open " + (apps.first { "app:\($0.bundleID)" == id }?.name ?? id)
            }
            return BootStep(id: id, title: title)
        }
    }

    /// 1.30: at login, writes to the Log which apps with a Dock icon were already open as Booth Check
    /// started (macOS reopening the apps open at shutdown, see `reopenAppsCheck`). Log only; nothing is quit.
    func logAppsOpenAtLogin() {
        let running = NSWorkspace.shared.runningApplications
        let info: [RunningAppInfo] = running.map { ($0.bundleIdentifier, $0.localizedName ?? $0.bundleIdentifier ?? "pid \($0.processIdentifier)", $0.activationPolicy == .regular) }
        let open = otherRegularApps(info, selfID: Bundle.main.bundleIdentifier, skip: ["com.apple.finder"]).map { info[$0].name }
        lightkeyReopenedByMacOS = isRunning(IDs.lightkey)
        diagEvent("apps_open_at_login", ["apps": .string(open.joined(separator: ",")), "lightkey_reopened": .int(lightkeyReopenedByMacOS ? 1 : 0)])
        changes.insert(LogEntry(title: "Start-up: apps already open when the start-up began", language: "macOS API",
                                code: "NSWorkspace: list the running apps with a Dock icon (not Finder, not Booth Check)",
                                output: (open.isEmpty ? "None." : "Already open when the start-up began: " + open.joined(separator: ", ") + ".")
                                    + (lightkeyReopenedByMacOS
                                       ? "\nLightkey was already running before the start-up: macOS reopened it at login, not Booth Check. The start-up\u{2019}s Lightkey steps say \u{201C}Already open\u{201D}."
                                       : ""),
                                status: nil), at: 0)
    }

    /// Runs the start-up steps in order, shown live in a small panel that floats over everything,
    /// full-screen Lightkey included. Opens apps only; changes no settings. `checkOnly` is the
    /// login path on a Mac that doesn't start the show: just check, and show the result. `atLogin`
    /// is the start-up that runs by itself at login, which also puts up the hands-off sign.
    func startShow(checkOnly: Bool = false, atLogin: Bool = false, byHand: Bool = false) {
        guard !starting else { return }
        starting = true
        bootByHand = byHand
        bootCheckOnly = checkOnly
        bootPeople = 0
        bootStartedUptime = ProcessInfo.processInfo.systemUptime
        stepStartedUptime = [:]
        authAskingSince = nil
        authWaitTotal = 0
        bootFinished = false
        bootSettled = false
        bootSteps = plannedSteps(checkOnly: checkOnly)
        if !atLogin && !checkOnly { lightkeyReopenedByMacOS = false }   // only the login start-up's own find
        signOn = startUpShowsSign(atLogin: atLogin, steps: bootSteps.map(\.id))
        signLightkeyOpened = isRunning(IDs.lightkey)       // reopened by macOS, it may be asking already
        signDMXLinked = false
        bootStartedAt = Date()
        lastDeckProfileDiag = nil           // deck_profile goes once per start-up (and on change)
        bootTimeline = []
        lightkeyRunningAtStart = isRunning(IDs.lightkey)
        bootAtLogin = atLogin
        dmxFirstSeen = nil
        dmxSeenAtStart = false
        dmxLadder = DMXLadder()
        dmxSuspect = false
        diagReplugShown = false
        frontAttempts = 0
        lastFront = nil
        SignOverlay.shared.setAsking(false)
        lightkeyOpenedByStartUp = false
        midiRelaunched = false
        startStateMark = nil
        startStateLate = false
        if atLogin { putBackNoPasswordSetting() }
        lightkeyMayAsk = setup.lightkey && setup.dmx
            && !defaultsSaysOn(shell("/usr/bin/defaults", ["read", IDs.lightkey, "DontUnloadFTDIDrivers"]).out)
        ReplugOverlay.shared.onHide = { [weak self] in self?.updateSign() }
        BootPanel.shared.show(steps: bootSteps.count)
        runStep(0)
    }

    /// Keeps the hands-off sign in step with the start-up (see `startSign`). Called when a step starts
    /// and when the replug sign comes or goes; Lightkey holding the DMX interface counts from the next step.
    private func updateSign() {
        guard signOn, starting, !workingSignUp else { return }
        let sign = startSign(replugShowing: ReplugOverlay.shared.isShowing, asksPassword: lightkeyMayAsk,
                             lightkeyOpened: signLightkeyOpened, dmxLinked: signDMXLinked)
        let step = bootSteps.firstIndex { $0.state == .running }
            .map { "Step \($0 + 1) of \(bootSteps.count): \(bootSteps[$0].title)" }
        SignOverlay.shared.show(sign, step: step ?? "", show: showName.map { ($0 as NSString).deletingPathExtension })
    }

    /// Someone wants the screen (Open Booth Check, or Hide on the start-up panel), so the hands-off sign
    /// goes for the rest of this start-up. The start-up itself carries on.
    func dismissStartSign() {
        guard signOn else { return }        // the shutdown's countdown uses the same sign
        signOn = false
        SignOverlay.shared.hide()
    }

    private func setStep(_ i: Int, _ state: StepState, _ detail: String? = nil) {
        guard i < bootSteps.count else { return }
        bootSteps[i].state = state
        if let detail { bootSteps[i].detail = detail }
        let at = bootStartedAt.map { String(format: "+%6.1f s", Date().timeIntervalSince($0)) } ?? "?"
        bootTimeline.append("\(at)  \(i + 1). \(bootSteps[i].title): \(state)" + (detail.map { " \u{2014} \($0)" } ?? ""))
        let up = ProcessInfo.processInfo.systemUptime
        if state == .running {
            if stepStartedUptime[i] == nil { stepStartedUptime[i] = up }
        } else {
            changes.insert(LogEntry(title: "Start-up \(i + 1): \(bootSteps[i].title)", language: "Start-up",
                                    code: bootSteps[i].title, output: bootSteps[i].detail ?? "Done.",
                                    status: state == .done ? 0 : 1), at: 0)
            let began = stepStartedUptime.removeValue(forKey: i) ?? up
            diagEvent("startup_step", ["step": .string(bootSteps[i].id), "n": .int(i + 1),
                                       "result": .string(state == .done ? "done" : state == .warn ? "warn" : "failed"),
                                       "seconds": .double(((up - began) * 10).rounded() / 10),
                                       "at_s": .double(((up - (bootStartedUptime ?? up)) * 10).rounded() / 10),
                                       "detail": .string(bootSteps[i].detail ?? "")])
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

    /// Runs step `i`, then `then` (the DMX recovery re-runs Lightkey's steps that way), or else the next step.
    private func runStep(_ i: Int, then: (() -> Void)? = nil) {
        guard i < bootSteps.count else { return finishBoot() }
        let next = then ?? { self.runStep(i + 1) }
        setStep(i, .running)
        let id = bootSteps[i].id
        if id == "lightkey" || id == "lightkeyApp" { signLightkeyOpened = true }
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
            var polls = 0, foundAtOnce = false, seen = DMXPlanes()
            var shownAt: TimeInterval?
            let ask = DispatchWorkItem {
                guard i < self.bootSteps.count, self.bootSteps[i].id == "dmxWait",
                      self.bootSteps[i].state == .running else { return }
                self.setStep(i, .running, "Not found yet: unplug the DMX box\u{2019}s USB cable and plug it back in.")
                ReplugOverlay.shared.show { skipped = true }
                self.diagReplugShown = true
                shownAt = ProcessInfo.processInfo.systemUptime
                self.updateSign()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: ask)
            // Both USB planes (1.30): either one listing it counts.
            poll(for: 90, background: true, {
                polls += 1
                seen = readDMXPlanes().planes
                if polls == 1 && seen.present { foundAtOnce = true }
                return seen.present
            }, stop: { skipped }, done: { ok in
                ask.cancel()
                if ok { ReplugOverlay.shared.found() } else { ReplugOverlay.shared.hide() }
                // The replug card asked a person: how it was answered, and after how long.
                if let shownAt {
                    self.person("replug", ["result": .string(ok ? "found" : skipped ? "skipped" : "timeout"),
                                           "wait_s": .double(((ProcessInfo.processInfo.systemUptime - shownAt) * 10).rounded() / 10)])
                }
                if ok {
                    self.dmxFirstSeen = Date()
                    self.dmxSeenAtStart = foundAtOnce
                    if seen.disagree {
                        self.changes.insert(LogEntry(title: "Start-up: the two USB planes disagree about the DMX interface", language: "Terminal",
                                                     code: commandLine("/usr/sbin/ioreg", ioUSBPlaneArgs) + "\n" + commandLine("/usr/sbin/ioreg", ioServicePlaneArgs),
                                                     output: "The DMX interface was \(seen.text). It counts as found.", status: 0), at: 0)
                    }
                }
                self.setStep(i, ok ? .done : .warn,
                             ok ? "Found on USB." + (seen.disagree ? " (\(seen.text))" : "")
                                : skipped ? "Skipped, so Lightkey opens without it."
                                : "Not found in 90 seconds, so Lightkey opens anyway: unplug the blue DMX box\u{2019}s USB cable and plug it back in now, and Booth Check connects it in a later step.")
                if !ok { self.dmxSnapshot(skipped ? "dmxWait-skipped" : "dmxWait-timeout") }
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
            // Nov 2026: listen (read only) to what Lightkey reports as the show opens: every cue's start
            // state, once. Evidence for the Log and diagnostics (`startStateEvidence`), nothing more.
            markStartState(late: false)
            // A show that was moved or renamed can't be opened, so open Lightkey on its own and say why.
            let showMissing = showPath.map { !FileManager.default.fileExists(atPath: $0) } ?? false
            if !wasRunning && NSWorkspace.shared.urlForApplication(withBundleIdentifier: IDs.lightkey) == nil {
                setStep(i, .failed, "Lightkey isn\u{2019}t installed on this Mac.")
                return next()
            }
            func open() {
                if let showPath = self.showPath, !showMissing {
                    NSWorkspace.shared.open(URL(fileURLWithPath: showPath))
                } else if !wasRunning, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: IDs.lightkey) {
                    NSWorkspace.shared.openApplication(at: url, configuration: .init())
                }
            }
            // Lightkey not open yet: an olad left over from an earlier Lightkey goes first (1.30).
            if wasRunning { open() } else { clearOrphanOlad("Start-up") { open() } }
            // Two different prompts can appear here: Lightkey asking for the Mac's password to take
            // the DMX interface (any Mac), and macOS asking to allow the accessory (Apple silicon only).
            let hints = [lightkeyMayAsk ? "If Lightkey asks, click Authenticate and type the Mac\u{2019}s password." : nil,
                         hasAccessoryPrompt ? "If macOS asks to allow an accessory, click Allow." : nil].compactMap { $0 }
            setStep(i, .running, hints.isEmpty ? nil : hints.joined(separator: " "))
            poll(for: 45, {
                NSRunningApplication.runningApplications(withBundleIdentifier: IDs.lightkey).first?.isFinishedLaunching == true
            }) { ok in
                if ok { self.frontLightkeyIfBehind() }
                if ok && self.startStateMark == nil { self.markStartState(late: true) }     // Lightkey opened with the show: listen now
                if !ok {
                    self.setStep(i, .failed, "Lightkey didn\u{2019}t open within 45 seconds.")
                } else if showMissing {
                    self.setStep(i, .failed, "Can\u{2019}t find \(self.showName ?? "the show"): it was moved, renamed or deleted. Open the show from Lightkey\u{2019}s File menu, then choose it again in Booth Check.")
                } else if let showPath = self.showPath {
                    let reopened = self.lightkeyReopenedByMacOS && !self.bootSteps.contains { $0.id == "lightkeyApp" }
                return self.confirmShowOpen(i, showPath, doneText: !wasRunning ? "Opened."
                                                : reopened ? "Already open (macOS reopened it at login, before the start-up); brought to the front."
                                                : "Already open; brought to the front.",
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
                if ok {
                    self.setStep(i, .done, "Lightkey\u{2019}s MIDI input is ready.")
                    return next()
                }
                // Nov 2026: Stream Deck's plugin looks for the input only when it starts, so opening it
                // now would leave the keys dead all service. A Lightkey this start-up opened (no show,
                // nothing on stage yet) is quit the no-questions way and opened once more.
                guard midiRelaunchAllowed(openedByStartUp: self.lightkeyOpenedByStartUp, alreadyRelaunched: self.midiRelaunched,
                                          shuttingDown: self.shuttingDown),
                      let app = self.bootSteps.firstIndex(where: { $0.id == "lightkeyApp" }), app < i else {
                    self.setStep(i, .warn, "Lightkey\u{2019}s MIDI input isn\u{2019}t there after 45 seconds, so the Stream Deck\u{2019}s keys may not work: click Restart Lightkey\u{2026} in Booth Check.")
                    return next()
                }
                self.midiRelaunched = true
                self.setStep(i, .running, "Lightkey\u{2019}s MIDI input isn\u{2019}t there after 45 seconds: restarting Lightkey once\u{2026}")
                self.changes.insert(LogEntry(title: "Start-up: Lightkey\u{2019}s MIDI input didn\u{2019}t appear, so Booth Check restarts Lightkey once",
                                             language: "macOS API", code: "CoreMIDI: list the MIDI destinations, every 0.5 s, for 45 s",
                                             output: "No \u{201C}\(IDs.lightkeyMIDIInput)\u{201D}. Destinations: "
                                                + { let d = MIDIWatch.shared.destinationNames(); return d.isEmpty ? "(none)" : d.joined(separator: ", ") }()
                                                + ". Lightkey was opened by this start-up without the show, so nothing is on stage: quitting it (Quit pressed if it asks, made to quit after 15 s), clearing any olad left behind, then opening it again and waiting once more.",
                                             status: 1), at: 0)
                self.quitLightkey("Start-up") { closed in
                    guard closed else {
                        self.setStep(i, .warn, "Lightkey\u{2019}s MIDI input isn\u{2019}t there, and Lightkey didn\u{2019}t close for a restart: click Restart Lightkey\u{2026} in Booth Check.")
                        return next()
                    }
                    self.runSteps([app, i], then: next)
                }
            }

        case "deckLights":
            // launchd starts the helper at login, so it's normally up long before this. It must be
            // listening before the show opens and sends every cue's state: not there within 3 s, Booth
            // Check starts it through launchd at once, then waits up to 20 s in all, never for good.
            let started = Date()
            let found = { MIDIWatch.shared.sourceNames().contains { $0.localizedCaseInsensitiveContains(IDs.deckFeedback) } }
            func finish(_ ok: Bool) {
                let sources = MIDIWatch.shared.sourceNames()
                self.changes.insert(LogEntry(title: "Start-up: the deck lights helper\u{2019}s MIDI port", language: "macOS API",
                                             code: "CoreMIDI: list the MIDI sources, every 0.5 s, for up to 20 s",
                                             output: (ok ? "\u{201C}\(IDs.deckFeedback)\u{201D} found after \(String(format: "%.1f", Date().timeIntervalSince(started))) s."
                                                         : "\u{201C}\(IDs.deckFeedback)\u{201D} not there after 20 s.")
                                                + "\nSources: " + (sources.isEmpty ? "(none)" : sources.joined(separator: ", ")),
                                             status: ok ? 0 : 1), at: 0)
                self.setStep(i, ok ? .done : .warn,
                             ok ? "Its \u{201C}\(IDs.deckFeedback)\u{201D} port is there."
                                : "Not there after 20 seconds, so the deck\u{2019}s key lights may not follow Lightkey (presses still work). Opening Stream Deck anyway.")
                next()
            }
            poll(every: 0.5, for: 3, found) { ok in
                if ok { return finish(true) }
                self.kickDeckHelper("Start-up") { _ in
                    self.poll(every: 0.5, for: 17, found) { finish($0) }
                }
            }

        case "dmxLink":
            runDMXLink(i, next: next)

        case "lightkeyApp":
            // Lightkey on its own, so its MIDI ports exist and Stream Deck can connect before the show
            // opens (see `startUpOrder`). Launched without a show it opens none (rig, 9 Oct 2026).
            if isRunning(IDs.lightkey) {
                setStep(i, .done, lightkeyReopenedByMacOS ? "Already open (macOS reopened it at login, before the start-up)." : "Already open.")
                return next()
            }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: IDs.lightkey) else {
                setStep(i, .failed, "Lightkey isn\u{2019}t installed on this Mac.")
                return next()
            }
            // An olad left over from an earlier Lightkey goes first (1.30): the new Lightkey would reuse it.
            clearOrphanOlad("Start-up") {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
                self.poll(for: 45, {
                    NSRunningApplication.runningApplications(withBundleIdentifier: IDs.lightkey).first?.isFinishedLaunching == true
                }) { ok in
                    if ok { self.lightkeyOpenedByStartUp = true }
                    self.setStep(i, ok ? .done : .failed, ok ? "Opened, without the show for now." : "Lightkey didn\u{2019}t open within 45 seconds.")
                    next()
                }
            }

        case "deck":
            // 1.32: the profile that goes with the show, switched in the gap while Stream Deck is closed.
            // Nov 2026: first a broken or missing profile is put back from its last-good copy
            // (`mendDeckProfiles`), so the switch is worked out on the profile as it now is.
            var profileFix: (device: String, target: String, name: String)?
            var wrote: (ok: Bool, text: String)?
            let write = {
                profileFix = self.deckProfileFixNeeded(during: "Start-up")
                guard let f = profileFix else { return }
                self.showWorkingSign(.deckProfileSwitching(f.name))
                wrote = self.setPreferredProfile(device: f.device, to: f.target, name: f.name, during: "Start-up")
            }
            let finish: ((state: StepState, detail: String, opened: Bool)) -> Void = { incoming in
                var result = incoming
                if let f = profileFix {
                    let ok = wrote?.ok == true
                    result.detail += ok ? " Put it on the \u{201C}\(f.name)\u{201D} profile."
                                        : " Couldn\u{2019}t put it on \u{201C}\(f.name)\u{201D}: choose it at the top of Stream Deck\u{2019}s window."
                    if !ok && result.state == .done { result.state = .warn }
                    self.endWorkingSign(ok ? .deckProfileSwitched(f.name) : .deckProfileFailed(f.name), ok: ok)
                    if ok {
                        self.verifyDeckProfile(device: f.device, target: f.target, name: f.name, during: "Start-up") { stuck in
                            self.diagEvent("self_repair", ["what": .string("deck_profile"), "why": .string("Start-up"), "result": .string(stuck ? "ok" : "didn't stick")])
                            self.refresh()
                        }
                    } else {
                        self.diagEvent("self_repair", ["what": .string("deck_profile"), "why": .string("Start-up"), "result": .string("failed")])
                    }
                }
                // When the show comes next, give the plugin a few seconds to connect to Lightkey first,
                // so it's listening when Lightkey sends every cue's state as the show opens. Meanwhile
                // (Nov 2026) Booth Check checks the profile is still healthy once Stream Deck is up
                // (`confirmDeckAfterLaunch`, one automatic retry if it isn't).
                let showNext = self.bootSteps.indices.contains(i + 1) && self.bootSteps[i + 1].id == "lightkey"
                guard result.opened else {
                    self.setStep(i, result.state, result.detail)
                    return next()
                }
                if showNext {
                    self.setStep(i, .running, result.detail + " Giving it a few seconds to connect before the show opens.")
                } else {
                    self.setStep(i, result.state, result.detail)
                    next()
                }
                self.confirmDeckAfterLaunch(during: "Start-up") { ok in
                    guard showNext else { return }
                    self.setStep(i, ok ? result.state : .warn, result.detail
                                 + (ok ? "" : " Its keys may not work: open Booth Check, the Stream Deck row says what to press."))
                    next()
                }
            }
            // Already open (say, left running from before): restart it, so no key stays lit from then.
            if shouldRestartStreamDeck(enabled: true, deckRunning: isRunning(IDs.streamDeck), startUpDeckStep: true,
                                       lightkeyJustLaunched: false, busy: false) {
                setStep(i, .running, "Restarting it so every key starts clean\u{2026}")
                restartStreamDeck(during: "Start-up", whileClosed: write, clearKeys: true, then: finish)
            } else {
                let closed = !isRunning(IDs.streamDeck)
                if closed { mendDeckProfiles(during: "Start-up") }
                write()
                if closed { clearDeckKeyLights(during: "Start-up") }
                finish(openStreamDeckInBackground(during: "Start-up"))
            }

        default:        // "check"
            // A pass already running started before the steps above finished, so wait for the next one
            // (`refresh` keeps the request); at most 90 s, then go by the last pass and say so.
            let fresh = passesStarted + 1
            refresh()
            poll(every: 0.25, for: 90, { self.passesFinished >= fresh }) { ok in
                let words = checkStepWords(problems: self.problemCount)
                self.setStep(i, words.state, words.detail + (ok ? "" : " (The last check took over 90 seconds, so this is from the one before.)"))
                // The login rows a login start-up fixes by itself, off the main thread, after the apps are open.
                if self.bootAtLogin { self.repairLoginAtStartUp() }
                next()
            }
        }
    }

    /// Notes what "Lightkey Output" has reported so far, as the show starts to open (see `startStateEvidence`).
    /// `late`: Lightkey wasn't there to listen to before it opened with the show.
    private func markStartState(late: Bool) {
        LightkeyOutputWatch.shared.keepListening(setup.lightkey)
        guard startStateMark == nil, LightkeyOutputWatch.shared.listening else { return }
        startStateMark = LightkeyOutputWatch.shared.now()
        startStateLate = late
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
            var asking = false
            if AXIsProcessTrusted() {
                let pid = NSRunningApplication.runningApplications(withBundleIdentifier: IDs.lightkey).first?.processIdentifier
                isOpen = pid.map { let (docs, titles) = windowsOf(pid: $0); return showIsOpen(showPath, docs: docs, titles: titles) } ?? false
                asking = pid.map(asksToAuthenticate) ?? false
            }
            SignOverlay.shared.setAsking(asking)
            if AXIsProcessTrusted() { self.noteAuthAsking(asking, during: "show") }
            if asking && !self.lightkeyMayAsk {         // it asks after all, say the setting was reset
                self.lightkeyMayAsk = true
                self.updateSign()
            }
            switch showOpenNext(isOpen: isOpen, waited: Date().timeIntervalSince(started)) {
            case .done:
                self.endAuthWait(asking ? "still_asking" : "answered", during: "show")
                self.setStep(i, .done, doneText)
                next()
            case .notShowing:
                self.endAuthWait(asking ? "still_asking" : "answered", during: "show")
                self.setStep(i, .warn, "\(name) isn\u{2019}t open after 2 minutes. Click Authenticate if Lightkey asks, or open it from File \u{2192} Open Recent.")
                next()
            case .wait:
                self.frontLightkeyIfBehind()
                self.setStep(i, .running, asking
                    ? "Lightkey is asking for the password: tap Authenticate on the Touch Bar (or click it), then type the Mac\u{2019}s password."
                    : "Waiting for \(name)."
                        + (self.lightkeyMayAsk ? " If Lightkey asks, click Authenticate and type the Mac\u{2019}s password." : "")
                        + " Can\u{2019}t see Lightkey? Click its icon in the Dock.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { look() }
            }
        }
        look()
    }

    /// Opens Stream Deck behind everything, App Nap off first: out of sight is exactly what App Nap puts
    /// to sleep, and apps read the setting when they launch, so it takes effect straight away. No
    /// password needed; both go in the Log.
    func openStreamDeckInBackground(during what: String) -> (state: StepState, detail: String, opened: Bool) {
        let napOff = defaultsSaysOn(shell("/usr/bin/defaults", ["read", "-g", "NSAppSleepDisabled"]).out)
        var napSwitched = false
        if !napOff {
            let args = ["write", "-g", "NSAppSleepDisabled", "-bool", "true"]
            let r = shell("/usr/bin/defaults", args)
            changes.insert(LogEntry(title: "\(what): switched App Nap off for Stream Deck", language: "Terminal",
                                    code: commandLine("/usr/bin/defaults", args),
                                    output: r.out.isEmpty ? "(no output)" : r.out, status: r.code), at: 0)
            napSwitched = r.code == 0
            if napSwitched { appNapSwitchedOffAt = Date() }
        }
        if isRunning(IDs.streamDeck) {
            return napSwitched
                ? (.warn, "Already open, but it started before App Nap was switched off. " + quitStreamDeckWords, false)
                : (.done, "Already open.", false)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: IDs.streamDeck) else {
            return (.failed, "Not installed on this Mac.", false)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false                    // Lightkey stays in front, full screen undisturbed
        NSWorkspace.shared.openApplication(at: url, configuration: config)
        lastDeckOpen = Date()
        changes.insert(LogEntry(title: "\(what): opened Stream Deck in the background", language: "macOS API",
                                code: "NSWorkspace.openApplication (Stream Deck, activates = false)",
                                output: napSwitched ? "App Nap was switched off first." : "App Nap is off.", status: 0), at: 0)
        return (.done, napSwitched ? "Switched App Nap off, then opened it in the background, so it keeps running there."
                                   : "Opened in the background. App Nap is off, so it keeps running there.", true)
    }

    /// Quits Stream Deck (made to quit after 5 seconds if it hangs: it has nothing to save), then opens
    /// it again in the background, so every key starts dark (see `shouldRestartStreamDeck`). Logged.
    /// `whileClosed` runs in the gap, once Stream Deck has quit and before it opens again (1.32: the
    /// profile switch, see `setPreferredProfile`).
    /// `clearKeys`: also reset the keys' saved lit state in the gap, after `whileClosed` (so the profile
    /// it resets is the one the deck will show). Only the start-up and the restart after Lightkey starts.
    func restartStreamDeck(during what: String, whileClosed: (() -> Void)? = nil, clearKeys: Bool = false,
                           then finished: @escaping ((state: StepState, detail: String, opened: Bool)) -> Void) {
        // While it's closed on purpose, the 15-second checks mustn't reopen it (`keepStreamDeckOpen`).
        deckRestartsRunning += 1
        let done = { (r: (state: StepState, detail: String, opened: Bool)) in
            self.deckRestartsRunning -= 1
            finished(r)
        }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: IDs.streamDeck)
        apps.forEach { _ = $0.terminate() }
        let started = Date()
        func look() {
            let waited = Date().timeIntervalSince(started)
            if apps.allSatisfy(\.isTerminated) && !isRunning(IDs.streamDeck) {
                changes.insert(LogEntry(title: "\(what): restarted Stream Deck so its keys start clean", language: "macOS API",
                                        code: "NSRunningApplication.terminate (Stream Deck), then open it again",
                                        output: "A key left lit (a colour, a house level) stays lit when Lightkey restarts: the deck can't be told a cue is off."
                                            + (clearKeys ? " Its saved key lights are reset while it's closed (next entry), since Stream Deck brings a key back lit if it was saved lit." : ""),
                                        status: 0), at: 0)
                // Nov 2026: a broken or missing profile is put back first, then the gap's own work,
                // then the last-good copy and the key reset (`clearDeckKeyLights`).
                if clearKeys { mendDeckProfiles(during: what) }
                whileClosed?()
                if clearKeys { clearDeckKeyLights(during: what) }
                let result = openStreamDeckInBackground(during: what)
                return done((result.state, "Restarted it so every key starts clean. " + result.detail, result.opened))
            }
            if waited > 5 { apps.forEach { _ = $0.forceTerminate() } }
            if waited > 15 { return done((.warn, "Couldn\u{2019}t restart it, so keys may still be lit from before. " + quitStreamDeckWords, false)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { look() }
        }
        look()
    }

    /// With Stream Deck closed: keeps a last-good copy of each profile the deck will show
    /// (`deckProfilesToClear`, `snapshotDeckProfile`: only when it's healthy and changed), then resets
    /// the saved lit state of its MIDI keys, so no key comes up lit from the last service and Lightkey
    /// drives them from then on. A profile Booth Check has no copy of as it is now isn't reset. Logged,
    /// with a `deck_keys_cleared` event. Never stops the start-up: anything unexpected is skipped and logged.
    func clearDeckKeyLights(during what: String) {
        var lines: [String] = []
        var keys = 0, pages = 0, profilesDone = 0, skipped = 0
        var ok = true
        if isRunning(IDs.streamDeck) {
            lines.append("Stream Deck is running, so nothing was changed (it keeps its own copy and would write it back).")
            ok = false
        } else {
            let read = readDeckProfiles()
            let prefs = deckPreferredProfiles(readStreamDeckDevices())
            let targets = deckProfilesToClear(choice: setup.deckProfile, read: read, preferred: prefs.preferred)
            if let p = read.problem { lines.append("Can\u{2019}t read the profiles: \(p) Nothing changed."); ok = false }
            else if targets.profiles.isEmpty {
                lines.append("No profile to reset: none is chosen in This Mac and " + (prefs.problem ?? "no deck\u{2019}s preferred profile is installed") + ". Nothing changed.")
            }
            for uuid in targets.missing { lines.append("A deck\u{2019}s preferred profile \(uuid) isn\u{2019}t installed; skipped.") }
            for p in targets.profiles {
                guard let dir = deckProfileFolder(uuid: p.uuid, in: read.folder) else {
                    lines.append("\u{201C}\(p.name)\u{201D}: its folder wasn\u{2019}t found; skipped."); ok = false; continue
                }
                let store = DeckCopyStore(root: deckBackupsRoot, uuid: p.uuid)
                let snap = snapshotDeckProfile(dir: dir, store: store, deckRunning: { self.isRunning(IDs.streamDeck) })
                lines.append(deckSnapshotText(name: p.name, snap, store: store))
                if case .saved(let c, let old) = snap {
                    diagEvent("deck_profile_copy", ["pages": .int(c.pages), "keys": .int(c.keys), "kb": .int(c.bytes / 1024),
                                                    "why": .string(what), "first": .int(old == nil ? 1 : 0)])
                }
                guard snap.copy != nil else {
                    lines.append("\u{201C}\(p.name)\u{201D}: its saved key lights weren\u{2019}t reset, since Booth Check has no copy of it as it is now.")
                    ok = false; skipped += 1; continue
                }
                let results = clearDeckKeyStates(profileDir: dir, deckRunning: { self.isRunning(IDs.streamDeck) })
                lines.append(deckClearText(profile: p, results: results, backupFolder: store.goodDir))
                profilesDone += 1
                for r in results where r.written { keys += r.resets.count; pages += 1 }
                let left = results.filter { $0.skipped != nil }.count
                skipped += left
                if left > 0 { ok = false }
            }
        }
        changes.insert(LogEntry(title: "\(what): kept a copy of the Stream Deck profile and reset its saved key lights" + (keys > 0 ? " (\(keys) key\(keys == 1 ? "" : "s"))" : ""),
                                language: "macOS API",
                                code: "Copy the profile the deck will show to \(deckBackupsRoot)/<profile>/good when it\u{2019}s healthy and changed (one copy, replaced); then in each page\u{2019}s manifest.json: \"State\": 1 \u{2192} 0 on MIDI keys only, nothing else in the file changed; atomic write, only while Stream Deck is closed",
                                output: lines.joined(separator: "\n"), status: ok ? 0 : 1), at: 0)
        diagEvent("deck_keys_cleared", ["why": .string(what), "keys": .int(keys), "pages": .int(pages),
                                        "profiles": .int(profilesDone), "skipped": .int(skipped), "result": .string(ok ? "ok" : "skipped")])
    }

    /// With Stream Deck closed (the start-up, the restart after Lightkey starts, the Restore button):
    /// each profile Booth Check looks after (`deckProfilesToMend`) is checked on disk, and one that's
    /// objectively broken or missing gets its last-good copy back (`deckMendDecision`,
    /// `restoreDeckProfile`), with the sign saying so. A healthy one is left as it is. Logged, with a
    /// `deck_profile_restored` event per restore. Returns the restored profiles' UUIDs.
    @discardableResult
    func mendDeckProfiles(during what: String) -> [String] {
        guard setup.streamDeck else { return [] }
        let read = readDeckProfiles()
        guard let folder = read.folder else { return [] }      // no profiles folder: the row says so
        let prefs = deckPreferredProfiles(readStreamDeckDevices())
        let targets = deckProfilesToMend(choice: setup.deckProfile, read: read, preferred: prefs.preferred,
                                         hasCopy: { DeckCopyStore(root: deckBackupsRoot, uuid: $0).good != nil })
        guard !targets.isEmpty else { return [] }
        var lines: [String] = [], restored: [String] = [], failed = false
        for t in targets {
            let d = deckDiskState(uuid: t.uuid, read: read)
            let store = DeckCopyStore(root: deckBackupsRoot, uuid: t.uuid)
            switch deckMendDecision(health: d.health, hasCopy: d.copy != nil, deckRunning: isRunning(IDs.streamDeck),
                                    automatic: true, restoresSoFar: deckAutoRestores) {
            case .keep:
                lines.append("\u{201C}\(t.name)\u{201D} (\(d.dir)): healthy, left as it is.")
            case .leave(let why):
                lines.append("\u{201C}\(t.name)\u{201D}: \(d.health.why); left alone: \(why).")
                if d.health.isBroken { failed = true }
            case .noCopy:
                lines.append("\u{201C}\(t.name)\u{201D}: \(d.health.why), and Booth Check has no copy of it yet, so it can\u{2019}t put it back. Import its .streamDeckProfile file again in Stream Deck.")
                failed = true
            case .restore:
                showWorkingSign(.deckKeysRestoring)
                let r = restoreDeckProfile(uuid: t.uuid, profilesFolder: folder, store: store, deckRunning: { self.isRunning(IDs.streamDeck) })
                deckAutoRestores += 1
                lines.append("\u{201C}\(t.name)\u{201D}: \(d.health.why). " + r.text)
                if r.ok { restored.append(t.uuid) } else { failed = true }
                if !r.ok { reportError("DeckProfileRestoreFailed", "\(what): couldn\u{2019}t put back the Stream Deck profile \u{201C}\(t.name)\u{201D} (\(d.health.why)): \(r.text)") }
                diagEvent("deck_profile_restored", ["why": .string(d.health.why), "during": .string(what), "how": .string("automatic"),
                                                    "result": .string(r.ok ? "ok" : "failed"), "identical": .int(r.identical ? 1 : 0),
                                                    "pages": .int(d.copy?.pages ?? 0), "keys": .int(d.copy?.keys ?? 0),
                                                    "copy_age_h": .int(Int(Date().timeIntervalSince(d.copy?.savedAt ?? Date()) / 3600))])
                endWorkingSign(r.ok ? .deckKeysRestored : .deckKeysRestoreFailed, ok: r.ok)
            }
        }
        changes.insert(LogEntry(title: "\(what): checked the Stream Deck profile on disk" + (restored.isEmpty ? "" : ", put it back from Booth Check\u{2019}s copy"),
                                language: "macOS API",
                                code: "FileManager: read the profile\u{2019}s manifest.json and Profiles/*/manifest.json; if it\u{2019}s gone, not JSON or a page is missing, and Stream Deck is closed: put back \(deckBackupsRoot)/<profile>/good (copy next to it, check identical, renamex_np RENAME_SWAP, the old one moved to set-aside)",
                                output: lines.joined(separator: "\n"), status: failed ? 1 : 0), at: 0)
        // The deck may have fallen back to another profile while the service one was gone.
        if !restored.isEmpty, what != "Start-up", let f = deckProfileFixNeeded(during: what) {
            setPreferredProfile(device: f.device, to: f.target, name: f.name, during: what)
        }
        return restored
    }

    /// About 10 s after Stream Deck opened (the start-up, the restarts): checks what can be checked
    /// without a person (it's running, the deck is seen, the service profile is still healthy on disk,
    /// the deck is still on it) and logs it. If the profile broke again, one more automatic try (quit,
    /// restore, reopen: `deckRelaunchRetryAllowed`), never more; then the row offers the button.
    func confirmDeckAfterLaunch(during what: String, attempt: Int = 0, then done: @escaping (Bool) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            guard !self.shuttingDown else { return done(true) }
            let running = self.isRunning(IDs.streamDeck)
            let deckSeen = self.checks.first { $0.id == "deck" }?.status == .ok
            let read = readDeckProfiles()
            let prefs = deckPreferredProfiles(readStreamDeckDevices())
            let targets = deckProfilesToMend(choice: self.setup.deckProfile, read: read, preferred: prefs.preferred,
                                             hasCopy: { DeckCopyStore(root: deckBackupsRoot, uuid: $0).good != nil })
            var lines = ["Stream Deck " + (running ? "is running." : "isn\u{2019}t running."),
                         "The deck " + (deckSeen ? "is plugged in (last check)." : "isn\u{2019}t seen on USB (last check).")]
            var broken: (uuid: String, name: String, health: DeckProfileHealth, hasCopy: Bool)?
            for t in targets {
                let d = deckDiskState(uuid: t.uuid, read: read)
                lines.append("\u{201C}\(t.name)\u{201D}: \(d.health.why).")
                if d.health.isBroken, broken == nil { broken = (t.uuid, t.name, d.health, d.copy != nil) }
                if let p = read.profiles.first(where: { $0.uuid == t.uuid }) {
                    let on = prefs.preferred[p.device]
                    lines.append(on == nil ? "Its deck isn\u{2019}t in Stream Deck\u{2019}s settings." : on == p.uuid ? "The deck is on it." : "The deck is on \(on!), not on it.")
                }
            }
            if targets.isEmpty { lines.append("No profile chosen and no deck\u{2019}s profile to check.") }
            let asks = running && streamDeckAsksToRestore(log: (try? String(contentsOfFile: streamDeckLogPath, encoding: .utf8)) ?? "")
            if asks {
                lines.append("Stream Deck is asking whether to restore its backup from today (its log: \u{201C}propose restore backup to user\u{201D}); its keys don\u{2019}t work until someone clicks Restore.")
                self.changes.insert(LogEntry(title: "\(what): Stream Deck is asking to restore its backup", language: "macOS API",
                                             code: "FileManager: read \(streamDeckLogPath)", output: lines.joined(separator: "\n"), status: 1), at: 0)
                self.diagEvent("self_repair", ["what": .string("deck_profile_restore"), "why": .string("Stream Deck asks to restore its backup"),
                                               "result": .string("asks_restore"), "attempt": .int(attempt)])
                self.refresh()
                return done(false)
            }
            let retry = broken.map { deckRelaunchRetryAllowed(attempt: attempt, health: $0.health, hasCopy: $0.hasCopy) } ?? false
                && self.deckAutoRestores < 3 && !self.streamDeckClosedOnPurpose && !self.shuttingDown
            if broken != nil {
                lines.append(retry ? "The profile broke after Stream Deck opened: one more try (quit Stream Deck, put the copy back, open it again)."
                                   : "The profile is still broken: Booth Check stops here; the row offers Restore the Stream Deck\u{2019}s keys\u{2026}")
            }
            self.changes.insert(LogEntry(title: "\(what): checked Stream Deck after it opened" + (broken == nil ? "" : ": the profile is damaged"),
                                         language: "macOS API",
                                         code: "NSRunningApplication (Stream Deck); the last USB check; FileManager: the profile\u{2019}s manifests; CFPreferencesCopyAppValue(\"Devices\", \"\(IDs.streamDeck)\"), 10 s after it opened",
                                         output: lines.joined(separator: "\n"), status: broken == nil && running ? 0 : 1), at: 0)
            guard let b = broken else { return done(true) }
            if retry {
                self.restartStreamDeck(during: "\(what), second try", clearKeys: true) { _ in
                    self.confirmDeckAfterLaunch(during: "\(what), second try", attempt: attempt + 1, then: done)
                }
                return
            }
            self.deckRepairFailed = true
            self.diagEvent("self_repair", ["what": .string("deck_profile_restore"), "why": .string(b.health.why),
                                           "result": .string(b.hasCopy ? "broke_again" : "no_copy"), "attempt": .int(attempt)])
            self.reportError("DeckProfileRestoreFailed", "\(what): the Stream Deck profile \u{201C}\(b.name)\u{201D} is still damaged after Stream Deck opened (\(b.health.why)); "
                             + (b.hasCopy ? "it broke again after being put back." : "Booth Check has no copy of it."))
            self.refresh()
            done(false)
        }
    }

    /// The row's Restore the Stream Deck's keys… button, after the change sheet's Run: Stream Deck closes, the copy
    /// goes back (`restoreDeckProfile`, even over a healthy profile: a person asked), the key lights are
    /// reset, Stream Deck opens, and `confirmDeckAfterLaunch` checks it. The sign says what's happening.
    func restoreDeckProfileByHand(uuid: String, name: String) {
        guard !streamDeckClosedOnPurpose, !shuttingDown, !starting else {
            logSetting("Restore the Stream Deck\u{2019}s keys: not now", "Booth Check is already starting, shutting down or restarting Stream Deck, so nothing was changed. Try again in a minute.")
            return
        }
        deckRestoring = true
        showWorkingSign(.deckKeysRestoring)
        var result = DeckRestoreResult(text: "Stream Deck didn\u{2019}t close, so nothing was changed.")
        let put = {
            let read = readDeckProfiles()
            guard let folder = read.folder else {
                result = DeckRestoreResult(text: "Stream Deck has no profiles folder here, so nothing was changed.")
                return
            }
            let store = DeckCopyStore(root: deckBackupsRoot, uuid: uuid)
            let copy = store.good
            result = restoreDeckProfile(uuid: uuid, profilesFolder: folder, store: store, deckRunning: { self.isRunning(IDs.streamDeck) })
            self.changes.insert(LogEntry(title: "Restore the Stream Deck\u{2019}s keys: put back \u{201C}\(name)\u{201D}", language: "Booth Check steps",
                                         code: copy.map { deckRestoreSteps(name: name, copy: $0, profilesFolder: folder, store: store) } ?? "(no copy)",
                                         output: result.text, status: result.ok ? 0 : 1), at: 0)
            self.diagEvent("deck_profile_restored", ["why": .string(deckDiskState(uuid: uuid, read: read).health.why), "during": .string("service"),
                                                     "how": .string("button"), "result": .string(result.ok ? "ok" : "failed"),
                                                     "identical": .int(result.identical ? 1 : 0), "pages": .int(copy?.pages ?? 0), "keys": .int(copy?.keys ?? 0),
                                                     "copy_age_h": .int(Int(Date().timeIntervalSince(copy?.savedAt ?? Date()) / 3600))])
            if result.ok, let f = self.deckProfileFixNeeded(during: "Restore the Stream Deck\u{2019}s keys") {
                self.setPreferredProfile(device: f.device, to: f.target, name: f.name, during: "Restore the Stream Deck\u{2019}s keys")
            }
            if result.ok { self.deckRepairFailed = false }
        }
        let opened = { (r: (state: StepState, detail: String, opened: Bool)) in
            self.deckRestoring = false
            guard result.ok else {
                self.reportError("DeckProfileRestoreFailed", "Restore the Stream Deck\u{2019}s keys (\u{201C}\(name)\u{201D}): \(result.text)")
                self.endWorkingSign(.deckKeysRestoreFailed, ok: false)
                return self.refresh()
            }
            self.confirmDeckAfterLaunch(during: "Restore the Stream Deck\u{2019}s keys", attempt: 1) { ok in
                self.endWorkingSign(ok ? .deckKeysRestored : .deckKeysRestoreFailed, ok: ok)
                self.refresh()
            }
        }
        if isRunning(IDs.streamDeck) {
            restartStreamDeck(during: "Restore the Stream Deck\u{2019}s keys", whileClosed: put, clearKeys: true, then: opened)
        } else {
            put()
            clearDeckKeyLights(during: "Restore the Stream Deck\u{2019}s keys")
            opened(openStreamDeckInBackground(during: "Restore the Stream Deck\u{2019}s keys"))
        }
    }

    /// Lightkey started outside a start-up (by hand, or after a crash) while Stream Deck is open: once
    /// Lightkey's MIDI input is there, restart Stream Deck so no key stays lit from before.
    func watchLightkeyLaunches() {
        guard lightkeyLaunchWatch == nil else { return }
        lightkeyLaunchWatch = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == IDs.lightkey,
                  shouldRestartStreamDeck(enabled: self.setup.streamDeck, deckRunning: self.isRunning(IDs.streamDeck),
                                          startUpDeckStep: false, lightkeyJustLaunched: true,
                                          busy: streamDeckBusy(starting: self.starting, shuttingDown: self.shuttingDown,
                                                               closedOnPurpose: self.streamDeckClosedOnPurpose)) else { return }
            self.poll(every: 1, for: 30, {
                MIDIWatch.shared.destinationNames().contains { $0.localizedCaseInsensitiveContains(IDs.lightkeyMIDIInput) }
            }) { _ in
                guard !self.starting, !self.shuttingDown, !self.streamDeckClosedOnPurpose, self.isRunning(IDs.streamDeck) else { return }
                self.showWorkingSign(.deckRestarting)
                self.restartStreamDeck(during: "Lightkey started", clearKeys: true) { result in
                    let ok = result.state == .done
                    self.diagEvent("self_repair", ["what": .string("streamdeck_restart"), "why": .string("Lightkey started"), "result": .string(ok ? "ok" : "failed")])
                    self.endWorkingSign(ok ? .deckRestarted : .deckFailed, ok: ok)
                    if result.opened { self.confirmDeckAfterLaunch(during: "Lightkey started") { _ in } }
                }
            }
        }
    }

    /// With the 15-second checks, and when Stream Deck is switched on in This Mac: if it's switched on
    /// but its app isn't running, open it (see `shouldOpenStreamDeck`).
    func keepStreamDeckOpen() {
        guard shouldOpenStreamDeck(enabled: setup.streamDeck,
                                   installed: NSWorkspace.shared.urlForApplication(withBundleIdentifier: IDs.streamDeck) != nil,
                                   running: isRunning(IDs.streamDeck),
                                   busy: streamDeckBusy(starting: starting, shuttingDown: shuttingDown, closedOnPurpose: streamDeckClosedOnPurpose),
                                   needsLightkey: setup.lightkey,
                                   lightkeyReady: MIDIWatch.shared.destinationNames().contains { $0.localizedCaseInsensitiveContains(IDs.lightkeyMIDIInput) },
                                   sinceLast: Date().timeIntervalSince(lastDeckOpen ?? .distantPast)) else { return }
        showWorkingSign(.deckReopening)
        let result = openStreamDeckInBackground(during: "Stream Deck is switched on")
        // Give it a moment to come up before the sign says it's back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let ok = result.opened && self.isRunning(IDs.streamDeck)
            self.diagEvent("self_repair", ["what": .string("streamdeck_open"), "why": .string("not running"), "result": .string(ok ? "ok" : "failed")])
            self.endWorkingSign(ok ? .deckReopened : .deckFailed, ok: ok)
        }
    }

    // MARK: The Stream Deck profile (1.32)

    /// At the start-up: the switch to make, if the deck isn't on the chosen profile and the settings are
    /// exactly the shape Booth Check knows. Logged either way.
    func deckProfileFixNeeded(during what: String) -> (device: String, target: String, name: String)? {
        guard setup.streamDeck, let choice = setup.deckProfile else { return nil }
        let read = readDeckProfiles()
        deckProfiles = read
        let devices = readStreamDeckDevices()
        let preferred = deckPreferredProfiles(devices)
        var out: String
        var fix: (device: String, target: String, name: String)?
        if let p = read.problem {
            out = "Can\u{2019}t tell: \(p) Nothing changed."
        } else if deckProfileFolder(uuid: choice.uuid, in: read.folder) != nil, !read.profiles.contains(where: { $0.uuid == choice.uuid.lowercased() }) {
            // Nov 2026: its own folder is there but damaged; another profile with the same keys isn't it.
            out = "\u{201C}\(choice.name)\u{201D}\u{2019}s own folder is there but damaged, so Booth Check doesn\u{2019}t switch the deck to another profile. Nothing changed."
        } else if case .found(let target, _) = matchDeckProfile(choice, in: read.profiles) {
            let current = preferred.preferred[target.device]
            let sameKeys = read.profiles.first { $0.uuid == current }?.sigHash == target.sigHash
            if current == target.uuid || (current != nil && sameKeys) {
                out = "Already on \u{201C}\(target.name)\u{201D}. Nothing changed."
            } else {
                let g = deckPrefsWriteGuard(devices: devices, device: target.device, target: target.uuid,
                                            targetFolderExists: deckProfileFolder(uuid: target.uuid, in: read.folder) != nil)
                if g.ok {
                    out = "On \(current.map { c in read.profiles.first { $0.uuid == c }.map { "\u{201C}\($0.name)\u{201D}" } ?? c } ?? "nothing"), the service needs \u{201C}\(target.name)\u{201D}: switching it while Stream Deck is closed."
                    fix = (target.device, target.uuid, target.name)
                } else {
                    out = "On the wrong profile, but Booth Check won\u{2019}t write: \(g.why) Nothing changed."
                }
            }
        } else {
            out = "\u{201C}\(choice.name)\u{201D} isn\u{2019}t clearly one installed profile (missing, or more than one). Nothing changed."
        }
        changes.insert(LogEntry(title: "\(what): Stream Deck\u{2019}s profile", language: "macOS API",
                                code: "Read \(read.folder ?? streamDeckSupportDir) and CFPreferencesCopyAppValue(\"Devices\", \"\(IDs.streamDeck)\")",
                                output: out, status: fix == nil && !out.hasPrefix("Already") ? 1 : 0), at: 0)
        return fix
    }

    /// Writes `target` as `device`'s preferred profile through CFPreferences: only with Stream Deck
    /// closed, and only when `deckPrefsWriteGuard` passes. Logs before and after.
    @discardableResult
    func setPreferredProfile(device: String, to target: String, name: String, during what: String) -> (ok: Bool, text: String) {
        var out: String, ok = false
        if isRunning(IDs.streamDeck) {
            out = "Stream Deck is still open, so nothing was written (it would write its own choice back)."
        } else {
            let devices = readStreamDeckDevices()
            let folder = readDeckProfiles().folder
            let g = deckPrefsWriteGuard(devices: devices, device: device, target: target,
                                        targetFolderExists: deckProfileFolder(uuid: target, in: folder) != nil)
            if !g.ok {
                out = "Nothing written: \(g.why)"
            } else if g.current?.lowercased() == target.lowercased() {
                out = "Already \(target). Nothing written."
                ok = true
            } else if let d = devices as? [String: Any], let new = deckDevicesSetting(d, device: device, preferred: target) {
                let synced = writeStreamDeckDevices(new)
                let after = deckPreferredProfiles(readStreamDeckDevices()).preferred[device]
                ok = synced && after == target.lowercased()
                out = "Before: \(g.current ?? "(none)"). After: \(after ?? "(none)")." + (synced ? "" : " macOS said it couldn\u{2019}t save the setting.")
            } else {
                out = "Nothing written: the Devices setting changed shape while it was read."
            }
        }
        changes.insert(LogEntry(title: "\(what): put Stream Deck on \u{201C}\(name)\u{201D}", language: "macOS API",
                                code: "CFPreferencesSetAppValue(\"Devices\", \u{2026}, \"\(IDs.streamDeck)\"): \(device) \u{2192} ESDProfilesInfo \u{2192} ESDProfilesPreferred = \"\(target)\"; CFPreferencesAppSynchronize",
                                output: out, status: ok ? 0 : 1), at: 0)
        return (ok, out)
    }

    /// Once Stream Deck is up again, waits 10 s and reads the preferred profile back: Stream Deck may
    /// write its own choice over it. If it did, the row says how to choose it in Stream Deck instead.
    func verifyDeckProfile(device: String, target: String, name: String, during what: String, then done: @escaping (Bool) -> Void) {
        poll(every: 1, for: 30, {
            NSRunningApplication.runningApplications(withBundleIdentifier: IDs.streamDeck).first?.isFinishedLaunching == true
        }) { up in
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                let now = deckPreferredProfiles(readStreamDeckDevices()).preferred[device]
                let ok = up && now == target.lowercased()
                self.deckProfileWriteFailed = !ok
                self.changes.insert(LogEntry(
                    title: "\(what): checked Stream Deck kept \u{201C}\(name)\u{201D}", language: "macOS API",
                    code: "CFPreferencesCopyAppValue(\"Devices\", \"\(IDs.streamDeck)\") \u{2192} \(device) \u{2192} ESDProfilesInfo \u{2192} ESDProfilesPreferred, 10 s after Stream Deck opened",
                    output: !up ? "Stream Deck didn\u{2019}t open within 30 seconds, so Booth Check can\u{2019}t tell."
                        : ok ? "Still \(target): it stuck."
                        : "Now \(now ?? "(none)"), not \(target): the write didn\u{2019}t take (Stream Deck put its own choice back). The row now says to choose \u{201C}\(name)\u{201D} in Stream Deck.",
                    status: ok ? 0 : 1), at: 0)
                done(ok)
            }
        }
    }

    /// The row's Fix: Stream Deck closes, the profile is switched in the gap, it opens again, then the
    /// switch is read back. The working sign says what's happening.
    func switchDeckProfile(device: String, to target: String, name: String, during what: String, then done: @escaping (Bool) -> Void) {
        guard !streamDeckClosedOnPurpose, !shuttingDown else { return done(false) }
        deckProfileSwitching = true
        showWorkingSign(.deckProfileSwitching(name))
        var wrote = (ok: false, text: "Stream Deck didn\u{2019}t close, so nothing was written.")
        let write = { wrote = self.setPreferredProfile(device: device, to: target, name: name, during: what) }
        let end = { (ok: Bool, why: String) in
            self.deckProfileSwitching = false
            self.diagEvent("self_repair", ["what": .string("deck_profile"), "why": .string(why), "result": .string(ok ? "ok" : "failed")])
            self.endWorkingSign(ok ? .deckProfileSwitched(name) : .deckProfileFailed(name), ok: ok)
            done(ok)
            self.refresh()
        }
        let opened = { (result: (state: StepState, detail: String, opened: Bool)) in
            guard wrote.ok else { return end(false, "\(what): " + wrote.text) }
            self.verifyDeckProfile(device: device, target: target, name: name, during: what) { ok in
                end(ok, ok ? "\(what): switched" : "\(what): didn\u{2019}t stick")
            }
        }
        if isRunning(IDs.streamDeck) {
            restartStreamDeck(during: what, whileClosed: write, then: opened)
        } else {
            write()
            opened(openStreamDeckInBackground(during: what))
        }
    }

    /// deck_profile: what the deck is on and what the service wants, at each start-up and on change.
    func diagDeckProfile(choice: DeckProfileChoice, read: DeckProfilesRead, preferred: [String: String], check: Check) {
        var target: DeckProfile?
        if case .found(let p, _) = matchDeckProfile(choice, in: read.profiles) { target = p }
        let current = target.flatMap { preferred[$0.device] }
        let match: String
        switch check.status {
        case .ok: match = "yes"
        case .warn: match = "yes_warn"
        case .fail: match = "no"
        default: match = "unknown"
        }
        let props: [String: DiagValue] = [
            "preferred": .string(current.map { c in read.profiles.first { $0.uuid == c }?.name ?? "not installed" } ?? "unknown"),
            "wanted": .string(choice.name), "match": .string(match),
            "keys": .int(target?.keys.count ?? 0), "sig": .string(target?.sigHash ?? choice.sigHash),
            "plugin": .string(target?.pluginVersions.joined(separator: ",") ?? "")]
        let sig = props.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.text)" }.joined(separator: "|")
        guard sig != lastDeckProfileDiag else { return }
        lastDeckProfileDiag = sig
        diagEvent("deck_profile", props)
    }

    /// After each check of the deck lights helper: when it has stopped working, start or restart it
    /// through launchd (see `deckHelperAutoFix` for how often), logged like any change. When that hasn't
    /// fixed it, bring the window up once so someone sees the red row.
    func keepDeckHelperRunning(_ check: Check) {
        guard applies(check.id), !shuttingDown, pending == nil else { return }
        guard check.status == .fail else {
            deckHelperFailingSince = nil
            deckHelperAlerted = false
            return
        }
        let since = deckHelperFailingSince ?? Date()
        deckHelperFailingSince = since
        if deckHelperGaveUp(fixes: deckHelperFixesAgo) {
            guard !deckHelperAlerted else { return }
            deckHelperAlerted = true
            logSetting("Deck lights helper still not working", "Booth Check restarted it 3 times in 30 minutes and stopped trying, so it opened its window to show the red row.")
            diag.incident("helper_gave_up", checkIncidentText(check, since: since, entries: lastPass)
                          + changes.filter { $0.title.localizedCaseInsensitiveContains("deck lights helper") }.prefix(20).reversed().map(diskLogText).joined())
            diagFlushIfAllowed()
            showWindow()
            return
        }
        if case .installDeckHelper? = check.action { return }          // not installed: that needs someone to approve it
        guard deckHelperAutoFix(failingFor: Date().timeIntervalSince(since), fixes: deckHelperFixesAgo) else { return }
        showWorkingSign(.helperRestarting)
        kickDeckHelper("Deck lights helper stopped working") { ok in
            self.diagEvent("self_repair", ["what": .string("helper_restart"), "why": .string(check.detail), "result": .string(ok ? "ok" : "failed")])
            self.endWorkingSign(ok ? .helperRestarted : .helperFailed, ok: ok)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.refresh() }
        }
    }

    /// Starts the helper through launchd now: kickstart -k when launchd has it, bootstrap when it's
    /// installed but not loaded, nothing when it isn't installed. Logged, and counted against
    /// `deckHelperAutoFix`'s limits.
    func kickDeckHelper(_ why: String, then done: @escaping (Bool) -> Void) {
        deckHelperFixes.append(Date())
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = shell("/bin/launchctl", ["print", deckHelperService]).code == 0
            let installed = FileManager.default.fileExists(atPath: deckHelperPlist)
            let args = loaded ? deckHelperRestartArgs() : deckHelperStartArgs()
            let r = loaded || installed ? shell("/bin/launchctl", args) : nil
            DispatchQueue.main.async {
                if let r {
                    self.changes.insert(LogEntry(title: "\(why): Booth Check \(loaded ? "restarted" : "started") the deck lights helper",
                                                 language: "Terminal", code: commandLine("/bin/launchctl", args),
                                                 output: r.out.isEmpty ? "(no output)" : r.out, status: r.code), at: 0)
                }
                done(r?.code == 0)
            }
        }
    }

    /// Brings Lightkey to the front if it opened behind something, so its Authenticate alert shows on
    /// screen and on the Touch Bar (see `shouldFrontLightkey`). Logged each time.
    private func frontLightkeyIfBehind() {
        guard let lightkey = NSRunningApplication.runningApplications(withBundleIdentifier: IDs.lightkey).first,
              lightkey.isFinishedLaunching else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard shouldFrontLightkey(frontmost: frontmost?.bundleIdentifier, me: Bundle.main.bundleIdentifier,
                                  attempts: frontAttempts, sinceLast: Date().timeIntervalSince(lastFront ?? .distantPast)) else { return }
        frontAttempts += 1
        lastFront = Date()
        let ok = lightkey.activate(options: [])
        changes.insert(LogEntry(title: "Start-up: brought Lightkey to the front", language: "macOS API",
                                code: "NSRunningApplication.activate (Lightkey)",
                                output: "It was behind \(frontmost?.localizedName ?? "another app"), where its Authenticate alert can\u{2019}t be seen. "
                                    + (ok ? "Done." : "macOS didn\u{2019}t allow it."),
                                status: ok ? 0 : 1), at: 0)
    }

    /// All green: the panel hides itself shortly after. Anything else: it stays until dismissed. The
    /// hands-off sign says which it was for a moment, then goes.
    private func finishBoot() {
        starting = false
        bootFinished = true
        if setup.lightkey && setup.dmx { dmxSnapshot("startup-end") }
        let linked = bootSteps.first { $0.id == "dmxLink" }.map { $0.state == .done } ?? true
        endAuthWait("still_asking", during: "startup_end")
        let total = ProcessInfo.processInfo.systemUptime - (bootStartedUptime ?? ProcessInfo.processInfo.systemUptime)
        var props: [String: DiagValue] = [
            "ready": .int(bootReady ? 1 : 0), "problems": .int(problemCount),
            "total_s": .double((total * 10).rounded() / 10),
            "replug_shown": .int(diagReplugShown ? 1 : 0),
            "dmx_recovery": .string(dmxRecoverySummary(dmxLadder, linked: linked)),
            "dmx_rungs": .int(dmxRungsRun(dmxLadder)),
            "how": .string(bootAtLogin ? "login" : bootByHand ? "by_hand" : bootCheckOnly ? "check_only" : "restart_lightkey"),
            "auth_wait_s": .double((authWaitTotal * 10).rounded() / 10),
            "people": .int(bootPeople),
            "started": .string(aptabaseTimestamp(bootStartedAt ?? Date()))]
        props.merge(startupStepCounts(bootSteps.map(\.state))) { a, _ in a }
        if bootSteps.contains(where: { $0.id == "lightkey" }) {
            let e = startStateEvidence(mark: startStateMark, now: LightkeyOutputWatch.shared.now(), late: startStateLate)
            props["start_state"] = .string(e.prop)
            props["start_state_msgs"] = .int(e.messages)
            props["start_state_on"] = .int(e.on)
            changes.insert(LogEntry(title: "Start-up: what Lightkey reported as the show opened", language: "macOS API",
                                    code: "CoreMIDI: listen (read only) to \u{201C}\(IDs.lightkeyMIDIOutput)\u{201D}; count its note and control messages from the show step to the end of the start-up",
                                    output: e.text, status: e.prop == "reported" ? 0 : nil), at: 0)
        }
        diagEvent("startup_done", props)
        if !bootReady {
            let bad = checks.filter { statusIsBad($0.status) }.map(\.title)
            let steps = bootSteps.enumerated().filter { $0.element.state == .warn || $0.element.state == .failed }.map { "\($0.offset + 1). \($0.element.title)" }
            reportError("StartupNotReady", "The start-up (\(props["how"]?.text ?? "?")) ended not ready: " + thingsToFix(problemCount)
                        + (bad.isEmpty ? "" : " (" + bad.joined(separator: ", ") + ")") + (steps.isEmpty ? "." : ". Steps that warned: " + steps.joined(separator: ", ") + "."))
        }
        let wanted = noPasswordWantedAfterStartUp(setup.noPasswordWanted, ready: bootReady, settingOn: lightkeyNoPassword)
        if wanted != setup.noPasswordWanted && setup.lightkey && setup.dmx {
            setup.noPasswordWanted = wanted
            logSetting("This Mac: Lightkey connects without the password here", "The start-up was ready with Lightkey\u{2019}s DontUnloadFTDIDrivers on, so a login start-up puts it back if it ever goes missing. Untick \u{201C}Connect without asking for the password\u{201D} in This Mac to stop that.")
        }
        tally.startups += 1
        tally.startupReady = bootReady
        tally.startupSeconds = total
        persistTally()
        if bootSteps.contains(where: { $0.state == .warn || $0.state == .failed }), let began = bootStartedAt {
            diag.incident("startup", logText(since: began))
        }
        diagStartupDone = true
        // The snapshot above logs a moment later; give it time to queue, then send.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.diagFlushIfAllowed() }
        if dmxRestartingByHand {
            // Restart Lightkey… from the row: the sign said "Restarting Lightkey"; now say how it went.
            dmxRestartingByHand = false
            endWorkingSign(linked ? .dmxConnected : .dmxFailed, ok: linked)
        }
        if signOn && !workingSignUp { SignOverlay.shared.finish(ready: bootReady) }
        signOn = false
        if bootSteps.allSatisfy({ $0.state == .done }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                if self.bootFinished && !self.starting { BootPanel.shared.hide() }
            }
        }
    }
}

// MARK: - DMX self-recovery and the working sign (1.30)

extension Booth {
    /// The big sign for something Booth Check is fixing by itself (the owner asked: whenever it works on
    /// a problem by itself, the screen says what it's doing). The same hands-off sign as the start-up:
    /// it ignores clicks and never takes focus. A bottom banner with nothing dimmed whenever Lightkey may
    /// need a person: outside a start-up (someone is running the service in Lightkey), and during one
    /// while Lightkey may be asking for its password. Not during a shutdown, which has its own sign.
    func showWorkingSign(_ r: SelfRepair) {
        guard !shuttingDown else { return }
        let words = selfRepairWords(r)
        workingActive = true
        workingSignUp = true
        let banner = !starting || (lightkeyMayAsk && signLightkeyOpened && !signDMXLinked)
        SignOverlay.shared.working(title: words.title, detail: words.detail, banner: banner)
    }

    /// The self-repair is over: its last word for a moment (3 s, or 8 s when it didn't work), then the
    /// start-up's own sign comes back, or the sign goes.
    func endWorkingSign(_ r: SelfRepair, ok: Bool) {
        guard workingActive else { return }
        workingActive = false
        let words = selfRepairWords(r)
        SignOverlay.shared.endWorking(ok: ok, title: words.title, detail: words.detail, after: ok ? 3 : 8) { [weak self] in
            guard let self, !self.workingActive else { return }
            self.workingSignUp = false
            if self.signOn && self.starting { self.updateSign() } else if !self.shuttingDown { SignOverlay.shared.hide() }
        }
    }

    /// Stops any olad left running without Lightkey (SIGTERM, then SIGKILL after 3 s), so the next
    /// Lightkey starts its own and it scans for the interface. Every step goes in the Log.
    func clearOrphanOlad(_ why: String, then done: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var entries: [LogEntry] = []
            let ps = shell("/bin/ps", psDMXArgs)
            let procs = parsePs(ps.out)
            let orphans = orphanOladPIDs(procs)
            let olads = procs.filter(\.isOlad)
            entries.append(LogEntry(title: "\(why): any olad left without Lightkey?", language: "Terminal",
                                    code: commandLine("/bin/ps", psDMXArgs),
                                    output: (olads.isEmpty ? "No olad running." : olads.map { "olad pid \($0.pid), parent \($0.ppid), running \($0.etime): \($0.args)" }.joined(separator: "\n"))
                                        + (orphans.isEmpty ? "" : "\nLightkey isn\u{2019}t running, so this olad is left over: stopping it, so the next Lightkey starts its own and looks for the interface.")
                                        + "\n(Only olad is shown.)",
                                    status: ps.code))
            func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
            // Each signal re-reads ps first (`signalOladIfStill`): the pid must still be a left-over olad.
            for pid in orphans {
                let term = signalOladIfStill("-TERM", pid: pid, orphan: true)
                var gone = !term.sent
                if term.sent { for _ in 0..<12 where !gone { usleep(250_000); gone = !alive(pid) } }
                entries.append(LogEntry(title: "\(why): stopped the left-over olad (pid \(pid))", language: "Terminal",
                                        code: commandLine("/bin/ps", psDMXArgs) + "\n" + commandLine("/bin/kill", ["-TERM", String(pid)]),
                                        output: term.out + "\n" + (!term.sent ? "" : gone ? "olad stopped." : "Still running after 3 seconds."),
                                        status: term.code))
                if !gone {
                    let k = signalOladIfStill("-KILL", pid: pid, orphan: true)
                    if k.sent { usleep(300_000) }
                    entries.append(LogEntry(title: "\(why): made the left-over olad (pid \(pid)) stop", language: "Terminal",
                                            code: commandLine("/bin/ps", psDMXArgs) + "\n" + commandLine("/bin/kill", ["-KILL", String(pid)]),
                                            output: k.out + (k.sent ? "\n" + (alive(pid) ? "Still running." : "olad stopped.") : ""),
                                            status: k.code))
                }
            }
            DispatchQueue.main.async {
                entries.forEach { self.changes.insert($0, at: 0) }
                done()
            }
        }
    }

    /// The start-up's DMX link step: a first wait for Lightkey or olad to hold the interface (20 s, a
    /// minute while Lightkey may ask for the password, none when the link is suspect), then the ladder.
    func runDMXLink(_ i: Int, afterRelaunch: Bool = false, next: @escaping () -> Void) {
        let stepStart = Date()
        guard let lk = NSRunningApplication.runningApplications(withBundleIdentifier: IDs.lightkey).first?.processIdentifier else {
            return failDMXLink(i, "Lightkey isn\u{2019}t open.", next: next)
        }
        setStep(i, .running, lightkeyMayAsk ? "If Lightkey asks, click Authenticate and type the Mac\u{2019}s password." : "Waiting for Lightkey to take the interface.")
        DispatchQueue.global(qos: .userInitiated).async {
            let st = readDMXState(lightkeyPID: lk)
            DispatchQueue.main.async {
                if st.held { return self.dmxLinked(i, next: next) }
                // Not seen yet (no DMX interface step) but there now: this is the first look, so it was there at once.
                if self.dmxFirstSeen == nil && st.planes.present { self.dmxFirstSeen = Date(); self.dmxSeenAtStart = true }
                let why = afterRelaunch ? nil
                    : dmxLinkSuspect(atLogin: self.bootAtLogin, lightkeyRunningAtStart: self.lightkeyRunningAtStart, boxSeenAtStart: self.dmxSeenAtStart,
                                     oladStarted: st.olad?.started, boxFirstSeen: self.dmxFirstSeen)
                self.dmxSuspect = !afterRelaunch
                    && (why != nil || (self.bootAtLogin && self.lightkeyReopenedByMacOS && !self.dmxSeenAtStart))
                if let why {
                    self.changes.insert(LogEntry(title: "Start-up: the DMX link is suspect, so Booth Check reconnects straight away",
                                                 language: "Terminal", code: commandLine("/bin/ps", psDMXArgs),
                                                 output: why + (st.olad.map { "\nolad: pid \($0.pid), parent \($0.ppid), running \($0.etime)." } ?? "\nNo olad running."),
                                                 status: 0), at: 0)
                }
                let wait: TimeInterval = why != nil ? 0 : self.lightkeyMayAsk ? 60 : 20
                self.poll(every: 2, for: wait, background: true, { readDMXState(lightkeyPID: lk).held }) { ok in
                    if ok { return self.dmxLinked(i, next: next) }
                    self.climbDMXLadder(i, since: stepStart, next: next)
                }
            }
        }
    }

    private func dmxLinked(_ i: Int, next: @escaping () -> Void) {
        signDMXLinked = true        // it has the interface, so it's past its password
        endAuthWait("answered", during: "dmx")
        setStep(i, .done, dmxLadder.started ? "Lightkey has the interface open. " + dmxLadderTriedText(dmxLadder) : "Lightkey has the interface open.")
        if dmxLadder.started {
            diagDMXRecovery("held", "connected")
            endWorkingSign(.dmxConnected, ok: true)
        }
        next()
    }

    private func failDMXLink(_ i: Int, _ text: String, next: @escaping () -> Void) {
        endAuthWait("still_asking", during: "dmx")
        setStep(i, .warn, text)
        if dmxLadder.started { reportError("DMXRecoveryFailed", "The start-up\u{2019}s DMX recovery didn\u{2019}t get Lightkey to take the interface: \(text)") }
        dmxSnapshot("dmxLink-failed")
        endWorkingSign(.dmxFailed, ok: false)
        next()
    }

    /// One rung of the ladder (see `dmxLadderNext`), each logged with its command and output, then a
    /// re-check for up to 12 s.
    private func climbDMXLadder(_ i: Int, since: Date, next: @escaping () -> Void) {
        let lk = NSRunningApplication.runningApplications(withBundleIdentifier: IDs.lightkey).first?.processIdentifier
        let ax = AXIsProcessTrusted()
        let asking = ax && (lk.map(asksToAuthenticate) ?? false)
        DispatchQueue.global(qos: .userInitiated).async {
            let st = readDMXState(lightkeyPID: lk)
            let found = (FileManager.default.contents(atPath: olaLogPath)).flatMap { olaFoundDevices(String(decoding: $0, as: UTF8.self)) }
            DispatchQueue.main.async {
                let rung = dmxLadderNext(boxPresent: st.planes.present, held: st.held, lightkeyRunning: lk != nil,
                                         oladPID: st.olad?.pid, asking: asking, accessibility: ax, ladder: self.dmxLadder,
                                         olaFound: found?.count, suspect: self.dmxSuspect,
                                         suspectCounts: dmxSuspectCounts(atLogin: self.bootAtLogin, lightkeyRunningAtStart: self.lightkeyRunningAtStart))
                if ax { self.noteAuthAsking(asking, during: "dmx") }
                let elapsed = Date().timeIntervalSince(since)
                let climb = { self.climbDMXLadder(i, since: since, next: next) }
                let again = { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { climb() } }
                let recheck = {
                    self.poll(every: 2, for: 12, background: true, { readDMXState(lightkeyPID: lk).held }) { _ in climb() }
                }
                let tried = dmxLadderTriedText(self.dmxLadder)
                switch rung {
                case .held, .noLightkey, .noBox, .waitForPassword: break
                default:
                    if !self.dmxLadder.started {
                        self.dmxLadder.started = true
                        self.dmxSnapshot("ladder")
                        self.showWorkingSign(.dmxNotConnected)
                        self.logDMX("The DMX interface is on USB (\(st.planes.text)), but Lightkey and olad aren\u{2019}t holding it, so Booth Check tries to reconnect.", code: "Start the DMX recovery", status: 1)
                    }
                }
                switch rung {
                case .held:
                    self.dmxLinked(i, next: next)
                case .noLightkey:
                    self.failDMXLink(i, "Lightkey isn\u{2019}t open. " + (self.dmxLadder.started ? tried : ""), next: next)
                case .noBox:
                    if elapsed < 60 {
                        self.setStep(i, .running, "The DMX interface isn\u{2019}t on USB.")
                        again()
                    } else {
                        self.failDMXLink(i, "The DMX interface isn\u{2019}t on USB, so there was nothing to reconnect. " + replugDMXWords, next: next)
                    }
                case .waitForPassword:
                    if elapsed < 180 {
                        self.setStep(i, .running, "Lightkey is asking for the password: tap Authenticate, then type the Mac\u{2019}s password.")
                        again()
                    } else {
                        self.failDMXLink(i, "Lightkey was still asking for the password after 3 minutes.", next: next)
                    }
                case .hup(let pid):
                    self.dmxLadder.hupTried = true
                    self.showWorkingSign(.dmxAskingOlad)
                    self.setStep(i, .running, "Asking Lightkey\u{2019}s DMX server to look for the interface again\u{2026}")
                    DispatchQueue.global(qos: .userInitiated).async {
                        let args = ["-HUP", String(pid)]
                        let r = signalOladIfStill("-HUP", pid: pid, orphan: false)
                        DispatchQueue.main.async {
                            self.dmxLadder.hupSent = self.dmxLadder.hupSent || r.sent
                            self.diagDMXRecovery("sighup", r.sent ? "sent" : r.code == 3 ? "changed" : "failed")
                            self.changes.insert(LogEntry(title: "DMX recovery: asked olad (pid \(pid)) to look for the interface again", language: "Terminal",
                                                         code: commandLine("/bin/ps", psDMXArgs) + "\n" + commandLine("/bin/kill", args),
                                                         output: r.out + (r.sent ? "\nolad reloads its plugins on SIGHUP and scans USB again." : "") + " Checking for 12 seconds.",
                                                         status: r.code), at: 0)
                            recheck()
                        }
                    }
                case .skipHup:
                    self.dmxLadder.hupTried = true
                    self.logDMX("olad isn\u{2019}t running, so there\u{2019}s no DMX server to ask. Next: Lightkey\u{2019}s Reset DMX Output.", code: "kill -HUP <olad> (skipped)", status: nil)
                    climb()
                case .resetOutput:
                    self.dmxLadder.resetTried = true
                    self.showWorkingSign(.dmxResetOutput)
                    self.setStep(i, .running, "Pressing Lightkey\u{2019}s Reset DMX Output\u{2026}")
                    let r: (pressed: Bool, path: String?) = lk.map { pressMenuItem(pid: $0, matching: isResetDMXOutputTitle) } ?? (pressed: false, path: nil)
                    self.dmxLadder.resetPressed = self.dmxLadder.resetPressed || r.pressed
                    self.diagDMXRecovery("reset", r.pressed ? "pressed" : r.path == nil ? "not_found" : "not_pressable")
                    self.changes.insert(LogEntry(title: "DMX recovery: Lightkey\u{2019}s Reset DMX Output", language: "macOS API",
                                                 code: "Accessibility: Lightkey\u{2019}s menu bar \u{2192} the item titled \u{201C}Reset DMX Output\u{201D} \u{2192} AXPress",
                                                 output: r.path == nil ? "Not found in Lightkey\u{2019}s menus, so skipped."
                                                     : r.pressed ? "Pressed \(r.path!). Checking for 12 seconds." : "Found \(r.path!), but it couldn\u{2019}t be pressed (greyed out?), so skipped.",
                                                 status: r.pressed ? 0 : 1), at: 0)
                    if r.pressed { recheck() } else { climb() }
                case .skipReset:
                    self.dmxLadder.resetTried = true
                    self.logDMX("Booth Check isn\u{2019}t allowed to use Accessibility, so it can\u{2019}t press Lightkey\u{2019}s Reset DMX Output. Skipped.", code: "Lightkey \u{2192} Reset DMX Output (skipped)", status: nil)
                    climb()
                case .relaunch:
                    self.relaunchForDMX(i, next: next)
                case .giveUp:
                    self.diagDMXRecovery("giveup", "failed")
                    self.failDMXLink(i, "Lightkey didn\u{2019}t take the DMX interface. \(tried) " + dmxUnconfirmedWords, next: next)
                case .unconfirmed:
                    // Task 0 (14 Nov 2026): the "held" check may just be wrong, and olad's log doesn't say
                    // it missed the box, so Lightkey isn't restarted (the lights would go dark for nothing).
                    let why = found.map { "olad\u{2019}s log says it found \($0.count) FTDI device\($0.count == 1 ? "" : "s") (\u{201C}\($0.line)\u{201D})" }
                        ?? "olad\u{2019}s log doesn\u{2019}t say how many FTDI devices it found"
                    self.logDMX("Booth Check couldn\u{2019}t confirm Lightkey holds the DMX interface, but \(why), and the link wasn\u{2019}t suspect, so it doesn\u{2019}t restart Lightkey.",
                                code: "Restart Lightkey (not done: no evidence olad missed the interface)", status: 1)
                    self.dmxLadder.unconfirmed = true
                    self.diagDMXRecovery("relaunch", "skipped_unconfirmed")
                    self.setStep(i, .warn, "Couldn\u{2019}t confirm Lightkey has the DMX interface. \(tried) Nothing was restarted, because Lightkey\u{2019}s DMX server says it found the interface. " + dmxUnconfirmedWords)
                    self.dmxSnapshot("dmxLink-unconfirmed")
                    self.endWorkingSign(.dmxUnconfirmed, ok: false)
                    next()
                }
            }
        }
    }

    private func logDMX(_ output: String, code: String, status: Int32?) {
        changes.insert(LogEntry(title: "DMX recovery", language: "Booth Check", code: code, output: output, status: status), at: 0)
    }

    /// The ladder's last rung: quit Lightkey (no questions, see `close`), make sure no olad is left,
    /// then run the start-up's own Lightkey steps again in order (Lightkey without the show, its MIDI
    /// input, the deck lights helper, Stream Deck restarted, the show), then the DMX link step again.
    private func relaunchForDMX(_ i: Int, next: @escaping () -> Void) {
        dmxLadder.relaunches += 1
        let n = dmxLadder.relaunches
        diagDMXRecovery("relaunch\(n)", "started")
        showWorkingSign(.dmxRestarting(n))
        setStep(i, .running, "Restarting Lightkey (try \(n) of 2): it hadn\u{2019}t picked the interface up.")
        dmxSnapshot("before-relaunch-\(n)")     // reads olad's log first: the new Lightkey overwrites it
        quitLightkey("DMX recovery") { closed in
            guard closed else {
                return self.failDMXLink(i, "Lightkey didn\u{2019}t close for the restart. " + dmxLadderTriedText(self.dmxLadder), next: next)
            }
            self.clearOrphanOlad("DMX recovery") {
                self.dmxLadder.hupTried = false
                self.dmxLadder.resetTried = false
                self.signDMXLinked = false
                self.frontAttempts = 0
                let ids: Set = ["lightkeyApp", "midi", "deckLights", "deck", "lightkey"]
                let steps = self.bootSteps.indices.filter { $0 < i && ids.contains(self.bootSteps[$0].id) }
                self.runSteps(steps) { self.runDMXLink(i, afterRelaunch: true, next: next) }
            }
        }
    }

    private func runSteps(_ steps: [Int], then done: @escaping () -> Void) {
        guard let first = steps.first else { return done() }
        runStep(first) { self.runSteps(Array(steps.dropFirst()), then: done) }
    }

    /// What Restart Lightkey… will do, for its approval sheet.
    func dmxRestartStepsText() -> String {
        let show = showName.map { ($0 as NSString).deletingPathExtension } ?? "the show"
        return """
        1. Quit Lightkey (press Quit if it asks; Force Quit after 15 seconds)
        2. /bin/kill -TERM <olad pid>   (only if Lightkey's olad is still running; -KILL after 3 s)
        3. Get the show started: open Lightkey, wait for its MIDI input, restart Stream Deck, open \(show)
        4. Check Lightkey takes the DMX interface (if not, the start-up's own reconnect steps)
        """
    }

    /// Restart Lightkey… from the "Lightkey is sending DMX" row, after someone pressed Run.
    func restartLightkeyForDMX() {
        guard !starting, !shuttingDown else { return }
        dmxRestartingByHand = true
        showWorkingSign(.dmxRestarting(1))
        dmxSnapshot("restart-by-hand")
        quitLightkey("Restart Lightkey") { closed in
            guard closed else {
                self.dmxRestartingByHand = false
                self.endWorkingSign(.dmxFailed, ok: false)
                return
            }
            self.clearOrphanOlad("Restart Lightkey") { self.startShow() }
        }
    }

    /// Reconnect the lights… ran (SIGHUP to olad, approved by a person): the sign says so while Booth
    /// Check checks for 12 seconds, then the row turns green or offers Restart Lightkey….
    func watchDMXReconnect() {
        dmxReconnectAt = Date()
        showWorkingSign(.dmxAskingOlad)
        let lk = NSRunningApplication.runningApplications(withBundleIdentifier: IDs.lightkey).first?.processIdentifier
        poll(every: 2, for: 12, background: true, { readDMXState(lightkeyPID: lk).held }) { ok in
            self.changes.insert(LogEntry(title: "Reconnect the lights: " + (ok ? "Lightkey has the DMX interface again" : "still not connected"),
                                         language: "Booth Check", code: "Check every 2 s for 12 s that Lightkey or olad holds the DMX interface",
                                         output: ok ? "Connected." : "Not held after 12 seconds. The row now offers Restart Lightkey\u{2026}", status: ok ? 0 : 1), at: 0)
            self.endWorkingSign(ok ? .dmxConnected : .dmxReconnectFailed, ok: ok)
            if !ok { self.dmxSnapshot("reconnect-failed") }
            self.refresh()
        }
    }

    /// Each pass, after the start-up: logs the DMX interface going and coming back (unplugged and
    /// replugged), and takes a snapshot when the DMX rows change (at most once a minute).
    func watchDMXRows(present: Bool, planes: DMXPlanes, rows: [Check]) {
        if let was = lastDMXPresent, was != present {
            if present { dmxFirstSeen = Date() }
            changes.insert(LogEntry(title: present ? "DMX interface plugged in again" : "DMX interface unplugged", language: "Terminal",
                                    code: commandLine("/usr/sbin/ioreg", ioUSBPlaneArgs) + "\n" + commandLine("/usr/sbin/ioreg", ioServicePlaneArgs),
                                    output: present ? "The DMX interface is back on USB (\(planes.text)). Lightkey\u{2019}s DMX server doesn\u{2019}t notice a replug by itself: if the lights don\u{2019}t come back, the \u{201C}Lightkey is sending DMX\u{201D} row offers Reconnect."
                                                    : "The DMX interface is no longer on USB.",
                                    status: present ? 0 : 1), at: 0)
        }
        lastDMXPresent = present
        let state = rows.map { "\($0.id)=\($0.status)" }.joined(separator: ",")
        defer { lastDMXRows = state }
        guard let was = lastDMXRows, was != state, !starting,
              Date().timeIntervalSince(lastMonitorSnapshot ?? .distantPast) > 60 else { return }
        lastMonitorSnapshot = Date()
        dmxSnapshot("monitor")
    }

    /// A DMX diagnostic snapshot: both USB planes' FTDI blocks, the serial devices, olad and Lightkey's
    /// processes, olad's log, the FTDI drivers, boot time and uptime, and this start-up's steps. Saved to
    /// ~/Library/Logs/Booth Check (the newest 30 kept), with one Log entry. olad's log is read here,
    /// straight away (a relaunch overwrites it); everything else off the main thread, never waited for.
    func dmxSnapshot(_ reason: String) {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let tf: (Date) -> String = { formatter.string(from: $0) }
        let olaLogPath = NSHomeDirectory() + "/Library/Logs/Lightkey OLA.log"
        let olaLog = (FileManager.default.contents(atPath: olaLogPath).map { String(decoding: $0, as: UTF8.self) }) ?? "(no file at \(olaLogPath))"
        let context = ["Reason: \(reason)", "Taken: \(tf(now))",
                       "Start-up began: " + (bootStartedAt.map(tf) ?? "(no start-up this session)") + (starting ? " (running)" : ""),
                       "DMX interface first seen: " + (dmxFirstSeen.map(tf) ?? "not seen") + (dmxSeenAtStart ? " (at the first look)" : ""),
                       "Lightkey running when the start-up began: \(lightkeyRunningAtStart ? "yes" : "no")",
                       "Recovery so far: " + dmxLadderTriedText(dmxLadder) + " Relaunches: \(dmxLadder.relaunches).",
                       "", "Start-up steps so far:"] + (bootTimeline.isEmpty ? ["(none)"] : bootTimeline)
        let lk = NSRunningApplication.runningApplications(withBundleIdentifier: IDs.lightkey).first?.processIdentifier
        DispatchQueue.global(qos: .utility).async {
            let st = readDMXState(lightkeyPID: lk)
            func section(_ title: String, _ body: String, max: Int = 8000) -> String {
                "==== \(title)\n" + capText(body.isEmpty ? "(nothing)" : body, maxBytes: max) + "\n"
            }
            func grep(_ s: String, _ word: String) -> String {
                s.split(separator: "\n").filter { $0.localizedCaseInsensitiveContains(word) }.joined(separator: "\n")
            }
            let devs = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []).filter { $0.hasPrefix("cu.usbserial") }.sorted().map { "/dev/" + $0 }
            let ls = devs.isEmpty ? "(no /dev/cu.usbserial* devices)" : shell("/bin/ls", ["-l"] + devs).out
            let ps = parsePs(shell("/bin/ps", psDMXArgs).out).filter { $0.isOlad || $0.isLightkey }
                .map { "\($0.pid) ppid \($0.ppid) started \($0.started.map(tf) ?? "?") etime \($0.etime)  \($0.args)" }.joined(separator: "\n")
            let kext = grep(shell("/usr/bin/kmutil", ["showloaded"]).out, "ftdi")
            let sysext = grep(shell("/usr/bin/systemextensionsctl", ["list"]).out, "ftdi")
            let boot = shell("/usr/sbin/sysctl", ["-n", "kern.boottime"]).out
            let up = shell("/usr/bin/uptime", []).out
            let found = olaFoundDevices(olaLog)
            let summary = dmxSnapshotSummary(planes: st.planes, held: st.held, olad: st.olad, found: found)
            let text = section("Booth Check DMX snapshot", context.joined(separator: "\n"), max: 12000)
                + section("Summary", summary)
                + section("IOUSB plane: ioreg -p IOUSB -l -w0 (FTDI blocks)", ftdiBlocks(st.usbOut).joined(separator: "\n\n"))
                + section("IOService plane: ioreg -r -c IOUSBHostDevice -l -w0 (FTDI blocks)", ftdiBlocks(st.serviceOut).joined(separator: "\n\n"))
                + section("ls -l /dev/cu.usbserial*", ls, max: 2000)
                + section("ps -axo pid,ppid,lstart,etime,args (olad and Lightkey)", ps.isEmpty ? "(neither running)" : ps, max: 4000)
                + section("~/Library/Logs/Lightkey OLA.log (overwritten at each Lightkey start)", olaLog, max: 20000)
                + section("kmutil showloaded | grep -i ftdi", kext.isEmpty ? "(no FTDI kext loaded)" : kext, max: 2000)
                + section("systemextensionsctl list | grep -i ftdi", sysext.isEmpty ? "(no FTDI system extension listed)" : sysext, max: 2000)
                + section("sysctl -n kern.boottime; uptime", boot + up, max: 1000)
            let dir = NSHomeDirectory() + "/Library/Logs/Booth Check"
            let path = dir + "/" + dmxSnapshotFileName(now, reason: reason)
            var saved = "Saved to \(path)"
            do {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try text.write(toFile: path, atomically: true, encoding: .utf8)
                let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
                for old in snapshotFilesToRemove(names) { try? FileManager.default.removeItem(atPath: dir + "/" + old) }
            } catch {
                saved = "Couldn\u{2019}t save it to \(path): \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                self.diagEvent("dmx_snapshot", ["reason": .string(reason), "present": .int(st.planes.present ? 1 : 0),
                                                "planes": .string(st.planes.text), "held": .int(st.held ? 1 : 0),
                                                "olad_age_s": .int(st.olad?.started.map { Int(now.timeIntervalSince($0)) } ?? -1),
                                                "ola_found": .int(found?.count ?? -1), "file": .string((path as NSString).lastPathComponent)])
                let failure = ["failed", "timeout", "skipped", "unconfirmed", "relaunch"].contains { reason.contains($0) }
                if self.dmxLadder.started || failure { self.diag.incident("dmx_\(reason)", text) }
                self.changes.insert(LogEntry(title: "DMX snapshot (\(reason))", language: "Terminal",
                                             code: ["ioreg -p IOUSB -l -w0", "ioreg -r -c IOUSBHostDevice -l -w0", "ls -l /dev/cu.usbserial*",
                                                    "ps -axo pid,ppid,lstart,etime,args", "cat ~/Library/Logs/Lightkey OLA.log",
                                                    "kmutil showloaded | grep -i ftdi", "systemextensionsctl list | grep -i ftdi",
                                                    "sysctl -n kern.boottime", "uptime"].joined(separator: "\n"),
                                             output: saved + "\n" + summary + (found.map { "\n" + $0.line } ?? ""), status: 0), at: 0)
            }
        }
    }
}

// MARK: - Shutting the booth down

extension Booth {
    /// Sets when the timed shutdown next warns: the next set time after `now`, or never when it's off.
    func armShutdown(after now: Date = Date()) {
        shutdownAt = autoShutdown ? nextShutdown(after: now, days: shutdownDays, minute: shutdownMinute) : nil
    }

    /// With the 15-second checks: when the set time comes, the warning goes up. Not while the start-up
    /// runs (it waits until that's done), and not if the Mac was off or asleep at the time.
    func checkShutdownTime() {
        guard let at = shutdownAt, !shuttingDown, !starting else { return }
        switch shutdownDue(now: Date(), at: at) {
        case .notYet: break
        case .missed: armShutdown()
        case .now:
            // Nov 2026: someone pressed a cue in the last 10 minutes, so the service may still be on.
            // That counts as Not yet: ask again in half an hour, as the button does.
            let used = LightkeyOutputWatch.shared.now()
            if lightkeyRecentlyUsed(lastAt: used.lastAt, now: ProcessInfo.processInfo.systemUptime) {
                shutdownAt = Date().addingTimeInterval(30 * 60)
                shutdownReason = .timed         // for the shutdown event's reason
                let ago = Int(ProcessInfo.processInfo.systemUptime - (used.lastAt ?? 0))
                logShutdown("not yet by itself", "It\u{2019}s the set time, but Lightkey reported a cue changing \(ago / 60) min \(ago % 60) s ago (on \u{201C}\(IDs.lightkeyMIDIOutput)\u{201D}), so the lights are probably in use. Asking again in 30 minutes.", status: nil)
                return
            }
            armShutdown()
            shutDownBooth(.timed)
        }
    }

    /// Keeps the screen on while Stays on for services is switched on and the Mac is on the charger
    /// (`keepsScreenOn`), with macOS's "keep the display awake" request, the one a video player
    /// holds. The user asked, 17 Oct 2026: on the church Mac, with the screen set never to turn off,
    /// it still went to the screen saver after a while untouched, and Stream Deck went with it. It
    /// changes no setting and ends when Booth Check quits. Starting and stopping it are logged.
    func keepScreenOn() {
        let want = keepsScreenOn(alwaysOn: setup.alwaysOn, onAC: onACPower())
        let code = "IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep, \u{201C}\(screenAssertionName)\u{201D})"
        if want, screenAssertion == 0 {
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn), screenAssertionName as CFString, &id)
            if r == kIOReturnSuccess {
                screenAssertion = id
                screenAssertionRefused = false
                changes.insert(LogEntry(title: "Screen: keep it on", language: "macOS", code: code,
                                        output: "Held while Booth Check runs on the charger. `pmset -g assertions` lists it.", status: 0), at: 0)
            } else if !screenAssertionRefused {
                screenAssertionRefused = true
                changes.insert(LogEntry(title: "Screen: keep it on", language: "macOS", code: code,
                                        output: "macOS said no (error \(r)).", status: r), at: 0)
            }
        } else if !want, screenAssertion != 0 {
            IOPMAssertionRelease(screenAssertion)
            screenAssertion = 0
            changes.insert(LogEntry(title: "Screen: let macOS turn it off again", language: "macOS",
                                    code: "IOPMAssertionRelease(\u{201C}\(screenAssertionName)\u{201D})",
                                    output: setup.alwaysOn ? "On battery." : "Stays on for services is switched off.", status: 0), at: 0)
        }
    }

    /// Hears the moment the power source changes; the 15-second checks back it up.
    func watchPower() {
        powerWasAC = onACPower()
        guard powerWatch == nil,
              let source = IOPSNotificationCreateRunLoopSource({ _ in
                  DispatchQueue.main.async { Booth.shared.checkPower() }
              }, nil)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerWatch = source
    }

    /// The power changed, or the 15-second checks came round: if the charger's power went off while
    /// Booth Check was running, warn and shut down (see `powerNext`); if it comes back during that
    /// warning, stop.
    func checkPower() {
        let onAC = onACPower()
        if powerWasAC != onAC { diagEvent("power_change", ["on_ac": .int(onAC ? 1 : 0)]) }
        if powerWasAC && !onAC {
            powerOutage = true
            logShutdown("the power went off", shutdownOnPowerOff
                        ? "Running on battery." : "Running on battery. Shut down when the power goes off is off, so nothing happens.",
                        status: nil)
        }
        powerWasAC = onAC
        switch powerNext(enabled: shutdownOnPowerOff, onAC: onAC, outage: powerOutage, handled: powerOutageWarned,
                         busy: starting || shuttingDown) {
        case .nothing: break
        case .warn:
            powerOutageWarned = true
            shutDownBooth(.powerOff)
        case .powerBack:
            if powerOutage, shuttingDown, shutdownReason == .powerOff, !closingApps {
                stopCountdown()
                SignOverlay.shared.stayedOn("The power came back.")
                logShutdown("stopped", "The power came back, so the Mac stays on.", status: nil)
            }
            powerOutage = false
            powerOutageWarned = false
        }
    }

    /// Shuts the booth down (the user asked for it, 6 Oct 2026): first a warning with Not yet (10
    /// seconds from the menu, 5 minutes at the set time, 1 minute when the power goes off), then every
    /// other app is asked to quit (`quitOtherApps`), then Stream Deck closes, then Lightkey (its quit question answered, made to quit if it hangs on, see
    /// `close`), then macOS shuts down. Closing
    /// the apps first also keeps macOS from reopening them at the next login, where they'd race the
    /// start-up. Every step is logged.
    func shutDownBooth(_ reason: ShutdownReason) {
        guard !shuttingDown, !starting else { return }
        shuttingDown = true
        shutdownReason = reason
        shutdownStartedAt = Date()
        shutdownMarks = [("start", ProcessInfo.processInfo.systemUptime)]
        shutdownClosed = [:]
        let warning = shutdownWarning(reason)
        logShutdown(reason == .button ? "someone clicked Shut down the booth" : reason == .timed ? "the set time came" : "the power is off",
                    "A \(countdownText(warning)) warning, with Not yet.", status: nil)
        var left = warning
        SignOverlay.shared.countdown(left, why: shutdownWhy(reason), notYet: { [weak self] in
            guard let self, !self.closingApps else { return }
            self.stopCountdown()
            SignOverlay.shared.hide()
            self.person("not_yet", ["trigger": .string(shutdownTrigger(reason)), "left_s": .int(max(left, 0)),
                                    "after_s": .int(Int(ProcessInfo.processInfo.systemUptime - (self.shutdownMarks.first?.at ?? 0)))])
            // At the set time, ask again in half an hour, so a Mac that's forgotten still goes off.
            // After a power cut, not again until the power comes back and goes off once more.
            if reason == .timed { self.shutdownAt = Date().addingTimeInterval(30 * 60) }
            self.logShutdown("Not yet", reason == .timed ? "Asking again in 30 minutes."
                             : reason == .powerOff ? "Not asking again until the power comes back and goes off again."
                             : "Nothing closed.", status: nil)
        }, now: { [weak self] in self?.closeAppsAndShutDown() })
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            left -= 1
            SignOverlay.shared.tick(max(left, 0))
            if left <= 0 { self?.closeAppsAndShutDown() }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func stopCountdown() {
        countdownTimer?.invalidate()
        shuttingDown = false
    }

    private func closeAppsAndShutDown() {
        guard shuttingDown, !closingApps else { return }
        closingApps = true
        countdownTimer?.invalidate()
        markShutdown("countdown")
        quitOtherApps {
            self.markShutdown("other_apps")
            self.blackoutBeforeClosing {
                self.markShutdown("blackout")
                self.closeBoothApps()
            }
        }
    }

    func markShutdown(_ name: String) { shutdownMarks.append((name, ProcessInfo.processInfo.systemUptime)) }

    /// shutdown_done: the trigger, each step's seconds (`markDurations`), how Stream Deck and Lightkey
    /// closed, and whether the Mac is going off or stayed on.
    func diagShutdownDone(_ result: String) {
        var props = markDurations(shutdownMarks)
        props.merge(shutdownClosed) { a, _ in a }
        props["trigger"] = .string(shutdownTrigger(shutdownReason))
        props["result"] = .string(result)
        props["blackout_on"] = .int(setup.blackoutAtShutdown ? 1 : 0)
        diagEvent("shutdown_done", props)
    }

    /// The shutdown's Blackout (1.30, see `blackoutPlan` and `blackoutNext`): with "Black out the stage
    /// first" on, sends the show's Blackout to Lightkey as the deck's Blackout key does, waits for
    /// Lightkey's report (at most 1.5 s, twice if a toggling Blackout went off), then 2 seconds for the
    /// lights. At most about 5 seconds; anything missing is logged and skipped. Only ever called by the
    /// shutdown, never by the checks, the start-up or the DMX recovery.
    private func blackoutBeforeClosing(then done: @escaping () -> Void) {
        guard setup.blackoutAtShutdown else { return done() }
        let source = blackoutSource(file: loadDeckShowFile(forShow: showPath)?.file, chosen: setup.deckProfile,
                                    profiles: readDeckProfiles().profiles)
        let midi = MIDIWatch.shared
        let plan = blackoutPlan(lightkeyRunning: !NSRunningApplication.runningApplications(withBundleIdentifier: IDs.lightkey).isEmpty,
                                destinations: midi.destinationNames(), sources: midi.sourceNames(), source: source)
        guard case .send(let note, let from) = plan else {
            if case .skip(let why) = plan { logShutdown("black out the stage", "Skipped: \(why)", status: nil) }
            return done()
        }
        SignOverlay.shared.present(.shuttingDown, banner: false, step: "Turning the stage lights off\u{2026}")
        var replies: [CueReply] = [], heard: [String] = [], sends = 0, sentAt = Date(), finished = false
        let stop = midi.listen(to: IDs.lightkeyMIDIOutput) { word in
            guard !finished, let r = cueReply(word, for: note) else { return }
            replies.append(r)
            heard.append("\(midiBytesText(word)) (\(r == .on ? "on" : "off"))")
        }
        guard let stop else {
            logShutdown("black out the stage", "Skipped: Booth Check couldn\u{2019}t listen to \u{201C}\(IDs.lightkeyMIDIOutput)\u{201D}, and doesn\u{2019}t send Blackout blind.", status: 1)
            return done()
        }
        func send() -> Bool {
            sends += 1
            replies = []
            sentAt = Date()
            let r = midi.sendNoteOn(note, to: IDs.lightkeyMIDIInput)
            logShutdown("black out the stage", "Send \(sends): \(r.detail) The note is \(from).", status: r.ok ? 0 : 1)
            return r.ok
        }
        func finish(_ outcome: String, on: Bool?, status: Int32?) {
            finished = true
            stop()
            logShutdown("black out the stage", outcome + (heard.isEmpty ? "" : " Heard from Lightkey: " + heard.joined(separator: ", ") + "."), status: status)
            diagEvent("shutdown_blackout", ["sends": .int(sends), "on": .string(on.map { $0 ? "yes" : "no" } ?? "unknown")])
            guard on != false, sends > 0 else { return done() }
            DispatchQueue.main.asyncAfter(deadline: .now() + blackoutFade) {
                self.logShutdown("black out the stage", "Waited \(Int(blackoutFade)) seconds for the lights, then carried on.", status: nil)
                done()
            }
        }
        func look() {
            switch blackoutNext(replies: replies, sends: sends, sinceSend: Date().timeIntervalSince(sentAt)) {
            case .wait: DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { look() }
            case .sendAgain:
                guard send() else { return finish("The second send failed; carrying on.", on: false, status: 1) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { look() }
            case .done(let on, let outcome): finish(outcome, on: on, status: on == false ? 1 : 0)
            }
        }
        guard send() else { return finish("Nothing was sent; carrying on.", on: false, status: 1) }
        look()
    }

    /// 1.30: every other app with a Dock icon (Chrome, Mail…) is asked to quit first, as Quit in its
    /// menu would, never forced: left open, macOS would reopen it at the next login. Up to 8 seconds,
    /// then the shutdown carries on regardless; an app still asking something holds up macOS's shut
    /// down, which the minute's wait in `closeBoothApps` covers.
    private func quitOtherApps(then done: @escaping () -> Void) {
        let running = NSWorkspace.shared.runningApplications
        let info: [RunningAppInfo] = running.map { ($0.bundleIdentifier, $0.localizedName ?? $0.bundleIdentifier ?? "pid \($0.processIdentifier)", $0.activationPolicy == .regular) }
        let apps = appsToQuitBeforeShutdown(info, selfID: Bundle.main.bundleIdentifier).map { running[$0] }
        let name = { (a: NSRunningApplication) in a.localizedName ?? a.bundleIdentifier ?? "pid \(a.processIdentifier)" }
        guard !apps.isEmpty else {
            logShutdown("quit the other apps", "No other apps were open.", status: nil)
            diagEvent("apps_quit_at_shutdown", ["apps": .string(""), "stayed": .string("")])
            return done()
        }
        let report = { (left: [NSRunningApplication]) in
            self.diagEvent("apps_quit_at_shutdown", ["apps": .string(apps.map(name).joined(separator: ",")),
                                                     "stayed": .string(left.map(name).joined(separator: ","))])
        }
        SignOverlay.shared.present(.shuttingDown, banner: false, step: "Closing the other apps\u{2026}")
        for a in apps {
            let asked = a.terminate()
            logShutdown("quit \(name(a))", asked ? "Asked it to quit (NSRunningApplication terminate, not forced)."
                                                 : "macOS didn\u{2019}t pass the request on (NSRunningApplication terminate returned false).",
                        status: asked ? 0 : 1)
        }
        let started = Date()
        func look() {
            let left = apps.filter { !$0.isTerminated }
            if left.isEmpty {
                logShutdown("quit the other apps", "All \(apps.count) closed after \(String(format: "%.1f", Date().timeIntervalSince(started))) s.", status: 0)
                report(left)
                return done()
            }
            if Date().timeIntervalSince(started) >= 8 {
                report(left)
                logShutdown("quit the other apps",
                            "Still open after 8 seconds: \(left.map(name).joined(separator: ", ")). Carrying on; one asking to save can hold up macOS\u{2019}s shut down.",
                            status: 1)
                return done()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { look() }
        }
        look()
    }

    private func closeBoothApps() {
        SignOverlay.shared.present(.shuttingDown, banner: false, step: "Closing Stream Deck\u{2026}")
        close(IDs.streamDeck, name: "Stream Deck", forceAfter: 5) { _ in
            self.markShutdown("stream_deck")
            SignOverlay.shared.present(.shuttingDown, banner: false, step: "Closing Lightkey\u{2026}")
            self.close(IDs.lightkey, name: "Lightkey", forceAfter: 15) { closed in
                self.markShutdown("lightkey")
                guard closed else {
                    return self.stayOn("Lightkey didn\u{2019}t close, even when made to quit, so Booth Check stopped there. Shut down from the Apple menu.")
                }
                SignOverlay.shared.present(.shuttingDown, banner: false, step: "Shutting down the Mac\u{2026}")
                // Diagnostics: shutdown_done, app_quit and the session summary go into the queue
                // ahead of one last send (at most 4 seconds), and the clean-exit marker goes.
                self.diagShutdownDone("shutting_down")
                self.endSession("shutdown_" + shutdownTrigger(self.shutdownReason))
                var went = false
                let shutDownNow = {
                    guard !went else { return }
                    went = true
                    self.diag.markCleanExit("the booth shuts down")
                    self.askMacOSToShutDown()
                }
                if self.setup.diagnostics { self.diag.flush(maxTime: 4) { shutDownNow() } }
                DispatchQueue.main.asyncAfter(deadline: .now() + (self.setup.diagnostics ? 4.5 : 0)) { shutDownNow() }
            }
        }
    }

    private func askMacOSToShutDown() {
        let script = "tell application \"System Events\" to shut down"
        let r = runAppleScript(script)
        changes.insert(LogEntry(title: "Shut down: asked macOS to shut down", language: "AppleScript", code: script,
                                output: r.out.isEmpty ? "(no output)" : r.out, status: r.code), at: 0)
        guard r.code == 0 else {
            return stayOn("macOS didn\u{2019}t let Booth Check shut it down (\(r.out)). Shut down from the Apple menu.")
        }
        // Booth Check quits with everything else. Still here after a minute: another app said no.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if self.shuttingDown {
                self.stayOn("macOS didn\u{2019}t finish shutting down: another app may be asking something. Shut down from the Apple menu.")
            }
        }
    }

    /// Asks an app to close and waits for it (see `quitNext`); nothing waits for a person (the user
    /// asked, 17 Oct 2026). Lightkey's "Are you sure you want to quit Lightkey?" gets Quit pressed
    /// (`pressQuitIfAsked`). Still open after `forceAfter` seconds, it's made to quit: Stream Deck has
    /// nothing to save, and for Lightkey that's Don't Save, which the guide says anyway (Booth Check
    /// always opens the chosen show file).
    private func close(_ bundleID: String, name: String, forceAfter: TimeInterval, logAs: String = "Shut down",
                       then done: @escaping (Bool) -> Void) {
        func logShutdown(_ what: String, _ output: String, status: Int32?) {
            self.logShutdown(what, output, status: status, prefix: logAs)
        }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !apps.isEmpty else {
            logShutdown("close \(name)", "It wasn\u{2019}t open.", status: nil)
            return done(true)
        }
        apps.forEach { $0.terminate() }
        let started = Date()
        let words = bundleID == IDs.lightkey ? lightkeyQuitWords(apps.first?.bundleURL) : nil
        var pressed = false, forced = false
        // For shutdown_done: whether it had to be made to quit, and whether its quit question got Quit pressed.
        let tag = bundleID == IDs.lightkey ? "lightkey" : "stream_deck"
        func note(_ closed: Bool) {
            guard logAs == "Shut down" else { return }
            shutdownClosed[tag + "_forced"] = .int(forced ? 1 : 0)
            if bundleID == IDs.lightkey { shutdownClosed["lightkey_quit_pressed"] = .int(pressed ? 1 : 0) }
            if !closed { shutdownClosed[tag + "_stuck"] = .int(1) }
        }
        func look() {
            let running = apps.contains { !$0.isTerminated }
            if running, !pressed, !forced, let words,
               apps.contains(where: { pressQuitIfAsked(pid: $0.processIdentifier, message: words.message, quit: words.quit) }) {
                pressed = true
                logShutdown("close \(name)", "\(name) asked \u{201C}\(words.message)\u{201D}, so Booth Check pressed \(words.quit).", status: 0)
            }
            switch quitNext(running: running, waited: Date().timeIntervalSince(started), forceAfter: forceAfter) {
            case .done:
                logShutdown("close \(name)", !forced ? "Closed."
                            : bundleID == IDs.lightkey
                            ? "It didn\u{2019}t close within \(Int(forceAfter)) seconds (it may have been asking to save the show), so it was made to quit, as Force Quit does. Changes to the show since it opened weren\u{2019}t saved, as with Don\u{2019}t Save."
                            : "It didn\u{2019}t close within \(Int(forceAfter)) seconds, so it was made to quit, as Force Quit does.",
                            status: 0)
                if forced && bundleID == IDs.lightkey {
                    reportError("LightkeyForceQuit", "\(logAs): Lightkey didn\u{2019}t close within \(Int(forceAfter)) s" + (pressed ? " after Booth Check pressed Quit on its question" : "") + ", so it was made to quit.")
                }
                note(true)
                done(true)
            case .wait:
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { look() }
            case .force:
                if !forced {
                    forced = true
                    apps.forEach { $0.forceTerminate() }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { look() }
            case .giveUp:
                logShutdown("close \(name)", "Still open, even after being made to quit.", status: 1)
                note(false)
                done(false)
            }
        }
        look()
    }

    private func stayOn(_ note: String) {
        closingApps = false
        shuttingDown = false
        SignOverlay.shared.stayedOn(note)
        logShutdown("the Mac stays on", note, status: 1)
        markShutdown("stayed_on")
        diagShutdownDone("stayed_on")
        diag.writeMarker(version: currentVersion)       // still running after all: the marker goes back
        reopenSession()
        reportError("ShutdownStayedOn", "Shut down (\(shutdownTrigger(shutdownReason))): " + note)
        diag.incident("shutdown_stayed_on", logText(since: shutdownStartedAt ?? Date().addingTimeInterval(-600)))
        diag.flush()
    }

    private func logShutdown(_ what: String, _ output: String, status: Int32?, prefix: String = "Shut down") {
        changes.insert(LogEntry(title: "\(prefix): \(what)", language: prefix, code: what, output: output, status: status), at: 0)
        if prefix == "Shut down" {
            diagEvent("shutdown", ["reason": .string("\(shutdownReason)"), "step": .string(what), "detail": .string(output)])
        }
    }

    /// Quits Lightkey the shutdown's way, with no one needed (see `close`), for a restart: the DMX
    /// recovery, Restart Lightkey…, and the start-up when Lightkey's MIDI input didn't appear. `why`
    /// heads its Log entries.
    func quitLightkey(_ why: String, then done: @escaping (Bool) -> Void) {
        close(IDs.lightkey, name: "Lightkey", forceAfter: 15, logAs: why, then: done)
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
        person("update", ["from": .string(currentVersion), "to": .string(r.version)])
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
                DispatchQueue.main.async {
                    self.changes.insert(e, at: 0)
                    self.diagEvent("update", ["from": .string(self.currentVersion), "to": .string(r.version),
                                              "step": .string(title), "result": .string(status == 0 ? "ok" : "failed")])
                }
            }
            func fail(_ s: String) {
                try? fm.removeItem(at: work)
                DispatchQueue.main.async {
                    self.diagEvent("update", ["from": .string(self.currentVersion), "to": .string(r.version),
                                              "step": .string("stopped"), "result": .string(s)])
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
            let u = shell("/usr/bin/ditto", unzipArgs, timeout: 120)
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
            let sig = shell("/usr/bin/codesign", sigArgs, timeout: 60)
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
                    self.quitReason = "update"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        self.endSession("update")
                        self.diag.markCleanExit("update to \(r.version) (quit refused, exit)")
                        exit(0)
                    }
                }
            }
        }
    }
}

// MARK: - The log on disk and diagnostics (pure parts, tested in tests/test_diagnostics.swift)

/// Where the log, the queue and the clean-exit marker live. Tests point it at a temporary folder.
struct DiagFiles {
    var logDir: String
    var supportDir: String
    var log: String { logDir + "/BoothCheck.log" }
    var queue: String { supportDir + "/aptabase-queue.jsonl" }
    /// Error reports waiting to go, one JSON line each (`DiagError`), next to the events' queue.
    var errors: String { supportDir + "/aptabase-errors.jsonl" }
    var marker: String { supportDir + "/running.json" }
    var lastVersion: String { supportDir + "/last-version.txt" }
    /// The session's running tallies (`SessionTally`), so a session the Mac never finished still gets its summary.
    var session: String { supportDir + "/session.json" }
    static let standard = DiagFiles(logDir: NSHomeDirectory() + "/Library/Logs/Booth Check",
                                    supportDir: NSHomeDirectory() + "/Library/Application Support/Booth Check")
}

func diskTime(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.string(from: d)
}

func indentLines(_ text: String, _ prefix: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { prefix + $0 }.joined(separator: "\n") + "\n"
}

/// One Log entry, in full, as it goes into BoothCheck.log.
func diskLogText(_ e: LogEntry) -> String {
    "\(diskTime(e.time))  [\(e.language)] \(e.title)" + (e.status.map { "  (status \($0))" } ?? "") + "\n"
        + indentLines(e.code, "    $ ") + indentLines(e.output, "    > ")
}

/// Whether a 15-second pass goes into the log in full: the first one, during a start-up, when any
/// check's status changed, and once an hour. Otherwise it gets one line (`passLogLine`).
func passLogIsFull(first: Bool, starting: Bool, changed: Bool, sinceLastFull: TimeInterval) -> Bool {
    first || starting || changed || sinceLastFull >= 3600
}

func passSignature(_ checks: [Check]) -> String { checks.map { "\($0.id)=\(statusWord($0.status))" }.joined(separator: ",") }

func passLogLine(_ time: Date, problems: Int) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm:ss"
    return "pass \(f.string(from: time)), \(problems) problem\(problems == 1 ? "" : "s"), unchanged\n"
}

func statusWord(_ s: Status) -> String {
    switch s { case .ok: return "ok"; case .warn: return "warn"; case .fail: return "fail"; case .unknown: return "unknown"; case .manual: return "manual" }
}

/// Rotate before writing when the log would pass `limit` (5 MB).
func logNeedsRotation(size: UInt64, adding: Int, limit: UInt64 = 5_000_000) -> Bool {
    size > 0 && size + UInt64(adding) > limit
}

/// Keeping `keep` files in all (the log and .1 to .keep-1): the one to delete, then the renames, in order.
func logRotationMoves(_ base: String, keep: Int = 5) -> (remove: String, moves: [(from: String, to: String)]) {
    let name = { (n: Int) in n == 0 ? base : "\(base).\(n)" }
    return (name(keep - 1), stride(from: keep - 2, through: 0, by: -1).map { (name($0), name($0 + 1)) })
}

// Scrubbing ------------------------------------------------------------------------------------------

/// What gets taken out of anything sent or saved as diagnostics.
struct ScrubContext {
    var home: String
    var users: [String]         // NSUserName, NSFullUserName
    var macs: [String]          // the computer name, the host name
    /// The names come from configd (the computer name, the Bonjour name) and the kernel (gethostname),
    /// never `ProcessInfo.hostName` or `Host.current()`, which can wait on DNS.
    static func current() -> ScrubContext {
        let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ""
        let local = (SCDynamicStoreCopyLocalHostName(nil) as String?) ?? ""
        var buf = [CChar](repeating: 0, count: 256)
        let host = gethostname(&buf, buf.count) == 0 ? String(cString: buf) : ""
        let short = host.hasSuffix(".local") ? String(host.dropLast(6)) : host
        return ScrubContext(home: NSHomeDirectory(), users: [NSFullUserName(), NSUserName()],
                            macs: [name, local, local.isEmpty ? "" : local + ".local", host, short, name.replacingOccurrences(of: " ", with: "-")])
    }
}

func shortHash(_ s: String) -> String { String(SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(6)) }

/// Replaces each match of `pattern`; `f` gets the match and its groups.
func regexReplace(_ s: String, _ pattern: String, _ f: ([String]) -> String) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
    let ns = s as NSString
    var out = s as NSString
    for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
        let groups = (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        out = out.replacingCharacters(in: m.range, with: f(groups)) as NSString
    }
    return out as String
}

/// The home folder becomes ~, the user's names <user>, the computer's name <mac>, USB serial numbers
/// and the serial in Stream Deck device ids ([4057/143/<serial>]) sn: plus the first 6 hex digits of
/// their SHA-256, emails <email>, IPv4 addresses <ip>; lines with
/// the Mac's own serial number or UUID go.
func scrub(_ text: String, _ c: ScrubContext) -> String {
    var s = text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.contains("IOPlatformSerialNumber") && !$0.contains("IOPlatformUUID") }.joined(separator: "\n")
    if c.home.count > 1 { s = s.replacingOccurrences(of: c.home, with: "~") }
    s = regexReplace(s, "\"(USB Serial Number|kUSBSerialNumberString|Serial Number)\" = \"(?!sn:)([^\"]*)\"") { "\"\($0[1])\" = \"sn:\(shortHash($0[2]))\"" }
    s = regexReplace(s, "(usbserial|usbmodem)-(?!sn:)([A-Za-z0-9]+)") { "\($0[1])-sn:\(shortHash($0[2]))" }
    s = regexReplace(s, "([Ss]erial:? )(?!sn:)([A-Za-z0-9]*[0-9][A-Za-z0-9]*)") { "\($0[1])sn:\(shortHash($0[2]))" }
    // Stream Deck device ids, @(1)[vendor/product/serial] (also with JSON's escaped slashes): the serial goes.
    s = regexReplace(s, "\\[([0-9]+)(\\\\?/)([0-9]+)(\\\\?/)(?!sn:)([A-Za-z0-9]+)\\]") { "[\($0[1])\($0[2])\($0[3])\($0[4])sn:\(shortHash($0[5]))]" }
    s = regexReplace(s, "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}") { _ in "<email>" }
    for u in c.users.filter({ $0.count >= 3 }).sorted(by: { $0.count > $1.count }) { s = s.replacingOccurrences(of: u, with: "<user>") }
    for m in c.macs.filter({ $0.count >= 3 }).sorted(by: { $0.count > $1.count }) { s = s.replacingOccurrences(of: m, with: "<mac>") }
    s = regexReplace(s, "\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b") { _ in "<ip>" }
    return s
}

// Aptabase events ------------------------------------------------------------------------------------

/// A prop or system prop value: Aptabase takes strings and numbers in props (isDebug is a bool).
enum DiagValue: Codable, Equatable {
    case string(String), int(Int), double(Double), bool(Bool)
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s) }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else { self = .double(try c.decode(Double.self)) }
    }
    var text: String {
        switch self { case .string(let s): return s; case .int(let i): return "\(i)"; case .double(let d): return "\(d)"; case .bool(let b): return "\(b)" }
    }
}

/// One event as queued: `id` is only for taking it off the queue; `time` is when it happened.
struct DiagEvent: Codable, Equatable {
    var id: String
    var time: Double
    var name: String
    var session: String
    var system: [String: DiagValue]
    var props: [String: DiagValue]
}

/// Cut to at most `max` UTF-16 units, never inside a character.
func truncateUTF16(_ s: String, _ max: Int) -> String {
    guard s.utf16.count > max else { return s }
    var out = "", n = 0
    for ch in s {
        let u = String(ch).utf16.count
        if n + u > max { break }
        out.append(ch); n += u
    }
    return out
}

/// The event made to pass the server's rules (name ≤ 60, keys 1-40, strings ≤ 170 UTF-16 units of
/// our 180, values strings or numbers), by truncating, so one bad event never spoils a batch.
func validDiagEvent(_ e: DiagEvent) -> DiagEvent {
    var e = e
    e.name = truncateUTF16(e.name.isEmpty ? "unnamed" : e.name, 60)
    func fix(_ d: [String: DiagValue], bools: Bool) -> [String: DiagValue] {
        var out: [String: DiagValue] = [:]
        for (k, v) in d {
            let key = truncateUTF16(k.trimmingCharacters(in: .whitespacesAndNewlines), 40)
            guard !key.isEmpty else { continue }
            switch v {
            case .string(let s): out[key] = .string(truncateUTF16(s, 170))
            case .bool(let b): out[key] = bools ? v : .int(b ? 1 : 0)
            case .double(let d): out[key] = d.isFinite ? v : .string("\(d)")
            case .int: out[key] = v
            }
        }
        return out
    }
    e.props = fix(e.props, bools: false)
    e.system = fix(e.system, bools: true)
    // The server answers 400 for the whole batch when a system prop is too long (live test, 14 Nov 2026:
    // "Locale must be a string with a maximum length of 10").
    if case .string(let l)? = e.system["locale"] { e.system["locale"] = .string(aptabaseLocale(l)) }
    return e
}

/// "en_US@rg=auzzzz" → "en-US": no @ options, a dash, at most 10 characters.
func aptabaseLocale(_ identifier: String) -> String {
    String((identifier.split(separator: "@").first.map(String.init) ?? identifier).replacingOccurrences(of: "_", with: "-").prefix(10))
}

func aptabaseTimestamp(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    return f.string(from: d)
}

/// The timestamp an event is sent with. The server rejects events over a day old (the booth Mac is off
/// for a week between services), so anything older than 20 hours goes as now, with its own time in
/// `at` and `late_h`; a clock that was ahead is sent as now too.
func sendStamp(eventTime: Date, now: Date) -> (timestamp: String, extra: [String: DiagValue]) {
    let age = now.timeIntervalSince(eventTime)
    if age > 20 * 3600 { return (aptabaseTimestamp(now), ["at": .string(aptabaseTimestamp(eventTime)), "late_h": .int(Int(age / 3600))]) }
    if age < -600 { return (aptabaseTimestamp(now), ["at": .string(aptabaseTimestamp(eventTime))]) }
    return (aptabaseTimestamp(eventTime), [:])
}

/// The POST body: a JSON array of at most 25 events in Aptabase's shape.
func aptabaseBatchBody(_ events: [DiagEvent], now: Date) -> Data {
    struct Wire: Encodable { let timestamp, sessionId, eventName: String; let systemProps, props: [String: DiagValue] }
    let wire = events.prefix(25).map { e -> Wire in
        let stamp = sendStamp(eventTime: Date(timeIntervalSince1970: e.time), now: now)
        let v = validDiagEvent(DiagEvent(id: e.id, time: e.time, name: e.name, session: e.session, system: e.system,
                                         props: e.props.merging(stamp.extra) { _, new in new }))
        return Wire(timestamp: stamp.timestamp, sessionId: v.session, eventName: v.name, systemProps: v.system, props: v.props)
    }
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? enc.encode(wire)) ?? Data("[]".utf8)
}

/// Text cut into pieces of at most `maxUnits` UTF-16 units, at line ends where a line fits. Joined
/// back together they give the text exactly.
func logChunkPieces(_ text: String, maxUnits: Int = 170) -> [String] {
    var pieces: [String] = [], cur = "", curUnits = 0
    func flush() { if !cur.isEmpty { pieces.append(cur); cur = ""; curUnits = 0 } }
    var lines = text.components(separatedBy: "\n")
    for i in 0..<(lines.count - 1) { lines[i] += "\n" }
    for line in lines where !line.isEmpty {
        let u = line.utf16.count
        if curUnits + u <= maxUnits { cur += line; curUnits += u; continue }
        flush()
        if u <= maxUnits { cur = line; curUnits = u; continue }
        for ch in line {
            let cu = String(ch).utf16.count
            if curUnits + cu > maxUnits { flush() }
            cur.append(ch); curUnits += cu
        }
    }
    flush()
    return pieces
}

/// An incident's text as log_chunk props: incident, part, parts and t00…t19. At most ~30 KB.
func logChunkProps(_ text: String, incident: String, maxBytes: Int = 30_000) -> [[String: DiagValue]] {
    let pieces = logChunkPieces(capText(text, maxBytes: maxBytes))
    let groups = stride(from: 0, to: pieces.count, by: 20).map { Array(pieces[$0..<min($0 + 20, pieces.count)]) }
    return groups.enumerated().map { n, g in
        var p: [String: DiagValue] = ["incident": .string(incident), "part": .int(n + 1), "parts": .int(groups.count)]
        for (i, piece) in g.enumerated() { p[String(format: "t%02d", i)] = .string(piece) }
        return p
    }
}

/// The text back from log_chunk props (for checking, and for reading an export).
func joinLogChunks(_ parts: [[String: DiagValue]]) -> String {
    parts.sorted { ($0["part"].map { Int($0.text) ?? 0 } ?? 0) < ($1["part"].map { Int($0.text) ?? 0 } ?? 0) }
        .map { p in (0..<20).compactMap { p[String(format: "t%02d", $0)]?.text }.joined() }.joined()
}

/// Which events go first when the queue is over its cap: log_chunk, then the rest, and app_start,
/// startup_*, shutdown and check_* last.
func diagPriority(_ name: String) -> Int {
    if name == "log_chunk" { return 0 }
    if name == "app_start" || name.hasPrefix("startup_") || name == "shutdown" || name.hasPrefix("check_") { return 2 }
    return 1
}

/// Indexes of the queued events to keep (oldest first in, oldest dropped first within a priority).
func trimDiagQueue(_ items: [(name: String, bytes: Int)], maxCount: Int = 3000, maxBytes: Int = 3_000_000) -> [Int] {
    var drop = Set<Int>(), count = items.count, bytes = items.reduce(0) { $0 + $1.bytes }
    for prio in 0...2 {
        for (i, it) in items.enumerated() where diagPriority(it.name) == prio {
            if count <= maxCount && bytes <= maxBytes { break }
            drop.insert(i); count -= 1; bytes -= it.bytes
        }
    }
    return items.indices.filter { !drop.contains($0) }
}

enum FlushOutcome: Equatable { case sent, retry, drop }

/// What a send's answer means. The server says 200 `{}` even when it drops invalid events (so they're
/// checked here first), and 200 with "error" in the body for a bad or locked key: keep those. 400:
/// the batch itself is bad, drop it. Network errors, 429, 5xx and anything else: keep, back off.
func aptabaseOutcome(status: Int?, body: String) -> FlushOutcome {
    guard let status else { return .retry }
    if (200..<300).contains(status) { return body.contains("\"error\"") ? .retry : .sent }
    return status == 400 ? .drop : .retry
}

// Aptabase error reports (Nov 2026): the dashboard's Errors page, one report per request ------------

let aptabaseErrorURL = URL(string: "https://us.aptabase.com/api/v0/error")!

/// One error report as queued in `aptabase-errors.jsonl` (`time`: when it happened; `session`: the
/// session it belongs to, the crashed one for a crash).
struct DiagError: Codable, Equatable {
    var id: String
    var time: Double
    var session: String
    var errorType: String
    var errorMessage: String
    var stackTrace: String?
    var severity: String            // fatal, error
    var kind: String                // crash, unhandled, handled
}

/// The POST body for one report, in Aptabase's error API shape (docs/error-api-openapi.yaml): the
/// required errorMessage (≤ 5000) and errorType (≤ 100), the rest optional, each cut to its limit, with
/// the app's own system props (the same sdkVersion and isDebug rule as the events).
func aptabaseErrorBody(_ e: DiagError, system: [String: DiagValue]) -> Data {
    func sys(_ key: String, _ max: Int) -> DiagValue? {
        if case .string(let s)? = system[key], !s.isEmpty { return .string(truncateUTF16(s, max)) }
        return nil
    }
    var body: [String: DiagValue] = [
        "errorMessage": .string(truncateUTF16(e.errorMessage.isEmpty ? e.errorType : e.errorMessage, 5000)),
        "errorType": .string(truncateUTF16(e.errorType, 100)),
        "timestamp": .string(aptabaseTimestamp(Date(timeIntervalSince1970: e.time))),
        "platform": .string("macOS"),
        "sessionId": .string(truncateUTF16(e.session, 100)),
        "severity": .string(e.severity), "kind": .string(e.kind)]
    if let s = e.stackTrace, !s.isEmpty { body["stackTrace"] = .string(truncateUTF16(s, 10000)) }
    for (key, max) in [("osName", 30), ("osVersion", 100), ("appVersion", 50), ("sdkVersion", 40)] { body[key] = sys(key, max) }
    if case .bool(let debug)? = system["isDebug"] { body["isDebug"] = .bool(debug) }
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? enc.encode(body)) ?? Data("{}".utf8)
}

/// What the error API's answer means: 202 (any 2xx) sent; no answer, 408, 429 or 5xx kept for later;
/// 403 (the month's error quota is used up, it resets on the 1st) and any other 4xx dropped.
func aptabaseErrorOutcome(status: Int?) -> FlushOutcome {
    guard let status else { return .retry }
    if (200..<300).contains(status) { return .sent }
    return status == 408 || status == 429 || status >= 500 ? .retry : .drop
}

/// Whether one more error report goes this session: each errorType once, at most `max` in all.
func errorReportAllowed(_ type: String, sent: Set<String>, max: Int = 10) -> Bool {
    !sent.contains(type) && sent.count < max
}

/// The last `lines` lines of Log entries (newest first, as `changes` holds them) as the log on disk
/// writes them: an error report's stackTrace.
func recentLogLines(_ entries: [LogEntry], lines: Int = 40) -> String {
    entries.reversed().map(diskLogText).joined().split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
}

/// A crash report's gist for the Errors page: errorType (the exception type), a message (exception,
/// signal, subtype, termination reason, the app's own last words such as a Swift fatal error) and the
/// crashed thread's frames, one per line. Reads macOS's .ips (a JSON header line, then the JSON report)
/// and the older .crash text. Nil when it's neither.
func crashReportGist(_ text: String) -> (type: String, message: String, stack: String)? {
    let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
    if parts.count == 2, let body = (try? JSONSerialization.jsonObject(with: Data(parts[1].utf8))) as? [String: Any] {
        let exc = body["exception"] as? [String: Any] ?? [:]
        let type = exc["type"] as? String ?? "Crash"
        let asi = (body["asi"] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }
            .flatMap { k, v in (v as? [String] ?? []).map { "\(k): \($0)" } }
        let words = [[type, exc["signal"] as? String].compactMap { $0 }.joined(separator: " "),
                     exc["subtype"] as? String, (body["termination"] as? [String: Any])?["indicator"] as? String].compactMap { $0 } + asi
        let images = body["usedImages"] as? [[String: Any]] ?? []
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = body["faultingThread"] as? Int ?? threads.firstIndex { $0["triggered"] as? Bool == true } ?? 0
        let frames = threads.indices.contains(faulting) ? threads[faulting]["frames"] as? [[String: Any]] ?? [] : []
        let stack = frames.enumerated().map { n, f -> String in
            let image = (f["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0]["name"] as? String : nil } ?? "???"
            let at = (f["symbol"] as? String).map { "\($0) + \(f["symbolLocation"] as? Int ?? 0)" }
                ?? String(format: "0x%llx", (f["imageOffset"] as? Int) ?? 0)
            return "\(n)  \(image)  \(at)"
        }.joined(separator: "\n")
        return (type, words.joined(separator: " \u{00B7} "), "Thread \(faulting) crashed:\n" + stack)
    }
    let lines = text.components(separatedBy: "\n")
    func value(_ label: String) -> String? {
        lines.first { $0.hasPrefix(label + ":") }.map { String($0.dropFirst(label.count + 1)).trimmingCharacters(in: .whitespaces) }
    }
    guard let exception = value("Exception Type") else { return nil }
    let type = exception.split(separator: " ").first.map(String.init) ?? exception
    let message = [exception, value("Exception Codes"), value("Termination Reason")].compactMap { $0 }.joined(separator: " \u{00B7} ")
    var stack: [String] = []
    if let start = lines.firstIndex(where: { $0.hasPrefix("Thread ") && $0.contains("Crashed") }) {
        stack = Array(lines[start...].prefix { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }
    return (type, message, stack.joined(separator: "\n"))
}

/// How the previous run ended: `running.json` left behind means it never got to quit; a crash report
/// newer than its start says it crashed (otherwise power loss or a force quit).
func previousExit(markerPresent: Bool, crashReportSinceStart: Bool, lastVersion: String?, currentVersion: String) -> String {
    if markerPresent { return crashReportSinceStart ? "crash" : "unclean" }
    guard let lastVersion else { return "first" }
    return lastVersion == currentVersion ? "clean" : "update"
}

func isBoothCheckCrashReport(_ name: String) -> Bool {
    (name.hasPrefix("Booth Check") || name.hasPrefix("BoothCheck")) && (name.hasSuffix(".ips") || name.hasSuffix(".crash"))
}

/// The newest of `reports` (name, modification date) written after `since`: the crash of the run that
/// started then.
func newestCrashReport(_ reports: [(name: String, modified: Date)], since: Date) -> String? {
    reports.filter { isBoothCheckCrashReport($0.name) && $0.modified > since }.max { $0.modified < $1.modified }?.name
}

/// A check going bad or coming good, from the diff of two passes.
struct CheckTransition: Equatable { let failed: Bool; let id, title, status, detail: String }

/// Compares the last definite results (`old`) with a new pass. A check is reported failing when it's
/// fail or warn and wasn't that before, recovered when it's ok after fail or warn. Unknown or manual
/// results carry the old one forward, so bad → unknown → ok still counts as recovered.
func checkTransitions(old: [Check], new: [Check]) -> (changes: [CheckTransition], baseline: [Check]) {
    let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var baseline: [Check] = [], out: [CheckTransition] = []
    func bad(_ s: Status) -> Bool { s == .fail || s == .warn }
    for c in new {
        let was = before[c.id]
        if c.status == .unknown || c.status == .manual { baseline.append(was ?? c); continue }
        baseline.append(c)
        if bad(c.status) && was?.status != c.status {
            out.append(CheckTransition(failed: true, id: c.id, title: c.title, status: statusWord(c.status), detail: c.detail))
        } else if c.status == .ok, let was, bad(was.status) {
            out.append(CheckTransition(failed: false, id: c.id, title: c.title, status: "ok", detail: c.detail))
        }
    }
    return (out, baseline)
}

/// The pass entries behind a check, for its incident.
func passTitlesForCheck(_ id: String) -> [String] {
    switch id {
    case "dmx": return ["USB devices", "USB devices (IOService plane)", "DMX interface: the two USB planes disagree"]
    case "dmxLive": return ["Lightkey's DMX server, olad (experimental)", "Lightkey's USB connections (experimental)", "Lightkey's open serial ports (experimental)", "Running apps"]
    case "show": return ["The show file", "Which show Lightkey has open", "Running apps"]
    case "lkpass": return ["Lightkey connects without the password"]
    case "midi": return ["Lightkey's MIDI input", "Running apps"]
    case "deck": return ["USB devices"]
    case "deckLights": return ["Deck lights helper installed", "Deck lights helper in launchd", "Deck lights helper's copy and log", "Deck lights helper's settings", "The deck lights helper's MIDI port", "The show's deck file"]
    case "deckProfile": return ["Stream Deck profiles", "Stream Deck's profile per deck"]
    case "ac": return ["Power source"]
    case "sleep", "lpm": return ["Sleep settings"]
    case "screen": return ["What keeps the screen on"]
    case "nap": return ["App Nap setting"]
    case "autoboot": return ["Starts from the charger"]
    case "upd": return ["Automatic macOS updates"]
    case "reopen": return ["Old apps reopen at start-up"]
    default: return ["Running apps"]
    }
}

/// A check's incident: the row itself, then the commands behind it with their output (each capped).
func checkIncidentText(_ c: Check, since: Date, entries: [LogEntry]) -> String {
    let titles = Set(passTitlesForCheck(c.id))
    return "Check \(c.id): \(c.title)\nStatus: \(statusWord(c.status)), failing since \(diskTime(since))\nDetail: \(c.detail)\n"
        + (c.fix.map { "Fix: \($0)\n" } ?? "")
        + entries.filter { titles.contains($0.title) }.map { e in
            diskLogText(LogEntry(title: e.title, language: e.language, code: e.code, output: capText(e.output, maxBytes: 8000), status: e.status))
        }.joined()
}

/// "lk,dmx,deck,helper,on,apps1" for app_start.
func setupTag(_ s: MacSetup) -> String {
    let apps = s.apps.filter(\.on).count
    return [s.lightkey ? "lk" : nil, s.lightkey && s.dmx ? "dmx" : nil, s.streamDeck ? "deck" : nil,
            s.deckLights == true ? "helper" : nil, s.alwaysOn ? "on" : nil, apps > 0 ? "apps\(apps)" : nil]
        .compactMap { $0 }.joined(separator: ",")
}

/// What the start-up's DMX recovery came to: none, sighup, reset, relaunch1/2, unconfirmed or failed.
func dmxRecoverySummary(_ l: DMXLadder, linked: Bool) -> String {
    if !l.started { return "none" }
    if l.unconfirmed { return "unconfirmed" }
    if !linked { return "failed" }
    if l.relaunches > 0 { return "relaunch\(l.relaunches)" }
    if l.resetPressed { return "reset" }
    return l.hupSent ? "sighup" : "none"
}

/// How many rungs of the start-up's DMX ladder actually did something: SIGHUP sent, Reset DMX Output
/// pressed, each Lightkey relaunch.
func dmxRungsRun(_ l: DMXLadder) -> Int { (l.hupSent ? 1 : 0) + (l.resetPressed ? 1 : 0) + l.relaunches }

// The session log (1.30): what the session_summary and session_row events are built from ------------
//
// The owner's question: a check that was red or orange but the service went ahead anyway probably
// isn't needed. So for each row, how long it wasn't OK in the session. Times here are session seconds,
// counted from launch with the monotonic clock (`ProcessInfo.systemUptime`, which stops while the Mac
// sleeps); wall-clock time only for timestamps. Start-ups aren't counted (rows are red while apps
// open, which says nothing), nor the shutdown's closing of the apps.

/// One check row's tally for the session.
struct RowTally: Codable, Equatable {
    var id: String
    var title: String
    var worst = "ok"                // the worst it got: ok, warn or fail
    var badSeconds: Double = 0      // not-OK time in spells that have ended
    var badSince: Double?           // when the current not-OK spell began; nil while OK
    var firstBadAt: Double?
    var spells = 0                  // how many times it went not-OK
    var everOK = false              // seen OK at least once (else it was not-OK the whole session)
    var fixClicks = 0               // its Fix button clicked
    var muted = false
    var lastAction: String?         // the last thing done for it ("fix:…", "run:…", "self_repair:…", "startup", "mute")
    var lastActionAt: Double?
    var clearedBy: String?          // what ended its last spell
}

/// The session as it stands; also saved to session.json so the next launch can report a session the
/// Mac never got to finish (power cut, force quit).
struct SessionTally: Codable, Equatable {
    var session: String
    var version: String
    var launch: String              // how Booth Check started (see `launchKind`)
    var startedWall: Double
    var elapsed: Double = 0         // session seconds when last saved
    var savedWall: Double = 0
    var passes = 0
    var startups = 0
    var startupReady: Bool?
    var startupSeconds: Double?
    var people = 0                  // person events this session
    var rows: [String: RowTally] = [:]
    var ended: String?              // how it ended, once it did
    var sent = false                // its summary is queued
}

func statusIsBad(_ s: Status) -> Bool { s == .fail || s == .warn }

func statusRank(_ word: String) -> Int { word == "fail" ? 2 : word == "warn" ? 1 : 0 }

/// What a row's not-OK spell ending is put down to: the last thing done for it since the spell began
/// (a second's slack), otherwise by_itself.
func clearedByText(_ r: RowTally) -> String {
    guard let since = r.badSince, let at = r.lastActionAt, let what = r.lastAction, at >= since - 1 else { return "by_itself" }
    return what
}

/// A spell that ended in a pass: the row, how long it lasted, what ended it.
struct RowCleared: Equatable { let id: String; let seconds: Double; let by: String }

private func endSpell(_ r: inout RowTally, at: Double, by: String) -> RowCleared? {
    guard let since = r.badSince else { return nil }
    r.badSeconds += max(0, at - since)
    r.clearedBy = by
    r.badSince = nil
    return RowCleared(id: r.id, seconds: max(0, at - since), by: by)
}

/// One pass into the tally. Unknown and manual results leave a row as it was (as `checkTransitions`
/// does); a row missing from the pass (muted, switched off in This Mac) ends its spell. Returns the
/// spells that ended.
@discardableResult
func tallyPass(_ t: inout SessionTally, _ checks: [Check], at: Double) -> [RowCleared] {
    t.passes += 1
    t.elapsed = max(t.elapsed, at)
    var out: [RowCleared] = []
    for c in checks where c.status != .unknown && c.status != .manual {
        var r = t.rows[c.id] ?? RowTally(id: c.id, title: c.title)
        r.title = c.title
        if statusIsBad(c.status) {
            if r.badSince == nil {
                r.badSince = at
                r.spells += 1
                if r.firstBadAt == nil { r.firstBadAt = at }
            }
            let word = statusWord(c.status)
            if statusRank(word) > statusRank(r.worst) { r.worst = word }
        } else {
            if let cleared = endSpell(&r, at: at, by: clearedByText(r)) { out.append(cleared) }
            r.everOK = true
        }
        t.rows[c.id] = r
    }
    let present = Set(checks.map(\.id))
    for id in t.rows.keys.sorted() where !present.contains(id) && t.rows[id]?.badSince != nil {
        var r = t.rows[id]!
        if let cleared = endSpell(&r, at: at, by: r.muted ? "muted" : "gone") { out.append(cleared) }
        t.rows[id] = r
    }
    return out
}

/// Something done for a row: "fix:<button>" (its Fix clicked), "run:<key>" (a change run), "mute",
/// "unmute", "startup" (Get the show started), "self_repair:<what>" (Booth Check fixing it).
func tallyAction(_ t: inout SessionTally, row: String, title: String? = nil, what: String, at: Double) {
    var r = t.rows[row] ?? RowTally(id: row, title: title ?? row)
    r.lastAction = what
    r.lastActionAt = at
    if what.hasPrefix("fix:") { r.fixClicks += 1 }
    if what == "mute" { r.muted = true }
    if what == "unmute" { r.muted = false }
    t.rows[row] = r
}

/// A self_repair's `what` → the rows it works on.
func selfRepairRows(_ what: String) -> [String] {
    switch what {
    case "deck_profile", "deck_profile_restore": return ["deckProfile"]
    case "streamdeck_restart", "streamdeck_open": return ["deckapp", "deck"]
    case "helper_restart": return ["deckLights"]
    case "lightkey_no_password": return ["lkpass"]
    case _ where what.hasPrefix("login_"): return [String(what.dropFirst(6))]     // a login row fixed at the start-up
    default: return []
    }
}

/// One session_row's props: a row that was warn or fail at some point.
func sessionRowProps(_ r: RowTally, at: Double, sessionSeconds: Double) -> [String: DiagValue] {
    let bad = r.badSeconds + (r.badSince.map { max(0, at - $0) } ?? 0)
    let share = sessionSeconds > 0 ? min(100, Int((bad / sessionSeconds * 100).rounded())) : 0
    return ["check": .string(r.id), "title": .string(r.title), "worst": .string(r.worst),
            "bad_s": .int(Int(bad.rounded())), "share_pct": .int(share),
            "whole": .int(r.everOK ? 0 : 1), "bad_at_end": .int(r.badSince != nil ? 1 : 0),
            "spells": .int(r.spells), "first_bad_s": .int(Int((r.firstBadAt ?? 0).rounded())),
            "fix_clicks": .int(r.fixClicks), "muted": .int(r.muted ? 1 : 0),
            "cleared_by": .string(r.badSince != nil ? "still_bad" : r.clearedBy ?? "")]
}

/// session_summary's props.
func sessionSummaryProps(_ t: SessionTally, at: Double, ended: String) -> [String: DiagValue] {
    let bad = t.rows.values.filter { $0.spells > 0 }
    return ["ended": .string(ended), "session_s": .int(Int(at.rounded())), "launch_how": .string(t.launch), "version": .string(t.version),
            "started": .string(aptabaseTimestamp(Date(timeIntervalSince1970: t.startedWall))),
            "startups": .int(t.startups),
            "startup": .string(t.startupReady.map { $0 ? "ready" : "not_ready" } ?? "none"),
            "startup_s": .int(Int((t.startupSeconds ?? 0).rounded())), "passes": .int(t.passes),
            "rows": .int(t.rows.count), "rows_ok": .int(t.rows.count - bad.count), "rows_bad": .int(bad.count),
            "bad_at_end": .int(bad.filter { $0.badSince != nil }.count), "people": .int(t.people),
            "bad_rows": .string(bad.map(\.id).sorted().joined(separator: ","))]
}

/// The end of a session as events: session_summary, then a session_row for each row that was ever warn
/// or fail (the most not-OK time first). All carry `ended` and, when sent, the same session id.
func sessionEvents(_ t: SessionTally, at: Double, ended: String) -> [(name: String, props: [String: DiagValue])] {
    let bad = t.rows.values.filter { $0.spells > 0 }
        .map { ($0, sessionRowProps($0, at: at, sessionSeconds: at)) }
        .sorted { a, b in
            let x = Int(a.1["bad_s"]?.text ?? "0") ?? 0, y = Int(b.1["bad_s"]?.text ?? "0") ?? 0
            return x != y ? x > y : a.0.id < b.0.id
        }
    return [("session_summary", sessionSummaryProps(t, at: at, ended: ended))]
        + bad.map { ("session_row", $0.1.merging(["ended": .string(ended)]) { a, _ in a }) }
}

/// The session's end in the log on disk: one line for the session, one per row that wasn't OK.
func sessionLogText(_ events: [(name: String, props: [String: DiagValue])], time: Date) -> String {
    events.map { eventLogLine($0.name, $0.props, time: time) }.joined()
}

/// An event as one line in the log on disk: `<time>  event <name>: key=value …`, keys sorted, values
/// with spaces quoted, newlines folded.
func eventLogLine(_ name: String, _ props: [String: DiagValue], time: Date) -> String {
    let parts = props.sorted { $0.key < $1.key }.map { k, v -> String in
        let s = v.text.replacingOccurrences(of: "\n", with: " / ")
        if case .string = v, s.isEmpty || s.contains(" ") || s.contains("=") { return "\(k)=\"\(s.replacingOccurrences(of: "\"", with: "'"))\"" }
        return "\(k)=\(s)"
    }
    return "\(diskTime(time))  event \(name)" + (parts.isEmpty ? "" : ": " + parts.joined(separator: " ")) + "\n"
}

/// The time between marks as "<name>_s" props (one decimal), and total_s from the first mark to the last.
func markDurations(_ marks: [(name: String, at: Double)]) -> [String: DiagValue] {
    var out: [String: DiagValue] = [:]
    for (a, b) in zip(marks, marks.dropFirst()) { out[b.name + "_s"] = .double((max(0, b.at - a.at) * 10).rounded() / 10) }
    if let f = marks.first, let l = marks.last { out["total_s"] = .double((max(0, l.at - f.at) * 10).rounded() / 10) }
    return out
}

/// The start-up's steps at its end: how many, and how many ended done, warn, failed or never ran.
func startupStepCounts(_ states: [StepState]) -> [String: DiagValue] {
    ["steps": .int(states.count), "steps_ok": .int(states.filter { $0 == .done }.count),
     "steps_warn": .int(states.filter { $0 == .warn }.count), "steps_failed": .int(states.filter { $0 == .failed }.count),
     "steps_not_run": .int(states.filter { $0 == .waiting || $0 == .running }.count)]
}

/// The This Mac settings that differ between two setups (top-level keys of their saved JSON).
func changedSetupKeys(_ a: MacSetup, _ b: MacSetup) -> [String] {
    let enc = JSONEncoder()
    enc.outputFormatting = .sortedKeys
    func dict(_ s: MacSetup) -> [String: Any] {
        (try? enc.encode(s)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
    let x = dict(a), y = dict(b)
    return Set(x.keys).union(y.keys).filter { k in
        switch (x[k], y[k]) {
        case (nil, nil): return false
        case let (p?, q?): return !(p as AnyObject).isEqual(q)
        default: return true
        }
    }.sorted()
}

/// How Booth Check was started: login_flag (`--login`, testing), login_item (macOS opened it at
/// login), after_restart (in the first 3 minutes after a start), by_hand (someone opened it).
func launchKind(flag: Bool, loginItemEvent: Bool, uptime: Double) -> String {
    if flag { return "login_flag" }
    if loginItemEvent { return "login_item" }
    return uptime < 180 ? "after_restart" : "by_hand"
}

// MARK: - The log on disk and diagnostics (files and network; one serial queue, never the main thread)

/// Sends a request and calls back with the HTTP status (nil on a network error) and the body. Tests
/// inject their own; the app's is an ephemeral URLSession.
typealias DiagTransport = (URLRequest, @escaping (Int?, Data?, Error?) -> Void) -> Void

let aptabaseURL = URL(string: "https://us.aptabase.com/api/v0/events")!

final class Diagnostics {
    static let shared = Diagnostics(files: .standard,
                                    appKey: (Bundle.main.object(forInfoDictionaryKey: "AptabaseAppKey") as? String).flatMap { $0.isEmpty ? nil : $0 },
                                    transport: Diagnostics.urlSessionTransport)

    static let urlSessionTransport: DiagTransport = { request, done in
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        URLSession(configuration: config).dataTask(with: request) { data, response, error in
            done(error == nil ? (response as? HTTPURLResponse)?.statusCode : nil, data, error)
        }.resume()
    }

    let files: DiagFiles
    let appKey: String?
    let transport: DiagTransport
    let queue = DispatchQueue(label: "app.boothcheck.diagnostics", qos: .utility)
    let session = UUID().uuidString.lowercased()
    let launchedAt = Date()
    /// Built once, on `queue` at launch (see init); read from any thread under the lock.
    private let scrubLock = NSLock()
    private var builtScrubContext: ScrubContext?
    var scrubContext: ScrubContext {
        scrubLock.lock(); defer { scrubLock.unlock() }
        if let c = builtScrubContext { return c }
        let c = ScrubContext.current()
        builtScrubContext = c
        return c
    }
    var systemProps: [String: DiagValue] = [:]
    /// Read and set on `queue` (set it with `setEnabled`).
    private(set) var enabled = true
    private var seq = 0
    private var appendsSinceTrim = 0
    private var backoff: TimeInterval = 0
    private var backoffUntil: Date?
    private var lastRequest = Date.distantPast
    /// Error report types queued this session (on `queue`; see `errorReportAllowed`).
    private var errorTypesSent: Set<String> = []
    /// On the main thread: incidents sent this launch (at most 6), and where the Network Log entries go.
    var incidents = 0
    var onLog: ((LogEntry) -> Void)?

    init(files: DiagFiles, appKey: String?, transport: @escaping DiagTransport) {
        self.files = files
        self.appKey = appKey
        self.transport = transport
        queue.async { _ = self.scrubContext }
    }

    func setEnabled(_ on: Bool) { queue.async { self.enabled = on } }

    // The log on disk -----------------------------------------------------------------------------

    /// Appends text to BoothCheck.log (rotating at 5 MB, 5 files kept), off the main thread.
    func write(_ text: String) { queue.async { self.appendToLog(text) } }

    func appendToLog(_ text: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: files.logDir, withIntermediateDirectories: true)
        let data = Data(text.utf8)
        let size = ((try? fm.attributesOfItem(atPath: files.log))?[.size] as? NSNumber)?.uint64Value ?? 0
        if logNeedsRotation(size: size, adding: data.count) {
            let plan = logRotationMoves(files.log)
            try? fm.removeItem(atPath: plan.remove)
            for m in plan.moves where fm.fileExists(atPath: m.from) { try? fm.moveItem(atPath: m.from, toPath: m.to) }
        }
        if !fm.fileExists(atPath: files.log) { fm.createFile(atPath: files.log, contents: nil) }
        guard let h = FileHandle(forWritingAtPath: files.log) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
    }

    /// The end of the log as it stands (the previous run's tail, read before this run's header).
    func logTail(maxBytes: Int) -> String {
        guard let h = FileHandle(forReadingAtPath: files.log) else { return "" }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0)
        return String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
    }

    // The clean-exit marker ---------------------------------------------------------------------------

    func writeMarker(version: String) {
        try? FileManager.default.createDirectory(atPath: files.supportDir, withIntermediateDirectories: true)
        let json = "{\"pid\":\(ProcessInfo.processInfo.processIdentifier),\"version\":\"\(version)\",\"started\":\"\(aptabaseTimestamp(launchedAt))\",\"start\":\(launchedAt.timeIntervalSince1970)}\n"
        FileManager.default.createFile(atPath: files.marker, contents: Data(json.utf8))
    }

    /// Booth Check is about to end on purpose (quit, update, shutdown): the marker goes, at once, on
    /// the calling thread, so nothing can come between.
    func markCleanExit(_ why: String) {
        try? FileManager.default.removeItem(atPath: files.marker)
        write("\(diskTime(Date()))  ==== Booth Check ends: \(why) (clean-exit marker removed)\n")
    }

    // The session's tallies on disk ---------------------------------------------------------------------

    /// Saves session.json (a few KB; atomic). Safe from any thread: each write replaces the file whole.
    func writeSession(_ data: Data) {
        try? FileManager.default.createDirectory(atPath: files.supportDir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: files.session), options: .atomic)
    }

    func readSession() -> SessionTally? {
        FileManager.default.contents(atPath: files.session).flatMap { try? JSONDecoder().decode(SessionTally.self, from: $0) }
    }

    /// At launch, before anything else is written: how the previous run ended, and its log's tail.
    func readPreviousRun(currentVersion: String) -> (exit: String, tail: String, detail: String, crashPath: String?) {
        let fm = FileManager.default
        let marker = fm.contents(atPath: files.marker).map { String(decoding: $0, as: UTF8.self) }
        var crash: String?
        let dir = NSHomeDirectory() + "/Library/Logs/DiagnosticReports"
        if let marker {
            let start = regexReplace(marker, "^.*\"start\":([0-9.]+).*$") { $0[1] }
            let since = Date(timeIntervalSince1970: Double(start.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
            let reports = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter(isBoothCheckCrashReport).compactMap { name in
                ((try? fm.attributesOfItem(atPath: dir + "/" + name))?[.modificationDate] as? Date).map { (name: name, modified: $0) }
            }
            crash = newestCrashReport(reports, since: since)
        }
        let last = fm.contents(atPath: files.lastVersion).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        let exit = previousExit(markerPresent: marker != nil, crashReportSinceStart: crash != nil, lastVersion: last, currentVersion: currentVersion)
        let detail = "Previous run: \(exit)" + (marker.map { ". running.json was left: \($0.trimmingCharacters(in: .whitespacesAndNewlines))" } ?? "")
            + (crash.map { ". Crash report: \($0)" } ?? "") + (last.map { ". Last version: \($0)" } ?? "")
        try? fm.createDirectory(atPath: files.supportDir, withIntermediateDirectories: true)
        fm.createFile(atPath: files.lastVersion, contents: Data((currentVersion + "\n").utf8))
        return (exit, marker != nil ? logTail(maxBytes: 30_000) : "", detail, crash.map { dir + "/" + $0 })
    }

    // Events and the queue ------------------------------------------------------------------------------

    /// One event: a line in the log on disk (always, so the log has it with diagnostics off too), and
    /// queued for Aptabase (scrubbed, validated, with seq and launch; nothing when switched off or keyless).
    func event(_ name: String, _ props: [String: DiagValue] = [:], time: Date = Date()) {
        queue.async { self.record(name, props, time: time) }
    }

    /// `event` on the queue. `sid`: another session's id (the previous session's summary, sent late).
    func record(_ name: String, _ props: [String: DiagValue], time: Date, session sid: String? = nil) {
        appendToLog(eventLogLine(name, props, time: time))
        enqueue(name, props, time: time, session: sid)
    }

    func enqueue(_ name: String, _ props: [String: DiagValue], time: Date, session sid: String? = nil) {
        guard enabled, appKey != nil else { return }
        seq += 1
        // log_chunk text is scrubbed whole before it's cut up (see `incident`).
        var p = name == "log_chunk" ? props
            : props.mapValues { v -> DiagValue in if case .string(let s) = v { return .string(scrub(s, scrubContext)) }; return v }
        p["seq"] = .int(seq)
        p["launch"] = .string(sid ?? session)
        let e = validDiagEvent(DiagEvent(id: UUID().uuidString, time: time.timeIntervalSince1970, name: name, session: sid ?? session,
                                         system: systemProps, props: p))
        guard var line = try? JSONEncoder().encode(e) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(atPath: files.supportDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: files.queue) { fm.createFile(atPath: files.queue, contents: nil) }
        if let h = FileHandle(forWritingAtPath: files.queue) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
            try? h.close()
        }
        appendsSinceTrim += 1
        let size = ((try? fm.attributesOfItem(atPath: files.queue))?[.size] as? NSNumber)?.intValue ?? 0
        if appendsSinceTrim >= 100 || size > 3_000_000 { trimQueue() }
    }

    /// A queue file: one JSON value per line (the events' queue, the error reports').
    func loadLines<T: Decodable>(_ path: String) -> [T] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? JSONDecoder().decode(T.self, from: Data($0)) }
    }

    func saveLines<T: Encodable>(_ items: [T], to path: String) {
        let enc = JSONEncoder()
        var data = Data()
        for e in items { if let l = try? enc.encode(e) { data.append(l); data.append(0x0A) } }
        try? FileManager.default.createDirectory(atPath: files.supportDir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func loadQueue() -> [DiagEvent] { loadLines(files.queue) }
    func saveQueue(_ events: [DiagEvent]) { saveLines(events, to: files.queue) }

    // Error reports (the Errors page) -------------------------------------------------------------------

    /// One error report, off the main thread (see `recordError`). `recent`: the Log's newest entries,
    /// whose last 40 lines become the stackTrace when none is given.
    func error(_ type: String, _ message: String, stack: String? = nil, recent: [LogEntry] = [],
               severity: String = "error", kind: String = "handled", session sid: String? = nil, time: Date = Date()) {
        queue.async {
            self.recordError(type, message, stack: stack ?? recentLogLines(recent), severity: severity, kind: kind, session: sid, time: time)
        }
    }

    /// `error` on the queue: a line in the log on disk always; queued for Aptabase (scrubbed) when
    /// diagnostics are on with a key, each errorType once a session and at most 10 (`errorReportAllowed`).
    func recordError(_ type: String, _ message: String, stack: String, severity: String, kind: String, session sid: String?, time: Date) {
        guard errorReportAllowed(type, sent: errorTypesSent) else {
            appendToLog("\(diskTime(Date()))  error report \(type): not sent again (each type once a session, at most 10)\n")
            return
        }
        errorTypesSent.insert(type)
        appendToLog("\(diskTime(time))  error report \(type) (\(severity), \(kind)): \(message)\n")
        guard enabled, appKey != nil else { return }
        let ctx = scrubContext
        let e = DiagError(id: UUID().uuidString, time: time.timeIntervalSince1970, session: sid ?? session, errorType: type,
                          errorMessage: truncateUTF16(scrub(message, ctx), 5000),
                          stackTrace: stack.isEmpty ? nil : truncateUTF16(scrub(stack, ctx), 10000), severity: severity, kind: kind)
        // A Mac offline for weeks keeps the newest 100.
        saveLines(Array(((loadLines(files.errors) as [DiagError]) + [e]).suffix(100)), to: files.errors)
    }

    func trimQueue() {
        appendsSinceTrim = 0
        let events = loadQueue()
        let enc = JSONEncoder()
        let keep = trimDiagQueue(events.map { ($0.name, ((try? enc.encode($0))?.count ?? 0) + 1) })
        if keep.count < events.count {
            saveQueue(keep.map { events[$0] })
            appendToLog("\(diskTime(Date()))  Diagnostics queue over its cap: dropped \(events.count - keep.count) of \(events.count) events (log_chunk first)\n")
        }
    }

    func clearQueue() {
        queue.async {
            try? FileManager.default.removeItem(atPath: self.files.queue)
            try? FileManager.default.removeItem(atPath: self.files.errors)
        }
    }

    // Sending -----------------------------------------------------------------------------------------

    /// Sends the queue in batches of 25, one request a second at most, until it's empty, a send fails
    /// (then it backs off: 1 minute, doubling to 30) or `deadline` passes. Returns the Network Log
    /// entries. Runs on the calling thread: `flush` puts it on the queue.
    func flushSync(deadline: Date? = nil, ignoreBackoff: Bool = false) -> [LogEntry] {
        guard enabled else { return [] }
        guard let key = appKey else {
            return [LogEntry(title: "Diagnostics: nothing sent", language: "Network", code: "POST \(aptabaseURL.absoluteString)",
                             output: "This build has no Aptabase key (aptabase.key wasn\u{2019}t there when it was built), so Booth Check sends nothing.", status: nil)]
        }
        if !ignoreBackoff, let until = backoffUntil, until > Date() { return [] }
        var logs: [LogEntry] = []
        var retry = false
        while true {
            let all = loadQueue()
            guard !all.isEmpty else { break }
            let batch = Array(all.prefix(25))
            let body = aptabaseBatchBody(batch, now: Date())
            guard let answer = post(aptabaseURL, body, key: key, deadline: deadline) else { break }
            let (status, reply, failure) = answer
            let outcome = aptabaseOutcome(status: failure == nil ? status : nil, body: reply)
            let ids = Set(batch.map(\.id))
            let left = outcome == .retry ? all.count : all.count - batch.count
            if outcome != .retry { saveQueue(all.filter { !ids.contains($0.id) }) }
            noteOutcome(outcome)
            var names: [String: Int] = [:]
            batch.forEach { names[$0.name, default: 0] += 1 }
            let what = names.sorted { $0.key < $1.key }.map { "\($0.key) \u{00D7}\($0.value)" }.joined(separator: ", ")
            logs.append(LogEntry(title: "Diagnostics: " + (outcome == .sent ? "sent \(batch.count) events" : outcome == .drop ? "the server refused \(batch.count) events (dropped)" : "couldn\u{2019}t send \(batch.count) events (kept)"),
                                 language: "Network",
                                 code: "POST \(aptabaseURL.absoluteString)\n\(batch.count) events, \(body.count) bytes: \(what)",
                                 output: (failure.map { "Network error: \($0)" } ?? "HTTP \(status ?? 0): \(reply.isEmpty ? "(empty)" : capText(reply, maxBytes: 2000))")
                                    + "\nLeft in the queue: \(left)" + (outcome == .retry ? ". Trying again in \(Int(backoff / 60)) min or with Send now." : ""),
                                 status: outcome == .sent ? 0 : 1))
            if body.count <= 16_000 { appendToLog("\(diskTime(Date()))  Diagnostics body sent:\n" + indentLines(String(decoding: body, as: UTF8.self), "    ")) }
            // The answer on disk too (at quit, the Log's own entry never reaches the disk).
            appendToLog("\(diskTime(Date()))  Diagnostics answer: " + (failure.map { "network error: \($0)" } ?? "HTTP \(status ?? 0) \(capText(reply, maxBytes: 300))")
                        + " \u{2192} \(outcome == .sent ? "sent" : outcome == .drop ? "dropped" : "kept") \(batch.count) events (\(what))\n")
            if outcome == .retry { retry = true; break }
        }
        // Then the error reports, one per request (the error API takes a single report).
        while !retry {
            let all: [DiagError] = loadLines(files.errors)
            guard let e = all.first else { break }
            guard let answer = post(aptabaseErrorURL, aptabaseErrorBody(e, system: systemProps), key: key, deadline: deadline) else { break }
            let (status, reply, failure) = answer
            let outcome = aptabaseErrorOutcome(status: failure == nil ? status : nil)
            if outcome != .retry { saveLines(all.filter { $0.id != e.id }, to: files.errors) }
            noteOutcome(outcome)
            let said = failure.map { "Network error: \($0)" } ?? "HTTP \(status ?? 0): \(reply.isEmpty ? "(empty)" : capText(reply, maxBytes: 500))"
            logs.append(LogEntry(title: "Diagnostics: " + (outcome == .sent ? "sent error report \(e.errorType)" : outcome == .drop ? "the server refused error report \(e.errorType) (dropped)" : "couldn\u{2019}t send error report \(e.errorType) (kept)"),
                                 language: "Network", code: "POST \(aptabaseErrorURL.absoluteString)\nerrorType \(e.errorType), \(e.severity), \(e.kind)",
                                 output: said + "\nError reports left: \(outcome == .retry ? all.count : all.count - 1)", status: outcome == .sent ? 0 : 1))
            appendToLog("\(diskTime(Date()))  Diagnostics answer (error report \(e.errorType)): \(said) \u{2192} \(outcome == .sent ? "sent" : outcome == .drop ? "dropped" : "kept")\n")
            if outcome == .retry { break }
        }
        return logs
    }

    /// One POST with the App-Key, at most one a second, waiting for the answer (11 s at most). Nil when
    /// `deadline` comes first. The events and the error reports both go through here.
    private func post(_ url: URL, _ body: Data, key: String, deadline: Date?) -> (status: Int?, reply: String, failure: String?)? {
        let wait = lastRequest.addingTimeInterval(1).timeIntervalSinceNow
        if let deadline, Date().addingTimeInterval(max(wait, 0) + 0.5) > deadline { return nil }
        if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
        var request = URLRequest(url: url, timeoutInterval: min(10, deadline.map { max($0.timeIntervalSinceNow, 1) } ?? 10))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "App-Key")
        request.httpBody = body
        lastRequest = Date()
        let sem = DispatchSemaphore(value: 0)
        var status: Int?, reply = "", failure: String?
        transport(request) { s, d, e in
            status = s
            reply = d.map { String(decoding: $0, as: UTF8.self) } ?? ""
            failure = e?.localizedDescription
            sem.signal()
        }
        if sem.wait(timeout: .now() + 11) == .timedOut { failure = "No answer in 11 seconds." }
        return (status, reply, failure)
    }

    /// A send's outcome sets the back-off: sent clears it; kept for later starts it at 1 minute, doubling to 30.
    private func noteOutcome(_ outcome: FlushOutcome) {
        if outcome == .sent { backoff = 0; backoffUntil = nil }
        if outcome == .retry {
            backoff = backoff == 0 ? 60 : min(backoff * 2, 1800)
            backoffUntil = Date().addingTimeInterval(backoff)
        }
    }

    /// `flushSync` on the queue; the Log entries and `done` come back on the main thread.
    func flush(maxTime: TimeInterval? = nil, ignoreBackoff: Bool = false, done: (() -> Void)? = nil) {
        let deadline = maxTime.map { Date().addingTimeInterval($0) }
        queue.async {
            let logs = self.flushSync(deadline: deadline, ignoreBackoff: ignoreBackoff)
            DispatchQueue.main.async {
                logs.forEach { self.onLog?($0) }
                done?()
            }
        }
    }

    /// Sends an incident's scrubbed text as log_chunk events (at most 6 incidents a launch). Main thread.
    func incident(_ name: String, _ text: String) {
        guard incidents < 6, !text.isEmpty else { return }
        incidents += 1
        queue.async {
            guard self.enabled, self.appKey != nil else { return }
            for p in logChunkProps(scrub(text, self.scrubContext), incident: name) { self.enqueue("log_chunk", p, time: Date()) }
        }
    }

    func queueCount(_ done: @escaping (Int, Int) -> Void) {
        queue.async {
            let size = ((try? FileManager.default.attributesOfItem(atPath: self.files.queue))?[.size] as? NSNumber)?.intValue ?? 0
            let n = self.loadQueue().count
            DispatchQueue.main.async { done(n, size) }
        }
    }
}

/// sysctl hw.model ("MacBookPro16,1").
func hardwareModel() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var buf = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("hw.model", &buf, &size, nil, 0)
    return String(cString: buf)
}

#if arch(arm64)
let runArch = "arm64"
#else
let runArch = "x86_64"
#endif

extension Booth {
    var diag: Diagnostics { Diagnostics.shared }
    var buildNumber: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0" }

    /// `changes` grew: the new entries (at the front) go to the log on disk, oldest first; then the
    /// list is cut to 500.
    func logNewChanges(_ old: [LogEntry]) {
        let firstOld = old.first?.id
        let fresh = changes.prefix { $0.id != firstOld }
        if !fresh.isEmpty { diag.write(fresh.reversed().map(diskLogText).joined()) }
        if changes.count > 500 { changes.removeLast(changes.count - 500) }
    }

    func diagEvent(_ name: String, _ props: [String: DiagValue] = [:]) {
        diag.event(name, props)
        // Booth Check fixing a row by itself: if the row turns green, it's put down to that.
        if name == "self_repair", case .string(let what)? = props["what"] {
            for row in selfRepairRows(what) { tallyAction(&tally, row: row, what: "self_repair:\(what)", at: sessionNow) }
        }
    }

    // The session log (1.30) ---------------------------------------------------------------------------

    /// Session seconds, monotonic (stops while the Mac sleeps).
    var sessionNow: Double { ProcessInfo.processInfo.systemUptime - sessionUptime0 }

    /// A person did something, or had to: one `person` event, with the row it was for (id, title, its
    /// status then) and whether a start-up or a shutdown was running.
    func person(_ action: String, row: (id: String, title: String, status: String)? = nil, _ extra: [String: DiagValue] = [:]) {
        var p = extra
        p["action"] = .string(action)
        if let row {
            p["check"] = .string(row.id)
            p["title"] = .string(row.title)
            p["row_status"] = .string(row.status)
        }
        p["during"] = .string(starting ? "startup" : shuttingDown ? "shutdown" : "service")
        tally.people += 1
        if starting { bootPeople += 1 }
        diagEvent("person", p)
    }

    /// This Mac settings changed: gathered for 2 seconds (a toggle, a time picker), then one
    /// settings_changed with the keys and whether This Mac was open (a person) or not (Booth Check itself).
    func noteSettings(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        settingKeysPending.formUnion(keys)
        guard settingKeysWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let keys = self.settingKeysPending.sorted()
            self.settingKeysPending = []
            self.settingKeysWork = nil
            self.diagEvent("settings_changed", ["keys": .string(keys.joined(separator: ",")), "this_mac_open": .int(self.showSetup ? 1 : 0)])
        }
        settingKeysWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Lightkey's Authenticate, as last seen (start-up only): the wait starts when it's first seen asking
    /// and ends when it's gone (`endAuthWait`).
    func noteAuthAsking(_ asking: Bool, during: String) {
        if asking {
            if authAskingSince == nil { authAskingSince = ProcessInfo.processInfo.systemUptime }
        } else {
            endAuthWait("answered", during: during)
        }
    }

    func endAuthWait(_ result: String, during: String) {
        guard let since = authAskingSince else { return }
        authAskingSince = nil
        let waited = ProcessInfo.processInfo.systemUptime - since
        authWaitTotal += waited
        person("authenticate", ["result": .string(result), "wait_s": .double((waited * 10).rounded() / 10), "step": .string(during)])
    }

    /// Saves the tallies to session.json, off the main thread. On a change of a row, at the end of a
    /// start-up, and every 5 minutes, so a power cut loses at most 5 minutes of the session's length.
    func persistTally() {
        guard !sessionEnded else { return }
        tally.elapsed = sessionNow
        tally.savedWall = Date().timeIntervalSince1970
        guard let data = try? JSONEncoder().encode(tally) else { return }
        diag.queue.async { self.diag.writeSession(data) }
    }

    /// The session ends (quit, shutdown, update): app_quit, session_summary and one session_row per row
    /// that was ever warn or fail, to the log on disk and the queue. session.json says how it ended at
    /// once, on this thread, so if the queue never gets to it, the next launch still sends it. Once
    /// per session; returns whether it ran now.
    @discardableResult
    func endSession(_ ended: String) -> Bool {
        guard !sessionEnded else { return false }
        let at = sessionNow
        tally.elapsed = at
        tally.savedWall = Date().timeIntervalSince1970
        tally.ended = ended
        tally.sent = false
        sessionEnded = true
        let enc = JSONEncoder()
        if let data = try? enc.encode(tally) { diag.writeSession(data) }
        var sent = tally
        sent.sent = true
        let sentData = try? enc.encode(sent)
        let quit: [String: DiagValue] = ["reason": .string(ended), "session_s": .int(Int(at.rounded())),
                                         "startup": .string(tally.startupReady.map { $0 ? "ready" : "not_ready" } ?? "none"),
                                         "problems_now": .int(problemCount), "people": .int(tally.people)]
        let events = sessionEvents(tally, at: at, ended: ended)
        let now = Date()
        diag.queue.async {
            self.diag.record("app_quit", quit, time: now)
            for e in events { self.diag.record(e.name, e.props, time: now) }
            if let sentData { self.diag.writeSession(sentData) }
        }
        return true
    }

    /// The shutdown stopped and the Mac stays on: the session goes on (its summary may have gone; the
    /// next end sends another with the same session id, and the later one is the one to read).
    func reopenSession() {
        guard sessionEnded else { return }
        sessionEnded = false
        tally.ended = nil
        tally.sent = false
        persistTally()
    }

    /// A handled failure for the Errors page (see `Diagnostics.recordError`): its stable type, what
    /// happened, and the Log's last 40 lines as the trace. Nothing goes with diagnostics off or no key.
    func reportError(_ type: String, _ message: String) {
        diag.error(type, message, recent: Array(changes.prefix(40)))
    }

    func diagDMXRecovery(_ rung: String, _ result: String) {
        diagEvent("dmx_recovery", ["rung": .string(rung), "result": .string(result)])
    }

    /// At launch: the header in the log, how the last run ended, the clean-exit marker, app_start, and
    /// an incident with the previous run's tail when it didn't end cleanly. Then the 5-minute flushes.
    func diagLaunch(atLogin: Bool, how: String) {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let macos = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let inApplications = Bundle.main.bundlePath.hasPrefix("/Applications/")
        diag.systemProps = ["isDebug": .bool(!inApplications), "osName": .string("macOS"), "osVersion": .string(macos),
                            "locale": .string(aptabaseLocale(Locale.current.identifier)),
                            "appVersion": .string(currentVersion), "appBuildNumber": .string(buildNumber),
                            "sdkVersion": .string("boothcheck@1"), "deviceModel": .string(hardwareModel())]
        diag.setEnabled(setup.diagnostics)
        diag.onLog = { [weak self] e in self?.changes.insert(e, at: 0) }
        let uptime = Int(ProcessInfo.processInfo.systemUptime)
        let version = currentVersion, build = buildNumber, tag = setupTag(setup), diagOn = setup.diagnostics
        let keyed = diag.appKey != nil
        tally = SessionTally(session: diag.session, version: version, launch: how, startedWall: Date().timeIntervalSince1970)
        diag.queue.async {
            let prev = self.diag.readPreviousRun(currentVersion: version)
            let prevSession = self.diag.readSession()
            self.diag.appendToLog("\n\(diskTime(Date()))  ==== Booth Check \(version) (build \(build)) \u{00B7} \(runArch) \u{00B7} macOS \(macos) \u{00B7} \(hardwareModel()) \u{00B7} up \(uptime) s \u{00B7} at login: \(atLogin ? "yes" : "no") (\(how)) \u{00B7} pid \(ProcessInfo.processInfo.processIdentifier)\n"
                + "    \(prev.detail)\n    Setup: \(tag). Diagnostics: " + (!diagOn ? "off" : keyed ? "on (session \(self.diag.session))" : "on, but this build has no key, so nothing is sent") + "\n")
            // The previous session's summary, if it never went: the Mac lost power or Booth Check was
            // killed (running.json left: ended = unclean or crash), or it quit before the queue got it.
            if let p = prevSession, !p.sent {
                let ended = prev.exit == "unclean" || prev.exit == "crash" ? prev.exit : (p.ended ?? "unknown")
                let when = Date(timeIntervalSince1970: p.savedWall)
                self.diag.appendToLog("\(diskTime(Date()))  The previous session (\(p.session)) never sent its summary; sending it now, ended \(ended), as of \(diskTime(when)):\n")
                for e in sessionEvents(p, at: p.elapsed, ended: ended) {
                    self.diag.record(e.name, e.props.merging(["late": .int(1)]) { a, _ in a }, time: when, session: p.session)
                }
            }
            // The Errors page: a crash with its report, else an unclean end with the log's last lines.
            if prev.exit == "crash" || prev.exit == "unclean" {
                let crashed = prevSession?.session
                let when = prevSession.map { Date(timeIntervalSince1970: $0.savedWall) } ?? Date()
                if let path = prev.crashPath, let text = try? String(contentsOfFile: path, encoding: .utf8), let gist = crashReportGist(text) {
                    let at = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? when
                    self.diag.recordError(gist.type, "Booth Check crashed: " + gist.message + " (\((path as NSString).lastPathComponent))",
                                          stack: gist.stack, severity: "fatal", kind: "crash", session: crashed, time: at)
                } else {
                    self.diag.recordError("UncleanExit", "Booth Check\u{2019}s last run ended without quitting (a power cut, a force quit, or a crash without a readable report). " + prev.detail,
                                          stack: prev.tail.split(separator: "\n", omittingEmptySubsequences: false).suffix(40).joined(separator: "\n"),
                                          severity: "error", kind: "unhandled", session: crashed, time: when)
                }
            }
            try? FileManager.default.removeItem(atPath: self.diag.files.session)
            self.diag.writeMarker(version: version)
            DispatchQueue.main.async {
                var start: [String: DiagValue] = ["version": .string(version), "build": .string(build), "arch": .string(runArch),
                                                  "macos": .string(macos), "uptime_s": .int(uptime), "at_login": .int(atLogin ? 1 : 0),
                                                  "how": .string(how), "setup": .string(tag), "prev_exit": .string(prev.exit)]
                if let p = prevSession {
                    start["prev_ran_at"] = .string(aptabaseTimestamp(Date(timeIntervalSince1970: p.savedWall)))
                    start["prev_session_s"] = .int(Int(p.elapsed.rounded()))
                    start["prev_ended"] = .string(prev.exit == "unclean" || prev.exit == "crash" ? prev.exit : (p.ended ?? "unknown"))
                    start["since_prev_h"] = .double(((Date().timeIntervalSince1970 - p.savedWall) / 360).rounded() / 10)
                }
                self.diagEvent("app_start", start)
                if prev.exit == "unclean" || prev.exit == "crash" { self.diag.incident("prev_\(prev.exit)", prev.tail) }
                if !keyed {
                    self.changes.insert(LogEntry(title: "Diagnostics: this build sends nothing", language: "Booth Check", code: "Info.plist AptabaseAppKey",
                                                 output: "No Aptabase key was built in (aptabase.key wasn\u{2019}t there), so nothing is queued or sent. The log on disk is still written.",
                                                 status: nil), at: 0)
                }
            }
        }
        // The first flush comes after the start-up (or 2 minutes in), then every 5 minutes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 121) { self.diagFlushIfAllowed() }
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            self?.persistTally()        // the session's length so far, in case the power goes
            self?.diagFlushIfAllowed()
        }
        RunLoop.main.add(t, forMode: .common)
    }

    /// Never during a start-up; before the first start-up is done, only from 2 minutes after launch.
    func diagFlushIfAllowed() {
        guard setup.diagnostics, !starting, !shuttingDown,
              diagStartupDone || Date().timeIntervalSince(diag.launchedAt) >= 120 else { return }
        diag.flush()
    }

    /// The switch in This Mac. Off: nothing more is queued or sent, and what's queued is deleted.
    func setDiagnostics(_ on: Bool) {
        guard setup.diagnostics != on else { return }
        if !on { diag.clearQueue() }
        setup.diagnostics = on
        diag.setEnabled(on)
        logSetting(on ? "This Mac: send diagnostics to the developer" : "This Mac: don\u{2019}t send diagnostics",
                   on ? "Step timings, check results and the scrubbed log go to Aptabase (us.aptabase.com). Never passwords; the user name is removed."
                      : "Nothing more is queued or sent, and the queue was deleted. The log on disk is still written.")
    }

    /// Send now, from This Mac: ignores the back-off, and says what's left.
    func sendDiagnosticsNow() {
        diag.flush(ignoreBackoff: true) {
            self.diag.queueCount { n, size in
                self.logSetting("Diagnostics: Send now", "\(n) event\(n == 1 ? "" : "s") left in the queue (\(size) bytes).")
            }
        }
    }

    /// Each pass, with the new results: the log on disk (full or one line), check_failed and
    /// check_recovered (not while a start-up runs: its end is diffed against what came before), and
    /// an incident for a check failing more than 60 seconds.
    func diagPass(_ entries: [LogEntry], _ new: [Check]) {
        let now = Date()
        let sig = passSignature(new)
        let changed = lastPassSignature != nil && sig != lastPassSignature
        let full = passLogIsFull(first: lastPassSignature == nil, starting: starting, changed: changed,
                                 sinceLastFull: now.timeIntervalSince(lastFullPass ?? .distantPast))
        let reason = changed ? "a check changed" : starting ? "start-up" : lastFullPass == nil ? "first" : "hourly"
        lastPassSignature = sig
        let problems = new.filter { $0.status == .fail || $0.status == .warn }.count
        if full {
            lastFullPass = now
            let head = "\(diskTime(now))  ==== pass (full: \(reason)), \(problems) problem\(problems == 1 ? "" : "s")\n"
                + new.map { "    \(statusWord($0.status).padding(toLength: 8, withPad: " ", startingAt: 0)) \($0.id): \($0.title) \u{2014} \($0.detail)\n" }.joined()
            diag.queue.async { self.diag.appendToLog(head + entries.map(diskLogText).joined()) }
        } else {
            diag.write(passLogLine(now, problems: problems))
        }
        guard !starting else { return }
        let t = checkTransitions(old: diagBaseline ?? [], new: new)
        diagBaseline = t.baseline
        // The session's tallies (not while the shutdown closes the apps: rows go red on purpose then).
        let cleared = closingApps ? [] : tallyPass(&tally, new, at: sessionNow)
        for c in t.changes {
            if c.failed {
                if diagFailingSince[c.id] == nil { diagFailingSince[c.id] = now }
                diagEvent("check_failed", ["check": .string(c.id), "title": .string(c.title), "status": .string(c.status), "detail": .string(c.detail),
                                           "spell": .int(tally.rows[c.id]?.spells ?? 0)])
            } else {
                let since = diagFailingSince.removeValue(forKey: c.id)
                diagIncidentSent.remove(c.id)
                let spell = cleared.first { $0.id == c.id }
                diagEvent("check_recovered", ["check": .string(c.id), "title": .string(c.title), "status": .string(c.status), "detail": .string(c.detail),
                                              "for_s": .int(spell.map { Int($0.seconds.rounded()) } ?? Int(now.timeIntervalSince(since ?? now))),
                                              "cleared_by": .string(spell?.by ?? "by_itself")])
            }
        }
        // A row muted or switched off while not OK: its spell ended without check_recovered.
        for c in cleared where c.by == "muted" || c.by == "gone" {
            diagFailingSince.removeValue(forKey: c.id)
            diagEvent("check_cleared", ["check": .string(c.id), "title": .string(tally.rows[c.id]?.title ?? c.id), "for_s": .int(Int(c.seconds.rounded())), "cleared_by": .string(c.by)])
        }
        if !t.changes.isEmpty || !cleared.isEmpty { persistTally() }
        for c in t.baseline where (c.status == .fail || c.status == .warn) && !diagIncidentSent.contains(c.id) {
            guard let since = diagFailingSince[c.id], now.timeIntervalSince(since) > 60 else { continue }
            diagIncidentSent.insert(c.id)
            diag.incident("check_\(c.id)", checkIncidentText(c, since: since, entries: entries))
            // The same incident, for the dashboard's Errors page: only a row that's red, not orange.
            if c.status == .fail {
                reportError("CheckFailed:\(c.id)", "\(c.title): \(c.detail)" + (c.fix.map { " Fix: \($0)" } ?? "") + " (failing since \(diskTime(since)))")
            }
            diagFlushIfAllowed()
        }
    }

    /// The Log's entries since `start`, oldest first, as the log on disk has them.
    func logText(since start: Date) -> String {
        changes.filter { $0.time >= start }.reversed().map(diskLogText).joined()
    }

    /// Save diagnostics…: the scrubbed logs, the DMX snapshots, the queue and a short summary, zipped
    /// in a temporary folder, then the share menu (AirDrop). Logged.
    func saveDiagnostics(from view: NSView?) {
        let summary = "Booth Check \(currentVersion) (build \(buildNumber)), \(runArch), \(hardwareModel()), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
            + "Saved \(diskTime(Date())). Setup: \(setupTag(setup)). Diagnostics: \(setup.diagnostics ? "on" : "off").\n"
            + "Problems now: \(problemCount)\n" + checks.map { "  \(statusWord($0.status)) \($0.id): \($0.title) \u{2014} \($0.detail)\n" }.joined()
        let files = diag.files, diag = self.diag
        diag.queue.async {
            let ctx = diag.scrubContext     // read off the main thread
            let fm = FileManager.default
            let stamp = dmxSnapshotFileName(Date(), reason: "x").dropFirst(4).dropLast(6)
            let dir = fm.temporaryDirectory.appendingPathComponent("BoothCheck-diagnostics-\(stamp)")
            try? fm.removeItem(at: dir)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let names = ((try? fm.contentsOfDirectory(atPath: files.logDir)) ?? []).filter { $0.hasPrefix("BoothCheck.log") || ($0.hasPrefix("dmx-") && $0.hasSuffix(".txt")) }
            var copied: [String] = []
            for n in names.sorted() {
                guard let d = fm.contents(atPath: files.logDir + "/" + n) else { continue }
                let out = n.hasSuffix(".txt") || n.hasSuffix(".log") ? n : n + ".txt"
                try? Data(scrub(String(decoding: d, as: UTF8.self), ctx).utf8).write(to: dir.appendingPathComponent(out))
                copied.append(out)
            }
            if let q = fm.contents(atPath: files.queue) {
                // Scrubbed again: events queued by an older version weren't scrubbed for every id.
                try? Data(scrub(String(decoding: q, as: UTF8.self), ctx).utf8).write(to: dir.appendingPathComponent("aptabase-queue.jsonl"))
                copied.append("aptabase-queue.jsonl")
            }
            try? Data(scrub(summary, ctx).utf8).write(to: dir.appendingPathComponent("summary.txt"))
            let zip = dir.path + ".zip"
            try? fm.removeItem(atPath: zip)
            let args = ["-c", "-k", "--keepParent", dir.path, zip]
            let r = shell("/usr/bin/ditto", args, timeout: 120)
            DispatchQueue.main.async {
                self.changes.insert(LogEntry(title: "Save diagnostics", language: "Terminal", code: commandLine("/usr/bin/ditto", args),
                                             output: (r.out.isEmpty ? "" : r.out + "\n") + "Scrubbed copies of: summary.txt, " + copied.joined(separator: ", ") + "\nZip: \(zip)",
                                             status: r.code), at: 0)
                guard r.code == 0 else { return }
                let url = URL(fileURLWithPath: zip)
                if let view {
                    NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
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
                               isOn: $booth.setup.streamDeck) {
                            if booth.setup.streamDeck { deckOptions }
                        }
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
                        Divider().padding(.leading, indent)
                        SettingRow(symbol: "power", tint: .indigo, title: "Shut down by itself",
                                   detail: shutdownDetail, isOn: $booth.autoShutdown)
                        if booth.autoShutdown { shutdownOptions }
                        // Only a MacBook runs on when the power goes; a desktop Mac just goes off.
                        if macHasBattery() {
                            Divider().padding(.leading, indent)
                            SettingRow(symbol: "bolt.slash.fill", tint: .orange, title: "Shut down when the power goes off",
                                       detail: booth.shutdownOnPowerOff
                                        ? "When the charger loses power, say switched off at the wall: a 1-minute warning with Not yet, then Stream Deck and Lightkey close and the Mac shuts down. Power back during the warning stops it."
                                        : "Off: on battery, the Mac keeps running.",
                                       isOn: $booth.shutdownOnPowerOff)
                        }
                        if booth.setup.lightkey {
                            Divider().padding(.leading, indent)
                            SettingRow(symbol: "lightbulb.slash.fill", tint: .purple, title: "Black out the stage first",
                                       detail: blackoutSwitchDetail(on: booth.setup.blackoutAtShutdown, source: booth.blackoutSourceNow),
                                       isOn: $booth.setup.blackoutAtShutdown)
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

                    group("Booth Check") {
                        HStack(alignment: .firstTextBaseline) {
                            Toggle(isOn: Binding(get: { booth.setup.diagnostics }, set: { booth.setDiagnostics($0) })) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Send diagnostics to the developer").font(.system(size: 12))
                                    Text("Step timings, check results and the scrubbed log. Never passwords; the user name is removed.")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .toggleStyle(.checkbox)
                            Spacer()
                            Button("Send now") { booth.sendDiagnosticsNow() }
                                .controlSize(.small)
                                .disabled(!booth.setup.diagnostics)
                        }
                        .padding(.vertical, 10)
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
            if booth.setup.dmx {
                // Lightkey's own setting, not Booth Check's: the switch runs the command it shows.
                Toggle(isOn: Binding(get: { booth.lightkeyNoPassword }, set: { booth.setLightkeyNoPassword($0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Connect without asking for the password").font(.system(size: 12))
                        Text("Lightkey skips Authenticate (works with the church\u{2019}s Open DMX USB) from the next time it opens. "
                             + (booth.lightkeyNoPassword ? "Unticking runs: " : "Ticking runs: ")
                             + commandLine("/usr/bin/defaults", lightkeyPasswordCommand(on: !booth.lightkeyNoPassword)))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(.leading, indent)
    }

    /// The deck lights helper: launchd runs it; Booth Check installs it, checks it and restarts it. Ticked
    /// by itself the first time Booth Check finds it installed.
    private var deckOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            profilePicker
            if booth.setup.lightkey { helperOptions }
        }
        .padding(.leading, indent)
    }

    /// The installed profile the saved choice is (its tag), "missing" when it isn't installed, "" for Don't check.
    private var chosenProfileTag: String {
        guard let c = booth.setup.deckProfile else { return "" }
        if case .found(let p, _) = matchDeckProfile(c, in: booth.deckProfiles.profiles) { return p.uuid }
        return "missing"
    }

    /// 1.32: the profile that goes with the show. Picked once; Booth Check checks the deck is on it and
    /// switches it at the start-up.
    private var profilePicker: some View {
        let profiles = booth.deckProfiles.profiles
        let tag = chosenProfileTag
        let suggested = booth.setup.deckProfile == nil ? booth.deckShow?.profile : nil
        let suggestions = suggested.map { s in profiles.filter { $0.name == s } } ?? []
        return VStack(alignment: .leading, spacing: 2) {
            Picker(selection: Binding(get: { tag }, set: { booth.chooseDeckProfile($0) })) {
                Text("Don\u{2019}t check").tag("")
                if tag == "missing", let c = booth.setup.deckProfile {
                    Text("\u{201C}\(c.name)\u{201D} (not installed)").tag("missing")
                }
                ForEach(profiles) { p in Text(deckProfileHint(p, among: profiles)).tag(p.uuid) }
            } label: {
                Text("Profile for the service").font(.system(size: 12))
            }
            // No .fixedSize() here: a long profile name made the menu, and so the whole sheet, wider
            // than the window (1.30 test build). The menu takes the row's width and shortens its title.
            .frame(maxWidth: 440, alignment: .leading)
            Text(booth.deckProfiles.problem.map { "Can\u{2019}t list the profiles: \($0)" }
                 ?? (tag.isEmpty ? "Pick the profile that goes with the show, and Booth Check checks Stream Deck is on it."
                                 : "Booth Check checks Stream Deck is on it, and switches it at the start-up, while Stream Deck is closed."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let suggested {
                HStack(spacing: 8) {
                    Text(suggestions.count == 1 ? "The show\u{2019}s deck file suggests \u{201C}\(suggested)\u{201D}."
                         : suggestions.isEmpty ? "The show\u{2019}s deck file suggests \u{201C}\(suggested)\u{201D}, which isn\u{2019}t installed."
                         : "The show\u{2019}s deck file suggests \u{201C}\(suggested)\u{201D}: \(suggestions.count) profiles have that name, pick one above.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if suggestions.count == 1 {
                        Button("Use it") { booth.chooseDeckProfile(suggestions[0].uuid) }.controlSize(.small)
                    }
                }
            }
        }
        .padding(.bottom, 4)
    }

    private var helperOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !booth.showUsesHelper {
                Text("The show\u{2019}s deck file says it doesn\u{2019}t use the deck lights helper, so it isn\u{2019}t checked.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Toggle(isOn: Binding(get: { booth.setup.deckLights != false }, set: { booth.setup.deckLights = $0 })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Deck lights helper").font(.system(size: 12))
                    Text("The deck\u{2019}s key lights follow Lightkey through a small helper. Checks it\u{2019}s running, waits for it before Stream Deck opens, and if it stops working, restarts it by itself: "
                         + commandLine("/bin/launchctl", deckHelperRestartArgs()))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .toggleStyle(.checkbox)
            HStack(spacing: 8) {
                Button(booth.deckHelperSHA == nil ? "Install\u{2026}" : "Install / update\u{2026}") {
                    // The install's own sheet can't open over this one: it opens once this one has closed.
                    booth.afterSetup = { booth.perform(.installDeckHelper) }
                    booth.showSetup = false
                }
                .disabled(deckHelperBundled == nil)
                Text(deckHelperVersions).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.leading, 20)
        }
    }

    private var deckHelperVersions: String {
        let carried = deckHelperBundledSHA.map { String($0.prefix(8)) } ?? "none"
        guard let installed = booth.deckHelperSHA else { return "Not installed. Booth Check carries version \(carried)." }
        return installed == deckHelperBundledSHA ? "Installed: version \(carried), the one Booth Check carries."
                                                 : "Installed: version \(installed.prefix(8)). Booth Check carries \(carried)."
    }

    private var shutdownDetail: String {
        guard booth.autoShutdown else {
            return "Off: the booth shuts down when someone clicks Shut down the booth in Booth Check\u{2019}s menu."
        }
        guard !booth.shutdownDays.isEmpty else { return "Pick the days it shuts down by itself, below." }
        let days = shutdownDaysText(booth.shutdownDays)
        let time = Calendar.current.date(bySettingHour: booth.shutdownMinute / 60, minute: booth.shutdownMinute % 60,
                                         second: 0, of: Date())?.formatted(date: .omitted, time: .shortened) ?? ""
        return days.prefix(1).uppercased() + days.dropFirst()
            + " at \(time), if nobody has: a 5-minute warning with Not yet, then Stream Deck and Lightkey close and the Mac shuts down."
    }

    /// The days and the time the booth shuts down by itself, and when that next is.
    private var shutdownOptions: some View {
        let calendar = Calendar.current
        let time = Binding<Date>(
            get: { calendar.date(bySettingHour: booth.shutdownMinute / 60, minute: booth.shutdownMinute % 60, second: 0, of: Date()) ?? Date() },
            set: { booth.shutdownMinute = calendar.component(.hour, from: $0) * 60 + calendar.component(.minute, from: $0) })
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(1...7, id: \.self) { day in
                    Toggle(calendar.shortWeekdaySymbols[day - 1], isOn: Binding(
                        get: { booth.shutdownDays.contains(day) },
                        set: { on in
                            if on { booth.shutdownDays.insert(day) } else { booth.shutdownDays.remove(day) }
                        }))
                        .toggleStyle(.button)
                        .controlSize(.small)
                }
                DatePicker("at", selection: time, displayedComponents: .hourAndMinute)
                    .controlSize(.small)
                    .fixedSize()
                    .padding(.leading, 6)
            }
            // The next time it'll warn: usually the set time, or half an hour after a Not yet.
            let next = booth.shutdownAt ?? nextShutdown(after: Date(), days: booth.shutdownDays, minute: booth.shutdownMinute)
            Text(next.map { "Next: \($0.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))" }
                 ?? "Pick at least one day.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.leading, indent)
        .padding(.bottom, 10)
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
                    Button("Cancel") { booth.cancelChange(change) }.keyboardShortcut(.cancelAction)
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
                // 1.31: the log is kept on disk too; diagnostics can be zipped and AirDropped.
                Button("Show in Finder") {
                    let log = Diagnostics.shared.files.log
                    if FileManager.default.fileExists(atPath: log) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: log)])
                    } else {
                        NSWorkspace.shared.open(URL(fileURLWithPath: Diagnostics.shared.files.logDir))
                    }
                }
                .controlSize(.small)
                Button("Save diagnostics\u{2026}") { booth.saveDiagnostics(from: NSApp.keyWindow?.contentView) }
                    .controlSize(.small)
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
                                    CheckRow(check: check, perform: { booth.rowAction(check, $0) }, mute: booth.mute)
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
        .sheet(isPresented: $booth.showSetup, onDismiss: {
            let next = booth.afterSetup
            booth.afterSetup = nil
            next?()
        }) { SetupSheet(booth: booth) }
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
                Button { booth.startShowByHand() } label: {
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
            Button("Check again") { booth.checkAgain() }.keyboardShortcut("r")
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
        let title = bootHeadline(finished: booth.bootFinished, ready: booth.bootReady, problems: booth.problemCount)
        let (symbol, color): (String, Color) =
            !booth.bootFinished ? ("play.circle.fill", .green)
            : booth.bootReady ? ("checkmark.seal.fill", .green)
            : ("exclamationmark.triangle.fill", .orange)
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
    /// The plug moves only while the card is up: a hidden panel's TimelineView keeps redrawing (about
    /// 6% CPU for the rest of the session after a timed-out or skipped replug, dev Mac, Nov 2026).
    @Published var animating = false
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
                TimelineView(.animation(minimumInterval: nil, paused: !model.animating)) { context in
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
        model.animating = true
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
        if model.animating { model.animating = false }
        onHide?()
    }
}

/// The big sign's faces. While the start-up runs (see `startSign`): hands off, or what Lightkey may
/// need; then how it ended. While the booth shuts down (see `shutDownBooth`): the countdown with Not
/// yet, shutting down, or the Mac stays on.
enum SignFace: Equatable { case handsOff, password, ready, needsLook, countdown, shuttingDown, stayedOn, working, workDone, workFailed }

/// What the big sign shows. `banner` puts it along the bottom of the screen instead of the middle;
/// `show` is the show's name, as Lightkey lists it among its projects; `asking` is Lightkey's
/// Authenticate alert being up; `seconds`, `notYet` and `now` belong to the shutdown's countdown;
/// `note` says why the booth is shutting down, or why the Mac stayed on.
final class SignModel: ObservableObject {
    @Published var face: SignFace = .handsOff
    @Published var banner = false
    @Published var step = ""
    @Published var show: String?
    @Published var asking = false
    @Published var seconds = 0
    @Published var note = ""
    @Published var title = ""          // a self-repair's title (see `selfRepairWords`); its line goes in `note`
    /// The card is on screen: its busy ring only moves then (hidden on a busy face, say after Not yet,
    /// a TimelineView would keep redrawing for good).
    @Published var visible = false
    var notYet: (() -> Void)?
    var now: (() -> Void)?
}

/// The big sign. At login, the hands-off sign (the user asked for it, 6 Oct 2026): while Booth Check
/// opens everything, "Please don't touch the Mac" in the middle of the screen, so nobody clicks around
/// in a half-open Lightkey. While Lightkey may be asking for the Mac's password, a banner along the
/// bottom says what to do there and nothing more, clear of Lightkey's alert and macOS's password box.
/// At the end it says how the start-up went, which is also when the Mac is free to use. The same sign
/// counts down to a shutdown and stays up while the booth shuts down.
struct SignCard: View {
    @ObservedObject var model: SignModel

    private var look: (symbol: String, color: Color, title: String, text: String) {
        switch model.face {
        case .handsOff:
            return ("hand.raised.fill", .orange, "Please don\u{2019}t touch the Mac",
                    "Booth Check is getting the lights ready. This sign goes away by itself when it\u{2019}s done.")
        case .password:
            let words = passwordSign(show: model.show, asking: model.asking)
            return ("key.fill", .blue, words.title, words.text)
        case .ready:
            return ("checkmark.seal.fill", .green, "Ready for the service", "You can use the Mac now.")
        case .needsLook:
            return ("exclamationmark.triangle.fill", .orange, "Started, but something needs a look",
                    "The panel at the top right says what. You can use the Mac now.")
        case .countdown:
            return ("power", .red, "The booth shuts down in \(countdownText(model.seconds))", model.note)
        case .shuttingDown:
            return ("power", .indigo, "Shutting the booth down",
                    "Please don\u{2019}t touch the Mac. Stream Deck and Lightkey close, then the Mac shuts down.")
        case .stayedOn:
            return ("exclamationmark.triangle.fill", .orange, "The Mac stays on", model.note)
        case .working:
            return ("wrench.and.screwdriver.fill", .blue, model.title, model.note)
        case .workDone:
            return ("checkmark.circle.fill", .green, model.title, model.note)
        case .workFailed:
            return ("exclamationmark.triangle.fill", .orange, model.title, model.note)
        }
    }

    /// Booth Check is at work, as opposed to saying how something went: the ring keeps pulsing.
    private var busy: Bool { [.handsOff, .password, .countdown, .shuttingDown, .working].contains(model.face) }
    /// The step it's on, with a spinner. The countdown has its buttons instead.
    private var showsStep: Bool { busy && model.face != .countdown }

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
                        if showsStep { stepLine(size: 14) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 30)
                .frame(width: SignOverlay.bannerSize.width, height: SignOverlay.bannerSize.height)
            } else {
                VStack(spacing: 20) {
                    Spacer(minLength: 0)
                    badge(look.symbol, look.color, size: 120)
                    Text(look.title).font(.system(size: 42, weight: .bold).monospacedDigit())
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(look.text).font(.system(size: 20)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if showsStep { stepLine(size: 17) }
                    if model.face == .handsOff && hasAccessoryPrompt {
                        Text("If macOS asks to allow an accessory, click Allow.")
                            .font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                    if model.face == .countdown {
                        HStack(spacing: 14) {
                            Button("Not yet") { model.notYet?() }
                            Button("Shut down now") { model.now?() }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                        }
                        .controlSize(.large)
                    }
                    Spacer(minLength: 0)
                }
                .padding(44)
                .frame(width: SignOverlay.cardSize.width, height: SignOverlay.cardSize.height)
            }
        }
        .background(RoundedRectangle(cornerRadius: 28).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

    /// The symbol on a coloured disc. While Booth Check is busy, a ring keeps pulsing out of it.
    private func badge(_ symbol: String, _ color: Color, size: CGFloat) -> some View {
        ZStack {
            if busy {
                TimelineView(.animation(minimumInterval: nil, paused: !model.visible)) { context in
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

/// The big sign on screen: in the middle over a dimmed backdrop, or along the bottom with nothing
/// dimmed while Lightkey may be asking something (its password, or whether to save the show), so its
/// alert stays clear. It never takes focus and lets every click through, except on the countdown's
/// buttons: it's a sign, not a lock. Its backdrop sits just under the floating start-up panel, which
/// stays bright.
final class SignOverlay {
    static let shared = SignOverlay()
    static let cardSize = NSSize(width: 760, height: 500)
    static let bannerSize = NSSize(width: 900, height: 190)
    private let model = SignModel()
    private var backdrop: NSWindow?
    private var card: NSPanel?
    private var ending: DispatchWorkItem?

    /// The start-up's sign (see `startSign`).
    func show(_ sign: StartSign, step: String, show: String?) {
        guard sign != .none else { return hide() }
        model.show = show
        present(sign == .password ? .password : .handsOff, banner: sign == .password, step: step)
    }

    /// The shutdown's warning: counts down from `seconds`, with Not yet and Shut down now.
    func countdown(_ seconds: Int, why: String, notYet: @escaping () -> Void, now: @escaping () -> Void) {
        model.note = why
        model.notYet = notYet
        model.now = now
        model.seconds = seconds
        present(.countdown, banner: false, step: "")
    }

    func tick(_ seconds: Int) { model.seconds = seconds }

    /// Whether Lightkey's Authenticate alert is up, for the password banner's words.
    func setAsking(_ asking: Bool) { if model.asking != asking { model.asking = asking } }

    /// Puts a face up, in the middle of the screen over the dimmed backdrop or as a banner along the bottom.
    func present(_ face: SignFace, banner: Bool, step: String) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        ending?.cancel()
        model.face = face
        model.banner = banner
        model.step = step
        if backdrop == nil { backdrop = dimmingBackdrop(level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)) }
        if card == nil {
            let p = ClickablePanel(contentRect: NSRect(origin: .zero, size: Self.cardSize),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            setUpSignPanel(p, showing: SignCard(model: model))
            card = p
        }
        guard let backdrop, let card else { return }
        card.ignoresMouseEvents = face != .countdown        // only the countdown has buttons
        if banner {
            // Lightkey's alerts and macOS's password box come up in the middle and nearer the top.
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
        if !model.visible { model.visible = true }
    }

    /// The start-up is over: say how it went, where the sign already is, then go.
    func finish(ready: Bool) {
        guard card?.isVisible == true else { return }
        end(ready ? .ready : .needsLook, after: ready ? 3 : 6)
    }

    /// Something Booth Check is fixing by itself (see `Booth.showWorkingSign`): what it is, and what
    /// it's doing now. The same sign and rules as the hands-off sign.
    func working(title: String, detail: String, banner: Bool) {
        model.title = title
        model.note = detail
        present(.working, banner: banner, step: "Booth Check is doing this by itself. Please don\u{2019}t touch the Mac.")
    }

    /// The self-repair is over: its last word, where the sign already is, then `then` after `seconds`.
    func endWorking(ok: Bool, title: String, detail: String, after seconds: TimeInterval, then: @escaping () -> Void) {
        guard card?.isVisible == true else { return then() }
        ending?.cancel()
        model.title = title
        model.note = detail
        model.face = ok ? .workDone : .workFailed
        card?.ignoresMouseEvents = true
        let work = DispatchWorkItem { then() }
        ending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// The shutdown stopped: say why, then go.
    func stayedOn(_ note: String) {
        model.note = note
        present(.stayedOn, banner: false, step: "")
        end(.stayedOn, after: 12)
    }

    private func end(_ face: SignFace, after seconds: TimeInterval) {
        model.face = face
        card?.ignoresMouseEvents = true
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        ending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        ending?.cancel()
        card?.orderOut(nil)
        backdrop?.orderOut(nil)
        if model.visible { model.visible = false }
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
    @ObservedObject private var option = OptionKey.shared

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
                Button { booth.startShowByHand() } label: {
                    Label(booth.starting ? "Starting\u{2026}" : "Get the show started", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .disabled(booth.starting)
            }
            // The end of the service: a 10-second countdown with Not yet, then everything closes.
            Button { booth.shutDownBooth(.button) } label: {
                Label(booth.shuttingDown ? "Shutting down\u{2026}" : "Shut down the booth", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(booth.shuttingDown || booth.starting)
            HStack {
                Button("Open Booth Check") { booth.showWindow() }
                Button("Check again") { booth.checkAgain() }
                Spacer()
                // 1.30: Quit shows only while Option is held, so a volunteer can't close the watch by accident.
                if option.down {
                    Button("Quit") { booth.quitReason = "menu_quit"; NSApp.terminate(nil) }
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { option.down = NSEvent.modifierFlags.contains(.option) }
    }
}

/// Whether the Option key is held, for the dropdown's Quit (see `MenuPanel`).
final class OptionKey: ObservableObject {
    static let shared = OptionKey()
    @Published var down = false
    private var monitor: Any?
    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            let down = e.modifierFlags.contains(.option)
            if self?.down != down { self?.down = down }
            return e
        }
    }
}

/// Held for the app's whole life. Opts Booth Check out of App Nap so its checks keep running while
/// Lightkey is in front; it still lets the Mac itself sleep, which is the charger settings' job.
var napActivity: NSObjectProtocol?

/// True when macOS opened Booth Check as a login item, rather than someone opening it by hand.
/// `--login` forces it, for testing.
func launchedAsLoginItem() -> Bool { currentLaunchKind() != "by_hand" }

/// How this launch came about (see `launchKind`); read in applicationDidFinishLaunching, while macOS's
/// open event is still the current one.
func currentLaunchKind() -> String {
    var loginItem = false
    if let event = NSAppleEventManager.shared().currentAppleEvent,
       event.eventID == AEEventID(kAEOpenApplication),
       event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
        loginItem = true
    }
    return launchKind(flag: CommandLine.arguments.contains("--login"), loginItemEvent: loginItem,
                      uptime: ProcessInfo.processInfo.systemUptime)   // under 3 minutes: just after a restart
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = MIDIWatch.shared
        napActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                            reason: "Booth Check watches the booth in the background")
        let booth = Booth.shared
        let how = currentLaunchKind()
        let atLogin = how != "by_hand"
        booth.diagLaunch(atLogin: atLogin, how: how)
        // A logout, restart or shutdown from the Apple menu: say so when Booth Check is quit by it.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
            if booth.quitReason == nil { booth.quitReason = "mac_logout_or_shutdown" }
        }
        booth.logMenuIconLaunch()
        if atLogin { booth.logAppsOpenAtLogin() }
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

    /// Quitting on purpose (Quit, an update, the Mac shutting down): the clean-exit marker goes.
    func applicationWillTerminate(_ notification: Notification) {
        let booth = Booth.shared
        let why = booth.quitReason ?? "quit"
        // app_quit and the session summary (unless the shutdown already sent them), then one short send.
        let ended = booth.endSession(why)
        Diagnostics.shared.markCleanExit(why)
        // Let the last lines reach the disk and, with a new summary, try to send it: never more than
        // 2 seconds (a send may be under way). Anything not sent stays queued, and session.json says
        // how the session ended, so the next launch sends it.
        let written = DispatchSemaphore(value: 0)
        let deadline = Date().addingTimeInterval(1.5)
        let send = ended && booth.setup.diagnostics
        Diagnostics.shared.queue.async {
            if send { _ = Diagnostics.shared.flushSync(deadline: deadline) }
            written.signal()
        }
        _ = written.wait(timeout: .now() + (send ? 2 : 1))
    }
}

@main
struct BoothCheckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var booth = Booth.shared

    /// Before the menu bar icon is made: a saved "NSStatusItem Visible …" set to false (someone
    /// ⌘-dragged it off) would keep it hidden, so it's cleared (logged once the Log exists).
    init() {
        clearedStatusItemKeys = hiddenStatusItemKeys(UserDefaults.standard.dictionaryRepresentation())
        clearedStatusItemKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    var body: some Scene {
        // SwiftUI writes isInserted back on every update. Passed straight through ($booth.menuIconInserted,
        // 1891082), each write of the same `true` republished Booth and asked for another update: the main
        // thread spun at 100% (beachball, no rows, "Checking…" forever; found 14 Nov 2026). Only a real
        // change is stored (`menuIconWriteNeeded`).
        MenuBarExtra(isInserted: Binding(get: { booth.menuIconInserted },
                                         set: { if menuIconWriteNeeded($0, current: booth.menuIconInserted) { booth.menuIconInserted = $0 } })) {
            MenuPanel(booth: booth)
        } label: {
            StatusLabel(booth: booth)
        }
        .menuBarExtraStyle(.window)
    }
}
