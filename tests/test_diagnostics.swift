import Foundation

// 1.31: the log on disk and Aptabase diagnostics. Run with tests/run.sh, which compiles this next to a
// copy of BoothCheck.swift. Nothing here talks to the real server: sending uses an injected transport,
// in a temporary folder.
var failures = 0
func expect(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print((ok ? "PASS  " : "FAIL  ") + name + (ok ? "" : "   (got: \(got()))"))
    if !ok { failures += 1 }
}

let utc = { (s: String) -> Date in
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.date(from: s)! }
let now = utc("2026-11-14 03:04:05")
let sys: [String: DiagValue] = ["isDebug": .bool(false), "osName": .string("macOS"), "osVersion": .string("26.1.0"), "locale": .string("en-AU"),
                                "appVersion": .string("1.31"), "appBuildNumber": .string("131"), "sdkVersion": .string("boothcheck@1"),
                                "deviceModel": .string("MacBookPro16,1")]
func ev(_ name: String, _ props: [String: DiagValue] = [:], at: Date = now) -> DiagEvent {
    DiagEvent(id: UUID().uuidString, time: at.timeIntervalSince1970, name: name, session: "0a1b2c3d-0000-4000-8000-000000000000", system: sys, props: props)
}

// 1. The batch: a JSON array in Aptabase's shape, UTC timestamps without fractions.
expect("timestamp format", aptabaseTimestamp(now) == "2026-11-14T03:04:05Z", aptabaseTimestamp(now))
let body = aptabaseBatchBody([ev("app_start", ["version": .string("1.31"), "uptime_s": .int(42)])], now: now)
let arr = (try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]] ?? []
let first = arr.first ?? [:]
expect("one event in an array", arr.count == 1, String(decoding: body, as: UTF8.self))
expect("the keys", Set(first.keys) == ["timestamp", "sessionId", "eventName", "systemProps", "props"], "\(first.keys)")
expect("timestamp", first["timestamp"] as? String == "2026-11-14T03:04:05Z")
expect("eventName and sessionId", first["eventName"] as? String == "app_start" && first["sessionId"] as? String == "0a1b2c3d-0000-4000-8000-000000000000")
let sp = first["systemProps"] as? [String: Any] ?? [:]
expect("isDebug is a JSON bool", String(decoding: body, as: UTF8.self).contains("\"isDebug\":false"), String(decoding: body, as: UTF8.self))
expect("systemProps", sp["sdkVersion"] as? String == "boothcheck@1" && sp["deviceModel"] as? String == "MacBookPro16,1" && sp["osName"] as? String == "macOS")
let props = first["props"] as? [String: Any] ?? [:]
expect("props: strings and numbers", props["version"] as? String == "1.31" && props["uptime_s"] as? Int == 42, "\(props)")
let many = aptabaseBatchBody((0..<40).map { _ in ev("x") }, now: now)
expect("never more than 25 in a batch", ((try? JSONSerialization.jsonObject(with: many)) as? [Any])?.count == 25)

// 2. Local validation, so one bad event never spoils a batch.
let long = String(repeating: "\u{00E9}", count: 300)
let bad = validDiagEvent(ev(String(repeating: "n", count: 80), ["": .string("empty key"), String(repeating: "k", count: 50): .int(1),
                                                                 "s": .string(long), "b": .bool(true), "nan": .double(.nan)]))
expect("name cut to 60", bad.name.count == 60)
expect("empty key dropped", bad.props[""] == nil)
expect("long key cut to 40", bad.props[String(repeating: "k", count: 40)] == .int(1), "\(bad.props.keys)")
if case .string(let s)? = bad.props["s"] { expect("string cut to 170 UTF-16 units", s.utf16.count == 170, "\(s.utf16.count)") } else { expect("string kept", false) }
expect("a bool prop becomes 1", bad.props["b"] == .int(1))
expect("NaN becomes text (JSON can't hold it)", bad.props["nan"] == .string("nan"))
expect("locale: no @ options, dash, ≤ 10", aptabaseLocale("en_US@rg=auzzzz") == "en-US" && aptabaseLocale("zh_Hant_TW_extra") == "zh-Hant-TW")
var longLocale = ev("x"); longLocale.system["locale"] = .string("en_US@rg=auzzzz")
expect("validation fixes a long locale in systemProps", validDiagEvent(longLocale).system["locale"] == .string("en-US"))
let emoji = truncateUTF16(String(repeating: "\u{1F600}", count: 100), 171)
expect("never cut inside an emoji", emoji.utf16.count == 170 && emoji.count == 85, "\(emoji.utf16.count)")

