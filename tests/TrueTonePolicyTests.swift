import Foundation

@main
struct TrueTonePolicyTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
        print("PASS: \(message)")
    }

    static func main() {
        check(TrueTonePolicy.desired(builtinVisible: false, externalVisible: 1, asleep: false) == false,
              "仅外屏显示时关闭原彩")
        check(TrueTonePolicy.desired(builtinVisible: true, externalVisible: 1, asleep: false) == true,
              "内屏和外屏同时显示时开启原彩")
        check(TrueTonePolicy.desired(builtinVisible: true, externalVisible: 0, asleep: false) == true,
              "仅内屏显示时开启原彩")
        check(TrueTonePolicy.desired(builtinVisible: false, externalVisible: 0, asleep: false) == nil,
              "显示器切换过程中暂不修改原彩")
        check(TrueTonePolicy.desired(builtinVisible: true, externalVisible: 1, asleep: true) == nil,
              "所有显示器息屏时暂不修改原彩")
        print("原彩策略测试全部通过")
    }
}
