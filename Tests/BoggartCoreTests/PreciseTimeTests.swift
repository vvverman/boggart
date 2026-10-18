import XCTest
@testable import BoggartCore
final class PreciseTimeTests: XCTestCase {
    func testHoursSecondsHundredths() { XCTAssertEqual(DurationText.precise(7 * 3600 + 42 * 60 + 18.37), "07:42:18,37") }
    func testDoesNotWrapAfterDay() { XCTAssertEqual(DurationText.precise(31 * 3600 + 20 * 60 + 7.25), "31:20:07,25") }
    func testPositiveValueCannotLookFinished() { XCTAssertEqual(DurationText.precise(0.0001), "00:00:00,01") }
    func testZeroAndWholeHours() {
        XCTAssertEqual(DurationText.precise(0), "00:00:00,00")
        XCTAssertEqual(DurationText.precise(25 * 3600), "25:00:00,00")
    }
    func testInvalidNumbers() {
        for value in [Double.nan, .infinity, -1, Double.greatestFiniteMagnitude] { XCTAssertEqual(DurationText.precise(value), "—") }
        XCTAssertEqual(DurationText.precise(nil), "—")
    }
    func testMenuStillHasNoSeconds() {
        XCTAssertEqual(DurationText.compact(7 * 3600 + 42 * 60), "7:42")
        XCTAssertEqual(DurationText.menu(active: false, countdown: false, selectedHours: 12, remaining: nil), "12 ч")
    }
}
