import AppKit
import CoreGraphics
import Foundation
import IOKit

// DDC/CI 数据包和 Apple Silicon 的 IORegistry 路径参考 AppleSiliconDDC（MIT）。
// https://github.com/waydabber/AppleSiliconDDC

enum DDCFeature: String, CaseIterable, Codable {
    case brightness
    case contrast
    case volume

    var code: UInt8 {
        switch self {
        case .brightness: return 0x10
        case .contrast: return 0x12
        case .volume: return 0x62
        }
    }
    var title: String {
        switch self {
        case .brightness: return "硬件亮度"
        case .contrast: return "硬件对比度"
        case .volume: return "显示器音量"
        }
    }
    var requiresBackup: Bool { self != .volume }
}

struct DDCReading {
    let feature: DDCFeature
    let current: UInt16
    let maximum: UInt16
    var percent: Double { maximum == 0 ? 0 : Double(current) * 100 / Double(maximum) }
}

final class DDCSlider: NSSlider {
    var display: HiDPIDisplay?
    var feature: DDCFeature?
}

#if arch(arm64)
private typealias DDCServiceCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
private typealias DDCTransfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer?, UInt32) -> Int32
private let ddcFramework = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
private func ddcSymbol<T>(_ name: String, type: T.Type) -> T? {
    guard let ddcFramework, let symbol = dlsym(ddcFramework, name) else { return nil }
    return unsafeBitCast(symbol, to: type)
}
private let createDDCService = ddcSymbol("IOAVServiceCreateWithService", type: DDCServiceCreate.self)
private let writeDDC = ddcSymbol("IOAVServiceWriteI2C", type: DDCTransfer.self)
private let readDDC = ddcSymbol("IOAVServiceReadI2C", type: DDCTransfer.self)
#endif

enum DDCService {
    static var availableOnPlatform: Bool {
        #if arch(arm64)
        return createDDCService != nil && writeDDC != nil && readDDC != nil
        #else
        return false
        #endif
    }

    #if arch(arm64)
    private static func registryPath(_ entry: io_registry_entry_t) -> String? {
        var path = [CChar](repeating: 0, count: 512)
        guard IORegistryEntryGetPath(entry, kIOServicePlane, &path) == KERN_SUCCESS else { return nil }
        return String(cString: path)
    }

    private static func portName(_ path: String) -> String? {
        for component in path.split(separator: "/") {
            let name = component.split(separator: "@").first.map(String.init) ?? ""
            guard name.hasPrefix("dispext") else { continue }
            let suffix = name.dropFirst("dispext".count)
            if !suffix.isEmpty && suffix.allSatisfy(\.isNumber) { return name }
        }
        return nil
    }

    private static func resolve(_ display: HiDPIDisplay) -> CFTypeRef? {
        guard display.isAvailable, let createDDCService,
              let properties = DisplayInfo.properties(display.id),
              (properties["kCGDisplayIsVirtualDevice"] as? NSNumber)?.boolValue != true,
              let expectedPath = DisplayInfo.ioLocation(properties),
              let port = portName(expectedPath) else { return nil }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var previousFramebuffer: String?
        var services: [CFTypeRef] = []
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            var name = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS else {
                IOObjectRelease(entry)
                continue
            }
            let entryName = String(cString: name)
            if entryName == "AppleCLCD2" || entryName == "IOMobileFramebufferShim" {
                previousFramebuffer = registryPath(entry)
            } else if entryName == "DCPAVServiceProxy", previousFramebuffer == expectedPath,
                      let path = registryPath(entry), path.contains("/\(port):"),
                      let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                      location == "External", let service = createDDCService(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                services.append(service)
            }
            IOObjectRelease(entry)
        }
        return display.isAvailable && services.count == 1 ? services[0] : nil
    }

    private static func read(_ service: CFTypeRef, feature: DDCFeature) -> DDCReading? {
        guard let writeDDC, let readDDC else { return nil }
        for _ in 0..<4 {
            var packet = DDCProtocol.getPacket(feature.code)
            var writesOK = true
            for _ in 0..<2 {
                let result = packet.withUnsafeMutableBytes {
                    writeDDC(service, 0x37, 0x51, $0.baseAddress, UInt32($0.count))
                }
                writesOK = writesOK && result == 0
                usleep(10_000)
            }
            usleep(100_000)
            var response = [UInt8](repeating: 0, count: 11)
            let result = response.withUnsafeMutableBytes {
                readDDC(service, 0x37, 0, $0.baseAddress, UInt32($0.count))
            }
            guard writesOK && result == 0,
                  let value = DDCProtocol.parse(response, code: feature.code) else {
                usleep(100_000)
                continue
            }
            return DDCReading(feature: feature, current: value.current, maximum: value.maximum)
        }
        return nil
    }

    private static func write(_ service: CFTypeRef, feature: DDCFeature, value: UInt16) -> Bool {
        guard let writeDDC else { return false }
        var packet = DDCProtocol.setPacket(feature.code, value: value)
        var success = true
        for _ in 0..<2 {
            let result = packet.withUnsafeMutableBytes {
                writeDDC(service, 0x37, 0x51, $0.baseAddress, UInt32($0.count))
            }
            success = success && result == 0
            usleep(50_000)
        }
        return success
    }
    #endif

    static func readAll(_ display: HiDPIDisplay) -> [DDCReading] {
        #if arch(arm64)
        guard let service = resolve(display) else { return [] }
        return DDCFeature.allCases.compactMap { feature in
            guard display.isAvailable else { return nil }
            let value = read(service, feature: feature)
            usleep(100_000)
            return value
        }
        #else
        return []
        #endif
    }

    static func readOne(_ display: HiDPIDisplay, feature: DDCFeature) -> DDCReading? {
        #if arch(arm64)
        guard let service = resolve(display), display.isAvailable else { return nil }
        return read(service, feature: feature)
        #else
        return nil
        #endif
    }

    static func set(_ display: HiDPIDisplay, feature: DDCFeature, percent: Double,
                    protectedPreview: Bool = false) -> Result<DDCReading, DDCError> {
        #if arch(arm64)
        guard percent.isFinite, percent >= 0, percent <= 100, display.isAvailable else {
            return .failure(DDCError(message: "显示器已断开或设置值无效"))
        }
        if feature.requiresBackup && !protectedPreview && !HiDPIService.hasSafeBackup(excluding: display) {
            return .failure(DDCError(message: "请先点亮另一块屏幕，再调整亮度或对比度"))
        }
        guard let service = resolve(display), let previous = read(service, feature: feature) else {
            return .failure(DDCError(message: "无法读取该显示器的硬件控制"))
        }
        let value = UInt16((Double(previous.maximum) * percent / 100).rounded())
        guard display.isAvailable, !feature.requiresBackup || protectedPreview || HiDPIService.hasSafeBackup(excluding: display) else {
            return .failure(DDCError(message: "备用屏幕已不可用，未发送调整"))
        }
        let sent = write(service, feature: feature, value: value)
        usleep(250_000)
        guard let actual = read(service, feature: feature) else {
            return .failure(DDCError(message: sent ? "已发送调整，但无法读取显示器反馈" : "命令可能只部分发送，无法读取显示器反馈"))
        }
        return .success(actual)
        #else
        return .failure(DDCError(message: "此架构暂不支持 DDC 硬件控制"))
        #endif
    }
}

struct DDCError: Error {
    let message: String
}
