import Foundation

/// Удержание автоматической блокировки не меняет пароль, не разблокирует экран
/// и не действует при погашенных дисплеях или закрытой крышке.
public enum IdleLockPolicy {
    public static func shouldHold(requested: Bool, active: Bool, remaining: TimeInterval,
                                  externalPower: Bool, unlockedConsole: Bool,
                                  displayAwake: Bool, lidClosed: Bool) -> Bool {
        requested && active && remaining.isFinite && remaining > 0
            && externalPower && unlockedConsole && displayAwake && !lidClosed
    }
    /// Ограниченная системная аренда защищает от зависания интерфейса.
    public static func timeout(remaining: TimeInterval) -> TimeInterval {
        guard remaining.isFinite, remaining > 0 else { return 0 }
        return min(25, remaining)
    }
}
