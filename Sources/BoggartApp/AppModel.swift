import AppKit
import Combine
import ServiceManagement
import BoggartCore
import BoggartPlatform

final class AppModel: ObservableObject {
    @Published private(set) var status: ServiceStatus?
    @Published private(set) var connected = false
    @Published private(set) var pending: CommandKind?
    @Published private(set) var uncertain = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedHours: Int
    @Published var showRemaining: Bool { didSet { defaults.set(showRemaining, forKey: "showRemaining.v3") } }
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginApprovalRequired = false
    @Published private(set) var helperState: SMAppService.Status = .notRegistered
    @Published private(set) var settingsBusy = false
    @Published private(set) var history: [SessionRecord] = []
    @Published private(set) var continuous = MacClock.continuous
    @Published private(set) var localPower = MacPower.snapshot()
    @Published private(set) var isQuitting = false
    @Published private(set) var introductionCompleted: Bool
    @Published private(set) var setupBlocker: String?
    @Published private(set) var maintenanceBusy = false
    @Published var maintenanceOffer: MaintenanceOffer?
    @Published private(set) var maintenanceMessage: String?
    private var maintenanceCommitted = false
    private var restoreLoginOnFailure = false
    private var restoreHelperOnFailure = false
    var onNeedsPanel: (() -> Void)?
    private let defaults: UserDefaults
    private let client = ServiceClient()
    private let notifier = NotificationManager()
    private let helper = SMAppService.daemon(plistName: BoggartConstants.daemonPlist)
    private var heartbeatTimer: Timer?
    private var displayTimer: Timer?
    private var activity: NSObjectProtocol?
    private var connectionMessage = "Проверяется состояние помощника…"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        introductionCompleted = defaults.bool(forKey: "introductionCompleted.v4")
        selectedHours = Preferences.hours(defaults.object(forKey: "selectedHours") as? Int)
        showRemaining = Preferences.countdown(newValue: defaults.object(forKey: "showRemaining.v3") as? Bool,
                                               legacyMode: defaults.string(forKey: "displayMode"))
        if let data = defaults.data(forKey: "history.v3"), let entries = try? JSONDecoder().decode([SessionRecord].self, from: data) {
            history = Array(entries.prefix(5))
        }
        client.onReply = { [weak self] in self?.receive($0) }
        client.onUnavailable = { [weak self] text in
            guard let self else { return }
            if self.status?.phase == .active || self.status?.phase == .recoveryRequired || self.pending != nil { self.uncertain = true }
            self.connected = false; self.connectionMessage = text
        }
    }
    func launch() {
        refreshSystemSettings()
        setupBlocker = BundleValidation.setupBlocker()
        resumeAfterUpdateIfNeeded()
        heartbeatTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.localPower = MacPower.snapshot()
            self.refreshSystemSettings()
            // Подготовка файла обновления не прерывает heartbeat текущей сессии.
            // После подтверждённого unregister опрос прекращается по состоянию службы.
            if self.helperState == .enabled && !self.isQuitting { self.client.heartbeat() }
        }
        displayTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.continuous = MacClock.continuous }
        if let heartbeatTimer { RunLoop.main.add(heartbeatTimer, forMode: .common) }
        if let displayTimer { RunLoop.main.add(displayTimer, forMode: .common) }
        if helperState == .enabled { client.heartbeat() }
    }
    var active: Bool { connected && status?.phase == .active }
    var recoveryRequired: Bool { status?.phase == .recoveryRequired }
    var attention: Bool { uncertain || recoveryRequired }
    var checkingStatus: Bool { helperState == .enabled && !connected && !attention }
    var busy: Bool { pending != nil || isQuitting || settingsBusy || maintenanceBusy }
    var remaining: TimeInterval? { active ? status?.session?.remaining(at: continuous) : nil }
    var awaitingExpiryConfirmation: Bool { active && (remaining ?? 0) <= 0 }
    var canExtend: Bool { active && !busy && (remaining ?? 0) > 0 && !attention }
    var canSleepDisplays: Bool { active && !busy && !attention && (remaining ?? 0) > 0 }
    var powerGraceSeconds: Int? {
        guard active, let deadline = status?.session?.powerGraceDeadline else { return nil }
        return max(0, Int(ceil(deadline - continuous)))
    }
    var menuText: String {
        if attention || checkingStatus { return "" }
        return DurationText.menu(active: active, countdown: showRemaining, selectedHours: selectedHours, remaining: remaining)
    }
    var stateTitle: String {
        if maintenanceBusy { return "Подготовка приложения…" }
        if isQuitting { return "Завершаю удержание перед выходом…" }
        if let pending {
            switch pending {
            case .start: return "Включаю удержание…"
            case .stop, .quit, .recover: return "Снимаю удержание…"
            case .extendOneHour: return "Продлеваю на час…"
            case .sleepDisplays: return "Гашу экраны…"
            case .heartbeat: return "Проверяю состояние…"
            case .prepareMaintenance, .cancelMaintenance: return "Подготавливаю приложение…"
            }
        }
        if uncertain { return "Состояние удержания неизвестно" }
        if recoveryRequired { return "Не удалось снять удержание" }
        if active { return (remaining ?? 0) > 0 ? "Удержание включено" : "Ожидается подтверждение завершения…" }
        if status?.phase == .ownedByAnotherUser { return "Удержанием управляет другой пользователь" }
        if !connected && helperState == .enabled { return "Проверяю состояние удержания…" }
        return "Удержание выключено"
    }
    var blockedReason: String? {
        if attention { return connected ? "Сначала восстановите удержание." : connectionMessage }
        if !localPower.known { return "Не удалось определить источник питания. Удержание пока недоступно." }
        if !localPower.external { return "Подключите питание, чтобы включить удержание." }
        if helperState != .enabled { return "Для работы нужен системный помощник." }
        if !connected { return connectionMessage }
        if status?.phase == .ownedByAnotherUser { return status?.message }
        if status?.maintenancePending == true { return "Идёт обслуживание Боггарта. Удержание выключено." }
        if let capability = status?.capability, !capability.available { return capability.message }
        return nil
    }
    var endingText: String {
        let seconds = active ? remaining ?? 0 : Double(selectedHours * 3600)
        return DateText.ending(remaining: seconds, now: Date())
    }
    var helperDescription: String {
        switch helperState {
        case .enabled: return connected ? "Подключён · \(status?.helperVersion ?? BoggartConstants.version)" : connectionMessage
        case .requiresApproval: return "Разрешите помощник в системных настройках входа и расширений."
        case .notRegistered: return "Не настроен"
        case .notFound: return "Файлы помощника не найдены. Требуется повторная сборка приложения."
        @unknown default: return "Неизвестное состояние помощника"
        }
    }
    var accessibilityValue: String {
        if attention { return "\(stateTitle). Откройте панель для проверки." }
        if checkingStatus { return "Проверяю состояние удержания. Дождитесь подтверждения помощника." }
        if needsIntroduction { return "Боггарт не подготовлен. Нажатие открывает первоначальную настройку." }
        if status?.phase == .ownedByAnotherUser { return stateTitle }
        if active { return "Удержание включено. Осталось \(DurationText.expanded(remaining)). Нажатие останавливает сессию." }
        return "Удержание выключено. Нажатие включает на \(selectedHours) часов."
    }
    func selectHours(_ value: Int) {
        guard !active else { return }
        selectedHours = min(24, max(1, value)); defaults.set(selectedHours, forKey: "selectedHours")
    }
    func toggle() {
        guard !busy else { return }
        if needsIntroduction { onNeedsPanel?(); return }
        if recoveryRequired && connected { perform(.init(.recover)); return }
        if active { stop(); return }
        guard blockedReason == nil else {
            errorMessage = blockedReason; onNeedsPanel?(); return
        }
        perform(.init(.start, hours: selectedHours))
    }
    func stop() {
        guard !busy, connected else { return }
        if recoveryRequired { perform(.init(.recover)); return }
        guard let id = status?.session?.id else { return }
        perform(.init(.stop, sessionID: id))
    }
    func extend() {
        guard canExtend, let id = status?.session?.id else { return }
        perform(.init(.extendOneHour, sessionID: id))
    }
    /// Вызывается после mouseUp и закрытия панели. За время задержки сессия могла
    /// измениться, поэтому помощник перепроверяет её UUID и собственный дедлайн.
    func sleepDisplaysAfterClosingPanel() {
        guard canSleepDisplays, let id = status?.session?.id else { return }
        pending = .sleepDisplays
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isQuitting else { return }
            self.send(.init(.sleepDisplays, sessionID: id))
        }
    }
    private func perform(_ command: ServiceCommand) {
        guard !busy else { return }
        if command.kind == .start { defaults.set(true, forKey: "sessionNeedsConfirmation.v4") }
        pending = command.kind; errorMessage = nil; send(command)
    }
    private func send(_ command: ServiceCommand) {
        client.send(command) { [weak self] reply in
            guard let self else { return }
            self.pending = nil
            if let error = reply?.error { self.errorMessage = error; self.onNeedsPanel?() }
            if reply == nil {
                self.uncertain = true
                self.errorMessage = "Помощник не подтвердил команду. Нельзя считать удержание выключенным."
                self.onNeedsPanel?()
            }
        }
    }
    private func receive(_ reply: ServiceReply) {
        continuous = MacClock.continuous; status = reply.status; connected = true; uncertain = false
        defaults.set(reply.status.phase != .inactive, forKey: "sessionNeedsConfirmation.v4")
        cleanUpdateBackupAfterConfirmation()
        if reply.status.historyWarning != nil {
            let ids = Set(reply.status.history.map(\.id))
            history = Array((reply.status.history + history.filter { !ids.contains($0.id) }).prefix(5))
        } else { history = Array(reply.status.history.prefix(5)) }
        if let encoded = try? JSONEncoder().encode(history) { defaults.set(encoded, forKey: "history.v3") }
        notifier.receive(reply.status)
        let needsActivity = reply.status.phase == .active || reply.status.phase == .recoveryRequired
        if needsActivity && activity == nil {
            // Исключает App Nap для watchdog-связи, не удерживает дисплеи и idle sleep.
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .automaticTerminationDisabled],
                                                              reason: "Связь с системным помощником Боггарта")
        } else if !needsActivity, let activity {
            ProcessInfo.processInfo.endActivity(activity); self.activity = nil
        }
    }
    func refreshSystemSettings() {
        helperState = helper.status
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginApprovalRequired = SMAppService.mainApp.status == .requiresApproval
    }
    /// Только явная кнопка. Ни hover, ни опрос состояния не вызывают register().
    func configureHelper() {
        guard !busy else { return }
        setupBlocker = BundleValidation.setupBlocker()
        guard setupBlocker == nil else { errorMessage = setupBlocker; return }
        settingsBusy = true; errorMessage = nil
        defer { settingsBusy = false }
        do {
            if helper.status != .enabled { try helper.register() }
            defaults.set(true, forKey: "helperEverConfigured.v4")
            refreshSystemSettings()
            if helperState == .enabled { client.heartbeat() }
            if helperState == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            notifier.requestAfterExplicitSetup()
        } catch {
            refreshSystemSettings(); errorMessage = "Помощник не настроен. \(error.localizedDescription)"
        }
        // Авторизация помощника никогда сама по себе не включает удержание.
    }
    func setLoginEnabled(_ enabled: Bool) {
        guard !busy else { return }
        settingsBusy = true; defer { settingsBusy = false }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { errorMessage = "Не удалось изменить автозапуск. \(error.localizedDescription)" }
        refreshSystemSettings()
    }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
    func clearError() { errorMessage = nil }

    /// Перед штатным выходом всегда сверяем состояние. Нет тайм-аута, который
    /// принудительно прячет значок после неудачного выключения.
    func prepareToQuit(completion: @escaping (Bool) -> Void) {
        if maintenanceCommitted { completion(true); return }
        guard !busy else { completion(false); return }
        refreshSystemSettings()
        if helperState != .enabled && !attention && status?.phase != .active { completion(true); return }
        isQuitting = true
        client.send(.init(.heartbeat)) { [weak self] reply in
            guard let self else { completion(false); return }
            guard let reply else { self.quitFailed(completion); return }
            if reply.status.phase == .inactive || reply.status.phase == .ownedByAnotherUser {
                self.isQuitting = false; completion(true); return
            }
            let command: ServiceCommand
            if reply.status.phase == .recoveryRequired { command = .init(.recover) }
            else { command = .init(.quit, sessionID: reply.status.session?.id) }
            self.client.send(command) { [weak self] result in
                guard let self else { completion(false); return }
                guard let result, result.error == nil, result.status.phase == .inactive else { self.quitFailed(completion); return }
                self.isQuitting = false; completion(true)
            }
        }
    }
    private func quitFailed(_ completion: (Bool) -> Void) {
        isQuitting = false; errorMessage = "Выход отменён: снятие удержания не подтверждено. Проверьте помощник и повторите восстановление."
        onNeedsPanel?(); completion(false)
    }
    var needsIntroduction: Bool { !introductionCompleted && !active && !attention }
    var setupReady: Bool { connected && status?.phase == .inactive && status?.capability.available == true }
    var lastAbnormalSummary: String? {
        guard connected, let record = RecentSessionText.abnormalRecord(history, phase: status?.phase) else { return nil }
        return RecentSessionText.summary(record)
    }
    func completeIntroduction() {
        guard setupReady, !busy else { return }
        introductionCompleted = true
        defaults.set(true, forKey: "introductionCompleted.v4")
        errorMessage = nil
        // Закрытие введения никогда не вызывает start.
    }
    func copyDiagnostics() {
        let rawState: String
        switch helperState {
        case .enabled: rawState = connected ? "подключён" : "ожидается связь"
        case .notRegistered: rawState = "не настроен"
        case .requiresApproval: rawState = "требуется разрешение"
        case .notFound: rawState = "файлы не найдены"
        @unknown default: rawState = "неизвестно"
        }
        let report = DiagnosticReport(appVersion: BoggartConstants.version,
            osVersion: "\(ProcessInfo.processInfo.operatingSystemVersionString) (\(HardwareValidation.osBuild))",
            model: HardwareValidation.machineModel, helperState: rawState,
            phase: connected ? status?.phase : nil, sourceKnown: localPower.known,
            externalPower: localPower.external, validationBuild: BoggartConstants.hardwareTesting,
            historyWarning: status?.historyWarning != nil, lastReason: history.first?.reason)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.text, forType: .string)
    }

    func shutdown() {
        heartbeatTimer?.invalidate(); displayTimer?.invalidate(); client.invalidate()
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
}

