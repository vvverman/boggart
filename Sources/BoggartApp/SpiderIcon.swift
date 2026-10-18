import SwiftUI

/// Один векторный персонаж для значка приложения и монохромной строки меню.
/// Геометрия нормализована к 100 × 100; в маленьком размере остаётся силуэт.
struct SkatingSpider: View {
    var monochrome = false
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 100
            context.translateBy(x: (size.width - scale * 100) / 2, y: (size.height - scale * 100) / 2)
            context.scaleBy(x: scale, y: scale)
            let ink = monochrome ? Color.primary : Color(red: 0.12, green: 0.14, blue: 0.24)
            let boot = monochrome ? ink : Color(red: 1.0, green: 0.39, blue: 0.22)
            let legs: [[CGPoint]] = [
                [.init(x: 37, y: 37), .init(x: 24, y: 23), .init(x: 12, y: 30)],
                [.init(x: 36, y: 45), .init(x: 18, y: 39), .init(x: 8, y: 47)],
                [.init(x: 63, y: 37), .init(x: 76, y: 23), .init(x: 88, y: 30)],
                [.init(x: 64, y: 45), .init(x: 82, y: 39), .init(x: 92, y: 47)],
                [.init(x: 39, y: 57), .init(x: 21, y: 60), .init(x: 17, y: 72)],
                [.init(x: 45, y: 62), .init(x: 39, y: 67), .init(x: 39, y: 79)],
                [.init(x: 55, y: 62), .init(x: 61, y: 67), .init(x: 61, y: 79)],
                [.init(x: 61, y: 57), .init(x: 79, y: 60), .init(x: 83, y: 72)]
            ]
            for p in legs {
                var path = Path(); path.move(to: p[0]); path.addQuadCurve(to: p[2], control: p[1])
                context.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: monochrome ? 5 : 5.5, lineCap: .round, lineJoin: .round))
            }
            let body = Path(ellipseIn: CGRect(x: 29, y: 24, width: 42, height: 42))
            if monochrome { context.fill(body, with: .color(ink)) }
            else {
                context.fill(body, with: .linearGradient(Gradient(colors: [Color(red: 0.31, green: 0.34, blue: 0.50), ink]),
                    startPoint: .init(x: 37, y: 27), endPoint: .init(x: 61, y: 66)))
            }
            // Четыре ролика на опорных лапах. Ещё четыре лапы удерживают равновесие.
            for (x, y) in [(17.0, 72.0), (39.0, 79.0), (61.0, 79.0), (83.0, 72.0)] {
                let shoe = CGRect(x: x - 7, y: y - 4, width: 15, height: 8)
                context.fill(Path(roundedRect: shoe, cornerRadius: 3), with: .color(boot))
                for wheelX in [x - 4, x + 5] {
                    context.fill(Path(ellipseIn: CGRect(x: wheelX - 2.6, y: y + 6, width: 5.2, height: 5.2)), with: .color(ink))
                }
            }
            if !monochrome {
                for x in [41.0, 58.0] {
                    context.fill(Path(ellipseIn: CGRect(x: x - 5.5, y: 39, width: 11, height: 13)), with: .color(.white))
                    context.fill(Path(ellipseIn: CGRect(x: x - 1, y: 44, width: 4.5, height: 6)), with: .color(ink))
                }
                var smile = Path(); smile.move(to: .init(x: 46, y: 57))
                smile.addQuadCurve(to: .init(x: 54, y: 57), control: .init(x: 50, y: 60))
                context.stroke(smile, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }.accessibilityHidden(true)
    }
}

struct BoggartAppIcon: View {
    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.22, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.94, green: 0.97, blue: 1), Color(red: 0.74, green: 0.85, blue: 0.98)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        RoundedRectangle(cornerRadius: s * 0.22, style: .continuous)
                            .strokeBorder(.white.opacity(0.7), lineWidth: max(1, s * 0.007))
                    }
                SkatingSpider().padding(s * 0.055)
                    .shadow(color: Color(red: 0.15, green: 0.23, blue: 0.4).opacity(0.15), radius: s * 0.016, y: s * 0.012)
            }
            .padding(s * 0.065)
            .shadow(color: .black.opacity(0.15), radius: s * 0.025, y: s * 0.015)
        }.accessibilityHidden(true)
    }
}
