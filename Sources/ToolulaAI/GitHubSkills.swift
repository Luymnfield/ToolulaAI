import AppKit
import Foundation
import SwiftUI

// MARK: - 数据

struct GHRepo: Identifiable, Hashable {
    let fullName: String       // owner/repo
    let description: String
    let stars: Int
    let updated: String
    var id: String { fullName }
}

/// 仓库里的一个技能 (SKILL.md 所在的文件夹)
struct GHSkill: Identifiable, Hashable {
    let repo: String
    let branch: String
    let folder: String         // 例如 skills/pdf ("" = 仓库根目录)
    let skillPath: String      // 例如 skills/pdf/SKILL.md
    let sha: String
    var name: String
    var description: String
    var license: String?
    var body: String
    var files: [(path: String, size: Int)]
    var id: String { repo + "/" + skillPath }

    static func == (a: GHSkill, b: GHSkill) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// 安全检查发现的问题
struct RiskFinding: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let file: String
}

// MARK: - GitHub 访问

enum GitHubError: LocalizedError {
    case rateLimited, notFound, http(Int), noSkill
    var errorDescription: String? {
        switch self {
        case .rateLimited: return String(localized: "GitHub 访问次数暂时用完了（每小时 60 次），请过一会儿再试。")
        case .notFound: return String(localized: "找不到这个 GitHub 仓库或路径。")
        case .http(let c): return String(localized: "GitHub 返回错误 \(c)")
        case .noSkill: return String(localized: "这个仓库里没有找到技能（SKILL.md）。")
        }
    }
}

enum GitHub {
    static let maxFileSize = 5_000_000
    static let maxTotalSize = 40_000_000

    static func api(_ path: String, query: [URLQueryItem] = []) async throws -> Any {
        var c = URLComponents(string: "https://api.github.com" + path)!
        if !query.isEmpty { c.queryItems = query }
        var req = URLRequest(url: c.url!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Toolula-AI", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 403 || code == 429 { throw GitHubError.rateLimited }
        if code == 404 { throw GitHubError.notFound }
        guard code == 200 else { throw GitHubError.http(code) }
        return try JSONSerialization.jsonObject(with: data)
    }

    static func raw(_ repo: String, _ branch: String, _ path: String) async throws -> Data {
        let encoded = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let url = URL(string: "https://raw.githubusercontent.com/\(repo)/\(branch)/\(encoded)")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw GitHubError.notFound }
        return data
    }

    /// 搜索有技能的仓库
    static func search(_ query: String) async throws -> [GHRepo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let full = q.isEmpty ? "topic:agent-skills" : "\(q) topic:agent-skills"
        var repos = try await searchRepos(full)
        if repos.count < 5 && !q.isEmpty {
            // 没有打 topic 的仓库: 按名字/简介再找一次
            let more = try await searchRepos("\(q) skills in:name,description,readme")
            for r in more where !repos.contains(r) { repos.append(r) }
        }
        return repos
    }

    private static func searchRepos(_ q: String) async throws -> [GHRepo] {
        let obj = try await api("/search/repositories", query: [URLQueryItem(name: "q", value: q), URLQueryItem(name: "sort", value: "stars"),
                                                               URLQueryItem(name: "per_page", value: "30")])
        let items = (obj as? [String: Any])?["items"] as? [[String: Any]] ?? []
        return items.compactMap { r in
            guard let name = r["full_name"] as? String else { return nil }
            return GHRepo(fullName: name, description: r["description"] as? String ?? "", stars: r["stargazers_count"] as? Int ?? 0,
                          updated: String((r["pushed_at"] as? String ?? "").prefix(10)))
        }
    }

    /// 解析 GitHub 链接: github.com/owner/repo[/tree|blob/branch/path]
    static func parse(_ link: String) -> (repo: String, branch: String?, path: String?)? {
        var s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://", "http://", "www."] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        if s.hasPrefix("github.com/") { s = String(s.dropFirst("github.com/".count)) }
        let parts = s.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let repo = parts[0] + "/" + parts[1].replacingOccurrences(of: ".git", with: "")
        if parts.count >= 4, parts[2] == "tree" || parts[2] == "blob" {
            var path = parts.dropFirst(4).joined(separator: "/")
            if path.lowercased().hasSuffix("skill.md") { path = (path as NSString).deletingLastPathComponent }
            return (repo, parts[3], path)
        }
        return (repo, nil, nil)
    }

