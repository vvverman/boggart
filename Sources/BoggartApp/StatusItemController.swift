import AppKit
import SwiftUI
import Combine
import BoggartCore
import BoggartPlatform

private final class PassthroughStatusView: NSHostingView<StatusLabelView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
/// Системное nonactivating-окно. orderFront при наведении не активирует приложение
/// и не забирает ввод у редактора, терминала или другого текущего приложения.
private final class ControlPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Только интеграция с macOS: события, окно, доступность NSStatusItem.
/// Ни правила сессии, ни настройки, ни представления не реализованы в AppKit.
final class StatusItemController: NSObject {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: ControlPanel
    private var panelHost: NSHostingController<ControlPanelView>?
    private var tracking: NSTrackingArea?
    private var interaction = PanelInteraction()
    private var delayed: DispatchWorkItem?
    private var subscription: AnyCancellable?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var settingsWindow: NSWindowController?

    init(model: AppModel) {
        self.model = model
        panel = ControlPanel(contentRect: .zero,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.title = "Боггарт"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true; panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu; panel.hasShadow = true
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let content = ControlPanelView(model: model,
            openSettings: { [weak self] in self?.showSettings() },
            dismiss: { [weak self] in self?.send(.dismiss) },
            quit: { NSApp.terminate(nil) },
            hover: { [weak self] in self?.send($0 ? .enterPanel : .leavePanel) },
            editing: { [weak self] in self?.send($0 ? .beginEditing : .endEditing) })
        let host = NSHostingController(rootView: content)
        panel.contentViewController = host; panelHost = host
        guard let button = item.button else { return }
        button.title = ""; button.image = nil
        button.target = self; button.action = #selector(clicked)
        // mouseDown отменяет ожидающее hover-открытие; команда выполняется на mouseUp.
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
        refresh()
    }
    @objc private func clicked() {
        if NSApp.currentEvent?.type == .leftMouseDown || NSApp.currentEvent?.type == .rightMouseDown {
            send(.toggleClick); return
        }
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            send(.openMouse)
        } else {
            send(.toggleClick)
            model.toggle()
        }
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
            positionPanel()
            panel.orderFrontRegardless() // Не вызываем NSApp.activate на hover.
            if interaction.pinned { panel.makeKey() }
            if interaction.keyboard { panel.selectNextKeyView(nil) }
            installMonitors()
        case .close:
            panel.orderOut(nil); removeMonitors()
        case nil: break
        }
    }
    private func positionPanel() {
        guard let button = item.button, let window = button.window, let host = panelHost else { return }
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        panel.setContentSize(NSSize(width: 350, height: max(100, size.height)))
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        let x = min(max(anchor.midX - panel.frame.width / 2, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        let y = max(visible.minY + 8, anchor.minY - panel.frame.height - 4)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
    private func pointerInManagedArea() -> Bool {
        let point = NSEvent.mouseLocation
        if panel.isVisible && panel.frame.contains(point) { return true }
        if let button = item.button, let window = button.window {
            return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(point)
        }
        return false
    }
    private func installMonitors() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.window === self.panel {
                if event.keyCode == 53 { self.send(.dismiss); return nil }
            } else if event.type == .leftMouseUp || event.type == .rightMouseUp { self.send(.endPointerAction) }
            else if event.type == .leftMouseDown || event.type == .rightMouseDown {
                if !self.pointerInManagedArea() { self.send(.dismiss) }
                else if event.window === self.panel {
                    self.send(.beginPointerAction)
                    // Явное взаимодействие может дать панели клавиатурный фокус.
                    self.panel.makeKey()
                }
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.pointerInManagedArea() else { return }
            self.send(.dismiss)
        }
    }
    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil; globalMonitor = nil
    }
    private func refresh() {
        item.button?.setAccessibilityValue(model.accessibilityValue)
        item.button?.setAccessibilityHelp("Нажатие переключает удержание. Панель доступна через правый клик или действие VoiceOver «Открыть панель управления».")
        let length: CGFloat
        if model.attention || (model.active && !model.showRemaining) { length = 28 }
        else if model.active {
            let hours = Int(min((model.remaining ?? 0) / 3600, Double(Int.max / 2)))
            length = max(82, CGFloat(String(hours).count * 8 + 60))
        } else { length = 66 }
        if item.length != length { item.length = length }
        if panel.isVisible { positionPanel() }
    }
    func showSettings() {
        dismiss(); model.refreshSystemSettings()
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: controller)
            window.title = "Настройки Боггарта"; window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false; window.center()
            settingsWindow = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.showWindow(nil); settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }
    deinit {
        delayed?.cancel(); removeMonitors()
        if let tracking { item.button?.removeTrackingArea(tracking) }
        panel.orderOut(nil); NSStatusBar.system.removeStatusItem(item)
    }
}
