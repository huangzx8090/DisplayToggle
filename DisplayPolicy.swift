enum ExternalDisplayMode: String, CaseIterable {
    case angle
    case externalOnly
    case manual

    static func migrate(angle: Bool?, autoOff: Bool?) -> ExternalDisplayMode {
        if angle ?? true { return .angle }
        if autoOff ?? true { return .externalOnly }
        return .manual
    }

    var title: String {
        switch self {
        case .angle: return "按开盖角度切换"
        case .externalOnly: return "接外屏后关闭内屏"
        case .manual: return "不自动切换"
        }
    }
}

enum DisplayPriority {
    static func forceOnWhileClosed(keepOn: Bool, isClosed: Bool) -> Bool {
        keepOn && isClosed
    }
}

struct DisplayActivity {
    let builtinActive: Bool
    let externalOnline: Int
    let externalActive: Int
    let screensSleeping: Bool
    let physicalDisplaysAsleep: Bool

    // 仅内屏时也必须尊重息屏；虚拟屏已在物理显示器采样时排除。
    var asleep: Bool { screensSleeping || physicalDisplaysAsleep }

    func shouldRestoreBuiltin(autoRestore: Bool) -> Bool {
        !builtinActive && externalActive == 0 && !asleep && (externalOnline == 0 || autoRestore)
    }
}

/// 所有自动切换共用同一节流器，避免定时器和配置回调重复提交同一目标。
struct BuiltinConfigurationGate {
    enum Decision {
        case unchanged, apply, inFlight, coolingDown
    }

    private var inFlight = false
    private var lastTarget: Bool?
    private var nextAttempt: Double = 0
    private var retryDelay: Double = 2

    mutating func begin(enabled: Bool, currentEnabled: Bool, now: Double,
                        retryImmediately: Bool = false) -> Decision {
        guard !inFlight else { return .inFlight }
        if currentEnabled == enabled {
            retryDelay = 2
            return .unchanged
        }
        if !retryImmediately && lastTarget == enabled && now < nextAttempt {
            return .coolingDown
        }
        // 目标反转（例如拔线后救回内屏）不能被上一次关屏的退避阻塞。
        if lastTarget != enabled { retryDelay = 2 }
        lastTarget = enabled
        inFlight = true
        return .apply
    }

    mutating func finish(succeeded: Bool, now: Double) {
        precondition(inFlight)
        inFlight = false
        // 成功后也留出状态传播时间；失败按 2、4、8…秒退避，最多 30 秒。
        nextAttempt = now + (succeeded ? 2 : retryDelay)
        retryDelay = succeeded ? 2 : min(retryDelay * 2, 30)
    }
}
