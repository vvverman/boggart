#if BOGGART_UI_TESTING
import AppKit
import SwiftUI

/// Собирается только в отдельный исполняемый файл приёмки. В поставке кода нет.
@MainActor enum UISnapshots {
    static func run(directory: URL) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua), ("dark", .dark, .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let off = AppModel.preview()
            let on = AppModel.preview(active: true)
            let setup = AppModel.preview(setup: true)
            for (state, model) in [("inactive", off), ("active", on)] {
                try render(ControlPanelView(model: model, openSettings: {}, openSetup: {}, dismiss: {}, quit: {}, hover: { _ in }, editing: { _ in })
                    .environment(\.colorScheme, scheme), to: directory.appendingPathComponent("panel-\(state)-\(name).png"))
            }
            try render(SettingsView(model: off).environment(\.colorScheme, scheme), to: directory.appendingPathComponent("settings-\(name).png"))
            try render(SetupView(model: setup, done: {}).environment(\.colorScheme, scheme), to: directory.appendingPathComponent("setup-\(name).png"))
        }
        NSApp.appearance = NSAppearance(named: .aqua)
        let controller = StatusItemController(model: .preview(active: true))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        controller.openKeyboard()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        try controller.capturePopover(to: directory.appendingPathComponent("system-popover.png"))
        controller.dismiss()
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
    static func capture(_ view: NSView, to url: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NSError(domain: "UICapture", code: 1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "UICapture", code: 2) }
        try data.write(to: url)
    }
}
#endif
