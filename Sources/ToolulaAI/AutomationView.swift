import SwiftUI

struct AutomationView: View {
    @EnvironmentObject var auto: AutomationStore

    static let templates: [AutomationTask] = [
        AutomationTask(name: String(localized: "新照片自动修图"), prompt: String(localized: "用 photo_edit 把这些新照片修成「自动优化，让照片自然好看」的效果并导出，最后用一句话汇报。"),
                       model: "qwen/qwen3.8-27b", kind: .folder, allowActions: false),
        AutomationTask(name: String(localized: "每天整理下载文件夹"), prompt: String(localized: "查看 ~/Downloads，按 图片/文档/安装包/压缩包/视频/其他 分类，把文件移动到 ~/Downloads 下对应的子文件夹里（不要删除任何文件），最后汇报移动了哪些。"),
                       model: "qwen3-coder-next-mlx", kind: .daily, hour: 18, minute: 0, allowActions: true),
        AutomationTask(name: String(localized: "硬盘空间提醒"), prompt: String(localized: "用 df -h / 查看系统盘剩余空间。如果剩余少于 100GB，用 notify_user 提醒我，并列出 ~ 下最大的 5 个文件夹（du -sh ~/* 2>/dev/null | sort -rh | head -5）。"),
                       model: "qwen3-coder-next-mlx", kind: .daily, hour: 10, minute: 0, allowActions: true),
    ]

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Menu {
                    Button("空白任务") { auto.add() }
                    Divider()
                    ForEach(Self.templates, id: \.name) { t in Button(String(localized: "模板：\(t.name)")) { auto.add(t) } }
                } label: { Label("新建自动化", systemImage: "plus") }
                    .padding(8)
                List(selection: $auto.selected) {
                    ForEach(auto.tasks) { t in
                        HStack {
                            Image(systemName: t.enabled ? "clock.badge.checkmark" : "clock").foregroundStyle(t.enabled ? .green : .secondary)
                            VStack(alignment: .leading) {
                                Text(t.name).lineLimit(1)
                                Text(t.triggerText).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if auto.runningTask == t.id { ProgressView().controlSize(.mini) }
                        }.tag(t.id)
                    }
                }
                BackgroundToggle()
                Toggle("登录 Mac 时自动打开（让自动化一直运行）", isOn: Binding(get: { auto.launchAtLogin }, set: { auto.setLaunchAtLogin($0) }))
                    .font(.caption).padding(8)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if let id = auto.selected, auto.tasks.contains(where: { $0.id == id }) {
                TaskEditor(taskId: id)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.2.circlepath").font(.system(size: 44)).foregroundStyle(.green)
                    Text("自动化").font(.title.bold())
                    Text("让本地 AI 按时间或在文件夹有新文件时自动干活。\nToolula AI 需要保持打开（可以设成登录时自动打开）。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("新建自动化") { auto.add() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct TaskEditor: View {
    @EnvironmentObject var auto: AutomationStore
    @ObservedObject var models = ModelManager.shared
    let taskId: UUID

    var task: AutomationTask { auto.tasks.first { $0.id == taskId }! }
    func bind<T>(_ kp: WritableKeyPath<AutomationTask, T>) -> Binding<T> {
        Binding(get: { task[keyPath: kp] }, set: { v in auto.update(taskId) { $0[keyPath: kp] = v } })
    }

    var body: some View {
        Form {
            Section {
                TextField("名称", text: bind(\.name))
                Toggle("启用", isOn: bind(\.enabled))
                VStack(alignment: .leading) {
                    Text("让 AI 做什么")
                    TextEditor(text: bind(\.prompt)).frame(minHeight: 90).font(.body)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                }
                Picker("模型", selection: bind(\.model)) {
                    ForEach(models.chatModels) { Text($0.displayName + ($0.vision ? " 👁" : "")).tag($0.id) }
                    if models.model(task.model) == nil { Text(task.model).tag(task.model) }
                }
            }
            Section("什么时候运行") {
                Picker("触发方式", selection: bind(\.kind)) { ForEach(TriggerKind.allCases) { Text($0.label).tag($0) } }
                switch task.kind {
                case .interval:
                    Stepper("每 \(task.intervalMinutes) 分钟", value: bind(\.intervalMinutes), in: 5...1440, step: 5)
                case .daily, .weekly:
                    if task.kind == .weekly {
                        Picker("星期", selection: bind(\.weekday)) {
                            ForEach(1...7, id: \.self) { d in Text(Calendar.current.weekdaySymbols[d - 1]).tag(d) }
                        }
                    }
                    HStack {
                        Text("时间")
                        Picker("小时", selection: bind(\.hour)) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) } }.labelsHidden().frame(width: 70)
                        Text(":")
                        Picker("分钟", selection: bind(\.minute)) { ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text(String(format: "%02d", $0)).tag($0) } }.labelsHidden().frame(width: 70)
                    }
                case .folder:
                    HStack {
                        (task.folder.isEmpty ? Text("还没选文件夹") : Text(task.folder)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("选择文件夹…") {
                            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                            if p.runModal() == .OK, let u = p.url { auto.setFolder(taskId, u.path) }
                        }
                    }
                    Text("只处理选好文件夹之后新放进去的文件，新文件的路径会自动附在任务后面。").font(.caption).foregroundStyle(.secondary)
                case .manual:
                    Text("只在你点「立即运行」时执行。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("权限") {
                Toggle("允许直接执行命令和写文件（没有人确认）", isOn: bind(\.allowActions))
                (task.allowActions
                     ? Text("⚠️ AI 会在无人确认的情况下执行命令。只给你信任的任务打开，并在任务里写清楚不要删除文件。")
                     : Text("关闭时 AI 只能查看文件夹、读文件、修图和发通知，不能执行命令或改文件。"))
                    .font(.caption).foregroundStyle(task.allowActions ? .orange : .secondary)
                Toggle("完成后发通知", isOn: bind(\.notify))
            }
            Section {
                HStack {
                    Button { auto.run(taskId) } label: { Label("立即运行", systemImage: "play.fill") }
                        .disabled(auto.runningTask != nil || task.prompt.isEmpty)
                    if auto.runningTask == taskId { ProgressView().controlSize(.small); Text("运行中…") }
                    Spacer()
                    if let d = task.lastRun { Text("上次运行：") + Text(d, style: .relative) }
                    Button("删除任务", role: .destructive) { auto.delete(taskId) }
                }
            }
            Section("运行记录") {
                let runs = auto.runs.filter { $0.taskId == taskId }.prefix(20)
                if runs.isEmpty { Text("还没有运行过").foregroundStyle(.secondary) }
                ForEach(Array(runs)) { r in RunRow(run: r) }
            }
        }
        .formStyle(.grouped)
    }
}

struct RunRow: View {
    let run: AutomationRun
    @State private var open = false
    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 6) {
                MarkdownText(text: run.output)
                if !run.log.isEmpty {
                    Text(run.log).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        } label: {
            HStack {
                Image(systemName: run.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(run.ok ? .green : .red)
                Text(run.date, format: .dateTime.month().day().hour().minute())
                Text(run.output.replacingOccurrences(of: "\n", with: " ")).lineLimit(1).foregroundStyle(.secondary)
            }
        }
    }
}

