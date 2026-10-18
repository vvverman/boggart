import AppKit
import SwiftUI

/// Геометрия остаётся SwiftUI, но в строке меню macOS рисует NSImage-template,
/// а не NSHostingView. Контраст определяется фоном строки меню, не темой окна.
enum NativeStatusArtwork {
    static let spider = template(SkatingSpider(monochrome: true).environment(\.colorScheme, .light), fallback: "asterisk.circle")
    static let noSleep = template(NoSleepSymbol().foregroundStyle(Color.black), fallback: "moon.zzz")
    static let busy = symbol("hourglass")
    static let error = symbol("exclamationmark.triangle.fill")

    /// Три масштаба считаются один раз за процесс, не на каждом тике таймера.
    private static func template<V: View>(_ view: V, fallback: String) -> NSImage {
        precondition(Thread.isMainThread)
        return MainActor.assumeIsolated {
            let image = NSImage(size: NSSize(width: 18, height: 18))
            for scale in [1.0, 2.0, 3.0] {
                let renderer = ImageRenderer(content: view.frame(width: 18, height: 18))
                renderer.scale = scale
                guard let cg = renderer.cgImage else { return symbol(fallback) }
                let rep = NSBitmapImageRep(cgImage: cg)
                rep.size = image.size
                image.addRepresentation(rep)
            }
            image.isTemplate = true
            return image
        }
    }
    private static func symbol(_ name: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(named: NSImage.cautionName)!
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
}
