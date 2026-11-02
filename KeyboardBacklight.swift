import Darwin
import Foundation
import ObjectiveC

// CoreBrightness 桥接方式参考 Dim Keys（MIT）；只操作被系统标记为内置的键盘。
private final class KeyboardBacklight {
    @objc private protocol SystemClient {
        @objc(copyPropertyForKey:keyboardID:)
        func copyProperty(forKey key: String, keyboardID: UInt64) -> Any?
        @objc(setProperty:withKey:keyboardID:)
        func setProperty(_ value: Any, withKey key: String, keyboardID: UInt64) -> Bool
    }

    @objc private protocol KeyboardClient {
        func copyKeyboardBacklightIDs() -> [NSNumber]?
        @objc(isKeyboardBuiltIn:)
        func isKeyboardBuiltIn(_ id: UInt64) -> Bool
        @objc(isAutoBrightnessEnabledForKeyboard:)
        func isAutoBrightnessEnabledForKeyboard(_ id: UInt64) -> Bool
        @objc(isBacklightSuppressedOnKeyboard:)
        func isBacklightSuppressedOnKeyboard(_ id: UInt64) -> Bool
        @objc(setBrightness:forKeyboard:)
        func setBrightness(_ value: Float, forKeyboard id: UInt64) -> Bool
    }

    private static let key = "KeyboardBacklightBrightness"
    private let systemObject: NSObject
    private let keyboardObject: NSObject
    private let system: SystemClient
    private let keyboard: KeyboardClient
    let keyboardID: UInt64

    private init(systemObject: NSObject, keyboardObject: NSObject, system: SystemClient, keyboard: KeyboardClient,
                 keyboardID: UInt64) {
        self.systemObject = systemObject
        self.keyboardObject = keyboardObject
        self.system = system
        self.keyboard = keyboard
        self.keyboardID = keyboardID
    }

    private static func matches(_ cls: AnyClass, _ selector: String, result: Character, arguments: [Character]) -> Bool {
        guard let method = class_getInstanceMethod(cls, sel_registerName(selector)),
              method_getNumberOfArguments(method) == UInt32(arguments.count + 2) else { return false }
        func first(_ type: UnsafeMutablePointer<CChar>?) -> Character? {
            guard let type else { return nil }
            defer { free(type) }
            return String(cString: type).first
        }
        let resultType = first(method_copyReturnType(method))
        guard resultType == result || (result == "B" && resultType == "c") else { return false }
        for (index, expected) in arguments.enumerated() {
            let actual = first(method_copyArgumentType(method, UInt32(index + 2)))
            if actual != expected { return false }
        }
        return true
    }

    static func open() -> KeyboardBacklight? {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil,
              let systemClass = NSClassFromString("BrightnessSystemClient") as? NSObject.Type,
              let keyboardClass = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type,
              matches(systemClass, "copyPropertyForKey:keyboardID:", result: "@", arguments: ["@", "Q"]),
              matches(systemClass, "setProperty:withKey:keyboardID:", result: "B", arguments: ["@", "@", "Q"]),
              matches(keyboardClass, "copyKeyboardBacklightIDs", result: "@", arguments: []),
              matches(keyboardClass, "isKeyboardBuiltIn:", result: "B", arguments: ["Q"]),
              matches(keyboardClass, "isAutoBrightnessEnabledForKeyboard:", result: "B", arguments: ["Q"]),
              matches(keyboardClass, "isBacklightSuppressedOnKeyboard:", result: "B", arguments: ["Q"]),
              matches(keyboardClass, "setBrightness:forKeyboard:", result: "B", arguments: ["f", "Q"]) else { return nil }
        let systemObject = systemClass.init()
        let keyboardObject = keyboardClass.init()
        let system = unsafeBitCast(systemObject, to: SystemClient.self)
        let keyboard = unsafeBitCast(keyboardObject, to: KeyboardClient.self)
        guard let ids = keyboard.copyKeyboardBacklightIDs() else { return nil }
        let builtins = ids.filter { keyboard.isKeyboardBuiltIn($0.uint64Value) }
        guard builtins.count == 1, let id = builtins.first?.uint64Value,
              let number = system.copyProperty(forKey: key, keyboardID: id) as? NSNumber else { return nil }
        let brightness = number.floatValue
        guard brightness.isFinite, (0...1).contains(brightness) else { return nil }
        return KeyboardBacklight(systemObject: systemObject, keyboardObject: keyboardObject,
                                 system: system, keyboard: keyboard, keyboardID: id)
    }

