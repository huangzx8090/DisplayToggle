import Foundation

/// 版本号比较。忽略 `v` 前缀和段数差异（1.9 == 1.9.0）；
/// 数字相同时，正式版高于预发布版（1.9.0 > 1.9.0-beta.2）。
enum Version {

    /// 拆成"数字核心 + 预发布后缀"
    static func split(_ raw: String) -> (core: [Int], prerelease: String?) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("v") { text.removeFirst() }
        text = String(text.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        let parts = text.split(maxSplits: 1, omittingEmptySubsequences: false,
                              whereSeparator: { $0 == "-" || $0 == "+" })
        let core = parts.first.map(String.init) ?? text
        let prerelease = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
        return (core.split(separator: ".").map { Int($0) ?? 0 }, prerelease)
    }

    static func components(_ raw: String) -> [Int] { split(raw).core }

    /// remote 是否比 local 新
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = split(remote)
        let b = split(local)
        for index in 0..<max(a.core.count, b.core.count) {
            let left = index < a.core.count ? a.core[index] : 0
            let right = index < b.core.count ? b.core[index] : 0
            if left != right { return left > right }
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil): return false
        case (nil, _): return true          // 正式版高于同号预发布版
        case (_, nil): return false
        case let (left?, right?):
            let lhs = left.split(separator: ".")
            let rhs = right.split(separator: ".")
            for index in 0..<min(lhs.count, rhs.count) {
                if lhs[index] == rhs[index] { continue }
                switch (Int(lhs[index]), Int(rhs[index])) {
                case let (a?, b?): return a > b
                case (nil, _?): return true
                case (_?, nil): return false
                case (nil, nil): return lhs[index] > rhs[index]
                }
            }
            return lhs.count > rhs.count
        }
    }
}
