import Foundation

/// Только системный адаптер умеет менять питание. Контроллер никогда не получает
/// из XPC команду оболочки, путь к программе или произвольные аргументы pmset.
public protocol SleepBackend: AnyObject {
    func clock() -> ClockReading
    func power() -> PowerSnapshot
    func criticalThermal() -> Bool
    func capability() -> Capability
    func sleepDisabled() throws -> Bool
    func setSleepDisabled(_ disabled: Bool) throws
    func acquireIdleAssertion() throws
    func releaseIdleAssertion() throws
    func sleepDisplays() throws
}
public protocol RecoveryStore: AnyObject {
    func load() throws -> RecoveryRecord?
    func save(_ record: RecoveryRecord) throws
    func clear() throws
}
public protocol HistoryStore: AnyObject {
    func records(for uid: UInt32) throws -> [SessionRecord]
    func append(_ record: SessionRecord) throws
}

/// Выполняется строго последовательно на очереди помощника. Эта же реализация
/// тестируется на Linux с подставными часами, питанием, журналом и адаптером сна.
public final class SessionController {
    private let backend: SleepBackend
    private let store: RecoveryStore
    private let history: BestEffortHistory
    private var lease: SessionLease?
    private var recovery: RecoveryRecord?
    private var recoveryError: String?
    private var message = "Удержание выключено."
    private var nextRecoveryAttempt: TimeInterval = 0
    private var nextSettingCheck: TimeInterval = 0
    private var appliedCommandIDs: [(UUID, UInt32)] = []
    private var bootstrapped = false
    private var maintenanceOwner: UInt32?
    private var maintenanceDeadline: TimeInterval = 0

