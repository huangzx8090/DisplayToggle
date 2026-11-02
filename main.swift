import Cocoa
import CoreGraphics
import Foundation
import IOKit

// MARK: - 私有 SkyLight API（和原 displaytoggle 用的是同一个）

private let skyLightHandle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

private typealias SLSConfigureDisplayEnabledFn =
    @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, UInt32) -> CGError

private let s_SLSConfigureDisplayEnabled: SLSConfigureDisplayEnabledFn? = {
    guard let h = skyLightHandle, let sym = dlsym(h, "SLSConfigureDisplayEnabled") else { return nil }
    return unsafeBitCast(sym, to: SLSConfigureDisplayEnabledFn.self)
}()

private typealias SLSGetDisplayListFn =
    @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError

/// 能列出「已经被关掉」的显示器，这是能救回内屏的关键
private let s_SLSGetDisplayList: SLSGetDisplayListFn? = {
    guard let h = skyLightHandle, let sym = dlsym(h, "SLSGetDisplayList") else { return nil }
    return unsafeBitCast(sym, to: SLSGetDisplayListFn.self)
}()

// MARK: - 应用标识与目录

/// 应用标识。正常从 Info.plist 的 CFBundleIdentifier 读取；
/// 直接运行裸二进制时回退到构建脚本里的默认值。
let appBundleID = Bundle.main.bundleIdentifier ?? "com.github.huangzx.displaytoggle"

/// 本应用的私有数据目录（键盘背光恢复记录、手动覆盖、各种预览缓存）。
let appCacheDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/\(appBundleID)", isDirectory: true)

// MARK: - 日志（常驻写文件，出问题后可以直接查）

let debugLogging = ProcessInfo.processInfo.environment["DT_DEBUG"] != nil
/// 开发模式：解锁伪造外接屏 / 合盖状态 / 盖子角度等测试钩子，避免误触发影响真实行为。
let devMode = ProcessInfo.processInfo.environment["DT_DEV"] != nil

let dtLogURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/DisplayToggle.log")
private let dtLogQueue = DispatchQueue(label: "\(appBundleID).log")
private let dtStamp: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func dtlog(_ message: @autoclosure () -> String) {
    let line = dtStamp.string(from: Date()) + " " + message() + "\n"
    if debugLogging {
        FileHandle.standardError.write(Data(line.utf8))
    }
    guard let data = line.data(using: .utf8) else { return }
    dtLogQueue.async {
        let fm = FileManager.default
        try? fm.createDirectory(at: dtLogURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if let attrs = try? fm.attributesOfItem(atPath: dtLogURL.path),
           let size = attrs[.size] as? Int, size > 512_000 {
            try? fm.removeItem(at: dtLogURL)
        }
        if let handle = try? FileHandle(forWritingTo: dtLogURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: dtLogURL)
        }
    }
}

func dtFlushLog() {
    dtLogQueue.sync {}
}

// MARK: - 显示器操作

enum DisplayService {

    private static let cacheKey = "cachedBuiltinDisplayID"

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// 系统已知的全部显示器（含被关掉的、睡眠中的）
    static func allDisplays() -> [CGDirectDisplayID] {
        if let sls = s_SLSGetDisplayList {
            var count: UInt32 = 0
            guard sls(0, nil, &count) == .success, count > 0 else { return onlineDisplays() }
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            guard sls(count, &ids, &count) == .success else { return onlineDisplays() }
            return Array(ids.prefix(Int(count)))
        }
        return onlineDisplays()
    }

    /// 内屏 ID。内屏被关掉后会从 online/active 列表里消失，所以走 allDisplays + 缓存兜底。
    static func builtinDisplayID() -> CGDirectDisplayID? {
        if let id = allDisplays().first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            UserDefaults.standard.set(Int(id), forKey: cacheKey)
            return id
        }
        if let id = activeDisplays().first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            UserDefaults.standard.set(Int(id), forKey: cacheKey)
            return id
        }
        let cached = UserDefaults.standard.integer(forKey: cacheKey)
        return cached > 0 ? CGDirectDisplayID(cached) : nil
    }

    static func isBuiltinActive() -> Bool {
        activeDisplays().contains { CGDisplayIsBuiltin($0) != 0 }
    }

    /// 镜像从屏可能不在 active 列表，但仍显示镜像源的画面。
    static func isBuiltinVisible() -> Bool {
        onlineDisplays().contains { id in
            guard CGDisplayIsBuiltin(id) != 0, CGDisplayIsAsleep(id) == 0 else { return false }
            if CGDisplayIsActive(id) != 0 { return true }
            let source = CGDisplayMirrorsDisplay(id)
            return source != 0 && CGDisplayIsActive(source) != 0 && CGDisplayIsAsleep(source) == 0
        }
    }

    /// 只让有物理输出特征的在线外屏参与安全判定。镜像关系本身不能证明是虚拟屏。
    static func externalExclusionReason(_ id: CGDirectDisplayID) -> String? {
        if CGDisplayIsBuiltin(id) != 0 { return "builtin" }
        if CGDisplayIsOnline(id) == 0 { return "offline" }
        let bounds = CGDisplayBounds(id)
        if bounds.width <= 1 || bounds.height <= 1 { return "placeholder" }
        let vendor = CGDisplayVendorNumber(id)
        if vendor == 0 || vendor == 0x756E6B6E { return "unknown-or-virtual-vendor" }
        return nil
    }

    static func physicalExternalDisplays() -> [CGDirectDisplayID] {
        onlineDisplays().filter { externalExclusionReason($0) == nil }
    }

    /// online 包含睡眠中的物理外屏，不能把正常息屏当作拔线。
    static func externalCount() -> Int {
        physicalExternalDisplays().count
    }

    /// 物理镜像从屏可能不在 active 列表里，但仍然能显示镜像源的画面。
    static func activeExternalCount() -> Int {
        physicalExternalDisplays().filter {
            if CGDisplayIsActive($0) != 0 { return true }
            let source = CGDisplayMirrorsDisplay($0)
            return source != 0 && CGDisplayIsActive(source) != 0
        }.count
    }

    static func topologyDescription() -> String {
        let ids = Set(allDisplays() + onlineDisplays() + activeDisplays()).sorted()
        return ids.map { id in
            let bounds = CGDisplayBounds(id)
            return "id=\(id) builtin=\(CGDisplayIsBuiltin(id)) online=\(CGDisplayIsOnline(id)) active=\(CGDisplayIsActive(id)) asleep=\(CGDisplayIsAsleep(id)) size=\(Int(bounds.width))x\(Int(bounds.height)) vendor=\(CGDisplayVendorNumber(id)) model=\(CGDisplayModelNumber(id)) mirror=\(CGDisplayMirrorsDisplay(id)) excluded=\(externalExclusionReason(id) ?? "no")"
        }.joined(separator: "; ")
    }

    /// 所有在线显示器都在睡眠（= 系统息屏，不是拔线）
    static func screenAsleep() -> Bool {
        let online = onlineDisplays().filter {
            CGDisplayIsBuiltin($0) != 0 || externalExclusionReason($0) == nil
        }
        guard !online.isEmpty else { return false }
        return online.allSatisfy { CGDisplayIsAsleep($0) != 0 }
    }

    struct ToggleResult {
        var ok: Bool
        var message: String
    }

    /// enabled = true → 点亮内屏；false → 关闭内屏
    /// 内屏 ID 候选列表：SkyLight 列表 > UserDefaults 缓存 > 常见值 1
    private static func builtinCandidates() -> [CGDirectDisplayID] {
        var list: [CGDirectDisplayID] = []
        if let id = builtinDisplayID() { list.append(id) }
        let cached = UserDefaults.standard.integer(forKey: cacheKey)
        if cached > 0 { list.append(CGDirectDisplayID(cached)) }
        list.append(1)
        var seen = Set<CGDirectDisplayID>()
        return list.filter { seen.insert($0).inserted }
    }

    /// 用某个配置选项去实际执行一次开关
    private static func apply(_ api: SLSConfigureDisplayEnabledFn,
                              display: CGDirectDisplayID,
                              enabled: Bool) -> CGError {
        var config: CGDisplayConfigRef?
        let beginErr = CGBeginDisplayConfiguration(&config)
        guard beginErr == .success, let config else { return beginErr }
        let confErr = api(config, display, enabled ? 1 : 0)
        guard confErr == .success else {
            CGCancelDisplayConfiguration(config)
            return confErr
        }
        // 只修改当前登录会话；任何失败都不能回退到永久配置。
        let doneErr = CGCompleteDisplayConfiguration(config, CGConfigureOption(rawValue: 1))
        return doneErr
    }

    static func setBuiltin(enabled: Bool) -> ToggleResult {
        guard let api = s_SLSConfigureDisplayEnabled else {
            return ToggleResult(ok: false, message: "无法加载 SkyLight 私有接口")
        }
        if !enabled, activeExternalCount() == 0 {
            return ToggleResult(ok: false, message: "没有可用的物理外接显示器，拒绝关闭内屏")
        }
        if !enabled, DisplayPriority.forceOnWhileClosed(
            keepOn: UserDefaults.standard.bool(forKey: "allowBuiltinOnWhenLidClosed"),
            isClosed: Lid.state == .closed) {
            return ToggleResult(ok: false, message: "已开启「合盖时保持内屏点亮」，合盖时不能关闭内屏")
        }
        // 硬约束：合盖时一律拒绝点亮内屏（除非用户显式打开"合盖时保持内屏点亮"）
        if enabled, Lid.state == .closed,
           !UserDefaults.standard.bool(forKey: "allowBuiltinOnWhenLidClosed") {
            return ToggleResult(ok: false, message: "盖子合着，已阻止点亮内屏（菜单里可开启「合盖时保持内屏点亮」）")
        }
        // 幂等：已经是目标状态就直接返回，避免系统返回 kCGErrorFailure
        if isBuiltinActive() == enabled {
            return ToggleResult(ok: true, message: enabled ? "内屏已是点亮状态" : "内屏已是关闭状态")
        }

        var lastError: CGError = .failure
        for display in builtinCandidates() {
            // 每个候选都重查保护条件，避免重试期间发生插拔或合盖。
            if !enabled && CGDisplayIsBuiltin(display) == 0 {
                dtlog("setBuiltin id=\(display) 无法确认为内屏，拒绝关闭")
                continue
            }
            if enabled, Lid.state == .closed,
               !UserDefaults.standard.bool(forKey: "allowBuiltinOnWhenLidClosed") {
                return ToggleResult(ok: false, message: "盖子合着，已阻止点亮内屏")
            }
            if !enabled, activeExternalCount() == 0 {
                return ToggleResult(ok: false, message: "物理外接屏已断开，拒绝关闭内屏")
            }
            if !enabled, DisplayPriority.forceOnWhileClosed(
                keepOn: UserDefaults.standard.bool(forKey: "allowBuiltinOnWhenLidClosed"),
                isClosed: Lid.state == .closed) {
                return ToggleResult(ok: false, message: "已开启「合盖时保持内屏点亮」，合盖时不能关闭内屏")
            }
            let err = apply(api, display: display, enabled: enabled)
            guard err == .success else {
                dtlog("setBuiltin id=\(display) enabled=\(enabled) 失败 err=\(err.rawValue)")
                lastError = err
                continue
            }
            if isBuiltinActive() != enabled {
                dtlog("setBuiltin id=\(display) enabled=\(enabled) 调用成功但状态未生效")
                continue
            }
            UserDefaults.standard.set(Int(display), forKey: cacheKey)
            dtlog("setBuiltin id=\(display) enabled=\(enabled) 成功")
            return ToggleResult(ok: true, message: enabled ? "内屏已点亮" : "内屏已关闭")
        }
        return ToggleResult(ok: false, message: "切换内屏失败（错误码 \(lastError.rawValue)）")
    }

    static func setBuiltinFromUser(enabled: Bool) -> ToggleResult {
        let previous = ManualOverride.current
        // CLI 与菜单进程并行：先公布手动意图，再触发显示器重配置回调。
        ManualOverride.record(enabled: enabled)
        let result = setBuiltin(enabled: enabled)
        if !result.ok { ManualOverride.restore(previous) }
        return result
    }
}

