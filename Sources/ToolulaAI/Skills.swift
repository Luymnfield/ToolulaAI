import Foundation
import SwiftUI

/// 一个技能: 一套可以反复使用的做事方法
struct Skill: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var description: String
    var instructions: String
    var enabled = true
    var created = Date()
    // 从 GitHub 导入的技能
    var source: String?        // owner/repo
    var sourcePath: String?    // 仓库里技能文件夹的路径
    var sourceRef: String?     // 分支
    var sourceSHA: String?     // SKILL.md 的版本 (用来检查更新)
    var folder: String?        // 下载到本机的文件夹
    var license: String?
    var sourceURL: URL? {
        guard let source else { return nil }
        return URL(string: "https://github.com/\(source)/tree/\(sourceRef ?? "main")/\(sourcePath ?? "")")
    }
}

@MainActor
final class SkillStore: ObservableObject {
    static let shared = SkillStore()

    @Published var skills: [Skill] = [] { didSet { save() } }
    @Published var selected: UUID?
    private let file = AppPaths.dataFile("skills.json")

    static var starters: [Skill] {
        [
            Skill(name: String(localized: "网页调研"),
                  description: String(localized: "上网搜索一个主题，读几篇资料，整理成带来源链接的总结"),
                  instructions: String(localized: """
                  1. 用 web_search 搜索主题（必要时换 2~3 个关键词）。
                  2. 选 3~5 个最相关、最可靠的结果，用 browser_open 打开阅读。
                  3. 整理成：一句话结论 → 要点（每条注明来自哪个网站）→ 不同说法或需要注意的地方 → 来源链接列表。
                  4. 不要编造网页里没有的内容。
                  """)),
            Skill(name: String(localized: "整理文件夹"),
                  description: String(localized: "把一个文件夹里的文件按类型分到子文件夹，不删除任何文件"),
                  instructions: String(localized: """
                  1. 先用 list_directory 看清楚文件夹里有什么，向用户说明打算怎么分类。
                  2. 按 图片 / 文档 / 安装包 / 压缩包 / 视频 / 音频 / 其他 分类，用 mkdir -p 建子文件夹，用 mv -n 移动（不覆盖同名文件）。
                  3. 绝对不要删除文件。
                  4. 最后汇报每类移动了多少个文件。
                  """)),
            Skill(name: String(localized: "照片批量修图"),
                  description: String(localized: "把一个文件夹里的照片按指定风格修好并导出"),
                  instructions: String(localized: """
                  1. 确认照片所在文件夹和想要的风格（用户没说风格就用「自动优化，让照片自然好看」）。
                  2. 用 photo_edit 处理，paths 填文件夹路径。
                  3. 汇报修了几张、导出到哪里，并提醒用户可以在「修图」页继续微调。
                  """)),
        ]
    }

    init() {
        if let list = SafeJSON.load([Skill].self, from: file) {
            skills = list
        } else {
            skills = Self.starters
        }
        selected = skills.first?.id
    }

    private func save() {
        SafeJSON.save(skills, to: file)
    }

    func skill(named name: String) -> Skill? {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        return skills.first { $0.name.lowercased() == n } ?? skills.first { $0.name.lowercased().contains(n) && !n.isEmpty }
    }

    @discardableResult
    func add(name: String, description: String, instructions: String) -> Skill {
        if let i = skills.firstIndex(where: { $0.name == name }) {
            skills[i].description = description
            skills[i].instructions = instructions
            return skills[i]
        }
        let s = Skill(name: name, description: description, instructions: instructions)
        skills.insert(s, at: 0)
        selected = s.id
        return s
    }

    func update(_ id: UUID, _ f: (inout Skill) -> Void) {
        guard let i = skills.firstIndex(where: { $0.id == id }) else { return }
        f(&skills[i])
    }

    /// 系统提示里的技能清单 (只列名字和简介, 用到时再取完整说明)
    var promptSection: String {
        let on = skills.filter { $0.enabled }
        var s = "\n\n【技能】"
        if !on.isEmpty {
            s += "任务符合时先 use_skill 读步骤再照做：\n"
            s += on.map { "- \($0.name)：\($0.description)" }.joined(separator: "\n")
        }
        s += "\n用户教你新流程或说「做成技能」时，用 use_skill 带上 description 和 instructions 保存。"
        return s
    }

    /// 用户用 "/技能名 内容" 直接调用技能
    func expandSlash(_ text: String) -> String {
        guard text.hasPrefix("/") else { return text }
        let body = text.dropFirst()
        let name = body.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard let sk = skill(named: name) else { return text }
        let rest = body.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
        return "【使用技能：\(sk.name)】\n\(sk.instructions)\n\n" + (rest.isEmpty ? "" : "用户的具体要求：\(rest)")
    }
}

