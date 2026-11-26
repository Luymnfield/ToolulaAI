import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - 全局快捷键 (Carbon RegisterEventHotKey, 不需要辅助功能权限)

struct HotKey: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32          // Carbon: cmdKey / optionKey / controlKey / shiftKey

    static let defaultQuickAsk = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
    /// 选中文字后按: 翻译 / 解释 / 改写
    static let defaultTextAction = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey))

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_F1...kVK_F12: return "F\(Int(code) - kVK_F1 + 1)"
        default: break
        }
        // 按当前键盘布局取字符
        let src = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        guard let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let r = data.withUnsafeBytes { raw -> OSStatus in
            UCKeyTranslate(raw.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                           UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        return r == noErr && len > 0 ? String(utf16CodeUnits: chars, count: len).uppercased() : "#\(code)"
    }

    /// 从 NSEvent 的修饰键换算成 Carbon 的
    static func carbon(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    /// 已知会和系统冲突的组合
    var systemConflict: String? {
        let cmd = UInt32(cmdKey), opt = UInt32(optionKey), ctrl = UInt32(controlKey)
        switch (Int(keyCode), modifiers) {
        case (kVK_Space, cmd): return String(localized: "和「聚焦」(Spotlight) 冲突")
        case (kVK_Space, ctrl), (kVK_Space, ctrl | opt): return String(localized: "和切换输入法冲突")
        case (kVK_Space, cmd | opt): return String(localized: "和访达搜索冲突")
        case (kVK_Tab, cmd), (kVK_ANSI_Q, cmd), (kVK_ANSI_W, cmd), (kVK_ANSI_H, cmd), (kVK_ANSI_M, cmd):
            return String(localized: "和系统常用快捷键冲突")
        default: break
        }
        if modifiers == 0 || modifiers == UInt32(shiftKey) { return String(localized: "至少要带 ⌘、⌥ 或 ⌃ 中的一个") }
        return nil
    }
}

@MainActor
final class HotKeyCenter: ObservableObject {
    static let shared = HotKeyCenter()
    @Published private(set) var quickAsk: HotKey
    @Published private(set) var error: String?
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "quickAskEnabled"); register() } }

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: (() -> Void)?

    /// 第二个快捷键: 处理选中的文字
    @Published private(set) var textAction: HotKey
    @Published private(set) var textError: String?
    @Published var textEnabled: Bool { didSet { UserDefaults.standard.set(textEnabled, forKey: "textActionEnabled"); registerText() } }
    private var textRef: EventHotKeyRef?
    var onTextAction: (() -> Void)?

    private init() {
        if let d = UserDefaults.standard.data(forKey: "quickAskHotKey"), let k = try? JSONDecoder().decode(HotKey.self, from: d) {
            quickAsk = k
        } else {
            quickAsk = .defaultQuickAsk
        }
        if let d = UserDefaults.standard.data(forKey: "textActionHotKey"), let k = try? JSONDecoder().decode(HotKey.self, from: d) {
            textAction = k
        } else {
            textAction = .defaultTextAction
        }
        enabled = UserDefaults.standard.object(forKey: "quickAskEnabled") as? Bool ?? true
        textEnabled = UserDefaults.standard.object(forKey: "textActionEnabled") as? Bool ?? true
    }

    @discardableResult
    func setText(_ k: HotKey) -> String? {
        if let c = k.systemConflict { textError = c; return c }
        if k == quickAsk { textError = String(localized: "和快速提问的快捷键重复了"); return textError }
        let old = textAction
        textAction = k
        if let e = registerText() { textAction = old; registerText(); textError = e; return e }
        if let d = try? JSONEncoder().encode(k) { UserDefaults.standard.set(d, forKey: "textActionHotKey") }
        return nil
    }

    func resetTextDefault() { setText(.defaultTextAction) }

    @discardableResult
    func registerText() -> String? {
        if let textRef { UnregisterEventHotKey(textRef); self.textRef = nil }
        guard textEnabled else { textError = nil; return nil }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x544C_4151), id: 2)
        var r: EventHotKeyRef?
        let st = RegisterEventHotKey(textAction.keyCode, textAction.modifiers, id, GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &r)
        if st == noErr { textRef = r; textError = nil; return nil }
        let msg = st == OSStatus(eventHotKeyExistsErr)
            ? String(localized: "快捷键 \(textAction.display) 已被其他程序占用，请换一个")
            : String(localized: "注册快捷键失败（错误 \(Int(st))）")
        textError = msg
        return msg
    }

    /// 两个快捷键共用一个事件处理: 按 id 分发
    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let which = hk.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if which == 2 { HotKeyCenter.shared.onTextAction?() } else { HotKeyCenter.shared.onPress?() }
                }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// 换快捷键。返回冲突说明 (nil = 成功)
    @discardableResult
    func set(_ k: HotKey) -> String? {
        if let c = k.systemConflict { error = c; return c }
        let old = quickAsk
        quickAsk = k
        if let e = register() {
            quickAsk = old
            register()
            error = e
            return e
        }
        if let d = try? JSONEncoder().encode(k) { UserDefaults.standard.set(d, forKey: "quickAskHotKey") }
        return nil
    }

    func resetDefault() { set(.defaultQuickAsk) }

    @discardableResult
    func register() -> String? {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        guard enabled else { error = nil; return nil }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x544C_4151), id: 1)   // 'TLAQ'
        var r: EventHotKeyRef?
        let st = RegisterEventHotKey(quickAsk.keyCode, quickAsk.modifiers, id, GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &r)
        if st == noErr {
            ref = r
            error = nil
            return nil
        }
        let msg = st == OSStatus(eventHotKeyExistsErr)
            ? String(localized: "快捷键 \(quickAsk.display) 已被其他程序占用，请换一个")
            : String(localized: "注册快捷键失败（错误 \(Int(st))）")
        error = msg
        return msg
    }
}

