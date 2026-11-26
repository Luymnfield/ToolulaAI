import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case home = "主页"
    case chat = "助手"
    case photo = "修图"
    case video = "视频"
    case image = "绘图"
    case automation = "自动化"
    case skills = "技能"
    case memory = "记忆"
    case models = "模型"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "house"
        case .chat: return "bubble.left.and.text.bubble.right"
        case .photo: return "camera.filters"
        case .video: return "film"
        case .image: return "paintbrush.pointed"
        case .automation: return "clock.arrow.2.circlepath"
        case .skills: return "sparkles"
        case .memory: return "brain"
        case .models: return "cpu"
        }
    }
    /// 左侧功能栏里的项目 (主页用顶部的图标进入)
    static let railItems: [AppSection] = [.chat, .photo, .image, .video, .automation, .skills, .memory, .models]
}

@MainActor
final class AppState: ObservableObject {
    @Published var section: AppSection = AppSection(rawValue: UserDefaults.standard.string(forKey: "section") ?? "") ?? .home {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: "section") }
    }
    @Published var showPalette = false
    @Published var showTasks = false
}

/// Toolula 的品牌绿 (取自变色龙 logo)
extension Color {
    static let toolula = Color(red: 0.29, green: 0.78, blue: 0.52)
}

struct RootView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var chat: ChatStore
    @EnvironmentObject var automations: AutomationStore
    @ObservedObject var models = ModelManager.shared
    @ObservedObject var info = SystemInfo.shared
    @ObservedObject var wizard = SetupWizardState.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            rail
            Divider()
            Group {
                switch app.section {
                case .home: HomeView()
                case .chat: ChatView()
                case .photo: ContentView()
                case .video: VideoView()
                case .image: ImageView()
                case .automation: AutomationView()
                case .skills: SkillsView()
                case .memory: MemoryView()
                case .models: ModelsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { TaskCenterButton() }
            ToolbarItem(placement: .primaryAction) { AppearanceButton() }
        }
        .sheet(isPresented: $wizard.show) { SetupWizard().environmentObject(app) }
        .sheet(isPresented: $app.showPalette) { CommandPalette().environmentObject(app).environmentObject(chat) }
        .onAppear { WindowOpener.open = openWindow }
        .modifier(PageTitle(section: app.section))
    }

    /// 左侧功能栏：按钮尽量大；窗口矮时按钮缩小一档，底部的机器信息始终保留
    var rail: some View {
        ViewThatFits(in: .vertical) {
            railBody(size: 2)
            railBody(size: 1)
            railBody(size: 0)
        }
        .frame(width: 86)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }

    func railBody(size: Int) -> some View {
        let large = size > 0
        return VStack(spacing: large ? 5 : 3) {
            // 点 logo 回到主页
            Button { app.section = .home } label: {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: large ? 48 : 42, height: large ? 48 : 42)
                    .shadow(color: .black.opacity(app.section == .home ? 0.25 : 0.1), radius: app.section == .home ? 4 : 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(Text("主页"))
            .accessibilityLabel(Text("主页"))
            .padding(.top, 10).padding(.bottom, large ? 8 : 4)

            ForEach(AppSection.railItems) { s in
                RailButton(section: s, selected: app.section == s, size: size,
                           busy: s == .automation && automations.runningTask != nil) { app.section = s }
            }
            Spacer(minLength: 8)
            Circle().fill(models.online ? .green : .red).frame(width: 8, height: 8)
                .help(models.online ? Text("本地 AI 在线") : Text("本地 AI 离线"))
                .accessibilityElement()
                .accessibilityLabel(models.online ? Text("本地 AI 在线") : Text("本地 AI 离线"))
            MachineBadge(compact: true)
                .frame(width: 70)
                .padding(.bottom, 10)
        }
    }
}

