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
                Text("界面语言跟随系统（简体中文、English、Deutsch）。想单独给 Toolula 换语言：系统设置 → 通用 → 语言与地区 → 应用程序。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("打开「语言与地区」") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
                }
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
            Section("存储位置") {
                LabeledContent("数据文件夹") {
                    Button(AppPaths.support.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.support])
                    }
                    .buttonStyle(.link)
                }
                Text("所有对话、记忆、设置都只存在这台 Mac 上。对话每个一个文件（conversations 文件夹），写入是原子的，不会写坏。")
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
                Text("把日志、系统信息、模型和引擎状态、最近错误打成 zip 放到桌面，方便排查问题。不包含 API Key、对话内容和照片。")
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
                Button("打开日志所在文件夹") { NSWorkspace.shared.open(AppPaths.support) }
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
