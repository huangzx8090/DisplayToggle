import Darwin
import Foundation

/// CLI 与菜单栏进程共享；不阻塞主线程，避免等待 WindowServer 时互相卡住。
enum DisplayConfigurationLock {
    enum Result<Value> {
        case acquired(Value)
        case busy
        case unavailable
    }

    static func withLock<Value>(_ url: URL, _ body: () -> Value) -> Result<Value> {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
        } catch {
            return .unavailable
        }
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return .unavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            return errno == EWOULDBLOCK ? .busy : .unavailable
        }
        defer { flock(descriptor, LOCK_UN) }
        var opened = stat()
        var current = stat()
        guard fstat(descriptor, &opened) == 0, lstat(url.path, &current) == 0,
              opened.st_dev == current.st_dev, opened.st_ino == current.st_ino else {
            return .unavailable
        }
        return .acquired(body())
    }
}