    func brightness() -> Float? {
        guard let value = system.copyProperty(forKey: Self.key, keyboardID: keyboardID) as? NSNumber,
              value.floatValue.isFinite, (0...1).contains(value.floatValue) else { return nil }
        return value.floatValue
    }

    func set(_ value: Float) -> Bool {
        system.setProperty(NSNumber(value: value), withKey: Self.key, keyboardID: keyboardID)
    }

    func restore(original: Float) -> Bool {
        let automatic = keyboard.isAutoBrightnessEnabledForKeyboard(keyboardID)
        let target = KeyboardBacklightPolicy.restoreTarget(original: original, automatic: automatic)
        // 只写回 SystemClient 的数值可能让背光停留在 suppressed；通过键盘接口解除抑制。
        guard keyboard.setBrightness(target, forKeyboard: keyboardID) else { return false }
        for _ in 0..<10 {
            if target > 0.01 {
                if !keyboard.isBacklightSuppressedOnKeyboard(keyboardID) { return true }
            } else if let brightness = brightness(), brightness <= 0.01 {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}

private struct KeyboardRecoveryState: Codable {
    let keyboardID: UInt64
    let brightness: Float
}

/// 在修改亮度前保存恢复值，文件锁避免两个进程同时接管键盘。
private final class KeyboardRecovery {
    private static let directory = appCacheDir
    private static let stateURL = directory.appendingPathComponent("keyboard-backlight-recovery.json")
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }

    static var pending: Bool { FileManager.default.fileExists(atPath: stateURL.path) }

    static func acquire() -> KeyboardRecovery? {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return nil }
        let descriptor = open(directory.appendingPathComponent("keyboard-backlight.lock").path,
                              O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); return nil }
        return KeyboardRecovery(descriptor: descriptor)
    }

    func save(_ state: KeyboardRecoveryState) -> Bool {
        do {
            try JSONEncoder().encode(state).write(to: Self.stateURL, options: .atomic)
            return true
        } catch { return false }
    }

    func recover(using keyboard: KeyboardBacklight) -> Bool {
        guard Self.pending else { return true }
        guard let data = try? Data(contentsOf: Self.stateURL),
              let state = try? JSONDecoder().decode(KeyboardRecoveryState.self, from: data),
              state.keyboardID == keyboard.keyboardID, state.brightness.isFinite,
              (0...1).contains(state.brightness), keyboard.restore(original: state.brightness) else { return false }
        do { try FileManager.default.removeItem(at: Self.stateURL); return true }
        catch { return false }
    }
}

