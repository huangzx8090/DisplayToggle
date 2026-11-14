import Cocoa

/// 已发布的更新信息
struct UpdateInfo {
    let version: String          // 1.9.0（已去掉 v 前缀）
    let tag: String              // v1.9.0
    let notes: String            // Release 正文（Markdown）
    let downloadURL: URL         // 安装包（.zip，内含 .app）
    let releaseURL: URL          // 发布页面，用于"稍后再说/查看详情"

    var sizeText: String? {
        guard let size = assetSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    fileprivate var assetSize: Int64?
}

enum UpdaterError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

/// 通过 GitHub Releases 检查并安装更新。
///
/// 设计取舍：
/// - 只用 GitHub 公开 API，不需要 token；
/// - 安装包是 zip（内含 .app），下载后做一次 ad-hoc 校验（包标识、可执行文件存在）；
/// - 替换流程交给一个独立的 shell 脚本：等本进程退出 → 备份旧包 → 替换 → 失败自动回滚，
///   这样不会出现"删了旧的、新的没装上"的黑屏式事故。
enum Updater {

    static let repository = "huangzx8090/DisplayToggle"
    private static let lastCheckKey = "lastUpdateCheckDate"
    private static let autoCheckInterval: TimeInterval = 24 * 60 * 60

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.github.huangzx.displaytoggle"
    }

    // MARK: 对外入口

