import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import BoggartCore

final class MenuBarLayoutTests: XCTestCase {
    let right = CGRect(x: 820, y: 870, width: 620, height: 30)
    func frame(_ x: CGFloat, _ width: CGFloat = 60) -> CGRect {
        CGRect(x: x, y: 875, width: width, height: 22)
    }
    func testNotchCannotAnchorPopover() { XCTAssertFalse(MenuBarLayout.contains(frame(700), in: right)) }
    func testPartialNotchCannotAnchorPopover() { XCTAssertFalse(MenuBarLayout.contains(frame(800), in: right)) }
    func testVisibleAnchor() { XCTAssertTrue(MenuBarLayout.contains(frame(1000), in: right)) }
    func testMissingWindowIsNotVisible() { XCTAssertFalse(MenuBarLayout.contains(nil, in: right)) }
    func testOffscreenAnchor() { XCTAssertFalse(MenuBarLayout.contains(frame(1430), in: right)) }
    func testBelowMenuBarAnchor() {
        XCTAssertFalse(MenuBarLayout.contains(CGRect(x: 1000, y: 600, width: 60, height: 22), in: right))
    }
    func testNotchCompacts() {
        XCTAssertTrue(MenuBarLayout.needsCompact(frame: frame(790), area: right, expandedWidth: 60, wasCompact: false))
    }
    func testAvailableSpacePreservesTime() {
        XCTAssertFalse(MenuBarLayout.needsCompact(frame: frame(900), area: right, expandedWidth: 60, wasCompact: false))
    }
    func testCompactStaysCompactAtBoundary() {
        XCTAssertTrue(MenuBarLayout.needsCompact(frame: frame(858, 22), area: right, expandedWidth: 60, wasCompact: true))
    }
    func testDraggingRightRestoresTimeWithReserve() {
        XCTAssertFalse(MenuBarLayout.needsCompact(frame: frame(920, 22), area: right, expandedWidth: 60, wasCompact: true))
    }
    func testNoOscillationAfterCompactingAtBoundary() {
        let hidden = frame(810)
        XCTAssertTrue(MenuBarLayout.needsCompact(frame: hidden, area: right, expandedWidth: 60, wasCompact: false))
        let shortened = frame(hidden.maxX - 22, 22)
        XCTAssertTrue(MenuBarLayout.needsCompact(frame: shortened, area: right, expandedWidth: 60, wasCompact: true))
    }
    func testExternalMonitorNegativeOrigin() {
        let external = CGRect(x: -1920, y: 1058, width: 1920, height: 22)
        let anchor = CGRect(x: -90, y: 1058, width: 60, height: 22)
        XCTAssertTrue(MenuBarLayout.contains(anchor, in: external))
        XCTAssertFalse(MenuBarLayout.needsCompact(frame: anchor, area: external, expandedWidth: 60, wasCompact: true))
    }
    func testNoScreenDataCompactsSafely() {
        XCTAssertTrue(MenuBarLayout.needsCompact(frame: nil, area: nil, expandedWidth: 60, wasCompact: false))
    }
    func testZeroGeometryCannotAnchor() {
        XCTAssertFalse(MenuBarLayout.contains(.zero, in: right))
        XCTAssertTrue(MenuBarLayout.needsCompact(frame: frame(900), area: .zero, expandedWidth: 60, wasCompact: false))
    }
    func testManyHourDigitsReevaluateWidth() {
        XCTAssertTrue(MenuBarLayout.needsCompact(frame: frame(840), area: right, expandedWidth: 100, wasCompact: false))
    }
}
