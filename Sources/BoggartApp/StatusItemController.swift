import AppKit
import SwiftUI
import Combine
import BoggartCore
import BoggartPlatform

/// AppKit отвечает только за системное размещение и события. Системный popover
/// привязывается только к доступной кнопке. При вырезе или переполнении
/// управление открывается в обычном временном окне с тем же SwiftUI-содержимым.
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var compact = true
    private var access = AccessPresentation()
    private var refreshQueued = false
    private var retired = false
    private var accessTimer: Timer?
    private var closedWindows = Set<ObjectIdentifier>()
    private var controlWindow: NSWindowController?
    private var host: NSHostingController<ControlPanelView>?
    private var tracking: NSTrackingArea?
    private var interaction = PanelInteraction()
    private var delayed: DispatchWorkItem?
    private var subscription: AnyCancellable?
    private var maintenanceSubscription: AnyCancellable?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var settingsWindow: NSWindowController?
    private var setupWindow: NSWindowController?
    private var maintenanceWindow: NSWindowController?
    private var observers: [NSObjectProtocol] = []

    init(model: AppModel, autosaveName: String = "BoggartNativeStatusItem") {
        self.model = model
        super.init()
        IdleLockController.shared.attach(model)
        item.autosaveName = autosaveName
        item.behavior = []
        item.isVisible = true
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        let content = ControlPanelView(model: model,
            openSettings: { [weak self] in self?.showSettings() },
            openSetup: { [weak self] in self?.showSetup() },
            dismiss: { [weak self] in self?.send(.dismiss) },
            quit: { NSApp.terminate(nil) },
            hover: { [weak self] in self?.send($0 ? .enterPanel : .leavePanel) },
            editing: { [weak self] in self?.send($0 ? .beginEditing : .endEditing) })
        let host = NSHostingController(rootView: content)
        self.host = host; popover.contentViewController = host
        guard let button = item.button else { return }
        button.title = ""
        button.image = NativeStatusArtwork.spider
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        button.target = self; button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp])
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        button.addTrackingArea(tracking); self.tracking = tracking
        button.setAccessibilityLabel("Боггарт")
        button.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Открыть панель управления", handler: { [weak self] in self?.openKeyboard(); return true }),
            NSAccessibilityCustomAction(name: "Открыть настройки", handler: { [weak self] in self?.showSettings(); return true })
        ])
        subscription = model.objectWillChange.sink { [weak self] _ in
            self?.queueRefresh()
        }
        maintenanceSubscription = model.$maintenanceOffer.sink { [weak self] offer in
            DispatchQueue.main.async {
                guard let self else { return }
                if let offer { self.showMaintenance(offer) }
                else { self.maintenanceWindow?.close(); self.maintenanceWindow = nil }
            }
        }
        for name in [NSApplication.didChangeScreenParametersNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            let center = name == NSWorkspace.activeSpaceDidChangeNotification ? NSWorkspace.shared.notificationCenter : NotificationCenter.default
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.send(.dismiss); self?.queueRefresh()
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: nil, queue: .main) { [weak self] note in
                if let window = note.object as? NSWindow { self?.closedWindows.insert(ObjectIdentifier(window)) }
                DispatchQueue.main.async { self?.refreshClockVisibility(); self?.updateDockPresence() }
            })
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil,
                queue: .main) { [weak self] note in
                    guard let self, let window = note.object as? NSWindow, window === self.item.button?.window else { return }
                    self.queueRefresh()
                })
        }
        accessTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.queueRefresh() }
        if let accessTimer { RunLoop.main.add(accessTimer, forMode: .common) }
        refresh()
        // AppKit назначает окончательное место не синхронно с созданием statusItem.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }
    @objc private func clicked() {
        // Command-перетаскивание — системная перестановка, не включение сессии.
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true { dismiss(); return }
        if NSApp.currentEvent?.type == .leftMouseDown || NSApp.currentEvent?.type == .rightMouseDown {
            send(.toggleClick); return
        }
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            send(.openMouse)
        } else { send(.toggleClick); model.toggle() }
    }
    @objc func mouseEntered(with event: NSEvent) { send(.enterAnchor) }
    @objc func mouseExited(with event: NSEvent) { send(.leaveAnchor) }
    func openKeyboard() { send(.openKeyboard) }
    func showAfterUserCommand() { send(.openMouse) }
    func dismiss() { send(.dismiss); controlWindow?.close(); refreshClockVisibility() }
    private func send(_ event: PanelInteraction.Event) {
        apply(interaction.receive(event, at: MacClock.continuous)); schedule()
    }
    private func schedule() {
        delayed?.cancel(); delayed = nil
        guard let deadline = interaction.nextDeadline else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.apply(self.interaction.advance(at: MacClock.continuous)); self.schedule()
        }
        delayed = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - MacClock.continuous), execute: work)
    }
    private func apply(_ effect: PanelInteraction.Effect?) {
        switch effect {
        case .show:
            refresh()
            guard anchorAvailable, let button = item.button else {
                // Наведение не активирует приложение и не создаёт отдельное окно.
                if interaction.pinned { showControlWindow() }
                else { send(.dismiss) }
                return
            }
            controlWindow?.close()
            updateSize()
            if !popover.isShown {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
            if interaction.pinned { host?.view.window?.makeKey() }
            if interaction.keyboard { host?.view.window?.selectNextKeyView(nil) }
            installMonitors(); refreshClockVisibility()
        case .close:
            if popover.isShown { popover.close() }
            removeMonitors(); refreshClockVisibility()
        case nil: break
        }
    }
    private func updateSize() {
        guard let host else { return }
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        let newSize = NSSize(width: ControlPanelView.width, height: max(100, size.height))
        if popover.contentSize != newSize {
            host.preferredContentSize = newSize
            popover.contentSize = newSize
        }
        if popover.isShown, let button = item.button { popover.positioningRect = button.bounds }
    }
    func popoverDidClose(_ notification: Notification) {
        _ = interaction.receive(.dismiss, at: MacClock.continuous)
        delayed?.cancel(); delayed = nil; removeMonitors(); refreshClockVisibility()
    }
    func popoverShouldDetach(_ popover: NSPopover) -> Bool { false }
    private func pointerInManagedArea() -> Bool {
        let point = NSEvent.mouseLocation
        if popover.isShown, let window = host?.view.window, window.frame.contains(point) { return true }
        if let button = item.button, let window = button.window {
            return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(point)
        }
        return false
    }
    private func installMonitors() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.window === self.host?.view.window {
                if event.keyCode == 53 { self.send(.dismiss); return nil }
            } else if event.type == .leftMouseUp || event.type == .rightMouseUp { self.send(.endPointerAction) }
            else if event.type == .leftMouseDown || event.type == .rightMouseDown {
                if !self.pointerInManagedArea() { self.send(.dismiss) }
                else if event.window === self.host?.view.window {
                    self.send(.beginPointerAction); self.host?.view.window?.makeKey()
                }
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.pointerInManagedArea() else { return }; self.send(.dismiss)
        }
    }
    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil; globalMonitor = nil
    }
    private func refreshClockVisibility() {
        model.preciseClockVisible = popover.isShown || settingsWindow?.window?.isVisible == true || controlWindow?.window?.isVisible == true
    }
