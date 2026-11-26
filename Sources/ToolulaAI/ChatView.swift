import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject var chat: ChatStore
    @State private var confirmDeleteAll = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Button { chat.newConversation() } label: {
                    Label("新对话", systemImage: "square.and.pencil").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .focusEffectDisabled()
                .padding(8)
                List(selection: $chat.selected) {
                    ForEach(chat.conversations) { c in
                        ConversationRow(conversation: c, running: chat.running.contains(c.id)) { chat.delete(c.id) }
                            .tag(c.id)
                            .contextMenu {
                                Button("删除对话", role: .destructive) { chat.delete(c.id) }
                                Divider()
                                Button("删除所有空对话") { chat.deleteEmpty() }
                            }
                    }
                }
                .listStyle(.sidebar)
                .onDeleteCommand { if let id = chat.selected { chat.delete(id) } }

                if !chat.conversations.isEmpty {
                    HStack {
                        Text("\(chat.conversations.count) 个对话").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            Button("删除所有空对话") { chat.deleteEmpty() }
                            Button("删除全部对话…", role: .destructive) { confirmDeleteAll = true }
                        } label: { Image(systemName: "trash") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help(Text("删除对话"))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            .confirmationDialog(Text("删除全部 \(chat.conversations.count) 个对话？"), isPresented: $confirmDeleteAll) {
                Button("删除全部", role: .destructive) { chat.deleteAll() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除后无法恢复。")
            }
        } detail: {
            if let c = chat.current {
                ConversationView(conversationId: c.id)
            } else {
                EmptyChat()
            }
        }
    }
}

/// 对话列表的一行: 鼠标移上去时右边出现删除按钮
struct ConversationRow: View {
    let conversation: Conversation
    let running: Bool
    let onDelete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                (conversation.title.isEmpty || conversation.title == "新对话" ? Text("新对话") : Text(conversation.title)).lineLimit(1)
                Text(conversation.updated, style: .relative).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if running {
                ProgressView().controlSize(.mini)
            } else if hover {
                Button(action: onDelete) {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(Text("删除对话"))
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

struct EmptyChat: View {
    @EnvironmentObject var chat: ChatStore
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 48)).foregroundStyle(.green)
            Text("Toolula AI").font(.largeTitle.bold())
            MachineBadge().frame(width: 320)
            Text("完全在本机运行的 AI：聊天、执行命令、整理文件、修图、自动化").foregroundStyle(.secondary)
            Button("开始新对话") { chat.newConversation() }.controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ConversationView: View {
    @EnvironmentObject var chat: ChatStore
    @ObservedObject var models = ModelManager.shared
    let conversationId: UUID
    @State private var input = ""
    @State private var images: [String] = []

    var conv: Conversation? { chat.conversations.first { $0.id == conversationId } }
    var isRunning: Bool { chat.running.contains(conversationId) }

    var body: some View {
        VStack(spacing: 0) {
            messagesView
            Divider()
            composer
        }
        .toolbar { toolbarContent }
        .onDrop(of: [.fileURL], isTargeted: nil) { p in
            loadURLs(p) { urls in for u in urls { if let a = chat.attach(u) { images.append(a) } } }
            return true
        }
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let conv {
                Picker("模型", selection: Binding(get: { conv.model }, set: { v in chat.update(conversationId) { $0.model = v }; chat.save() })) {
                    ForEach(models.chatModels) { m in
                        Text(m.displayName + (m.vision ? " 👁" : "") + (m.loaded ? " ●" : "") + (m.isCloud ? " ☁︎" : "")).tag(m.id)
                    }
                    if models.model(conv.model) == nil { Text(conv.model).tag(conv.model) }
                }
                .frame(width: 220)
                .help("选择这个对话用的本地模型（👁=能看图，●=已加载）")

                Picker("思考", selection: Binding(get: { conv.reasoning }, set: { v in chat.update(conversationId) { $0.reasoning = v } })) {
                    Text("不思考（快）").tag("none"); Text("思考：低").tag("low"); Text("思考：中").tag("medium"); Text("思考：高").tag("high")
                }
                .frame(width: 130)

                Toggle(isOn: Binding(get: { conv.agent }, set: { v in chat.update(conversationId) { $0.agent = v } })) {
                    Label("可执行操作", systemImage: "hammer")
                }
                .toggleStyle(.button)
                .help("打开后 AI 可以执行命令、读写文件、修图（每条命令会先问你）")

                ComputerControlButton()

                Button {
                    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                    p.directoryURL = URL(fileURLWithPath: conv.workDir)
                    if p.runModal() == .OK, let u = p.url { chat.update(conversationId) { $0.workDir = u.path }; chat.save() }
                } label: {
                    Label((conv.workDir as NSString).lastPathComponent, systemImage: "folder")
                }
                .help("工作目录：\(conv.workDir)")
            }
        }
    }

    // MARK: 消息

    var messagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let conv {
                        if conv.messages.isEmpty { suggestions }
                        let results = toolResults(conv)
                        ForEach(conv.messages) { m in
                            LiveMessage(live: chat.live, message: m,
                                        toolResult: m.toolCalls.isEmpty ? [:] : results.filter { k, _ in m.toolCalls.contains { $0.id == k } },
                                        onRetry: { chat.retryLast() })
                                .id(m.id)
                            if m.id == conv.summaryUntil, let s = conv.summary { CompressedDivider(conversationId: conversationId, summary: s, tokens: conv.compressedTokens) }
                        }
                        if chat.compressing.contains(conversationId) {
                            HStack { ProgressView().controlSize(.small); Text("正在压缩较早的对话…").foregroundStyle(.secondary) }
                        }
                        if let a = chat.approval, a.conversationId == conversationId { ApprovalCard(approval: a) }
                        if isRunning { ThinkingIndicator(live: chat.live, last: conv.messages.last) }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .background(LiveScroller(live: chat.live, proxy: proxy))
                }
                .padding(20)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: conv?.messages.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: conv?.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: chat.approval?.id) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }

    /// 所有工具结果 (调用 id -> 结果), 每次刷新只算一遍
    func toolResults(_ conv: Conversation) -> [String: String] {
        var out: [String: String] = [:]
        for t in conv.messages where t.role == "tool" { if let id = t.toolCallId { out[id] = t.text } }
        return out
    }

    var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("试试这些：").foregroundStyle(.secondary)
            let items = [String(localized: "我的 Mac 还剩多少硬盘空间？哪些文件夹最占地方？"),
                         String(localized: "看看下载文件夹里有什么，帮我按类型整理一下"),
                         String(localized: "把桌面上的照片用日系清新风格修好并导出"),
                         String(localized: "写一个 Python 脚本，把一个文件夹里的图片批量缩小到 2000 像素"),
                         String(localized: "解释一下 MLX 和 GGUF 有什么区别")]
            ForEach(items, id: \.self) { s in
                Button { input = s } label: {
                    Text(s).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .background(Color.gray.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
        }
    }

    // MARK: 输入框

    var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !images.isEmpty {
                HStack {
                    ForEach(images, id: \.self) { p in
                        ZStack(alignment: .topTrailing) {
                            if let img = NSImage(contentsOfFile: p) {
                                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            Button { images.removeAll { $0 == p } } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).padding(2)
                        }
                    }
                    if let conv, !(models.model(conv.model)?.vision ?? false) {
                        Text("当前模型看不了图片，请切换到带 👁 的模型").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.allowedContentTypes = [.image]
                    if p.runModal() == .OK { for u in p.urls { if let a = chat.attach(u) { images.append(a) } } }
                } label: { Image(systemName: "photo.badge.plus").font(.title3) }
                .buttonStyle(.plain).help("添加图片（也可以拖进来）")

                ZStack(alignment: .topLeading) {
                    if input.isEmpty {
                        Text("给 Toolula AI 发消息…（⌘↩ 发送）").foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 8)
                    }
                    TextEditor(text: $input)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 36, maxHeight: 140)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))

                if isRunning {
                    Button { chat.stop(conversationId) } label: { Image(systemName: "stop.circle.fill").font(.title) }
                        .buttonStyle(.plain).foregroundStyle(.red).help("停止")
                } else {
                    Button { sendNow() } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .buttonStyle(.plain).foregroundStyle(.green)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty)
                }
            }
            if let conv { ContextBar(conv: conv, running: isRunning).padding(.leading, 30) }
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        .task(id: conv?.model) { if let m = conv?.model { await chat.refreshContextLimit(m) } }
        // 打开对话 / 换模型 / 开关工具时, 后台先把模型和提示词缓存准备好
        .task(id: "\(conversationId)|\(conv?.model ?? "")|\(conv?.agent ?? false)") {
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { chat.warmUp(conversationId) }
        }
    }

    func sendNow() {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !images.isEmpty else { return }
        chat.selected = conversationId
        chat.send(t, images: images)
        input = ""
        images = []
    }
}

