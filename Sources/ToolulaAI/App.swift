import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: Store?
    var chat: ChatStore?
    var app: AppState?
    var pending: [URL] = []
    var pendingLinks: [URL] = []

    @MainActor
    func handleLink(_ u: URL) {
        guard let app, let chat, let store else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        WindowOpener.showMain()
        let parts = [u.host ?? ""] + u.pathComponents.filter { $0 != "/" }
        switch parts.first ?? "" {
        case "chat":
            app.section = .chat
            chat.newConversation()
            if parts.contains("computer") { ComputerControl.shared.showPanel = true }
        case "photo":
            app.section = .photo
            if parts.contains("add") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openPanel(store) } }
        case "image": app.section = .image
        case "video": app.section = .video
        case "models": app.section = .models
        default: app.section = .home
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppAppearance.apply(AppAppearance.current)
        #if TOOLULA_SELFTEST
        applySelfTestFlags()
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 上次崩溃留下的 llama.cpp / MTP 引擎 / ComfyUI (只清理 Toolula 自己启动、已失去父进程的)
        Task.detached(priority: .utility) { ProcessJanitor.cleanupOrphans() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // 后台常驻: 主窗口关掉后隐藏 Dock 图标, 留在菜单栏
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard BackgroundMode.enabled, let w = note.object as? NSWindow, w.identifier?.rawValue.contains("main") == true else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.setActivationPolicy(.accessory) }
        }
        #if TOOLULA_SELFTEST
        runSelfTestIfRequested()
        #endif
    }

    /// 把照片拖到 Dock / 桌面图标上 -> 打开修图页
    func application(_ application: NSApplication, open urls: [URL]) {
        // 桌面小组件的按钮: toolula://chat, toolula://photo/add ...
        let links = urls.filter { $0.scheme == "toolula" }
        for l in links {
            if store != nil { Task { @MainActor in self.handleLink(l) } } else { pendingLinks.append(l) }
        }
        let urls = urls.filter { $0.isFileURL }
        guard !urls.isEmpty else { return }
        if let store {
            Task { @MainActor in
                self.app?.section = .photo
                store.add(urls: urls)
            }
        } else { pending += urls }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            ComfyEngine.shared.stopOwned(); BuiltinEngine.shared.stop(); MLXEngine.shared.stop()
            if let chat { chat.save(); chat.storage.flush() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !BackgroundMode.enabled }

}

@main
struct ToolulaAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store()
    @StateObject private var chat = ChatStore()
    @StateObject private var app = AppState()
    @StateObject private var automations = AutomationStore()
    @AppStorage("backgroundMode") private var backgroundMode = false

    init() {
        // 滚动条只在滚动时出现 (只影响 Toolula 自己, 不改系统设置)
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
    }

    var body: some Scene {
        Window("Toolula AI", id: "main") {
            RootView()
                .environmentObject(store)
                .environmentObject(chat)
                .environmentObject(app)
                .environmentObject(automations)
                .frame(minWidth: 1180, minHeight: 700)
                .onAppear(perform: startup)
        }
        .windowToolbarStyle(.unified)

        // 后台常驻时菜单栏里的图标
        MenuBarExtra(isInserted: $backgroundMode) {
            MenuBarContent()
                .environmentObject(automations)
                .environmentObject(app)
        } label: {
            Image(systemName: automations.runningTask == nil ? "sparkles" : "sparkles.rectangle.stack")
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新对话") { app.section = .chat; chat.newConversation() }.keyboardShortcut("n")
                Button("添加照片…") { app.section = .photo; openPanel(store) }.keyboardShortcut("o")
            }
            CommandMenu("修图") {
                Button("AI 修图") { store.aiEdit() }.keyboardShortcut("e")
                Button("AI 选片") { store.cull() }
                Button("AI 关键词和描述") { store.tag() }
                Divider()
                Button("复制设置") { store.copySettings() }.keyboardShortcut("c", modifiers: [.command, .shift])
                Button("粘贴设置") { store.pasteSettings() }.keyboardShortcut("v", modifiers: [.command, .shift])
                Divider()
                Button("导出 JPEG…") { store.exportJPEG(maxSide: nil) }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button("发送到 Lightroom") { store.sendToLightroom() }
                Button("发送到 Photoshop（Camera Raw）") { store.sendToPhotoshop() }
                Button("发送到 Luminar Neo（16 位 TIFF）") { store.sendToLuminar() }
                Divider()
                Button("存成 Lightroom / Photoshop 预设…") { store.savePresetForAdobe() }
                Button("导出 LUT…") { store.exportLUT() }
            }
            CommandGroup(after: .appSettings) {
                Button("设置向导…") { SetupWizardState.shared.show = true }
            }
            CommandGroup(replacing: .help) {
                Button("导出诊断报告…") { Diagnostics.exportAndReveal() }
            }
            CommandGroup(after: .toolbar) {
                Picker("外观", selection: Binding(get: { AppAppearance.current }, set: { AppAppearance.apply($0) })) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
            }
            CommandMenu("前往") {
                Button("命令面板…") { app.showPalette.toggle() }.keyboardShortcut("k")
                Divider()
                ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { i, s in
                    Button(s.rawValue.locKey) { app.section = s }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
            }
        }
    }

    private func startup() {
        delegate.store = store
        delegate.chat = chat
        delegate.app = app
        chat.photoStore = store
        Diagnostics.chat = chat
        QuickAsk.shared.setup(chat: chat, app: app)
        automations.photoStore = store
        SystemInfo.shared.start()
        Task.detached { LightroomSetup.syncPlugin() }
        ModelManager.shared.refresh()
        if BuiltinEngine.installed { BuiltinEngine.writeInfo() }
        Task {
            try? await Task.sleep(for: .seconds(1.5))   // 等模型列表刷新
            if !SelfTest.isActive { SetupWizardState.shared.showOnLaunchIfNeeded() }
        }
        automations.start()
        store.refreshTaste()
        Task {
            // 把电脑信息写进 AI 的系统提示
            for _ in 0..<20 where SystemInfo.shared.chip.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            SystemInfoSnapshot.text = SystemInfo.shared.promptText
        }
        if !delegate.pendingLinks.isEmpty {
            let links = delegate.pendingLinks
            delegate.pendingLinks = []
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { for l in links { delegate.handleLink(l) } }
        }
        if !delegate.pending.isEmpty {
            app.section = .photo
            store.add(urls: delegate.pending)
            delegate.pending = []
        }
    }
}

@MainActor
func openPanel(_ store: Store) {
    let p = NSOpenPanel()
    p.allowsMultipleSelection = true
    p.canChooseDirectories = true
    p.allowedContentTypes = [.image, .rawImage, .folder]
    p.message = String(localized: "选择照片或文件夹（支持 JPEG / HEIC / PNG / TIFF / RAW）")
    if p.runModal() == .OK { store.add(urls: p.urls) }
}


/// 窗口被关掉 (后台常驻模式) 时, 用它重新打开主窗口
@MainActor
enum WindowOpener {
    static var open: OpenWindowAction?
    static func showMain() {
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            open?(id: "main")
        }
    }
}
