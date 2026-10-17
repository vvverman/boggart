import XCTest
@testable import BoggartCore

final class ProductPresentationTests: XCTestCase {
    private func record(_ reason: StopReason, date: Date = Date(timeIntervalSince1970: 1700000000)) -> SessionRecord {
        .init(id: UUID(), ownerUID: 501, startedAt: date.addingTimeInterval(-3600), endedAt: date, reason: reason)
    }
    func testLatestAbnormalReasonVisibleOnlyWhenInactive() {
        let entry = record(.powerDisconnected)
        XCTAssertEqual(RecentSessionText.abnormalRecord([entry], phase: .inactive), entry)
        for phase in [ServicePhase.active, .recoveryRequired, .ownedByAnotherUser] {
            XCTAssertNil(RecentSessionText.abnormalRecord([entry], phase: phase))
        }
        XCTAssertNil(RecentSessionText.abnormalRecord([entry], phase: nil))
    }
    func testOlderFailureDoesNotResurfaceAfterOrdinarySession() {
        for reason in [StopReason.manual, .expired, .applicationQuit] {
            XCTAssertNil(RecentSessionText.abnormalRecord([record(reason), record(.powerDisconnected)], phase: .inactive))
        }
    }
    func testEmptyHistoryHasNoSummary() {
        XCTAssertNil(RecentSessionText.abnormalRecord([], phase: .inactive))
    }
    func testRecentSummaryUsesTodayYesterdayOrDate() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12))!
        let today = RecentSessionText.summary(record(.powerDisconnected, date: now.addingTimeInterval(-3600)), now: now, calendar: calendar)
        XCTAssertTrue(today.contains("сегодня в 11:00")); XCTAssertTrue(today.contains("отключено питание"))
        let yesterday = RecentSessionText.summary(record(.clientLost, date: now.addingTimeInterval(-86400)), now: now, calendar: calendar)
        XCTAssertTrue(yesterday.contains("вчера в 12:00"))
        let old = RecentSessionText.summary(record(.helperRestarted, date: now.addingTimeInterval(-86400 * 5)), now: now, calendar: calendar)
        XCTAssertTrue(old.contains("12 октября")); XCTAssertFalse(old.contains("вчера"))
    }
    func testPowerLabelDoesNotRepeatBatteryPercentage() {
        XCTAssertEqual(PowerSnapshot(external: true, batteryPercent: 80).label, "Внешнее питание")
        XCTAssertEqual(PowerSnapshot(external: false, batteryPercent: 25).label, "Аккумулятор")
        XCTAssertEqual(PowerSnapshot.unknown.label, "Источник питания не определён")
    }
    func testHistoryWarningDoesNotBlockMaintenanceAfterConfirmedStop() {
        var status = ServiceStatus(phase: .inactive, power: .init(external: true), capability: .init(available: true, message: ""), message: "", history: [])
        status.historyWarning = "error"
        XCTAssertTrue(MaintenancePolicy.mayDetach(status, connected: true))
        XCTAssertFalse(MaintenancePolicy.mayDetach(status, connected: false))
        XCTAssertFalse(MaintenancePolicy.mayDetach(nil, connected: true))
    }
    func testMaintenanceRefusesEveryUnfinishedOrForeignState() {
        for phase in [ServicePhase.active, .recoveryRequired, .ownedByAnotherUser] {
            let status = ServiceStatus(phase: phase, power: .init(external: true), capability: .init(available: true, message: ""), message: "", history: [])
            XCTAssertFalse(MaintenancePolicy.mayDetach(status, connected: true))
        }
    }
    func testBuildOrderIsNumericAndRejectsMalformedOrOlder() {
        XCTAssertTrue(MaintenancePolicy.isNewerBuild("10", than: "4"))
        XCTAssertTrue(MaintenancePolicy.isNewerBuild("4.1", than: "4"))
        for proposed in ["4", "3", "", "../5", "5x", ".5", "5..1", "5."] {
            XCTAssertFalse(MaintenancePolicy.isNewerBuild(proposed, than: "4"), proposed)
        }
    }
    func testDiagnosticsUsesAllowlistWithoutRawErrorOrPersonalIDs() {
        let report = DiagnosticReport(appVersion: "0.4.0", osVersion: "macOS test", model: "Mac-test",
            helperState: "подключён", phase: .inactive, sourceKnown: true, externalPower: true,
            validationBuild: true, historyWarning: true, lastReason: .clientLost).text
        XCTAssertTrue(report.contains("Удержание выключено")); XCTAssertTrue(report.contains("проверочная"))
        for text in ["/Users/", "SSID", "VPN", "ownerUID", "startedAt", "serial", "password"] { XCTAssertFalse(report.contains(text)) }
    }
    func testOptionalHistoryWarningRoundTripsWithoutChangingPhase() throws {
        let status = ServiceStatus(phase: .inactive, power: .init(external: true), capability: .init(available: true, message: ""), message: "", history: [], historyWarning: "warn")
        let copy = try JSONDecoder().decode(ServiceStatus.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(copy.phase, .inactive); XCTAssertEqual(copy.historyWarning, "warn")
    }
}