// MARK: - 一条消息

/// 一条消息。不观察 ChatStore: 流式输出时只有内容变了的那条会重新计算 (配合 .equatable())
struct MessageView: View, Equatable {
    let message: ChatMessage
    let toolResult: [String: String]
    var onRetry: () -> Void = {}
    @State private var showReasoning = false

    static func == (a: MessageView, b: MessageView) -> Bool { a.message == b.message && a.toolResult == b.toolResult }

    var body: some View {
        switch message.role {
        case "user":
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.images.isEmpty {
                        HStack {
                            ForEach(message.images, id: \.self) { p in
                                if let img = ThumbCache.image(p) {
                                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 140)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                    }
                    if !message.text.isEmpty {
                        Text(message.text).textSelection(.enabled)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Color.green.opacity(0.18))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        case "assistant":
            VStack(alignment: .leading, spacing: 8) {
                if !message.reasoning.isEmpty {
                    DisclosureGroup(isExpanded: $showReasoning) {
                        Text(message.reasoning).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    } label: { Label("思考过程", systemImage: "brain").font(.caption).foregroundStyle(.secondary) }
                }
                if !message.text.isEmpty { MarkdownText(text: message.text) }
                if let m = message.model {
                    Label(String(localized: "快速模型回答 · \(ModelManager.shared.model(m)?.displayName ?? m)"), systemImage: "bolt.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                        .help(Text("这个问题比较简单，自动交给了快速模型（可在模型页的「加速」里关闭）"))
                }
                ForEach(message.toolCalls) { call in ToolCallCard(call: call, result: toolResult[call.id]) }
                if let e = message.error {
                    HStack(alignment: .top) {
                        Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                        Button("重试") { onRetry() }
                    }
                }
            }
        default:
            EmptyView()  // tool 结果显示在 ToolCallCard 里
        }
    }
}

struct ToolCallCard: View {
    let call: ToolCall
    let result: String?
    @State private var open = false

    var title: String {
        let a = call.args
        switch call.name {
        case "run_shell": return String(localized: "执行命令") + "  " + (a["command"] as? String ?? "")
        case "list_directory": return String(localized: "查看文件夹") + "  " + (a["path"] as? String ?? "")
        case "read_file": return String(localized: "读取文件") + "  " + (a["path"] as? String ?? "")
        case "write_file": return String(localized: "写入文件") + "  " + (a["path"] as? String ?? "")
        case "photo_edit": return String(localized: "AI 修图") + "  " + ((a["paths"] as? [String])?.joined(separator: ", ") ?? "")
        case "notify_user": return String(localized: "发送通知") + "  " + (a["title"] as? String ?? "")
        case "web_search": return String(localized: "上网搜索") + "  " + (a["query"] as? String ?? "")
        case "generate_video": return String(localized: "生成视频") + "  " + (a["prompt"] as? String ?? "")
        case "browser_open": return String(localized: "打开网页") + "  " + (a["url"] as? String ?? "")
        case "browser_click": return String(localized: "点击网页元素") + "  #\(a["element_id"] as? Int ?? 0)"
        case "browser_type": return String(localized: "在网页输入") + "  " + (a["text"] as? String ?? "")
        case "browser_back": return String(localized: "返回上一页")
        case "browser_read": return String(localized: "读取网页")
        case "memory_save": return String(localized: "记住") + "  " + (a["text"] as? String ?? "")
        case "memory_delete": return String(localized: "忘记一条记忆")
        case "use_skill": return String(localized: "使用技能") + "  " + (a["name"] as? String ?? "")
        case "create_skill": return String(localized: "保存新技能") + "  " + (a["name"] as? String ?? "")
        default: return call.name
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: result == nil ? "hourglass" : "checkmark.circle.fill")
                        .foregroundStyle(result == nil ? Color.secondary : Color.green)
                    Text(title).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption)
                }
            }
            .buttonStyle(.plain)
            if open, let result {
                ScrollView {
                    Text(result).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ApprovalCard: View {
    @EnvironmentObject var chat: ChatStore
    let approval: PendingApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("AI 想要执行这个操作，允许吗？", systemImage: "exclamationmark.shield").font(.headline)
            Text(approval.summary)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("允许") { chat.answerApproval(true) }.keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent).tint(.green)
                Button("本对话都允许") { chat.answerApproval(true, always: true) }
                Button("拒绝", role: .cancel) { chat.answerApproval(false) }.keyboardShortcut(.escape, modifiers: [])
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.5)))
    }
}

