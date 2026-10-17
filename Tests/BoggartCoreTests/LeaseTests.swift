import XCTest
@testable import BoggartCore

final class LeaseTests: XCTestCase {
    let peer = PeerIdentity(uid: 501)
    func lease(_ hours: Int = 24) throws -> SessionLease {
        try .init(hours: hours, clock: .init(100, wall: Date(timeIntervalSince1970: 0)), owner: peer)
    }
    func testInitialRange() throws {
        for h in 1...24 { XCTAssertEqual(try lease(h).remaining(at: 100), Double(h * 3600)) }
        for h in [-1, 0, 25, Int.max] { XCTAssertThrowsError(try lease(h)) }
    }
    func testTwentyFourPlusOneIsTwentyFive() throws {
        var value = try lease(); try value.extendOneHour(at: 100)
        XCTAssertEqual(value.remaining(at: 100), 25 * 3600)
    }
    func testManyExtensionsHaveNoDailyLimit() throws {
        var value = try lease()
        for _ in 0..<1000 { try value.extendOneHour(at: 100) }
        XCTAssertEqual(value.remaining(at: 100), 1024 * 3600)
    }
    func testExtensionAddsToDeadlineNotNow() throws {
        var value = try lease(1); try value.extendOneHour(at: 1234)
        XCTAssertEqual(value.deadline, 100 + 7200)
        XCTAssertEqual(value.continuousStart, 100)
    }
    func testCannotExtendAtDeadlineOrAfter() throws {
        var value = try lease(1)
        XCTAssertThrowsError(try value.extendOneHour(at: 3700))
        XCTAssertThrowsError(try value.extendOneHour(at: 3800))
    }
    func testUnrepresentableInitialClockRejected() throws {
        for clock in [Double.infinity, Double.nan, Double.greatestFiniteMagnitude, -1] {
            XCTAssertThrowsError(try SessionLease(hours: 24, clock: .init(clock, wall: Date()), owner: peer))
        }
    }
    func testLateDisconnectDoesNotReviveExpiredClientLease() throws {
        var value = try lease()
        value.disconnected(at: 130, peer: peer)
        XCTAssertEqual(value.clientDeadline, 130)
        XCTAssertEqual(value.evaluate(at: 130, power: .init(external: true), critical: false), .clientLost)
    }
    func testWallClockIsNotPartOfDuration() throws {
        let value = try lease(); XCTAssertEqual(value.remaining(at: 101), 86400 - 1)
    }
    func testPowerGraceAndTimelyReturn() throws {
        var value = try lease()
        XCTAssertNil(value.evaluate(at: 100, power: .init(external: false), critical: false))
        XCTAssertEqual(value.powerGraceDeadline, 110)
        XCTAssertNil(value.evaluate(at: 109.9, power: .init(external: true), critical: false))
        XCTAssertNil(value.powerGraceDeadline)
        XCTAssertEqual(value.deadline, 86500)
    }
    func testPowerReturnAtOrAfterDeadlineTooLate() throws {
        for now in [110.0, 111.0] {
            var value = try lease()
            _ = value.evaluate(at: 100, power: .init(external: false), critical: false)
            XCTAssertEqual(value.evaluate(at: now, power: .init(external: true), critical: false), .powerDisconnected)
        }
    }
    func testPollingDoesNotRestartPowerGrace() throws {
        var value = try lease()
        for t in 100..<110 { _ = value.evaluate(at: Double(t), power: .init(external: false), critical: false) }
        XCTAssertEqual(value.powerGraceDeadline, 110)
    }
    func testDisconnectGivesThirtySecondsWithoutRepeatedReset() throws {
        var value = try lease()
        value.disconnected(at: 115, peer: peer); value.disconnected(at: 120, peer: peer)
        XCTAssertEqual(value.clientDeadline, 145)
        XCTAssertNil(value.evaluate(at: 144.9, power: .init(external: true), critical: false))
        XCTAssertEqual(value.evaluate(at: 145, power: .init(external: true), critical: false), .clientLost)
    }
    func testReconnectPreservesSessionAndDeadline() throws {
        var value = try lease(); let id = value.id, deadline = value.deadline
        value.disconnected(at: 101, peer: peer)
        let replacement = PeerIdentity(uid: 501)
        try value.connected(at: 129, peer: replacement)
        XCTAssertEqual(value.id, id); XCTAssertEqual(value.deadline, deadline)
        value.disconnected(at: 130, peer: peer) // Старое соединение не влияет на новое.
        XCTAssertEqual(value.clientDeadline, 159)
    }
    func testLateHeartbeatCannotResurrect() throws {
        var value = try lease(); XCTAssertThrowsError(try value.connected(at: 130, peer: peer))
    }
    func testForeignHeartbeatRejected() throws {
        var value = try lease(); XCTAssertThrowsError(try value.connected(at: 101, peer: .init(uid: 502)))
    }
    func testThermalCriticalImmediate() throws {
        var value = try lease()
        XCTAssertEqual(value.evaluate(at: 100, power: .init(external: true), critical: true), .criticalThermal)
    }
    func testUnknownPowerProtectiveStop() throws {
        var value = try lease(); XCTAssertEqual(value.evaluate(at: 100, power: .unknown, critical: false), .powerUnknown)
    }
    func testExpiryNotDependentOnHeartbeat() throws {
        var value = try lease(1)
        XCTAssertEqual(value.evaluate(at: 3700, power: .init(external: true), critical: false), .expired)
    }
    func testBatteryPercentDoesNotReplaceExternalPower() throws {
        var value = try lease()
        XCTAssertNil(value.evaluate(at: 100, power: .init(external: true, batteryPercent: 1), critical: false))
    }
}
