import XCTest
@testable import BoggartCore

final class MaintenanceTests: XCTestCase {
    func testPreparationReleasesBothAndBlocksNewStarts() {
        let r = Rig(); r.start()
        let reply = r.command(.prepareMaintenance)
        XCTAssertNil(reply.error); XCTAssertEqual(reply.status.phase, .inactive)
        XCTAssertEqual(reply.status.maintenancePending, true)
        XCTAssertFalse(r.backend.disabled); XCTAssertFalse(r.backend.assertion); XCTAssertNil(r.recovery.value)
        XCTAssertNotNil(r.start().error)
    }
    func testForeignUserCannotInterruptSessionForMaintenance() {
        let r = Rig(); r.start()
        XCTAssertNotNil(r.command(.prepareMaintenance, peer: .init(uid: 502)).error)
        XCTAssertEqual(r.status.phase, .active); XCTAssertEqual(r.status.maintenancePending, false)
    }
    func testOtherUsersCannotStartDuringMaintenance() {
        let r = Rig(); r.command(.prepareMaintenance)
        let other = PeerIdentity(uid: 502)
        XCTAssertNotNil(r.engine.execute(.init(.start, hours: 1), peer: other).error)
        XCTAssertEqual(r.engine.snapshot(for: 502).phase, .ownedByAnotherUser)
    }
    func testForeignCancellationDoesNotReleaseMaintenance() {
        let r = Rig(); r.command(.prepareMaintenance)
        XCTAssertNotNil(r.command(.cancelMaintenance, peer: .init(uid: 502)).error)
        XCTAssertEqual(r.status.maintenancePending, true)
    }
    func testOwnerCancellationAllowsStartWithoutStartingItself() {
        let r = Rig(); r.command(.prepareMaintenance); r.command(.cancelMaintenance)
        XCTAssertEqual(r.status.maintenancePending, false); XCTAssertEqual(r.status.phase, .inactive)
        XCTAssertNil(r.start().error)
    }
    func testLostMaintenanceConnectionExpiresButNeverEnablesHold() {
        let r = Rig(); r.command(.prepareMaintenance)
        r.engine.disconnected(r.peer); r.pass(29, connected: false)
        XCTAssertEqual(r.status.maintenancePending, true)
        r.pass(1, connected: false)
        XCTAssertEqual(r.status.maintenancePending, false); XCTAssertEqual(r.status.phase, .inactive)
        XCTAssertFalse(r.backend.disabled)
    }
    func testOwnerHeartbeatKeepsMaintenanceReserved() {
        let r = Rig(); r.command(.prepareMaintenance); r.pass(60)
        XCTAssertEqual(r.status.maintenancePending, true); XCTAssertNotNil(r.start().error)
    }
    func testReleaseFailureCannotGrantMaintenancePermission() {
        let r = Rig(); r.start(); r.backend.failDisable = true
        let reply = r.command(.prepareMaintenance)
        XCTAssertNotNil(reply.error); XCTAssertEqual(reply.status.phase, .recoveryRequired)
        XCTAssertEqual(reply.status.maintenancePending, false); XCTAssertNotNil(r.recovery.value)
    }
    func testHistoryFailureDoesNotBlockMaintenanceReservation() {
        let r = Rig(); r.start(); r.history.failAppend = true
        XCTAssertNil(r.command(.prepareMaintenance).error)
        XCTAssertEqual(r.status.phase, .inactive); XCTAssertEqual(r.status.maintenancePending, true)
        XCTAssertNotNil(r.status.historyWarning)
    }
}
