import Foundation

/// 精确改文件 (edit_file)、找文件 (search_files)、写完自动查语法。
/// 给模型看的文字不翻译: 系统提示词本来就是中文, 模型都看得懂。
enum FileTools {
    // MARK: - edit_file

    @MainActor
    static func edit(_ call: ToolCall, _ a: [String: Any], ctx: ToolContext) async -> String {
        let url = Tools.expand(a["path"] as? String ?? "", base: ctx.workDir)
        guard let old = a["old_text"] as? String, !old.isEmpty else { return "错误：缺少 old_text（要被替换的原文）。新建文件请用 write_file。" }
        var new = a["new_text"] as? String ?? ""
        let all = (a["replace_all"] as? Bool) ?? ((a["replace_all"] as? String) == "true")
        guard FileManager.default.fileExists(atPath: url.path) else { return notFound(url, workDir: ctx.workDir) }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "错误：\(url.lastPathComponent) 不是纯文本文件，不能用 edit_file 改。"
        }
        var target = old
        var note = ""
        var ranges = occurrences(old, in: text)
        if ranges.isEmpty, let m = looseMatch(old, new: new, in: text) {
            // 空格、缩进和文件里略有不同: 按文件里的实际内容替换, 新内容的缩进也跟着调整
            target = m.target; new = m.new
            ranges = occurrences(target, in: text)
            note = "（原文的空格或缩进和文件里不完全一样，已按文件里的实际内容替换）"
        }
        if ranges.isEmpty {
            return "错误：在 \(url.lastPathComponent) 里找不到 old_text。" + closest(old, in: text)
                + "\n请先 read_file 看清原文（要一字不差，包括空格和缩进），再重新调用。"
        }
        if ranges.count > 1 && !all {
            let lines = ranges.prefix(8).map { String(lineNumber(of: $0.lowerBound, in: text)) }.joined(separator: "、")
            return "错误：old_text 在文件里出现了 \(ranges.count) 次（第 \(lines) 行）。请多带几行上下文让它只出现一次；要全部替换就设 replace_all=true。"
        }
        if target == new { return "old_text 和 new_text 一样，文件没有变化。" }
        let n = all ? ranges.count : 1
        guard await ctx.approve(call, String(localized: "修改文件 \(url.path)（替换 \(String(n)) 处）")) else { return String(localized: "用户拒绝写入。") }

        let first = ranges[0]
        let startLine = lineNumber(of: first.lowerBound, in: text)
        let result = all ? text.replacingOccurrences(of: target, with: new) : text.replacingCharacters(in: first, with: new)
        do { try result.write(to: url, atomically: true, encoding: .utf8) }
        catch { return String(localized: "写入失败：\(error.localizedDescription)") }

