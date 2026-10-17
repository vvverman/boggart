import Foundation
import IOKit.ps
import BoggartCore

public enum MacPower {
    public static func snapshot() -> PowerSnapshot {
        guard let reference = IOPSCopyPowerSourcesInfo() else { return .unknown }
        let info = reference.takeRetainedValue()
        guard let source = IOPSGetProvidingPowerSourceType(info) else { return .unknown }
        let type = source.takeUnretainedValue() as String
        guard type == kIOPSACPowerValue || type == kIOPSBatteryPowerValue else { return .unknown }
        var percent: Int?
        if let list = IOPSCopyPowerSourcesList(info) {
            for item in list.takeRetainedValue() as [CFTypeRef] {
                guard let ref = IOPSGetPowerSourceDescription(info, item),
                      let description = ref.takeUnretainedValue() as? [String: Any],
                      description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let current = description[kIOPSCurrentCapacityKey] as? Int,
                      let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
                percent = Int((Double(current) / Double(maximum) * 100).rounded())
                break
            }
        }
        // IsCharging намеренно не читается: при полном заряде питание всё ещё внешнее.
        return .init(external: type == kIOPSACPowerValue, batteryPercent: percent)
    }
}
