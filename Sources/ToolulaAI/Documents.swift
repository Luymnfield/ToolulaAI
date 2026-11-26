import AppKit
import PDFKit
import UniformTypeIdentifiers
import Vision

/// 对话里附带的文档 (PDF / Word / Excel / PPT / 文本 / 代码 …)。
/// 拖进来时先把文字取出来存成 .txt (Attachments/Docs), 之后发给 AI 的都是这份文字, 原文件不动。
struct DocAttachment: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var source: String          // 原文件路径
    var textPath: String        // 取出的文字
    var chars: Int
    var pages: Int?
    var note: String?           // 例如「扫描件，已用文字识别」
    var digest: String?         // 长文档: 先读一遍写成的提要

    /// 发给 AI 的整篇最多多少 token, 超过就发提要 + 开头, 其余让 AI 用 read_file 分段读
    static let inlineTokens = 12_000

    var tokens: Int { DocReader.estimateTokens(chars: chars, sample: (try? String(contentsOfFile: textPath, encoding: .utf8).prefix(2000)).map(String.init) ?? "") }
    var isLong: Bool { tokens > Self.inlineTokens }

    var text: String { (try? String(contentsOfFile: textPath, encoding: .utf8)) ?? "" }

    /// 对话快满时较早的文档只留这一段
    func shortBlock() -> String {
        "【附件：\(name)，\(chars) 字，全文在 \(textPath)，需要时用 read_file 读取】" + (digest.map { "\n【提要】\n" + $0 } ?? "")
    }

    /// 拼进用户消息里的内容
    func promptBlock() -> String {
        var head = "【附件：\(name)" + (pages.map { "，\($0) 页" } ?? "") + "，\(chars) 字" + (note.map { "，\($0)" } ?? "") + "】"
        if !isLong {
            return head + "\n" + text + "\n【附件结束】"
        }
        head += "\n这份文档较长，下面是提要和开头；需要细节时用 read_file 读取 \(textPath)，用 offset 参数分段读（每次最多 2 万字）。"
        let start = String(text.prefix(3000))
        return head + "\n【提要】\n" + (digest ?? "（提要生成失败，请直接分段读取全文）") + "\n【开头】\n" + start + "\n…\n【附件结束】"
    }
}