#if BOGGART_UI_TESTING
    func capturePopover(to url: URL) throws {
        guard let button = item.button, let window = button.window,
              let content = host?.view.window?.contentView, let panelWindow = host?.view.window else {
            throw NSError(domain: "PopoverTest", code: 1)
        }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let gap = anchor.minY - panelWindow.frame.maxY
        guard gap <= 12 && gap >= -32 else { throw NSError(domain: "PopoverGap", code: Int(gap)) }
        let contentTop = panelWindow.convertToScreen(host!.view.convert(host!.view.bounds, to: nil)).maxY
        let contentGap = anchor.minY - contentTop
        guard contentGap <= 18 && contentGap >= -32 else { throw NSError(domain: "PopoverContentGap", code: Int(contentGap)) }
        print("POPOVER_ANCHOR_GAP_POINTS=\(gap); CONTENT_GAP_POINTS=\(contentGap)")
        try UISnapshots.capture(content, to: url)
    }
#endif
    private var anchorFrame: NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }
    private var menuArea: NSRect? {
        guard let screen = item.button?.window?.screen ?? NSScreen.main else { return nil }
        if let right = screen.auxiliaryTopRightArea { return right }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - NSStatusBar.system.thickness,
                      width: screen.frame.width, height: NSStatusBar.system.thickness)
    }
    private var anchorAvailable: Bool {
        let available = item.isVisible && MenuBarLayout.contains(anchorFrame, in: menuArea)
#if BOGGART_UI_TESTING
        print("STATUS_ANCHOR item=\(item.isVisible) ownerVisible=\(item.button?.window?.isVisible == true) frame=\(String(describing: anchorFrame)) area=\(String(describing: menuArea)) available=\(available)")
#endif
        return available
    }
    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.refresh()
        }
    }
    private func refresh() {
        guard !retired else { return }
        guard let button = item.button else { return }
        button.setAccessibilityValue(model.accessibilityValue)
        button.setAccessibilityHelp("Нажатие переключает удержание; наведение или правый клик открывают панель. Открытие Боггарта из Finder или Dock показывает окно управления.")
        button.toolTip = "Боггарт: \(model.accessibilityValue)"
        // Не сбрасываем image в nil и не зависим от размеров SwiftUI-подвида.
        let waiting = model.busy || model.awaitingExpiryConfirmation || model.checkingStatus
        let image = model.attention ? NativeStatusArtwork.error :
            (waiting ? NativeStatusArtwork.busy : (model.active ? NativeStatusArtwork.noSleep : NativeStatusArtwork.spider))
        if button.image !== image { button.image = image }
        button.contentTintColor = model.attention ? .systemRed : (model.active && !waiting ? .controlAccentColor : nil)
        let text = model.menuText
        let font = button.font ?? NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let expandedWidth = ceil(18 + 6 + 16 + (text as NSString).size(withAttributes: [.font: font]).width)
        let nextCompact = text.isEmpty || MenuBarLayout.needsCompact(
            frame: anchorFrame, area: menuArea, expandedWidth: expandedWidth, wasCompact: compact)
        compact = nextCompact
        let nextTitle = compact ? "" : text
        if button.title != nextTitle { button.title = nextTitle }
        button.imagePosition = compact ? .imageOnly : .imageLeading
        let length: CGFloat = compact ? 28 : expandedWidth
        if item.length != length { item.length = length }
        // Пропавший значок даёт запасной вход в Dock, но не всплывающее окно
        // поверх чужой работы. После первого пропадания Dock больше не мерцает.
        access.observeMenuItem(available: anchorAvailable, at: MacClock.continuous)
        updateDockPresence()
        if popover.isShown { updateSize() }
        if let window = controlWindow?.window, window.isVisible, let view = window.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            let size = NSSize(width: ControlPanelView.width, height: max(100, view.fittingSize.height))
            if window.contentLayoutRect.size != size { window.setContentSize(size) }
        }
    }
    private var hasUserWindow: Bool {
        [controlWindow, settingsWindow, setupWindow, maintenanceWindow].contains { controller in
            guard let window = controller?.window else { return false }
            return !closedWindows.contains(ObjectIdentifier(window)) && (window.isVisible || window.isMiniaturized)
        }
    }
    private func updateDockPresence() {
        guard !retired else { return }
        let policy: NSApplication.ActivationPolicy = access.needsDock(hasWindow: hasUserWindow) ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    /// Явное открытие через Finder/Spotlight не зависит от места в строке меню.
    /// Закрытие окна не останавливает сессию; «Выйти» использует штатное завершение.
    func showControlWindow() {
        send(.dismiss)
        if controlWindow == nil {
            let content = ControlPanelView(model: model,
                openSettings: { [weak self] in self?.showSettings() },
                openSetup: { [weak self] in self?.showSetup() },
                dismiss: { [weak self] in self?.dismiss() },
                quit: { NSApp.terminate(nil) }, hover: { _ in }, editing: { _ in })
            controlWindow = makeWindow(content, title: "Боггарт")
        }
        if let window = controlWindow?.window {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            if let area = screen?.visibleFrame {
                let origin = NSPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2)
                window.setFrameOrigin(origin)
            }
        }
        activate(controlWindow); refreshClockVisibility()
    }
