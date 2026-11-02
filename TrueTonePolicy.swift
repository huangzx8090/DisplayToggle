import Foundation

enum TrueTonePolicy {
    // 所有屏幕暂时不可用时保留原状态，等待拔线恢复或唤醒完成。
    static func desired(builtinVisible: Bool, externalVisible: Int, asleep: Bool) -> Bool? {
        guard !asleep else { return nil }
        if builtinVisible { return true }
        if externalVisible > 0 { return false }
        return nil
    }
}