    public init(backend: SleepBackend, recovery: RecoveryStore, history: HistoryStore) {
        self.backend = backend; self.store = recovery; self.history = BestEffortHistory(store: history)
    }
    public func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        do {
            recovery = try store.load()
            if recovery != nil { finish(.helperRestarted) }
        } catch { markRecoveryError(error) }
    }
    public func execute(_ command: ServiceCommand, peer: PeerIdentity) -> ServiceReply {
        bootstrap()
        tick()
        do {
            guard peer.uid > 0 else { throw BoggartError.message("Недопустимый пользователь.") }
            if appliedCommandIDs.contains(where: { $0.0 == command.id && $0.1 == peer.uid }) {
                return .init(status: snapshot(for: peer.uid))
            }
            switch command.kind {
            case .heartbeat:
                if maintenanceOwner == peer.uid { maintenanceDeadline = backend.clock().continuous + BoggartConstants.clientGrace }
                if lease?.ownerUID == peer.uid { try lease?.connected(at: backend.clock().continuous, peer: peer) }
            case .start:
                guard let hours = command.hours else { throw BoggartError.message("Не задана начальная длительность.") }
                try start(hours: hours, peer: peer)
            case .extendOneHour:
                try requireSession(command.sessionID, peer: peer)
                try lease?.extendOneHour(at: backend.clock().continuous)
            case .stop, .quit:
                if lease != nil || recovery != nil {
                    try requireOwner(peer)
                    guard let requested = command.sessionID,
                          requested == (lease?.id ?? recovery?.sessionID) else {
                        throw BoggartError.message("Сессия изменилась. Обновите состояние.")
                    }
                    finish(command.kind == .quit ? .applicationQuit : .manual)
                } else if recoveryError != nil {
                    throw BoggartError.message("Нужно восстановить состояние помощника.")
                }
            case .recover:
                if recovery == nil { try loadForRecovery() }
                if recovery != nil { try requireOwner(peer) }
                finish(recovery?.stopReason ?? .helperRestarted)
            case .sleepDisplays:
                try requireSession(command.sessionID, peer: peer)
                try backend.sleepDisplays()
            case .prepareMaintenance:
                if let owner = maintenanceOwner, owner != peer.uid {
                    throw BoggartError.message("Другой пользователь обслуживает Боггарт.")
                }
                if recovery == nil && recoveryError != nil { try loadForRecovery() }
                if lease != nil || recovery != nil { try requireOwner(peer) }
                finish(.applicationQuit)
                guard recoveryError == nil, lease == nil, recovery == nil else {
                    throw BoggartError.message(recoveryError ?? "Снятие удержания не подтверждено.")
                }
                maintenanceOwner = peer.uid
                maintenanceDeadline = backend.clock().continuous + BoggartConstants.clientGrace
            case .cancelMaintenance:
                guard maintenanceOwner == nil || maintenanceOwner == peer.uid else {
                    throw BoggartError.message("Другой пользователь обслуживает Боггарт.")
                }
                maintenanceOwner = nil
            }
            if command.kind != .heartbeat {
                appliedCommandIDs.append((command.id, peer.uid))
                if appliedCommandIDs.count > 128 { appliedCommandIDs.removeFirst(appliedCommandIDs.count - 128) }
            }
            return .init(status: snapshot(for: peer.uid), error: recoveryError)
        } catch {
            return .init(status: snapshot(for: peer.uid), error: error.localizedDescription)
        }
    }

    public func disconnected(_ peer: PeerIdentity) {
        lease?.disconnected(at: backend.clock().continuous, peer: peer)
    }
    public func shutdown() { finish(.systemShutdown) }

    public func tick() {
        guard bootstrapped else { return }
        let now = backend.clock().continuous
        history.retry(at: now)
        if maintenanceOwner != nil && now >= maintenanceDeadline { maintenanceOwner = nil }
        if recoveryError != nil {
            if now >= nextRecoveryAttempt {
                nextRecoveryAttempt = now + 5
                do {
                    if recovery == nil { try loadForRecovery() }
                    finish(recovery?.stopReason ?? .helperRestarted)
                } catch { markRecoveryError(error) }
            }
            return
        }
        guard var current = lease else { return }
        let reason = current.evaluate(at: now, power: backend.power(), critical: backend.criticalThermal())
        lease = current
        if let reason { finish(reason); return }
        if now >= nextSettingCheck {
            nextSettingCheck = now + 5
            do {
                if try !backend.sleepDisabled() { finish(.externalChange) }
            } catch {
                finish(.externalChange)
                if recoveryError == nil { message += " Не удалось проверить общую настройку сна." }
            }
        }
    }

    public func snapshot(for uid: UInt32) -> ServiceStatus {
        let power = backend.power()
        let capability = backend.capability()
        let records = history.records(for: uid, at: backend.clock().continuous)
        let historyWarning = history.warning(for: uid)
        let owner = lease?.ownerUID ?? recovery?.ownerUID ?? maintenanceOwner
        if let owner, owner != uid {
            return .init(phase: .ownedByAnotherUser, power: power, capability: capability,
                         message: maintenanceOwner == nil ? "Удержанием управляет другой пользователь этого Mac." : "Другой пользователь обновляет или удаляет Боггарт.", history: records, historyWarning: historyWarning, maintenancePending: maintenanceOwner != nil)
        }
        let phase: ServicePhase = recoveryError != nil ? .recoveryRequired : (lease == nil ? .inactive : .active)
        return .init(phase: phase, session: phase == .active ? lease?.snapshot : nil,
                     recoverySessionID: recoveryError == nil ? nil : recovery?.sessionID,
                     power: power, capability: capability, message: recoveryError ?? (maintenanceOwner != nil ? "Боггарт подготавливается к обслуживанию. Удержание выключено." : message), history: records, historyWarning: historyWarning, maintenancePending: maintenanceOwner != nil)
    }

    private func requireOwner(_ peer: PeerIdentity) throws {
        guard peer.uid == (lease?.ownerUID ?? recovery?.ownerUID) else {
            throw BoggartError.message("Эта сессия принадлежит другому пользователю.")
        }
    }
    private func requireSession(_ id: UUID?, peer: PeerIdentity) throws {
        try requireOwner(peer)
        guard recoveryError == nil, let current = lease, current.id == id,
              current.remaining(at: backend.clock().continuous) > 0 else {
            throw BoggartError.message("Сессия уже завершилась или была заменена. Команда не выполнена.")
        }
    }

    private func start(hours: Int, peer: PeerIdentity) throws {
        guard maintenanceOwner == nil else {
            throw BoggartError.message("Боггарт обновляется или удаляется. Запуск пока недоступен.")
        }
        guard lease == nil, recovery == nil, recoveryError == nil else {
            throw BoggartError.message("Сначала завершите текущую сессию или восстановление.")
        }
        let power = backend.power()
        guard power.known, power.external else {
            throw BoggartError.message("Подключите питание, чтобы включить удержание.")
        }
        guard !backend.criticalThermal() else { throw BoggartError.message("Критическое тепловое состояние. Удержание не включено.") }
        let capability = backend.capability()
        guard capability.available else { throw BoggartError.message(capability.message) }
        guard try !backend.sleepDisabled() else {
            throw BoggartError.message("Общий запрет сна уже включён другой утилитой. Боггарт не будет его менять.")
        }
        let candidate = try SessionLease(hours: hours, clock: backend.clock(), owner: peer)
        let record = RecoveryRecord(sessionID: candidate.id, ownerUID: peer.uid, startedAt: candidate.startedAt)
        // Запись синхронизируется с диском до первого изменения удержания.
        do { try store.save(record) }
        catch {
            // Если атомарная запись успела появиться, оставляем её для восстановления.
            do { recovery = try store.load() } catch { markRecoveryError(error) }
            if recovery != nil { finish(.activationFailed) }
            throw error
        }
        recovery = record
        do {
            try backend.acquireIdleAssertion()
            try backend.setSleepDisabled(true)
            guard try backend.sleepDisabled() else { throw BoggartError.message("macOS не подтвердила удержание закрытой крышки.") }
        } catch {
            finish(.activationFailed)
            throw error
        }
        lease = candidate
        message = "Удержание включено. Экраны могут быть выключены."
        nextSettingCheck = backend.clock().continuous + 5
        tick() // За время применения могли измениться питание или тепловое состояние.
    }

    /// Единая остановка для всех причин. Даже при ошибке глобального адаптера
    /// пробуем снять собственный IOKit assertion. Успех требует обоих механизмов.
    private func finish(_ reason: StopReason) {
        guard var record = recovery else {
            if recoveryError == nil {
                do { try backend.releaseIdleAssertion(); lease = nil; message = "Удержание выключено." }
                catch { markRecoveryError(error) }
            }
            return
        }
        if record.stopReason == nil { record.stopReason = reason }
        recovery = record
        // Ошибка обновления причины не должна задерживать снятие удержаний.
        try? store.save(record)
        var errors: [String] = []
        do {
            try record.validate()
            if !record.sleepRestored {
                if try backend.sleepDisabled() { try backend.setSleepDisabled(false) }
                guard try !backend.sleepDisabled() else { throw BoggartError.message("Общий запрет сна не снят.") }
                record.sleepRestored = true
                recovery = record
                // После подтверждённого снятия больше не трогаем глобальный флаг,
                // даже если запись истории или удаление журнала не удалось.
                try store.save(record)
            }
        } catch { errors.append(error.localizedDescription) }
        do { try backend.releaseIdleAssertion() }
        catch { errors.append(error.localizedDescription) }
        guard errors.isEmpty else {
            markRecoveryError(BoggartError.message(errors.joined(separator: " ")))
            return
        }
        do {
            let entry = SessionRecord(id: record.sessionID, ownerUID: record.ownerUID,
                                      startedAt: record.startedAt, endedAt: backend.clock().wall,
                                      reason: record.stopReason ?? reason)
            // Журнал безопасности завершается независимо от необязательной истории.
            // Потеря записи сессии при аварии в этом промежутке допустима; потеря
            // возможности вернуть сон — нет. Не перемещать append внутрь do/try.
            try store.clear()
            recovery = nil; lease = nil; recoveryError = nil
            message = "Удержание выключено."
            history.append(entry, at: backend.clock().continuous)
        } catch { markRecoveryError(error) }
    }
    private func loadForRecovery() throws {
        recovery = try store.load()
        if recovery == nil && lease == nil {
            // Предыдущая ошибка чтения могла быть временной. Без собственной
            // записи восстановления чужой глобальный запрет не сбрасываем.
            try backend.releaseIdleAssertion()
            recoveryError = nil
            message = "Удержание выключено."
        }
    }
    private func markRecoveryError(_ error: Error) {
        recoveryError = "Не удалось подтвердить снятие удержания. \(error.localizedDescription)"
        nextRecoveryAttempt = backend.clock().continuous + 5
    }
}
