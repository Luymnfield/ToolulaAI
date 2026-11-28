import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

/// 在任何程序里选中文字, 按 ⌥⇧Space: 翻译 / 解释 / 改写 / 总结 / 回复, 结果可以直接替换原文。
/// 取选中文字: 先用辅助功能读 (不碰剪贴板), 读不到再模拟 ⌘C (之后恢复剪贴板)。
@MainActor
final class TextAssist: ObservableObject {
    static let shared = TextAssist()

    enum Action: String, CaseIterable, Identifiable {
        case translate, explain, polish, summarize, reply
        var id: String { rawValue }
        var title: String {
            switch self {
            case .translate: return String(localized: "翻译")
            case .explain: return String(localized: "解释")
            case .polish: return String(localized: "改写润色")
            case .summarize: return String(localized: "总结")
            case .reply: return String(localized: "帮我回复")
            }
        }
        var icon: String {
            switch self {
            case .translate: return "character.bubble"
            case .explain: return "lightbulb"
            case .polish: return "wand.and.stars"
            case .summarize: return "text.redaction"
            case .reply: return "arrowshape.turn.up.left"
            }
        }
        /// 结果适不适合直接替换原文
        var replaces: Bool { self == .translate || self == .polish }
    }

    @Published var source = ""
    @Published var sourceApp: String?
    @Published var result = ""
    @Published var running = false
    @Published var error: String?
    @Published var lastAction: Action?
    @Published var custom = ""
    @Published var needsPermission = false

    private var panel: QuickPanel?
    private var previousApp: NSRunningApplication?
    private var focused: AXUIElement?          // 原来那个文字框 (能用辅助功能替换时)
    private var task: Task<Void, Never>?
    weak var chat: ChatStore?
    weak var app: AppState?

    func setup(chat: ChatStore, app: AppState) {
        self.chat = chat; self.app = app
        HotKeyCenter.shared.onTextAction = { [weak self] in self?.trigger() }
        HotKeyCenter.shared.registerText()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 按下快捷键
    func trigger() {
        if isVisible { close(); return }
        previousApp = NSWorkspace.shared.frontmostApplication
        sourceApp = previousApp?.localizedName
        result = ""; error = nil; lastAction = nil; custom = ""
        needsPermission = !AXIsProcessTrusted()
        if needsPermission { source = ""; show(); return }
        Task {
            let (s, el) = await Self.readSelection()
            source = s ?? ""; focused = el
            show()
        }
    }

    // MARK: 取选中的文字

    static func readSelection() async -> (String?, AXUIElement?) {
        let sys = AXUIElementCreateSystemWide()
        var el: CFTypeRef?
        if AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &el) == .success, let el {
            let e = el as! AXUIElement
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXSelectedTextAttribute as CFString, &v) == .success, let s = v as? String,
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (s, e)
            }
        }
        // 浏览器、Electron 程序等读不到: 模拟 ⌘C, 读完把剪贴板还原
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let n = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { n.setData(d, forType: t) } }
            return n
        } ?? []
        let before = pb.changeCount
        postKey(UInt16(kVK_ANSI_C), flags: .maskCommand)
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(50))
            if pb.changeCount != before { break }
        }
        let s = pb.changeCount != before ? pb.string(forType: .string) : nil
        if pb.changeCount != before {
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
        return (s, nil)
    }

    static func postKey(_ key: UInt16, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    // MARK: 让 AI 处理

    func run(_ action: Action?) {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        task?.cancel()
        lastAction = action
        result = ""; error = nil; running = true
        let instruction: String
        let lang = Lang.aiLanguage
        switch action {
        case .translate:
            let cjk = text.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
            let target = Double(cjk) / Double(max(text.count, 1)) > 0.3 ? "English" : lang
            instruction = "把下面的文字翻译成\(target)。只输出译文，保留原来的格式和换行。"
        case .explain: instruction = "用\(lang)通俗地解释下面这段文字：讲了什么、关键概念是什么意思。简洁，可以用要点。"
        case .polish: instruction = "把下面的文字改写得更通顺、更专业，保持原来的语言和意思，只输出改写后的文字。"
        case .summarize: instruction = "用\(lang)总结下面这段文字的要点（3–5 条）。"
        case .reply: instruction = "这是别人发给我的消息。用和原文相同的语言，帮我写一段得体、简洁的回复，只输出回复正文。"
        case nil: instruction = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let mm = ModelManager.shared
        let model = mm.fastModel(for: mm.chatModel) ?? mm.chatModel
        let msgs: [[String: Any]] = [
            ["role": "system", "content": "你是 Leonix，帮用户处理他在别的程序里选中的文字。直接给结果，不寒暄，不解释你做了什么。"],
            ["role": "user", "content": instruction + "\n\n" + text],
        ]
        task = Task {
            do {
                if mm.model(model) != nil { await mm.ensureLoaded(model) }
                _ = try await LLMClient.stream(model: model, messages: msgs, tools: nil, reasoning: "none") { [weak self] c, _ in
                    self?.result += c
                }
                result = DocReader.clean(result)
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            running = false
        }
    }

    // MARK: 用结果

    /// 替换原文: 能用辅助功能直接写回就写回, 否则切回原来的程序粘贴 (之后恢复剪贴板)
    func replace() {
        let out = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return }
        close()
        if let f = focused, AXUIElementSetAttributeValue(f, kAXSelectedTextAttribute as CFString, out as CFString) == .success { return }
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents(); pb.setString(out, forType: .string)
        previousApp?.activate()
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            Self.postKey(UInt16(kVK_ANSI_V), flags: .maskCommand)
            try? await Task.sleep(for: .milliseconds(600))
            if let saved { pb.clearContents(); pb.setString(saved, forType: .string) }
        }
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
    }

    /// 在助手中继续: 新建一个对话, 带上原文和这次的结果
    func continueInAssistant() {
        guard let chat, let app else { return }
        var c = Conversation(model: ModelManager.shared.chatModel)
        c.agent = false
        let ask = (lastAction?.title ?? custom) + "：\n\n" + source
        c.title = String(ask.prefix(24)).replacingOccurrences(of: "\n", with: " ")
        c.messages = [ChatMessage(role: "user", text: ask), ChatMessage(role: "assistant", text: result)]
        chat.conversations.insert(c, at: 0)
        chat.selected = c.id
        chat.save()
        close()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        WindowOpener.showMain()
        app.section = .chat
    }

    // MARK: 小窗

    func show() {
        if panel == nil {
            let p = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                               styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
                               backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { p.standardWindowButton(b)?.isHidden = true }
            p.identifier = NSUserInterfaceItemIdentifier("text-assist")
            p.onCancel = { [weak self] in self?.close() }
            p.contentView = NSHostingView(rootView: TextAssistView(assist: self))
            p.setAccessibilityLabel(String(localized: "处理选中的文字"))
            panel = p
        }
        guard let p = panel else { return }
        // 放在鼠标旁边 (不超出屏幕)
        let m = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            let s = p.frame.size
            let x = min(max(f.minX + 8, m.x - s.width / 2), f.maxX - s.width - 8)
            let y = min(max(f.minY + 8, m.y - s.height - 16), f.maxY - s.height - 8)
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }
        p.makeKeyAndOrderFront(nil)
    }

    func close() {
        task?.cancel()
        running = false
        panel?.orderOut(nil)
    }
}

