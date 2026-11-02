import Foundation
import IOKit
import IOKit.hid

/// 传感器使用 HID Feature Report；读取在后台队列执行，不能阻塞拔线恢复。
final class LidAngleReader {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var retryAfter: TimeInterval = 0

    deinit { close() }

    func read() -> Int? {
        let env = devMode ? ProcessInfo.processInfo.environment : [:]
        if let path = env["DT_FAKE_ANGLE_FILE"] {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            return Self.validAngle(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let value = env["DT_FAKE_ANGLE"] { return Self.validAngle(value) }
        if device == nil && ProcessInfo.processInfo.systemUptime < retryAfter { return nil }
        guard let device = device ?? open() else {
            retryAfter = ProcessInfo.processInfo.systemUptime + 5
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: 8)
        var length = CFIndex(bytes.count)
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &bytes, &length)
        guard result == kIOReturnSuccess, length >= 3, bytes[0] == 1 else {
            close()
            retryAfter = ProcessInfo.processInfo.systemUptime + 2
            return nil
        }
        let angle = Int(bytes[1]) | (Int(bytes[2]) << 8)
        return (0...180).contains(angle) ? angle : nil
    }

    private static func validAngle(_ text: String) -> Int? {
        guard let value = Int(text), (0...180).contains(value) else { return nil }
        return value
    }

    private func open() -> IOHIDDevice? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDVendorIDKey: 0x05ac,
                                    kIOHIDDeviceUsagePageKey: 0x20,
                                    kIOHIDDeviceUsageKey: 0x8a]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return nil }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return nil
        }
        let candidates = devices.filter {
            (IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String)?.lowercased() == "las"
        }
        guard candidates.count == 1, let device = candidates.first,
              IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return nil
        }
        self.manager = manager
        self.device = device
        return device
    }

    private func close() {
        if let device { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        if let manager { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil
        manager = nil
    }
}
