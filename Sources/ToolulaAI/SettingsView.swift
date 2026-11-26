import AppKit
import SwiftUI

/// 统一设置窗口 (⌘,)。各页面里原有的入口还在, 但以这里为准。
enum SettingsTab: Int, CaseIterable, Identifiable {
    case general, models, computer, shortcuts, privacy, diagnostics
    var id: Int { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .general: return "通用"
        case .models: return "模型与加速"
        case .computer: return "操作电脑"
        case .shortcuts: return "快捷键"
        case .privacy: return "隐私与数据"
        case .diagnostics: return "诊断"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .models: return "bolt.horizontal"
        case .computer: return "cursorarrow.click"
        case .shortcuts: return "command"
        case .privacy: return "lock.shield"
        case .diagnostics: return "stethoscope"
        }
    }
}

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: $tab) {
            ForEach(SettingsTab.allCases) { t in
                Group {
                    switch t {
                    case .general: GeneralSettings()
                    case .models: ScrollView { AccelerationBlock().padding(20) }
                    case .computer: ScrollView { ComputerControlPanel().frame(maxWidth: .infinity) }
                    case .shortcuts: ShortcutSettings()
                    case .privacy: PrivacySettings()
                    case .diagnostics: DiagnosticsSettings()
                    }
                }
                .tabItem { Label(t.title, systemImage: t.icon) }
                .tag(t.rawValue)
            }
        }
        .frame(width: 640, height: 520)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var automations: AutomationStore
    @State private var appearance = AppAppearance.current

    var body: some View {
        Form {
            Picker("外观", selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: appearance) { _, v in AppAppearance.apply(v) }
            Section("语言") {
                LanguagePicker()
                Text("支持简体中文、繁體中文、English、日本語、한국어、Deutsch、Français、Español、Português、Русский。AI 默认也用这种语言回答。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("启动") {
                Toggle("登录 Mac 时自动打开", isOn: Binding(get: { automations.launchAtLogin }, set: { automations.setLaunchAtLogin($0) }))
                BackgroundToggle()
            }
            Section {
                Button("设置向导…") { SetupWizardState.shared.show = true; WindowOpener.showMain() }
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutSettings: View {
    @ObservedObject var hk = HotKeyCenter.shared

    var body: some View {
        Form {
            Section("快速提问小窗（全局）") {
                Toggle("在任何程序里用快捷键唤出", isOn: $hk.enabled)
                LabeledContent("快捷键") { HotKeyRecorder() }
                Text("点按钮后按下新的组合（至少带 ⌘、⌥ 或 ⌃）。被其他程序占用时会提示。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("处理选中的文字（全局）") {
                Toggle("在任何程序里选中文字后用快捷键翻译、解释、改写", isOn: $hk.textEnabled)
                LabeledContent("快捷键") { HotKeyRecorder(text: true) }
                Text("需要「辅助功能」权限。改写和翻译的结果可以一键替换原文。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("程序内") {
                row("命令面板", "⌘K")
                row("新对话", "⌘N")
                row("发送消息", "⌘↩")
                row("切换页面", "⌘1 … ⌘9")
                row("设置", "⌘,")
                row("快速提问：在助手中继续", "⌘↩")
                row("关闭小窗 / 面板", "Esc")
            }
        }
        .formStyle(.grouped)
    }

    func row(_ t: LocalizedStringKey, _ k: String) -> some View {
        LabeledContent(t) { Text(verbatim: k).font(.body.monospaced()).foregroundStyle(.secondary) }
    }
}

struct PrivacySettings: View {
    @EnvironmentObject var chat: ChatStore
    @State private var backups: [URL] = []
    @State private var confirmDelete = false
    @State private var note: String?

    var body: some View {
        Form {
            StorageSection()
            Section("聚焦搜索") {
                Toggle("在聚焦搜索（⌘Space）里能搜到对话", isOn: Binding(get: { SpotlightIndex.enabled }, set: { v in
                    SpotlightIndex.enabled = v
                    if v { SpotlightIndex.rebuild(chat.conversations) }
                }))
                Text("每个对话在 Toolula 文件夹的 Chats/Search 里有一份纯文本索引，只存在这台 Mac 上。关掉后会立即删除。").font(.caption).foregroundStyle(.secondary)
            }
            Section("对话") {
                Text("对话每个一个文件（Chats 文件夹），写入是原子的，不会写坏。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LabeledContent("对话数量") { Text("\(chat.conversations.count)") }
            }
            Section("备份") {
                Text("启动时自动备份对话（间隔至少 6 小时，保留最近 5 份）。").font(.caption).foregroundStyle(.secondary)
                ForEach(backups.prefix(5), id: \.self) { b in
                    Text(b.lastPathComponent).font(.callout.monospaced())
                }
                HStack {
                    Button("立即备份") {
                        let st = chat.storage
                        chat.save()
                        st.flush()
                        note = st.backup() == nil ? String(localized: "备份失败") : String(localized: "已备份")
                        backups = st.backupList
                    }
                    Button("打开备份文件夹") { NSWorkspace.shared.open(chat.storage.backups) }
                    if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("清除数据") {
                Button("删除全部对话…", role: .destructive) { confirmDelete = true }
                Text("删除前会先自动备份一份，可以从备份文件夹找回。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { backups = chat.storage.backupList }
        .confirmationDialog("删除全部对话？", isPresented: $confirmDelete) {
            Button("删除全部对话", role: .destructive) {
                chat.save(); chat.storage.flush(); chat.storage.backup()
                chat.deleteAll()
                backups = chat.storage.backupList
            }
        } message: { Text("共 \(chat.conversations.count) 个对话。删除前会先备份。") }
    }
}

struct DiagnosticsSettings: View {
    @State private var exporting = false
    @State private var result: String?

    var body: some View {
        Form {
            Section("诊断报告") {
                Text("把日志、系统信息、模型和引擎状态、最近错误打成 zip 放到 Toolula 文件夹的 Logs/Diagnostics 里，方便排查问题。不包含 API Key、对话内容和照片。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("导出诊断报告…") {
                        exporting = true
                        Task {
                            do {
                                let zip = try await Diagnostics.export()
                                result = zip.lastPathComponent
                                NSWorkspace.shared.activateFileViewerSelecting([zip])
                            } catch { result = error.localizedDescription }
                            exporting = false
                        }
                    }
                    .disabled(exporting)
                    if exporting { ProgressView().controlSize(.small) }
                    if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
                }
                Button("打开日志所在文件夹") { NSWorkspace.shared.open(AppPaths.logs) }
            }
            Section("最近") {
                if ProcessJanitor.lastCleanup.isEmpty && SafeJSON.lastErrors.isEmpty {
                    Text("没有记录到问题。").foregroundStyle(.secondary)
                }
                ForEach(ProcessJanitor.lastCleanup, id: \.self) { Text("启动清理：\($0)").font(.caption) }
                ForEach(SafeJSON.lastErrors, id: \.self) { Text(verbatim: $0).font(.caption) }
                if let e = HotKeyCenter.shared.error { Text("快捷键：\(e)").font(.caption).foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
    }
}

/// 存储空间: Toolula 文件夹里每一类占多少, 一键打开、清理缓存
struct StorageSection: View {
    @State private var items: [StorageUsage.Item] = []
    @State private var measuring = false
    @State private var confirmClear = false
    @State private var note: String?

    static func title(_ id: String) -> String {
        switch id {
        case "Images": return String(localized: "生成的图片")
        case "Videos": return String(localized: "生成的视频")
        case "Exports": return String(localized: "修图导出和 LUT")
        case "Chats": return String(localized: "对话")
        case "Attachments": return String(localized: "对话附件和截图")
        case "Backups": return String(localized: "对话备份")
        case "Data": return String(localized: "记忆、技能、自动化等数据")
        case "Logs": return String(localized: "日志和诊断报告")
        case "Cache": return String(localized: "缓存（可以清理）")
        case "Engines": return String(localized: "本地 AI 引擎")
        case "Models": return String(localized: "Toolula 下载的模型")
        default: return id
        }
    }

    var cacheBytes: Int64 { items.first { $0.id == "Cache" }?.bytes ?? 0 }

    var body: some View {
        Section {
            LabeledContent("Toolula 文件夹") {
                Button(AppPaths.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    NSWorkspace.shared.open(AppPaths.root)
                }
                .buttonStyle(.link)
            }
            if items.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("正在计算占用空间…").foregroundStyle(.secondary) }
            }
            ForEach(items) { it in
                HStack {
                    Text(Self.title(it.id))
                    Text(it.id + "/").font(.caption.monospaced()).foregroundStyle(.tertiary)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: it.bytes, countStyle: .file)).monospacedDigit().foregroundStyle(.secondary)
                    Button { NSWorkspace.shared.open(it.url) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless)
                        .help(Text("在访达中打开"))
                        .accessibilityLabel(Text("在访达中打开 \(Self.title(it.id))"))
                }
            }
            HStack {
                Button("清理缓存…") { confirmClear = true }
                    .disabled(cacheBytes == 0)
                Button("重新计算") { Task { await measure() } }.disabled(measuring)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
        } header: {
            Text("存储空间")
        } footer: {
            Text("所有对话、记忆、作品都只存在这台 Mac 上，按类别放在这个文件夹里。缓存会自动控制大小（提示词缓存最多 4 GB），清理后第一次回答会稍慢。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .task { await measure() }
        .confirmationDialog("清理缓存？", isPresented: $confirmClear) {
            Button("清理 \(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))") {
                Task {
                    MLXEngine.shared.stop()      // 提示词缓存正在被 MTP 引擎使用时先停掉它
                    let freed = await Task.detached { StorageUsage.clearCache() }.value
                    note = String(localized: "已释放 \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))")
                    await measure()
                }
            }
        } message: {
            Text("会删除提示词缓存、视频预览和修图临时图片。对话、作品和模型都不受影响。")
        }
    }

    func measure() async {
        measuring = true
        items = await Task.detached(priority: .utility) { StorageUsage.measure() }.value
        measuring = false
    }
}
