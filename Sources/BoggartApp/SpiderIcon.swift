import SwiftUI

/// Геометрический знак: восемь лап, ролики и сквозной просвет в корпусе.
/// Просветы действительно прозрачны, а пересечения не удваивают непрозрачность.
struct SkatingSpider: View {
    var monochrome = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 100
            context.translateBy(x: (size.width - scale * 100) / 2, y: (size.height - scale * 100) / 2)
            context.scaleBy(x: scale, y: scale)
            let ink: Color = scheme == .dark ? .white : .black
            context.drawLayer { mark in
                for mirror in [false, true] {
                    func p(_ x: Double, _ y: Double) -> CGPoint { .init(x: mirror ? 100 - x : x, y: y) }
                    for points in [[p(38, 31), p(25, 19), p(13, 19)],
                                   [p(35, 40), p(20, 34), p(10, 40)],
                                   [p(35, 50), p(18, 51), p(10, 62)],
                                   [p(40, 61), p(30, 71), p(30, 76)]] {
                        var leg = Path()
                        leg.move(to: points[0])
                        for point in points.dropFirst() { leg.addLine(to: point) }
                        mark.stroke(leg, with: .color(ink), style: StrokeStyle(lineWidth: 7, lineCap: .square, lineJoin: .miter))
                    }
                    mark.fill(Path(roundedRect: CGRect(x: mirror ? 55 : 22, y: 71, width: 23, height: 9), cornerRadius: 2), with: .color(ink))
                }
                var body = Path()
                body.move(to: .init(x: 50, y: 19))
                for point in [CGPoint(x: 65, y: 28), .init(x: 68, y: 47), .init(x: 60, y: 63),
                              .init(x: 50, y: 69), .init(x: 40, y: 63), .init(x: 32, y: 47), .init(x: 35, y: 28)] {
                    body.addLine(to: point)
                }
                body.closeSubpath(); mark.fill(body, with: .color(ink))
                for x in [27.0, 40.0, 60.0, 73.0] {
                    mark.fill(Path(ellipseIn: .init(x: x - 5, y: 83, width: 10, height: 10)), with: .color(ink))
                }
                mark.blendMode = .destinationOut
                var aperture = Path()
                aperture.move(to: .init(x: 50, y: 31))
                for point in [CGPoint(x: 57, y: 41), CGPoint(x: 50, y: 55), CGPoint(x: 43, y: 41)] {
                    aperture.addLine(to: point)
                }
                aperture.closeSubpath(); mark.fill(aperture, with: .color(.black))
            }
        }.accessibilityHidden(true)
    }
}

/// Месяц в круге с диагональной чертой: «сон запрещён».
struct NoSleepSymbol: View {
    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 24
            context.translateBy(x: (size.width - s * 24) / 2, y: (size.height - s * 24) / 2)
            context.scaleBy(x: s, y: s)
            context.drawLayer { moon in
                moon.fill(Path(ellipseIn: .init(x: 6.8, y: 5.2, width: 10.7, height: 13.6)), with: .foreground)
                moon.blendMode = .destinationOut
                moon.fill(Path(ellipseIn: .init(x: 10.3, y: 3.4, width: 11, height: 12)), with: .color(.black))
                var slash = Path(); slash.move(to: .init(x: 5, y: 5)); slash.addLine(to: .init(x: 19, y: 19))
                moon.stroke(slash, with: .color(.black), style: .init(lineWidth: 4, lineCap: .round))
            }
            context.stroke(Path(ellipseIn: .init(x: 1.4, y: 1.4, width: 21.2, height: 21.2)),
                with: .foreground, style: .init(lineWidth: 1.8))
            var slash = Path(); slash.move(to: .init(x: 4.6, y: 4.6)); slash.addLine(to: .init(x: 19.4, y: 19.4))
            context.stroke(slash, with: .foreground, style: .init(lineWidth: 1.8, lineCap: .round))
        }.accessibilityLabel("Сон запрещён")
    }
}

struct BoggartAppIcon: View {
    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.215, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.19, green: 0.22, blue: 0.26), Color(red: 0.07, green: 0.09, blue: 0.12)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                SkatingSpider(monochrome: true).environment(\.colorScheme, .dark).padding(s * 0.115)
            }
            .padding(s * 0.075)
            .shadow(color: .black.opacity(0.2), radius: s * 0.018, y: s * 0.012)
        }.accessibilityHidden(true)
    }
}
