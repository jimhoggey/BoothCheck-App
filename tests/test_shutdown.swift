import Foundation

// 1.18: shutting the booth down, from the menu or at a set time each week.
// Run with tests/run.sh, which compiles this next to a copy of BoothCheck.swift (no @main).
var failures = 0
func expect(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print((ok ? "PASS  " : "FAIL  ") + name + (ok ? "" : "   (got: \(got()))"))
    if !ok { failures += 1 }
}

// Fixed dates: October 2026 in Sydney. The 10th is a Saturday, the 11th and 18th Sundays.
var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "Australia/Sydney")!
func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}
let onePM = 13 * 60

// 1. When the booth next shuts down by itself.
func next(_ now: Date, _ days: Set<Int>) -> Date? { nextShutdown(after: now, days: days, minute: onePM, calendar: cal) }
expect("Saturday noon, Sundays at 1 pm: tomorrow at 1 pm", next(date(10, 12), [1]) == date(11, 13), "\(String(describing: next(date(10, 12), [1])))")
expect("Sunday 12:59: today at 1 pm", next(date(11, 12, 59), [1]) == date(11, 13))
expect("Sunday 1 pm exactly: next week", next(date(11, 13), [1]) == date(18, 13))
expect("Monday, Sundays and Wednesdays: Wednesday", next(date(12, 9), [1, 4]) == date(14, 13))
expect("no days: never", next(date(12, 9), []) == nil)

// 2. Due only near the set time: a Mac that was off or asleep then mustn't shut down as it comes back.
let at = date(11, 13)
expect("before the time: not yet", shutdownDue(now: date(11, 12, 59), at: at) == .notYet)
expect("at the time: now", shutdownDue(now: at, at: at) == .now)
expect("ten minutes late (it was asleep): still now", shutdownDue(now: date(11, 13, 10), at: at) == .now)
expect("over half an hour late: missed, wait for the next", shutdownDue(now: date(11, 13, 31), at: at) == .missed)

// 3. Waiting for an app to close: Lightkey may ask about saving the show; never wait for ever.
expect("closed: done", quitNext(running: false, waited: 1) == .done)
expect("still closing: wait", quitNext(running: true, waited: 2) == .wait)
expect("still open after 5 seconds: it may be asking something", quitNext(running: true, waited: 6) == .ask)
expect("still open after 2 minutes: give up, the Mac stays on", quitNext(running: true, waited: 121) == .giveUp)

// 4. Words on the sign and in This Mac.
expect("countdown 5:00", countdownText(300) == "5:00", countdownText(300))
expect("countdown 4:59", countdownText(299) == "4:59", countdownText(299))
expect("countdown 0:09", countdownText(9) == "0:09", countdownText(9))
expect("one day", shutdownDaysText([1]) == "Sundays", shutdownDaysText([1]))
expect("two days, in week order", shutdownDaysText([4, 1]) == "Sundays and Wednesdays", shutdownDaysText([4, 1]))
expect("three days", shutdownDaysText([1, 2, 3]) == "Sundays, Mondays and Tuesdays", shutdownDaysText([1, 2, 3]))
expect("every day", shutdownDaysText(Set(1...7)) == "every day", shutdownDaysText(Set(1...7)))

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
