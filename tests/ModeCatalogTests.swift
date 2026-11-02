import Foundation

@main
struct ModeCatalogTests {
    static func mode(_ id: UInt32, _ width: UInt32, _ height: UInt32, _ hz: Double,
                     _ scale: Float = 2, flags: UInt32 = 1, depth: UInt32 = 8,
                     approximate: Bool = false, backend: HiDPIBackend = .skyLight) -> HiDPIMode {
        HiDPIMode(number: id, flags: flags, width: width, height: height, depth: depth,
                  refresh: hz, refreshApproximate: approximate, density: scale, backend: backend)
    }

    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("FAIL: \(name)") }
        print("PASS: \(name)")
    }

    static func main() {
        let current = mode(1, 1920, 1080, 120)
        let modes = [
            current, mode(2, 1920, 1080, 60), mode(3, 1920, 1080, 144),
            mode(4, 1920, 1080, 59.95, backend: .coreGraphics),
            mode(5, 1920, 1080, 120, 1),
            mode(6, 1280, 960, 120), mode(7, 3440, 1440, 120),
            mode(8, 2560, 1440, 60), mode(9, 2560, 1440, 144),
            mode(10, 1280, 720, 120, flags: 0),
        ]
        let groups = ModeCatalog.group(modes, current: current)
        check(groups.hiDPI.contains { $0.width == 1280 && $0.height == 960 }, "保留 4:3 显示模式")
        check(groups.hiDPI.contains { $0.width == 3440 && $0.height == 1440 }, "保留超宽屏模式")
        check(!groups.hiDPI.contains { $0.number == 10 }, "过滤系统标记为无效的模式")
        check(groups.loDPI.contains { $0.number == 5 }, "同尺寸普通模式与 HiDPI 分开")
        check(groups.hiDPI.first { $0.width == 2560 }?.refresh == 144, "优先选择接近当前刷新率的模式")
        check(groups.refreshRates.map(\.refresh) == [144, 120, 60, 59.95], "列出当前模式全部刷新率并保留小数")
        check(groups.refreshRates.last?.refreshTitle == "59.95 Hz", "准确显示小数刷新率")
        check(mode(11, 1920, 1080, 60, approximate: true).refreshTitle == "约 60 Hz", "标注近似刷新率")
        check(!mode(12, 1920, 1080, 59.94).matches(mode(13, 1920, 1080, 60)), "区分 59.94 Hz 与 60 Hz")
        check(!mode(12, 1920, 1080, 59.94).matches(mode(12, 1920, 1080, 60)), "模式编号复用时仍检查刷新率")
        check(!mode(12, 1920, 1080, 59.94, approximate: true).matches(mode(13, 1920, 1080, 60)), "不同编号的相邻刷新率不可混同")
        let portrait = mode(20, 1440, 2560, 60)
        let portraitGroups = ModeCatalog.group([portrait, mode(21, 1080, 1920, 60)], current: portrait)
        check(portraitGroups.hiDPI.count == 2, "支持竖屏模式")
        print("模式目录测试全部通过")
    }
}
