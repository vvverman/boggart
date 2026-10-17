import XCTest
@testable import BoggartCore

final class PanelTests: XCTestCase {
    func testHover300Milliseconds() {
        var p = PanelInteraction(); XCTAssertNil(p.receive(.enterAnchor, at: 0))
        XCTAssertNil(p.advance(at: 0.299)); XCTAssertEqual(p.advance(at: 0.3), .show)
    }
    func testQuickPassDoesNotOpen() {
        var p = PanelInteraction(); _ = p.receive(.enterAnchor, at: 0); _ = p.receive(.leaveAnchor, at: 0.1)
        XCTAssertNil(p.advance(at: 1)); XCTAssertFalse(p.visible)
    }
    func testClickCancelsPendingHover() {
        var p = PanelInteraction(); _ = p.receive(.enterAnchor, at: 0); _ = p.receive(.toggleClick, at: 0.2)
        XCTAssertNil(p.advance(at: 1)); XCTAssertFalse(p.visible)
    }
    func testClickDoesNotReopenUntilPointerReturns() {
        var p = PanelInteraction(); _ = p.receive(.enterAnchor, at: 0); _ = p.receive(.toggleClick, at: 0.2)
        _ = p.receive(.enterAnchor, at: 0.4); XCTAssertNil(p.advance(at: 1))
        _ = p.receive(.leaveAnchor, at: 2); _ = p.receive(.enterAnchor, at: 3)
        XCTAssertEqual(p.advance(at: 3.3), .show)
    }
    func testCrossingGapToPanelKeepsItVisible() {
        var p = PanelInteraction(); _ = p.receive(.enterAnchor, at: 0); _ = p.advance(at: 0.3)
        _ = p.receive(.leaveAnchor, at: 1); _ = p.receive(.enterPanel, at: 1.2)
        XCTAssertNil(p.advance(at: 2)); XCTAssertTrue(p.visible)
    }
    func testLeaveBothClosesAfterDelay() {
        var p = PanelInteraction(); _ = p.receive(.enterAnchor, at: 0); _ = p.advance(at: 0.3)
        _ = p.receive(.leaveAnchor, at: 1)
        XCTAssertNil(p.advance(at: 1.249)); XCTAssertEqual(p.advance(at: 1.25), .close)
    }
    func testEditingPreventsAutomaticClosure() {
        var p = PanelInteraction(); _ = p.receive(.openMouse, at: 0); _ = p.receive(.beginEditing, at: 0)
        _ = p.receive(.leavePanel, at: 1); XCTAssertNil(p.advance(at: 10)); XCTAssertTrue(p.visible)
        _ = p.receive(.endEditing, at: 11); XCTAssertNil(p.advance(at: 11.25))
        XCTAssertTrue(p.pinned); XCTAssertEqual(p.receive(.dismiss, at: 12), .close)
    }
    func testExplicitDismissWorksWhileEditing() {
        var p = PanelInteraction(); _ = p.receive(.openMouse, at: 0); _ = p.receive(.beginEditing, at: 1)
        XCTAssertEqual(p.receive(.dismiss, at: 2), .close)
    }
    func testPointerActionPinsPanelUntilDismissed() {
        var p = PanelInteraction(); _ = p.receive(.openMouse, at: 0); _ = p.receive(.beginPointerAction, at: 1)
        _ = p.receive(.leavePanel, at: 2); XCTAssertNil(p.advance(at: 3))
        _ = p.receive(.endPointerAction, at: 4); XCTAssertNil(p.advance(at: 4.25))
        XCTAssertTrue(p.visible); XCTAssertTrue(p.pinned)
    }
    func testRightClickPinsEvenWithoutEditing() {
        var p = PanelInteraction(); _ = p.receive(.openMouse, at: 0)
        _ = p.receive(.leaveAnchor, at: 1); _ = p.receive(.leavePanel, at: 2)
        XCTAssertTrue(p.pinned); XCTAssertNil(p.advance(at: 100)); XCTAssertTrue(p.visible)
    }
    func testHoverPanelPinsAfterInteraction() {
        var p = PanelInteraction(); _ = p.receive(.enterAnchor, at: 0); _ = p.advance(at: 0.3)
        XCTAssertFalse(p.pinned)
        _ = p.receive(.enterPanel, at: 1); _ = p.receive(.beginPointerAction, at: 1.1)
        _ = p.receive(.endPointerAction, at: 1.2)
        _ = p.receive(.leaveAnchor, at: 2); _ = p.receive(.leavePanel, at: 2)
        XCTAssertTrue(p.pinned); XCTAssertNil(p.advance(at: 100))
    }
    func testDismissClearsPinnedStateForNextHover() {
        var p = PanelInteraction(); _ = p.receive(.openMouse, at: 0); _ = p.receive(.dismiss, at: 1)
        _ = p.receive(.enterAnchor, at: 2); XCTAssertEqual(p.advance(at: 2.3), .show)
        XCTAssertFalse(p.pinned)
        _ = p.receive(.leaveAnchor, at: 3); XCTAssertEqual(p.advance(at: 3.25), .close)
    }
    func testRightClickCancelsPendingHoverTimer() {
        var p = PanelInteraction(); _ = p.receive(.enterAnchor, at: 0)
        XCTAssertEqual(p.receive(.openMouse, at: 0.1), .show)
        XCTAssertNil(p.advance(at: 1)); XCTAssertNil(p.nextDeadline)
    }
    func testRightClickOpensSamePanelImmediately() {
        var p = PanelInteraction(); XCTAssertEqual(p.receive(.openMouse, at: 0), .show)
        XCTAssertTrue(p.visible); XCTAssertFalse(p.keyboard)
    }
    func testKeyboardRouteRemainsAvailableWithoutPointer() {
        var p = PanelInteraction(); _ = p.receive(.openKeyboard, at: 0); _ = p.receive(.leavePanel, at: 1)
        XCTAssertNil(p.advance(at: 10)); XCTAssertTrue(p.visible)
        XCTAssertEqual(p.receive(.dismiss, at: 11), .close)
    }
    func testHoverDoesNotRequestKeyboardFocus() {
        var p = PanelInteraction(); _ = p.receive(.enterAnchor, at: 0); _ = p.advance(at: 0.3)
        XCTAssertFalse(p.keyboard)
    }
}
