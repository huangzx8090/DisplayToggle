import AppKit
import CoreGraphics
import Darwin
import Foundation

// SkyLight 模式记录布局参考 https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/screen/libscreen.m
// 并在本机与 BetterDisplay 的只读结果交叉核对。
private typealias ModeCountFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>?) -> Void
private typealias ModeDescriptionFn = @convention(c) (CGDirectDisplayID, Int32, UnsafeMutableRawPointer?, Int32) -> Void
private typealias CurrentModeFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>?) -> Int32
private typealias ConfigureModeFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Int32) -> CGError

private let modeFramework = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
private func modeSymbol<T>(_ name: String, as type: T.Type) -> T? {
    guard let modeFramework, let symbol = dlsym(modeFramework, name) else { return nil }
    return unsafeBitCast(symbol, to: type)
}
private let getModeCount = modeSymbol("CGSGetNumberOfDisplayModes", as: ModeCountFn.self)
private let getModeDescription = modeSymbol("CGSGetDisplayModeDescriptionOfLength", as: ModeDescriptionFn.self)
private let getCurrentMode = modeSymbol("CGSGetCurrentDisplayMode", as: CurrentModeFn.self)
private let configureMode = modeSymbol("CGSConfigureDisplayMode", as: ConfigureModeFn.self)

struct HiDPIDisplay: Codable, Hashable {
    let id: CGDirectDisplayID
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32

    init(_ id: CGDirectDisplayID) {
        self.id = id
        vendor = CGDisplayVendorNumber(id)
        model = CGDisplayModelNumber(id)
        serial = CGDisplaySerialNumber(id)
    }

    var isAvailable: Bool {
        CGDisplayIsOnline(id) != 0 && CGDisplayIsBuiltin(id) == 0 &&
        DisplayService.externalExclusionReason(id) == nil &&
        CGDisplayVendorNumber(id) == vendor && CGDisplayModelNumber(id) == model &&
        CGDisplaySerialNumber(id) == serial
    }
}

struct HiDPISnapshot {
    let display: HiDPIDisplay
    let name: String
    let mirrored: Bool
    let current: HiDPIMode
    let canRestore: Bool
    let hiDPI: [HiDPIMode]
    let loDPI: [HiDPIMode]
    let refreshRates: [HiDPIMode]
    let nativeSize: CGSize?
    let renderSize: CGSize?
    let estimatedDiagonal: Double?
    let rotation: Double
}

final class HiDPISelection: NSObject {
    let display: HiDPIDisplay
    let mode: HiDPIMode
    init(display: HiDPIDisplay, mode: HiDPIMode) {
        self.display = display
        self.mode = mode
    }
}

struct HiDPITransaction: Codable {
    let display: HiDPIDisplay
    let original: HiDPIMode
    let target: HiDPIMode
    let deadlineUptime: TimeInterval
}

enum HiDPIResult {
    case unchanged
    case preview(URL, HiDPITransaction)
    case failure(String)
}

enum HiDPIService {
    static let previewSeconds: TimeInterval = 20
    private static let directory = appCacheDir.appendingPathComponent("hidpi-preview", isDirectory: true)

    private static var hasSkyLightModes: Bool {
        getModeCount != nil && getModeDescription != nil && getCurrentMode != nil && configureMode != nil &&
        (devMode && ProcessInfo.processInfo.environment["DT_FORCE_NO_RESTORE"] == "1") == false
    }

    static var isSupported: Bool { true }

