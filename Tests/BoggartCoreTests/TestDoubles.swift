import Foundation
import BoggartCore

final class FakeBackend: SleepBackend {
    var now: TimeInterval = 1000
    var date = Date(timeIntervalSince1970: 1_792_252_800)
    var source = PowerSnapshot(external: true, batteryPercent: 100)
    var critical = false
    var supported = true
    var disabled = false
    var assertion = false
    var failEnable = false
    var failDisable = false
    var failAcquire = false
    var failRelease = false
    var failRead = false
    var displayCalls = 0
    var calls: [String] = []
    var onAcquire: (() -> Void)?
    func clock() -> ClockReading { .init(now, wall: date) }
    func power() -> PowerSnapshot { source }
    func criticalThermal() -> Bool { critical }
    func capability() -> Capability { .init(available: supported, message: "Конфигурация не проверена.") }
    func sleepDisabled() throws -> Bool {
        if failRead { throw BoggartError.message("read") }; return disabled
    }
    func setSleepDisabled(_ value: Bool) throws {
        calls.append(value ? "global.on" : "global.off")
        if value && failEnable { throw BoggartError.message("enable") }
        if !value && failDisable { throw BoggartError.message("disable") }
        disabled = value
    }
    func acquireIdleAssertion() throws {
        calls.append("assertion.on"); onAcquire?()
        if failAcquire { throw BoggartError.message("acquire") }; assertion = true
    }
    func releaseIdleAssertion() throws {
        calls.append("assertion.off")
        if failRelease { throw BoggartError.message("release") }; assertion = false
    }
    func sleepDisplays() throws { displayCalls += 1 }
    func advance(_ seconds: TimeInterval) { now += seconds; date.addTimeInterval(seconds) }
}
final class MemoryRecovery: RecoveryStore {
    var value: RecoveryRecord?
    var failSave = false
    var failLoad = false
    var failClear = false
    var saves = 0
    func load() throws -> RecoveryRecord? {
        if failLoad { throw BoggartError.message("load") }; return value
    }
    func save(_ record: RecoveryRecord) throws {
        if failSave { throw BoggartError.message("save") }; value = record; saves += 1
    }
    func clear() throws {
        if failClear { throw BoggartError.message("clear") }; value = nil
    }
}
final class MemoryHistory: HistoryStore {
    var values: [UInt32: [SessionRecord]] = [:]
    var failAppend = false
    var failRead = false
    var appendAttempts = 0
    func records(for uid: UInt32) throws -> [SessionRecord] {
        if failRead { throw BoggartError.message("history read") }
        return values[uid] ?? []
    }
    func append(_ record: SessionRecord) throws {
        appendAttempts += 1
        if failAppend { throw BoggartError.message("history") }
        let old = values[record.ownerUID] ?? []
        guard !old.contains(where: { $0.id == record.id }) else { return }
        values[record.ownerUID] = HistoryPolicy.appending(record, to: old)
    }
}
final class Rig {
    let backend = FakeBackend(), recovery = MemoryRecovery(), history = MemoryHistory()
    let peer = PeerIdentity(uid: 501)
    lazy var engine = SessionController(backend: backend, recovery: recovery, history: history)
    @discardableResult func start(_ hours: Int = 12) -> ServiceReply { engine.execute(.init(.start, hours: hours), peer: peer) }
    var status: ServiceStatus { engine.snapshot(for: peer.uid) }
    @discardableResult func command(_ kind: CommandKind, peer other: PeerIdentity? = nil) -> ServiceReply {
        engine.execute(.init(kind, sessionID: status.session?.id ?? status.recoverySessionID), peer: other ?? peer)
    }
    func pass(_ seconds: TimeInterval, connected: Bool = true) {
        var left = seconds
        while left > 0 {
            let step = min(left, 5); backend.advance(step)
            if connected { _ = command(.heartbeat) } else { engine.tick() }
            left -= step
        }
    }
}
