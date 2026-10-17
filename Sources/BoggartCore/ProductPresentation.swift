import Foundation

public enum RecentSessionText {
    /// Показываем только последнее завершение, если оно нештатное. Не вытаскиваем
    /// старую ошибку из глубины истории после более поздней успешной сессии.
    public static func abnormalRecord(_ history: [SessionRecord], phase: ServicePhase?) -> SessionRecord? {
        guard phase == .inactive, let latest = history.first, latest.reason.abnormal else { return nil }
        return latest
    }
    public static func summary(_ record: SessionRecord, now: Date = Date(), calendar: Calendar = .current) -> String {
        "Удержание завершено \(moment(record.endedAt, now: now, calendar: calendar)): \(record.reason.description)."
    }
    public static func moment(_ date: Date, now: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU"); formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "сегодня в \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "вчера в \(time)"
        }
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "d MMMM" : "d MMMM yyyy"
        return "\(formatter.string(from: date)) в \(time)"
    }
}

/// В диагностику попадают только явно перечисленные поля. Здесь нет путей,
/// имени пользователя, серийного номера, списка процессов, задач или сети.
public struct DiagnosticReport {
    public let appVersion: String
    public let osVersion: String
    public let model: String
    public let helperState: String
    public let phase: ServicePhase?
    public let sourceKnown: Bool
    public let externalPower: Bool
    public let validationBuild: Bool
    public let historyWarning: Bool
    public let lastReason: StopReason?
    public init(appVersion: String, osVersion: String, model: String, helperState: String,
                phase: ServicePhase?, sourceKnown: Bool, externalPower: Bool,
                validationBuild: Bool, historyWarning: Bool, lastReason: StopReason?) {
        self.appVersion = appVersion; self.osVersion = osVersion; self.model = model
        self.helperState = helperState; self.phase = phase; self.sourceKnown = sourceKnown
        self.externalPower = externalPower; self.validationBuild = validationBuild
        self.historyWarning = historyWarning; self.lastReason = lastReason
    }
    public var text: String {
        let state: String
        switch phase {
        case .inactive: state = "Удержание выключено"
        case .active: state = "Удержание включено"
        case .recoveryRequired: state = "Требуется восстановление"
        case .ownedByAnotherUser: state = "Сессия другого пользователя"
        case nil: state = "Нет подтверждённого состояния"
        }
        return """
        Боггарт \(appVersion)
        macOS: \(osVersion)
        Модель: \(model)
        Сборка: \(validationBuild ? "проверочная" : "обычная")
        Помощник: \(helperState)
        Состояние: \(state)
        Питание: \(sourceKnown ? (externalPower ? "внешнее" : "аккумулятор") : "не определено")
        История: \(historyWarning ? "ошибка локального хранения" : "без известных ошибок")
        Последнее завершение: \(lastReason?.description ?? "нет данных")
        Личные файлы, задачи и сетевые настройки не собираются.
        """
    }
}

public enum MaintenancePolicy {
    public static func mayDetach(_ status: ServiceStatus?, connected: Bool) -> Bool {
        // Даже незавершённая сессия другой учётной записи запрещает удаление.
        connected && status?.phase == .inactive
    }
    public static func isNewerBuild(_ proposed: String, than installed: String) -> Bool {
        guard [proposed, installed].allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") } }),
              proposed.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }),
              installed.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }) else { return false }
        return proposed.compare(installed, options: .numeric) == .orderedDescending
    }
}
