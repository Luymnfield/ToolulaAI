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
        ] + codingStarters
    }

    /// 让助手按 "先读懂 → 计划 → 小步修改 → 验证" 的方式干活的技能 (第 2 版默认技能)
    static var codingStarters: [Skill] {
        [
            Skill(name: String(localized: "写代码"),
                  description: String(localized: "修改或新增代码功能：先读懂相关代码，小步修改，改完编译或跑测试验证"),
                  instructions: String(localized: """
                  1. 先用 list_directory、search_files 弄清项目结构，找到相关文件，用 read_file 读完整再动手。
                  2. 用 plan 列出要改的文件和步骤。
                  3. 用 edit_file 做最小改动，保持原有代码风格，不顺手重构无关代码。
                  4. 改完用 run_shell 编译或运行测试（如 swift build / npm test / pytest）。失败就读错误、修复、再跑，直到通过。
                  5. 汇报：改了哪些文件、为什么改、验证结果。没验证的地方明确说出来。
                  """)),
            Skill(name: String(localized: "调试排错"),
                  description: String(localized: "程序报错或行为不对时：先复现，找到根本原因，再做最小修复并验证"),
                  instructions: String(localized: """
                  1. 先复现：用 run_shell 跑出错误，记下完整报错。
                  2. 根据报错用 search_files 定位代码，用 read_file 读上下文。
                  3. 列出 1~3 个可能原因，逐个用日志或小实验验证，不要靠猜直接改。
                  4. 找到根因后做最小修复，再次运行，确认问题消失且没有引入新错误。
                  5. 说明根因是什么、怎么修的、怎么验证的。
                  """)),
            Skill(name: String(localized: "读懂项目"),
                  description: String(localized: "快速了解一个陌生的代码库或文件夹：做什么、怎么组织、怎么运行"),
                  instructions: String(localized: """
                  1. 用 list_directory 看顶层，用 read_file 读 README 和 package.json / Package.swift / requirements.txt 等配置。
                  2. 找到入口文件和核心模块，各读关键部分。
                  3. 输出：项目做什么 → 技术栈 → 目录结构说明 → 怎么运行 → 关键文件清单。
                  4. 只写读到的内容，没看到的不要猜。
                  """)),
            Skill(name: String(localized: "大任务拆分"),
                  description: String(localized: "步骤多、涉及很多文件或需要长时间的任务：拆成小步，逐步完成并核对"),
                  instructions: String(localized: """
                  1. 用 plan 拆成 3~8 个可以单独验证的步骤。
                  2. 彼此独立的调研类子任务用 delegate 交给子助手，并说清要它返回什么。
                  3. 每完成一步就更新 plan，做完一步验证一步。
                  4. 全部做完后，对照用户的原始要求逐条核对，再汇报。
                  """)),
            Skill(name: String(localized: "Git 操作"),
                  description: String(localized: "提交、分支、查看改动等 git 操作，按安全规则执行"),
                  instructions: String(localized: """
                  1. 先用 git status、git diff 看清当前改动。
                  2. 用户没要求就不 commit、不 push。除非用户明确要求，永远不用 --force、reset --hard、clean -fd。
                  3. 提交信息写清楚做了什么、为什么。
                  4. 不提交 .env、密钥、凭证之类的文件；发现了要提醒用户。
                  """)),
            Skill(name: String(localized: "代码审查"),
                  description: String(localized: "检查代码或改动里的 bug 和问题，按严重程度列出"),
                  instructions: String(localized: """
                  1. 用 git diff 或 read_file 读要审查的代码，必要时读调用它的地方。
                  2. 重点找真实 bug：边界条件、空值、并发、错误处理、安全问题，每条都写出具体的触发场景。
                  3. 按严重程度排序，不确定的标明「可能」。不要列一堆风格意见凑数。
                  4. 没发现问题就直说没发现。
                  """)),
        ]
    }

    init() {
        if let list = SafeJSON.load([Skill].self, from: file) {
            skills = list
        } else {
            skills = Self.starters
        }
        // 老用户: 只补一次新加的默认技能 (之后用户删掉的不会再加回来)
        let seedKey = "skillsSeedVersion"
        if UserDefaults.standard.integer(forKey: seedKey) < 2 {
            let have = Set(skills.map { $0.name })
            let missing = Self.codingStarters.filter { !have.contains($0.name) }
            if !missing.isEmpty { skills += missing }
            UserDefaults.standard.set(2, forKey: seedKey)
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
