import Foundation

/// 每次会改动文件的操作 (命令、写文件、改文件) 前后, 把相关文件夹拍个「快照」对比,
/// 把实际变化附在工具结果后面: 模型不用再猜命令做了什么 (例如 mv * 把新建的文件夹也挪走了)。
/// 只记文件名、大小、修改时间, 不读内容; 文件太多的文件夹不拍 (比如整个主目录)。
enum ChangeTracker {
    struct Entry: Equatable { let size: Int64; let mtime: TimeInterval; let dir: Bool }
    typealias Snapshot = [String: Entry]   // 绝对路径 -> 信息

    static let tracked: Set<String> = ["run_shell", "write_file", "edit_file"]
    static let skipDirs: Set<String> = [".git", "node_modules", ".build", "DerivedData", "venv", ".venv", "__pycache__", "Library", ".Trash"]

    /// 这次操作可能改动的文件夹: 工作目录 (不是主目录时) + 命令里提到的路径
    static func roots(for call: ToolCall, workDir: URL) -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        let fm = FileManager.default
        var out: [URL] = []
        func add(_ u: URL) {
            var u = u.standardizedFileURL
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: u.path, isDirectory: &isDir) || !isDir.boolValue { u = u.deletingLastPathComponent() }
            let p = u.path
            // 主目录、系统文件夹太大, 不拍
            // 只看用户自己的地方: 主目录里面、外接磁盘、临时文件夹; 系统目录 (/dev、/usr …) 不看
            let allowed = [home + "/", "/Volumes/", "/private/tmp/", "/tmp/", "/private/var/folders/", "/var/folders/"]
            guard p != home, allowed.contains(where: { p.hasPrefix($0) }), fm.fileExists(atPath: p) else { return }
            // 已经包含在别的里面, 或者是别的的上层 (上层往往很大, 例如临时文件夹): 都不加
            if out.contains(where: { p == $0.path || p.hasPrefix($0.path + "/") || $0.path.hasPrefix(p + "/") }) { return }
            out.append(u)
        }
        let a = call.args
        switch call.name {
        case "write_file", "edit_file":
            if let p = a["path"] as? String { add(Tools.expand(p, base: workDir)) }
        case "run_shell":
            add(workDir)
            let cmd = a["command"] as? String ?? ""
            for raw in cmd.split(whereSeparator: { " \t\n;|&><()".contains($0) }) {
                let t = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                guard t.hasPrefix("/") || t.hasPrefix("~/") else { continue }
                add(Tools.expand(t.replacingOccurrences(of: "*", with: ""), base: workDir))
                if out.count >= 4 { break }
            }
        default: break
        }
        return out
    }

    /// 拍快照; 文件太多 (超过 limit 项) 的文件夹不拍, 一个都拍不了返回 nil
    static func snapshot(_ roots: [URL], limit: Int = 8000, depth: Int = 4) -> Snapshot? {
        guard !roots.isEmpty else { return nil }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        var snap: Snapshot = [:]
        var any = false
        rootLoop: for root in roots {
            let base = root.pathComponents.count
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else { continue }
            var part: Snapshot = [:]
            for case let u as URL in en {
                let v = try? u.resourceValues(forKeys: Set(keys))
                let dir = v?.isDirectory == true
                if dir, skipDirs.contains(u.lastPathComponent) || u.pathComponents.count - base >= depth { en.skipDescendants() }
                if u.lastPathComponent == ".DS_Store" { continue }
                part[u.standardizedFileURL.path] = Entry(size: Int64(v?.fileSize ?? 0), mtime: v?.contentModificationDate?.timeIntervalSince1970 ?? 0, dir: dir)
                if part.count > limit { continue rootLoop }
            }
            any = true
            snap.merge(part) { a, _ in a }
        }
        return any ? snap : nil
    }

    /// 两次快照的差别, 写成给模型看的一段话
    static func describe(before: Snapshot, after: Snapshot, roots: [URL]) -> String {
        func rel(_ p: String) -> String {
            for r in roots where p.hasPrefix(r.path + "/") {
                let s = String(p.dropFirst(r.path.count + 1))
                return roots.count > 1 ? r.lastPathComponent + "/" + s : s
            }
            return p
        }
        func name(_ p: String, _ e: Entry?) -> String { rel(p) + (e?.dir == true ? "/" : "") }
        // 整个文件夹新增/删除时, 只报文件夹本身, 不逐个列里面的文件
        func topLevel(_ paths: [String]) -> [String] {
            let set = Set(paths)
            return paths.filter { p in !set.contains((p as NSString).deletingLastPathComponent) }.sorted()
        }
        let added = topLevel(after.keys.filter { before[$0] == nil })
        let removed = topLevel(before.keys.filter { after[$0] == nil })
        let modified = after.keys.filter { k in
            guard let b = before[k], let a = after[k], !a.dir else { return false }
            return a.size != b.size || a.mtime != b.mtime
        }.sorted()
        if added.isEmpty && removed.isEmpty && modified.isEmpty { return "\n【实际变化】没有任何文件变化。" }
        func list(_ xs: [String], _ snap: Snapshot) -> String {
            let shown = xs.prefix(12).map { name($0, snap[$0]) }.joined(separator: "、")
            return shown + (xs.count > 12 ? " 等 \(xs.count) 项" : "")
        }
        var parts: [String] = []
        if !added.isEmpty { parts.append("新增 \(added.count) 项：" + list(added, after)) }
        if !removed.isEmpty { parts.append("不见了 \(removed.count) 项：" + list(removed, before)) }
        if !modified.isEmpty { parts.append("内容变了 \(modified.count) 项：" + list(modified, after)) }
        return "\n【实际变化】" + parts.joined(separator: "；") + "。"
    }
}
