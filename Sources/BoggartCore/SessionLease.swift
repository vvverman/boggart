import Foundation

public struct SessionLease: Equatable {
    public let id: UUID
    public let ownerUID: UInt32
    public let startedAt: Date
    public let continuousStart: TimeInterval
    public private(set) var deadline: TimeInterval
    public private(set) var clientDeadline: TimeInterval
    public private(set) var powerGraceDeadline: TimeInterval?
    public private(set) var connection: UUID

    public init(hours: Int, clock: ClockReading, owner: PeerIdentity, id: UUID = UUID()) throws {
        guard (1...24).contains(hours), clock.continuous.isFinite, clock.continuous >= 0 else {
            throw BoggartError.message("Начальная длительность — от 1 до 24 часов с шагом один час.")
        }
        let end = clock.continuous + Double(hours) * 3600
        let clientEnd = clock.continuous + BoggartConstants.clientGrace
        guard end.isFinite, end > clock.continuous, clientEnd.isFinite, clientEnd > clock.continuous else {
            throw BoggartError.message("Недопустимое значение системного отсчёта.")
        }
        self.id = id; ownerUID = owner.uid; startedAt = clock.wall; continuousStart = clock.continuous
        deadline = end
        clientDeadline = clientEnd
        connection = owner.connection
    }
    public func remaining(at now: TimeInterval) -> TimeInterval { max(0, deadline - now) }
    public mutating func extendOneHour(at now: TimeInterval) throws {
        guard now.isFinite, now < deadline else { throw BoggartError.message("Сессия уже завершилась. Продление не выполнено.") }
        let next = deadline + BoggartConstants.extensionSeconds
        guard next.isFinite, next > deadline else { throw BoggartError.message("Числовой предел отсчёта исчерпан.") }
        deadline = next
    }
    /// Сначала проверяется прежний дедлайн. Опоздавший heartbeat не оживляет сессию.
    public mutating func heartbeat(at now: TimeInterval, peer: PeerIdentity) throws {
        guard peer.uid == ownerUID, now < clientDeadline, now < deadline else {
            throw BoggartError.message("Срок текущего соединения истёк.")
        }
        connection = peer.connection
        clientDeadline = now + BoggartConstants.clientGrace
    }
    public mutating func disconnected(at now: TimeInterval, peer: PeerIdentity) {
        guard peer.uid == ownerUID, peer.connection == connection,
              now.isFinite, now < deadline, now < clientDeadline else { return }
        // Первый разрыв даёт полные 30 секунд. Повторный callback их не продлевает.
        if !isDisconnected {
            clientDeadline = now + BoggartConstants.clientGrace
            isDisconnected = true
        }
    }
    private var isDisconnected = false
    public mutating func connected(at now: TimeInterval, peer: PeerIdentity) throws {
        try heartbeat(at: now, peer: peer)
        isDisconnected = false
    }
    public mutating func evaluate(at now: TimeInterval, power: PowerSnapshot, critical: Bool) -> StopReason? {
        if critical { return .criticalThermal }
        if now >= deadline { return .expired }
        if now >= clientDeadline { return .clientLost }
        if !power.known { return .powerUnknown }
        // Возврат питания после дедлайна не отменяет уже наступившее завершение.
        if let grace = powerGraceDeadline, now >= grace { return .powerDisconnected }
        if power.external { powerGraceDeadline = nil }
        else if powerGraceDeadline == nil { powerGraceDeadline = now + BoggartConstants.powerGrace }
        return nil
    }
    public var snapshot: SessionSnapshot {
        .init(id: id, startedAt: startedAt, deadline: deadline, powerGraceDeadline: powerGraceDeadline)
    }
}