// 3. log_chunk: pieces ≤ 170 units, at line ends where possible, and back again exactly.
let text = (1...120).map { "line \($0): \u{201C}quoted\u{201D} \"double\" 'single' \u{1F3AD}\u{1F3B5} " + String(repeating: "x", count: $0 % 50) }.joined(separator: "\n")
    + "\n" + String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 60) + "\nend"
let pieces = logChunkPieces(text)
expect("every piece ≤ 170 UTF-16 units", pieces.allSatisfy { $0.utf16.count <= 170 }, "\(pieces.map { $0.utf16.count }.max() ?? 0)")
expect("pieces join back to the text", pieces.joined() == text)
expect("short lines aren't split", pieces.first.map { $0.hasPrefix("line 1:") && $0.hasSuffix("\n") } == true)
let chunks = logChunkProps(text, incident: "startup")
expect("round trip through log_chunk props", joinLogChunks(chunks) == text)
expect("parts numbered", chunks.first?["part"] == .int(1) && chunks.first?["parts"] == .int(chunks.count) && chunks.first?["incident"] == .string("startup"))
expect("at most t00…t19 per event", chunks.allSatisfy { p in p.keys.filter { $0.hasPrefix("t") }.count <= 20 } && chunks.first?["t19"] != nil)
expect("every chunk event passes validation unchanged", chunks.allSatisfy { validDiagEvent(ev("log_chunk", $0)).props == $0 })
let huge = logChunkProps(String(repeating: "0123456789abcdef\n", count: 10_000), incident: "big")
expect("an incident is capped at about 30 KB (≤ 10 events)", huge.count <= 10 && huge.count >= 8, "\(huge.count)")

// 4. Scrubbing.
let ctx = ScrubContext(home: "/Users/jdoe", users: ["Jane Doe", "jdoe"], macs: ["Jane\u{2019}s MacBook Pro", "Janes-MacBook-Pro.local", "Janes-MacBook-Pro"])
let raw = """
Saved to /Users/jdoe/Library/Logs/Booth Check/dmx.txt
  "USB Serial Number" = "AB0JXYZ1"
/dev/cu.usbserial-AB0JXYZ1
USB DMX interface, serial AB0JXYZ1.
    "IOPlatformSerialNumber" = "C02ABCDEF"
    "IOPlatformUUID" = "1234-5678"
mail jane.doe@example.org from 192.168.1.20 on Jane\u{2019}s MacBook Pro (Janes-MacBook-Pro.local), user jdoe, Jane Doe
Lightkey 5.2, show BackupChurch_modular_v37.lightkeyproj, no serial ports open
"""
let clean = scrub(raw, ctx)
let h = shortHash("AB0JXYZ1")
expect("home → ~", clean.contains("~/Library/Logs/Booth Check") && !clean.contains("/Users/jdoe"), clean)
expect("USB serial → sn:hash", clean.contains("\"USB Serial Number\" = \"sn:\(h)\"") && clean.contains("usbserial-sn:\(h)") && clean.contains("serial sn:\(h)."), clean)
expect("the raw serial is gone", !clean.contains("AB0JXYZ1"))
expect("platform serial and UUID lines gone", !clean.contains("C02ABCDEF") && !clean.contains("IOPlatformUUID"))
expect("email, IP, Mac name, user names", clean.contains("<email>") && clean.contains("<ip>") && clean.contains("on <mac> (<mac>)")
       && clean.contains("user <user>, <user>") && !clean.contains("jdoe") && !clean.contains("Jane"), clean)
