import Foundation

enum LidUseMode: Equatable {
    case usingBuiltin
    case notUsingBuiltin
}

/// 阈值两侧保留 5° 回差，并要求状态稳定，避免手抖时反复开关屏幕。
struct AnglePolicy {
    private(set) var mode: LidUseMode?
    private var candidate: LidUseMode?
    private var candidateSince: TimeInterval = 0
    private var lastReading: TimeInterval?

    mutating func reset() {
        mode = nil
        candidate = nil
        lastReading = nil
    }

    mutating func update(angle: Int?, threshold: Int, now: TimeInterval) -> LidUseMode? {
        guard let angle, (0...180).contains(angle) else {
            if let lastReading, now - lastReading > 3 { reset() }
            return mode
        }
        lastReading = now
        let next: LidUseMode
        if angle >= threshold { next = .usingBuiltin }
        else if angle <= threshold - 5 { next = .notUsingBuiltin }
        else { next = mode ?? .notUsingBuiltin }
        if next == mode { candidate = nil; return mode }
        if candidate != next { candidate = next; candidateSince = now; return mode }
        if now - candidateSince >= 0.8 { mode = next; candidate = nil }
        return mode
    }
}