struct TextAssistView: View {
    @ObservedObject var assist: TextAssist
    @FocusState private var customFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "text.cursor").foregroundStyle(Color.toolula)
                Text(assist.sourceApp.map { String(localized: "来自 \($0) 的文字") } ?? String(localized: "选中的文字")).font(.headline)
                Spacer()
                Button { assist.close() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel(Text("关闭"))
            }
            if assist.needsPermission {
                VStack(alignment: .leading, spacing: 8) {
                    Text("需要「辅助功能」权限才能读取其他程序里选中的文字。").fixedSize(horizontal: false, vertical: true)
                    Button("打开系统设置") { ComputerControl.openSettings("Privacy_Accessibility") }
                }
            } else if assist.source.isEmpty {
                Text("没有读到选中的文字。先在其他程序里选中一段文字，再按 \(HotKeyCenter.shared.textAction.display)。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(assist.source).lineLimit(3).font(.callout).foregroundStyle(.secondary)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 6) {
                    ForEach(TextAssist.Action.allCases) { a in
                        Button { assist.run(a) } label: { Label(a.title, systemImage: a.icon) }
                            .buttonStyle(.bordered)
                            .tint(assist.lastAction == a ? Color.toolula : nil)
                    }
                }
                .controlSize(.small)
                HStack {
                    TextField("或者告诉它要怎么处理…", text: $assist.custom)
                        .textFieldStyle(.roundedBorder).focused($customFocused)
                        .onSubmit { assist.run(nil) }
                    Button("好") { assist.run(nil) }.disabled(assist.custom.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if assist.running || !assist.result.isEmpty || assist.error != nil {
                    ScrollView {
                        VStack(alignment: .leading) {
                            if let e = assist.error { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                            if assist.result.isEmpty && assist.running {
                                HStack { ProgressView().controlSize(.small); Text("处理中…").foregroundStyle(.secondary) }
                            }
                            MarkdownText(text: assist.result)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }
                    .frame(minHeight: 80, maxHeight: 260)
                    HStack {
                        if assist.lastAction?.replaces ?? true {
                            Button("替换原文") { assist.replace() }
                                .buttonStyle(.borderedProminent).tint(Color.toolula)
                                .keyboardShortcut(.return, modifiers: .command)
                                .help(Text("用结果替换刚才选中的文字（⌘↩）"))
                        }
                        Button("复制") { assist.copy() }
                        Button("在助手中继续") { assist.continueInAssistant() }
                        Spacer()
                    }
                    .disabled(assist.running || assist.result.isEmpty)
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
