import AppKit
import SwiftUI
import Combine
import BoggartCore
import BoggartPlatform

private final class PassthroughStatusView: NSHostingView<StatusLabelView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// AppKit отвечает только за системное размещение и события. Системный popover
/// сам привязывается к реальной кнопке на нужном дисплее, включая скрытую строку меню.
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
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

    init(model: AppModel) {
        self.model = model
        super.init()
        IdleLockController.shared.attach(model)
        item.autosaveName = "BoggartStatusItem"
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
        let statusHost = PassthroughStatusView(rootView: StatusLabelView(model: model))
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
        refresh()
    }
    @objc private func clicked() {
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
    func dismiss() { send(.dismiss) }
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
            guard let button = item.button, button.window != nil else { return }
            updateSize()
            popover.positioningRect = button.bounds
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
        model.preciseClockVisible = popover.isShown || settingsWindow?.window?.isVisible == true
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
    private func refresh() {
        item.button?.setAccessibilityValue(model.accessibilityValue)
        item.button?.setAccessibilityHelp("Нажатие переключает удержание; наведение или правый клик открывают панель.")
        let length: CGFloat
        if model.attention || (model.active && !model.showRemaining) { length = 32 }
        else if model.active {
            let hours = Int(min((model.remaining ?? 0) / 3600, Double(Int.max / 2)))
            length = max(78, CGFloat(String(hours).count * 8 + 54))
        } else { length = 72 }
        if item.length != length { item.length = length }
        if popover.isShown { updateSize() }
    }
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
        popover.close(); NSStatusBar.system.removeStatusItem(item)
    }
}
