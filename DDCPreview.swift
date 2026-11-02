import AppKit
import Darwin
import Foundation

struct DDCTransaction: Codable {
    let display: HiDPIDisplay
    let feature: DDCFeature
    let original: UInt16
    let maximum: UInt16
    let deadlineUptime: TimeInterval
}

enum DDCPreviewResult {
    case unchanged(DDCReading)
    case preview(URL, DDCTransaction, DDCReading)
    case failure(String)
}

enum DDCPreview {
    static let previewSeconds: TimeInterval = 25
    private static let directory = appCacheDir.appendingPathComponent("ddc-preview", isDirectory: true)

    static func begin(display: HiDPIDisplay, feature: DDCFeature, percent: Double) -> DDCPreviewResult {
        guard percent.isFinite, percent >= 0, percent <= 100,
              let before = DDCService.readOne(display, feature: feature) else {
            return .failure("无法读取该显示器的硬件控制")
        }
        if UInt16((Double(before.maximum) * percent / 100).rounded()) == before.current {
            return .unchanged(before)
        }
        let transaction = DDCTransaction(display: display, feature: feature, original: before.current,
                                         maximum: before.maximum,
                                         deadlineUptime: ProcessInfo.processInfo.systemUptime + previewSeconds)
        let url = directory.appendingPathComponent(UUID().uuidString + ".json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(transaction).write(to: url, options: .atomic)
            guard startWorker(url) else {
                try? FileManager.default.removeItem(at: url)
                return .failure("无法启动硬件设置的自动还原保护，已取消调整")
            }
            let adjusted: Result<DDCReading, DDCError> = PreviewLock.withLock(
                url, failure: .failure(DDCError(message: "自动还原保护已结束，未调整硬件设置"))
            ) {
                guard ProcessInfo.processInfo.systemUptime < transaction.deadlineUptime else {
                    return .failure(DDCError(message: "自动还原保护已超时，未调整硬件设置"))
                }
                return DDCService.set(display, feature: feature, percent: percent, protectedPreview: true)
            }
            switch adjusted {
            case .success(let value):
                dtlog("ddc preview id=\(display.id) feature=\(feature.rawValue) original=\(before.current) actual=\(value.current)")
                return .preview(url, transaction, value)
            case .failure(let error):
                let restoreError = restoreNow(url, transaction: transaction)
                let detail = restoreError.flatMap { $0 == "自动还原已开始或预览已结束" ? nil : "；还原失败：\($0)" } ?? ""
                return .failure(error.message + detail)
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            return .failure("无法准备硬件设置的自动还原保护：\(error.localizedDescription)")
        }
    }

    static func confirm(_ url: URL) -> Bool {
        url.path.withCString { unlink($0) == 0 }
    }

    @discardableResult
    static func restoreNow(_ url: URL, transaction: DDCTransaction) -> String? {
        PreviewLock.withLock(url, failure: "自动还原已开始或预览已结束") {
            let claimed = url.appendingPathExtension("reverting")
            let claimedOK = url.path.withCString { old in claimed.path.withCString { new in rename(old, new) } }
            guard claimedOK == 0 else { return "自动还原已开始或预览已结束" }
            defer { try? FileManager.default.removeItem(at: claimed) }
            guard transaction.maximum > 0, transaction.original <= transaction.maximum,
                  let current = DDCService.readOne(transaction.display, feature: transaction.feature),
                  current.maximum == transaction.maximum else { return "无法读取原显示器的硬件控制" }
            if current.current == transaction.original { return nil }
            let percent = Double(transaction.original) * 100 / Double(transaction.maximum)
            switch DDCService.set(transaction.display, feature: transaction.feature, percent: percent, protectedPreview: true) {
            case .success(let result) where result.current == transaction.original:
                dtlog("ddc rollback id=\(transaction.display.id) feature=\(transaction.feature.rawValue) verified=true")
                return nil
            case .success:
                return "显示器未恢复到原硬件设置"
            case .failure(let error):
                return error.message
            }
        }
    }

    private static func startWorker(_ url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["--ddc-rollback-worker", url.path]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            var descriptor = pollfd(fd: pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 6000) > 0 else { return false }
            return String(data: pipe.fileHandleForReading.availableData, encoding: .utf8) == "READY\n" && process.isRunning
        } catch {
            return false
        }
    }

    static func runWorker(path: String) -> Never {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let prefix = directory.standardizedFileURL.path + "/"
        guard url.path.hasPrefix(prefix), url.pathExtension == "json",
              let data = try? Data(contentsOf: url),
              let transaction = try? JSONDecoder().decode(DDCTransaction.self, from: data),
              transaction.deadlineUptime > ProcessInfo.processInfo.systemUptime,
              transaction.deadlineUptime - ProcessInfo.processInfo.systemUptime <= previewSeconds + 5,
              let current = DDCService.readOne(transaction.display, feature: transaction.feature),
              current.current == transaction.original, current.maximum == transaction.maximum else { exit(1) }
        FileHandle.standardOutput.write(Data("READY\n".utf8))
        while ProcessInfo.processInfo.systemUptime < transaction.deadlineUptime {
            Thread.sleep(forTimeInterval: min(0.5, max(0.01, transaction.deadlineUptime - ProcessInfo.processInfo.systemUptime)))
        }
        let result = restoreNow(url, transaction: transaction)
        dtlog("ddc rollback-worker result=\(result ?? "success")")
        dtFlushLog()
        exit(0)
    }
}
