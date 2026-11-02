import CoreGraphics
import Foundation

private typealias DisplayInfoFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
private let coreDisplayHandle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW)
private let createDisplayInfo: DisplayInfoFn? = {
    guard let coreDisplayHandle, let symbol = dlsym(coreDisplayHandle, "CoreDisplay_DisplayCreateInfoDictionary") else { return nil }
    return unsafeBitCast(symbol, to: DisplayInfoFn.self)
}()

enum DisplayInfo {
    static func properties(_ display: CGDirectDisplayID) -> [String: Any]? {
        createDisplayInfo?(display)?.takeRetainedValue() as? [String: Any]
    }

    static func nativeSize(_ properties: [String: Any]?) -> CGSize? {
        guard let width = properties?["kCGDisplayPixelWidth"] as? NSNumber,
              let height = properties?["kCGDisplayPixelHeight"] as? NSNumber,
              width.intValue > 0, height.intValue > 0,
              width.intValue <= 65535, height.intValue <= 65535 else { return nil }
        return CGSize(width: width.intValue, height: height.intValue)
    }

    static func ioLocation(_ properties: [String: Any]?) -> String? {
        properties?["IODisplayLocation"] as? String
    }
}
