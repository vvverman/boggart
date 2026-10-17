import Foundation

public enum DurationText {
    // Для очень большого, но конечного продления нельзя допустить переполнение Int.
    private static func minutes(_ seconds: TimeInterval) -> Int? {
        guard seconds.isFinite, seconds >= 0, seconds / 60 < Double(Int.max / 2) else { return nil }
        return Int(ceil(seconds / 60))
    }
    public static func compact(_ seconds: TimeInterval?) -> String {
        guard let value = seconds, let total = minutes(value) else { return "—" }
        if value <= 0 { return "…" } // Не выдаём локальный ноль за подтверждённую остановку.
        if value < 60 { return "<1 мин" }
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
    public static func expanded(_ seconds: TimeInterval?) -> String {
        guard let value = seconds, let total = minutes(value) else { return "—" }
        if value <= 0 { return "ожидается подтверждение завершения" }
        if value < 60 { return "меньше минуты" }
        return total >= 60 ? "\(total / 60) ч \(total % 60) мин" : "\(total) мин"
    }
    public static func menu(active: Bool, countdown: Bool, selectedHours: Int, remaining: TimeInterval?) -> String {
        if !active { return "\(Preferences.hours(selectedHours)) ч" }
        return countdown ? compact(remaining) : ""
    }
}

public enum DateText {
    public static func ending(remaining: TimeInterval, now: Date, calendar: Calendar = .current) -> String {
        let end = now.addingTimeInterval(max(0, remaining))
        let time = DateFormatter(); time.locale = Locale(identifier: "ru_RU")
        time.timeZone = calendar.timeZone; time.dateFormat = "HH:mm"
        let day: String
        if calendar.isDate(end, inSameDayAs: now) { day = "сегодня" }
        else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(end, inSameDayAs: tomorrow) { day = "завтра" }
        else {
            let date = DateFormatter(); date.locale = Locale(identifier: "ru_RU"); date.timeZone = calendar.timeZone
            date.dateFormat = calendar.component(.year, from: end) == calendar.component(.year, from: now) ? "d MMMM" : "d MMMM yyyy"
            day = date.string(from: end)
        }
        return "Завершится \(day) в \(time.string(from: end))."
    }
}

/// Чистый автомат взаимодействия, без зависимости от AppKit.
public struct PanelInteraction {
    public enum Event {
        case enterAnchor, leaveAnchor, enterPanel, leavePanel, toggleClick, dismiss
        case openMouse, openKeyboard, beginEditing, endEditing, beginPointerAction, endPointerAction
    }
    public enum Effect: Equatable { case show, close }
    public private(set) var visible = false
    public private(set) var nextDeadline: TimeInterval?
    public private(set) var keyboard = false
    public private(set) var pinned = false
    private var insideAnchor = false
    private var insidePanel = false
    private var editing = false
    private var pointerAction = false
    private var suppress = false
    private var opening = false
    public init() {}
    public mutating func receive(_ event: Event, at now: TimeInterval) -> Effect? {
        switch event {
        case .enterAnchor:
            insideAnchor = true; nextDeadline = nil
            if !visible && !suppress { opening = true; nextDeadline = now + 0.300 }
        case .leaveAnchor:
            insideAnchor = false; suppress = false
            if !visible { nextDeadline = nil; opening = false } else { scheduleClose(now) }
        case .enterPanel: insidePanel = true; nextDeadline = nil
        case .leavePanel: insidePanel = false; scheduleClose(now)
        case .toggleClick: suppress = true; return close()
        case .dismiss: suppress = insideAnchor; return close()
        case .openMouse, .openKeyboard:
            keyboard = (event == .openKeyboard)
            visible = true; pinned = true; opening = false; nextDeadline = nil
            return .show
        case .beginEditing: editing = true; pinned = visible; nextDeadline = nil
        case .endEditing: editing = false; scheduleClose(now)
        case .beginPointerAction: pointerAction = true; pinned = visible; nextDeadline = nil
        case .endPointerAction: pointerAction = false; scheduleClose(now)
        }
        return nil
    }
    public mutating func advance(at now: TimeInterval) -> Effect? {
        guard let deadline = nextDeadline, now >= deadline else { return nil }
        nextDeadline = nil
        if opening {
            opening = false
            guard insideAnchor, !visible, !suppress else { return nil }
            visible = true; return .show
        }
        guard visible, !insideAnchor, !insidePanel, !editing, !pointerAction, !pinned else { return nil }
        return close()
    }
    private mutating func scheduleClose(_ now: TimeInterval) {
        guard visible, !insideAnchor, !insidePanel, !editing, !pointerAction, !pinned else { return }
        opening = false; nextDeadline = now + 0.250
    }
    private mutating func close() -> Effect? {
        let old = visible
        visible = false; keyboard = false; pinned = false; editing = false; pointerAction = false
        insidePanel = false; nextDeadline = nil; opening = false
        return old ? .close : nil
    }
}
extension PanelInteraction.Event: Equatable {}

public enum HistoryPolicy {
    public static func appending(_ record: SessionRecord, to records: [SessionRecord]) -> [SessionRecord] {
        // Порядок завершения, а не сортировка по wall clock: часы могли перевести назад.
        let others = records.filter { $0.id != record.id }
        return Array(([record] + others).prefix(5))
    }
}
