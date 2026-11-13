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

        let flat = LidGeometry.lidPoint(x: 25, distance: 100, angle: 0)
        let upright = LidGeometry.lidPoint(x: 25, distance: 100, angle: 90)
        let backward = LidGeometry.lidPoint(x: 25, distance: 100, angle: 135)
        expect(near(flat.y, 100) && near(flat.z, 0), "零度盖板与底座重合")
        expect(near(upright.y, 0) && near(upright.z, 100), "九十度盖板竖直")
        expect(backward.y < 0 && backward.z > 0, "大于九十度正确向后展开")
        for angle in [0.0, 30, 90, 135, 180] {
            let hinge = LidGeometry.lidPoint(x: 25, distance: 0, angle: angle)
            expect(near(hinge.x, 25) && near(hinge.y, 0) && near(hinge.z, 0),
                   "旋转过程中铰链位置不漂移")
        }

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