    /// 列出仓库里所有技能 (每个 SKILL.md 一个)
    static func skills(in repo: String, branch: String? = nil, onlyPath: String? = nil) async throws -> [GHSkill] {
        var br = branch
        if br == nil {
            let info = try await api("/repos/\(repo)") as? [String: Any]
            br = info?["default_branch"] as? String ?? "main"
        }
        let b = br!
        let tree = try await api("/repos/\(repo)/git/trees/\(b)", query: [URLQueryItem(name: "recursive", value: "1")]) as? [String: Any]
        let entries = (tree?["tree"] as? [[String: Any]]) ?? []
        let blobs: [(String, Int, String)] = entries.compactMap { e in
            guard e["type"] as? String == "blob", let p = e["path"] as? String else { return nil }
            return (p, e["size"] as? Int ?? 0, e["sha"] as? String ?? "")
        }
        var skillFiles = blobs.filter { ($0.0 as NSString).lastPathComponent.lowercased() == "skill.md" }
        if let only = onlyPath, !only.isEmpty {
            skillFiles = skillFiles.filter { ($0.0 as NSString).deletingLastPathComponent == only }
        }
        guard !skillFiles.isEmpty else { throw GitHubError.noSkill }

        var out: [GHSkill] = []
        for (path, _, sha) in skillFiles.prefix(60) {
            let folder = (path as NSString).deletingLastPathComponent
            let prefix = folder.isEmpty ? "" : folder + "/"
            // 根目录的技能只带上同级和子文件夹里不属于别的技能的文件
            let files = blobs.filter { b in
                guard b.0.hasPrefix(prefix), b.0 != path else { return false }
                if folder.isEmpty { return !b.0.contains("/") }
                return true
            }.map { (String($0.0.dropFirst(prefix.count)), $0.1) }
            guard let data = try? await raw(repo, b, path), let text = String(data: data, encoding: .utf8) else { continue }
            let (meta, body) = frontmatter(text)
            out.append(GHSkill(repo: repo, branch: b, folder: folder, skillPath: path, sha: sha,
                               name: meta["name"] ?? ((folder as NSString).lastPathComponent.isEmpty ? repo : (folder as NSString).lastPathComponent),
                               description: meta["description"] ?? "", license: meta["license"], body: body, files: files))
        }
        return out.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// 解析 SKILL.md 开头的 --- name / description --- 部分
    static func frontmatter(_ text: String) -> ([String: String], String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return ([:], text) }
        var meta: [String: String] = [:]
        var lastKey: String?
        for l in lines[1..<end] {
            if let colon = l.firstIndex(of: ":"), !l.hasPrefix(" ") {
                let k = l[..<colon].trimmingCharacters(in: .whitespaces)
                var v = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) { v = String(v.dropFirst().dropLast()) }
                if v == ">" || v == "|" { v = "" }
                meta[k] = v
                lastKey = k
            } else if let k = lastKey {
                meta[k] = ((meta[k] ?? "") + " " + l.trimmingCharacters(in: .whitespaces)).trimmingCharacters(in: .whitespaces)
            }
        }
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (meta, body)
    }

    // MARK: 安全检查

    static let riskRules: [(pattern: String, label: String)] = [
        (#"(curl|wget)[^\n|]*\|\s*(ba|z)?sh"#, "下载网络脚本并直接运行"),
        (#"rm\s+-[a-z]*r[a-z]*f|rm\s+-[a-z]*f[a-z]*r"#, "强制删除文件的命令"),
        (#"\bsudo\b"#, "需要管理员权限"),
        (#"~/\.ssh|id_rsa|id_ed25519|security\s+find-(generic|internet)-password|Keychain"#, "读取密钥或钥匙串"),
        (#"base64\s+(-d|--decode)|\beval\s*\(|\bexec\s*\("#, "隐藏或动态执行代码"),
        (#"(?i)ignore (all |any )?(previous|prior|above) (instructions|rules)|忽略(之前|以上|前面)的"#, "试图改变 AI 的规则"),
        (#"(curl\s+[^\n]*(-X\s*POST|--data|-d\s|-F\s)|requests\.post|fetch\([^)]*method:\s*['"]POST)"#, "向网络发送数据"),
        (#"(?i)(api[_-]?key|secret|password|token)\s*[:=]"#, "处理密钥或密码"),
    ]

    static func scan(text: String, file: String) -> [RiskFinding] {
        riskRules.compactMap { rule in
            text.range(of: rule.pattern, options: .regularExpression) != nil ? RiskFinding(text: rule.label.loc, file: file) : nil
        }
    }

    static let scriptExtensions: Set<String> = ["sh", "bash", "zsh", "py", "js", "ts", "rb", "pl", "applescript", "command"]
}

// MARK: - 导入

extension SkillStore {
    var skillsFolder: URL {
        let u = AppPaths.support.appendingPathComponent("skills")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// 下载技能文件夹并保存成 Toolula 技能. 返回错误信息 (nil = 成功)
    func importSkill(_ gh: GHSkill) async -> String? {
        let safeName = (gh.repo + "-" + gh.name).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "-")
        let dir = skillsFolder.appendingPathComponent(safeName)
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(("---\nname: \(gh.name)\ndescription: \(gh.description)\n---\n\n" + gh.body).utf8)
                .write(to: dir.appendingPathComponent("SKILL.md"))
            var total = 0
            let prefix = gh.folder.isEmpty ? "" : gh.folder + "/"
            for f in gh.files where f.size <= GitHub.maxFileSize {
                total += f.size
                if total > GitHub.maxTotalSize { break }
                let data = try await GitHub.raw(gh.repo, gh.branch, prefix + f.path)
                let dest = dir.appendingPathComponent(f.path)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: dest)
            }
        } catch {
            return error.localizedDescription
        }
        var s = Skill(name: gh.name, description: gh.description, instructions: gh.body)
        s.source = gh.repo
        s.sourcePath = gh.folder
        s.sourceRef = gh.branch
        s.sourceSHA = gh.sha
        s.folder = dir.path
        s.license = gh.license
        if let i = skills.firstIndex(where: { $0.source == gh.repo && $0.sourcePath == gh.folder }) {
            s.id = skills[i].id
            s.enabled = skills[i].enabled
            skills[i] = s
        } else {
            skills.insert(s, at: 0)
        }
        selected = s.id
        return nil
    }

    /// 检查 GitHub 上有没有新版本. 返回新版本 (nil = 已是最新)
    func checkUpdate(_ skill: Skill) async throws -> GHSkill? {
        guard let repo = skill.source else { return nil }
        let list = try await GitHub.skills(in: repo, branch: skill.sourceRef, onlyPath: skill.sourcePath ?? "")
        guard let latest = list.first else { return nil }
        return latest.sha != skill.sourceSHA ? latest : nil
    }

    /// 技能文件夹里的文件 (给 AI 看)
    func fileList(_ skill: Skill) -> [String] {
        guard let folder = skill.folder, let e = FileManager.default.enumerator(atPath: folder) else { return [] }
        return (e.allObjects as? [String] ?? []).filter { p in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(p), isDirectory: &isDir)
            return !isDir.boolValue && p != "SKILL.md"
        }.sorted()
    }
}

// MARK: - 界面: 从 GitHub 添加技能

@MainActor
final class GitHubBrowser: ObservableObject {
    @Published var query = ""
    @Published var link = ""
    @Published var repos: [GHRepo] = []
    @Published var selectedRepo: String?
    @Published var skills: [GHSkill] = []
    @Published var selectedSkill: GHSkill?
    @Published var loading = false
    @Published var error: String?
    @Published var importing = false
    @Published var imported: Set<String> = []

    static let recommended: [GHRepo] = [
        GHRepo(fullName: "anthropics/skills", description: "Anthropic 官方技能库（文档、PDF、表格、设计等）", stars: 0, updated: ""),
        GHRepo(fullName: "addyosmani/agent-skills", description: "工程开发类技能", stars: 0, updated: ""),
        GHRepo(fullName: "coreyhaines31/marketingskills", description: "营销、文案、SEO 类技能", stars: 0, updated: ""),
        GHRepo(fullName: "obra/superpowers", description: "软件开发方法类技能", stars: 0, updated: ""),
    ]

    func showRecommended() { repos = Self.recommended; error = nil }

    func search() {
        loading = true; error = nil
        Task {
            defer { loading = false }
            do { repos = try await GitHub.search(query) } catch { self.error = error.localizedDescription }
        }
    }

    func openRepo(_ repo: String, branch: String? = nil, path: String? = nil) {
        selectedRepo = repo; skills = []; selectedSkill = nil; loading = true; error = nil
        Task {
            defer { loading = false }
            do {
                skills = try await GitHub.skills(in: repo, branch: branch, onlyPath: path)
                if skills.count == 1 { selectedSkill = skills[0] }
            } catch { self.error = error.localizedDescription }
        }
    }

    func openLink() {
        guard let p = GitHub.parse(link) else { error = String(localized: "看不懂这个链接，请粘贴 GitHub 仓库或技能文件夹的地址"); return }
        if !repos.contains(where: { $0.fullName == p.repo }) {
            repos.insert(GHRepo(fullName: p.repo, description: "", stars: 0, updated: ""), at: 0)
        }
        openRepo(p.repo, branch: p.branch, path: p.path)
    }

    func risks(_ s: GHSkill) -> [RiskFinding] {
        var out = GitHub.scan(text: s.body, file: "SKILL.md")
        let scripts = s.files.filter { GitHub.scriptExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }
        if !scripts.isEmpty {
            out.append(RiskFinding(text: String(localized: "包含 \(scripts.count) 个脚本（AI 每次运行前都会征求你同意）"), file: scripts.map(\.path).joined(separator: ", ")))
        }
        return out
    }
}

struct GitHubSkillsSheet: View {
    @StateObject private var gh = GitHubBrowser()
    @ObservedObject var store = SkillStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                repoList.frame(width: 300)
                Divider()
                skillList.frame(width: 280)
                Divider()
                preview.frame(maxWidth: .infinity)
            }
        }
        .frame(width: 1120, height: 680)
        .onAppear { gh.showRecommended() }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("从 GitHub 添加技能", systemImage: "square.and.arrow.down.on.square").font(.title3.bold())
                Spacer()
                if gh.loading { ProgressView().controlSize(.small) }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                TextField("搜索技能，例如 pdf、excel、design、marketing", text: $gh.query).onSubmit { gh.search() }
                Button("搜索") { gh.search() }
                Button("推荐") { gh.showRecommended() }
                Button {
                    let q = gh.query.trimmingCharacters(in: .whitespaces)
                    let url = q.isEmpty ? "https://github.com/topics/agent-skills"
                        : "https://github.com/search?type=repositories&q=" + ((q + " topic:agent-skills").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)
                    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                } label: { Label("在浏览器里搜索 GitHub", systemImage: "safari") }
            }
            HStack {
                TextField("或者粘贴 GitHub 链接（仓库或技能文件夹）", text: $gh.link).onSubmit { gh.openLink() }
                Button("打开") { gh.openLink() }.disabled(gh.link.isEmpty)
            }
            if let e = gh.error { Text(e).font(.caption).foregroundStyle(.orange) }
        }
        .padding(16)
    }

    var repoList: some View {
        List(selection: Binding(get: { gh.selectedRepo }, set: { if let r = $0 { gh.openRepo(r) } })) {
            Section("仓库") {
                ForEach(gh.repos) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(r.fullName).bold().lineLimit(1)
                            Spacer()
                            if r.stars > 0 { Label("\(r.stars)", systemImage: "star").font(.caption2).foregroundStyle(.secondary) }
                        }
                        if !r.description.isEmpty {
                            Text(r.description.locKey).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .tag(r.fullName)
                }
            }
        }
    }

    var skillList: some View {
        List(selection: Binding(get: { gh.selectedSkill?.id }, set: { id in gh.selectedSkill = gh.skills.first { $0.id == id } })) {
            Section {
                if gh.selectedRepo == nil { Text("先在左边选一个仓库").foregroundStyle(.secondary) }
                ForEach(gh.skills) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(s.name).bold().lineLimit(1)
                            if gh.imported.contains(s.id) || store.skills.contains(where: { $0.source == s.repo && $0.sourcePath == s.folder }) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                        Text(s.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .tag(s.id)
                }
            } header: {
                if gh.selectedRepo == nil { Text("技能") } else { Text("技能（\(gh.skills.count)）") }
            }
        }
    }

    @ViewBuilder var preview: some View {
        if let s = gh.selectedSkill {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.name).font(.title2.bold())
                            Text(s.description).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 10) {
                                Label(s.repo, systemImage: "person.crop.circle").font(.caption)
                                if let l = s.license, !l.isEmpty { Label(l, systemImage: "doc.text").font(.caption).lineLimit(1) }
                            }
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            Button {
                                gh.importing = true
                                Task {
                                    let err = await store.importSkill(s)
                                    gh.importing = false
                                    if let err { gh.error = err } else { gh.imported.insert(s.id) }
                                }
                            } label: {
                                Label(gh.imported.contains(s.id) ? "已添加" : "添加这个技能", systemImage: "plus.circle.fill")
                            }
                            .buttonStyle(.borderedProminent).tint(Color.toolula)
                            .disabled(gh.importing)
                            if gh.importing { ProgressView().controlSize(.small) }
                            Link(destination: URL(string: "https://github.com/\(s.repo)/tree/\(s.branch)/\(s.folder)")!) {
                                Label("在 GitHub 上查看", systemImage: "arrow.up.right.square")
                            }
                            .font(.caption)
                        }
                    }

                    let risks = gh.risks(s)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            if risks.isEmpty {
                                Label("没有发现明显的风险", systemImage: "checkmark.shield").foregroundStyle(.green)
                            }
                            ForEach(risks) { r in
                                Label { Text(r.text) + Text("  · \(r.file)").foregroundColor(.secondary) } icon: {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                }
                                .font(.callout)
                            }
                            Text("这是别人写的技能，添加前请看一下下面的步骤。AI 执行任何命令、写文件、在网页上操作前都会先问你。")
                                .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: { Label("安全检查", systemImage: "shield.lefthalf.filled") }

                    if !s.files.isEmpty {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(s.files.prefix(40), id: \.path) { f in
                                    HStack {
                                        Image(systemName: GitHub.scriptExtensions.contains((f.path as NSString).pathExtension.lowercased()) ? "terminal" : "doc")
                                            .foregroundStyle(.secondary)
                                        Text(f.path).font(.system(.caption, design: .monospaced))
                                        Spacer()
                                        Text(SystemInfo.size(Int64(f.size))).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                                if s.files.count > 40 { Text("… \(s.files.count - 40)").font(.caption).foregroundStyle(.secondary) }
                            }
                        } label: { Label("附带的文件（\(s.files.count)）", systemImage: "folder") }
                    }

                    GroupBox {
                        Text(s.body).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: { Label("技能内容（SKILL.md）", systemImage: "doc.richtext") }
                }
                .padding(16)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "sparkles.rectangle.stack").font(.system(size: 40)).foregroundStyle(Color.toolula)
                Text("选一个技能查看内容，确认没问题再添加").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 给自测用的安全检查 (和预览里同样的规则)
enum GitBrowserRisk {
    static func scan(_ s: GHSkill) -> [String] {
        var out = GitHub.scan(text: s.body, file: "SKILL.md").map(\.text)
        let scripts = s.files.filter { GitHub.scriptExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }
        if !scripts.isEmpty { out.append("scripts: \(scripts.count)") }
        return out
    }
}