expect("show names, versions and 'serial ports' kept", clean.contains("Lightkey 5.2, show BackupChurch_modular_v37.lightkeyproj, no serial ports open"), clean)
expect("scrubbing twice changes nothing", scrub(clean, ctx) == clean)

// 4b. Stream Deck device ids carry the deck's hardware serial.
let deckRaw = """
Stream Deck's profile per deck: @(1)[4057/143/A00NA525320EK4] → Church XL
{"Device":{"UUID":"@(1)[4057\\/143\\/A00NA525320EK4]"},"Name":"Church XL"}
defaults write com.elgato.StreamDeck … "@(1)[4057/96/CL12K1A00213]" = "6D3F…"
"""
let deckClean = scrub(deckRaw, ctx)
let dh = shortHash("A00NA525320EK4")
expect("deck serial → sn:hash, vendor/product kept", deckClean.contains("@(1)[4057/143/sn:\(dh)] → Church XL"), deckClean)
expect("JSON's escaped slashes too", deckClean.contains("@(1)[4057\\/143\\/sn:\(dh)]"), deckClean)
expect("a second deck's serial too", deckClean.contains("[4057/96/sn:\(shortHash("CL12K1A00213"))]") && !deckClean.contains("CL12K1A00213"), deckClean)
expect("the raw deck serial is gone", !deckClean.contains("A00NA525320EK4"), deckClean)
expect("scrubbing a deck id twice changes nothing", scrub(deckClean, ctx) == deckClean)

// 5. The queue's cap: log_chunk goes first, app_start/startup/shutdown/check last.
let q: [(name: String, bytes: Int)] = [("app_start", 10), ("log_chunk", 10), ("setting", 10), ("check_failed", 10), ("log_chunk", 10), ("startup_done", 10)]
expect("under the cap: all kept", trimDiagQueue(q, maxCount: 10) == Array(0..<6))
expect("over by 2: both log_chunks go", trimDiagQueue(q, maxCount: 4) == [0, 2, 3, 5], "\(trimDiagQueue(q, maxCount: 4))")
expect("over by 3: then the other events", trimDiagQueue(q, maxCount: 3) == [0, 3, 5], "\(trimDiagQueue(q, maxCount: 3))")
expect("over by 4: then the oldest important one", trimDiagQueue(q, maxCount: 2) == [3, 5], "\(trimDiagQueue(q, maxCount: 2))")
expect("by size too: 60 bytes to 45 drops the two log_chunks", trimDiagQueue(q, maxCount: 100, maxBytes: 45) == [0, 2, 3, 5], "\(trimDiagQueue(q, maxCount: 100, maxBytes: 45))")

// 6. Re-stamping late events (the Mac is off for a week).
let at19 = sendStamp(eventTime: now.addingTimeInterval(-19.9 * 3600), now: now)
expect("19.9 h old: its own time", at19.timestamp == aptabaseTimestamp(now.addingTimeInterval(-19.9 * 3600)) && at19.extra.isEmpty)
let at20 = sendStamp(eventTime: now.addingTimeInterval(-20.1 * 3600), now: now)
expect("20.1 h old: sent as now, with at and late_h", at20.timestamp == aptabaseTimestamp(now) && at20.extra["late_h"] == .int(20)
       && at20.extra["at"] == .string(aptabaseTimestamp(now.addingTimeInterval(-20.1 * 3600))))
expect("1 day old: now, late_h 24", sendStamp(eventTime: now.addingTimeInterval(-86_400), now: now).extra["late_h"] == .int(24))
let week = sendStamp(eventTime: now.addingTimeInterval(-7 * 86_400), now: now)
expect("7 days old: now, late_h 168", week.timestamp == aptabaseTimestamp(now) && week.extra["late_h"] == .int(168))
expect("clock ahead by an hour: now", sendStamp(eventTime: now.addingTimeInterval(3600), now: now).timestamp == aptabaseTimestamp(now))
let lateBody = aptabaseBatchBody([ev("startup_done", at: now.addingTimeInterval(-7 * 86_400))], now: now)
let lateProps = (((try? JSONSerialization.jsonObject(with: lateBody)) as? [[String: Any]])?.first?["props"] as? [String: Any]) ?? [:]
expect("the batch carries at and late_h", lateProps["late_h"] as? Int == 168 && lateProps["at"] as? String != nil, "\(lateProps)")

