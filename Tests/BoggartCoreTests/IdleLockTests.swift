import XCTest
@testable import BoggartCore

final class IdleLockTests: XCTestCase {
    private func hold(requested: Bool = true, active: Bool = true, remaining: Double = 60,
                      external: Bool = true, unlocked: Bool = true, display: Bool = true, lid: Bool = false) -> Bool {
        IdleLockPolicy.shouldHold(requested: requested, active: active, remaining: remaining,
            externalPower: external, unlockedConsole: unlocked, displayAwake: display, lidClosed: lid)
    }
    func testOnlyExplicitOption() { XCTAssertFalse(hold(requested: false)); XCTAssertTrue(hold()) }
    func testNoHoldOutsideSession() { XCTAssertFalse(hold(active: false)) }
    func testNoHoldAfterExpiry() { XCTAssertFalse(hold(remaining: 0)); XCTAssertFalse(hold(remaining: -1)) }
    func testManualLockIsRespected() { XCTAssertFalse(hold(unlocked: false)) }
    func testDisplaySleepDoesNotWakeDisplay() { XCTAssertFalse(hold(display: false)) }
    func testClosedLidDisablesIdleActivityOnly() { XCTAssertFalse(hold(lid: true)) }
    func testExternalPowerRequired() { XCTAssertFalse(hold(external: false)) }
    func testInvalidTimeRejected() { XCTAssertFalse(hold(remaining: .nan)); XCTAssertFalse(hold(remaining: .infinity)) }
    func testSystemLeaseBoundedBySession() {
        XCTAssertEqual(IdleLockPolicy.timeout(remaining: 3600), 25)
        XCTAssertEqual(IdleLockPolicy.timeout(remaining: 0.3), 0.3)
        XCTAssertEqual(IdleLockPolicy.timeout(remaining: .infinity), 0)
        XCTAssertEqual(IdleLockPolicy.timeout(remaining: -1), 0)
    }
}
