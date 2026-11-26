import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 对话的基本功: 改一句重新发、从某条分出新对话、全文搜索、导出

extension ChatStore {
    /// 改写一条已发出的消息, 删掉它后面的内容, 重新发送 (图片和文档附件保留)
    func editAndResend(_ conv: UUID, message mid: UUID, text: String) {
        guard !running.contains(conv), let c = conversations.first(where: { $0.id == conv }),
              let i = c.messages.firstIndex(where: { $0.id == mid }), c.messages[i].role == "user" else { return }
        let old = c.messages[i]
        update(conv) { c in
            // 改的是已经被压缩进摘要的部分: 摘要作废
            if let su = c.summaryUntil, let si = c.messages.firstIndex(where: { $0.id == su }), i <= si {
                c.summary = nil; c.summaryUntil = nil; c.compressedTokens = nil
            }
            c.messages.removeSubrange(i...)
            c.lastStats = nil
        }
        selected = conv
        send(text, images: old.images, docs: old.docs ?? [], to: conv)
    }

    /// 从某条消息分出一个新对话 (保留到这条为止), 原对话不动
    @discardableResult
    func branch(_ conv: UUID, upTo mid: UUID) -> UUID? {
        guard let c = conversations.first(where: { $0.id == conv }), let i = c.messages.firstIndex(where: { $0.id == mid }) else { return nil }
        var n = c
        n.id = UUID()
        n.messages = Array(c.messages[...i])
        // 工具调用没有结果就分开会让模型困惑: 末尾是还没回结果的工具调用时去掉它
        while let last = n.messages.last, last.role == "assistant", !last.toolCalls.isEmpty, last.text.isEmpty { n.messages.removeLast() }
        n.title = String(localized: "\(c.title.isEmpty ? String(localized: "新对话") : c.title)（分支）")
        if let su = c.summaryUntil, !n.messages.contains(where: { $0.id == su }) { n.summary = nil; n.summaryUntil = nil; n.compressedTokens = nil }
        n.lastStats = nil
        n.updated = Date()
        conversations.insert(n, at: 0)
        selected = n.id
        save()
        return n.id
    }
}

/// 侧边栏全文搜索
enum ChatSearch {
    /// 标题或任意一条消息 (含附件文件名) 里出现关键词就算命中; 返回用来显示的片段 (标题命中时为空串)
    static func match(_ c: Conversation, _ q: String) -> String? {
        let q = q.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return "" }
        if c.title.localizedCaseInsensitiveContains(q) { return "" }
        for m in c.messages where m.role != "tool" && m.hidden != true {
            let names = (m.docs ?? []).map(\.name).joined(separator: " ")
            for t in [m.text, names] where !t.isEmpty {
                if let r = t.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
                    return snippet(t, r)
                }
            }
        }
        return nil
    }

    static func snippet(_ t: String, _ r: Range<String.Index>) -> String {
        let start = t.index(r.lowerBound, offsetBy: -18, limitedBy: t.startIndex) ?? t.startIndex
        let end = t.index(r.upperBound, offsetBy: 40, limitedBy: t.endIndex) ?? t.endIndex
        return (start > t.startIndex ? "…" : "") + t[start..<end].replacingOccurrences(of: "\n", with: " ") + (end < t.endIndex ? "…" : "")
    }
}

