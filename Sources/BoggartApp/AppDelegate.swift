import AppKit
import Carbon
import BoggartCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model: AppModel
    override init() { model = AppModel(); super.init() }
#if BOGGART_UI_TESTING
    private var previewMode = false
    private var previewLogin = false
    init(previewModel: AppModel, atLogin: Bool) {
        model = previewModel
        previewMode = true; previewLogin = atLogin
        super.init()
    }
#endif
    private var controller: StatusItemController?
    private var duplicateInstance = false
    private var duplicatePresenter: DuplicateInstancePresenter?
    private var terminating = false
    private var workspaceObservers: [NSObjectProtocol] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        var skipExternalServices = false
#if BOGGART_UI_TESTING
        skipExternalServices = previewMode
#endif
        if !skipExternalServices {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: BoggartConstants.appID)
                .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
                duplicateInstance = true
                NSApp.setActivationPolicy(.accessory)
                let presenter = DuplicateInstancePresenter(existingURL: running.bundleURL)
                duplicatePresenter = presenter
                presenter.show()
                return
            }
        }
        NSApp.setActivationPolicy(.accessory)
        var itemName = "BoggartNativeStatusItem"
#if BOGGART_UI_TESTING
        if previewMode { itemName = "Boggart-Launch-Test-" + UUID().uuidString }
#endif
        let controller = StatusItemController(model: model, autosaveName: itemName); self.controller = controller
        model.onNeedsSetup = { [weak controller] in controller?.showSetup() }
        model.onNeedsPanel = { [weak controller] in controller?.showAfterUserCommand() }
        let menu = NSMenu()
        let root = NSMenuItem(); menu.addItem(root)
        let appMenu = NSMenu(); root.submenu = appMenu
        let open = NSMenuItem(title: "Открыть панель Боггарта", action: #selector(openPanel), keyEquivalent: "")
        open.target = self; appMenu.addItem(open)
        let settings = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self; appMenu.addItem(settings)
        let remove = NSMenuItem(title: "Удалить Боггарт…", action: #selector(removeApp), keyEquivalent: "")
        remove.target = self; appMenu.addItem(remove)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak controller] _ in
                controller?.dismiss()
            })
        }
        if !skipExternalServices { model.launch() }
        let event = NSAppleEventManager.shared().currentAppleEvent
        var atLogin = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
#if BOGGART_UI_TESTING
        if previewMode { atLogin = previewLogin }
#endif
        present(LaunchPresentation.initial(atLogin: atLogin,
            needsSetup: model.needsIntroduction || model.helperState != .enabled))
    }
    @objc private func removeApp() { model.offerRemoval() }
    @objc private func openPanel() { controller?.showControlWindow() }
    @objc private func openSettings() { controller?.showSettings() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if duplicateInstance { duplicatePresenter?.show(); return true }
        present(LaunchPresentation.reopen(needsSetup: model.needsIntroduction || model.helperState != .enabled))
        return true
    }
    private func present(_ destination: LaunchPresentation) {
        switch destination {
        case .setup: controller?.showSetup()
        case .controls: controller?.showControlWindow()
        case .background: break
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    @objc private func stopSession() { model.stop() }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let open = NSMenuItem(title: "Открыть Боггарт", action: #selector(openPanel), keyEquivalent: "")
        open.target = self; menu.addItem(open)
        let stop = NSMenuItem(title: "Остановить удержание", action: #selector(stopSession), keyEquivalent: "")
        stop.target = self; stop.isEnabled = model.active && !model.busy
        menu.addItem(stop)
        let settings = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self; menu.addItem(settings)
        return menu
    }
#if BOGGART_UI_TESTING
    func verifyLaunchForCI(to directory: URL, active: Bool) throws {
        applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let controller else { throw NSError(domain: "LaunchCI", code: 1) }
        if previewLogin {
            guard !controller.hasVisibleControlWindowForCI else { throw NSError(domain: "LoginCI", code: 2) }
            print("LOGIN_LAUNCH_NO_CONTROL_WINDOW")
        } else {
            try controller.verifyAlreadyVisibleControlWindowForCI(to: directory.appendingPathComponent("first-launch-\(active).png"))
            guard NSApp.activationPolicy() == .regular else { throw NSError(domain: "DockCI", code: 3) }
            print("FIRST_MANUAL_LAUNCH_VISIBLE_WITH_DOCK")
        }
        controller.dismiss()
        _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        try controller.verifyAlreadyVisibleControlWindowForCI(to: directory.appendingPathComponent("reopen-\(active)-\(previewLogin).png"))
        guard let stop = applicationDockMenu(NSApp)?.items.first(where: { $0.title == "Остановить удержание" }),
              stop.isEnabled == active else { throw NSError(domain: "DockStopCI", code: 4) }
        controller.dismiss()
        guard model.active == active else { throw NSError(domain: "CloseMustNotStopCI", code: 5) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        controller.retireForCI()
        self.controller = nil
        print("REOPEN_VISIBLE; DOCK_STOP_STATE_CORRECT; CLOSE_PRESERVES_SESSION")
    }
#endif
    func applicationDidBecomeActive(_ notification: Notification) {
        if !duplicateInstance { model.refreshSystemSettings() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if duplicateInstance { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { NSApp.reply(toApplicationShouldTerminate: false); return }
            self.model.prepareToQuit { [weak self] succeeded in
                self?.terminating = false
                NSApp.reply(toApplicationShouldTerminate: succeeded)
            }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        guard !duplicateInstance else { return }
        model.shutdown()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
}
