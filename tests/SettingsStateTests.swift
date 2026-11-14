import Foundation

@main
struct SettingsStateTests {
    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        print("PASS: \(message)")
    }

    static func near(_ left: Double, _ right: Double) -> Bool {
        abs(left - right) < 0.0001
    }

    static func main() {
        let closed = LidPose.resolve(angle: 120, isClosed: true)
        expect(closed.angle == 0 && closed.source == .closed && closed.reading == "已合盖",
               "合盖状态覆盖滞后角度，且不伪装为传感器零度读数")
        let live = LidPose.resolve(angle: 123, isClosed: false)
        expect(live.angle == 123 && live.reading == "123°" && live.source == .sensor,
               "有效角度直接驱动示意")
        for angle in [nil, -1, 181] as [Int?] {
            let pose = LidPose.resolve(angle: angle, isClosed: nil)
            expect(pose.source == .unavailable && pose.reading == "—",
                   "缺失或越界角度不显示伪造读数")
        }

        // 将原模型的盖板方向绕实际支点旋转，检查打开角度而不是复述公式。
        let rest = LidGeometry.restAngle * .pi / 180
        for angle in [0.0, 30, 90, 135, 180] {
            let rotation = LidGeometry.rotation(for: angle)
            let y = sin(rest) * cos(rotation) - cos(rest) * sin(rotation)
            let z = sin(rest) * sin(rotation) + cos(rest) * cos(rotation)
            expect(near(y, sin(angle * .pi / 180)) && near(z, cos(angle * .pi / 180)),
                   "原素材旋转后开盖角度为 \(Int(angle))°")
        }
        expect(near(LidGeometry.rotation(for: -20), LidGeometry.rotation(for: 0)) &&
               near(LidGeometry.rotation(for: 220), LidGeometry.rotation(for: 180)), "模型旋转限制在物理角度范围")

        var state = DisplaySettingsState()
        state.externalCount = 1
        expect(!state.canToggleBuiltin, "在线但没有出画的外屏不能让设置窗口关闭内屏")
        state.activeExternalCount = 1
        expect(state.canToggleBuiltin, "有可用外屏画面时允许手动关闭")
        state.lidClosed = true
        state.keepOnWhenClosed = true
        expect(!state.canToggleBuiltin, "合盖保持开启时不能从设置窗口关闭内屏")
        state.builtinActive = false
        state.keepOnWhenClosed = false
        expect(!state.canToggleBuiltin, "默认合盖时不能从设置窗口点亮内屏")
        state.keepOnWhenClosed = true
        expect(state.canToggleBuiltin, "显式开启合盖保持后允许点亮")
        print("设置状态与开合几何测试全部通过")
    }
}
