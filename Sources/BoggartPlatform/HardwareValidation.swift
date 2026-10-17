import Foundation
import Darwin
import BoggartCore

/// Записи добавляются только после подписанного протокола аппаратной проверки.
/// Наличие команды pmset или успешный IOPMAssertion НЕ добавляет конфигурацию.
public enum HardwareValidation {
    public struct ApprovedMachine {
        let model: String
        let osBuild: String
        let testReport: String
    }
    public static let approved: [ApprovedMachine] = []
    public static func currentCapability() -> Capability {
        let model = sysctlString("hw.model")
        let build = sysctlString("kern.osversion")
        #if BOGGART_HARDWARE_TESTING
        return .init(available: true, validationBuild: true,
            message: "Проверочная сборка. Закрытая крышка ещё не подтверждена: \(model), macOS \(build). Не оставляйте без наблюдения до проверки.")
        #else
        if approved.contains(where: { $0.model == model && $0.osBuild == build && !$0.testReport.isEmpty }) {
            return .init(available: true, message: "Конфигурация прошла аппаратную проверку.")
        }
        return .init(available: false,
            message: "Работа с закрытой крышкой на \(model), macOS \(build) не проверена. Эта сборка не включает удержание на неподтверждённой конфигурации.")
        #endif
    }
    public static var machineModel: String { sysctlString("hw.model") }
    public static var osBuild: String { sysctlString("kern.osversion") }
    private static func sysctlString(_ name: String) -> String {
        var count = 0
        guard sysctlbyname(name, nil, &count, nil, 0) == 0, count > 0, count < 4096 else { return "неизвестно" }
        var buffer = [CChar](repeating: 0, count: count)
        guard sysctlbyname(name, &buffer, &count, nil, 0) == 0 else { return "неизвестно" }
        return String(cString: buffer)
    }
}
