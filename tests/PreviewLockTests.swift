import Darwin
import Foundation

@main
struct PreviewLockTests {
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("FAIL: \(name)") }
        print("PASS: \(name)")
    }

    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 4 && args[1] == "--hold" {
            let url = URL(fileURLWithPath: args[2])
            let held = PreviewLock.withLock(url, failure: false) {
                FileHandle.standardOutput.write(Data("READY\n".utf8))
                Thread.sleep(forTimeInterval: 1)
                if args[3] == "delete" { try? FileManager.default.removeItem(at: url) }
                return true
            }
            exit(held ? 0 : 1)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        func holder(delete: Bool) throws -> Process {
            try Data("preview".utf8).write(to: url)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: args[0]).standardizedFileURL
            process.arguments = ["--hold", url.path, delete ? "delete" : "keep"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            check(String(data: pipe.fileHandleForReading.readData(ofLength: 6), encoding: .utf8) == "READY\n", "保护进程持有文件锁")
            return process
        }
        var child = try holder(delete: false)
        let start = ProcessInfo.processInfo.systemUptime
        let acquired = PreviewLock.withLock(url, failure: false) { true }
        child.waitUntilExit()
        check(acquired && ProcessInfo.processInfo.systemUptime - start > 0.5, "写入与还原在不同进程间串行")
        child = try holder(delete: true)
        var wrote = false
        let result = PreviewLock.withLock(url, failure: false) { wrote = true; return true }
        child.waitUntilExit()
        check(!result && !wrote, "保护文件消失后禁止迟到的写入")
        print("预览锁测试全部通过")
    }
}
