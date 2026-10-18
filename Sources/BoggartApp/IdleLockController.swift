import AppKit
import Combine
import CoreGraphics
import IOKit
import IOKit.pwr_mgt
import BoggartCore
import BoggartPlatform

/// Только непривилегированный процесс и временные IOKit assertions.
/// Никаких defaults write, изменения пароля, CGEvent или обхода ручной блокировки.
final class IdleLockController: ObservableObject {
    static let shared = IdleLockController()
    @Published private(set) var requested = false
    @Published private(set) var error: String?
    private weak var model: AppModel?
    private var subscription: AnyCancellable?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var displayID: IOPMAssertionID?
    private var activityID: IOPMAssertionID?
    private var activeSession: UUID?
    private var lastRenewal: TimeInterval = -.infinity
    private var displayAwake = true
    private var manuallyLocked = false

    private init() {}
    func attach(_ model: AppModel) {
        guard self.model !== model else { return }
        self.model = model
        #if !BOGGART_UI_TESTING
        subscription = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.reconcile() }
        }
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in
            self?.displayAwake = false; self?.cancel()
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in self?.displayAwake = true }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.cancel() }
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in self?.cancel() }
        observe(NotificationCenter.default, NSApplication.willTerminateNotification) { [weak self] in self?.cancel() }
        // Дополнительные наблюдения loginwindow. Отсутствие уведомления никогда
        // не используется как доказательство разблокированного экрана.
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, .init("com.apple.screenIsLocked")) { [weak self] in
            self?.manuallyLocked = true; self?.cancel()
        }
        observe(distributed, .init("com.apple.screenIsUnlocked")) { [weak self] in self?.manuallyLocked = false }
        #endif
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in action() }
        observers.append((center, token))
    }
    func setRequested(_ value: Bool) {
        guard model?.busy != true else { return }
        requested = value; error = nil
        #if !BOGGART_UI_TESTING
        if value {
            timer?.invalidate()
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.reconcile() }
            timer.tolerance = 0.25; RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
        reconcile()
        #endif
    }
    /// Вызывается ДО команды погашения; последующая активность не зажигает экран.
    func cancel() {
        requested = false; timer?.invalidate(); timer = nil
        release()
    }
    private func reconcile() {
        guard let model else { cancel(); return }
        let session = model.active ? model.status?.session?.id : nil
        if activeSession != nil && activeSession != session { cancel() }
        activeSession = session
        guard requested else { release(); return }
        let remaining = model.status?.session?.remaining(at: MacClock.continuous) ?? 0
        let console = CGSessionCopyCurrentDictionary() as? [String: Any]
        let unlocked = !manuallyLocked
            && console?[kCGSessionOnConsoleKey as String] as? Bool == true
            && console?[kCGSessionLoginDoneKey as String] as? Bool == true
            && console?["CGSSessionScreenIsLocked"] as? Bool != true
            && NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow"
        let lidClosed = Self.lidClosed()
        if !displayAwake || !unlocked || lidClosed { cancel(); return }
        let stopping = model.isQuitting || model.maintenanceBusy
            || model.pending.map { [CommandKind.stop, .quit, .recover, .sleepDisplays, .prepareMaintenance].contains($0) } == true
        guard IdleLockPolicy.shouldHold(requested: requested, active: model.active && !model.attention && !stopping,
            remaining: remaining, externalPower: model.localPower.known && model.localPower.external,
            unlockedConsole: unlocked, displayAwake: displayAwake, lidClosed: lidClosed) else {
            release(); return
        }
        guard displayID == nil || MacClock.continuous - lastRenewal >= 10 else { return }
        do {
            let timeout = IdleLockPolicy.timeout(remaining: remaining)
            if displayID == nil {
                let properties: [String: Any] = [
                    kIOPMAssertionTypeKey: kIOPMAssertionTypePreventUserIdleDisplaySleep,
                    kIOPMAssertionNameKey: "Боггарт: без автоблокировки",
                    kIOPMAssertionLevelKey: kIOPMAssertionLevelOn,
                    kIOPMAssertionTimeoutKey: timeout,
                    kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionTurnOff
                ]
                var id: IOPMAssertionID = 0
                try check(IOPMAssertionCreateWithProperties(properties as CFDictionary, &id))
                displayID = id
            } else if let id = displayID {
                try check(IOPMAssertionSetProperty(id, kIOPMAssertionTimeoutKey as CFString, NSNumber(value: timeout)))
                try check(IOPMAssertionSetProperty(id, kIOPMAssertionLevelKey as CFString, NSNumber(value: kIOPMAssertionLevelOn)))
            }
            var id = activityID ?? 0
            try check(IOPMAssertionDeclareUserActivity("Боггарт: без автоблокировки" as CFString, kIOPMUserActiveLocal, &id))
            activityID = id
            try check(IOPMAssertionSetProperty(id, kIOPMAssertionTimeoutKey as CFString, NSNumber(value: timeout)))
            lastRenewal = MacClock.continuous
        } catch {
            self.error = "Не удалось удержать экран: \(error.localizedDescription)"
            cancel()
        }
    }
    private func check(_ result: IOReturn) throws {
        guard result == kIOReturnSuccess else { throw BoggartError.message("IOKit: \(result).") }
    }
    private func release() {
        if let id = activityID {
            let code = IOPMAssertionRelease(id)
            if code == kIOReturnSuccess || code == kIOReturnNotFound { activityID = nil }
            else { error = "Не удалось снять активность экрана: \(code). Повторная попытка выполняется автоматически." }
        }
        if let id = displayID {
            let code = IOPMAssertionRelease(id)
            if code == kIOReturnSuccess || code == kIOReturnNotFound { displayID = nil }
            else { error = "Не удалось снять удержание дисплея: \(code). Повторная попытка выполняется автоматически." }
        }
        lastRenewal = -.infinity
    }
    private static func lidClosed() -> Bool {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard entry != 0 else { return true } // Неизвестное состояние — без активности.
        defer { IOObjectRelease(entry) }
        return IORegistryEntryCreateCFProperty(entry, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? false
    }
    deinit {
        timer?.invalidate()
        observers.forEach { $0.0.removeObserver($0.1) }
        if let id = activityID { IOPMAssertionRelease(id) }
        if let id = displayID { IOPMAssertionRelease(id) }
    }
}
