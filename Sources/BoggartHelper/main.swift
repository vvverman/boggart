import Foundation
import Darwin
import BoggartCore
import BoggartPlatform

// Нет режима произвольного root-запуска и нет CLI-команд изменения pmset.
guard CommandLine.arguments.count == 1, geteuid() == 0 else {
    fputs("Помощник запускается только через SMAppService.\n", stderr)
    exit(64)
}
do {
    let requirement = try ClientAuthentication.requirement(for: BoggartConstants.appID)
    let runtime = try HelperRuntime()
    let listener = NSXPCListener(machServiceName: BoggartConstants.serviceID)
    listener.setConnectionCodeSigningRequirement(requirement)
    let delegate = ServiceDelegate(runtime: runtime)
    listener.delegate = delegate
    runtime.launch()
    listener.resume()
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: runtime.queue)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: runtime.queue)
    let stop = { runtime.controller.shutdown(); exit(0) }
    termination.setEventHandler(handler: stop); interrupt.setEventHandler(handler: stop)
    termination.resume(); interrupt.resume()
    withExtendedLifetime((runtime, listener, delegate, termination, interrupt)) { RunLoop.main.run() }
} catch {
    NSLog("Боггарт: помощник не запущен: %@", error.localizedDescription)
    exit(1)
}
