import Darwin
import Foundation
import ObjectiveC

enum TrueToneStatus: Equatable {
    case enabled, disabled, unavailable, unsupported, failed

    var title: String {
        switch self {
        case .enabled: return "开"
        case .disabled: return "关"
        case .unavailable: return "暂不可用"
        case .unsupported: return "此设备不支持"
        case .failed: return "读取或设置失败"
        }
    }
}

struct TrueToneResult {
    let status: TrueToneStatus
    let changed: Bool
}

enum TrueToneService {
    private typealias Create = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
    private typealias Read = @convention(c) (AnyObject, Selector) -> Bool
    private typealias Write = @convention(c) (AnyObject, Selector, Bool) -> Bool

    private static let framework = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)

    private static func boolType(_ value: UnsafeMutablePointer<CChar>?) -> Bool {
        guard let value else { return false }
        defer { free(value) }
        return value.pointee == 66 || value.pointee == 99 // B 或 c（不同架构的 BOOL）
    }

    private static func getter(_ cls: AnyClass, _ name: String) -> (Selector, Read)? {
        let selector = sel_registerName(name)
        guard let method = class_getInstanceMethod(cls, selector), method_getNumberOfArguments(method) == 2,
              boolType(method_copyReturnType(method)) else { return nil }
        return (selector, unsafeBitCast(method_getImplementation(method), to: Read.self))
    }

    private static func setter(_ cls: AnyClass) -> (Selector, Write)? {
        let selector = sel_registerName("setEnabled:")
        guard let method = class_getInstanceMethod(cls, selector), method_getNumberOfArguments(method) == 3,
              boolType(method_copyReturnType(method)), boolType(method_copyArgumentType(method, 2)) else { return nil }
        return (selector, unsafeBitCast(method_getImplementation(method), to: Write.self))
    }

    private struct Client {
        let object: AnyObject
        let supported: (Selector, Read)
        let available: (Selector, Read)
        let enabled: (Selector, Read)
        let setEnabled: (Selector, Write)
    }

    private static func makeClient() -> Client? {
        guard framework != nil, let cls = NSClassFromString("CBTrueToneClient"),
              let supported = getter(cls, "supported"), let available = getter(cls, "available"),
              let enabled = getter(cls, "enabled"), let setEnabled = setter(cls) else { return nil }
        let selector = sel_registerName("new")
        guard let method = class_getClassMethod(cls, selector), method_getNumberOfArguments(method) == 2 else { return nil }
        let returnType = method_copyReturnType(method)
        let objectReturn = returnType.pointee == 64 // @
        free(returnType)
        guard objectReturn else { return nil }
        let create = unsafeBitCast(method_getImplementation(method), to: Create.self)
        guard let object = create(cls, selector)?.takeRetainedValue() else { return nil }
        return Client(object: object, supported: supported,
                      available: available, enabled: enabled, setEnabled: setEnabled)
    }

    static func read() -> TrueToneStatus {
        guard let client = makeClient() else { return .unsupported }
        guard client.supported.1(client.object, client.supported.0) else { return .unsupported }
        guard client.available.1(client.object, client.available.0) else { return .unavailable }
        return client.enabled.1(client.object, client.enabled.0) ? .enabled : .disabled
    }

    static func ensure(enabled desired: Bool) -> TrueToneResult {
        guard let client = makeClient() else { return TrueToneResult(status: .unsupported, changed: false) }
        guard client.supported.1(client.object, client.supported.0) else {
            return TrueToneResult(status: .unsupported, changed: false)
        }
        guard client.available.1(client.object, client.available.0) else {
            return TrueToneResult(status: .unavailable, changed: false)
        }
        let original = client.enabled.1(client.object, client.enabled.0)
        let expected: TrueToneStatus = desired ? .enabled : .disabled
        if original == desired { return TrueToneResult(status: expected, changed: false) }
        guard client.setEnabled.1(client.object, client.setEnabled.0, desired) else {
            return TrueToneResult(status: .failed, changed: false)
        }
        for _ in 0..<5 {
            if client.enabled.1(client.object, client.enabled.0) == desired {
                return TrueToneResult(status: expected, changed: true)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return TrueToneResult(status: .failed, changed: false)
    }
}
