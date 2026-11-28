import Foundation

/// 读写 JSON 存储的统一入口:
/// - 写入一律原子写 (先写临时文件再替换, 写到一半崩溃也不会留下半个文件)
/// - 读到坏文件时, 先复制一份 `<名字>.corrupt-<时间>.json` 保留下来, 绝不直接覆盖
enum SafeJSON {
    nonisolated(unsafe) static var lastErrors: [String] = []

    /// preserve: 读坏时是否在原位置旁复制一份留底 (调用方自己挪走坏文件时传 false)
    static func load<T: Decodable>(_ type: T.Type, from url: URL, preserve: Bool = true) -> T? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: d)
        } catch {
            if preserve { preserveCorrupt(url, error: error) } else { note("读取失败 \(url.lastPathComponent): \(error)") }
            return nil
        }
    }

    @discardableResult
    static func save<T: Encodable>(_ value: T, to url: URL) -> Bool {
        guard let d = try? JSONEncoder().encode(value) else { return false }
        return write(d, to: url)
    }

    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            note("写入失败 \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    /// 把读不出来的文件复制一份留底, 返回副本位置
    @discardableResult
    static func preserveCorrupt(_ url: URL, error: Error? = nil) -> URL? {
        let stamp = Self.stamp()
        let copy = url.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).\(url.pathExtension.isEmpty ? "json" : url.pathExtension)")
        try? FileManager.default.copyItem(at: url, to: copy)
        note("读取失败 \(url.lastPathComponent)，已保留副本 \(copy.lastPathComponent): \(error.map { "\($0)" } ?? "-")")
        return copy
    }

    static func stamp(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: d)
    }

    static func note(_ s: String) {
        lastErrors.append(s)
        if lastErrors.count > 50 { lastErrors.removeFirst(lastErrors.count - 50) }
        NSLog("[Leonix storage] %@", s)
    }
}

/// 对话存储: 每个对话一个文件 `conversations/<uuid>.json`, 只写改动过的那个。
/// 顺序记在 `conversations/index.json`。启动时自动备份整个文件夹 (保留最近 `keepBackups` 份)。
/// 兼容旧版的单个 `conversations.json`: 第一次启动时先备份原文件, 再拆分迁移。
final class ConversationStorage: @unchecked Sendable {
    let root: URL
    let dir: URL
    let backups: URL
    let legacy: URL
    var keepBackups = 5
    private let queue = DispatchQueue(label: "toolula.conversations.storage")
    private var saved: [UUID: Conversation] = [:]     // 上次写到硬盘的内容 (只在 queue 上访问)
    private var savedOrder: [UUID] = []

    convenience init(root: URL) {
        self.init(dir: root.appendingPathComponent("conversations", isDirectory: true),
                  backups: root.appendingPathComponent("backups", isDirectory: true),
                  legacy: root.appendingPathComponent("conversations.json"))
    }

    init(dir: URL, backups: URL, legacy: URL) {
        self.root = dir.deletingLastPathComponent()
        self.dir = dir
        self.backups = backups
        self.legacy = legacy
    }

    private var indexFile: URL { dir.appendingPathComponent("index.json") }
    func file(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }

    /// 读出全部对话 (按上次保存的顺序)。需要时先迁移旧文件。
    func load() -> [Conversation] {
        queue.sync {
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            migrateLegacyIfNeeded()
            var byId: [UUID: Conversation] = [:]
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.pathExtension == "json" && f.lastPathComponent != "index.json" {
                guard UUID(uuidString: f.deletingPathExtension().lastPathComponent) != nil else { continue }
                if let c = SafeJSON.load(Conversation.self, from: f, preserve: false) {
                    byId[c.id] = c
                } else {
                    // 坏文件: 原样挪进 corrupt/ 保留, 不参与之后的读写
                    let bad = dir.appendingPathComponent("corrupt", isDirectory: true)
                    try? fm.createDirectory(at: bad, withIntermediateDirectories: true)
                    try? fm.moveItem(at: f, to: bad.appendingPathComponent("\(f.deletingPathExtension().lastPathComponent).\(SafeJSON.stamp()).json"))
                }
            }
            let order = SafeJSON.load([UUID].self, from: indexFile) ?? []
            var list = order.compactMap { byId.removeValue(forKey: $0) }
            // 索引里没有的 (例如索引丢了) 按更新时间排在前面
            list = byId.values.sorted { $0.updated > $1.updated } + list
            saved = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            savedOrder = list.map(\.id)
            return list
        }
    }