/// 助手页右上角: 操作电脑 开关 + 权限
struct ComputerControlButton: View {
    @ObservedObject var cc = ComputerControl.shared
    var body: some View {
        Button { cc.showPanel.toggle() } label: {
            Label("操作电脑", systemImage: cc.enabled ? "cursorarrow.click.badge.clock" : "cursorarrow.click")
                .foregroundStyle(cc.enabled ? Color.toolula : .primary)
        }
        .help(Text("让 AI 操作 Mac 上的程序（快捷指令、AppleScript、点击按钮、输入文字）"))
        .popover(isPresented: $cc.showPanel, arrowEdge: .bottom) { ComputerControlPanel() }
    }
}


// MARK: - 上下文用量 / 压缩

/// 输入框下面的一行: 上下文用了多少、上次回答的速度、压缩按钮
struct ContextBar: View {
    @EnvironmentObject var chat: ChatStore
    @ObservedObject var models = ModelManager.shared
    let conv: Conversation
    let running: Bool

    var body: some View {
        let limit = chat.contextLimits[conv.model] ?? 0
        let used = conv.messages.isEmpty ? 0 : chat.usedTokens(conv)
        let frac = limit > 0 ? Double(used) / Double(limit) : 0
        let threshold = ModelManager.compressThreshold(limit)
        let nearly = limit > 0 && Double(used) > Double(threshold) * 0.8
        HStack(spacing: 10) {
            if limit > 0 && !conv.messages.isEmpty {
                HStack(spacing: 6) {
                    UsageBar(fraction: frac, height: 5).frame(width: 70)
                    Text("上下文 \(Self.k(used)) / \(Self.k(limit))").monospacedDigit()
                }
                .help(Text("这个对话发给 AI 的内容大约占了模型上下文的 \(String(Int(frac * 100)))%。越长越慢；超过 \(Self.k(threshold)) 时会自动压缩较早的对话（可在模型页关闭）。"))
            }
            if let st = conv.lastStats, st.promptTokens > 0 {
                Text(statsText(st)).lineLimit(1).truncationMode(.tail)
                    .help(Text("上一次回答：开始回答前读提示词用的时间；括号里是直接复用缓存、不用重新读的比例；后面是输出速度。"))
            }
            Spacer(minLength: 4)
            if conv.summary != nil {
                Button("取消压缩") { chat.uncompress(conv.id) }
                    .buttonStyle(.link).disabled(running)
                    .help(Text("之后发给 AI 的又是完整对话"))
            }
            Button {
                Task { await chat.compress(conv.id) }
            } label: {
                if chat.compressing.contains(conv.id) { ProgressView().controlSize(.mini) } else { Label("压缩对话", systemImage: "arrow.down.right.and.arrow.up.left") }
            }
            .buttonStyle(.borderless)
            .disabled(running || chat.compressing.contains(conv.id) || chat.compressibleRange(conv) == nil)
            .help(Text("让 AI 把较早的对话写成摘要，只保留最近两轮原文，回答更快。至少要有 3 轮对话才能压缩。"))
        }
        .font(.caption)
        .foregroundStyle(nearly ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
    }

    func statsText(_ st: ChatStats) -> String {
        var p: [String] = []
        let hit = st.promptTokens > 0 ? Int(Double(st.cachedTokens) / Double(st.promptTokens) * 100) : 0
        if st.promptSeconds > 0 {
            let sec = String(format: "%.1f", st.promptSeconds)
            p.append(hit > 0 ? String(localized: "读提示 \(sec) 秒（缓存 \(String(hit))%）") : String(localized: "读提示 \(sec) 秒"))
        }
        if st.tokensPerSecond > 0 { p.append(String(localized: "\(String(Int(st.tokensPerSecond.rounded()))) token/秒")) }
        return p.joined(separator: " · ")
    }

    static func k(_ n: Int) -> String { n >= 1000 ? String(format: "%.1fK", Double(n) / 1000).replacingOccurrences(of: ".0K", with: "K") : String(n) }
}

/// 消息列表里压缩到哪儿的分隔线, 点开能看摘要
struct CompressedDivider: View {
    @EnvironmentObject var chat: ChatStore
    let conversationId: UUID
    let summary: String
    let tokens: [Int]?
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Rectangle().fill(.quaternary).frame(height: 1)
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                    Text(label).lineLimit(1)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                    Rectangle().fill(.quaternary).frame(height: 1)
                }
                .font(.caption).foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                Text(summary).font(.callout).textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            }
        }
    }

    var label: String {
        if let t = tokens, t.count == 2 {
            return String(localized: "以上对话已压缩成摘要（\(ContextBar.k(t[0])) → \(ContextBar.k(t[1])) token）")
        }
        return String(localized: "以上对话已压缩成摘要")
    }
}