enum KeyboardBacklightWorker {
    static func run() -> Never {
        guard let recovery = KeyboardRecovery.acquire(), let keyboard = KeyboardBacklight.open(),
              recovery.recover(using: keyboard), let original = keyboard.brightness(),
              recovery.save(KeyboardRecoveryState(keyboardID: keyboard.keyboardID, brightness: original)) else {
            FileHandle.standardOutput.write(Data("UNAVAILABLE\n".utf8))
            exit(1)
        }
        guard keyboard.set(0) else {
            _ = recovery.recover(using: keyboard)
            FileHandle.standardOutput.write(Data("UNAVAILABLE\n".utf8))
            exit(1)
        }
        var verified = false
        for _ in 0..<10 {
            if let brightness = keyboard.brightness(), brightness <= 0.01 { verified = true; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard verified else {
            _ = recovery.recover(using: keyboard)
            FileHandle.standardOutput.write(Data("UNAVAILABLE\n".utf8))
            exit(1)
        }
        FileHandle.standardOutput.write(Data("READY\n".utf8))
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
        while true {
            descriptor.revents = 0
            let result = poll(&descriptor, 1, 1200)
            if result < 0 { if errno == EINTR { continue }; break }
            if result > 0 {
                if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { break }
                if descriptor.revents & Int16(POLLIN) != 0 {
                    var byte: UInt8 = 0
                    if Darwin.read(STDIN_FILENO, &byte, 1) <= 0 || byte == 113 { break }
                }
            }
            guard let brightness = keyboard.brightness() else { break }
            if brightness > 0.01 && !keyboard.set(0) { break }
        }
        exit(recovery.recover(using: keyboard) ? 0 : 2)
    }

    static func recover() -> Never {
        guard KeyboardRecovery.pending else { exit(0) }
        guard let recovery = KeyboardRecovery.acquire(), let keyboard = KeyboardBacklight.open(),
              recovery.recover(using: keyboard) else { exit(2) }
        exit(0)
    }
}

/// 背光控制放在子进程中：结束或父进程退出时释放系统客户端，交回系统自动调节。
enum KeyboardHoldStatus: Equatable { case idle, holding, unavailable }

final class KeyboardHoldController {
    private let queue = DispatchQueue(label: "\(appBundleID).keyboard", qos: .utility)
    private let onStatus: (KeyboardHoldStatus) -> Void
    private var desired = false
    private var process: Process?
    private var input: Pipe?
    private var status: KeyboardHoldStatus = .idle
    private var recoveryRetryPending = false

    init(onStatus: @escaping (KeyboardHoldStatus) -> Void) { self.onStatus = onStatus }

    private func report(_ value: KeyboardHoldStatus) {
        guard status != value else { return }
        status = value
        DispatchQueue.main.async { self.onStatus(value) }
    }

    func update(holding: Bool) {
        queue.async {
            self.desired = holding
            self.reconcile()
        }
    }

    func recoverIfNeeded() {
        queue.async { self.recoverPending() }
    }

    private func recoverPending() {
        guard !desired, process == nil, KeyboardRecovery.pending else { return }
        let recovery = Process()
        recovery.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        recovery.arguments = ["--keyboard-backlight-recover"]
        recovery.standardOutput = FileHandle.nullDevice
        recovery.standardError = FileHandle.nullDevice
        do {
            try recovery.run()
            recovery.waitUntilExit()
            if recovery.terminationStatus == 0 {
                dtlog("keyboard-backlight 已恢复上次遗留的亮度")
                report(.idle)
                return
            }
        } catch {
            dtlog("keyboard-backlight 无法启动恢复进程：\(error.localizedDescription)")
        }
        dtlog("keyboard-backlight 恢复未确认，稍后重试")
        report(.unavailable)
        // 合盖时内置键盘下线，拿不到控制权，恢复必然失败；等开盖后由 tick 触发。
        guard Lid.state == .open else {
            dtlog("keyboard-backlight 恢复推迟到开盖后")
            return
        }
        guard !recoveryRetryPending else { return }
        recoveryRetryPending = true
        queue.asyncAfter(deadline: .now() + 15) {
            self.recoveryRetryPending = false
            self.recoverPending()
        }
    }

    private func reconcile() {
        if !desired {
            if let process, let input {
                input.fileHandleForWriting.closeFile()
                process.waitUntilExit()
                self.process = nil
                self.input = nil
                dtlog(process.terminationStatus == 0
                      ? "keyboard-backlight 已恢复并释放控制"
                      : "keyboard-backlight 恢复结果未确认，已释放控制")
                report(process.terminationStatus == 0 ? .idle : .unavailable)
            } else {
                if !KeyboardRecovery.pending { report(.idle) }
            }
            recoverPending()
            return
        }
        if let process, process.isRunning { return }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["--keyboard-backlight-worker"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            self.process = process
            self.input = input
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 6000) > 0 &&
                String(data: output.fileHandleForReading.availableData, encoding: .utf8) == "READY\n" && process.isRunning
            guard ready else {
                input.fileHandleForWriting.closeFile()
                process.waitUntilExit()
                self.process = nil
                self.input = nil
                dtlog("keyboard-backlight 不可用或未能确认已关闭")
                report(.unavailable)
                queue.asyncAfter(deadline: .now() + 15) { if self.desired { self.reconcile() } }
                return
            }
            dtlog("keyboard-backlight 已关闭，等待恢复系统控制")
            report(.holding)
            process.terminationHandler = { [weak self, weak process] _ in
                self?.queue.async {
                    guard let self, let process, self.process === process else { return }
                    self.process = nil
                    self.input = nil
                    if self.desired {
                        dtlog("keyboard-backlight 控制进程退出，稍后重试")
                        self.report(.unavailable)
                        self.queue.asyncAfter(deadline: .now() + 15) { if self.desired { self.reconcile() } }
                    }
                }
            }
        } catch {
            dtlog("keyboard-backlight 无法启动：\(error.localizedDescription)")
            report(.unavailable)
            queue.asyncAfter(deadline: .now() + 15) { if self.desired { self.reconcile() } }
        }
    }
}
