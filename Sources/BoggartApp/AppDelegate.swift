import AppKit
import BoggartCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var controller: StatusItemController?
    private var duplicateInstance = false
    private var duplicatePresenter: DuplicateInstancePresenter?
    private var terminating = false
    private var workspaceObservers: [NSObjectProtocol] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: BoggartConstants.appID)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            duplicateInstance = true
            NSApp.setActivationPolicy(.accessory)
            let presenter = DuplicateInstancePresenter(existingURL: running.bundleURL)
            duplicatePresenter = presenter
            presenter.show()
            return
        }
        NSApp.setActivationPolicy(.accessory)
        let controller = StatusItemController(model: model); self.controller = controller
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
        model.launch()
        if model.needsIntroduction || model.helperState != .enabled { controller.showSetup() }
    }
    @objc private func removeApp() { model.offerRemoval() }
    @objc private func openPanel() { controller?.showControlWindow() }
    @objc private func openSettings() { controller?.showSettings() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if duplicateInstance { duplicatePresenter?.show(); return true }
        if model.needsIntroduction || model.helperState != .enabled { controller?.showSetup() }
        else { controller?.showControlWindow() }
        return true
    }
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
