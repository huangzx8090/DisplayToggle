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
    struct Point {
        let x: Double
        let y: Double
        let z: Double
    }

    static func lidPoint(x: Double, distance: Double, angle: Double,
                         inset: Double = 0) -> Point {
        let radians = max(0, min(180, angle)) * .pi / 180
        // 铰链沿 x 轴：0° 与底座重合，90° 竖直，超过90°向后展开。
        return Point(x: x,
                     y: distance * cos(radians) + inset * sin(radians),
                     z: distance * sin(radians) - inset * cos(radians))
    }

    static func project(_ point: Point, size: CGSize) -> CGPoint {
        let scale = min(size.width / 350, size.height / 240)
        return CGPoint(x: size.width * 0.58 + (point.x * 0.88 - point.y * 0.46) * scale,
                       y: size.height * 0.72 + (point.x * 0.06 + point.y * 0.29 - point.z * 0.94) * scale)
    }
}