    /// - Parameter interactive: 用户主动点击时为 true，失败/无更新都要给反馈；后台静默检查时只在有更新时提示。
    static func check(interactive: Bool) {
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        dtlog("update 检查更新（当前 \(currentVersion)）")

        resolveLatest { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let info):
                    if Version.isNewer(info.version, than: currentVersion) {
                        dtlog("update 发现新版本 \(info.version)")
                        present(info)
                    } else if interactive {
                        inform(title: "已是最新版本",
                               text: "当前版本 \(currentVersion)，没有可更新的内容。",
                               style: .informational)
                    }
                case .failure(let error):
                    dtlog("update 检查失败：\(error.localizedDescription)")
                    if interactive {
                        inform(title: "检查更新失败",
                               text: error.localizedDescription + "\n\n可以手动到 \(info(htmlURL: repository)) 查看。",
                               style: .warning)
                    }
                }
            }
        }
    }

    /// 启动时调用：超过 24 小时才静默检查一次。
    static func autoCheckIfNeeded() {
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > autoCheckInterval else { return }
        check(interactive: false)
    }

    // MARK: 网络

    /// 先走 GitHub API（信息最全）；失败（常见：未认证请求被限流 60 次/小时）时
    /// 退回不需要 API 的 releases/latest 重定向 + 固定下载地址。
    private static func resolveLatest(completion: @escaping (Result<UpdateInfo, Error>) -> Void) {
        requestLatest { apiResult in
            if case .success = apiResult {
                completion(apiResult)
                return
            }
            if case .failure(let error) = apiResult {
                dtlog("update API 不可用（\(error.localizedDescription)），改用 release 页面解析")
            }
            requestLatestViaWeb(completion: completion)
        }
    }

    private static func requestLatestViaWeb(completion: @escaping (Result<UpdateInfo, Error>) -> Void) {
        guard let url = URL(string: "https://github.com/\(repository)/releases/latest") else {
            completion(.failure(UpdaterError.message("发布地址无效")))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"        // 只跟随 302 拿到最终的 tag 地址，不下载整页
        request.setValue("DisplayToggle/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let finalURL = response?.url,
                  let tag = releaseTag(from: finalURL) else {
                completion(.failure(UpdaterError.message("无法从发布页面解析版本号")))
                return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let notesURL = "https://github.com/\(repository)/releases/latest/download/release-notes.md"
            let assetName = "DisplayToggle-\(tag)-macos-universal.zip"
            guard let asset = URL(string: "https://github.com/\(repository)/releases/latest/download/\(assetName)") else {
                completion(.failure(UpdaterError.message("安装包地址无效")))
                return
            }
            fetchText(notesURL) { notes in
                let body = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
                completion(.success(UpdateInfo(
                    version: version,
                    tag: tag,
                    notes: body?.isEmpty == false ? body! : "这个版本没有附带单独的更新说明，点「查看详情」可以在发布页面看到。",
                    downloadURL: asset,
                    releaseURL: finalURL)))
            }
        }.resume()
    }

    private static func releaseTag(from url: URL) -> String? {
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "tag"), index + 1 < parts.count else { return nil }
        let tag = parts[index + 1]
        return tag.isEmpty ? nil : tag
    }

    private static func fetchText(_ urlString: String, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.setValue("DisplayToggle/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data, let text = String(data: data, encoding: .utf8) else {
                completion(nil)
                return
            }
            completion(text)
        }.resume()
    }

    // MARK: 命令行自查

    /// `displaytoggle check-update`：不弹窗，直接把结果打到 stdout（便于脚本和排查）
    static func cliCheck() -> Never {
        print("当前版本：\(currentVersion)")
        print("更新源：https://github.com/\(repository)/releases/latest")
        let semaphore = DispatchSemaphore(value: 0)
        var status: Int32 = 0
        resolveLatest { result in
            switch result {
            case .success(let info):
                if Version.isNewer(info.version, than: currentVersion) {
                    print("发现新版本：\(info.version)")
                    print("更新说明：")
                    print(info.notes)
                    print("安装包：\(info.downloadURL.absoluteString)")
                } else {
                    print("已是最新版本")
                }
            case .failure(let error):
                print("检查失败：\(error.localizedDescription)")
                status = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(status)
    }

    private static func requestLatest(completion: @escaping (Result<UpdateInfo, Error>) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            completion(.failure(UpdaterError.message("发布地址无效")))
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DisplayToggle/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let hint = http.statusCode == 404
                    ? "还没有发布任何版本" : "GitHub 返回了 \(http.statusCode)"
                completion(.failure(UpdaterError.message("无法获取发布信息：\(hint)")))
                return
            }
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(UpdaterError.message("发布信息解析失败")))
                return
            }
            guard let info = parse(json) else {
                completion(.failure(UpdaterError.message("最新发布里没有可下载的安装包")))
                return
            }
            completion(.success(info))
        }.resume()
    }

    private static func parse(_ json: [String: Any]) -> UpdateInfo? {
        guard let tag = json["tag_name"] as? String else { return nil }
        let notes = (json["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let htmlURL = URL(string: json["html_url"] as? String ?? "")?.absoluteString ?? info(htmlURL: repository)

        let assets = json["assets"] as? [[String: Any]] ?? []
        let zips = assets.compactMap { asset -> (String, URL, Int64)? in
            guard let name = asset["name"] as? String, name.lowercased().hasSuffix(".zip"),
                  let url = URL(string: asset["browser_download_url"] as? String ?? "") else { return nil }
            return (name, url, (asset["size"] as? NSNumber)?.int64Value ?? 0)
        }
        // 优先当前架构的包，其次任意 zip
        let preferred = zips.first { $0.0.lowercased().contains(architectureTag) } ?? zips.first
        guard let asset = preferred else { return nil }

        var info = UpdateInfo(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                              tag: tag,
                              notes: notes.isEmpty ? "（这个版本没有填写更新说明）" : notes,
                              downloadURL: asset.1,
                              releaseURL: URL(string: htmlURL) ?? URL(string: "https://github.com/\(repository)")!)
        info.assetSize = asset.2
        return info
    }

    private static var architectureTag: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private static func info(htmlURL repository: String) -> String {
        "https://github.com/\(repository)/releases"
    }

    // MARK: 提示

    /// 更新详情：版本 + 更新内容 + 两个按钮
    private static func present(_ info: UpdateInfo) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "有新版本 \(info.version)"
        var subtitle = "当前版本 \(currentVersion)"
        if let size = info.sizeText { subtitle += "　·　安装包 \(size)" }
        alert.informativeText = subtitle
        alert.alertStyle = .informational
        alert.addButton(withTitle: "下载并更新")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "查看详情")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 210))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.font = .systemFont(ofSize: 12)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.string = info.notes
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        alert.accessoryView = scroll

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            downloadAndInstall(info)
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(info.releaseURL)
        default:
            break
        }
    }

    private static func inform(title: String, text: String, style: NSAlert.Style) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = style
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: 下载与安装

    private static func downloadAndInstall(_ info: UpdateInfo) {
        dtlog("update 开始下载 \(info.downloadURL.absoluteString)")
        var request = URLRequest(url: info.downloadURL)
        request.setValue("DisplayToggle/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120

        URLSession.shared.downloadTask(with: request) { location, response, error in
            DispatchQueue.main.async {
                if let error {
                    dtlog("update 下载失败：\(error.localizedDescription)")
                    inform(title: "下载失败", text: error.localizedDescription, style: .warning)
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    inform(title: "下载失败", text: "服务器返回了 \(http.statusCode)", style: .warning)
                    return
                }
                guard let location else {
                    inform(title: "下载失败", text: "没有拿到安装包", style: .warning)
                    return
                }
                do {
                    try install(zip: location, expecting: info.version)
                } catch {
                    dtlog("update 安装准备失败：\(error.localizedDescription)")
                    inform(title: "更新失败", text: error.localizedDescription, style: .warning)
                }
            }
        }.resume()
    }

    /// 解包 → 校验 → 交给替换脚本 → 退出当前进程
    private static func install(zip: URL, expecting version: String) throws {
        let fm = FileManager.default
        let appURL = Bundle.main.bundleURL.standardizedFileURL
        let parent = appURL.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else {
            throw UpdaterError.message("""
            没有权限写入 \(parent.path)。
            请把屏衡应用移到 ~/Applications 或你有权限的目录后再试。
            """)
        }

        let workDir = fm.temporaryDirectory.appendingPathComponent("DisplayToggleUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let payload = workDir.appendingPathComponent("payload.zip")
        try fm.copyItem(at: zip, to: payload)

        let unpacked = workDir.appendingPathComponent("unpacked")
        try run("/usr/bin/ditto", ["-x", "-k", payload.path, unpacked.path])

        let contents = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
        guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdaterError.message("安装包里没有找到 .app")
        }

        let newPlist = newApp.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: newPlist)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        guard let newID = plist?["CFBundleIdentifier"] as? String, newID == bundleIdentifier else {
            throw UpdaterError.message("安装包的标识与当前应用不一致，已中止更新")
        }
        let executable = newApp.appendingPathComponent("Contents/MacOS/DisplayToggle")
        guard fm.isExecutableFile(atPath: executable.path) else {
            throw UpdaterError.message("安装包里缺少可执行文件，已中止更新")
        }

        // 下载来的包带隔离标记，ad-hoc 签名会被 Gatekeeper 拦，先清掉
        _ = try? run("/usr/bin/xattr", ["-cr", newApp.path])

        // 换到脚本自己管理的临时目录，避免 defer 删掉它
        let staged = fm.temporaryDirectory.appendingPathComponent("DisplayToggle-staged-\(UUID().uuidString)")
        try fm.copyItem(at: newApp, to: staged)
        _ = try? run("/usr/bin/xattr", ["-cr", staged.path])

        try launchSwapScript(app: appURL.path, staged: staged.path, pid: ProcessInfo.processInfo.processIdentifier,
                             version: version)
        dtlog("update 已交给替换脚本，退出当前进程")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    private static func launchSwapScript(app: String, staged: String, pid: Int32, version: String) throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("displaytoggle-update-\(UUID().uuidString).sh")
        let script = """
        #!/bin/sh
        set -u
        APP="$1"; NEW="$2"; OLD_PID="$3"; VERSION="$4"
        # 等旧进程真正退出
        for _ in $(seq 1 150); do
            kill -0 "$OLD_PID" 2>/dev/null || break
            sleep 0.1
        done
        BACKUP="${APP}.old-$(date +%s)"
        /bin/mv "$APP" "$BACKUP" || exit 1
        if /usr/bin/ditto "$NEW" "$APP" && /usr/bin/xattr -cr "$APP" && /usr/bin/open "$APP"; then
            /bin/rm -rf "$BACKUP" "$NEW"
            exit 0
        fi
        # 失败回滚
        /bin/rm -rf "$APP"
        /bin/mv "$BACKUP" "$APP"
        /usr/bin/open "$APP"
        exit 1
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path, app, staged, String(pid), version]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdaterError.message("\(URL(fileURLWithPath: path).lastPathComponent) 执行失败（\(process.terminationStatus)）")
        }
        return process.terminationStatus
    }
}
