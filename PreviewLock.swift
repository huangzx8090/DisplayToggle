import Darwin
import Foundation

enum PreviewLock {
    // 防止进程暂停后，保护已超时却仍继续写入；同时序列化写入和还原。
    static func withLock<T>(_ url: URL, failure: T, _ body: () -> T) -> T {
        let descriptor = open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return failure }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return failure }
        defer { flock(descriptor, LOCK_UN) }
        var opened = stat()
        var current = stat()
        guard fstat(descriptor, &opened) == 0, lstat(url.path, &current) == 0,
              opened.st_dev == current.st_dev, opened.st_ino == current.st_ino else { return failure }
        return body()
    }
}
