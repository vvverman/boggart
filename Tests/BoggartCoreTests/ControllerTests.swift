import XCTest
@testable import BoggartCore

final class ControllerTests: XCTestCase {
    func testStartConfirmsBothMechanisms() {
        let r = Rig(); let result = r.start()
        XCTAssertNil(result.error); XCTAssertEqual(r.status.phase, .active)
        XCTAssertTrue(r.backend.disabled); XCTAssertTrue(r.backend.assertion)
    }
    func testJournalExistsBeforeFirstMutation() {
        let r = Rig(); r.backend.onAcquire = { XCTAssertNotNil(r.recovery.value) }
        r.start(); XCTAssertGreaterThan(r.recovery.saves, 0)
    }
    func testForeignGlobalBanNotClaimedOrReset() {
        let r = Rig(); r.backend.disabled = true
        XCTAssertNotNil(r.start().error); XCTAssertTrue(r.backend.disabled)
        XCTAssertNil(r.recovery.value); XCTAssertTrue(r.backend.calls.isEmpty)
    }
    func testNoPowerNoStart() {
        let r = Rig(); r.backend.source = .init(external: false)
        XCTAssertNotNil(r.start().error); XCTAssertNil(r.recovery.value)
    }
    func testUnvalidatedReleaseCannotStart() {
        let r = Rig(); r.backend.supported = false
        XCTAssertNotNil(r.start().error); XCTAssertTrue(r.backend.calls.isEmpty)
    }
    func testCriticalCannotStart() {
        let r = Rig(); r.backend.critical = true
        XCTAssertNotNil(r.start().error); XCTAssertNil(r.recovery.value)
    }
    func testStartFailureRollsBack() {
        let r = Rig(); r.backend.failEnable = true
        XCTAssertNotNil(r.start().error)
        XCTAssertEqual(r.status.phase, .inactive); XCTAssertFalse(r.backend.assertion); XCTAssertNil(r.recovery.value)
    }
    func testJournalWriteFailureDoesNotMutateSleep() {
        let r = Rig(); r.recovery.failSave = true
        XCTAssertNotNil(r.start().error); XCTAssertTrue(r.backend.calls.isEmpty)
    }
    func testManualStopUsesCommonRelease() {
        let r = Rig(); r.start(); r.command(.stop)
        XCTAssertEqual(r.status.phase, .inactive)
        XCTAssertFalse(r.backend.disabled); XCTAssertFalse(r.backend.assertion); XCTAssertNil(r.recovery.value)
        XCTAssertEqual(r.status.history.first?.reason, .manual)
        XCTAssertEqual(r.status.message, "Удержание выключено.")
    }
    func testExpiryReleasesBothMechanisms() {
        let r = Rig(); r.start(1); r.pass(3600)
        XCTAssertEqual(r.status.phase, .inactive); XCTAssertFalse(r.backend.disabled); XCTAssertFalse(r.backend.assertion)
        XCTAssertEqual(r.status.history.first?.reason, .expired)
    }
    func testPowerReturnWithinGraceKeepsOriginalDeadline() {
        let r = Rig(); r.start(); let deadline = r.status.session?.deadline
        r.backend.source = .init(external: false); r.engine.tick(); r.pass(9)
        r.backend.source = .init(external: true); r.engine.tick()
        XCTAssertEqual(r.status.phase, .active); XCTAssertEqual(r.status.session?.deadline, deadline)
    }
    func testPowerDisconnectedStopsAndDoesNotAutoRestart() {
        let r = Rig(); r.start(); r.backend.source = .init(external: false); r.engine.tick(); r.pass(10)
        XCTAssertEqual(r.status.phase, .inactive); XCTAssertEqual(r.status.history.first?.reason, .powerDisconnected)
        r.backend.source = .init(external: true); r.pass(20)
        XCTAssertEqual(r.status.phase, .inactive)
    }
    func testExtensionsPastDayAndNextStartUnchanged() {
        let r = Rig(); r.start(24)
        for _ in 0..<7 { XCTAssertNil(r.command(.extendOneHour).error) }
        XCTAssertEqual(r.status.session?.remaining(at: r.backend.now), 31 * 3600)
        r.command(.stop); r.start(24)
        XCTAssertEqual(r.status.session?.remaining(at: r.backend.now), 24 * 3600)
    }
    func testDuplicateExtensionIsIdempotent() {
        let r = Rig(); r.start(24)
        let c = ServiceCommand(.extendOneHour, sessionID: r.status.session?.id)
        _ = r.engine.execute(c, peer: r.peer); _ = r.engine.execute(c, peer: r.peer)
        XCTAssertEqual(r.status.session?.remaining(at: r.backend.now), 25 * 3600)
    }
    func testDuplicateStartCannotStartAgainAfterStop() {
        let r = Rig(); let c = ServiceCommand(.start, hours: 12)
        _ = r.engine.execute(c, peer: r.peer); r.command(.stop)
        _ = r.engine.execute(c, peer: r.peer); XCTAssertEqual(r.status.phase, .inactive)
    }
    func testConcurrentStartRejected() {
        let r = Rig(); r.start(); let id = r.status.session?.id
        XCTAssertNotNil(r.start().error); XCTAssertEqual(r.status.session?.id, id)
    }
    func testExpiredExtensionDoesNotCreateSession() {
        let r = Rig(); r.start(1); let id = r.status.session?.id
        r.backend.advance(3600)
        let result = r.engine.execute(.init(.extendOneHour, sessionID: id), peer: r.peer)
        XCTAssertNotNil(result.error); XCTAssertEqual(r.status.phase, .inactive)
    }
    func testStaleStopDoesNotStopNewSession() {
        let r = Rig(); r.start(); let oldID = r.status.session?.id
        r.command(.stop); r.start()
        XCTAssertNotNil(r.engine.execute(.init(.stop, sessionID: oldID), peer: r.peer).error)
        XCTAssertEqual(r.status.phase, .active)
    }
    func testForeignUserCannotControlOrReadSession() {
        let r = Rig(); r.start()
        let foreign = PeerIdentity(uid: 502)
        XCTAssertNotNil(r.command(.stop, peer: foreign).error)
        XCTAssertEqual(r.engine.snapshot(for: 502).phase, .ownedByAnotherUser)
        XCTAssertNil(r.engine.snapshot(for: 502).session)
        XCTAssertEqual(r.status.phase, .active)
    }
    func testDisconnectAndReconnectPreserveLease() {
        let r = Rig(); r.start(); let id = r.status.session?.id, deadline = r.status.session?.deadline
        r.engine.disconnected(r.peer); r.pass(29, connected: false)
        XCTAssertNil(r.command(.heartbeat, peer: .init(uid: 501)).error)
        XCTAssertEqual(r.status.session?.id, id); XCTAssertEqual(r.status.session?.deadline, deadline)
    }
    func testDisconnectWithoutReturnStops() {
        let r = Rig(); r.start(); r.engine.disconnected(r.peer); r.pass(30, connected: false)
        XCTAssertEqual(r.status.phase, .inactive); XCTAssertEqual(r.status.history.first?.reason, .clientLost)
        XCTAssertFalse(r.backend.disabled)
    }
    func testHelperRestartRestoresInsteadOfResuming() {
        let r = Rig(); r.start()
        let newEngine = SessionController(backend: r.backend, recovery: r.recovery, history: r.history)
        newEngine.bootstrap()
        XCTAssertEqual(newEngine.snapshot(for: 501).phase, .inactive)
        XCTAssertFalse(r.backend.disabled); XCTAssertNil(r.recovery.value)
        XCTAssertEqual(newEngine.snapshot(for: 501).history.first?.reason, .helperRestarted)
    }
    func testFailedGlobalReleasePreservesErrorAndJournal() {
        let r = Rig(); r.start(); r.backend.failDisable = true
        XCTAssertNotNil(r.command(.stop).error)
        XCTAssertEqual(r.status.phase, .recoveryRequired); XCTAssertTrue(r.backend.disabled)
        XCTAssertFalse(r.backend.assertion); XCTAssertNotNil(r.recovery.value)
        XCTAssertNotNil(r.start().error)
    }
    func testFailedAssertionReleaseNotReportedAsSuccess() {
        let r = Rig(); r.start(); r.backend.failRelease = true
        XCTAssertNotNil(r.command(.stop).error)
        XCTAssertEqual(r.status.phase, .recoveryRequired); XCTAssertFalse(r.backend.disabled)
        XCTAssertNotNil(r.recovery.value)
    }
    func testRecoveryRetriesAndKeepsOriginalReason() {
        let r = Rig(); r.start(); r.backend.failDisable = true; r.command(.stop)
        r.backend.failDisable = false; r.backend.advance(5); r.engine.tick()
        XCTAssertEqual(r.status.phase, .inactive); XCTAssertNil(r.recovery.value)
        XCTAssertEqual(r.status.history.first?.reason, .manual)
    }
    func testFailedJournalDeletionNotSilent() {
        let r = Rig(); r.start(); r.recovery.failClear = true; r.command(.stop)
        XCTAssertEqual(r.status.phase, .recoveryRequired); XCTAssertNotNil(r.recovery.value)
        r.recovery.failClear = false; r.command(.recover)
        XCTAssertEqual(r.status.phase, .inactive); XCTAssertEqual(r.status.history.count, 1)
    }
    func testFailedHistoryPersistenceNeverRetainsSleepOrJournal() {
        let r = Rig(); r.start(); r.history.failAppend = true
        XCTAssertNil(r.command(.stop).error)
        XCTAssertEqual(r.status.phase, .inactive); XCTAssertNil(r.recovery.value)
        XCTAssertFalse(r.backend.disabled); XCTAssertFalse(r.backend.assertion)
        XCTAssertEqual(r.status.history.count, 1); XCTAssertNotNil(r.status.historyWarning)
        XCTAssertEqual(r.status.message, "Удержание выключено.")
        r.history.failAppend = false; r.backend.advance(5); r.engine.tick()
        XCTAssertEqual(r.status.history.count, 1); XCTAssertNil(r.status.historyWarning)
        XCTAssertEqual(r.history.values[501]?.count, 1)
    }
    func testHistoryFailureDoesNotBlockQuitOrAnotherSession() {
        let r = Rig(); r.start(); r.history.failAppend = true
        XCTAssertNil(r.command(.quit).error); XCTAssertEqual(r.status.phase, .inactive)
        XCTAssertNil(r.start().error); XCTAssertEqual(r.status.phase, .active)
    }
    func testHistoryRetryNeverTouchesNewForeignBan() {
        let r = Rig(); r.start(); r.history.failAppend = true; r.command(.stop)
        r.backend.disabled = true
        let calls = r.backend.calls
        r.history.failAppend = false; r.backend.advance(5); r.engine.tick()
        XCTAssertTrue(r.backend.disabled); XCTAssertEqual(calls, r.backend.calls)
    }
    func testHistoryFailureDoesNotMaskRealReleaseFailure() {
        let r = Rig(); r.start(); r.history.failAppend = true; r.backend.failDisable = true
        XCTAssertNotNil(r.command(.quit).error); XCTAssertEqual(r.status.phase, .recoveryRequired)
        XCTAssertNotNil(r.recovery.value); XCTAssertTrue(r.backend.disabled)
    }
    func testHistoryReadFailureDoesNotBlockStartOrStop() {
        let r = Rig(); r.history.failRead = true
        XCTAssertNil(r.start().error); XCTAssertNil(r.command(.stop).error)
        XCTAssertEqual(r.status.phase, .inactive); XCTAssertNil(r.recovery.value)
        XCTAssertNotNil(r.status.historyWarning)
    }
    func testHistoryIsNotWrittenBeforeSafetyJournalClears() {
        let r = Rig(); r.start(); r.recovery.failClear = true; r.command(.stop)
        XCTAssertEqual(r.status.phase, .recoveryRequired)
        XCTAssertEqual(r.history.appendAttempts, 0)
        r.recovery.failClear = false; r.command(.recover)
        XCTAssertEqual(r.history.appendAttempts, 1)
    }
    func testHistoryFiveSessionsInCompletionOrderEvenClockMovedBack() {
        let r = Rig()
        for _ in 0..<8 { r.start(); r.backend.date.addTimeInterval(-100); r.command(.stop) }
        XCTAssertEqual(r.status.history.count, 5)
        XCTAssertLessThan(r.status.history[0].endedAt, r.status.history[1].endedAt)
    }
    func testDisplaySleepRequiresActiveMatchingSession() {
        let r = Rig(); XCTAssertNotNil(r.command(.sleepDisplays).error)
        r.start(); let deadline = r.status.session?.deadline
        XCTAssertNil(r.command(.sleepDisplays).error)
        XCTAssertEqual(r.backend.displayCalls, 1); XCTAssertEqual(r.status.session?.deadline, deadline)
        XCTAssertEqual(r.status.phase, .active)
    }
    func testThermalStopReleasesBoth() {
        let r = Rig(); r.start(); r.backend.critical = true; r.engine.tick()
        XCTAssertEqual(r.status.history.first?.reason, .criticalThermal)
        XCTAssertFalse(r.backend.disabled); XCTAssertFalse(r.backend.assertion)
    }
    func testGlobalChangeFromOutsideStopsSession() {
        let r = Rig(); r.start(); r.backend.disabled = false; r.pass(5)
        XCTAssertEqual(r.status.phase, .inactive); XCTAssertEqual(r.status.history.first?.reason, .externalChange)
    }
    func testQuitFailureKeepsRecoveryState() {
        let r = Rig(); r.start(); r.backend.failDisable = true
        XCTAssertNotNil(r.command(.quit).error); XCTAssertEqual(r.status.phase, .recoveryRequired)
    }
    func testWallClockChangeDoesNotChangeDeadline() {
        let r = Rig(); r.start(); let deadline = r.status.session?.deadline
        r.backend.date.addTimeInterval(86400 * 10); r.command(.heartbeat)
        XCTAssertEqual(r.status.session?.deadline, deadline)
        r.backend.date.addTimeInterval(-86400 * 20); r.command(.heartbeat)
        XCTAssertEqual(r.status.session?.deadline, deadline)
    }
    func testNoConfirmationBeforeGlobalAdapterReturns() {
        let r = Rig()
        r.backend.onAcquire = { XCTAssertNotEqual(r.status.phase, .active) }
        r.start(); XCTAssertEqual(r.status.phase, .active)
    }
    func testAlreadyRestoredGlobalStateNotClaimedAgainDuringJournalRetry() {
        let r = Rig(); r.start(); r.recovery.failClear = true; r.command(.stop)
        XCTAssertEqual(r.recovery.value?.sleepRestored, true)
        r.backend.disabled = true // Другая утилита включилась после снятия нашего запрета.
        r.recovery.failClear = false; r.command(.recover)
        XCTAssertTrue(r.backend.disabled)
        XCTAssertEqual(r.status.phase, .inactive)
    }
    func testTransientJournalReadFailureCanRecoverWithoutResettingForeignBan() {
        let r = Rig(); r.recovery.failLoad = true; r.engine.bootstrap()
        XCTAssertEqual(r.status.phase, .recoveryRequired)
        r.recovery.failLoad = false; r.backend.disabled = true
        r.command(.recover)
        XCTAssertEqual(r.status.phase, .inactive); XCTAssertTrue(r.backend.disabled)
    }
}