/// 录制快捷键的按钮: 点一下, 再按想要的组合
struct HotKeyRecorder: View {
    @ObservedObject var center = HotKeyCenter.shared
    /// true: 录「选中文字」的快捷键; false: 快速提问
    var text = false
    @State private var recording = false
    @State private var monitor: Any?

    var current: HotKey { text ? center.textAction : center.quickAsk }

    var body: some View {
        HStack {
            Button(recording ? String(localized: "请按下新的快捷键…") : current.display) { recording ? stop() : start() }
                .frame(minWidth: 160)
                .accessibilityLabel(Text(text ? "选中文字快捷键" : "快速提问快捷键"))
                .accessibilityValue(Text(current.display))
            Button("恢复默认") { text ? center.resetTextDefault() : center.resetDefault() }
            if let e = text ? center.textError : center.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption) }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            let k = HotKey(keyCode: UInt32(e.keyCode), modifiers: HotKey.carbon(e.modifierFlags))
            if text { center.setText(k) } else { center.set(k) }
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - 浮动小窗

final class QuickPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel.map { $0() } ?? QuickAsk.shared.close() }
}

@MainActor
final class QuickAsk: ObservableObject {
    static let shared = QuickAsk()
    weak var chat: ChatStore?
    weak var app: AppState?
    @Published var text = ""
    @Published var conversationId: UUID?
    @Published var focusToken = 0
    private var panel: QuickPanel?

    func setup(chat: ChatStore, app: AppState) {
        self.chat = chat
        self.app = app
        HotKeyCenter.shared.onPress = { [weak self] in self?.toggle() }
        HotKeyCenter.shared.register()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? close() : show() }

