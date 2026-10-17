import XCTest
@testable import BoggartCore

final class PresentationTests: XCTestCase {
    func testSevenHoursFortyTwoMinutes() { XCTAssertEqual(DurationText.compact(7 * 3600 + 42 * 60), "7:42") }
    func testThirtyOneHoursNotWrapped() { XCTAssertEqual(DurationText.compact(31 * 3600 + 20 * 60), "31:20") }
    func testTwentyFiveHours() { XCTAssertEqual(DurationText.compact(25 * 3600), "25:00") }
    func testMinuteBoundary() {
        XCTAssertEqual(DurationText.compact(60), "0:01")
        XCTAssertEqual(DurationText.compact(59.999), "<1 мин")
        XCTAssertEqual(DurationText.compact(0.001), "<1 мин")
    }
    func testZeroDoesNotClaimStop() { XCTAssertEqual(DurationText.compact(0), "…") }
    func testInvalidTimeSafe() {
        for value in [Double.nan, .infinity, -.infinity, -1] { XCTAssertEqual(DurationText.compact(value), "—") }
        XCTAssertEqual(DurationText.compact(nil), "—")
    }
    func testExpandedOverDay() { XCTAssertEqual(DurationText.expanded(31 * 3600 + 20 * 60), "31 ч 20 мин") }
    func testExpandedLastMinute() { XCTAssertEqual(DurationText.expanded(59), "меньше минуты") }
    func testTimerHiddenDoesNotHideInactiveDuration() {
        XCTAssertEqual(DurationText.menu(active: false, countdown: false, selectedHours: 12, remaining: nil), "12 ч")
        XCTAssertEqual(DurationText.menu(active: true, countdown: false, selectedHours: 12, remaining: 100), "")
    }
    func testTimerVisibleUsesRemainingOnlyWhenActive() {
        XCTAssertEqual(DurationText.menu(active: false, countdown: true, selectedHours: 24, remaining: 100), "24 ч")
        XCTAssertEqual(DurationText.menu(active: true, countdown: true, selectedHours: 24, remaining: 112800), "31:20")
    }
    func testPreferenceMigration() {
        XCTAssertEqual(Preferences.hours(nil), 12); XCTAssertEqual(Preferences.hours(0), 12)
        XCTAssertEqual(Preferences.hours(25), 12); XCTAssertEqual(Preferences.hours(24), 24)
        XCTAssertTrue(Preferences.countdown(newValue: nil, legacyMode: nil))
        XCTAssertFalse(Preferences.countdown(newValue: nil, legacyMode: "icon"))
        XCTAssertTrue(Preferences.countdown(newValue: true, legacyMode: "icon"))
    }
    func testEndingTodayTomorrowAndDated() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 20, minute: 30))!
        XCTAssertEqual(DateText.ending(remaining: 3600, now: now, calendar: calendar), "Завершится сегодня в 21:30.")
        XCTAssertEqual(DateText.ending(remaining: 11 * 3600, now: now, calendar: calendar), "Завершится завтра в 07:30.")
        XCTAssertEqual(DateText.ending(remaining: 36 * 3600, now: now, calendar: calendar), "Завершится 19 октября в 08:30.")
    }
    func testTimezoneChangesOnlyLabel() {
        let now = Date(timeIntervalSince1970: 1792267200)
        var a = Calendar(identifier: .gregorian), b = a
        a.timeZone = TimeZone(secondsFromGMT: 0)!; b.timeZone = TimeZone(secondsFromGMT: 10800)!
        XCTAssertNotEqual(DateText.ending(remaining: 3600, now: now, calendar: a), DateText.ending(remaining: 3600, now: now, calendar: b))
    }
    func testDSTDoesNotSubtractDuration() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let before = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 0, minute: 30))!
        // Переход назад: три реальных часа дают местные 02:30, не 03:30.
        XCTAssertEqual(DateText.ending(remaining: 3 * 3600, now: before, calendar: calendar), "Завершится сегодня в 02:30.")
    }
    func testNotificationPolicy() {
        for r in [StopReason.manual, .expired, .applicationQuit] { XCTAssertFalse(r.abnormal) }
        for r in [StopReason.powerDisconnected, .criticalThermal, .clientLost, .helperRestarted] { XCTAssertTrue(r.abnormal) }
    }
    func testParser() throws {
        XCTAssertEqual(try PMSetParser.sleepSetting(from: "System-wide power settings:\n SleepDisabled 1\n"), .disabled)
        XCTAssertEqual(try PMSetParser.sleepSetting(from: "System-wide power settings:\n SleepDisabled 0\n"), .enabled)
        XCTAssertEqual(try PMSetParser.sleepSetting(from: "System-wide power settings:\n"), .unset)
    }
    func testParserRejectsUnexpectedAndDuplicateData() {
        for s in ["", "SleepDisabled 1", "System-wide power settings:\n SleepDisabled 2", "System-wide power settings:\n SleepDisabled 1\n SleepDisabled 0"] {
            XCTAssertThrowsError(try PMSetParser.sleepSetting(from: s))
        }
    }
    func testProtocolRejectsUnknownCommand() {
        let text = "{\"id\":\"\(UUID().uuidString)\",\"kind\":\"executeShell\"}"
        XCTAssertThrowsError(try JSONDecoder().decode(ServiceCommand.self, from: Data(text.utf8)))
    }
    func testRecoveryRecordRoundtrip() throws {
        let value = RecoveryRecord(sessionID: UUID(), ownerUID: 501, startedAt: Date())
        let encoded = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(RecoveryRecord.self, from: encoded), value)
    }
}
