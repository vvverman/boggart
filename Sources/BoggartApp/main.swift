import AppKit
import Darwin
import BoggartPlatform

// Проверяется новая подписанная поставка до остановки работающей версии.
// Здесь нет NSApplication, регистрации служб, настроек или операций питания.
if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--validate-current-machine" {
    exit(HardwareValidation.currentCapability().available ? 0 : 69)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
withExtendedLifetime(delegate) {}
