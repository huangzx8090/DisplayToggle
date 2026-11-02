import Foundation

enum HiDPIBackend: String, Codable {
    case skyLight
    case coreGraphics
}

struct HiDPIMode: Codable, Equatable {
    let number: UInt32
    let flags: UInt32
    let width: UInt32
    let height: UInt32
    let depth: UInt32
    let refresh: Double
    let refreshApproximate: Bool
    let density: Float
    let backend: HiDPIBackend

    var isHiDPI: Bool { density > 1.01 }
    var usable: Bool {
        flags & 1 != 0 && width > 0 && height > 0 && width <= 65535 && height <= 65535 &&
        refresh.isFinite && refresh >= 0 && density.isFinite && density >= 0.99 && density <= 4.0
    }
    var refreshTitle: String {
        guard refresh > 0 else { return "自动/未知" }
        let number = abs(refresh - refresh.rounded()) < 0.005
            ? String(Int(refresh.rounded())) : String(format: "%.2f", refresh)
        return "\(refreshApproximate ? "约 " : "")\(number) Hz"
    }
    var title: String { "\(width)×\(height) · \(refreshTitle)" }

    func matches(_ other: HiDPIMode) -> Bool {
        guard width == other.width, height == other.height,
              (depth == other.depth || depth == 0 || other.depth == 0),
              abs(density - other.density) < 0.01 else { return false }
        if backend == other.backend && number != other.number { return false }
        let tolerance = refreshApproximate || other.refreshApproximate ? 1.0 : 0.01
        return abs(refresh - other.refresh) < tolerance
    }
}

struct ModeGroups {
    let hiDPI: [HiDPIMode]
    let loDPI: [HiDPIMode]
    let refreshRates: [HiDPIMode]
}

enum ModeCatalog {
    static func group(_ modes: [HiDPIMode], current: HiDPIMode) -> ModeGroups {
        let valid = modes.filter(\.usable)
        func preferred(_ left: HiDPIMode, _ right: HiDPIMode) -> Bool {
            let leftCurrent = left.number == current.number && left.backend == current.backend
            let rightCurrent = right.number == current.number && right.backend == current.backend
            if leftCurrent != rightCurrent { return leftCurrent }
            let leftDepth = left.depth == current.depth ? 0 : 1
            let rightDepth = right.depth == current.depth ? 0 : 1
            if leftDepth != rightDepth { return leftDepth < rightDepth }
            let leftDiff = abs(left.refresh - current.refresh)
            let rightDiff = abs(right.refresh - current.refresh)
            if abs(leftDiff - rightDiff) > 0.001 { return leftDiff < rightDiff }
            if left.refreshApproximate != right.refreshApproximate { return !left.refreshApproximate }
            return left.number < right.number
        }
        func resolutions(_ hidpi: Bool) -> [HiDPIMode] {
            let groups = Dictionary(grouping: valid.filter { $0.isHiDPI == hidpi }) {
                "\($0.width)x\($0.height)"
            }
            return groups.values.compactMap { $0.sorted(by: preferred).first }.sorted {
                $0.width == $1.width ? $0.height > $1.height : $0.width > $1.width
            }
        }
        let sameSize = valid.filter {
            $0.width == current.width && $0.height == current.height &&
            abs($0.density - current.density) < 0.01
        }
        let rateGroups = Dictionary(grouping: sameSize) { Int(($0.refresh * 100).rounded()) }
        let rates = rateGroups.values.compactMap { $0.sorted(by: preferred).first }.sorted {
            if $0.refresh == $1.refresh { return $0.number < $1.number }
            return $0.refresh > $1.refresh
        }
        return ModeGroups(hiDPI: resolutions(true), loDPI: resolutions(false), refreshRates: rates)
    }
}