enum DocReader {
    enum Failure: LocalizedError {
        case unsupported(String), empty, unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unsupported(let ext): return String(localized: "不支持的文件格式：\(ext)")
            case .empty: return String(localized: "这个文件里没有可读的文字")
            case .unreadable(let why): return String(localized: "读取失败：\(why)")
            }
        }
    }

    static let folder: URL = {
        let u = AppPaths.attachments.appendingPathComponent("Docs", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static func isImage(_ url: URL) -> Bool {
        (UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .image) ?? false) && url.pathExtension.lowercased() != "pdf"
    }

    static func estimateTokens(chars: Int, sample: String) -> Int {
        guard !sample.isEmpty else { return chars / 3 }
        let cjk = sample.unicodeScalars.filter { $0.value >= 0x2E80 && $0.value <= 0x9FFF || $0.value >= 0xAC00 && $0.value <= 0xD7AF }.count
        let ratio = Double(cjk) / Double(sample.unicodeScalars.count)
        return Int(Double(chars) * (ratio * 0.7 + (1 - ratio) / 3.5))
    }

    /// 取出文字并存好。在后台调用。
    static func load(_ url: URL) throws -> DocAttachment {
        let r = try extract(url)
        let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.empty }
        var d = DocAttachment(name: url.lastPathComponent, source: url.path, textPath: "", chars: text.count, pages: r.pages, note: r.note)
        let dest = folder.appendingPathComponent("\(d.id.uuidString).txt")
        try Data(text.utf8).write(to: dest, options: .atomic)
        d.textPath = dest.path
        return d
    }

    struct Extracted { var text: String; var pages: Int? = nil; var note: String? = nil }

    static func extract(_ url: URL) throws -> Extracted {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": return try pdf(url)
        case "docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "webarchive", "wordml":
            return try attributed(url)
        case "xlsx", "xlsm": return try xlsx(url)
        case "pptx": return try pptx(url)
        case "pages", "numbers", "key":
            throw Failure.unsupported(ext + String(localized: "（请先在 Pages / Numbers / Keynote 里导出成 PDF 或 Word）"))
        default:
            if let s = plainText(url) { return Extracted(text: s) }
            throw Failure.unsupported(ext.isEmpty ? url.lastPathComponent : ext)
        }
    }

    /// 文本、代码、CSV、JSON、Markdown… 任何能按文字读的文件
    static func plainText(_ url: URL) -> String? {
        guard let d = try? Data(contentsOf: url), !d.isEmpty else { return nil }
        // 带 0 字节基本就是二进制文件
        if d.prefix(4096).contains(0) { return nil }
        for enc in [String.Encoding.utf8, .utf16, .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))), .isoLatin1] {
            if let s = String(data: d, encoding: enc) { return s }
        }
        return nil
    }

    static func pdf(_ url: URL) throws -> Extracted {
        guard let doc = PDFDocument(url: url) else { throw Failure.unreadable(String(localized: "PDF 打不开（可能有密码）")) }
        if doc.isLocked { throw Failure.unreadable(String(localized: "PDF 有密码")) }
        var pages: [String] = []
        var scanned = 0
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i) else { continue }
            var t = (p.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // 这一页几乎没有文字: 多半是扫描件, 用系统自带的文字识别 (离线)
            if t.count < 20, let ocr = ocrPage(p), ocr.count > t.count { t = ocr; scanned += 1 }
            pages.append("—— 第 \(i + 1) 页 ——\n" + t)
        }
        return Extracted(text: pages.joined(separator: "\n\n"), pages: doc.pageCount,
                         note: scanned > 0 ? String(localized: "\(scanned) 页是扫描件，已用文字识别") : nil)
    }

    static func ocrPage(_ page: PDFPage) -> String? {
        let box = page.bounds(for: .mediaBox)
        let scale = 2000 / max(box.width, box.height, 1)
        let img = page.thumbnail(of: CGSize(width: box.width * scale, height: box.height * scale), for: .mediaBox)
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return ocr(cg)
    }

    static func ocr(_ cg: CGImage) -> String? {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "de-DE", "ja-JP"]
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: cg).perform([req])
        let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func attributed(_ url: URL) throws -> Extracted {
        do {
            let s = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
            return Extracted(text: s.string)
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
    }

    // MARK: Office (xlsx / pptx 是 zip 包, 用系统的 unzip 取出 XML)

    static func unzip(_ url: URL, _ pattern: String) -> [String: Data] {
        let list = run("/usr/bin/zipinfo", ["-1", url.path]).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var out: [String: Data] = [:]
        let rx = try? NSRegularExpression(pattern: pattern)
        for name in list.split(separator: "\n").map(String.init) {
            guard rx?.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil,
                  let d = run("/usr/bin/unzip", ["-p", url.path, name]) else { continue }
            out[name] = d
        }
        return out
    }

    static func run(_ exe: String, _ args: [String]) -> Data? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? d : nil
    }

    /// 取出 XML 里某个标签的所有文字 (按出现顺序)
    final class TagText: NSObject, XMLParserDelegate {
        let tags: Set<String>; var items: [String] = []; private var cur: String?
        /// 每遇到 rowTag / cellTag 时记一下, 用来排表格
        var events: [(String, String?)] = []
        let markers: Set<String>
        init(_ tags: Set<String>, markers: Set<String> = []) { self.tags = tags; self.markers = markers }
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String] = [:]) {
            if tags.contains(e) { cur = "" }
            if markers.contains(e) { events.append((e, a["r"] ?? a["t"])) }
            if e == "c" { events.append(("cellType", a["t"])) }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { cur? += s }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName q: String?) {
            if tags.contains(e), let c = cur { items.append(c); events.append(("text:" + e, c)); cur = nil }
        }
        static func parse(_ d: Data, _ tags: Set<String>, markers: Set<String> = []) -> TagText {
            let t = TagText(tags, markers: markers); let x = XMLParser(data: d); x.delegate = t; x.parse(); return t
        }
    }

    static func xlsx(_ url: URL) throws -> Extracted {
        let files = unzip(url, #"^xl/(sharedStrings\.xml|workbook\.xml|worksheets/sheet\d+\.xml)$"#)
        guard !files.isEmpty else { throw Failure.unreadable(String(localized: "不是有效的 Excel 文件")) }
        // 共享字符串: <si> 里可能有多段 <t>, 按 <si> 合并
        var shared: [String] = []
        if let d = files["xl/sharedStrings.xml"] {
            let t = TagText.parse(d, ["t"], markers: ["si"])
            var cur: String?
            for (k, v) in t.events {
                if k == "si" { if let c = cur { shared.append(c) }; cur = "" }
                else if k == "text:t" { cur = (cur ?? "") + (v ?? "") }
            }
            if let c = cur { shared.append(c) }
        }
        let names = files["xl/workbook.xml"].map { d -> [String] in
            let s = String(decoding: d, as: UTF8.self)
            let rx = try? NSRegularExpression(pattern: #"<sheet [^>]*name="([^"]+)""#)
            return rx?.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range(at: 1), in: s).map { String(s[$0]) } } ?? []
        } ?? []
        var out: [String] = []
        let sheets = files.keys.filter { $0.hasPrefix("xl/worksheets/") }.sorted {
            Int($0.filter(\.isNumber)) ?? 0 < Int($1.filter(\.isNumber)) ?? 0
        }
        for (i, key) in sheets.enumerated() {
            guard let d = files[key] else { continue }
            let t = TagText.parse(d, ["v", "t"], markers: ["row", "c"])
            var rows: [[String]] = [], row: [String] = [], type: String?
            for (k, v) in t.events {
                switch k {
                case "row": if !row.isEmpty { rows.append(row) }; row = []
                case "cellType": type = v
                case "text:v": row.append(type == "s" ? (Int(v ?? "").flatMap { $0 < shared.count ? shared[$0] : nil } ?? "") : (v ?? ""))
                case "text:t": row.append(v ?? "")     // inlineStr
                default: break
                }
            }
            if !row.isEmpty { rows.append(row) }
            let name = i < names.count ? names[i] : "Sheet\(i + 1)"
            out.append("## 工作表：\(name)（\(rows.count) 行）\n" + rows.map { $0.joined(separator: "\t") }.joined(separator: "\n"))
        }
        return Extracted(text: out.joined(separator: "\n\n"), pages: sheets.count, note: String(localized: "表格按行列出，用制表符分隔"))
    }

    static func pptx(_ url: URL) throws -> Extracted {
        let files = unzip(url, #"^ppt/slides/slide\d+\.xml$"#)
        guard !files.isEmpty else { throw Failure.unreadable(String(localized: "不是有效的 PowerPoint 文件")) }
        let keys = files.keys.sorted { Int($0.filter(\.isNumber)) ?? 0 < Int($1.filter(\.isNumber)) ?? 0 }
        let slides = keys.enumerated().map { i, k in
            "—— 第 \(i + 1) 页幻灯片 ——\n" + TagText.parse(files[k]!, ["a:t"]).items.joined(separator: "\n")
        }
        return Extracted(text: slides.joined(separator: "\n\n"), pages: keys.count)
    }

    // MARK: 长文档提要

    /// 分段读一遍, 写成提要。用快速模型 (有的话), 否则用对话的模型
    static func digest(_ doc: DocAttachment, model: String) async -> String? {
        let text = doc.text
        guard !text.isEmpty else { return nil }
        let chunkChars = 14_000
        var chunks: [String] = []
        var i = text.startIndex
        while i < text.endIndex {
            let j = text.index(i, offsetBy: chunkChars, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[i..<j])); i = j
        }
        // 太长的只抽样: 最多读 12 段 (约 17 万字), 均匀取
        if chunks.count > 12 { let step = Double(chunks.count) / 12; chunks = (0..<12).map { chunks[Int(Double($0) * step)] } }
        var notes: [String] = []
        for (n, c) in chunks.enumerated() {
            let msgs: [[String: Any]] = [
                ["role": "system", "content": "你在帮另一个 AI 预读一份长文档。只输出要点，不寒暄。"],
                ["role": "user", "content": "这是《\(doc.name)》的第 \(n + 1)/\(chunks.count) 段。用\(Lang.aiLanguage)列出这一段的要点（不超过 250 字）：讲了什么、关键数字/名称/日期/结论（原样保留）、出现在第几页或哪个小标题下。\n\n\(c)"],
            ]
            guard let r = try? await LLMClient.stream(model: model, messages: msgs, tools: nil, reasoning: "none", maxTokens: 600, onDelta: { _, _ in }) else { continue }
            notes.append("（第 \(n + 1) 段）" + clean(r.content))
        }
        guard !notes.isEmpty else { return nil }
        if notes.count <= 3 { return notes.joined(separator: "\n") }
        let msgs: [[String: Any]] = [
            ["role": "system", "content": "你在帮另一个 AI 预读一份长文档。只输出提要，不寒暄。"],
            ["role": "user", "content": "下面是《\(doc.name)》各段的要点。合并成一份提要（\(Lang.aiLanguage)，不超过 1000 字）：先一句话说明这是什么文档，再按文档结构列出主要内容，关键数字/名称/日期原样保留，并注明大致在第几段。\n\n" + notes.joined(separator: "\n\n")],
        ]
        if let r = try? await LLMClient.stream(model: model, messages: msgs, tools: nil, reasoning: "none", maxTokens: 1600, onDelta: { _, _ in }) {
            let s = clean(r.content)
            if !s.isEmpty { return s }
        }
        return notes.joined(separator: "\n")
    }

    static func clean(_ s: String) -> String {
        var t = s
        if let e = t.range(of: "</think>") { t = String(t[e.upperBound...]) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