    /// 旧版 conversations.json -> 每个对话一个文件。原文件先备份, 迁移成功后改名为 .migrated 保留。
    private func migrateLegacyIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path) else { return }
        try? fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let backup = backups.appendingPathComponent("conversations-legacy-\(SafeJSON.stamp()).json")
        guard (try? fm.copyItem(at: legacy, to: backup)) != nil else { return }   // 备份不成功就不动原文件
        guard let list = SafeJSON.load([Conversation].self, from: legacy) else { return }   // 读不出来: 原文件保持不动
        let existing = Set(((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []))
        var order = SafeJSON.load([UUID].self, from: indexFile) ?? []
        for c in list {
            // 新格式里已经有同一个对话 (例如上次迁移到一半) 就以新格式为准
            if !existing.contains("\(c.id.uuidString).json") {
                guard SafeJSON.save(c, to: file(c.id)) else { return }
            }
            if !order.contains(c.id) { order.append(c.id) }
        }
        guard SafeJSON.save(order, to: indexFile) else { return }
        try? fm.moveItem(at: legacy, to: root.appendingPathComponent("conversations.json.migrated-\(SafeJSON.stamp())"))
    }

    /// 只写和上次保存不同的对话; 删掉已经不在列表里的对话文件。
    func save(_ list: [Conversation], sync: Bool = false) {
        let work = { [self] in
            for c in list where saved[c.id] != c {
                if SafeJSON.save(c, to: file(c.id)) { saved[c.id] = c }
            }
            let ids = Set(list.map(\.id))
            for id in saved.keys where !ids.contains(id) {
                try? FileManager.default.removeItem(at: file(id))
                saved[id] = nil
            }
            let order = list.map(\.id)
            if order != savedOrder, SafeJSON.save(order, to: indexFile) { savedOrder = order }
        }
        if sync { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    /// 等所有排队的写入完成 (退出前调用)
    func flush() { queue.sync {} }

    /// 把整个对话文件夹复制到 backups/conversations-<时间>/, 只保留最近 keepBackups 份
    /// minInterval: 离上一份备份不到这么久就跳过 (避免频繁启动把旧备份挤掉)
    @discardableResult
    func backup(minInterval: TimeInterval = 0) -> URL? {
        if minInterval > 0, let last = backupList.first,
           let d = (try? last.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
           Date().timeIntervalSince(d) < minInterval { return nil }
        return queue.sync {
            let fm = FileManager.default
            guard fm.fileExists(atPath: dir.path) else { return nil }
            try? fm.createDirectory(at: backups, withIntermediateDirectories: true)
            let dest = backups.appendingPathComponent("conversations-\(SafeJSON.stamp())", isDirectory: true)
            guard !fm.fileExists(atPath: dest.path) else { return dest }
            do { try fm.copyItem(at: dir, to: dest) } catch { return nil }
            let all = ((try? fm.contentsOfDirectory(atPath: backups.path)) ?? [])
                .filter { $0.hasPrefix("conversations-") && !$0.hasPrefix("conversations-legacy") }.sorted()
            for old in all.dropLast(keepBackups) { try? fm.removeItem(at: backups.appendingPathComponent(old)) }
            return dest
        }
    }

    var backupList: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("conversations-") && !$0.lastPathComponent.hasPrefix("conversations-legacy") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
