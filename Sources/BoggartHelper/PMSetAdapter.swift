import Foundation
import Darwin
import IOKit
import IOKit.pwr_mgt
import BoggartCore
import BoggartPlatform

/// Единственный адаптер закрытой крышки. Нет запасного режима «только assertion».
final class PMSetAdapter: SleepBackend {
    private var assertionID: IOPMAssertionID?
    private let configuration = HardwareValidation.currentCapability()
    func clock() -> ClockReading { MacClock.reading }
    func power() -> PowerSnapshot { MacPower.snapshot() }
    func criticalThermal() -> Bool { ProcessInfo.processInfo.thermalState == .critical }
    func capability() -> Capability { configuration }
    func sleepDisabled() throws -> Bool { try PMSetParser.sleepSetting(from: run(.read)) == .disabled }
    func setSleepDisabled(_ disabled: Bool) throws {
        _ = try run(disabled ? .disableSleep : .restoreSleep)
        guard try sleepDisabled() == disabled else {
            throw BoggartError.message("macOS не подтвердила изменение SleepDisabled.")
        }
    }
    func acquireIdleAssertion() throws {
        guard assertionID == nil else { throw BoggartError.message("IOKit-удержание уже существует.") }
        var id: IOPMAssertionID = 0
        let code = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn), "Боггарт: длительная задача" as CFString, &id)
        guard code == kIOReturnSuccess else { throw BoggartError.message("Не удалось создать удержание IOKit: \(code).") }
        assertionID = id
    }
    func releaseIdleAssertion() throws {
        guard let id = assertionID else { return }
        let code = IOPMAssertionRelease(id)
        guard code == kIOReturnSuccess else { throw BoggartError.message("Не удалось снять удержание IOKit: \(code).") }
        assertionID = nil
    }
    func sleepDisplays() throws { _ = try run(.sleepDisplays) }

    private enum Operation {
        case read, disableSleep, restoreSleep, sleepDisplays
        var arguments: [String] {
            switch self {
            case .read: return ["-g"]
            case .disableSleep: return ["-a", "disablesleep", "1"]
            case .restoreSleep: return ["-a", "disablesleep", "0"]
            case .sleepDisplays: return ["displaysleepnow"]
            }
        }
    }
    private func run(_ operation: Operation) throws -> String {
        let process = Process(), pipe = Pipe(), finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = operation.arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = pipe
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        try? pipe.fileHandleForWriting.close()
        let output = LockedOutput()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            defer { drained.signal() }
            while true {
                let part = pipe.fileHandleForReading.availableData
                if part.isEmpty { break }
                output.append(part)
            }
        }
        if finished.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            throw BoggartError.message("pmset не ответил вовремя. Снятие удержания требует проверки.")
        }
        guard drained.wait(timeout: .now() + 1) == .success else { throw BoggartError.message("Не получен полный ответ pmset.") }
        let (data, overflow) = output.result
        let text = String(decoding: data, as: UTF8.self)
        guard !overflow, process.terminationStatus == 0 else {
            throw BoggartError.message("Ошибка pmset (\(process.terminationStatus)): \(text.prefix(500))")
        }
        return text
    }
}
private final class LockedOutput {
    private let lock = NSLock()
    private var data = Data()
    private var overflow = false
    func append(_ part: Data) {
        lock.lock(); defer { lock.unlock() }
        let room = max(0, 65536 - data.count)
        data.append(part.prefix(room)); overflow = overflow || part.count > room
    }
    var result: (Data, Bool) { lock.lock(); defer { lock.unlock() }; return (data, overflow) }
}