#if BOGGART_UI_TESTING
    func retireForCI() {
        retired = true
        accessTimer?.invalidate(); delayed?.cancel()
        subscription?.cancel(); maintenanceSubscription?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        dismiss(); settingsWindow?.close(); setupWindow?.close(); maintenanceWindow?.close()
        NSStatusBar.system.removeStatusItem(item)
    }
    var hasVisibleControlWindowForCI: Bool { controlWindow?.window?.isVisible == true }
    func verifyAlreadyVisibleControlWindowForCI(to url: URL) throws {
        // Проверка не открывает окно сама: проверяем именно маршрут AppDelegate.
        guard let window = controlWindow?.window, window.isVisible,
              let content = window.contentView, NSApp.activationPolicy() == .regular else {
            throw NSError(domain: "VisibleLaunchWindow", code: 1)
        }
        try UISnapshots.capture(content, to: url)
    }
    func verifyNativeStatusForCI(to directory: URL, suffix: String) throws {
        refresh()
        guard let button = item.button, let image = button.image, image.isTemplate,
              button.subviews.allSatisfy({ !String(describing: type(of: $0)).contains("Hosting") }),
              image.representations.count >= 2 else {
            throw NSError(domain: "NativeStatusArtwork", code: 1)
        }
        guard let rep = image.representations.first as? NSBitmapImageRep else { throw NSError(domain: "NativeStatusInk", code: 1) }
        var inkPixels = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 { inkPixels += 1 }
            }
        }
        guard inkPixels > 15, inkPixels < rep.pixelsWide * rep.pixelsHigh else { throw NSError(domain: "NativeStatusInk", code: 2) }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            button.appearance = NSAppearance(named: appearance)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            try UISnapshots.capture(button, to: directory.appendingPathComponent("native-status-\(suffix)-\(name).png"))
        }
        button.appearance = nil
        print("NATIVE_STATUS_BUTTON_TEMPLATE_OK; NO_HOSTING_SUBVIEWS; IMAGE_REPS=\(image.representations.count)")
    }
    func captureControlWindow(to url: URL) throws {
        showControlWindow()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let window = controlWindow?.window, window.isVisible, let content = window.contentView,
              window.screen?.visibleFrame.contains(window.frame) == true else {
            throw NSError(domain: "IndependentControls", code: 1)
        }
        try UISnapshots.capture(content, to: url)
        print("INDEPENDENT_CONTROL_WINDOW_VISIBLE; PRECISE_CLOCK=\(model.preciseClockVisible)")
        dismiss()
    }
    func verifyHiddenItemRecovery(to url: URL) throws {
        // Только приёмочная сборка. Временно убираем свой statusItem публичным API.
        item.isVisible = false
        defer { item.isVisible = true }
        let now = MacClock.continuous
        access.observeMenuItem(available: false, at: now)
        access.observeMenuItem(available: false, at: now + 1.1)
        updateDockPresence()
        guard NSApp.activationPolicy() == .regular else { throw NSError(domain: "HiddenDock", code: 1) }
        openKeyboard()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard controlWindow?.window?.isVisible == true, !popover.isShown,
              let view = controlWindow?.window?.contentView else {
            throw NSError(domain: "HiddenStatusItemRecovery", code: 1)
        }
        try UISnapshots.capture(view, to: url)
        print("HIDDEN_STATUS_ITEM_RECOVERY_OK; NO_SESSION_COMMANDS")
        dismiss(); updateDockPresence()
        guard NSApp.activationPolicy() == .regular else { throw NSError(domain: "HiddenDockAfterClose", code: 1) }
        print("HIDDEN_ITEM_DOCK_ACCESS_REMAINS_AFTER_WINDOW_CLOSE")
    }
