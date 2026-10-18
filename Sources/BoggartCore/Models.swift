import Foundation

public enum BoggartConstants {
    public static let version = "0.5.3"
    public static let protocolVersion = 4
    #if BOGGART_HARDWARE_TESTING
    public static let hardwareTesting = true
    #else
    public static let hardwareTesting = false
    #endif
    public static let appID = "local.boggart.app"
    public static let serviceID = "local.boggart.helper"
    public static let daemonPlist = "local.boggart.helper.plist"
    public static let dataDirectory = "/Library/Application Support/Boggart/v3"
    public static let powerGrace: TimeInterval = 10
    public static let clientGrace: TimeInterval = 30
    public static let extensionSeconds: TimeInterval = 3600
}

public enum BoggartError: LocalizedError, Equatable {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

public struct ClockReading {
    public let continuous: TimeInterval
    public let wall: Date
    public init(_ continuous: TimeInterval, wall: Date) { self.continuous = continuous; self.wall = wall }
}

public struct PowerSnapshot: Codable, Equatable {
    public let external: Bool
    public let known: Bool
    public let batteryPercent: Int?
    public init(external: Bool, known: Bool = true, batteryPercent: Int? = nil) {
        self.external = external; self.known = known
        self.batteryPercent = batteryPercent.map { min(100, max(0, $0)) }
    }
    public static let unknown = PowerSnapshot(external: false, known: false)
    public var label: String {
        guard known else { return "Источник питания не определён" }
        return external ? "Внешнее питание" : "Аккумулятор"
    }
}

public struct Capability: Codable, Equatable {
    public let available: Bool
    public let validationBuild: Bool
    public let message: String
    public init(available: Bool, validationBuild: Bool = false, message: String) {
        self.available = available; self.validationBuild = validationBuild; self.message = message
    }
}

public enum StopReason: String, Codable, CaseIterable {
    case manual, expired, powerDisconnected, criticalThermal, clientLost, helperRestarted
    case applicationQuit, powerUnknown, externalChange, activationFailed, systemShutdown
    public var description: String {
        switch self {
        case .manual: return "остановлено вручную"
        case .expired: return "время истекло"
        case .powerDisconnected: return "отключено питание"
        case .criticalThermal: return "критическое тепловое состояние"
        case .clientLost: return "завершено после потери связи или сбоя приложения"
        case .helperRestarted: return "восстановлено после перезапуска помощника"
        case .applicationQuit: return "выход из Боггарта"
        case .powerUnknown: return "не удалось определить источник питания"
        case .externalChange: return "настройка сна изменена извне"
        case .activationFailed: return "не удалось включить удержание"
        case .systemShutdown: return "остановка системного помощника"
        }
    }
    public var abnormal: Bool {
        switch self { case .manual, .expired, .applicationQuit: return false; default: return true }
    }
}

public struct SessionRecord: Codable, Equatable, Identifiable {
    public let id: UUID
    public let ownerUID: UInt32
    public let startedAt: Date
    public let endedAt: Date
    public let reason: StopReason
    public init(id: UUID, ownerUID: UInt32, startedAt: Date, endedAt: Date, reason: StopReason) {
        self.id = id; self.ownerUID = ownerUID; self.startedAt = startedAt
        self.endedAt = endedAt; self.reason = reason
    }
}

/// Только запись восстановления. Дедлайн не восстанавливается из диска: после
/// перезапуска помощника старая сессия завершается, а не возобновляется.
public struct RecoveryRecord: Codable, Equatable {
    public let schema: Int
    public let sessionID: UUID
    public let ownerUID: UInt32
    public let startedAt: Date
    public let originalSleepDisabled: Bool
    public var stopReason: StopReason?
    public var sleepRestored = false
    public init(sessionID: UUID, ownerUID: UInt32, startedAt: Date) {
        self.schema = 3; self.sessionID = sessionID; self.ownerUID = ownerUID
        self.startedAt = startedAt; self.originalSleepDisabled = false
    }
    public func validate() throws {
        guard schema == 3, ownerUID > 0, !originalSleepDisabled,
              startedAt.timeIntervalSince1970.isFinite else {
            throw BoggartError.message("Запись восстановления повреждена. Глобальная настройка не изменена.")
        }
    }
}

public struct SessionSnapshot: Codable, Equatable {
    public let id: UUID
    public let startedAt: Date
    /// mach_continuous_time в секундах: одна шкала для процессов этого запуска macOS.
    public let deadline: TimeInterval
    public let powerGraceDeadline: TimeInterval?
    public init(id: UUID, startedAt: Date, deadline: TimeInterval, powerGraceDeadline: TimeInterval?) {
        self.id = id; self.startedAt = startedAt; self.deadline = deadline
        self.powerGraceDeadline = powerGraceDeadline
    }
    public func remaining(at continuous: TimeInterval) -> TimeInterval { max(0, deadline - continuous) }
}

public enum ServicePhase: String, Codable { case inactive, active, recoveryRequired, ownedByAnotherUser }

public struct ServiceStatus: Codable {
    public var protocolVersion = BoggartConstants.protocolVersion
    public var helperVersion = BoggartConstants.version
    public var phase: ServicePhase
    public var session: SessionSnapshot?
    public var recoverySessionID: UUID?
    public var power: PowerSnapshot
    public var capability: Capability
    public var message: String
    public var history: [SessionRecord]
    /// Неисправность необязательной истории, не ошибка снятия удержаний.
    public var historyWarning: String?
    public var maintenancePending: Bool?
    public init(phase: ServicePhase, session: SessionSnapshot? = nil, recoverySessionID: UUID? = nil,
                power: PowerSnapshot, capability: Capability, message: String, history: [SessionRecord], historyWarning: String? = nil, maintenancePending: Bool = false) {
        self.phase = phase; self.session = session; self.recoverySessionID = recoverySessionID
        self.power = power; self.capability = capability; self.message = message; self.history = history
        self.historyWarning = historyWarning; self.maintenancePending = maintenancePending
    }
}

/// Нет поля для пути, команды оболочки, произвольного аргумента pmset или длительности продления.
public enum CommandKind: String, Codable { case heartbeat, start, extendOneHour, stop, quit, recover, sleepDisplays, prepareMaintenance, cancelMaintenance }
public struct ServiceCommand: Codable {
    public let id: UUID
    public let kind: CommandKind
    public let hours: Int?
    public let sessionID: UUID?
    public init(_ kind: CommandKind, hours: Int? = nil, sessionID: UUID? = nil, id: UUID = UUID()) {
        self.id = id; self.kind = kind; self.hours = hours; self.sessionID = sessionID
    }
}
public struct ServiceReply: Codable {
    public let status: ServiceStatus
    public let error: String?
    public init(status: ServiceStatus, error: String? = nil) { self.status = status; self.error = error }
}
public struct PeerIdentity: Equatable {
    public let uid: UInt32
    public let connection: UUID
    public init(uid: UInt32, connection: UUID = UUID()) { self.uid = uid; self.connection = connection }
}

public enum Preferences {
    public static func hours(_ value: Int?) -> Int { value.flatMap { (1...24).contains($0) ? $0 : nil } ?? 12 }
    public static func countdown(newValue: Bool?, legacyMode: String?) -> Bool {
        if let newValue { return newValue }
        return legacyMode == nil || legacyMode == "countdown"
    }
}

public enum SleepSetting: Equatable { case unset, enabled, disabled }
public enum PMSetParser {
    public static func sleepSetting(from text: String) throws -> SleepSetting {
        var header = false
        var result: SleepSetting?
        for line in text.split(whereSeparator: \.isNewline) {
            if line.trimmingCharacters(in: .whitespaces) == "System-wide power settings:" { header = true }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.first == "SleepDisabled" else { continue }
            guard fields.count == 2, let number = Int(fields[1]), (0...1).contains(number), result == nil else {
                throw BoggartError.message("Неожиданный формат SleepDisabled.")
            }
            result = number == 1 ? .disabled : .enabled
        }
        guard header else { throw BoggartError.message("Не удалось прочитать общесистемную настройку сна.") }
        return result ?? .unset
    }
}
