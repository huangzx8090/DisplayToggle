import SwiftUI

struct LidIllustration: View, Animatable {
    var angle: Double
    let screenOn: Bool
    let threshold: Int?

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    private let silver = Color(red: 0.69, green: 0.74, blue: 0.80)
    private let graphite = Color(red: 0.10, green: 0.14, blue: 0.19)

    var body: some View {
        Canvas { context, size in
            draw(context, size: size)
        }
        .accessibilityHidden(true)
    }

    private func draw(_ context: GraphicsContext, size: CGSize) {
        func project(_ point: LidGeometry.Point) -> CGPoint {
            LidGeometry.project(point, size: size)
        }
        func base(_ x: Double, _ y: Double, _ z: Double = 0) -> CGPoint {
            project(.init(x: x, y: y, z: z))
        }
        func lid(_ x: Double, _ distance: Double, _ inset: Double = 0) -> CGPoint {
            project(LidGeometry.lidPoint(x: x, distance: distance, angle: angle, inset: inset))
        }
        func polygon(_ points: [CGPoint]) -> Path {
            Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
                path.closeSubpath()
            }
        }
        func baseRect(_ x: Double, _ y: Double, _ width: Double, _ depth: Double) -> Path {
            polygon([base(x, y), base(x + width, y),
                     base(x + width, y + depth), base(x, y + depth)])
        }
        func lidRect(_ x: Double, _ y: Double, _ width: Double,
                     _ height: Double, _ inset: Double = 0) -> Path {
            polygon([lid(x, y, inset), lid(x + width, y, inset),
                     lid(x + width, y + height, inset), lid(x, y + height, inset)])
        }

        let deck = baseRect(-115, 0, 230, 145)
        var shadow = context
        shadow.addFilter(.shadow(color: .black.opacity(0.20), radius: 12, x: 0, y: 12))
        shadow.fill(deck, with: .color(silver))

        let front = polygon([base(-115, 145), base(115, 145),
                             base(112, 145, -5), base(-112, 145, -5)])
        context.fill(front, with: .color(silver.opacity(0.85)))
        context.fill(deck, with: .linearGradient(
            Gradient(colors: [Color(red: 0.91, green: 0.93, blue: 0.96), silver]),
            startPoint: base(-115, 0), endPoint: base(115, 145)))
        context.stroke(deck, with: .color(Color.white.opacity(0.6)),
                       style: StrokeStyle(lineWidth: 1, lineJoin: .round))

        context.fill(baseRect(-101, 19, 202, 65), with: .color(graphite.opacity(0.85)))
        for row in 0..<4 {
            for column in 0..<10 {
                let key = baseRect(-96 + Double(column) * 19.5,
                                   23 + Double(row) * 14.5, 16, 10)
                context.fill(key, with: .color(Color(red: 0.23, green: 0.28, blue: 0.34)))
                context.stroke(key, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
            }
        }
        let trackpad = baseRect(-39, 98, 78, 35)
        context.fill(trackpad, with: .color(.white.opacity(0.12)))
        context.stroke(trackpad, with: .color(graphite.opacity(0.25)), lineWidth: 0.8)
        context.stroke(Path { path in
            path.move(to: base(-17, 145, -1))
            path.addLine(to: base(17, 145, -1))
        }, with: .color(graphite.opacity(0.3)), lineWidth: 1.5)

        // 底座始终不动，屏幕各顶点都绕同一条铰链旋转。
        let shell = lidRect(-115, 0, 230, 145)
        context.fill(shell, with: .linearGradient(
            Gradient(colors: [silver, Color(red: 0.88, green: 0.91, blue: 0.95)]),
            startPoint: lid(-115, 145), endPoint: lid(115, 0)))
        context.stroke(shell, with: .color(graphite.opacity(0.38)),
                       style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))

        let faceOpacity = max(0, min(1, (angle - 30) / 22))
        if faceOpacity > 0 {
            let bezel = lidRect(-111, 4, 222, 138, 0.7)
            context.fill(bezel, with: .color(graphite.opacity(faceOpacity)))
            let screen = lidRect(-105, 10, 210, 126, 1)
            let screenColors: [Color] = screenOn
                ? [Color(red: 0.06, green: 0.20, blue: 0.39),
                   Color(red: 0.09, green: 0.39, blue: 0.62),
                   Color(red: 0.23, green: 0.77, blue: 0.80)]
                : [Color(red: 0.07, green: 0.09, blue: 0.12),
                   Color(red: 0.11, green: 0.14, blue: 0.18)]
            var face = context
            face.opacity = faceOpacity
            face.fill(screen, with: .linearGradient(
                Gradient(colors: screenColors), startPoint: lid(-105, 136),
                endPoint: lid(105, 10)))
            if screenOn {
                face.clip(to: screen)
                let ribbon = polygon([lid(-130, 38, 1.1), lid(130, 103, 1.1),
                                      lid(130, 124, 1.1), lid(-130, 70, 1.1)])
                face.fill(ribbon, with: .color(.white.opacity(0.10)))
            }
        }
        context.stroke(Path { path in
            path.move(to: base(-102, 0, 1))
            path.addLine(to: base(102, 0, 1))
        }, with: .color(graphite.opacity(0.75)),
           style: StrokeStyle(lineWidth: 3, lineCap: .round))

        if let threshold {
            let origin = base(143, 0)
            let end = project(LidGeometry.lidPoint(x: 143, distance: 64,
                                                  angle: Double(threshold)))
            var guide = Path()
            guide.move(to: origin)
            guide.addLine(to: end)
            context.stroke(guide, with: .color(.accentColor.opacity(0.45)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            var arc = Path()
            for degree in stride(from: 0, through: max(3, Int(angle)), by: 3) {
                let point = project(LidGeometry.lidPoint(x: 143, distance: 42,
                                                        angle: Double(degree)))
                if degree == 0 { arc.move(to: point) } else { arc.addLine(to: point) }
            }
            context.stroke(arc, with: .color(.accentColor.opacity(0.65)),
                           style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
    }
}
