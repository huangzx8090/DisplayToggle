@main
struct DisplayPolicyTests {
    static func main() {
        precondition(ExternalDisplayMode.migrate(angle: nil, autoOff: nil) == .angle)
        precondition(ExternalDisplayMode.migrate(angle: true, autoOff: true) == .angle)
        precondition(ExternalDisplayMode.migrate(angle: true, autoOff: false) == .angle)
        precondition(ExternalDisplayMode.migrate(angle: false, autoOff: true) == .externalOnly)
        precondition(ExternalDisplayMode.migrate(angle: false, autoOff: false) == .manual)
        precondition(DisplayPriority.forceOnWhileClosed(keepOn: true, isClosed: true))
        precondition(!DisplayPriority.forceOnWhileClosed(keepOn: false, isClosed: true))
        precondition(!DisplayPriority.forceOnWhileClosed(keepOn: true, isClosed: false))
        precondition(!DisplayPriority.forceOnWhileClosed(keepOn: false, isClosed: false))
        testSleepAndRestore()
        testConfigurationGate()
        print("外屏模式迁移与合盖优先级测试全部通过")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        precondition(condition(), name)
        print("PASS: \(name)")
    }

    static func testSleepAndRestore() {
        func activity(builtin: Bool = false, online: Int = 0, active: Int = 0,
                      notification: Bool = false, physical: Bool = false) -> DisplayActivity {
            DisplayActivity(builtinActive: builtin, externalOnline: online, externalActive: active,
                            screensSleeping: notification, physicalDisplaysAsleep: physical)
        }

        check(!activity(notification: true).shouldRestoreBuiltin(autoRestore: true),
              "仅内屏收到息屏通知时不触发看门狗")
        check(!activity(physical: true).shouldRestoreBuiltin(autoRestore: true),
              "仅内屏被系统报告为睡眠时不提交点亮配置")
        check(activity().shouldRestoreBuiltin(autoRestore: false),
              "拔掉全部外屏且系统清醒时仍强制恢复内屏")
        check(!activity(builtin: true).shouldRestoreBuiltin(autoRestore: true),
              "仅内屏已亮时不提交配置")
        check(!activity(online: 1, active: 1).shouldRestoreBuiltin(autoRestore: true),
              "物理外屏正常出画时不触发恢复")
        check(!activity(online: 1).shouldRestoreBuiltin(autoRestore: false),
              "尊重外屏无画面时的可选恢复设置")
        check(activity(online: 1).shouldRestoreBuiltin(autoRestore: true),
              "外屏无画面且开启安全网时恢复内屏")
        check(!activity(online: 1, physical: true).shouldRestoreBuiltin(autoRestore: true),
              "物理外屏息屏时不误判成拔线")
    }

    static func testConfigurationGate() {
        var gate = BuiltinConfigurationGate()
        var commits = 0
        for tick in 0...405 {
            if gate.begin(enabled: true, currentEnabled: true, now: Double(tick) * 0.4) == .apply {
                commits += 1
                gate.finish(succeeded: true, now: Double(tick) * 0.4)
            }
        }
        check(commits == 0, "162 秒仅内屏稳定状态不提交任何配置")
        check(gate.begin(enabled: false, currentEnabled: true, now: 200) == .apply,
              "真实状态需要改变时允许首次配置")
        check(gate.begin(enabled: false, currentEnabled: true, now: 201) == .inFlight,
              "配置完成前的回调不能重入提交")
        check(gate.begin(enabled: true, currentEnabled: false, now: 201,
                         retryImmediately: true) == .inFlight,
              "手动请求和相反目标也不能重入配置")
        gate.finish(succeeded: true, now: 202)
        check(gate.begin(enabled: false, currentEnabled: true, now: 202.4) == .coolingDown,
              "配置成功但状态短暂滞后时不重复提交")
        check(gate.begin(enabled: false, currentEnabled: false, now: 203) == .unchanged,
              "收到目标状态确认时直接返回")
        check(gate.begin(enabled: false, currentEnabled: true, now: 203.4) == .coolingDown,
              "短暂状态确认不会清除传播等待期")
        check(gate.begin(enabled: true, currentEnabled: false, now: 203.5) == .apply,
              "拔线恢复等相反目标立即生效")
        gate.finish(succeeded: false, now: 203.5)
        check(gate.begin(enabled: true, currentEnabled: false, now: 204) == .coolingDown,
              "失败后不跟随每次定时器重试")
        check(gate.begin(enabled: true, currentEnabled: false, now: 204,
                         retryImmediately: true) == .apply,
              "显式手动操作可立即重试")
        gate.finish(succeeded: true, now: 204)

        var failingGate = BuiltinConfigurationGate()
        var attempts: [Double] = []
        for second in 0...162 {
            // 同一时刻模拟多次配置回调，不能绕过退避。
            for _ in 0..<10 {
                if failingGate.begin(enabled: true, currentEnabled: false, now: Double(second)) == .apply {
                    attempts.append(Double(second))
                    failingGate.finish(succeeded: false, now: Double(second))
                }
            }
        }
        check(attempts == [0, 2, 6, 14, 30, 60, 90, 120, 150],
              "持续失败按 2、4、8、16、30 秒退避并保留重试")
    }
}