struct SkillsView: View {
    @ObservedObject var store = SkillStore.shared
    @State private var showGitHub = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Button {
                    store.add(name: String(localized: "新技能"), description: "", instructions: "")
                } label: { Label("新建技能", systemImage: "plus").frame(maxWidth: .infinity) }
                .controlSize(.large).focusEffectDisabled().padding(.horizontal, 8).padding(.top, 8)
                Button { showGitHub = true } label: {
                    Label("从 GitHub 添加", systemImage: "square.and.arrow.down.on.square").frame(maxWidth: .infinity)
                }
                .controlSize(.large).focusEffectDisabled().padding(8)
                List(selection: $store.selected) {
                    ForEach(store.skills) { s in
                        HStack {
                            Image(systemName: s.source != nil ? "shippingbox" : (s.enabled ? "sparkles" : "moon.zzz"))
                                .foregroundStyle(s.enabled ? Color.toolula : .secondary)
                            VStack(alignment: .leading) {
                                Text(s.name).lineLimit(1)
                                Text(s.description).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .tag(s.id)
                        .contextMenu { Button("删除技能", role: .destructive) { store.skills.removeAll { $0.id == s.id } } }
                    }
                }
                .onDeleteCommand { if let id = store.selected { store.skills.removeAll { $0.id == id } } }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
            .sheet(isPresented: $showGitHub) { GitHubSkillsSheet() }
        } detail: {
            if let id = store.selected, store.skills.contains(where: { $0.id == id }) {
                SkillEditor(skillId: id)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(Color.toolula)
                    Text("技能").font(.title.bold())
                    Text("技能是一套可以反复使用的做事方法。\n在对话里直接说「把刚才的流程做成技能」，或者在这里手动新建。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct SkillEditor: View {
    @ObservedObject var store = SkillStore.shared
    let skillId: UUID
    @State private var updateStatus: String?
    @State private var checking = false
    @State private var update: GHSkill?

    var skill: Skill { store.skills.first { $0.id == skillId }! }
    func bind<T>(_ kp: WritableKeyPath<Skill, T>) -> Binding<T> {
        Binding(get: { skill[keyPath: kp] }, set: { v in store.update(skillId) { $0[keyPath: kp] = v } })
    }

    var body: some View {
        Form {
            Section {
                TextField("名称", text: bind(\.name))
                TextField("简介（AI 靠它判断什么时候用这个技能）", text: bind(\.description))
                Toggle("启用", isOn: bind(\.enabled))
            }
            Section {
                TextEditor(text: bind(\.instructions)).font(.body).frame(minHeight: 220)
            } header: { Text("具体步骤") } footer: {
                Text("在对话里输入「/\(skill.name) 具体要求」可以直接使用这个技能；AI 也会在合适的时候自己调用。")
            }
            if let repo = skill.source {
                Section {
                    HStack {
                        Label(repo, systemImage: "shippingbox")
                        Spacer()
                        if let u = skill.sourceURL { Link("在 GitHub 上查看", destination: u).font(.caption) }
                    }
                    if let l = skill.license, !l.isEmpty { Text(l).font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button("检查更新") {
                            checking = true; updateStatus = nil; update = nil
                            Task {
                                do {
                                    update = try await store.checkUpdate(skill)
                                    updateStatus = update == nil ? String(localized: "已经是最新版本") : String(localized: "有新版本")
                                } catch { updateStatus = error.localizedDescription }
                                checking = false
                            }
                        }
                        .disabled(checking)
                        if let u = update {
                            Button("更新到新版本") {
                                Task { updateStatus = await store.importSkill(u) ?? String(localized: "已更新"); update = nil }
                            }
                        }
                        if checking { ProgressView().controlSize(.small) }
                        if let s = updateStatus { Text(s).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if let f = skill.folder {
                            Button("在访达中显示文件") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f)]) }
                        }
                    }
                    let files = store.fileList(skill)
                    if !files.isEmpty {
                        Text(files.prefix(12).joined(separator: "\n") + (files.count > 12 ? "\n…" : ""))
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                } header: { Text("来自 GitHub") }
            }
            Section {
                Button("删除技能", role: .destructive) {
                    if let f = skill.folder { try? FileManager.default.removeItem(atPath: f) }
                    store.skills.removeAll { $0.id == skillId }
                    store.selected = store.skills.first?.id
                }
            }
        }
        .formStyle(.grouped)
    }
}