// 7. checkTransitions.
func ck(_ id: String, _ s: Status) -> Check { Check(id: id, group: "g", title: id.uppercased(), status: s, detail: "d") }
let t1 = checkTransitions(old: [], new: [ck("a", .ok), ck("b", .fail), ck("c", .unknown)])
expect("first pass: only bad checks reported", t1.changes.map(\.id) == ["b"] && t1.changes.first?.failed == true && t1.changes.first?.status == "fail")
let t2 = checkTransitions(old: t1.baseline, new: [ck("a", .warn), ck("b", .fail), ck("c", .unknown)])
expect("ok → warn fails; fail → fail is quiet", t2.changes.map(\.id) == ["a"])
let t3 = checkTransitions(old: t2.baseline, new: [ck("a", .unknown), ck("b", .ok), ck("c", .ok)])
expect("fail → ok recovers; unknown → ok is quiet", t3.changes.map { "\($0.id)\($0.failed)" } == ["bfalse"], "\(t3.changes)")
let t4 = checkTransitions(old: t3.baseline, new: [ck("a", .ok), ck("b", .ok), ck("c", .ok)])
expect("warn → unknown → ok still recovers", t4.changes.map(\.id) == ["a"] && t4.changes.first?.failed == false)
expect("warn → fail is reported", checkTransitions(old: [ck("a", .warn)], new: [ck("a", .fail)]).changes.count == 1)

// 8. How the previous run ended.
expect("first run", previousExit(markerPresent: false, crashReportSinceStart: false, lastVersion: nil, currentVersion: "1.31") == "first")
expect("clean", previousExit(markerPresent: false, crashReportSinceStart: false, lastVersion: "1.31", currentVersion: "1.31") == "clean")
expect("update", previousExit(markerPresent: false, crashReportSinceStart: false, lastVersion: "1.30", currentVersion: "1.31") == "update")
expect("unclean (power loss, force quit)", previousExit(markerPresent: true, crashReportSinceStart: false, lastVersion: "1.31", currentVersion: "1.31") == "unclean")
expect("crash", previousExit(markerPresent: true, crashReportSinceStart: true, lastVersion: "1.31", currentVersion: "1.31") == "crash")
expect("crash report names", isBoothCheckCrashReport("BoothCheck-2026-11-14-101010.ips") && isBoothCheckCrashReport("Booth Check-2026.ips")
       && !isBoothCheckCrashReport("Lightkey-2026.ips") && !isBoothCheckCrashReport("BoothCheck.diag"))

// 9. The full-pass decision.
expect("first pass: full", passLogIsFull(first: true, starting: false, changed: false, sinceLastFull: 0))
expect("during a start-up: full", passLogIsFull(first: false, starting: true, changed: false, sinceLastFull: 15))
expect("a status changed: full", passLogIsFull(first: false, starting: false, changed: true, sinceLastFull: 15))
expect("an hour on: full", passLogIsFull(first: false, starting: false, changed: false, sinceLastFull: 3600))
expect("otherwise one line", !passLogIsFull(first: false, starting: false, changed: false, sinceLastFull: 3585))
expect("the one line", passLogLine(Calendar.current.date(bySettingHour: 14, minute: 3, second: 15, of: now)!, problems: 0) == "pass 14:03:15, 0 problems, unchanged\n")

// 10. Rotation.
expect("small: no rotation", !logNeedsRotation(size: 1_000, adding: 500))
expect("would pass 5 MB: rotate", logNeedsRotation(size: 4_999_900, adding: 200))
expect("empty file: never", !logNeedsRotation(size: 0, adding: 6_000_000))
let rot = logRotationMoves("/x/BoothCheck.log")
expect("5 kept: .4 removed, then .3→.4 … log→.1", rot.remove == "/x/BoothCheck.log.4"
       && rot.moves.map { "\($0.from)>\($0.to)" } == ["/x/BoothCheck.log.3>/x/BoothCheck.log.4", "/x/BoothCheck.log.2>/x/BoothCheck.log.3",
                                                       "/x/BoothCheck.log.1>/x/BoothCheck.log.2", "/x/BoothCheck.log>/x/BoothCheck.log.1"], "\(rot)")

