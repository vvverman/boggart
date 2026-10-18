import XCTest
@testable import BoggartCore

final class AccessPresentationTests: XCTestCase {
    func testManualFirstLaunchAlwaysShowsControlsWhenPrepared() {
        XCTAssertEqual(LaunchPresentation.initial(atLogin: false, needsSetup: false), .controls)
    }
    func testManualFirstLaunchShowsSetupWhenNotPrepared() {
        XCTAssertEqual(LaunchPresentation.initial(atLogin: false, needsSetup: true), .setup)
    }
    func testLoginDoesNotOpenWindowsOrStartSetup() {
        for needsSetup in [true, false] {
            XCTAssertEqual(LaunchPresentation.initial(atLogin: true, needsSetup: needsSetup), .background)
        }
    }
    func testReopenAlwaysHasVisibleDestination() {
        XCTAssertEqual(LaunchPresentation.reopen(needsSetup: false), .controls)
        XCTAssertEqual(LaunchPresentation.reopen(needsSetup: true), .setup)
    }
    func testVisibleWindowAlwaysHasDockAccess() {
        XCTAssertTrue(AccessPresentation().needsDock(hasWindow: true))
        XCTAssertFalse(AccessPresentation().needsDock(hasWindow: false))
    }
    func testTransientLayoutDoesNotAddDockFallback() {
        var policy = AccessPresentation()
        policy.observeMenuItem(available: false, at: 0)
        policy.observeMenuItem(available: true, at: 0.9)
        policy.observeMenuItem(available: false, at: 1)
        XCTAssertFalse(policy.needsDock(hasWindow: false))
    }
    func testHiddenItemKeepsDockEvenAfterWindowCloses() {
        var policy = AccessPresentation()
        policy.observeMenuItem(available: false, at: 10)
        policy.observeMenuItem(available: false, at: 11)
        XCTAssertTrue(policy.needsDock(hasWindow: false))
    }
    func testReturningItemDoesNotFlickerDock() {
        var policy = AccessPresentation()
        policy.observeMenuItem(available: false, at: 10)
        policy.observeMenuItem(available: false, at: 11)
        policy.observeMenuItem(available: true, at: 12)
        XCTAssertTrue(policy.needsDock(hasWindow: false))
    }
    func testInvalidTimeCannotLatchFallback() {
        var policy = AccessPresentation()
        policy.observeMenuItem(available: false, at: .nan)
        policy.observeMenuItem(available: false, at: .infinity)
        XCTAssertFalse(policy.dockFallback)
    }
}
