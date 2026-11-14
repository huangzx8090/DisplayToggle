import Foundation

struct LidPose: Equatable {
    enum Source: Equatable { case sensor, closed, unavailable }

    let angle: Double
    let source: Source

    static func resolve(angle: Int?, isClosed: Bool?) -> LidPose {
        // 合盖信号优先于可能滞后的最后一帧角度；未知状态不伪造传感器读数。
        if isClosed == true { return LidPose(angle: 0, source: .closed) }
        if let angle, (0...180).contains(angle) {
            return LidPose(angle: Double(angle), source: .sensor)
        }
        return LidPose(angle: 90, source: .unavailable)
    }

    var reading: String {
        switch source {
        case .sensor: return "\(Int(angle))°"
        case .closed: return "已合盖"
        case .unavailable: return "—"
        }
    }
}

enum LidGeometry {
    // 由原模型屏幕平面的方向测得，而非将原始打开姿态误当成 90°。
    static let restAngle = 109.90796

    static func rotation(for angle: Double) -> Double {
        let clamped = angle.isFinite ? max(0, min(180, angle)) : 90
        return (restAngle - clamped) * .pi / 180
    }
}
