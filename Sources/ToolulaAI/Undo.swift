import Foundation

/// 撤销一次任务的文件改动。
/// 任务第一次要改文件之前: 工作目录不大 (不是主目录、不超过 2 万项) 就整个克隆一份 (APFS 克隆, 几乎不占空间);
/// 另外 write_file / edit_file 改的每个文件单独备份 (工作目录以外的也能恢复)。
/// 撤销时: 现在的内容先移到废纸篓 (还能找回), 再把备份放回去。
@MainActor
final class UndoStore: ObservableObject {
    static let shared = UndoStore()

    struct Record: Codable, Identifiable {
        var id: UUID                    // 这一轮的用户消息 id
        var conversation: UUID
        var created = Date()
        var dirs: [String: String] = [:]    // 整个克隆的文件夹: 原位置 -> 备份
        var files: [String: String] = [:]   // 原文件路径 -> 备份路径 ("" = 原来没有这个文件, 撤销时删掉)
        var undone = false
    }

    @Published private(set) var records: [UUID: Record] = [:]
    static var dir: URL { AppPaths.cacheDir("Undo") }
    private var index: URL { Self.dir.appendingPathComponent("index.json") }
    private let fm = FileManager.default

    init() {
        if let d = try? Data(contentsOf: index), let r = try? JSONDecoder().decode([Record].self, from: d) {
            records = Dictionary(uniqueKeysWithValues: r.map { ($0.id, $0) })
        }
        prune()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(Array(records.values)) { try? d.write(to: index, options: .atomic) }
    }

    /// 只留最近 30 次、7 天以内的
    private func prune() {
        let keep = Set(records.values.sorted { $0.created > $1.created }.prefix(30).filter { Date().timeIntervalSince($0.created) < 7 * 86400 }.map(\.id))
        for (id, _) in records where !keep.contains(id) {
            try? fm.removeItem(at: Self.dir.appendingPathComponent(id.uuidString))
            records[id] = nil
        }
        save()
    }

    /// 要改文件之前调用
    func prepare(turn: UUID, conversation: UUID, workDir: URL, call: ToolCall) async {
        let folder = Self.dir.appendingPathComponent(turn.uuidString)
        var r = records[turn] ?? Record(id: turn, conversation: conversation)
        // 要动的文件夹 (工作目录、命令里提到的文件夹): 还没备份过、又不太大的, 整个克隆
        for root in ChangeTracker.roots(for: call, workDir: workDir) where Tools.normalize(call).name == "run_shell" || records[turn] == nil {
            let p = root.standardizedFileURL.path
            if r.dirs.keys.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) { continue }
            let dst = folder.appendingPathComponent("dir-\(r.dirs.count)")
            let ok = await Task.detached { () -> Bool in
                guard Self.clonable(root) else { return false }
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                return (try? FileManager.default.copyItem(at: root, to: dst)) != nil
            }.value
            if ok { r.dirs[p] = dst.path }
        }
        // 写文件、改文件: 不在克隆范围里的, 单独备份这个文件 (每个文件只备份第一次的样子)
        let name = Tools.normalize(call).name
        if name == "write_file" || name == "edit_file", let p = call.args["path"] as? String {
            let url = Tools.expand(p, base: workDir).standardizedFileURL
            let covered = r.dirs.keys.contains { url.path.hasPrefix($0 + "/") }
            if !covered, r.files[url.path] == nil {
                if fm.fileExists(atPath: url.path) {
                    let dst = folder.appendingPathComponent("files/\(r.files.count)-" + url.lastPathComponent)
                    try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    r.files[url.path] = (try? fm.copyItem(at: url, to: dst)) != nil ? dst.path : nil
                } else {
                    r.files[url.path] = ""
                }
            }
        }
        records[turn] = r
        save()
    }

    /// 工作目录可以整个克隆: 不是主目录/系统目录, 不超过 2 万项
    nonisolated static func clonable(_ root: URL) -> Bool {
        let p = root.path
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        guard p != home, p != "/", !p.hasPrefix("/System"), !p.hasPrefix("/Applications"), p.count > 1,
              FileManager.default.fileExists(atPath: p) else { return false }
        guard let en = FileManager.default.enumerator(atPath: p) else { return false }
        var n = 0
        while en.nextObject() != nil { n += 1; if n > 20000 { return false } }
        return true
    }

    func record(for turn: UUID) -> Record? {
        guard let r = records[turn], !r.undone, !r.dirs.isEmpty || !r.files.isEmpty else { return nil }
        return r
    }

    /// 撤销: 返回给用户看的结果
    func undo(_ turn: UUID) -> String {
        guard var r = records[turn], !r.undone else { return String(localized: "没有可以撤销的改动") }
        var restored = 0, failed: [String] = []
        // 外层的先恢复, 里层的就不用再管 (外层恢复时已经包括了)
        for root in r.dirs.keys.sorted() {
            guard let backup = r.dirs[root] else { continue }
            let rootURL = URL(fileURLWithPath: root), backupURL = URL(fileURLWithPath: backup)
            // 现在的内容先移到废纸篓, 再把备份的内容克隆回来
            for item in (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? [] {
                if (try? fm.trashItem(at: item, resultingItemURL: nil)) == nil { try? fm.removeItem(at: item) }
            }
            for item in (try? fm.contentsOfDirectory(at: backupURL, includingPropertiesForKeys: nil)) ?? [] {
                do { try fm.copyItem(at: item, to: rootURL.appendingPathComponent(item.lastPathComponent)); restored += 1 }
                catch { failed.append(item.lastPathComponent) }
            }
        }
        for (orig, backup) in r.files {
            let o = URL(fileURLWithPath: orig)
            if fm.fileExists(atPath: orig) { _ = try? fm.trashItem(at: o, resultingItemURL: nil) }
            if backup.isEmpty { restored += 1; continue }   // 原来没有的文件: 移到废纸篓就是撤销
            do { try fm.copyItem(at: URL(fileURLWithPath: backup), to: o); restored += 1 }
            catch { failed.append(o.lastPathComponent) }
        }
        r.undone = true
        records[turn] = r
        save()
        var s = String(localized: "已撤销这次任务的文件改动（改动后的内容在废纸篓里，需要时可以找回）。")
        if !failed.isEmpty { s += "\n" + String(localized: "这些没能恢复：\(failed.joined(separator: "、"))") }
        if r.dirs.isEmpty { s += "\n" + String(localized: "注意：涉及的文件夹太大没有整体备份，只恢复了 AI 用写文件/改文件改过的文件；命令做的改动（移动、删除等）没法撤销。") }
        return s
    }
}
