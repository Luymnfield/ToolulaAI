import AppKit
import UniformTypeIdentifiers

// 融入 macOS: 聚焦搜索能搜到对话、访达右键菜单 (服务)、toolula:// 网址动作 (快捷指令里「打开 URL」也能用)

// MARK: - 聚焦搜索

/// 让聚焦搜索 (⌘Space) 能搜到对话: 每个对话写一个纯文本的 .toolulachat 文件 (~/Toolula/Chats/Search),
/// 系统自己会索引它; 点结果由 Toolula 打开那个对话。
/// (系统的 CoreSpotlight 接口要求正式开发者签名, 本机自签名的 App 用不了, 所以用文件的办法)
enum SpotlightIndex {
    static let ext = "toolulachat"
    static var folder: URL {
        let u = AppPaths.chats.appendingPathComponent("Search", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "spotlightChats") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "spotlightChats")
            if !newValue { try? FileManager.default.removeItem(at: folder); written = [:] }
        }
    }

    private static var pending: Task<Void, Never>?
    /// 对话 id -> (写过的文件名, 写的时候对话的更新时间)
    private static var written: [UUID: (String, Date)] = [:]

    /// 对话保存后调用: 2 秒内多次只做一次, 只写有变化的
    @MainActor
    static func schedule(_ conversations: [Conversation]) {
        guard enabled else { return }
        pending?.cancel()
        let list = conversations.filter { !$0.messages.isEmpty }
        pending = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            update(list)
        }
    }

    @MainActor
    private static func update(_ list: [Conversation]) {
        let fm = FileManager.default
        let dir = folder
        if written.isEmpty {
            // 第一次: 按文件里的 id 认领已有的文件
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == ext {
                if let id = id(in: f) { written[id] = (f.lastPathComponent, .distantPast) } else { try? fm.removeItem(at: f) }
            }
        }
        let ids = Set(list.map(\.id))
        for (id, (name, _)) in written where !ids.contains(id) {
            try? fm.removeItem(at: dir.appendingPathComponent(name)); written[id] = nil
        }
        for c in list where written[c.id]?.1 != c.updated {
            let title = c.title.isEmpty ? String(localized: "新对话") : c.title
            let safe = String(title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>\n")).joined(separator: " ").prefix(60))
            let name = "\(safe) · \(c.id.uuidString.prefix(4)).\(ext)"
            if let old = written[c.id]?.0, old != name { try? fm.removeItem(at: dir.appendingPathComponent(old)) }
            var body = "\(title)\n\n"
            for m in c.messages where (m.role == "user" && m.hidden != true) || (m.role == "assistant" && !m.text.isEmpty) {
                body += (m.role == "user" ? "我：" : "Toolula：") + m.text + "\n"
                for d in m.docs ?? [] { body += "📎 \(d.name)\n" }
                body += "\n"
            }
            body = String(body.prefix(50_000)) + "\n\ntoolula-chat-id: \(c.id.uuidString)\n"
            let u = dir.appendingPathComponent(name)
            if (try? Data(body.utf8).write(to: u, options: .atomic)) != nil {
                written[c.id] = (name, c.updated)
                // 聚焦搜索结果里显示对话的时间
                try? fm.setAttributes([.modificationDate: c.updated], ofItemAtPath: u.path)
            }
        }
    }

    /// 文件最后一行记着对话 id
    static func id(in url: URL) -> UUID? {
        guard let s = try? String(contentsOf: url, encoding: .utf8), let r = s.range(of: "toolula-chat-id: ", options: .backwards) else { return nil }
        return UUID(uuidString: String(s[r.upperBound...].prefix(36)))
    }

    /// 全部重写 (设置里打开开关时)
    @MainActor
    static func rebuild(_ conversations: [Conversation]) {
        try? FileManager.default.removeItem(at: folder)
        written = [:]
        schedule(conversations)
    }
}

// MARK: - 访达右键菜单 (服务)

/// Info.plist 里 NSServices 声明的几个服务: 在访达里选中文件右键 → 服务 / 快速操作
final class ServiceProvider: NSObject {
    static let shared = ServiceProvider()
    weak var chat: ChatStore?
    weak var app: AppState?
    weak var store: Store?

    private func urls(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    @MainActor private func front() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        WindowOpener.showMain()
    }

    /// 「用 Toolula 总结」: 新对话, 附上这些文件, 让 AI 总结
    @objc func summarizeFiles(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let files = urls(pb)
        MainActor.assumeIsolated {
            guard let chat, let app, !files.isEmpty else { return }
            front()
            app.section = .chat
            Task {
                var docs: [DocAttachment] = [], images: [String] = []
                for u in files {
                    if DocReader.isImage(u) { if let a = chat.attach(u) { images.append(a) }; continue }
                    if let d = try? await Task.detached(operation: { try DocReader.load(u) }).value { docs.append(d) }
                }
                guard !docs.isEmpty || !images.isEmpty else { return }
                let id = chat.newConversation()
                chat.update(id) { $0.agent = false }
                chat.send(String(localized: "总结这些文件的主要内容，列出关键信息。"), images: images, docs: docs, to: id)
            }
        }
    }

    /// 「用 Toolula 修图」: 照片加到修图页
    @objc func editPhotos(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let files = urls(pb)
        MainActor.assumeIsolated {
            guard let store, let app, !files.isEmpty else { return }
            front()
            app.section = .photo
            store.add(urls: files)
        }
    }

    /// 「用 Toolula 做成视频」: 第一张图当视频首帧
    @objc func videoFromImage(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let files = urls(pb).filter { DocReader.isImage($0) }
        MainActor.assumeIsolated {
            guard let app, let f = files.first else { return }
            front()
            app.section = .video
            VideoStore.shared.firstFrame = f
        }
    }

    /// 选中文字 → 「问 Toolula」: 打开处理选中文字的小窗
    @objc func askAboutText(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let text = pb.string(forType: .string) ?? ""
        MainActor.assumeIsolated {
            guard !text.isEmpty else { return }
            let t = TextAssist.shared
            t.source = text; t.sourceApp = nil; t.result = ""; t.error = nil; t.lastAction = nil; t.custom = ""; t.needsPermission = false
            t.show()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - toolula:// 网址动作

/// 给快捷指令的「打开 URL」、脚本、其他程序用:
///   toolula://ask?q=问题              快速提问小窗里直接提问
///   toolula://image?prompt=画面描述     加入绘图队列
///   toolula://video?prompt=视频描述     加入视频队列
///   toolula://chat/<对话 id>           打开某个对话 (聚焦搜索用)
enum URLActions {
    static func query(_ u: URL, _ name: String) -> String? {
        URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}
