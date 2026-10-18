import Foundation

/// Открытие приложения — пользовательская команда показать управление, а не
/// просто завести ещё один значок. Автозапуск не начинает сессию и не крадёт фокус.
public enum LaunchPresentation: Equatable {
    case setup, controls, background

    public static func initial(atLogin: Bool, needsSetup: Bool) -> Self {
        if atLogin { return .background }
        return needsSetup ? .setup : .controls
    }

    public static func reopen(needsSetup: Bool) -> Self {
        needsSetup ? .setup : .controls
    }
}

/// Если строка меню потеряла значок, Dock остаётся запасным входом до выхода
/// из процесса. Не переключаем политику туда-сюда при перерисовке строки меню.
public struct AccessPresentation {
    public private(set) var dockFallback = false
    private var unavailableSince: TimeInterval?

    public init() {}

    public mutating func observeMenuItem(available: Bool, at time: TimeInterval) {
        guard time.isFinite else { return }
        if available { unavailableSince = nil; return }
        if unavailableSince == nil { unavailableSince = time }
        if time - (unavailableSince ?? time) >= 1 { dockFallback = true }
    }

    public func needsDock(hasWindow: Bool) -> Bool { hasWindow || dockFallback }
}
