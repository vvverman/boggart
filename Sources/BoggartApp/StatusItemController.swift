import AppKit
import SwiftUI
import Combine
import BoggartCore
import BoggartPlatform

private struct AdaptiveStatusLabelView: View {
    @ObservedObject var model: AppModel
    var compact: Bool
    var body: some View {
        Group {
            if compact {
                Group {
                    if model.busy || model.awaitingExpiryConfirmation || model.checkingStatus {
                        ProgressView().controlSize(.mini)
                    } else if model.attention {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    } else if model.active {
                        NoSleepSymbol().foregroundStyle(Color.accentColor)
                    } else {
                        SkatingSpider(monochrome: true)
                    }
                }.frame(width: 18, height: 18)
            } else {
                StatusLabelView(model: model)
            }
        }.accessibilityHidden(true)
    }
}

private final class PassthroughStatusView: NSHostingView<AdaptiveStatusLabelView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// AppKit отвечает только за системное размещение и события. Системный popover
/// привязывается только к доступной кнопке. При вырезе или переполнении
/// управление открывается в обычном временном окне с тем же SwiftUI-содержимым.
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var statusHost: PassthroughStatusView?
    private var compact = true
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

    init(model: AppModel, autosaveName: String = "BoggartStatusItem") {
        self.model = model
        super.init()
        IdleLockController.shared.attach(model)
        item.autosaveName = autosaveName
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
        button.title = ""; button.image = nil
        button.target = self; button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp])
        let statusHost = PassthroughStatusView(rootView: AdaptiveStatusLabelView(model: model, compact: true))
        self.statusHost = statusHost
        statusHost.frame = button.bounds; statusHost.autoresizingMask = [.width, .height]
        statusHost.setAccessibilityElement(false); button.addSubview(statusHost)
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        button.addTrackingArea(tracking); self.tracking = tracking
        button.setAccessibilityLabel("Боггарт")
        button.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Открыть панель управления", handler: { [weak self] in self?.openKeyboard(); return true }),
            NSAccessibilityCustomAction(name: "Открыть настройки", handler: { [weak self] in self?.showSettings(); return true })
        ])
        subscription = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
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
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.dismiss() })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshClockVisibility() }
            })
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: button.window,
                queue: .main) { [weak self] _ in
                    DispatchQueue.main.async { self?.refresh() }
                })
        }
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
    private func refresh() {
        item.button?.setAccessibilityValue(model.accessibilityValue)
        item.button?.setAccessibilityHelp("Нажатие переключает удержание; наведение или правый клик открывают панель. Управление также доступно при открытии Боггарта из Finder или Spotlight.")
        item.button?.toolTip = "Боггарт: \(model.accessibilityValue)"
        let textWidth = (model.menuText as NSString).size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        ]).width
        let expandedWidth = ceil(22 + 10 + (model.menuText.isEmpty ? 0 : 5 + textWidth))
        let nextCompact = model.menuText.isEmpty || MenuBarLayout.needsCompact(
            frame: anchorFrame, area: menuArea, expandedWidth: expandedWidth, wasCompact: compact)
        if compact != nextCompact {
            compact = nextCompact
            statusHost?.rootView = AdaptiveStatusLabelView(model: model, compact: compact)
        }
        let length = compact ? NSStatusItem.squareLength : expandedWidth
        if item.length != length { item.length = length }
        if popover.isShown { updateSize() }
        if let window = controlWindow?.window, window.isVisible, let view = window.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            let size = NSSize(width: ControlPanelView.width, height: max(100, view.fittingSize.height))
            if window.contentLayoutRect.size != size { window.setContentSize(size) }
        }
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
        openKeyboard()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard controlWindow?.window?.isVisible == true, !popover.isShown,
              let view = controlWindow?.window?.contentView else {
            throw NSError(domain: "HiddenStatusItemRecovery", code: 1)
        }
        try UISnapshots.capture(view, to: url)
        print("HIDDEN_STATUS_ITEM_RECOVERY_OK; NO_SESSION_COMMANDS")
        dismiss()
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
                self.model.completeIntroduction(); self.setupWindow?.close()
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
        window.title = title; window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false; window.center()
        return NSWindowController(window: window)
    }
    private func activate(_ controller: NSWindowController?) {
        NSApp.activate(ignoringOtherApps: true)
        controller?.showWindow(nil); controller?.window?.makeKeyAndOrderFront(nil)
    }
    deinit {
        delayed?.cancel(); removeMonitors()
        for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let tracking { item.button?.removeTrackingArea(tracking) }
        controlWindow?.close(); popover.close(); NSStatusBar.system.removeStatusItem(item)
    }
}
