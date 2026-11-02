import Foundation

@main
struct AnglePolicyTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
        print("PASS: \(message)")
    }

    static func main() {
        var policy = AnglePolicy()
        check(policy.update(angle: 85, threshold: 100, now: 0) == nil, "角度未稳定时不操作")
        check(policy.update(angle: 85, threshold: 100, now: 1) == .notUsingBuiltin, "低于阈值判定不使用内屏")
        check(policy.update(angle: 101, threshold: 100, now: 2) == .notUsingBuiltin, "短暂跨过阈值不立即切换")
        check(policy.update(angle: 101, threshold: 100, now: 3) == .usingBuiltin, "高于阈值稳定后判定使用内屏")
        check(policy.update(angle: 97, threshold: 100, now: 4) == .usingBuiltin, "回差区间保持原状态")
        check(policy.update(angle: 94, threshold: 100, now: 5) == .usingBuiltin, "降低角度先等待稳定")
        check(policy.update(angle: 94, threshold: 100, now: 6) == .notUsingBuiltin, "低于回差并稳定后切换")
        check(policy.update(angle: nil, threshold: 100, now: 8) == .notUsingBuiltin, "短暂读取失败保持状态")
        check(policy.update(angle: nil, threshold: 100, now: 10) == nil, "角度长时间不可用时暂停判断")
        policy.reset()
        check(policy.update(angle: 110, threshold: 100, now: 11) == nil, "重置阈值后重新等待稳定")
        check(policy.update(angle: 110, threshold: 100, now: 12) == .usingBuiltin, "重置后识别新状态")
        print("开盖角度策略测试全部通过")
    }
}