#endif
    func showSettings() {
        dismiss(); model.refreshSystemSettings()
        if settingsWindow == nil {
            settingsWindow = makeWindow(SettingsView(model: model), title: "Настройки Боггарта")
        }
        activate(settingsWindow); refreshClockVisibility()
    }
    func showSetup() {
        dismiss()
        if setupWindow == nil {
            setupWindow = makeWindow(SetupView(model: model, done: { [weak self] in
                guard let self else { return }
                self.model.completeIntroduction()
                guard self.model.introductionCompleted else { return }
                self.setupWindow?.close(); self.showControlWindow()
            }), title: "Боггарт")
        }
        activate(setupWindow)
    }
    private func showMaintenance(_ offer: MaintenanceOffer) {
        dismiss()
        maintenanceWindow = makeWindow(MaintenanceView(model: model, offer: offer), title: offer.title)
        activate(maintenanceWindow)
    }
    private func makeWindow<V: View>(_ view: V, title: String) -> NSWindowController {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title; window.styleMask = [.titled, .closable, .miniaturizable]
        window.identifier = NSUserInterfaceItemIdentifier("Boggart-" + title)
        window.isReleasedWhenClosed = false; window.center()
        return NSWindowController(window: window)
    }
    private func activate(_ controller: NSWindowController?) {
        guard let window = controller?.window else { return }
        closedWindows.remove(ObjectIdentifier(window))
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller?.showWindow(nil); controller?.window?.makeKeyAndOrderFront(nil)
    }
    deinit {
        delayed?.cancel(); accessTimer?.invalidate(); removeMonitors()
        for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let tracking { item.button?.removeTrackingArea(tracking) }
        controlWindow?.close(); popover.close(); NSStatusBar.system.removeStatusItem(item)
    }
}
