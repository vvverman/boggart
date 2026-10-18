import AppKit
import SwiftUI
import BoggartCore

/// Второй экземпляр не захватывает помощник и не обрывает чужую сессию.
/// Вместо тихого закрытия показывает, почему пользователь видит прежний интерфейс.
final class DuplicateInstancePresenter: NSObject, NSWindowDelegate {
    private let controller: NSWindowController
    init(existingURL: URL?) {
        let host = NSHostingController(rootView: DuplicateInstanceView(existingURL: existingURL))
        let window = NSWindow(contentViewController: host)
        window.title = "Боггарт уже запущен"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        controller = NSWindowController(window: window)
        super.init()
        window.delegate = self
        window.center()
    }
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}

struct DuplicateInstanceView: View {
    let existingURL: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Боггарт уже работает").font(.title3.weight(.semibold))
            Text("Новая копия не запущена. После замены файла прежняя версия может продолжать работать, пока вы не завершите её.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Остановите удержание и завершите прежнюю копию через её меню, затем откройте обновление из «Программ». Текущая сессия не изменена.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let existingURL {
                Button("Показать работающую копию в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([existingURL])
                }
            }
            HStack {
                Text("Открываемое обновление: \(BoggartConstants.version)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Закрыть") { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 420)
    }
}