// 11. What a send's answer means.
expect("200 {}: sent", aptabaseOutcome(status: 200, body: "{}") == .sent)
expect("200 with error (bad or locked key): keep", aptabaseOutcome(status: 200, body: "{\"error\":\"locked\"}") == .retry)
expect("400: drop", aptabaseOutcome(status: 400, body: "bad") == .drop)
expect("429: keep", aptabaseOutcome(status: 429, body: "") == .retry)
expect("503: keep", aptabaseOutcome(status: 503, body: "") == .retry)
expect("network error: keep", aptabaseOutcome(status: nil, body: "") == .retry)

// 12. The queue and a flush, with an injected transport, in a temporary folder.
let tmp = NSTemporaryDirectory() + "bc-diag-\(UUID().uuidString)"
let files = DiagFiles(logDir: tmp + "/logs", supportDir: tmp + "/support")
var answers: [(Int?, String)] = [], requests: [URLRequest] = []
let d = Diagnostics(files: files, appKey: "A-TEST-1", transport: { req, done in
    requests.append(req)
    let a = answers.isEmpty ? (200, "{}") : answers.removeFirst()
    done(a.0, Data(a.1.utf8), nil)
})
d.systemProps = sys
for i in 0..<30 { d.enqueue(i == 0 ? "app_start" : "setting", ["key": .string("k\(i) in /Users/x \(NSUserName())")], time: now) }
expect("30 queued", d.loadQueue().count == 30)
expect("seq and launch on every event", d.loadQueue().last?.props["seq"] == .int(30) && d.loadQueue().first?.props["launch"] == .string(d.session))
expect("props are scrubbed before queueing", d.loadQueue().allSatisfy { $0.props["key"]?.text.hasSuffix("<user>") == true }, d.loadQueue().first?.props["key"]?.text ?? "")
answers = [(200, "{}"), (503, "")]
var logs = d.flushSync(ignoreBackoff: true)
expect("first batch of 25 sent, second kept on 503", d.loadQueue().count == 5 && logs.count == 2, "\(d.loadQueue().count) \(logs.map(\.title))")
expect("the request: POST, App-Key, JSON", requests.first?.httpMethod == "POST" && requests.first?.value(forHTTPHeaderField: "App-Key") == "A-TEST-1"
       && requests.first?.value(forHTTPHeaderField: "Content-Type") == "application/json")
expect("the Log entry says what happened", logs.first?.language == "Network" && logs.first!.output.contains("HTTP 200") && logs.first!.output.contains("Left in the queue: 5")
       && logs.first!.code.contains("setting \u{00D7}24"), logs.first.map { $0.code + "\n" + $0.output } ?? "")
expect("after a failure it backs off", d.flushSync().isEmpty && d.loadQueue().count == 5)
answers = [(200, "{\"error\":\"App-Key locked\"}")]
logs = d.flushSync(ignoreBackoff: true)
expect("200 with error: kept", d.loadQueue().count == 5 && logs.first?.status == 1)
answers = [(400, "bad request")]
logs = d.flushSync(ignoreBackoff: true)
expect("400: dropped and logged", d.loadQueue().isEmpty && logs.first!.title.contains("refused"))
let off = Diagnostics(files: files, appKey: nil, transport: { _, done in done(200, nil, nil) })
off.enqueue("app_start", [:], time: now)
expect("no key: nothing queued", d.loadQueue().isEmpty)
expect("no key: the flush says so", off.flushSync().first?.title == "Diagnostics: nothing sent")
d.appendToLog("hello\n")
let disk = (try? String(contentsOfFile: files.log, encoding: .utf8)) ?? ""
expect("the log on disk is written, with the small bodies sent", disk.hasSuffix("hello\n") && disk.contains("Diagnostics body sent"), String(disk.suffix(200)))
try? FileManager.default.removeItem(atPath: tmp)

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
