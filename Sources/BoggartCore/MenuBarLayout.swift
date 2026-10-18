import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Геометрия только нашего значка. Не переставляет чужие элементы строки меню.
public enum MenuBarLayout {
    public static func contains(_ frame: CGRect?, in area: CGRect?) -> Bool {
        guard let frame, let area, valid(frame), valid(area) else { return false }
        return frame.minX >= area.minX && frame.maxX <= area.maxX &&
            frame.minY >= area.minY && frame.maxY <= area.maxY
    }

    /// Строка меню растёт влево от правого края значка. При восстановлении
    /// подписи оставляем запас, чтобы смена состояния не вызывала мерцания.
    public static func needsCompact(frame: CGRect?, area: CGRect?, expandedWidth: CGFloat,
                                    wasCompact: Bool) -> Bool {
        guard let frame, let area, valid(frame), valid(area),
              expandedWidth.isFinite, expandedWidth > 0 else { return true }
        let reserve: CGFloat = wasCompact ? 12 : 0
        let proposed = CGRect(x: frame.maxX - expandedWidth - reserve, y: frame.minY,
                              width: expandedWidth + reserve, height: frame.height)
        return !contains(proposed, in: area)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }
}