    func show() {
        guard let chat else { return }
        if panel == nil {
            let p = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 80),
                               styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
                               backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.standardWindowButton(.closeButton)?.isHidden = true
            p.standardWindowButton(.miniaturizeButton)?.isHidden = true
            p.standardWindowButton(.zoomButton)?.isHidden = true
            p.identifier = NSUserInterfaceItemIdentifier("quick-ask")
            p.contentView = NSHostingView(rootView: QuickAskView(quick: self).environmentObject(chat))
            p.setAccessibilityLabel(String(localized: "快速提问"))
            panel = p
        }
        guard let p = panel else { return }
        // 放在鼠标所在屏幕的上三分之一
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            let size = p.frame.size
            p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - f.height / 4 - size.height))
        }
        p.makeKeyAndOrderFront(nil)
        focusToken += 1
    }

    func close() {
        panel?.orderOut(nil)
    }

    func ask() {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let chat else { return }
        if let id = conversationId, chat.running.contains(id) { return }
        // 同一个小窗里接着问, 就继续同一个对话
        if let id = conversationId, chat.conversations.contains(where: { $0.id == id }) {
            chat.send(q, to: id)
        } else {
            conversationId = chat.startQuick(q)
        }
        text = ""
    }

    func newQuestion() {
        conversationId = nil
        text = ""
        focusToken += 1
    }

    /// 在助手中继续: 打开主窗口, 选中这个对话
    func continueInAssistant() {
        guard let id = conversationId else { return }
        close()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        WindowOpener.showMain()
        app?.section = .chat
        chat?.selected = id
        conversationId = nil
    }

    func resize(height: CGFloat) {
        guard let p = panel else { return }
        var f = p.frame
        let h = min(max(height, 80), 560)
        guard abs(f.height - h) > 1 else { return }
        f.origin.y += f.height - h
        f.size.height = h
        p.setFrame(f, display: true, animate: false)
    }
}

struct QuickAskView: View {
    @ObservedObject var quick: QuickAsk
    @EnvironmentObject var chat: ChatStore
    @FocusState private var focused: Bool

    private var conv: Conversation? { quick.conversationId.flatMap { id in chat.conversations.first { $0.id == id } } }
    private var running: Bool { quick.conversationId.map { chat.running.contains($0) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(Color.toolula).accessibilityHidden(true)
                TextField(conv == nil ? String(localized: "问 Toolula AI…") : String(localized: "继续问…"), text: $quick.text)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($focused)
                    .onSubmit { quick.ask() }
                    .accessibilityLabel(Text("提问"))
                if running {
                    ProgressView().controlSize(.small)
                    Button { if let id = quick.conversationId { chat.stop(id) } } label: { Image(systemName: "stop.circle") }
                        .buttonStyle(.borderless).help(Text("停止")).accessibilityLabel(Text("停止"))
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            if let conv {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(conv.messages.filter { $0.role != "tool" && !($0.role == "assistant" && $0.text.isEmpty && !chat.live.parts.keys.contains($0.id) && $0.error == nil) }) { m in
                                LiveMessage(live: chat.live, message: m, toolResult: [:], onRetry: {})
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(16)
                        .background(GeometryReader { g in Color.clear.preference(key: QuickHeightKey.self, value: g.size.height) })
                    }
                    .frame(maxHeight: 440)
                    .onChange(of: conv.messages.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
                Divider()
                HStack {
                    Button("新问题") { quick.newQuestion() }.keyboardShortcut("n", modifiers: .command)
                    Spacer()
                    Text("Esc 关闭").font(.caption).foregroundStyle(.secondary)
                    Button("在助手中继续") { quick.continueInAssistant() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent).tint(.toolula)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .frame(width: 680)
        .background(.regularMaterial)
        .ignoresSafeArea()
        .onPreferenceChange(QuickHeightKey.self) { h in quick.resize(height: 64 + min(h, 440) + 52) }
        .onChange(of: quick.conversationId) { _, id in if id == nil { quick.resize(height: 64) } }
        .onChange(of: quick.focusToken) { _, _ in focused = true }
        .onAppear { focused = true }
        .onExitCommand { quick.close() }
    }
}

private struct QuickHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
