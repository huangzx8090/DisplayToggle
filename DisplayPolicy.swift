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
