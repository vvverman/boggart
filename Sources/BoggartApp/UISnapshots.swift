#if BOGGART_UI_TESTING
import AppKit
import SwiftUI

/// Собирается только в отдельный исполняемый файл приёмки. В поставке кода нет.
@MainActor enum UISnapshots {
    nonisolated static func run(directory: URL) throws {
        precondition(Thread.isMainThread)
        try MainActor.assumeIsolated { try renderAll(directory: directory) }
    }
    private static func renderAll(directory: URL) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try IdleLockController.shared.verifyNativeAssertionsForCI()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua), ("dark", .dark, .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let off = AppModel.preview()
            let on = AppModel.preview(active: true)
            let setup = AppModel.preview(setup: true)
            for (state, model) in [("inactive", off), ("active", on)] {
                try render(ControlPanelView(model: model, openSettings: {}, openSetup: {}, dismiss: {}, quit: {}, hover: { _ in }, editing: { _ in })
                    .environment(\.colorScheme, scheme), to: directory.appendingPathComponent("panel-\(state)-\(name).png"))
                try render(SettingsView(model: model).environment(\.colorScheme, scheme), to: directory.appendingPathComponent("settings-\(state)-\(name).png"))
                // Возвращаем тестовое состояние после onAppear настроек, не отправляя команд помощнику.
                let statusModel = AppModel.preview(active: state == "active")
                try render(StatusLabelView(model: statusModel).environment(\.colorScheme, scheme), to: directory.appendingPathComponent("status-\(state)-\(name).png"))
            }
            try render(SetupView(model: setup, done: {}).environment(\.colorScheme, scheme), to: directory.appendingPathComponent("setup-\(name).png"))
        }
        NSApp.appearance = NSAppearance(named: .aqua)
        // У разных тестовых statusItem разные autosaveName. В приложении всегда
        // один контроллер и постоянное имя; здесь две изолированные модели.
        // Имитация исчезновения значка выполняется после проверки обоих popover.
        let cases = [false, true].map { active in
            (active, StatusItemController(model: .preview(active: active),
                autosaveName: "Boggart-UI-\(active)-\(UUID().uuidString)"))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        for (active, controller) in cases {
            controller.openKeyboard()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            try controller.capturePopover(to: directory.appendingPathComponent(active ? "system-popover.png" : "system-popover-inactive.png"))
            controller.dismiss()
        }
        for (active, controller) in cases {
            try controller.captureControlWindow(to: directory.appendingPathComponent(active ? "independent-active.png" : "independent-inactive.png"))
            try controller.verifyHiddenItemRecovery(to: directory.appendingPathComponent(active ? "hidden-item-active.png" : "hidden-item-inactive.png"))
        }
        print("SWIFTUI_VIEWS_RENDERED; NO_SLEEP_COMMANDS_SENT")
    }
    private static func render<V: View>(_ view: V, to url: URL) throws {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let size = host.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.setContentSize(size)
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        try capture(host, to: url)
        window.orderOut(nil)
    }
    nonisolated static func capture(_ view: NSView, to url: URL) throws {
        precondition(Thread.isMainThread)
        try MainActor.assumeIsolated {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NSError(domain: "UICapture", code: 1) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "UICapture", code: 2) }
            try data.write(to: url)
        }
    }
}
#endif
