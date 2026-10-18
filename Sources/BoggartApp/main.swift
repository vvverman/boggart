import AppKit
import Darwin
import BoggartPlatform

// Проверяется новая подписанная поставка до остановки работающей версии.
// Здесь нет NSApplication, регистрации служб, настроек или операций питания.
if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--validate-current-machine" {
    exit(HardwareValidation.currentCapability().available ? 0 : 69)
}

// Проверка готового пакета без регистрации службы и изменения сна.
if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--validate-bundle" {
    do {
        let result = try BundleValidation.inspect(Bundle.main.bundleURL)
        print("BUNDLE_VALID: \(result.version)")
        exit(0)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(65)
    }
}

#if BOGGART_UI_TESTING
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--capture-ui" {
    do { try UISnapshots.run(directory: URL(fileURLWithPath: CommandLine.arguments[2])); exit(0) }
    catch { fputs("UI capture: \(error)\n", stderr); exit(1) }
}
#endif

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
withExtendedLifetime(delegate) {}
