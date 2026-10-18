import AppKit
import SwiftUI

struct InstallerBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.96, green: 0.97, blue: 0.985)
            VStack(spacing: 10) {
                Text("Боггарт").font(.system(size: 30, weight: .semibold))
                Text("Перенесите в «Программы»").font(.system(size: 16)).foregroundStyle(.secondary)
            }.position(x: 360, y: 72)
            Image(systemName: "arrow.right").font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.secondary.opacity(0.65)).position(x: 360, y: 232)
            Text("Затем откройте Боггарт из папки «Программы».")
                .font(.system(size: 13)).foregroundStyle(.secondary).position(x: 360, y: 384)
        }.frame(width: 720, height: 440).environment(\.colorScheme, .light)
    }
}

@main
struct RenderAssets {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw NSError(domain: "RenderAssets", code: 64) }
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("AppIcon.iconset"), withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 1 ? "" : "@2x"
                try writePNG(BoggartAppIcon().frame(width: CGFloat(points), height: CGFloat(points)).environment(\.colorScheme, .light),
                    scale: CGFloat(scale), to: root.appendingPathComponent("AppIcon.iconset/icon_\(points)x\(points)\(suffix).png"))
            }
        }
        try writePNG(BoggartAppIcon().frame(width: 512, height: 512), scale: 2, to: root.appendingPathComponent("app-icon.png"))
        try writePNG(SkatingSpider(monochrome: true).frame(width: 22, height: 22).padding(5)
            .background(Color.white).environment(\.colorScheme, .light), scale: 4, to: root.appendingPathComponent("menu-spider.png"))
        try writePNG(InstallerBackground(), scale: 2, to: root.appendingPathComponent("installer-background.png"))
        let background = NSImage(size: NSSize(width: 720, height: 440))
        for scale in [1.0, 2.0] {
            let renderer = ImageRenderer(content: InstallerBackground()); renderer.scale = scale
            guard let image = renderer.cgImage else { throw NSError(domain: "RenderAssets", code: 1) }
            let rep = NSBitmapImageRep(cgImage: image); rep.size = NSSize(width: 720, height: 440)
            background.addRepresentation(rep)
        }
        guard let data = background.tiffRepresentation else { throw NSError(domain: "RenderAssets", code: 2) }
        try data.write(to: root.appendingPathComponent("installer-background.tiff"))
        print("NATIVE_ARTWORK_RENDERED")
    }
    @MainActor private static func writePNG<V: View>(_ view: V, scale: CGFloat, to url: URL) throws {
        let renderer = ImageRenderer(content: view); renderer.scale = scale
        guard let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "RenderAssets", code: 3)
        }
        try data.write(to: url)
    }
}
