import AppKit
import Foundation

/// 「导出诊断报告」: 把日志、系统信息、模型和引擎状态、最近错误打成 zip 放到 ~/Toolula/Logs/Diagnostics。
/// 不包含: API Key (存在钥匙串, 不读)、对话内容、照片。日志里像密钥的字符串和提示词内容会被涂掉。
@MainActor
enum Diagnostics {
    weak static var chat: ChatStore?
    static let logNames = ["llama.log", "mlx.log", "comfyui.log", "engines.log"]
    static let maxLogLines = 3000

    /// 生成报告, 返回 zip 路径
    @discardableResult
    static func export(to folder: URL = AppPaths.logs.appendingPathComponent("Diagnostics", isDirectory: true)) async throws -> URL {
        let state = stateReport()
        let support = AppPaths.logs
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let name = "Leonix-诊断-\(SafeJSON.stamp())"
            let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let dir = tmp.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }
            func put(_ file: String, _ text: String) throws { try Data(text.utf8).write(to: dir.appendingPathComponent(file)) }

            try put("状态.txt", state)
            try put("系统.txt", systemReport())
            try put("数据文件夹.txt", dataListing(AppPaths.root))
            try put("进程.txt", processReport())
            for n in logNames {
                let u = support.appendingPathComponent(n)
                guard let t = try? String(contentsOf: u, encoding: .utf8) else { continue }
                try put(n, sanitize(t))
            }
            // 最近的崩溃报告 (只有调用栈, 没有对话或照片)
            let reports = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
            let crashes = ((try? fm.contentsOfDirectory(at: reports, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("ToolulaAI") }
                .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }.prefix(3)
            for c in crashes {
                if let t = try? String(contentsOf: c, encoding: .utf8) { try put("crash-\(c.lastPathComponent).txt", sanitize(t)) }
            }
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let zip = folder.appendingPathComponent("\(name).zip")
            let r = Exporter.shell("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", dir.path, zip.path])
            guard r.0 == 0 else { throw EngineError(String(localized: "打包诊断报告失败：\(r.1)")) }
            return zip
        }.value
    }

    /// 菜单 / 设置 / 命令面板里调用: 导出后在访达里显示
    static func exportAndReveal() {
        Task {
            do {
                let zip = try await export()
                NSWorkspace.shared.activateFileViewerSelecting([zip])
            } catch {
                let a = NSAlert()
                a.messageText = String(localized: "导出诊断报告失败")
                a.informativeText = error.localizedDescription
                a.runModal()
            }
        }
    }

    // MARK: - 内容

    static func stateReport() -> String {
        let mm = ModelManager.shared
        let mlx = MLXEngine.shared
        let comfy = ComfyEngine.shared
        let info = Bundle.main.infoDictionary ?? [:]
        var s = "Leonix \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))\n"
        s += "生成时间: \(Date())\n\n[模型设置]\n"
        s += "chatModel=\(mm.chatModel)\nphotoModel=\(mm.photoModel)\nfastModel=\(mm.fastModel)\n"
        s += "autoRoute=\(mm.autoRoute) autoCompress=\(mm.autoCompress)\ndraftModels=\(mm.draftModels)\n"
        s += "lmStudioOnline=\(mm.online) lastError=\(mm.lastError ?? "-")\n\n[本地模型]\n"
        for m in mm.models { s += "\(m.id) type=\(m.type) loaded=\(m.loaded) ctx=\(m.context) tools=\(m.toolUse)\n" }
        s += "\n[云端服务] (只有名称和地址, 不含 API Key)\n"
        for p in mm.providers { s += "\(p.name) \(p.baseURL) kind=\(p.kind) models=\(p.enabledModels.count)\n" }
        s += "\n[引擎]\n"
        s += "builtin(llama.cpp): installed=\(BuiltinEngine.installed) online=\(BuiltinEngine.shared.online)\n"
        s += "mtp(mlx): runtime=\(MLXEngine.runtimeInstalled) online=\(mlx.online) loaded=\(mlx.loadedTarget ?? "-") error=\(mlx.error ?? "-")\n"
        for p in MTPPair.all { s += "  \(p.id): ready=\(mlx.ready(p)) draft=\(p.draftReady) target=\(p.target?.path ?? "-")\n" }
        s += "comfyui: installed=\(ComfyEngine.installed) online=\(comfy.online) port=\(comfy.port) message=\(comfy.message ?? "-")\n"
        s += "\n[对话] 数量=\(chat?.conversations.count ?? -1) 运行中=\(chat?.running.count ?? 0) (不含内容)\n"
        s += "\n[最近错误]\n"
        s += "warm-up: \(ChatStore.lastWarmError ?? "-")\n"
        for e in SafeJSON.lastErrors { s += "storage: \(e)\n" }
        for e in ProcessJanitor.lastCleanup { s += "启动清理: \(e)\n" }
        return sanitize(s)
    }

    nonisolated static func systemReport() -> String {
        var s = ""
        let pi = ProcessInfo.processInfo
        s += "macOS: \(pi.operatingSystemVersionString)\n"
        s += "内存: \(pi.physicalMemory / 1_073_741_824) GB, CPU 核心: \(pi.processorCount)\n"
        s += "语言: \(Locale.preferredLanguages.prefix(3).joined(separator: ", "))\n"
        s += Exporter.shell("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string", "hw.model"]).1
        s += Exporter.shell("/usr/bin/vm_stat", []).1
        s += Exporter.shell("/bin/df", ["-h", NSHomeDirectory()]).1
        return sanitize(s)
    }

    nonisolated static func processReport() -> String {
        let r = Exporter.shell("/bin/ps", ["-axo", "pid,ppid,rss,etime,command"]).1
        let keep = r.split(separator: "\n").filter { l in
            ["ToolulaAI", "llama-server", "mlx_vlm", "ComfyUI", "LM Studio", "lms ", "Comfy"].contains { l.contains($0) } || l.contains("PID")
        }
        return sanitize(keep.joined(separator: "\n"))
    }

    /// 数据文件夹: 只列 JSON / 日志文件名和大小; 子文件夹只给文件数 (照片、附件不列名字)
    nonisolated static func dataListing(_ root: URL) -> String {
        let fm = FileManager.default
        var s = ""
        for name in ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted() {
            let u = root.appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: u.path, isDirectory: &isDir)
            if isDir.boolValue {
                let n = fm.enumerator(atPath: u.path)?.allObjects.count ?? 0
                s += "\(name)/  (\(n) 项)\n"
            } else {
                let size = (try? fm.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
                s += "\(name)  \(size) B\n"
            }
        }
        return s
    }

    /// 涂掉: 像 API Key / 令牌的字符串; JSON 里的提示词正文; 主目录换成 ~
    nonisolated static func sanitize(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(maxLogLines).map(String.init)
        let patterns: [(String, String)] = [
            (#"(?i)(authorization|x-api-key|api[_-]?key|bearer|token|secret|password)(["'\s:=]+)[^\s"',}]+"#, "$1$2[已涂掉]"),
            (#"\b(sk|pk|rk)-[A-Za-z0-9_\-]{12,}"#, "[已涂掉]"),
            (#"\b(hf|ghp|gho|ghs|github_pat|xox[abp])_[A-Za-z0-9_]{12,}"#, "[已涂掉]"),
            (#"\bAIza[0-9A-Za-z_\-]{20,}"#, "[已涂掉]"),
            (#"(?i)("(content|prompt|text|messages|input|system)"\s*:\s*)"(?:[^"\\]|\\.)*""#, "$1\"[已涂掉]\""),
        ]
        let regs = patterns.compactMap { p in (try? NSRegularExpression(pattern: p.0)).map { ($0, p.1) } }
        let home = NSHomeDirectory()
        for i in lines.indices {
            var l = lines[i]
            if l.count > 600 { l = String(l.prefix(600)) + " …[截断]" }
            for (r, t) in regs { l = r.stringByReplacingMatches(in: l, range: NSRange(l.startIndex..., in: l), withTemplate: t) }
            lines[i] = l.replacingOccurrences(of: home, with: "~")
        }
        return lines.joined(separator: "\n")
    }
}
