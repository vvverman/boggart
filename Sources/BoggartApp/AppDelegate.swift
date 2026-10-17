import AppKit
import BoggartCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var controller: StatusItemController?
    private var duplicateInstance = false
    private var terminating = false
    private var workspaceObservers: [NSObjectProtocol] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: BoggartConstants.appID)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            duplicateInstance = true
            NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.accessory)
        let controller = StatusItemController(model: model); self.controller = controller
        model.onNeedsPanel = { [weak controller] in controller?.showAfterUserCommand() }
        let menu = NSMenu()
        let root = NSMenuItem(); menu.addItem(root)
        let appMenu = NSMenu(); root.submenu = appMenu
        let open = NSMenuItem(title: "Открыть панель Боггарта", action: #selector(openPanel), keyEquivalent: "")
        open.target = self; appMenu.addItem(open)
        let settings = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self; appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Завершить Боггарт", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak controller] _ in
                controller?.dismiss() // Сон экранов не завершает сессию помощника.
            })
        }
        model.launch()
        if model.needsIntroduction { controller.showAfterUserCommand() }
    }
    @objc private func openPanel() { controller?.openKeyboard() }
    @objc private func openSettings() { controller?.showSettings() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.openKeyboard(); return true
    }
    func applicationDidBecomeActive(_ notification: Notification) { model.refreshSystemSettings() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if duplicateInstance { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        // Следующий проход run loop: reply(toApplicationShouldTerminate:) должен
        // выполняться только после возврата .terminateLater, даже без помощника.
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
        model.shutdown()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
}
