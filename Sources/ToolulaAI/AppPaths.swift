import Foundation

/// Toolula 的所有文件都放在用户主目录下的一个文件夹里, 按类别分好:
///
///     ~/Toolula/
///       Images/       绘图页生成的图片
///       Videos/       视频页生成的视频
///       Exports/      修图时交给 Photoshop / Luminar 等程序的照片、LUT
///       Chats/        对话 (每个对话一个文件)
///       Attachments/  对话里的图片附件、截图
///       Backups/      对话的自动备份
///       Data/         记忆、技能、自动化、图片/视频记录、设置类文件
///       Logs/         运行日志、诊断报告
///       Cache/        可以随时清掉的缓存 (提示词缓存、预览、修图临时图)
///       Engines/      本地 AI 引擎 (Python、MLX、ComfyUI 等程序文件)
///       Models/       Toolula 自己下载的模型 (内置引擎的对话模型、修图擦除模型)
///
/// 旧版本放在 ~/Library/Application Support/ToolulaAI、~/Pictures/Toolula AI、~/Movies/Toolula AI,
/// 第一次启动时由 `StorageMigration` 搬过来, 旧的 Application Support 位置换成指向新文件夹的链接
/// (引擎的 Python 环境里写死了旧路径, 有这个链接就不用重装)。
enum AppPaths {
    /// 测试搬家时可以用环境变量 TOOLULA_TEST_HOME 换一个假的主目录 (新旧位置都在它下面, 不碰真实数据)
    static let home: URL = {
        if let h = ProcessInfo.processInfo.environment["TOOLULA_TEST_HOME"], !h.isEmpty { return URL(fileURLWithPath: h, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }()
    static let root = home.appendingPathComponent("Toolula", isDirectory: true)
    /// 旧版本的数据文件夹 (迁移后是指向 root 的链接)
    static let legacySupport = home.appendingPathComponent("Library/Application Support/ToolulaAI")

    static let images = dir("Images")
    static let videos = dir("Videos")
    static let exports = dir("Exports")
    static let chats = dir("Chats")
    static let attachments = dir("Attachments")
    static let backups = dir("Backups")
    static let data = dir("Data")
    static let logs = dir("Logs")
    static let cache = dir("Cache")
    static let engines = dir("Engines")
    static let models = dir("Models")

    /// 兼容旧代码: 原来的"数据文件夹"就是根目录
    static var support: URL { root }

    static func dir(_ name: String) -> URL {
        let u = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func cacheDir(_ name: String) -> URL {
        let u = cache.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func dataFile(_ name: String) -> URL { data.appendingPathComponent(name) }
    static func log(_ name: String) -> URL { logs.appendingPathComponent(name) }

    /// 在文件夹里找一个不重名的文件名 (ComfyUI 的编号会从 00001 重新开始, 不能覆盖以前的作品)
    static func unique(_ name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var u = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: u.path) else { return u }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var i = 2
        repeat {
            u = folder.appendingPathComponent("\(base)-\(i)" + (ext.isEmpty ? "" : ".\(ext)"))
            i += 1
        } while fm.fileExists(atPath: u.path)
        return u
    }
}

/// 一次性搬家: 旧位置 -> ~/Toolula/<类别>。同一个磁盘上只是改名, 很快, 不会多占空间。
enum StorageMigration {
    static let marker = ".toolula-layout-1"
    static var done: Bool { FileManager.default.fileExists(atPath: AppPaths.root.appendingPathComponent(marker).path) }

    /// 搬了哪些东西 (日志和自测用)
    nonisolated(unsafe) static var report: [String] = []

    static func runIfNeeded() {
        moveEditedPhotos()
        guard !done else { return }
        let fm = FileManager.default
        let r = AppPaths.root
        try? fm.createDirectory(at: r, withIntermediateDirectories: true)
        var prefixes: [(String, String)] = []   // 旧路径前缀 -> 新路径前缀, 用来改写记录里的文件位置

        let old = AppPaths.legacySupport
        let oldIsDir = (try? old.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
            && fm.fileExists(atPath: old.path)
        if oldIsDir {
            // 先挪 Engines 里的缓存, 再整体挪 Engines
            let plan: [(String, URL)] = [
                ("conversations", AppPaths.chats),
                ("attachments", AppPaths.attachments),
                ("backups", AppPaths.backups),
                ("Engines/mlx-cache", AppPaths.cache.appendingPathComponent("MLX")),
                ("Engines/uv-cache", AppPaths.cache.appendingPathComponent("uv")),
                ("Engines", AppPaths.engines),
                ("Models", AppPaths.models.appendingPathComponent("Retouch")),
                ("LocalModels", AppPaths.models.appendingPathComponent("Chat")),
                ("skills", AppPaths.data.appendingPathComponent("Skills")),
                ("pids", AppPaths.cache.appendingPathComponent("run")),
            ]
            for (name, dest) in plan {
                let src = old.appendingPathComponent(name)
                guard fm.fileExists(atPath: src.path) else { continue }
                if moveMerge(src, dest) {
                    prefixes.append((src.path + "/", dest.path + "/"))
                    report.append("\(name) -> \(dest.path)")
                }
            }
            // 剩下的单个文件按类型分
            for f in (try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)) ?? [] {
                let n = f.lastPathComponent
                if n == ".DS_Store" { try? fm.removeItem(at: f); continue }
                let dest: URL
                if n.hasPrefix("preview-") { try? fm.removeItem(at: f); report.append("删除预览临时文件 \(n)"); continue }
                else if n.hasSuffix(".log") { dest = AppPaths.logs }
                else if n.hasPrefix("conversations.json.") { dest = AppPaths.backups }
                else { dest = AppPaths.data }
                let to = AppPaths.unique(n, in: dest)
                if (try? fm.moveItem(at: f, to: to)) != nil {
                    prefixes.append((f.path, to.path))
                    report.append("\(n) -> \(to.path)")
                }
            }
            // 旧文件夹空了: 换成指向新文件夹的链接 (引擎的 Python 环境里写死了旧路径)
            if ((try? fm.contentsOfDirectory(atPath: old.path)) ?? ["?"]).isEmpty {
                try? fm.removeItem(at: old)
                try? fm.createSymbolicLink(at: old, withDestinationURL: r)
            } else {
                report.append("旧文件夹里还有没搬走的文件，保留在原处")
            }
        }

        // 生成的作品
        let home = AppPaths.home
        for (oldDir, dest) in [(home.appendingPathComponent("Pictures/Toolula AI"), AppPaths.images),
                               (home.appendingPathComponent("Movies/Toolula AI"), AppPaths.videos)] {
            guard fm.fileExists(atPath: oldDir.path) else { continue }
            for f in (try? fm.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                if f.lastPathComponent == ".DS_Store" { try? fm.removeItem(at: f); continue }
                // 子文件夹是修图导出 (Photoshop / Luminar / LUTs), 放进 Exports
                let isDir = (try? f.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if isDir { if moveMerge(f, AppPaths.exports.appendingPathComponent(f.lastPathComponent)) { prefixes.append((f.path + "/", AppPaths.exports.appendingPathComponent(f.lastPathComponent).path + "/")) }; continue }
                let to = AppPaths.unique(f.lastPathComponent, in: dest)
                if (try? fm.moveItem(at: f, to: to)) != nil { prefixes.append((f.path, to.path)) }
            }
            if ((try? fm.contentsOfDirectory(atPath: oldDir.path)) ?? ["?"]).isEmpty { try? fm.removeItem(at: oldDir) }
            report.append("\(oldDir.lastPathComponent) (\(oldDir.deletingLastPathComponent().lastPathComponent)) -> \(dest.path)")
        }

        // 记录里写的是绝对路径: 改成新位置
        if !prefixes.isEmpty {
            let files = [AppPaths.data, AppPaths.chats].flatMap { d in
                ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
            }
            for f in files { rewrite(f, prefixes) }
        }
        fm.createFile(atPath: r.appendingPathComponent(marker).path, contents: Data(report.joined(separator: "\n").utf8))
    }

    /// 旧版本 (和 Lightroom 插件的拖放小程序) 把修好的照片放在 ~/Pictures/Toolula AI修图/<时间>
    static func moveEditedPhotos() {
        let old = AppPaths.home.appendingPathComponent("Pictures/Toolula AI修图")
        guard FileManager.default.fileExists(atPath: old.path) else { return }
        if moveMerge(old, AppPaths.exports.appendingPathComponent("Edited Photos")) { report.append("Toolula AI修图 -> Exports/Edited Photos") }
    }

    /// 把 src 挪到 dest。dest 已经存在时逐个挪里面的文件 (重名的保留两份)
    @discardableResult
    static func moveMerge(_ src: URL, _ dest: URL) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dest.path, isDirectory: &isDir) {
            guard isDir.boolValue else { return false }
            for f in (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? [] {
                let to = dest.appendingPathComponent(f.lastPathComponent)
                if fm.fileExists(atPath: to.path) {
                    var sub: ObjCBool = false
                    if fm.fileExists(atPath: f.path, isDirectory: &sub), sub.boolValue { moveMerge(f, to); continue }
                    try? fm.moveItem(at: f, to: AppPaths.unique(f.lastPathComponent, in: dest))
                } else {
                    try? fm.moveItem(at: f, to: to)
                }
            }
            if ((try? fm.contentsOfDirectory(atPath: src.path)) ?? ["?"]).isEmpty { try? fm.removeItem(at: src) }
            return true
        }
        return (try? fm.moveItem(at: src, to: dest)) != nil
    }

    /// 改写 JSON 文件里的路径 (JSONEncoder 默认把 / 写成 \/, 两种写法都处理)
    static func rewrite(_ file: URL, _ prefixes: [(String, String)]) {
        guard var s = try? String(contentsOf: file, encoding: .utf8) else { return }
        let before = s
        for (a, b) in prefixes.sorted(by: { $0.0.count > $1.0.count }) {
            s = s.replacingOccurrences(of: a, with: b)
            s = s.replacingOccurrences(of: a.replacingOccurrences(of: "/", with: "\\/"), with: b.replacingOccurrences(of: "/", with: "\\/"))
        }
        if s != before { try? Data(s.utf8).write(to: file, options: .atomic) }
    }
}

/// 存储空间: 各类别占多少、清理缓存
enum StorageUsage {
    struct Item: Identifiable { let id: String; let url: URL; let bytes: Int64 }

    static var categories: [(String, URL)] {
        [("Images", AppPaths.images), ("Videos", AppPaths.videos), ("Exports", AppPaths.exports), ("Chats", AppPaths.chats), ("Attachments", AppPaths.attachments),
         ("Backups", AppPaths.backups), ("Data", AppPaths.data), ("Logs", AppPaths.logs), ("Cache", AppPaths.cache),
         ("Engines", AppPaths.engines), ("Models", AppPaths.models)]
    }

    static func size(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey], options: []) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink == true { continue }
            total += Int64(v?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static func measure() -> [Item] { categories.map { Item(id: $0.0, url: $0.1, bytes: size($0.1)) } }

    /// 启动时的例行清理: 预览和修图临时图超过 1 天删掉, 日志超过 5 MB 只留最后 1 MB
    static func routineCleanup() {
        let fm = FileManager.default
        let dayAgo = Date().addingTimeInterval(-86_400)
        for d in [AppPaths.cacheDir("Previews"), AppPaths.cacheDir("Photo")] {
            for f in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                if let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m < dayAgo { try? fm.removeItem(at: f) }
            }
        }
        // 旧版本放在系统临时文件夹里的修图临时图
        let oldTmp = fm.temporaryDirectory.appendingPathComponent("ToolulaAI", isDirectory: true)
        if fm.fileExists(atPath: oldTmp.path) { try? fm.removeItem(at: oldTmp) }
        for f in (try? fm.contentsOfDirectory(at: AppPaths.logs, includingPropertiesForKeys: [.fileSizeKey])) ?? [] where f.pathExtension == "log" {
            guard let n = try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize, n > 5_000_000,
                  let h = try? FileHandle(forReadingFrom: f) else { continue }
            try? h.seek(toOffset: UInt64(n - 1_000_000))
            let tail = h.readDataToEndOfFile(); try? h.close()
            try? tail.write(to: f, options: .atomic)
        }
    }

    /// MTP 引擎的提示词缓存 (硬盘层) 超过上限时删掉最久没用的。
    /// 引擎自己也会按 APC_DISK_MAX_GB 清理, 但只在写入新缓存时才清; 启动时 (引擎还没开) 先清一次。
    @discardableResult
    static func trimMLXCache(maxBytes: Int64 = 4 << 30) -> Int64 {
        let fm = FileManager.default
        let apc = AppPaths.cache.appendingPathComponent("MLX/apc")
        guard let e = fm.enumerator(at: apc, includingPropertiesForKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey]) else { return 0 }
        var files: [(URL, Date, Int64)] = []
        for case let f as URL in e where f.pathExtension == "safetensors" {
            let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey])
            files.append((f, v?.contentModificationDate ?? .distantPast, Int64(v?.totalFileAllocatedSize ?? 0)))
        }
        var total = files.reduce(0) { $0 + $1.2 }
        guard total > maxBytes else { return 0 }
        let target = maxBytes * 9 / 10
        var freed: Int64 = 0
        for (f, _, n) in files.sorted(by: { $0.1 < $1.1 }) where total > target {
            if (try? fm.removeItem(at: f)) != nil { total -= n; freed += n }
        }
        return freed
    }

    /// 清掉可以重新生成的缓存。返回释放的字节数
    @discardableResult
    static func clearCache() -> Int64 {
        let fm = FileManager.default
        let before = size(AppPaths.cache)
        for f in (try? fm.contentsOfDirectory(at: AppPaths.cache, includingPropertiesForKeys: nil)) ?? [] where f.lastPathComponent != "run" {
            try? fm.removeItem(at: f)
        }
        return before - size(AppPaths.cache)
    }
}