/// 左侧功能栏的按钮: 选中时柔和的底色, 没有键盘焦点框
struct RailButton: View {
    let section: AppSection
    let selected: Bool
    var size = 2          // 2 大 · 1 中 · 0 小（窗口矮时自动缩小）
    let busy: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: size == 0 ? 2 : 4) {
                Image(systemName: section.icon).font(.system(size: [18, 20, 22][size], weight: selected ? .semibold : .regular))
                    .frame(height: [21, 24, 26][size])
                Text(section.rawValue.locKey).font(.system(size: [10, 11.5, 12][size], weight: selected ? .semibold : .regular))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: [60, 68, 70][size], height: [46, 54, 60][size])
            .foregroundStyle(selected ? Color.toolula : (hover ? Color.primary : Color.secondary))
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.toolula.opacity(0.14) : (hover ? Color.primary.opacity(0.06) : .clear))
            )
            .overlay(alignment: .topTrailing) {
                if busy { Circle().fill(.green).frame(width: 7, height: 7).padding(6) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(section.rawValue.locKey))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(busy ? Text("正在运行") : Text(verbatim: ""))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

// MARK: - 主页

struct HomeView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var chat: ChatStore
    @EnvironmentObject var automations: AutomationStore
    @ObservedObject var models = ModelManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                SetupBanner()
                features
                HStack(alignment: .top, spacing: 20) {
                    recentChats
                    automationStatus
                }
            }
            .padding(36)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    var header: some View {
        HStack(alignment: .center, spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 6) {
                Text("Toolula AI").font(.system(size: 34, weight: .bold))
                Text("完全在本机运行的 AI：聊天、执行命令、整理文件、修图、自动化").foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Circle().fill(models.online ? .green : .red).frame(width: 8, height: 8)
                    (models.online ? Text("本地 AI 在线") : Text("本地 AI 离线"))
                        .font(.callout).foregroundStyle(.secondary)
                    if !models.online { Button("启动") { models.startServer() }.controlSize(.small) }
                }
            }
            Spacer(minLength: 20)
            MachineBadge(large: true)
                .padding(20)
                .frame(width: 430)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.045)))
        }
    }

    var features: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
            FeatureCard(icon: "bubble.left.and.text.bubble.right", title: "助手",
                        text: "让 AI 帮你做事：聊天、执行命令、整理文件、写代码") { app.section = .chat; chat.newConversation() }
            FeatureCard(icon: "camera.filters", title: "修图",
                        text: "拖入照片，AI 按你想要的风格调色，可发送到 Lightroom、Photoshop 或 Luminar Neo 继续编辑") { app.section = .photo }
            FeatureCard(icon: "paintbrush.pointed", title: "绘图",
                        text: "写下想要的画面，本机的图片模型几十秒画出来") { app.section = .image }
            FeatureCard(icon: "film", title: "视频",
                        text: "用本机的视频模型（MiniMax H3、Wan 2.2）把文字或图片变成视频") { app.section = .video }
            FeatureCard(icon: "clock.arrow.2.circlepath", title: "自动化",
                        text: "按时间或在文件夹有新文件时，让 AI 自动干活") { app.section = .automation }
            FeatureCard(icon: "sparkles", title: "技能",
                        text: "教 AI 一套做事方法，以后一句话就能反复使用") { app.section = .skills }
            FeatureCard(icon: "brain", title: "记忆",
                        text: "AI 记住你的偏好和习惯，每次对话都用得上") { app.section = .memory }
            FeatureCard(icon: "cpu", title: "模型",
                        text: "下载本地模型或连接云端 API，选择对话、修图、绘图和视频用的模型") { app.section = .models }
        }
    }

    var recentChats: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近的对话").font(.headline)
            if chat.conversations.isEmpty {
                Text("还没有对话").foregroundStyle(.secondary)
            }
            ForEach(chat.conversations.prefix(5)) { c in
                Button {
                    chat.selected = c.id
                    app.section = .chat
                } label: {
                    HStack {
                        Image(systemName: "bubble.left").foregroundStyle(.secondary)
                        (c.title.isEmpty || c.title == "新对话" ? Text("新对话") : Text(c.title)).lineLimit(1)
                        Spacer()
                        Text(c.updated, style: .relative).font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    var automationStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("自动化").font(.headline)
            if automations.tasks.isEmpty {
                Text("还没有自动化任务").foregroundStyle(.secondary)
            }
            ForEach(automations.tasks.prefix(5)) { t in
                Button {
                    automations.selected = t.id
                    app.section = .automation
                } label: {
                    HStack {
                        Image(systemName: t.enabled ? "clock.badge.checkmark" : "clock")
                            .foregroundStyle(t.enabled ? Color.toolula : .secondary)
                        Text(t.name).lineLimit(1)
                        Spacer()
                        if automations.runningTask == t.id { ProgressView().controlSize(.mini) }
                        Text(t.triggerText).font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct FeatureCard: View {
    let icon: String
    let title: String
    let text: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.toolula)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.toolula.opacity(0.13)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title.locKey).font(.title3.weight(.semibold))
                    Text(text.locKey).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.primary.opacity(hover ? 0.07 : 0.04))
            )
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(hover ? 0.12 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}


// MARK: - 白天 / 夜间模式

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return String(localized: "跟随系统")
        case .light: return String(localized: "白天模式")
        case .dark: return String(localized: "夜间模式")
        }
    }
    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system
    }
    /// 应用到整个 App (所有窗口, 包括菜单栏面板)
    static func apply(_ a: AppAppearance) {
        UserDefaults.standard.set(a.rawValue, forKey: "appearance")
        switch a {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

struct AppearanceButton: View {
    @AppStorage("appearance") private var raw = AppAppearance.system.rawValue
    var body: some View {
        let cur = AppAppearance(rawValue: raw) ?? .system
        Button {
            let all = AppAppearance.allCases
            let next = all[(all.firstIndex(of: cur)! + 1) % all.count]
            AppAppearance.apply(next)
            raw = next.rawValue
        } label: {
            Label { Text("外观") } icon: { Image(systemName: cur.icon) }
        }
        .help(Text("外观：\(cur.title)（点一下切换）"))
        .accessibilityLabel(Text("外观"))
        .accessibilityValue(Text(cur.title))
        .accessibilityHint(Text("点一下切换"))
    }
}
