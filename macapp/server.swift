import Foundation
import Network
import CryptoKit

/// App 内嵌的极简 HTTP 服务。直接由 App 进程处理文件，
/// 因此只需要 App 本身拿到文件夹访问权限，不存在子进程继承问题。
final class SwiftServer {

    struct FolderInfo: Codable {
        let id: String
        let name: String
        let path: String
        let enabled: Bool?
    }

    /// 单例服务的引用，供窗口改状态时直接下发，无需重启监听。
    static weak var shared: SwiftServer?

    private var listener: NWListener?
    private var state: SyncState?
    private let queue = DispatchQueue(label: "netsync.server", qos: .userInitiated)

    private static let skipDirs: Set<String> = [
        ".git", ".obsidian", ".smart-env", ".netsync", ".cursor", ".claude",
        ".agents", ".copilot", "copilot", "node_modules", "__pycache__", ".venv",
        "videos",
    ]

    private static let ignoreSuffixes = [
        ".part", ".netsync-tmp", ".conflict-", ".sync-conflict-",
    ]

    private static let ignoreNames: Set<String> = [
        ".DS_Store", ".AppleDouble", ".LSOverride", ".netsync-state", ".netsync-sent",
    ]

    /// 数据库文件默认不同步：运行中的 SQLite/WAL 无法安全传输
    private static let ignoreExtensions: Set<String> = [
        "db", "db-wal", "db-shm", "sqlite", "sqlite-wal", "sqlite-shm",
    ]

