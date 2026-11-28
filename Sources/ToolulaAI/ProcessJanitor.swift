import Foundation

/// 记录 Leonix 自己启动的后台进程 (llama.cpp / MTP 引擎 / ComfyUI), 崩溃后下次启动时清理。
///
/// 每启动一个进程就在 `pids/<名字>.json` 里记下: pid、启动时间、命令行特征、Leonix 自己的 pid。
/// 下次启动时只清理同时满足下面所有条件的进程:
///   1. pid 文件里记着 (用户自己开的 LM Studio / Comfy Desktop 不会有记录)
///   2. 进程还在, 启动时间和记录一致 (防止 pid 被别的程序复用)
///   3. 命令行仍包含记录的特征
///   4. 已经没有父进程 (父进程变成了 launchd, 说明启动它的 Leonix 已经不在了)
enum ProcessJanitor {
    struct Record: Codable {
        var name: String
        var pid: Int32
        var owner: Int32
        var started: String
        var signature: String
    }

    struct PSInfo { let ppid: Int32; let started: String; let command: String }

    nonisolated(unsafe) static var dir = AppPaths.cache.appendingPathComponent("run", isDirectory: true)
    nonisolated(unsafe) static var lastCleanup: [String] = []

    /// 文件名带 pid: 新启动的进程不会覆盖上次残留进程的记录
    static func file(_ name: String, _ pid: Int32) -> URL { dir.appendingPathComponent("\(name)-\(pid).json") }

    static func records() -> [(URL, Record?)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.map { ($0, SafeJSON.load(Record.self, from: $0, preserve: false)) }
    }

    /// 刚启动的进程: 记下来
    static func register(_ name: String, pid: Int32, signature: String) {
        guard let info = ps(pid) else { return }
        let r = Record(name: name, pid: pid, owner: getpid(), started: info.started, signature: signature)
        SafeJSON.save(r, to: file(name, pid))
    }

    /// 正常关掉了: 删掉这次启动 (本 Leonix 进程) 记下的这一类记录
    static func unregister(_ name: String) {
        for (f, r) in records() where r?.name == name && r?.owner == getpid() {
            try? FileManager.default.removeItem(at: f)
        }
    }

    /// 启动时调用: 清理失去父进程的残留进程。返回清理掉的说明。
    @discardableResult
    static func cleanupOrphans() -> [String] {
        let fm = FileManager.default
        var done: [String] = []
        for (f, rec) in records() {
            guard let r = rec else { try? fm.removeItem(at: f); continue }
            guard let info = ps(r.pid) else { try? fm.removeItem(at: f); continue }          // 早就退出了
            guard info.started == r.started, info.command.contains(r.signature) else {        // pid 已被别的程序复用
                try? fm.removeItem(at: f); continue
            }
            if r.owner == getpid() { continue }                                               // 是我自己这次启动的
            guard info.ppid == 1 else { continue }                                            // 还有父进程 (另一个 Leonix 正在用)
            let ok = terminate(r.pid)
            done.append("\(r.name) pid=\(r.pid) \(ok ? "已结束" : "结束失败")")
            if ok { try? fm.removeItem(at: f) }
        }
        lastCleanup = done
        if !done.isEmpty { Run.appendLog("[启动清理] 结束了残留的后台进程: \(done.joined(separator: ", "))\n") }
        return done
    }

    /// 先 SIGTERM, 5 秒后还在就 SIGKILL
    static func terminate(_ pid: Int32) -> Bool {
        kill(pid, SIGTERM)
        for _ in 0..<50 {
            if kill(pid, 0) != 0 { return true }
            usleep(100_000)
        }
        kill(pid, SIGKILL)
        usleep(300_000)
        return kill(pid, 0) != 0
    }

    static func ps(_ pid: Int32) -> PSInfo? {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return nil }
        let r = Exporter.shell("/bin/ps", ["-o", "ppid=", "-o", "lstart=", "-o", "command=", "-p", String(pid)])
        let line = r.1.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.0 == 0, !line.isEmpty else { return nil }
        // "    1 Wed Nov 26 00:43:12 2026     /path/to/cmd args"
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 7, let ppid = Int32(parts[0]) else { return nil }
        let started = parts[1...5].joined(separator: " ")
        let cmdStart = line.range(of: String(parts[5]))!.upperBound
        return PSInfo(ppid: ppid, started: started, command: String(line[cmdStart...]).trimmingCharacters(in: .whitespaces))
    }
}
