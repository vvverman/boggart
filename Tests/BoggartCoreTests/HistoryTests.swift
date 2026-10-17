import XCTest
@testable import BoggartCore

final class HistoryTests: XCTestCase {
    private func entry(_ hour: Int, uid: UInt32 = 501, id: UUID = UUID()) -> SessionRecord {
        .init(id: id, ownerUID: uid, startedAt: Date(timeIntervalSince1970: Double(hour - 1) * 3600),
              endedAt: Date(timeIntervalSince1970: Double(hour) * 3600), reason: .expired)
    }
    func testFailedWriteKeepsRecordVisibleWithoutThrowing() {
        let store = MemoryHistory(), entry = entry(1)
        let h = BestEffortHistory(store: store); store.failAppend = true
        h.append(entry, at: 0)
        XCTAssertEqual(h.records(for: 501, at: 0), [entry]); XCTAssertNotNil(h.warning(for: 501))
    }
    func testRetryKeepsOriginalEndTimeAndID() {
        let store = MemoryHistory(), record = entry(1)
        let h = BestEffortHistory(store: store); store.failAppend = true
        h.append(record, at: 0); store.failAppend = false; h.retry(at: 500)
        XCTAssertEqual(store.values[501], [record]); XCTAssertNil(h.warning(for: 501))
    }
    func testRetriesAreThrottled() {
        let store = MemoryHistory(); let h = BestEffortHistory(store: store); store.failAppend = true
        h.append(entry(1), at: 100); XCTAssertEqual(store.appendAttempts, 1)
        h.retry(at: 104.999); XCTAssertEqual(store.appendAttempts, 1)
        h.retry(at: 105); XCTAssertEqual(store.appendAttempts, 2)
    }
    func testMultipleRetriesPersistInCompletionOrderNotWallOrder() {
        let store = MemoryHistory(); let h = BestEffortHistory(store: store); store.failAppend = true
        let a = entry(100), b = entry(10), c = entry(1)
        h.append(a, at: 0); h.append(b, at: 1); h.append(c, at: 2)
        store.failAppend = false; h.retry(at: 7)
        XCTAssertEqual(store.values[501], [c, b, a])
    }
    func testInMemoryHistoryAndRetryQueueBoundedToFive() {
        let store = MemoryHistory(); let h = BestEffortHistory(store: store); store.failAppend = true
        var records: [SessionRecord] = []
        for index in 1...20 { let e = entry(index); records.append(e); h.append(e, at: Double(index)) }
        XCTAssertEqual(h.records(for: 501, at: 20), Array(records.suffix(5).reversed()))
        let attempts = store.appendAttempts
        store.failAppend = false; h.retry(at: 100)
        XCTAssertEqual(store.appendAttempts - attempts, 5)
        XCTAssertEqual(store.values[501], Array(records.suffix(5).reversed()))
    }
    func testUserIsolationIncludesWarnings() {
        let store = MemoryHistory(); let h = BestEffortHistory(store: store)
        store.failAppend = true; h.append(entry(1, uid: 501), at: 0)
        store.failAppend = false; h.append(entry(2, uid: 502), at: 1)
        XCTAssertNotNil(h.warning(for: 501)); XCTAssertNil(h.warning(for: 502))
        XCTAssertTrue(h.records(for: 501, at: 1).allSatisfy { $0.ownerUID == 501 })
        XCTAssertTrue(h.records(for: 502, at: 1).allSatisfy { $0.ownerUID == 502 })
    }
    func testReadRecoveryMergesWithoutLosingUnpersistedEntries() {
        let store = MemoryHistory(), old = entry(1), recent = entry(2)
        store.values[501] = [old]; store.failRead = true; store.failAppend = true
        let h = BestEffortHistory(store: store)
        h.append(recent, at: 0)
        store.failRead = false; store.failAppend = false; h.retry(at: 5)
        XCTAssertEqual(h.records(for: 501, at: 5), [recent, old])
        XCTAssertEqual(store.values[501], [recent, old]); XCTAssertNil(h.warning(for: 501))
    }
    func testDuplicateIDDoesNotCreateAnotherRecord() {
        let store = MemoryHistory(), e = entry(1); let h = BestEffortHistory(store: store)
        h.append(e, at: 0); h.append(e, at: 1)
        XCTAssertEqual(h.records(for: 501, at: 1), [e]); XCTAssertEqual(store.appendAttempts, 1)
    }
}