    func start(state: SyncState, port: UInt16) -> Bool {
        SwiftServer.shared = self
        self.state = state
        stop()
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            l.stateUpdateHandler = { st in
                if case .failed(let e) = st { NSLog("NetSync listener failed: %@", "\(e)") }
            }
            l.start(queue: queue)
            listener = l
            return true
        } catch {
            print("listen error: \(error)")
            return false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// 配置变更（暂停设备等）无需重启监听，直接替换内存状态。
    func update(state newState: SyncState) {
        state = newState
    }

    // ---------------------------------------------------------------- 连接处理

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isDone, error in
            guard let self else { return }
            if error != nil { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }

            if let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<headerEnd.lowerBound], as: UTF8.self)
                let bodyStart = headerEnd.upperBound
                let length = self.contentLength(head)
                if buf.count - bodyStart >= length {
                    let body = buf.subdata(in: bodyStart..<(bodyStart + length))
                    self.route(conn, head: head, body: body)
                    return
                }
            } else if buf.count > 1_000_000 {
                conn.cancel()
                return
            }
            if isDone { conn.cancel(); return }
            self.receive(conn, buffer: buf)
        }
    }

    private func contentLength(_ head: String) -> Int {
        for line in head.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    private func header(_ head: String, _ name: String) -> String? {
        for line in head.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == name.lowercased() {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // ---------------------------------------------------------------- 路由

    private func route(_ conn: NWConnection, head: String, body: Data) {
        let firstLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { respond(conn, 400, json: ["error": "bad request"]); return }
        let method = String(parts[0])
        let rawPath = String(parts[1])
        let comps = rawPath.split(separator: "?", maxSplits: 1)
        let path = String(comps[0])
        var query: [String: String] = [:]
        if comps.count > 1 {
            for pair in comps[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                    let v = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                    query[k] = v
                }
            }
        }

        // 安装页 / 配对落地页 / APK 下载不需要令牌：手机还没装 App 时也能用
        if method == "GET", path == "/pair" {
            servePair(conn, state: state)
            return
        }
        // 扫码落地页的配对信息（无令牌，凭局域网直连获取）
        if method == "GET", path == "/api/pair" {
            guard let s = state else { respond(conn, 500, json: ["error": "not ready"]); return }
            respond(conn, 200, json: [
                "app": "NetSync", "v": 2,
                "name": Host.current().localizedName ?? "Mac",
                "host": lanIP(), "port": s.port, "token": s.token,
            ])
            return
        }
        if method == "GET", path == "/install" || path == "/netsync.apk" {
            serveInstall(conn, head: head, path: path)
            return
        }

        if header(head, "X-Sync-Token") != state?.token {
            respond(conn, 403, json: ["error": "bad token"])
            return
        }
        touchDevice(head)

        // Mac 端可以对单台设备暂停同步
        if let device = header(head, "X-Device-Id"), state?.paused?[device] == true {
            respond(conn, 423, json: ["error": "paused", "message": "电脑端已暂停这台设备的同步"])
            return
        }

        switch (method, path) {
        case ("GET", "/api/ping"):
            respond(conn, 200, json: [
                "ok": true, "app": "NetSync", "version": "2.0",
                "name": Host.current().localizedName ?? "Mac",
                "folders": state?.folders.count ?? 0,
            ])

        case ("GET", "/api/folders"):
            let items = (state?.folders ?? []).filter { $0.enabled ?? true }.map { f -> [String: Any] in
                ["id": f.id, "name": f.name,
                 "exists": FileManager.default.fileExists(atPath: f.path),
                 "readable": FileManager.default.isReadableFile(atPath: f.path)]
            }
            respond(conn, 200, json: ["folders": items])

        case ("GET", "/api/diag"):
            let folder = folder(query["folder"])
            let start = Date()
            let files = folder == nil ? 0 : walkOnly(folder!)
            respond(conn, 200, json: [
                "count": files,
                "seconds": Date().timeIntervalSince(start),
                "error": lastError ?? "",
            ])

        case ("GET", "/api/manifest"):
            guard let folder = folder(query["folder"]) else { respond(conn, 404, json: ["error": "unknown folder"]); return }
            let files = manifest(folder)
            if let err = lastError {
                respond(conn, 500, json: ["error": err])
            } else {
                let device = header(head, "X-Device-Id") ?? "unknown"
            SwiftServer.noteSync(device: device, folder: folder.id, summary: "\(files.count) 个文件")
            respond(conn, 200, json: ["folder": folder.id, "files": files])
            }

        case ("GET", "/api/file"):
            guard let folder = folder(query["folder"]),
                  let rel = query["p"],
                  let url = safeURL(folder, rel),
                  let data = FileManager.default.contents(atPath: url.path) else {
                respond(conn, 404, json: ["error": "not found"]); return
            }
            sendRaw(conn, status: 200, headers: [
                "Content-Type": "application/octet-stream",
                "Content-Length": "\(data.count)",
            ], body: data)

        case ("PUT", "/api/file"):
            guard let folder = folder(query["folder"]),
                  let rel = query["p"],
                  let url = safeURL(folder, rel) else {
                respond(conn, 400, json: ["error": "bad path"]); return
            }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            do {
                try body.write(to: url, options: .atomic)
                let dev = header(head, "X-Device-Id") ?? "unknown"
                SwiftServer.noteSync(device: dev, folder: folder.id, summary: "手机 → 电脑")
                if let m = header(head, "X-Mtime"), let ms = Double(m) {
                    try? FileManager.default.setAttributes(
                        [.modificationDate: Date(timeIntervalSince1970: ms / 1000)],
                        ofItemAtPath: url.path)
                }
                respond(conn, 200, json: ["ok": true])
            } catch {
                respond(conn, 500, json: ["error": "write failed"])
            }

        case ("DELETE", "/api/file"):
            guard let folder = folder(query["folder"]),
                  let rel = query["p"],
                  let url = safeURL(folder, rel) else {
                respond(conn, 400, json: ["error": "bad path"]); return
            }
            try? FileManager.default.removeItem(at: url)
            respond(conn, 200, json: ["ok": true])

        default:
            respond(conn, 404, json: ["error": "unknown endpoint"])
        }
    }

    private func folder(_ id: String?) -> Folder? {
        guard let id, let state else { return nil }
        return state.folders.first { $0.id == id && ($0.enabled ?? true) }
    }

    /// 手机没装 App 时，用浏览器打开 http://<mac-ip>:8765/install 就能下载并配对。
    private func serveInstall(_ conn: NWConnection, head: String, path: String) {
        if path == "/netsync.apk" {
            // 优先用 App 内自带的包，仓库里的开发目录仅作回退
            let bundled = bundleDir().appendingPathComponent("Resources/out/netsync.apk")
            let apk = FileManager.default.fileExists(atPath: bundled.path)
                ? bundled
                : baseDir().appendingPathComponent("out/netsync.apk")
            guard let data = FileManager.default.contents(atPath: apk.path) else {
                respond(conn, 404, json: ["error": "apk not found"])
                return
            }
            sendRaw(conn, status: 200, headers: [
                "Content-Type": "application/vnd.android.package-archive",
                "Content-Disposition": "attachment; filename=netsync.apk",
                "Content-Length": "\(data.count)",
            ], body: data)
            return
        }

        guard let s = state else {
            respond(conn, 500, json: ["error": "not ready"])
            return
        }
        let payload = "{\"v\":2,\"app\":\"NetSync\",\"host\":\"\(lanIP())\",\"port\":\(s.port),\"token\":\"\(s.token)\"}"
        let pairURL = "netsync://pair?data=" + (payload.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics) ?? "")
        let esc = { (t: String) in
            t.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
        }
        let html = """
        <!doctype html><html lang="zh-CN"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>安装内网同步</title>
        <style>
        body{font-family:-apple-system,"PingFang SC",sans-serif;margin:0;padding:28px 20px;
             background:#f7f7f8;color:#1d1d1f}
        h1{font-size:22px;margin:0 0 6px}
        p{color:#6e6e73;font-size:14px;line-height:1.6}
        a.btn{display:block;text-align:center;background:#0a84ff;color:#fff;text-decoration:none;
              padding:15px;border-radius:12px;font-size:17px;font-weight:600;margin:22px 0}
        code{background:#e9e9ec;padding:3px 6px;border-radius:5px;font-size:13px}
        .card{background:#fff;border-radius:12px;padding:16px;margin-top:16px}
        </style>
        <h1>安装「内网同步」</h1>
        <p>手机和这台 Mac 连同一个 Wi-Fi，然后点下面的按钮。</p>
        <a class="btn" href="/netsync.apk">下载并安装 App</a>
        <div class="card">
          <p style="margin:0 0 8px"><b>装好之后：</b></p>
          <p style="margin:0">1. 打开 App，允许「所有文件访问」<br>
             2. 回到本页再扫一次 Mac 上的二维码<br>
             3. 之后自动同步，不用再操作</p>
        </div>
        <div class="card">
          <p style="margin:0 0 6px"><b>也可以手动配对</b></p>
          <p style="margin:0">地址 <code>\(esc(lanIP())):\(s.port)</code><br>
             令牌 <code style="word-break:break-all">\(esc(s.token))</code></p>
          <p style="margin:8px 0 0;font-size:12px;color:#8e8e93">\(esc(String(pairURL.prefix(60))))…</p>
        </div>
        </html>
        """
        sendRaw(conn, status: 200, headers: [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Length": "\(html.utf8.count)",
        ], body: Data(html.utf8))
    }

    /// 扫码后的统一落地页：已装 App 可直接打开并配对，没装则先下载。
    private func servePair(_ conn: NWConnection, state s: SyncState?) {
        guard let s else { respond(conn, 500, json: ["error": "not ready"]); return }
        let host = lanIP()
        let payload = "{\"v\":2,\"app\":\"NetSync\",\"host\":\"\(host)\",\"port\":\(s.port),\"token\":\"\(s.token)\"}"
        let escaped = payload.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let pairURL = "netsync://pair?data=\(escaped)"

        func esc(_ t: String) -> String {
            t.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
        }

        let html = """
        <!doctype html><html lang="zh-CN"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>内网同步 · 配对</title>
        <style>
        :root{color-scheme:light}
        *{box-sizing:border-box}
        body{font-family:-apple-system,"PingFang SC",sans-serif;margin:0;padding:44px 22px;
             background:#F5F5F7;color:#1D1D1F;-webkit-font-smoothing:antialiased}
        .wrap{max-width:420px;margin:0 auto}
        .eyebrow{font-size:11px;letter-spacing:.14em;color:#86868B;text-transform:uppercase}
        h1{font-size:27px;letter-spacing:-.02em;margin:10px 0 6px}
        p.lead{color:#6E6E73;font-size:14px;line-height:1.6;margin:0}
        .card{background:#fff;border:1px solid #E5E5EA;border-radius:18px;padding:18px;margin-top:22px}
        .card h2{font-size:13px;margin:0 0 4px}
        .card p{margin:0;color:#6E6E73;font-size:12px;line-height:1.6}
        a.btn{display:block;text-align:center;text-decoration:none;border-radius:14px;
              padding:15px;font-size:15px;font-weight:600;margin-top:14px}
        .primary{background:#1D1D1F;color:#fff}
        .ghost{background:#fff;border:1px solid #E5E5EA;color:#1D1D1F}
        .row{display:flex;align-items:center;gap:10px;margin-top:14px}
        .dot{width:8px;height:8px;border-radius:50%;background:#34C759;flex:none}
        .muted{font-size:11px;color:#86868B}
        code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;
             background:#F4F4F6;padding:3px 7px;border-radius:6px;word-break:break-all}
        .step{display:flex;gap:10px;margin-top:12px;font-size:13px;color:#424245}
        .idx{width:18px;height:18px;border-radius:50%;background:#F2F2F4;color:#6E6E73;
             font-size:10px;display:flex;align-items:center;justify-content:center;flex:none}
        </style>
        <div class="wrap">
          <div class="eyebrow">NetSync · 局域网直传</div>
          <h1>连接这台 Mac</h1>
          <p class="lead">文件只在这台 Mac 和你的手机之间传输，不经过任何云端。</p>

          <a class="btn primary" href="\(pairURL)">打开「内网同步」并配对</a>
          <a class="btn ghost" href="/netsync.apk">先下载 Android 安装包</a>

          <div class="card">
            <h2>还没有安装 App？</h2>
            <p>先点上面的「下载」，装好后回到这里再点「打开并配对」。</p>
            <div class="step"><span class="idx">1</span><span>下载并安装内网同步</span></div>
            <div class="step"><span class="idx">2</span><span>回到本页，点「打开并配对」</span></div>
            <div class="step"><span class="idx">3</span><span>允许文件访问，之后自动同步</span></div>
          </div>

          <div class="card">
            <div class="row"><span class="dot"></span><b style="font-size:13px">\(esc(Host.current().localizedName ?? "Mac"))</b></div>
            <p style="margin-top:8px">地址 <code>\(esc(host)):\(s.port)</code></p>
            <p class="muted" style="margin-top:8px">两边需要连在同一个 Wi-Fi。</p>
          </div>
        </div>
        </html>
        """
        sendRaw(conn, status: 200, headers: [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Length": "\(html.utf8.count)",
        ], body: Data(html.utf8))
    }

    private func safeURL(_ folder: Folder, _ rel: String) -> URL? {
        let base = URL(fileURLWithPath: folder.path).standardizedFileURL
        let target = URL(fileURLWithPath: rel, relativeTo: base).standardizedFileURL
        guard target.path.hasPrefix(base.path) else { return nil }
        return target
    }

    // ---------------------------------------------------------------- 清单

    private var lastError: String?

    /// 设备 -> 文件夹 -> 同步摘要，供界面展示
    static var syncState: [String: [String: String]] = [:]

    static func noteSync(device: String, folder: String, summary: String) {
        syncState[device, default: [:]][folder] = summary
    }

    private func walkOnly(_ folder: Folder) -> Int {
        lastError = nil
        var n = 0
        var stack: [(URL, String)] = [(URL(fileURLWithPath: folder.path), "")]
        while let (dir, prefix) = stack.popLast() {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                options: []) else {
                lastError = "无法读取 \(dir.path)"
                return n
            }
            for url in entries {
                let name = url.lastPathComponent
                let rel = prefix.isEmpty ? name : prefix + "/" + name
                if SwiftServer.skipDirs.contains(name) || SwiftServer.skipDirs.contains(rel) { continue }
                if SwiftServer.ignoreSuffixes.contains(where: { name.contains($0) }) { continue }
                if SwiftServer.ignoreNames.contains(name) || SwiftServer.ignoreNames.contains(rel) { continue }
                if SwiftServer.ignoreExtensions.contains(url.pathExtension.lowercased()) { continue }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir { stack.append((url, rel)) } else { n += 1 }
            }
        }
        return n
    }

    private func manifest(_ folder: Folder) -> [[String: Any]] {
        lastError = nil
        let base = URL(fileURLWithPath: folder.path)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        var out: [[String: Any]] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        var stack: [(URL, String)] = [(base, "")]
        while let (dir, prefix) = stack.popLast() {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys,
                options: []) else {
                lastError = "无法读取 \(dir.path)，请在 Mac 上允许 NetSync 访问该文件夹"
                return []
            }
            for url in entries {
                let name = url.lastPathComponent
                let rel = prefix.isEmpty ? name : prefix + "/" + name
                if SwiftServer.skipDirs.contains(name) || SwiftServer.skipDirs.contains(rel) { continue }
                if SwiftServer.ignoreSuffixes.contains(where: { name.contains($0) }) { continue }
                if SwiftServer.ignoreNames.contains(name) || SwiftServer.ignoreNames.contains(rel) { continue }
                if SwiftServer.ignoreExtensions.contains(url.pathExtension.lowercased()) { continue }
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    stack.append((url, rel))
                    continue
                }
                let size = values?.fileSize ?? 0
                let mtime = values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
                out.append([
                    "p": rel,
                    "s": size,
                    "m": Int(mtime.timeIntervalSince1970 * 1000),
                    "h": sha256(url) ?? "",
                ])
            }
        }
        return out
    }

    private func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try? handle.read(upToCount: 1 << 20) ?? Data()
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // ---------------------------------------------------------------- 响应

    private func respond(_ conn: NWConnection, _ code: Int, json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        sendRaw(conn, status: code, headers: [
            "Content-Type": "application/json; charset=utf-8",
            "Content-Length": "\(data.count)",
        ], body: data)
    }

    private func sendRaw(_ conn: NWConnection, status: Int, headers: [String: String], body: Data) {
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "ERR")\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        conn.send(content: payload, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func touchDevice(_ head: String) {
        guard let id = header(head, "X-Device-Id"), !id.isEmpty else { return }
        let name = header(head, "X-Device-Name") ?? "Android"
        // 以磁盘上的最新配置为准再合并 peers，避免把外部改动（新增/移除目录）覆盖掉
        guard var s = loadState() ?? state else { return }
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let removed = PeerPresence.prune(&s, now: now)
            + PeerPresence.pruneDuplicates(of: id, name: name, in: &s, now: now)
        for old in removed { SwiftServer.syncState.removeValue(forKey: old) }
        s.peers[id] = Peer(name: name, lastSeen: formatter.string(from: now))
        state = s
        saveState(s)
    }
}