extension AppModel {
    func offerRemoval() {
        guard !busy else { return }
        maintenanceMessage = nil
        maintenanceOffer = .init(kind: .removal)
    }
    func offerUpdate(_ result: Result<URL, Error>) {
        guard !busy else { return }
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let bundle = try BundleValidation.inspect(url, requireNewer: true)
            maintenanceMessage = nil
            maintenanceOffer = .init(kind: .update(url, bundle.version))
        } catch {
            let error = error as NSError
            if error.domain != NSCocoaErrorDomain || error.code != NSUserCancelledError {
                errorMessage = error.localizedDescription
            }
        }
    }
    func runMaintenance() {
        guard !busy, let offer = maintenanceOffer else { return }
        guard Bundle.main.bundleURL.standardizedFileURL == BundleValidation.installedURL else {
            maintenanceMessage = "Откройте установленный Боггарт из папки «Программы»."; return
        }
        maintenanceBusy = true; maintenanceMessage = "Проверяю поставку…"
        restoreLoginOnFailure = SMAppService.mainApp.status == .enabled
        restoreHelperOnFailure = helper.status == .enabled
        switch offer.kind {
        case .update(let url, _):
            // Подготовка файла до остановки: отказ доступа не обрывает текущую задачу.
            BundleMaintenance.stage(url) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let staged): self.prepareMaintenance { error in
                    if let error { self.maintenanceFailed(error); return }
                    self.installStaged(staged)
                }
                case .failure(let error): self.maintenanceBusy = false; self.maintenanceMessage = error.localizedDescription
                }
            }
        case .removal:
            prepareMaintenance { [weak self] error in
                guard let self else { return }
                if let error { self.maintenanceFailed(error); return }
                self.maintenanceMessage = "Перемещаю приложение в Корзину…"
                BundleMaintenance.recycleCurrentApp { [weak self] error in
                    guard let self else { return }
                    if let error { self.maintenanceFailed(error); return }
                    self.finishMaintenanceAndQuit()
                }
            }
        }
    }
    private func prepareMaintenance(completion: @escaping (Error?) -> Void) {
        maintenanceMessage = "Проверяю и снимаю удержание…"
        // До первой регистрации у новой установки удержаний быть не может.
        if helper.status == .notRegistered, !defaults.bool(forKey: "helperEverConfigured.v4"),
           !defaults.bool(forKey: "sessionNeedsConfirmation.v4"), status == nil {
            detachServices(completion: completion); return
        }
        client.send(.init(.heartbeat)) { [weak self] reply in
            guard let self else { return }
            guard let reply else {
                completion(BoggartError.message("Нет подтверждения помощника. Удаление или обновление отменено; сначала восстановите связь.")); return
            }
            if reply.status.phase == .ownedByAnotherUser {
                completion(BoggartError.message("Другой пользователь удерживает этот Mac. Его сессия не будет остановлена.")); return
            }
            self.client.send(.init(.prepareMaintenance)) { [weak self] stopped in
                guard let self else { return }
                guard let stopped, stopped.error == nil, MaintenancePolicy.mayDetach(stopped.status, connected: true),
                      stopped.status.maintenancePending == true else {
                    completion(BoggartError.message("Снятие удержания не подтверждено. Файлы и помощник не удалены.")); return
                }
                self.detachServices(completion: completion)
            }
        }
    }
    private func detachServices(completion: @escaping (Error?) -> Void) {
        maintenanceMessage = "Подготавливаю системные службы…"
        do {
            let login = SMAppService.mainApp.status
            if login == .enabled || login == .requiresApproval { try SMAppService.mainApp.unregister() }
        } catch { completion(error); return }
        if helper.status == .notRegistered {
            refreshSystemSettings(); completion(nil); return
        }
        helper.unregister { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshSystemSettings()
                if let error { completion(error); return }
                guard self.helperState == .notRegistered else {
                    completion(BoggartError.message("macOS не подтвердила отключение помощника. Файлы не заменены.")); return
                }
                self.connected = false
                completion(nil)
            }
        }
    }
    private func installStaged(_ staged: StagedUpdate) {
        do {
            maintenanceMessage = "Устанавливаю обновление…"
            try staged.commit()
            defaults.set(restoreLoginOnFailure, forKey: "restoreLoginAfterUpdate.v4")
            defaults.set(restoreHelperOnFailure, forKey: "restoreHelperAfterUpdate.v4")
            defaults.set(staged.backupRoot.path, forKey: "updateBackup.v4")
            do { try BundleMaintenance.relaunchAfterExit() }
            catch {
                try staged.rollback()
                defaults.removeObject(forKey: "updateBackup.v4")
                defaults.removeObject(forKey: "restoreLoginAfterUpdate.v4")
                defaults.removeObject(forKey: "restoreHelperAfterUpdate.v4")
                throw error
            }
            finishMaintenanceAndQuit()
        } catch { maintenanceFailed(error) }
    }
    private func maintenanceFailed(_ error: Error) {
        var text = "Операция не завершена. \(error.localizedDescription)"
        // Возвращаем возможность работы, но никогда не возобновляем сессию.
        if restoreHelperOnFailure && helper.status == .notRegistered {
            do { try helper.register() }
            catch { text += " Для помощника потребуется повторная настройка." }
        }
        if restoreLoginOnFailure && SMAppService.mainApp.status == .notRegistered {
            do { try SMAppService.mainApp.register() }
            catch { text += " Автозапуск не восстановлен." }
        }
        refreshSystemSettings(); maintenanceBusy = false; maintenanceMessage = text
        if helperState == .enabled {
            client.send(.init(.cancelMaintenance)) { [weak self] _ in self?.client.heartbeat() }
        }
    }
    private func finishMaintenanceAndQuit() {
        maintenanceCommitted = true; maintenanceBusy = false
        maintenanceOffer = nil
        NSApp.terminate(nil)
    }
    private func resumeAfterUpdateIfNeeded() {
        let restoreHelper = defaults.bool(forKey: "restoreHelperAfterUpdate.v4")
        let restoreLogin = defaults.bool(forKey: "restoreLoginAfterUpdate.v4")
        defaults.removeObject(forKey: "restoreHelperAfterUpdate.v4")
        defaults.removeObject(forKey: "restoreLoginAfterUpdate.v4")
        if restoreHelper { configureHelper() }
        if restoreLogin { setLoginEnabled(true) }
        // Ни одна из ветвей не начинает сессию.
    }
    private func cleanUpdateBackupAfterConfirmation() {
        guard connected, status?.phase == .inactive, let path = defaults.string(forKey: "updateBackup.v4") else { return }
        do {
            try BundleMaintenance.removeVerifiedBackup(path)
            defaults.removeObject(forKey: "updateBackup.v4")
        } catch {
            // Резервная копия остаётся, но это не неисправность удержания.
        }
    }
}