/// 导出成 Markdown / PDF
enum ChatExport {
    static var folder: URL {
        let u = AppPaths.exports.appendingPathComponent("Chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func markdown(_ c: Conversation) -> String {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        var s = "# \(c.title.isEmpty ? String(localized: "新对话") : c.title)\n\n"
        s += "_" + String(localized: "导出时间：\(df.string(from: Date()))") + "_\n\n"
        if let sum = c.summary { s += "> " + String(localized: "较早的对话已压缩，摘要：") + "\n> " + sum.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n" }
        for m in c.messages where m.hidden != true {
            switch m.role {
            case "user":
                s += "## " + String(localized: "我") + "\n\n"
                for d in m.docs ?? [] { s += "📎 \(d.name)\n\n" }
                for p in m.images { s += "![](\(URL(fileURLWithPath: p).absoluteString))\n\n" }
                if !m.text.isEmpty { s += m.text + "\n\n" }
            case "assistant":
                if !m.text.isEmpty || !m.toolCalls.isEmpty || m.error != nil { s += "## Toolula AI\n\n" }
                for t in m.toolCalls {
                    let call = Tools.normalize(t)
                    s += "- 🔧 `\(call.name)` " + (call.args.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ").prefix(200)) + "\n"
                }
                if !m.toolCalls.isEmpty { s += "\n" }
                if !m.text.isEmpty { s += m.text + "\n\n" }
                if let e = m.error { s += "> ⚠️ \(e)\n\n" }
            default: break
            }
        }
        return s
    }

    static func safeName(_ c: Conversation) -> String {
        let t = (c.title.isEmpty ? String(localized: "对话") : c.title).components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        return String(t.prefix(60))
    }

    /// 弹出保存窗口 (默认放在 ~/Toolula/Exports/Chats), 保存后在访达里选中
    @MainActor
    static func save(_ c: Conversation, pdf: Bool) {
        let p = NSSavePanel()
        p.directoryURL = folder
        p.nameFieldStringValue = safeName(c) + (pdf ? ".pdf" : ".md")
        p.allowedContentTypes = [pdf ? .pdf : UTType(filenameExtension: "md") ?? .plainText]
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            if pdf { try writePDF(c, to: url) } else { try Data(markdown(c).utf8).write(to: url, options: .atomic) }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let a = NSAlert(); a.messageText = String(localized: "导出失败"); a.informativeText = error.localizedDescription; a.runModal()
        }
    }

    /// 排版成 A4 PDF (标题加粗, Markdown 里的粗体/代码/链接保留)
    @MainActor
    static func writePDF(_ c: Conversation, to url: URL) throws {
        let body = NSMutableAttributedString()
        let base = NSFont.systemFont(ofSize: 11)
        let para = NSMutableParagraphStyle(); para.paragraphSpacing = 6; para.lineSpacing = 2
        func add(_ md: String, font: NSFont = base, color: NSColor = .black) {
            let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            let a = (try? NSMutableAttributedString(AttributedString(markdown: md, options: opts))) ?? NSMutableAttributedString(string: md)
            let r = NSRange(location: 0, length: a.length)
            a.enumerateAttribute(.font, in: r) { v, sub, _ in
                // 保留粗体/斜体/等宽, 统一字号
                let f = (v as? NSFont).map { NSFontManager.shared.convert($0, toSize: font.pointSize) } ?? font
                a.addAttribute(.font, value: v == nil ? font : f, range: sub)
            }
            a.addAttribute(.foregroundColor, value: color, range: r)
            a.addAttribute(.paragraphStyle, value: para, range: r)
            body.append(a); body.append(NSAttributedString(string: "\n"))
        }
        for line in markdown(c).components(separatedBy: "\n") {
            if line.hasPrefix("# ") { add(String(line.dropFirst(2)), font: .boldSystemFont(ofSize: 18)) }
            else if line.hasPrefix("## ") { add(String(line.dropFirst(3)), font: .boldSystemFont(ofSize: 13), color: .darkGray) }
            else if line.hasPrefix("![](") { continue }
            else { add(line) }
        }
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842)
        info.topMargin = 40; info.bottomMargin = 40; info.leftMargin = 48; info.rightMargin = 48
        info.horizontalPagination = .fit; info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        tv.textStorage?.setAttributedString(body)
        tv.sizeToFit()
        tv.frame.size.height = max(tv.frame.height, tv.layoutManager?.usedRect(for: tv.textContainer!).height ?? 100)
        let op = NSPrintOperation(view: tv, printInfo: info)
        op.showsPrintPanel = false; op.showsProgressPanel = false
        guard op.run() else { throw CocoaError(.fileWriteUnknown) }
    }
}
