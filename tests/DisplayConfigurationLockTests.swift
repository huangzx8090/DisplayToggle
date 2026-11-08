import Foundation

@main
struct DisplayConfigurationLockTests {
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        precondition(condition(), name)
        print("PASS: \(name)")
    }

    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 3 && args[1] == "--hold" {
            let result = DisplayConfigurationLock.withLock(URL(fileURLWithPath: args[2])) {
                FileHandle.standardOutput.write(Data("READY\n".utf8))
                _ = FileHandle.standardInput.readData(ofLength: 1)
            }
            guard case .acquired = result else { fatalError("子进程获取配置锁失败") }
            return
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("display.lock")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: args[0]).standardizedFileURL
        child.arguments = ["--hold", url.path]
        let output = Pipe()
        let input = Pipe()
        child.standardOutput = output
        child.standardInput = input
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        check(output.fileHandleForReading.readData(ofLength: 6) == Data("READY\n".utf8),
              "自动创建目录和配置锁，子进程成功持有")
        var entered = false
        let busy = DisplayConfigurationLock.withLock(url) { entered = true }
        guard case .busy = busy else { fatalError("未拦截其他进程的并发配置") }
        check(!entered, "其他进程持锁时立即返回，不进入配置操作")
        input.fileHandleForWriting.write(Data("x".utf8))
        child.waitUntilExit()
        check(child.terminationStatus == 0, "子进程正常退出并释放配置锁")
        let acquired = DisplayConfigurationLock.withLock(url) {
            let nested = DisplayConfigurationLock.withLock(url) { true }
            guard case .busy = nested else { fatalError("未拦截同进程重入") }
            return 42
        }
        guard case .acquired(let value) = acquired else { fatalError("释放后未能重获配置锁") }
        check(value == 42, "释放后重新获取，且同进程重入不会重复执行")
        let link = directory.appendingPathComponent("link.lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        let invalid = DisplayConfigurationLock.withLock(link) { true }
        guard case .unavailable = invalid else { fatalError("不应跟随配置锁符号链接") }
        print("PASS: 拒绝配置锁符号链接")
    }
}