        // 把改过的地方 (带行号) 给模型看, 方便它自己核对
        let all_lines = result.components(separatedBy: "\n")
        let newCount = max(1, new.components(separatedBy: "\n").count)
        let from = max(1, startLine - 2), to = min(all_lines.count, startLine + newCount + 1)
        var snippet = (from...to).prefix(30).map { String(format: "%5d│ ", $0) + all_lines[$0 - 1] }.joined(separator: "\n")
        if to - from >= 30 { snippet += "\n   …" }
        let more = n > 1 ? "（共 \(n) 处，下面是第一处）" : ""
        return "已修改 \(url.path)\(note)\(more)，改后第 \(from)–\(to) 行：\n\(snippet)" + (await check(url))
    }

    /// 原文出现的位置 (不重叠)
    static func occurrences(_ s: String, in text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex, let r = text.range(of: s, range: from..<text.endIndex) {
            out.append(r)
            from = r.upperBound
        }
        return out
    }

    static func lineNumber(of i: String.Index, in text: String) -> Int {
        text[..<i].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    /// 宽松匹配: 逐行比较, 忽略每行首尾的空白。只有唯一一处对得上才算。
    /// 文件里的缩进比原文多 (或少) 一截时, new_text 每行也加上 (或去掉) 同样的一截。
    static func looseMatch(_ old: String, new: String, in text: String) -> (target: String, new: String)? {
        func trim(_ s: Substring) -> String { s.trimmingCharacters(in: .whitespaces) }
        var oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
        while let l = oldLines.last, trim(l).isEmpty { oldLines.removeLast() }
        while let l = oldLines.first, trim(l).isEmpty { oldLines.removeFirst() }
        guard !oldLines.isEmpty else { return nil }
        let want = oldLines.map(trim)
        let fileLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard fileLines.count >= want.count else { return nil }
        var hits: [Int] = []
        for i in 0...(fileLines.count - want.count) where trim(fileLines[i]) == want[0] {
            if (0..<want.count).allSatisfy({ trim(fileLines[i + $0]) == want[$0] }) { hits.append(i) }
            if hits.count > 1 { return nil }
        }
        guard let i = hits.first else { return nil }
        let target = fileLines[i..<(i + want.count)].joined(separator: "\n")
        // 缩进差多少
        func indent(_ s: Substring) -> String { String(s.prefix { $0 == " " || $0 == "\t" }) }
        guard let k = want.firstIndex(where: { !$0.isEmpty }) else { return (target, new) }
        let fi = indent(fileLines[i + k]), oi = indent(oldLines[k])
        var newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if fi != oi {
            if fi.hasPrefix(oi) {
                let add = String(fi.dropFirst(oi.count))
                newLines = newLines.map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? $0 : add + $0 }
            } else if oi.hasPrefix(fi) {
                let cut = oi.count - fi.count
                newLines = newLines.map { l in
                    let lead = l.prefix { $0 == " " || $0 == "\t" }.count
                    return String(l.dropFirst(min(cut, lead)))
                }
            }
        }
        return (target, newLines.joined(separator: "\n"))
    }

    /// 找不到原文时, 指出文件里最像的那几行
    static func closest(_ old: String, in text: String) -> String {
        guard let key = old.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.count >= 3 }) else { return "" }
        let words = Set(key.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let lines = text.components(separatedBy: "\n")
        var best = (score: 0, idx: -1)
        for (i, l) in lines.enumerated() {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            let w = Set(t.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
            let score = words.intersection(w).count * 10 + (t.contains(key.prefix(12)) ? 50 : 0)
            if score > best.score { best = (score, i) }
        }
        guard best.idx >= 0, best.score >= 10 else { return "" }
        let from = max(0, best.idx - 2), to = min(lines.count - 1, best.idx + 3)
        return "\n文件里最接近的是第 \(best.idx + 1) 行附近：\n" + (from...to).map { String(format: "%5d│ ", $0 + 1) + lines[$0] }.joined(separator: "\n")
    }

    static func notFound(_ url: URL, workDir: URL? = nil, folder: Bool = false) -> String {
        var s = folder ? "错误：找不到文件夹 \(url.path)。" : "错误：找不到文件 \(url.path)。"
        // 模型常把「work 文件夹」当成主目录下的: 当前工作目录里正好有同名的就直接指出来
        if let w = workDir?.standardizedFileURL, url.deletingLastPathComponent().standardizedFileURL != w {
            let alt = w.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: alt.path) { return s + "当前工作目录里有：\(alt.path)，是不是要找它？" }
        }
        let dir = url.deletingLastPathComponent()
        if let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let base = url.deletingPathExtension().lastPathComponent.lowercased()
            let similar = items.filter { $0.lowercased().contains(base.prefix(4)) || base.contains($0.lowercased().prefix(4)) }.prefix(5)
            if !similar.isEmpty { s += "同一个文件夹里有：" + similar.joined(separator: "、") + "。" }
        } else {
            s += "文件夹 \(dir.path) 也不存在。"
        }
        return s + (folder ? "可以用 search_files 按名字找。" : "可以用 search_files 按文件名找。")
    }

    // MARK: - 写完自动查语法

    /// 能查的文件类型写完顺手查一下语法, 有问题马上告诉模型 (不会生成任何额外文件)
    static func check(_ url: URL) async -> String {
        let ext = url.pathExtension.lowercased()
        let path = url.path
        if ext == "json" {
            guard let d = try? Data(contentsOf: url) else { return "" }
            do { _ = try JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]); return "\n✓ JSON 格式正确" }
            catch { return "\n⚠️ JSON 格式有错：\((error as NSError).userInfo["NSDebugDescription"] ?? error.localizedDescription)" }
        }
        let cmd: [String]
        switch ext {
        case "py": cmd = ["/usr/bin/python3", "-c", "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read(), sys.argv[1])", path]
        case "sh", "bash": cmd = ["/bin/bash", "-n", path]
        case "zsh": cmd = ["/bin/zsh", "-n", path]
        case "js", "mjs", "cjs":
            guard let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return "" }
            cmd = [node, "--check", path]
        case "plist": cmd = ["/usr/bin/plutil", "-lint", "-s", path]
        default: return ""
        }
        let name = ["py": "Python", "sh": "bash", "bash": "bash", "zsh": "zsh", "plist": "plist"][ext] ?? "JavaScript"
        let (code, out) = await Task.detached { run(cmd, timeout: 10) }.value
        if code == 0 { return "\n✓ \(name) 语法检查通过" }
        let tail = out.split(separator: "\n").suffix(6).joined(separator: "\n")
        return "\n⚠️ \(name) 语法检查没通过：\n\(tail)"
    }

    static func run(_ cmd: [String], timeout: TimeInterval) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd[0])
        p.arguments = Array(cmd.dropFirst())
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (0, "") }   // 查不了就当没问题, 不打扰模型
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); timer.cancel()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: - search_files

    static let skipDirs: Set<String> = ["node_modules", ".git", ".build", "build", "DerivedData", "venv", ".venv", "__pycache__", "Pods",
                                        ".Trash", "Library", "dist", "target", ".cache"]
    static let binaryExt: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tif", "tiff", "raw", "cr2", "nef", "arw", "dng", "mp4", "mov",
                                         "mp3", "wav", "m4a", "zip", "gz", "tar", "7z", "dmg", "pkg", "app", "pdf", "docx", "xlsx", "pptx", "bin",
                                         "o", "a", "dylib", "so", "pyc", "class", "jar", "safetensors", "gguf", "ttf", "otf", "ico", "icns", "sqlite", "db"]

    /// name: 文件名 (带 * ? 是通配符, 否则是包含); text: 文件内容 (正则, 不分大小写; 不是合法正则就按普通文字找)
    static func search(root: URL, name: String?, text: String?, maxFiles: Int = 40000, maxHits: Int = 80) -> String {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return "错误：文件夹不存在：\(root.path)" }
        let regex: NSRegularExpression? = text.flatMap {
            (try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]))
                ?? (try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: $0), options: [.caseInsensitive]))
        }
        let wildcard = name.map { $0.contains("*") || $0.contains("?") } ?? false
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return "错误：无法读取 \(root.path)" }
        let started = Date()
        var scanned = 0, hits: [String] = [], total = 0, filesWithHits = 0
        var stopped = false
        let rootPath = root.standardizedFileURL.path
        func rel(_ u: URL) -> String {
            let p = u.standardizedFileURL.path
            return p.hasPrefix(rootPath + "/") ? String(p.dropFirst(rootPath.count + 1)) : p
        }
        for case let u as URL in en {
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true {
                if skipDirs.contains(u.lastPathComponent) { en.skipDescendants() }
                continue
            }
            scanned += 1
            if scanned > maxFiles || Date().timeIntervalSince(started) > 20 { stopped = true; break }
            let fname = u.lastPathComponent
            if let name {
                let ok = wildcard ? fnmatch(name, fname, FNM_CASEFOLD) == 0 : fname.localizedCaseInsensitiveContains(name)
                if !ok { continue }
            }
            guard let regex else {
                total += 1
                if hits.count < maxHits {
                    let size = ByteCountFormatter.string(fromByteCount: Int64(v?.fileSize ?? 0), countStyle: .file)
                    hits.append("\(rel(u))  \(size)")
                }
                continue
            }
            if binaryExt.contains(u.pathExtension.lowercased()) || (v?.fileSize ?? 0) > 2_000_000 { continue }
            guard let s = try? String(contentsOf: u, encoding: .utf8) else { continue }
            var found = false
            var lineNo = 0
            s.enumerateLines { line, stop in
                lineNo += 1
                if regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    found = true
                    total += 1
                    if hits.count < maxHits {
                        let t = line.trimmingCharacters(in: .whitespaces)
                        hits.append("\(rel(u)):\(lineNo): \(t.count > 200 ? String(t.prefix(200)) + "…" : t)")
                    }
                }
            }
            if found { filesWithHits += 1 }
        }
        var out: String
        if hits.isEmpty {
            out = "没找到（搜了 \(rootPath) 里的 \(scanned) 个文件"
            out += regex != nil ? "，PDF/Word 等文档的内容不在搜索范围内，可以用 read_file 读）。" : "）。"
        } else if regex != nil {
            out = "在 \(filesWithHits) 个文件里找到 \(total) 处（路径相对于 \(rootPath)）：\n" + hits.joined(separator: "\n")
        } else {
            out = "找到 \(total) 个文件（路径相对于 \(rootPath)）：\n" + hits.joined(separator: "\n")
        }
        if total > hits.count { out += "\n…还有 \(total - hits.count) 处没列出，可以把条件写得更具体。" }
        if stopped { out += "\n（文件太多，只搜了前 \(scanned) 个；可以指定更小的文件夹）" }
        return out
    }
}

/// plan 工具的计划: 步骤 + 正在做第几步 (0 = 全部完成)
enum PlanState {
    static func steps(_ a: [String: Any]) -> [String] {
        if let s = a["steps"] as? [String] { return s.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        if let s = a["steps"] as? [Any] { return s.map { "\($0)" } }
        if let s = a["steps"] as? String { return s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        return []
    }

    static func current(_ a: [String: Any]) -> Int {
        if let i = a["current"] as? Int { return i }
        if let d = a["current"] as? Double { return Int(d) }
        if let s = a["current"] as? String { return Int(s.trimmingCharacters(in: .whitespaces)) ?? 0 }
        return 0
    }

    /// 对话里最近一次的计划
    static func latest(_ messages: [ChatMessage]) -> (steps: [String], current: Int)? {
        for m in messages.reversed() {
            if let c = m.toolCalls.last(where: { $0.name == "plan" }) {
                let s = steps(c.args)
                return s.isEmpty ? nil : (s, current(c.args))
            }
        }
        return nil
    }
}