/// 菜单和 CLI 共用同一份临时意图，避免另一个进程在下一轮轮询里立刻撤销手动操作。
enum ManualOverride {
    struct Value: Codable {
        let enabled: Bool
        let expires: Date
    }

    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/\(appBundleID)/manual-override.json")

    static var current: Value? {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Value.self, from: data),
              value.expires > Date() else { return nil }
        return value
    }

    static func record(enabled: Bool) {
        let value = Value(enabled: enabled, expires: Date().addingTimeInterval(300))
        restore(value)
        dtlog("manual-override enabled=\(enabled) duration=300s")
    }

    static func holdForPreview() {
        guard current == nil else { return }
        restore(Value(enabled: true, expires: Date().addingTimeInterval(30)))
        dtlog("manual-override 预览期间保持内屏 duration=30s")
    }

    static func restore(_ value: Value?) {
        guard let value else {
            clear()
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            dtlog("manual-override 保存失败: \(error)")
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - 盒盖状态

enum Lid {
    enum State: String {
        case open = "开"
        case closed = "合"
        case unknown = "未知"
    }

    /// 读不到时返回 .unknown；按约定只有明确合盖才阻止点亮。
    static var state: State {
        let realState = boolProperty("AppleClamshellState")
        // 调试钩子可以模拟合盖，但不能把真实合盖伪装成开盖，绕过底层保护。
        if realState == true { return .closed }
        // 调试用：DT_FAKE_LID=open/closed/unknown（也接受 开/合/未知），
        // 或 DT_FAKE_LID_FILE=/tmp/dt_lid（文件内容，可动态改，用来演练"合盖→开盖"）
        var fake = devMode ? (ProcessInfo.processInfo.environment["DT_FAKE_LID"] ?? "") : ""
        if devMode, let path = ProcessInfo.processInfo.environment["DT_FAKE_LID_FILE"],
           let text = try? String(contentsOfFile: path, encoding: .utf8) {
            fake = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !fake.isEmpty {
            switch fake.lowercased() {
            case "open", "开": return .open
            case "closed", "合": return .closed
            default: return .unknown
            }
        }
        guard let value = realState else { return .unknown }
        return value ? .closed : .open
    }

    static var isOpen: Bool { state == .open }
    static var isClosed: Bool { state == .closed }

    private static func boolProperty(_ key: String) -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let cf = IORegistryEntryCreateCFProperty(service, key as CFString,
                                                      kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        if let b = cf as? Bool { return b }
        if let n = cf as? NSNumber { return n.boolValue }
        return nil
    }
}

// MARK: - 开机自启（LaunchAgent）

enum LoginItem {
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(appBundleID).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ on: Bool) {
        let fm = FileManager.default
        if on {
            guard let exe = Bundle.main.executablePath else { return }
            let plist: [String: Any] = [
                "Label": appBundleID,
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive",
                "LimitLoadToSessionType": "Aqua",
            ]
            try? fm.createDirectory(at: plistURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                              format: .xml, options: 0) {
                try? data.write(to: plistURL)
            }
            // 只写文件，不用 launchctl load：load 会立刻再拉起一个实例（菜单栏出现两个图标）。
            // 登录时 launchd 会自己扫描 ~/Library/LaunchAgents，下次登录生效即可。
        } else {
            shell("/bin/launchctl", ["unload", plistURL.path])
            try? fm.removeItem(at: plistURL)
        }
    }

    static func removeAgent(at url: URL) {
        shell("/bin/launchctl", ["unload", url.path])
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    private static func shell(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}

// MARK: - 旧版本迁移

/// 一次性迁移。早期版本用 com.zixuan.displaytoggle 作为包标识，
/// 换标识后把偏好、缓存目录和开机启动项接过来，避免用户丢掉设置。
enum LegacyMigration {
    private static let legacyBundleID = "com.zixuan.displaytoggle"
    private static let markerKey = "didMigrateFromLegacyIdentifier"
    private static let preferenceKeys = [
        "autoRestoreWhenNoExternal", "autoOffWhenExternalConnected", "allowBuiltinOnWhenLidClosed",
        "autoTrueToneByBuiltin", "autoBuiltinByAngle", "builtinUseAngleThreshold",
        "externalDisplayMode", "cachedBuiltinDisplayID",
    ]

    static func runIfNeeded() {
        let fm = FileManager.default
        guard legacyBundleID != appBundleID, !UserDefaults.standard.bool(forKey: markerKey) else { return }
        UserDefaults.standard.set(true, forKey: markerKey)

        if let legacy = UserDefaults(suiteName: legacyBundleID) {
            for key in preferenceKeys where UserDefaults.standard.object(forKey: key) == nil {
                if let value = legacy.object(forKey: key) {
                    UserDefaults.standard.set(value, forKey: key)
                }
            }
        }

        let legacyCache = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/\(legacyBundleID)", isDirectory: true)
        if fm.fileExists(atPath: legacyCache.path) {
            try? fm.createDirectory(at: appCacheDir, withIntermediateDirectories: true)
            for name in (try? fm.contentsOfDirectory(atPath: legacyCache.path)) ?? []
            where !fm.fileExists(atPath: appCacheDir.appendingPathComponent(name).path) {
                try? fm.moveItem(at: legacyCache.appendingPathComponent(name),
                                 to: appCacheDir.appendingPathComponent(name))
            }
            try? fm.removeItem(at: legacyCache)
        }

        // 旧的开机启动项：卸掉旧 Label，按原意图生成新 Label（不立即加载）
        let legacyAgent = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(legacyBundleID).plist")
        if fm.fileExists(atPath: legacyAgent.path) {
            LoginItem.removeAgent(at: legacyAgent)
            LoginItem.setEnabled(true)
        }
    }
}

// MARK: - 菜单栏 App

/// 状态文字不响应点击，但保持正常对比度和无障碍文本。
final class StatusMenuItem: NSMenuItem {
    private let label: NSTextField

    init(_ text: String) {
        label = NSTextField(labelWithString: text)
        super.init(title: text, action: nil, keyEquivalent: "")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        label.frame = NSRect(x: 16, y: 2, width: 238, height: 20)
        label.font = NSFont.menuFont(ofSize: 0)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        container.addSubview(label)
        view = container
        isEnabled = false
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateText(_ text: String) {
        guard title != text else { return }
        title = text
        label.stringValue = text
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var timer: Timer?

    /// 用户意图：内屏应该处于关闭状态
    private var wantBuiltinOff = false
    /// 外接屏稳定存在的起始时间（用来防抖，避免插拔瞬间抖动）
    private var externalStableSince: Date?
    /// 上一次内屏 active 状态，用于检测状态变化
    private var lastBuiltinActive: Bool?
    /// 看门狗计时（内屏关着且没有可用外接屏时开始计时）
    private var watchdogSince: Date?
    private var lastLidState: Lid.State?
    private var lastSnapshot: String?
    private var lastTopology: String?
    private var screensSleeping = false
    private let hiDPIQueue = DispatchQueue(label: "\(appBundleID).hidpi", qos: .utility)
    private var hiDPISnapshots: [HiDPISnapshot] = []
    private var hiDPIRefreshWork: DispatchWorkItem?
    private var hiDPIGeneration = 0
    private var hiDPIBusy = false
    private var hiDPILoaded = false
    private let ddcQueue = DispatchQueue(label: "\(appBundleID).ddc", qos: .utility)
    private var ddcValues: [HiDPIDisplay: [DDCReading]] = [:]
    private var ddcDisplays: Set<HiDPIDisplay> = []
    private var ddcGeneration = 0
    private var ddcLoaded = false
    private var ddcReading = false
    private var ddcBusy: Set<HiDPIDisplay> = []
    private let trueToneQueue = DispatchQueue(label: "\(appBundleID).truetone", qos: .utility)
    private var trueToneTarget: Bool?
    private var trueToneTargetKnown = false
    private var trueToneStableSince: TimeInterval = 0
    private var trueToneNextCheck: TimeInterval = 0
    private var trueToneGeneration = 0
    private var trueToneInFlight = false
    private var trueToneStatus: TrueToneStatus?
    private let angleQueue = DispatchQueue(label: "\(appBundleID).angle", qos: .utility)
    private let angleReader = LidAngleReader()
    private var angleTimer: DispatchSourceTimer?
    private var anglePolicy = AnglePolicy()
    private var angleValue: Int?
    private var angleMode: LidUseMode?
    private var angleEverSeen = false
    private var angleProbeReturned = false
    private let angleProbeStarted = ProcessInfo.processInfo.systemUptime
    private var angleLastReading: TimeInterval?
    private var angleNextAttempt: TimeInterval = 0
    private var closedOverrideNextAttempt: TimeInterval = 0
    private var angleStatusItem: StatusMenuItem?
    private var lidStatusItem: StatusMenuItem?
    private var keyboardRequested = false
    private var keyboardStatus: KeyboardHoldStatus = .idle
    private lazy var keyboardHold = KeyboardHoldController { [weak self] status in
        guard let self, self.keyboardStatus != status else { return }
        self.keyboardStatus = status
        self.rebuildMenu()
    }

    private let kAutoRestore = "autoRestoreWhenNoExternal"
    private let kAutoOff = "autoOffWhenExternalConnected"
    private let kAllowLidClosed = "allowBuiltinOnWhenLidClosed"
    private let kAutoTrueTone = "autoTrueToneByBuiltin"
    private let kAutoAngle = "autoBuiltinByAngle"
    private let kAngleThreshold = "builtinUseAngleThreshold"
    private let kExternalMode = "externalDisplayMode"

    /// 合盖时是否允许点亮/保持内屏。默认 false：合盖时绝不动内屏，交回系统原生行为。
    private var allowBuiltinOnWhenLidClosed: Bool {
        get { UserDefaults.standard.bool(forKey: kAllowLidClosed) }
        set { UserDefaults.standard.set(newValue, forKey: kAllowLidClosed) }
    }

    /// 只有在“确实可以点亮内屏”的时候才允许自动恢复。
    /// 只有「确定合盖」才拦；读不到状态时按开盖处理——
    /// 黑屏（机器没法用）比“合盖时多亮一块屏”严重得多。
    private var mayLightUpBuiltin: Bool {
        Lid.state != .closed || allowBuiltinOnWhenLidClosed
    }

    /// 自测钩子（仅 DT_DEV）：存在 /tmp/dt_no_external 时假装没有外接屏，
    /// 用来在不拔线的情况下验证「拔线自动恢复」逻辑。
    private var simulatedNoExternal: Bool {
        devMode && FileManager.default.fileExists(atPath: "/tmp/dt_no_external")
    }

    private var externalDisplayCount: Int {
        simulatedNoExternal ? 0 : DisplayService.externalCount()
    }

    private var activeExternalDisplayCount: Int {
        simulatedNoExternal ? 0 : DisplayService.activeExternalCount()
    }

    private var autoRestore: Bool {
        get {
            if UserDefaults.standard.object(forKey: kAutoRestore) == nil { return true }
            return UserDefaults.standard.bool(forKey: kAutoRestore)
        }
        set { UserDefaults.standard.set(newValue, forKey: kAutoRestore) }
    }

    private var autoOffOnConnect: Bool {
        get {
            if UserDefaults.standard.object(forKey: kAutoOff) == nil { return true }
            return UserDefaults.standard.bool(forKey: kAutoOff)
        }
        set { UserDefaults.standard.set(newValue, forKey: kAutoOff) }
    }

    private var autoTrueTone: Bool {
        get {
            if UserDefaults.standard.object(forKey: kAutoTrueTone) == nil { return true }
            return UserDefaults.standard.bool(forKey: kAutoTrueTone)
        }
        set { UserDefaults.standard.set(newValue, forKey: kAutoTrueTone) }
    }

    private var autoAngle: Bool {
        get {
            if UserDefaults.standard.object(forKey: kAutoAngle) == nil { return true }
            return UserDefaults.standard.bool(forKey: kAutoAngle)
        }
        set { UserDefaults.standard.set(newValue, forKey: kAutoAngle) }
    }

    private var externalMode: ExternalDisplayMode {
        get {
            let preferences = UserDefaults.standard
            if let raw = preferences.string(forKey: kExternalMode) {
                return ExternalDisplayMode(rawValue: raw) ?? .manual
            }
            return ExternalDisplayMode.migrate(angle: preferences.object(forKey: kAutoAngle) as? Bool,
                                               autoOff: preferences.object(forKey: kAutoOff) as? Bool)
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: kExternalMode)
            autoAngle = newValue == .angle
            autoOffOnConnect = newValue == .externalOnly
        }
    }

    private var angleThreshold: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: kAngleThreshold)
            return (30...135).contains(stored) ? stored : 100
        }
        set { UserDefaults.standard.set(max(30, min(135, newValue)), forKey: kAngleThreshold) }
    }

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installSignalHandlers()
        setupStatusItem()
        // 启动时对齐真实状态
        wantBuiltinOff = !DisplayService.isBuiltinActive() && DisplayService.externalCount() > 0
        setupDisplayCallback()
        setupAngleMonitor()
        keyboardHold.recoverIfNeeded()

        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)

        scheduleHiDPIRefresh()
        rebuildMenu()

        // 启动后延迟静默检查更新（24 小时内只查一次），不打扰启动过程
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            Updater.autoCheckIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出时把内屏恢复回来，避免留下"关着内屏又没人管"的黑屏状态。
        // 但合盖时绝不点亮内屏——不然就成了"合着盖内屏却亮着"。
        restoreForShutdown()
    }

    private func restoreForShutdown() {
        keyboardHold.update(holding: false)
        if wantBuiltinOff && mayLightUpBuiltin { _ = DisplayService.setBuiltin(enabled: true) }
        let desired = TrueTonePolicy.desired(builtinVisible: DisplayService.isBuiltinVisible(),
                                              externalVisible: DisplayService.activeExternalCount(),
                                              asleep: DisplayService.screenAsleep())
        if autoTrueTone, let desired {
            trueToneQueue.sync { _ = TrueToneService.ensure(enabled: desired) }
        }
    }

    /// 被 SIGTERM / 注销 / launchctl 停止时也能恢复内屏
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.restoreForShutdown()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
        }
        rebuildMenu()
        refreshIcon()
    }

    private func setupDisplayCallback() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        dtlog("==== launch v\(version) lid=\(Lid.state.rawValue) builtin=\(DisplayService.isBuiltinActive()) ext=\(DisplayService.externalCount()) wantOff=\(wantBuiltinOff)")
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ display, flags, context in
            guard let context, !flags.contains(.beginConfigurationFlag) else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            // 回调中不修改配置；完成通知后回到主队列处理，移除事件立即触发重查。
            DispatchQueue.main.async {
                dtlog("display-change id=\(display) flags=\(flags.rawValue) removed=\(flags.contains(.removeFlag))")
                if flags.contains(.removeFlag) {
                    delegate.externalStableSince = nil
                }
                delegate.tick()
                if flags.contains(.addFlag) || flags.contains(.removeFlag) ||
                   flags.contains(.setModeFlag) || flags.contains(.mirrorFlag) ||
                   flags.contains(.unMirrorFlag) {
                    delegate.scheduleHiDPIRefresh()
                }
            }
        }, ctx)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.screensSleeping = true
            dtlog("显示器息屏")
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.screensSleeping = false
            dtlog("显示器唤醒")
            self?.tick()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.screensSleeping = false
            dtlog("系统唤醒")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.tick() }
        }
    }

    // MARK: 核心状态机

    private func angleStatusTitle() -> String {
        guard let angleValue else { return "📐 开盖角度：无法读取" }
        return "📐 开盖角度：\(angleValue)°"
    }

    private func lidStatusTitle(_ state: Lid.State) -> String {
        switch state {
        case .open: return "💻 盖子：已打开"
        case .closed: return "🔽 盖子：已合上"
        case .unknown: return "💻 盖子：无法读取"
        }
    }

    private func setupAngleMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: angleQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(600), leeway: .milliseconds(100))
        let reader = angleReader
        timer.setEventHandler { [weak self] in
            let value = reader.read()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let hadReading = self.angleEverSeen
                let previous = self.angleMode
                self.angleProbeReturned = true
                if value != nil {
                    self.angleEverSeen = true
                    self.angleLastReading = ProcessInfo.processInfo.systemUptime
                }
                self.angleValue = value
                self.angleMode = self.anglePolicy.update(angle: value, threshold: self.angleThreshold,
                                                          now: ProcessInfo.processInfo.systemUptime)
                self.angleStatusItem?.updateText(self.angleStatusTitle())
                if previous != self.angleMode || hadReading != self.angleEverSeen {
                    self.angleNextAttempt = 0
                    dtlog("lid-angle angle=\(value.map(String.init) ?? "unknown") mode=\(String(describing: self.angleMode)) threshold=\(self.angleThreshold)")
                    self.tick()
                }
            }
        }
        angleTimer = timer
        timer.resume()
    }

    private func tick() {
        if let last = angleLastReading, ProcessInfo.processInfo.systemUptime - last > 3, angleMode != nil {
            angleMode = anglePolicy.update(angle: nil, threshold: angleThreshold,
                                           now: ProcessInfo.processInfo.systemUptime)
            angleValue = nil
            angleStatusItem?.updateText(angleStatusTitle())
            dtlog("lid-angle 读取超时，暂停角度控制")
        }
        let extOnline = externalDisplayCount
        let extActive = activeExternalDisplayCount
        let builtinActive = DisplayService.isBuiltinActive()
        let lidState = Lid.state
        lidStatusItem?.updateText(lidStatusTitle(lidState))
        // 完全失去物理外屏时，系统可能把虚拟屏报告为睡眠；不能因此阻塞安全恢复。
        let asleep = (simulatedNoExternal || extOnline == 0)
            ? false : (screensSleeping || DisplayService.screenAsleep())
        var manual = ManualOverride.current
        if let manual { wantBuiltinOff = !manual.enabled }

        let topology = DisplayService.topologyDescription()
        if topology != lastTopology {
            dtlog("topology " + topology)
            lastTopology = topology
        }

        // 接管外部改动（比如用命令行关掉了内屏），保证保护逻辑始终生效
        if !builtinActive && extOnline > 0 && !wantBuiltinOff && manual == nil {
            wantBuiltinOff = true
        }

        let mode = externalMode
        let probingAngle = !angleEverSeen && (!angleProbeReturned || ProcessInfo.processInfo.systemUptime - angleProbeStarted < 5)
        let angleControls = mode == .angle && (angleEverSeen || probingAngle) && extOnline > 0 && extActive > 0 && !asleep
        let forceClosedOn = DisplayPriority.forceOnWhileClosed(keepOn: allowBuiltinOnWhenLidClosed,
                                                                isClosed: lidState == .closed)

        if forceClosedOn {
            // 显式开启时，合盖保持点亮优先于手动关闭及外屏自动切换。
            watchdogSince = nil
            externalStableSince = nil
            if manual?.enabled == false {
                ManualOverride.clear()
                manual = nil
            }
            wantBuiltinOff = false
            let now = ProcessInfo.processInfo.systemUptime
            if !builtinActive && !asleep && now >= closedOverrideNextAttempt {
                closedOverrideNextAttempt = now + 2
                let result = DisplayService.setBuiltin(enabled: true)
                dtlog("lid-override 合盖保持内屏点亮：\(result.message)")
            }
        } else {
            closedOverrideNextAttempt = 0
            // 拔掉全部物理外屏后持续重试；合盖时仍由底层保护决定是否允许点亮。
            if !builtinActive && extActive == 0 && !asleep && (extOnline == 0 || autoRestore) {
                if !mayLightUpBuiltin {
                    if watchdogSince == nil {
                        dtlog("watchdog 待命: 无可用外接屏但内屏关闭 (lid=\(lidState.rawValue) allowLidClosed=\(allowBuiltinOnWhenLidClosed))")
                    }
                    watchdogSince = watchdogSince ?? Date()
                } else {
                    if watchdogSince == nil {
                        dtlog("watchdog 触发: extActive=0 extOnline=\(extOnline) asleep=\(asleep) wantOff=\(wantBuiltinOff)")
                        watchdogSince = Date()
                    }
                    if Date().timeIntervalSince(watchdogSince!) >= 1.5 {
                        dtlog("watchdog 点亮内屏")
                        if DisplayService.setBuiltin(enabled: true).ok {
                            wantBuiltinOff = false
                            ManualOverride.clear()
                            manual = nil
                            watchdogSince = nil
                            flashIcon(symbol: "laptopcomputer")
                        } else {
                            watchdogSince = Date()
                        }
                    }
                }
            } else {
                watchdogSince = nil
            }

            if angleControls {
                externalStableSince = nil
                if manual == nil, let angleMode {
                    let now = ProcessInfo.processInfo.systemUptime
                    switch angleMode {
                    case .usingBuiltin:
                        if builtinActive {
                            wantBuiltinOff = false
                        } else if mayLightUpBuiltin && now >= angleNextAttempt {
                            angleNextAttempt = now + 2
                            let result = DisplayService.setBuiltin(enabled: true)
                            dtlog("lid-angle 打开内屏：\(result.message)")
                            if result.ok { wantBuiltinOff = false }
                        }
                    case .notUsingBuiltin:
                        if !builtinActive {
                            wantBuiltinOff = true
                        } else if now >= angleNextAttempt {
                            angleNextAttempt = now + 2
                            let result = DisplayService.setBuiltin(enabled: false)
                            dtlog("lid-angle 关闭内屏：\(result.message)")
                            if result.ok { wantBuiltinOff = true }
                        }
                    }
                } else if manual?.enabled == false && builtinActive {
                    _ = DisplayService.setBuiltin(enabled: false)
                }
            } else {
                if mode == .externalOnly && manual == nil && !wantBuiltinOff && extOnline > 0 && extActive > 0 && builtinActive && !asleep {
                    let now = Date()
                    if let since = externalStableSince {
                        if now.timeIntervalSince(since) > 1.0 {
                            dtlog("auto-off: 外接屏已稳定，关闭内屏")
                            if DisplayService.setBuiltin(enabled: false).ok {
                                wantBuiltinOff = true
                                externalStableSince = nil
                            }
                        }
                    } else {
                        externalStableSince = now
                    }
                } else {
                    externalStableSince = nil
                }
                if wantBuiltinOff && builtinActive && extActive > 0 &&
                    (mode == .externalOnly || manual?.enabled == false) {
                    _ = DisplayService.setBuiltin(enabled: false)
                }
            }
        }

        // 内屏没有在出画时（被关掉 / 合盖 / 只为外屏工作），键盘背光也没有意义。
        // 这里直接看"内屏有没有画面"，不再绑定具体的外屏策略：
        // 「接外屏后关闭内屏」「不自动切换下手动关内屏」「按角度切换」都会关键盘灯。
        let builtinVisible = DisplayService.isBuiltinVisible()
        var holdKeyboard = keyboardRequested
        if !asleep {
            // 合盖时内置键盘本来就不用，而且键盘设备会下线、拿不到控制权，
            // 此时保持"不接管"，避免每 15 秒重试一次并在菜单里报错。
            holdKeyboard = !forceClosedOn && manual?.enabled != true && !builtinVisible
                && lidState == .open
        }
        if holdKeyboard != keyboardRequested {
            keyboardRequested = holdKeyboard
            keyboardHold.update(holding: holdKeyboard)
        }

        updateTrueTone(builtinVisible: builtinVisible, externalVisible: extActive, asleep: asleep)

        // 开盖瞬间补做一次"上次遗留亮度"的恢复（合盖期间会推迟）
        if lastLidState != lidState {
            lastLidState = lidState
            if lidState == .open { keyboardHold.recoverIfNeeded() }
        }

        let snapshot = "extOnline=\(extOnline) extActive=\(extActive) builtin=\(builtinActive) lid=\(lidState.rawValue) asleep=\(asleep) wantOff=\(wantBuiltinOff) manual=\(manual.map { $0.enabled ? "on" : "off" } ?? "none")"
        if lastSnapshot != snapshot {
            dtlog("state " + snapshot)
            lastSnapshot = snapshot
        }

        if lastBuiltinActive != builtinActive {
            lastBuiltinActive = builtinActive
            refreshIcon()
            rebuildMenu()
        } else if menuExternalCount != extOnline || menuLid != lidState {
            rebuildMenu()
        }
    }

    private var menuExternalCount = -1
    private var menuLid: Lid.State?

    /// 等待拓扑稳定后在后台核对原彩，避免阻塞内屏恢复。
    private func updateTrueTone(builtinVisible: Bool, externalVisible: Int, asleep: Bool) {
        let desired = autoTrueTone
            ? TrueTonePolicy.desired(builtinVisible: builtinVisible, externalVisible: externalVisible, asleep: asleep)
            : nil
        let now = ProcessInfo.processInfo.systemUptime
        if !trueToneTargetKnown || desired != trueToneTarget {
            trueToneTarget = desired
            trueToneTargetKnown = true
            trueToneStableSince = now
            trueToneNextCheck = 0
            trueToneGeneration += 1
        }
        guard let desired, now - trueToneStableSince >= 0.8,
              now >= trueToneNextCheck, !trueToneInFlight else { return }
        trueToneInFlight = true
        trueToneNextCheck = now + 5
        let generation = trueToneGeneration
        let preferenceKey = kAutoTrueTone
        trueToneQueue.async { [weak self] in
            let preferences = UserDefaults.standard
            let enabled = preferences.object(forKey: preferenceKey) == nil || preferences.bool(forKey: preferenceKey)
            let noExternal = devMode && FileManager.default.fileExists(atPath: "/tmp/dt_no_external")
            let actual = TrueTonePolicy.desired(builtinVisible: DisplayService.isBuiltinVisible(),
                                                 externalVisible: noExternal ? 0 : DisplayService.activeExternalCount(),
                                                 asleep: DisplayService.screenAsleep())
            let result = enabled && actual == desired ? TrueToneService.ensure(enabled: desired) : nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.trueToneInFlight = false
                guard self.trueToneGeneration == generation, let result else {
                    self.trueToneNextCheck = 0
                    return
                }
                if result.changed || self.trueToneStatus != result.status {
                    dtlog("true-tone target=\(desired) status=\(result.status.title) changed=\(result.changed)")
                }
                if self.trueToneStatus != result.status {
                    self.trueToneStatus = result.status
                    self.rebuildMenu()
                }
            }
        }
    }

    /// 模式列表可能包含数百项，后台读取，避免阻塞拔线恢复的主线程。
    private func scheduleHiDPIRefresh() {
        hiDPIGeneration += 1
        let generation = hiDPIGeneration
        hiDPIRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let ids = DisplayService.physicalExternalDisplays().filter { CGDisplayIsActive($0) != 0 }
            var names: [CGDirectDisplayID: String] = [:]
            for screen in NSScreen.screens {
                if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                    names[id.uint32Value] = screen.localizedName
                }
            }
            let displayNames = names
            self.hiDPIQueue.async { [weak self] in
                let snapshots = ids.compactMap { id in
                    HiDPIService.snapshot(HiDPIDisplay(id), name: displayNames[id] ?? "外接显示器 \(id)")
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.hiDPIGeneration == generation else { return }
                    self.hiDPISnapshots = snapshots
                    self.hiDPILoaded = true
                    dtlog("hidpi catalog displays=\(snapshots.count) modes=\(snapshots.map { $0.hiDPI.count })")
                    self.scheduleDDCRefresh(displays: Set(snapshots.map(\.display)))
                    self.rebuildMenu()
                }
            }
        }
        hiDPIRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func scheduleDDCRefresh(displays: Set<HiDPIDisplay>) {
        guard displays != ddcDisplays || (!ddcLoaded && !ddcReading) else { return }
        ddcGeneration += 1
        let generation = ddcGeneration
        ddcDisplays = displays
        ddcLoaded = false
        ddcReading = true
        ddcValues = ddcValues.filter { displays.contains($0.key) }
        guard DDCService.availableOnPlatform else {
            ddcLoaded = true
            ddcReading = false
            return
        }
        ddcQueue.async { [weak self] in
            var values: [HiDPIDisplay: [DDCReading]] = [:]
            for display in displays { values[display] = DDCService.readAll(display) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.ddcGeneration == generation else { return }
                self.ddcValues = values
                self.ddcLoaded = true
                self.ddcReading = false
                dtlog("ddc catalog displays=\(values.count) controls=\(values.values.map(\.count))")
                self.rebuildMenu()
            }
        }
    }

    // MARK: 动作

    @objc private func refreshDDC() {
        ddcLoaded = false
        scheduleDDCRefresh(displays: Set(hiDPISnapshots.map(\.display)))
        rebuildMenu()
    }

    @objc private func adjustDDC(_ sender: DDCSlider) {
        guard let display = sender.display, let feature = sender.feature,
              !ddcBusy.contains(display) else { return }
        if feature.requiresBackup && Lid.state == .open && DisplayService.isBuiltinActive() {
            ManualOverride.holdForPreview()
        }
        let percent = sender.doubleValue
        ddcBusy.insert(display)
        ddcQueue.async { [weak self] in
            let result: DDCPreviewResult
            if feature.requiresBackup && !HiDPIService.hasSafeBackup(excluding: display) {
                result = DDCPreview.begin(display: display, feature: feature, percent: percent)
            } else {
                switch DDCService.set(display, feature: feature, percent: percent) {
                case .success(let actual): result = .unchanged(actual)
                case .failure(let error): result = .failure(error.message)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .unchanged(let actual), .preview(_, _, let actual):
                    var values = self.ddcValues[display] ?? []
                    values.removeAll { $0.feature == feature }
                    values.append(actual)
                    self.ddcValues[display] = values
                    dtlog("ddc set id=\(display.id) feature=\(feature.rawValue) actual=\(actual.current)/\(actual.maximum)")
                case .failure(let message):
                    self.showAlert(message)
                }
                if case .preview(let url, let transaction, _) = result {
                    self.confirmDDCPreview(url, transaction: transaction)
                }
                self.ddcBusy.remove(display)
                self.rebuildMenu()
            }
        }
    }

    private func confirmDDCPreview(_ url: URL, transaction: DDCTransaction) {
        let alert = NSAlert()
        alert.messageText = "保留新的\(transaction.feature.title)？"
        alert.informativeText = "当前没有其他可用屏幕；未及时确认时会自动尝试还原。"
        alert.addButton(withTitle: "保留")
        alert.addButton(withTitle: "还原")
        let remaining = max(0.1, transaction.deadlineUptime - ProcessInfo.processInfo.systemUptime + 0.3)
        let timer = Timer(timeInterval: remaining, repeats: false) { _ in
            if alert.window.isVisible {
                NSApp.stopModal(withCode: .alertSecondButtonReturn)
                alert.window.orderOut(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        timer.invalidate()
        if response == .alertFirstButtonReturn {
            if !DDCPreview.confirm(url) { showAlert("确认已超时，正在还原原硬件设置。") }
        } else {
            ddcQueue.async { [weak self] in
                let error = DDCPreview.restoreNow(url, transaction: transaction)
                DispatchQueue.main.async { [weak self] in
                    if let error, error != "自动还原已开始或预览已结束" {
                        self?.showAlert("未能自动还原：\(error)")
                    }
                    self?.refreshDDC()
                }
            }
        }
    }

    private func ddcMenuItem(_ reading: DDCReading, display: HiDPIDisplay) -> NSMenuItem {
        let item = NSMenuItem()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 42))
        let label = NSTextField(labelWithString: "\(reading.feature.title)：\(Int(reading.percent.rounded()))%")
        label.frame = NSRect(x: 14, y: 23, width: 240, height: 17)
        let slider = DDCSlider(frame: NSRect(x: 12, y: 2, width: 245, height: 20))
        slider.display = display
        slider.feature = reading.feature
        slider.minValue = 0
        slider.maxValue = 100
        slider.doubleValue = reading.percent
        slider.isContinuous = false
        slider.isEnabled = !ddcBusy.contains(display)
        slider.target = self
        slider.action = #selector(adjustDDC(_:))
        view.addSubview(label)
        view.addSubview(slider)
        item.view = view
        return item
    }

    @objc private func selectHiDPIMode(_ sender: NSMenuItem) {
        guard !hiDPIBusy, let selection = sender.representedObject as? HiDPISelection else { return }
        // 保持内屏作为预览期间的备用画面，独立于外屏的显示配置。
        if Lid.state == .open && DisplayService.isBuiltinActive() { ManualOverride.holdForPreview() }
        hiDPIBusy = true
        rebuildMenu()
        hiDPIQueue.async { [weak self] in
            let result = HiDPIService.beginPreview(display: selection.display, requested: selection.mode)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hiDPIBusy = false
                switch result {
                case .unchanged:
                    break
                case .failure(let message):
                    self.showAlert(message)
                case .preview(let url, let transaction):
                    self.confirmHiDPIPreview(url, transaction: transaction)
                }
                self.scheduleHiDPIRefresh()
                self.rebuildMenu()
            }
        }
    }

    private func confirmHiDPIPreview(_ url: URL, transaction: HiDPITransaction) {
        let alert = NSAlert()
        alert.messageText = "保留这个显示模式？"
        alert.informativeText = "\(transaction.target.width)×\(transaction.target.height)\(transaction.target.isHiDPI ? " HiDPI" : "")。\n未及时确认会自动还原。"
        alert.addButton(withTitle: "保留")
        alert.addButton(withTitle: "还原")
        let remaining = max(0.1, transaction.deadlineUptime - ProcessInfo.processInfo.systemUptime + 0.3)
        let timer = Timer(timeInterval: remaining, repeats: false) { _ in
            if alert.window.isVisible {
                NSApp.stopModal(withCode: .alertSecondButtonReturn)
                alert.window.orderOut(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        timer.invalidate()
        if response == .alertFirstButtonReturn {
            if !HiDPIService.confirm(url) { showAlert("确认已超时，正在还原原显示模式。") }
        } else {
            hiDPIQueue.async { [weak self] in
                let error = HiDPIService.restoreNow(url, transaction: transaction)
                DispatchQueue.main.async { [weak self] in
                    if let error, error != "自动还原已开始或预览已结束" {
                        self?.showAlert("未能自动还原：\(error)")
                    }
                    self?.scheduleHiDPIRefresh()
                }
            }
        }
    }

    @objc private func turnOff() {
        let r = DisplayService.setBuiltinFromUser(enabled: false)
        if r.ok {
            wantBuiltinOff = true
        } else {
            NSSound.beep()
            showAlert(r.message)
        }
        refreshIcon()
        rebuildMenu()
    }

    @objc private func turnOn() {
        let r = DisplayService.setBuiltinFromUser(enabled: true)
        if r.ok {
            wantBuiltinOff = false
        } else {
            NSSound.beep()
            showAlert(r.message)
        }
        refreshIcon()
        rebuildMenu()
    }

    @objc private func toggleAutoRestore(_ sender: NSMenuItem) {
        autoRestore.toggle()
        rebuildMenu()
    }

    @objc private func toggleAutoTrueTone(_ sender: NSMenuItem) {
        autoTrueTone.toggle()
        trueToneTargetKnown = false
        trueToneGeneration += 1
        trueToneStatus = nil
        rebuildMenu()
        tick()
    }

    @objc private func selectExternalMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let selected = ExternalDisplayMode(rawValue: raw) else { return }
        externalMode = selected
        if selected == .manual && ManualOverride.current == nil { wantBuiltinOff = false }
        externalStableSince = nil
        angleNextAttempt = 0
        rebuildMenu()
        tick()
    }

    @objc private func selectAngleThreshold(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSNumber else { return }
        angleThreshold = value.intValue
        anglePolicy.reset()
        angleMode = nil
        angleNextAttempt = 0
        rebuildMenu()
        tick()
    }

    @objc private func toggleAllowLidClosed(_ sender: NSMenuItem) {
        allowBuiltinOnWhenLidClosed.toggle()
        if !allowBuiltinOnWhenLidClosed && Lid.state == .closed &&
            DisplayService.isBuiltinActive() && DisplayService.activeExternalCount() > 0 {
            let result = DisplayService.setBuiltin(enabled: false)
            dtlog("lid-override 关闭合盖保持：\(result.message)")
            if result.ok { wantBuiltinOff = true }
        }
        rebuildMenu()
        tick()
    }

    @objc private func checkForUpdates() {
        Updater.check(interactive: true)
    }

    @objc private func openLog() {
        if !FileManager.default.fileExists(atPath: dtLogURL.path) {
            let a = NSAlert()
            a.messageText = "还没有日志"
            a.informativeText = "日志文件：\(dtLogURL.path)"
            a.runModal()
            return
        }
        NSWorkspace.shared.open(dtLogURL)
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        rebuildMenu()
    }

    private func showAlert(_ text: String) {
        let a = NSAlert()
        a.messageText = "DisplayToggle"
        a.informativeText = text
        a.alertStyle = .warning
        a.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // MARK: UI

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let builtinActive = DisplayService.isBuiltinActive()
        let name = builtinActive ? "laptopcomputer" : "laptopcomputer.slash"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        img?.isTemplate = true
        button.image = img
        button.toolTip = "内屏：\(builtinActive ? "开" : "关")｜盖子：\(Lid.state.rawValue)"
    }

    private var flashWork: DispatchWorkItem?
    private var signalSources: [DispatchSourceSignal] = []
    private func flashIcon(symbol: String) {
        flashWork?.cancel()
        guard let button = statusItem?.button else { return }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        img?.isTemplate = true
        button.image = img
        let work = DispatchWorkItem { [weak self] in self?.refreshIcon() }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func rebuildMenu() {
        let external = externalDisplayCount
        menuExternalCount = external
        let builtinActive = DisplayService.isBuiltinActive()
        let lidState = Lid.state
        menuLid = lidState

        let menu = NSMenu()

        let header = StatusMenuItem(builtinActive ? "🟢 内屏：已开启" : "⚫️ 内屏：已关闭")
        menu.addItem(header)

        let ext = StatusMenuItem(external == 0 ? "🖥️ 外接屏：未连接" : "🖥️ 外接屏：\(external) 台")
        menu.addItem(ext)

        let lid = StatusMenuItem(lidStatusTitle(lidState))
        menu.addItem(lid)
        lidStatusItem = lid

        let angle = StatusMenuItem(angleStatusTitle())
        menu.addItem(angle)
        angleStatusItem = angle

        menu.addItem(.separator())

        let off = NSMenuItem(title: "关闭内屏", action: #selector(turnOff), keyEquivalent: "d")
        off.target = self
        off.isEnabled = builtinActive && external > 0 &&
            !DisplayPriority.forceOnWhileClosed(keepOn: allowBuiltinOnWhenLidClosed, isClosed: lidState == .closed)
        menu.addItem(off)

        let on = NSMenuItem(title: "打开内屏", action: #selector(turnOn), keyEquivalent: "o")
        on.target = self
        on.isEnabled = !builtinActive
        menu.addItem(on)

        menu.addItem(.separator())

        let displayModes = NSMenuItem(title: "外接屏设置（分辨率、刷新率等）", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        displayMenu.autoenablesItems = false
        if !HiDPIService.isSupported {
            let item = NSMenuItem(title: "当前系统不支持读取显示模式", action: nil, keyEquivalent: "")
            item.isEnabled = false
            displayMenu.addItem(item)
        } else if hiDPISnapshots.isEmpty {
            let message = external == 0 ? "未检测到物理外接屏" : (hiDPILoaded ? "没有读取到可用显示模式" : "正在读取显示模式…")
            let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            item.isEnabled = false
            displayMenu.addItem(item)
        } else {
            for snapshot in hiDPISnapshots {
                let displayItem = NSMenuItem(title: "\(snapshot.name) · #\(snapshot.display.id)", action: nil, keyEquivalent: "")
                let modesMenu = NSMenu()
                modesMenu.autoenablesItems = false
                let label = "当前：\(snapshot.current.title)\(snapshot.current.isHiDPI ? " · HiDPI" : "")"
                let current = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                current.isEnabled = false
                modesMenu.addItem(current)
                if let native = snapshot.nativeSize {
                    let item = NSMenuItem(title: "原生：\(Int(native.width))×\(Int(native.height))", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    modesMenu.addItem(item)
                }
                if let size = snapshot.renderSize {
                    let item = NSMenuItem(title: "渲染：\(Int(size.width))×\(Int(size.height))", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    modesMenu.addItem(item)
                }
                if let inches = snapshot.estimatedDiagonal {
                    let item = NSMenuItem(title: String(format: "尺寸约 %.1f 英寸", inches), action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    modesMenu.addItem(item)
                }
                let identifiers = String(format: "厂商/型号：%04X / %04X", snapshot.display.vendor, snapshot.display.model)
                let identity = NSMenuItem(title: identifiers, action: nil, keyEquivalent: "")
                identity.isEnabled = false
                modesMenu.addItem(identity)
                if snapshot.rotation != 0 {
                    let item = NSMenuItem(title: "旋转：\(Int(snapshot.rotation))°", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    modesMenu.addItem(item)
                }
                let backupAvailable = HiDPIService.hasSafeBackup(excluding: snapshot.display)
                let hardware = ddcValues[snapshot.display] ?? []
                if !hardware.isEmpty {
                    modesMenu.addItem(.separator())
                    for feature in DDCFeature.allCases {
                        if let reading = hardware.first(where: { $0.feature == feature }) {
                            modesMenu.addItem(ddcMenuItem(reading, display: snapshot.display))
                        }
                    }
                } else {
                    let message = !DDCService.availableOnPlatform ? "此架构暂不支持 DDC" : (ddcLoaded ? "未检测到可读取的 DDC 控制" : "正在读取硬件控制…")
                    let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    modesMenu.addItem(item)
                }
                if DDCService.availableOnPlatform {
                    let refresh = NSMenuItem(title: "重新检测硬件控制", action: #selector(refreshDDC), keyEquivalent: "")
                    refresh.target = self
                    refresh.isEnabled = !ddcReading
                    modesMenu.addItem(refresh)
                }
                if snapshot.mirrored || !backupAvailable {
                    let reason = snapshot.mirrored ? "镜像状态暂不支持切换模式" : "单屏更改后请及时确认，超时将尝试还原"
                    let item = NSMenuItem(title: reason, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    modesMenu.addItem(item)
                }
                if !snapshot.canRestore {
                    let item = NSMenuItem(title: "当前系统无法确认还原通道，仅能查看模式", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    modesMenu.addItem(item)
                }
                for (title, modes, ratesOnly) in [("HiDPI（文字更清晰）", snapshot.hiDPI, false),
                                                  ("普通分辨率", snapshot.loDPI, false),
                                                  ("当前分辨率的刷新率", snapshot.refreshRates, true)] {
                    let group = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    let submenu = NSMenu()
                    submenu.autoenablesItems = false
                    if modes.isEmpty {
                        let empty = NSMenuItem(title: "没有可用模式", action: nil, keyEquivalent: "")
                        empty.isEnabled = false
                        submenu.addItem(empty)
                    }
                    for mode in modes {
                        let item = NSMenuItem(title: ratesOnly ? mode.refreshTitle : mode.title,
                                              action: #selector(selectHiDPIMode(_:)), keyEquivalent: "")
                        item.target = self
                        item.representedObject = HiDPISelection(display: snapshot.display, mode: mode)
                        item.state = mode.matches(snapshot.current) ? .on : .off
                        item.isEnabled = !hiDPIBusy && !snapshot.mirrored && snapshot.canRestore
                        submenu.addItem(item)
                    }
                    group.submenu = submenu
                    modesMenu.addItem(group)
                }
                displayItem.submenu = modesMenu
                displayMenu.addItem(displayItem)
            }
        }
        displayModes.submenu = displayMenu
        menu.addItem(displayModes)

        menu.addItem(.separator())

        let ar = NSMenuItem(title: "外接屏没画面时，自动打开内屏",
                            action: #selector(toggleAutoRestore(_:)), keyEquivalent: "")
        ar.target = self
        ar.state = autoRestore ? .on : .off
        ar.toolTip = "外接屏仍连接、没有可用画面且系统未息屏时，尝试打开内屏。拔掉全部外接屏后始终尝试恢复；合盖时遵循合盖设置。"
        menu.addItem(ar)

        let currentMode = externalMode
        let modeItem = NSMenuItem(title: "接外屏时：\(currentMode.title)", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        modeMenu.autoenablesItems = false
        for choice in ExternalDisplayMode.allCases {
            let item = NSMenuItem(title: choice.title, action: #selector(selectExternalMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.state = choice == currentMode ? .on : .off
            modeMenu.addItem(item)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        if currentMode == .angle {
            let threshold = NSMenuItem(title: "打开内屏的角度：\(angleThreshold)°", action: nil, keyEquivalent: "")
            threshold.toolTip = "角度达到设定值时打开内屏；低于设定值 5° 并稳定后关闭。"
            let thresholdMenu = NSMenu()
            thresholdMenu.autoenablesItems = false
            for value in stride(from: 30, through: 135, by: 5) {
                let item = NSMenuItem(title: "\(value)°", action: #selector(selectAngleThreshold(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = NSNumber(value: value)
                item.state = value == angleThreshold ? .on : .off
                thresholdMenu.addItem(item)
            }
            threshold.submenu = thresholdMenu
            menu.addItem(threshold)
        }
        if keyboardStatus != .idle {
            let text = keyboardStatus == .holding ? "键盘灯已关闭，内屏恢复显示后自动恢复" : "键盘灯控制暂不可用，或恢复尚未确认"
            let status = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }

        let trueTone = NSMenuItem(title: "自动切换原彩显示", action: #selector(toggleAutoTrueTone(_:)), keyEquivalent: "")
        trueTone.target = self
        trueTone.state = autoTrueTone ? .on : .off
        trueTone.toolTip = "内屏显示画面时开启原彩；只用外接屏时关闭。"
        menu.addItem(trueTone)
        if autoTrueTone {
            let status = NSMenuItem(title: "原彩显示：\(trueToneStatus?.title ?? "检测中")", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }

        menu.addItem(.separator())

        let lc = NSMenuItem(title: "合盖时保持内屏点亮",
                            action: #selector(toggleAllowLidClosed(_:)), keyEquivalent: "")
        lc.target = self
        lc.state = allowBuiltinOnWhenLidClosed ? .on : .off
        lc.toolTip = "开启后，合盖时优先点亮内屏；开盖后继续按选择的外屏使用方式切换。"
        menu.addItem(lc)

        menu.addItem(.separator())

        let li = NSMenuItem(title: "开机自动启动",
                            action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        li.target = self
        li.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(li)

        let update = NSMenuItem(title: "检查更新…（v\(Updater.currentVersion)）",
                                action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)

        let logItem = NSMenuItem(title: "查看日志", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 DisplayToggle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }
}

// MARK: - CLI 模式（和原来的 displaytoggle 参数一致）

func runCLI(_ args: [String]) -> Never {
    switch args[1].lowercased() {
    case "on":
        let r = DisplayService.setBuiltinFromUser(enabled: true)
        print(r.message)
        exit(r.ok ? 0 : 1)
    case "off":
        let r = DisplayService.setBuiltinFromUser(enabled: false)
        print(r.message)
        exit(r.ok ? 0 : 1)
    case "toggle":
        if DisplayService.isBuiltinActive() {
            let r = DisplayService.setBuiltinFromUser(enabled: false)
            print(r.message)
            exit(r.ok ? 0 : 1)
        } else {
            let r = DisplayService.setBuiltinFromUser(enabled: true)
            print(r.message)
            exit(r.ok ? 0 : 1)
        }
    case "status":
        print("Built-in display: \(DisplayService.isBuiltinActive() ? "ON" : "OFF")")
        print("External displays: \(DisplayService.externalCount())")
        print("Lid: \(Lid.state.rawValue) (AppleClamshellState)")
        exit(0)
    case "lid":
        print("Lid: \(Lid.state.rawValue)")
        exit(0)
    case "lid-angle":
        let reader = LidAngleReader()
        if let angle = reader.read() { print("开盖角度：\(angle)°") }
        else { print("开盖角度：不可用") }
        let stored = UserDefaults.standard.integer(forKey: "builtinUseAngleThreshold")
        print("使用内屏的角度阈值：\((30...135).contains(stored) ? stored : 100)°")
        exit(0)
    case "true-tone":
        print("原彩显示：\(TrueToneService.read().title)")
        let key = "autoTrueToneByBuiltin"
        let auto = UserDefaults.standard.object(forKey: key) == nil || UserDefaults.standard.bool(forKey: key)
        print("按显示器状态自动切换：\(auto ? "开" : "关")")
        exit(0)
    case "diagnose":
        print(DisplayService.topologyDescription())
        if let manual = ManualOverride.current {
            print("Manual override: \(manual.enabled ? "ON" : "OFF"), expires: \(manual.expires)")
        }
        exit(0)
    case "hidpi-list":
        for id in DisplayService.physicalExternalDisplays() {
            guard let snapshot = HiDPIService.snapshot(HiDPIDisplay(id), name: "外接屏 \(id)") else { continue }
            print("外接屏 \(id)：当前 \(snapshot.current.title)\(snapshot.current.isHiDPI ? " HiDPI" : "")")
            if let native = snapshot.nativeSize { print("  原生：\(Int(native.width))×\(Int(native.height))") }
            if let size = snapshot.renderSize { print("  渲染：\(Int(size.width))×\(Int(size.height))") }
            if let inches = snapshot.estimatedDiagonal { print(String(format: "  尺寸约 %.1f 英寸", inches)) }
            for mode in snapshot.hiDPI { print("  HiDPI \(mode.title)\(mode.matches(snapshot.current) ? " [当前]" : "")") }
            for mode in snapshot.loDPI { print("  普通 \(mode.title)\(mode.matches(snapshot.current) ? " [当前]" : "")") }
            print("  当前分辨率的刷新率：\(snapshot.refreshRates.map(\.refreshTitle).joined(separator: "、"))")
        }
        exit(0)
    case "ddc-status":
        guard DDCService.availableOnPlatform else {
            print("当前架构或系统暂不支持 DDC 硬件控制")
            exit(1)
        }
        for id in DisplayService.physicalExternalDisplays() {
            let values = DDCService.readAll(HiDPIDisplay(id))
            print("外接屏 \(id)：\(values.isEmpty ? "未检测到可读取的 DDC 控制" : "")")
            for value in values {
                print("  \(value.feature.title)：\(value.current)/\(value.maximum)")
            }
        }
        exit(0)
    case "--hidpi-rollback-worker":
        guard args.count == 3 else { exit(2) }
        HiDPIService.runRollbackWorker(path: args[2])
    case "--ddc-rollback-worker":
        guard args.count == 3 else { exit(2) }
        DDCPreview.runWorker(path: args[2])
    case "--keyboard-backlight-worker":
        guard args.count == 2 else { exit(2) }
        KeyboardBacklightWorker.run()
    case "--keyboard-backlight-recover":
        guard args.count == 2 else { exit(2) }
        KeyboardBacklightWorker.recover()
    default:
        print("Usage: DisplayToggle [on|off|toggle|status|lid|lid-angle|true-tone|diagnose|hidpi-list|ddc-status]")
        print("  不带参数运行则启动菜单栏应用")
        exit(2)
    }
}

LegacyMigration.runIfNeeded()

let arguments = CommandLine.arguments
if arguments.count > 1 {
    runCLI(arguments)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