    private static func publicModeObjects(_ display: HiDPIDisplay) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(display.id, options) as? [CGDisplayMode]) ?? []
    }

    private static func publicModes(_ display: HiDPIDisplay, objects: [CGDisplayMode]) -> [HiDPIMode] {
        let current = CGDisplayCopyDisplayMode(display.id)
        var objects = objects
        if let current, !objects.contains(where: { $0.ioDisplayModeID == current.ioDisplayModeID }) {
            objects.append(current)
        }
        return objects.compactMap { mode in
            guard mode.ioDisplayModeID >= 0, mode.width > 0, mode.height > 0,
                  mode.width <= 65535, mode.height <= 65535,
                  mode.pixelWidth > 0, mode.pixelHeight > 0,
                  mode.isUsableForDesktopGUI() || mode.ioDisplayModeID == current?.ioDisplayModeID else { return nil }
            let result = HiDPIMode(number: UInt32(mode.ioDisplayModeID), flags: mode.ioFlags | 1,
                                   width: UInt32(mode.width), height: UInt32(mode.height), depth: 0,
                                   refresh: max(0, mode.refreshRate), refreshApproximate: false,
                                   density: Float(mode.pixelWidth) / Float(mode.width), backend: .coreGraphics)
            return result.usable ? result : nil
        }
    }

    private static func skyLightModes(for display: HiDPIDisplay, objects: [CGDisplayMode]) -> [HiDPIMode]? {
        guard display.isAvailable, hasSkyLightModes, let getModeCount, let getModeDescription else { return nil }
        var count: Int32 = 0
        getModeCount(display.id, &count)
        guard count > 0, count <= 4096 else { return nil }
        // 记录长度和字段偏移只在此处使用；未知系统返回异常数据时不展示该模式。
        let length = 212
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 16)
        defer { buffer.deallocate() }
        var result: [HiDPIMode] = []
        for index in 0..<count {
            buffer.initializeMemory(as: UInt8.self, repeating: 0, count: length)
            getModeDescription(display.id, index, buffer, Int32(length))
            let number = buffer.load(fromByteOffset: 0, as: UInt32.self)
            let hz = Double(buffer.load(fromByteOffset: 190, as: UInt16.self))
            let width = buffer.load(fromByteOffset: 8, as: UInt32.self)
            let height = buffer.load(fromByteOffset: 12, as: UInt32.self)
            let density = buffer.load(fromByteOffset: 208, as: Float.self)
            let publicRate = objects.first {
                $0.ioDisplayModeID >= 0 && UInt32($0.ioDisplayModeID) == number &&
                $0.width == Int(width) && $0.height == Int(height) && $0.width > 0 &&
                abs(Double($0.pixelWidth) / Double($0.width) - Double(density)) < 0.05
            }?.refreshRate ?? 0
            let mode = HiDPIMode(number: number,
                                 flags: buffer.load(fromByteOffset: 4, as: UInt32.self),
                                 width: width, height: height,
                                 depth: buffer.load(fromByteOffset: 16, as: UInt32.self),
                                 refresh: publicRate > 0 ? publicRate : hz,
                                 refreshApproximate: publicRate <= 0,
                                 density: density, backend: .skyLight)
            if mode.usable && mode.number <= UInt32(Int32.max) { result.append(mode) }
        }
        guard display.isAvailable else { return nil }
        // 私有布局校验失败时只使用公开 API，而不是猜测字段含义。
        guard current(for: display, in: result) != nil else { return nil }
        return result
    }

    static func modes(for display: HiDPIDisplay) -> [HiDPIMode] {
        guard display.isAvailable else { return [] }
        let objects = publicModeObjects(display)
        let fallback = publicModes(display, objects: objects)
        guard ProcessInfo.processInfo.environment["DT_FORCE_PUBLIC_MODES"] != "1",
              let result = skyLightModes(for: display, objects: objects) else { return fallback }
        let existing = Set(result.map(\.number))
        return result + fallback.filter { !existing.contains($0.number) }
    }

    private static func restorationMode(_ original: HiDPIMode, for display: HiDPIDisplay) -> HiDPIMode? {
        skyLightModes(for: display, objects: publicModeObjects(display))?.first {
            $0.number == original.number && $0.matches(original)
        }
    }

    static func current(for display: HiDPIDisplay, in modes: [HiDPIMode]) -> HiDPIMode? {
        guard display.isAvailable, let publicMode = CGDisplayCopyDisplayMode(display.id),
              publicMode.ioDisplayModeID >= 0, publicMode.width > 0, publicMode.height > 0 else { return nil }
        var number = publicMode.ioDisplayModeID
        if modes.contains(where: { $0.backend == .skyLight }), let getCurrentMode {
            var privateNumber: Int32 = -1
            guard getCurrentMode(display.id, &privateNumber) == 0, privateNumber == number else { return nil }
            number = privateNumber
        }
        guard let mode = modes.first(where: { $0.number == UInt32(number) }),
              publicMode.width == Int(mode.width), publicMode.height == Int(mode.height) else { return nil }
        // 私有记录布局可能随系统变化；当前模式必须与公开接口的尺寸和缩放一致才可使用。
        let scaleX = Double(publicMode.pixelWidth) / Double(publicMode.width)
        let scaleY = Double(publicMode.pixelHeight) / Double(publicMode.height)
        guard abs(scaleX - Double(mode.density)) < 0.05,
              abs(scaleY - Double(mode.density)) < 0.05,
              publicMode.refreshRate == 0 || abs(publicMode.refreshRate - mode.refresh) < 1 else { return nil }
        return mode
    }

    static func snapshot(_ display: HiDPIDisplay, name: String) -> HiDPISnapshot? {
        let all = modes(for: display)
        guard let current = current(for: display, in: all), current.height > 0 else { return nil }
        let groups = ModeCatalog.group(all, current: current)
        let native = all.filter { $0.flags & 0x02000000 != 0 && !$0.isHiDPI }
            .max { UInt64($0.width) * UInt64($0.height) < UInt64($1.width) * UInt64($1.height) }
        let reportedNative = DisplayInfo.nativeSize(DisplayInfo.properties(display.id))
        let size = CGDisplayScreenSize(display.id)
        let diagonal = hypot(Double(size.width), Double(size.height)) / 25.4
        return HiDPISnapshot(display: display, name: name,
                             mirrored: CGDisplayIsInMirrorSet(display.id) != 0,
                             current: current, canRestore: restorationMode(current, for: display) != nil,
                             hiDPI: groups.hiDPI, loDPI: groups.loDPI,
                             refreshRates: groups.refreshRates,
                             nativeSize: reportedNative ?? native.map { CGSize(width: Int($0.width), height: Int($0.height)) },
                             renderSize: CGDisplayCopyDisplayMode(display.id).map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) },
                             estimatedDiagonal: diagonal >= 5 && diagonal <= 150 ? diagonal : nil,
                             rotation: CGDisplayRotation(display.id))
    }

    static func hasSafeBackup(excluding display: HiDPIDisplay) -> Bool {
        if Lid.state == .open && DisplayService.isBuiltinActive() { return true }
        return DisplayService.physicalExternalDisplays().contains { id in
            id != display.id && CGDisplayIsActive(id) != 0 && CGDisplayIsAsleep(id) == 0 &&
            CGDisplayIsInMirrorSet(id) == 0
        }
    }

    private static func apply(_ mode: HiDPIMode, to display: HiDPIDisplay) -> String? {
        guard display.isAvailable, CGDisplayIsInMirrorSet(display.id) == 0,
              mode.number <= UInt32(Int32.max) else {
            return "外接屏已断开、正在镜像，或系统不支持该模式"
        }
        let publicMode: CGDisplayMode?
        if mode.backend == .coreGraphics {
            publicMode = publicModeObjects(display).first {
                $0.ioDisplayModeID == Int32(mode.number) && $0.width == Int(mode.width) &&
                $0.height == Int(mode.height) && $0.width > 0 &&
                abs(Double($0.pixelWidth) / Double($0.width) - Double(mode.density)) < 0.05
            }
            guard publicMode != nil else { return "显示模式已不可用" }
        } else {
            publicMode = nil
            guard configureMode != nil else { return "当前系统不支持此显示模式" }
        }
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else { return "无法开始显示配置（\(begin.rawValue)）" }
        guard display.isAvailable else {
            CGCancelDisplayConfiguration(config)
            return "外接屏已断开"
        }
        let configured: CGError
        if let publicMode {
            configured = CGConfigureDisplayWithDisplayMode(config, display.id, publicMode, nil)
        } else if let configureMode {
            configured = configureMode(config, display.id, Int32(mode.number))
        } else {
            CGCancelDisplayConfiguration(config)
            return "当前系统不支持此显示模式"
        }
        guard configured == .success else {
            CGCancelDisplayConfiguration(config)
            return "无法设置此显示模式（\(configured.rawValue)）"
        }
        // 与内屏开关一致，只修改本次登录会话。
        let completed = CGCompleteDisplayConfiguration(config, CGConfigureOption(rawValue: 1))
        return completed == .success ? nil : "系统拒绝了显示模式（\(completed.rawValue)）"
    }

    static func beginPreview(display: HiDPIDisplay, requested: HiDPIMode) -> HiDPIResult {
        guard display.isAvailable, CGDisplayIsActive(display.id) != 0,
              CGDisplayIsAsleep(display.id) == 0, CGDisplayIsInMirrorSet(display.id) == 0 else {
            return .failure("外接屏已断开或处于镜像状态，暂不能切换。")
        }
        let all = modes(for: display)
        guard let original = current(for: display, in: all),
              let target = all.first(where: { $0.number == requested.number && $0.matches(requested) }) else {
            return .failure("显示模式已变化，请重新打开菜单。")
        }
        if original.matches(target) { return .unchanged }
        guard restorationMode(original, for: display) != nil else {
            return .failure("无法确认原显示模式的还原通道，当前系统只能查看模式。")
        }

        let transaction = HiDPITransaction(display: display, original: original, target: target,
                                            deadlineUptime: ProcessInfo.processInfo.systemUptime + previewSeconds)
        let url = directory.appendingPathComponent(UUID().uuidString + ".json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(transaction).write(to: url, options: .atomic)
            guard startRollbackWorker(url) else {
                try? FileManager.default.removeItem(at: url)
                return .failure("无法启动自动还原保护，已取消切换。")
            }
            let error: String? = PreviewLock.withLock(url, failure: "自动还原保护已结束，未切换显示模式") {
                guard ProcessInfo.processInfo.systemUptime < transaction.deadlineUptime else {
                    return "自动还原保护已超时，未切换显示模式"
                }
                return apply(target, to: display)
            }
            if let error {
                _ = restoreNow(url, transaction: transaction)
                return .failure(error)
            }
            Thread.sleep(forTimeInterval: 0.25)
            let after = modes(for: display)
            guard let actual = current(for: display, in: after), actual.matches(target) else {
                _ = restoreNow(url, transaction: transaction)
                return .failure("系统没有切换到所选模式，已尝试恢复原设置。")
            }
            dtlog("hidpi preview id=\(display.id) \(original.width)x\(original.height) -> \(target.width)x\(target.height) density=\(target.density)")
            return .preview(url, transaction)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return .failure("无法准备自动还原保护：\(error.localizedDescription)")
        }
    }

    static func confirm(_ url: URL) -> Bool {
        url.path.withCString { unlink($0) == 0 }
    }

    private static func claim(_ url: URL) -> URL? {
        let claimed = url.appendingPathExtension("reverting")
        let result = url.path.withCString { old in
            claimed.path.withCString { new in rename(old, new) }
        }
        return result == 0 ? claimed : nil
    }

    @discardableResult
    static func restoreNow(_ url: URL, transaction: HiDPITransaction) -> String? {
        PreviewLock.withLock(url, failure: "自动还原已开始或预览已结束") {
            guard let claimed = claim(url) else { return "自动还原已开始或预览已结束" }
            defer { try? FileManager.default.removeItem(at: claimed) }
            let display = transaction.display
            guard display.isAvailable, CGDisplayIsInMirrorSet(display.id) == 0 else {
                return "外接屏已断开或镜像关系已变化"
            }
            let all = modes(for: display)
            guard let currentMode = current(for: display, in: all) else { return "无法读取当前模式" }
            if currentMode.number == transaction.original.number && currentMode.matches(transaction.original) { return nil }
            guard currentMode.number == transaction.target.number && currentMode.matches(transaction.target) else { return "显示模式已由其他操作更改" }
            // 公开 API 在切换后可能丢失原模式；仅使用经过尺寸和缩放校验的 SkyLight 记录恢复。
            guard let old = restorationMode(transaction.original, for: display) else { return "原显示模式已不可用" }
            let error = apply(old, to: display)
            if let error {
                dtlog("hidpi rollback id=\(display.id) result=\(error)")
                return error
            }
            Thread.sleep(forTimeInterval: 0.25)
            let restored = current(for: display, in: modes(for: display))
            let verified = restored?.number == transaction.original.number && restored?.matches(transaction.original) == true
            dtlog("hidpi rollback id=\(display.id) verified=\(verified)")
            return verified ? nil : "系统未恢复到原显示模式"
        }
    }

    private static func startRollbackWorker(_ url: URL) -> Bool {
        let process = Process()
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.executableURL = executable
        process.arguments = ["--hidpi-rollback-worker", url.path]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            var descriptor = pollfd(fd: pipe.fileHandleForReading.fileDescriptor,
                                    events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 3000) > 0 else { return false }
            let response = pipe.fileHandleForReading.availableData
            return String(data: response, encoding: .utf8) == "READY\n" && process.isRunning
        } catch {
            return false
        }
    }

    static func runRollbackWorker(path: String) -> Never {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let prefix = directory.standardizedFileURL.path + "/"
        guard url.path.hasPrefix(prefix), url.pathExtension == "json",
              let data = try? Data(contentsOf: url),
              let transaction = try? JSONDecoder().decode(HiDPITransaction.self, from: data),
              transaction.deadlineUptime > ProcessInfo.processInfo.systemUptime,
              transaction.deadlineUptime - ProcessInfo.processInfo.systemUptime <= previewSeconds + 5,
              transaction.display.isAvailable,
              restorationMode(transaction.original, for: transaction.display) != nil else {
            exit(1)
        }
        FileHandle.standardOutput.write(Data("READY\n".utf8))
        while ProcessInfo.processInfo.systemUptime < transaction.deadlineUptime {
            Thread.sleep(forTimeInterval: min(0.5, max(0.01, transaction.deadlineUptime - ProcessInfo.processInfo.systemUptime)))
        }
        let result = restoreNow(url, transaction: transaction)
        dtlog("hidpi rollback-worker result=\(result ?? "success")")
        dtFlushLog()
        exit(0)
    }
}