/// 消息里的图片缩略图缓存 (不用每次刷新都从硬盘读)
enum ThumbCache {
    nonisolated(unsafe) static let cache: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.countLimit = 200; return c }()
    static func image(_ path: String) -> NSImage? {
        if let i = cache.object(forKey: path as NSString) { return i }
        guard let i = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(i, forKey: path as NSString)
        return i
    }
}


// MARK: - 流式输出 (只有这些小视图观察 LiveStream)

/// 一条消息: 正在输出时显示 live 里的内容
struct LiveMessage: View {
    @ObservedObject var live: LiveStream
    let message: ChatMessage
    let toolResult: [String: String]
    let onRetry: () -> Void

    var body: some View {
        if let p = live.parts[message.id] {
            var m = message
            let _ = { m.text = p.text; m.reasoning = p.reasoning }()
            MessageView(message: m, toolResult: toolResult, onRetry: onRetry)
        } else {
            MessageView(message: message, toolResult: toolResult, onRetry: onRetry).equatable()
        }
    }
}

struct ThinkingIndicator: View {
    @ObservedObject var live: LiveStream
    let last: ChatMessage?
    var body: some View {
        let streaming = last.flatMap { live.parts[$0.id] }.map { !$0.text.isEmpty } ?? false
        if !streaming && (last?.role != "assistant" || (last?.text.isEmpty ?? true)) {
            HStack { ProgressView().controlSize(.small); Text("思考中…").foregroundStyle(.secondary) }
        }
    }
}

/// 输出时自动滚到底 (节流: 最多每 0.25 秒一次)
struct LiveScroller: View {
    @ObservedObject var live: LiveStream
    let proxy: ScrollViewProxy
    @State private var last = Date.distantPast
    var body: some View {
        Color.clear.onChange(of: live.parts.values.map(\.text.count).reduce(0, +)) { _, _ in
            guard Date().timeIntervalSince(last) > 0.25 else { return }
            last = Date()
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }
}
