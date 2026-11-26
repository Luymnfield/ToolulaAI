import AppKit
import Foundation
import ServiceManagement
import SwiftUI

enum TriggerKind: String, Codable, CaseIterable, Identifiable {
    case interval = "每隔一段时间"
    case daily = "每天"
    case weekly = "每周"
    case folder = "文件夹有新文件时"
    case diskMounted = "插入 U 盘或移动硬盘时"
    case appLaunched = "打开某个程序时"
    case wake = "电脑从睡眠中唤醒时"
    case manual = "只手动运行"
    var id: String { rawValue }
    var label: String { rawValue.loc }
}

struct AutomationTask: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = String(localized: "新任务")
    var prompt = ""
    var model: String
    var kind: TriggerKind = .daily
    var intervalMinutes = 60
    var hour = 9
    var minute = 0
    var weekday = 2            // 1=周日 2=周一 … 7=周六
    var folder = ""
    /// 打开某个程序时: 程序名或 bundle id 的一部分 (可选: 旧的配置文件里没有这一项也能读)
    var appName: String?
    var allowActions = false   // 允许执行命令/写文件 (无人确认)
    var enabled = true
    var notify = true
    var created = Date()
    var lastRun: Date?
    var seen: [String] = []

    var triggerText: String {
        switch kind {
        case .interval: return String(localized: "每 \(intervalMinutes) 分钟")
        case .daily: return String(localized: "每天 \(String(format: "%02d:%02d", hour, minute))")
        case .weekly:
            let day = Calendar.current.weekdaySymbols[(weekday - 1) % 7]
            return String(localized: "每周 \(day) \(String(format: "%02d:%02d", hour, minute))")
        case .folder:
            let name = folder.isEmpty ? String(localized: "（未选文件夹）") : (folder as NSString).lastPathComponent
            return String(localized: "监视 \(name)")
        case .diskMounted: return String(localized: "插入磁盘时")
        case .appLaunched: return String(localized: "打开 \((appName ?? "").isEmpty ? "?" : appName ?? "") 时")
        case .wake: return String(localized: "唤醒时")
        case .manual: return String(localized: "手动")
        }
    }

    /// 定时类任务: 是否到点
    func isDue(_ now: Date) -> Bool {
        guard enabled else { return false }
        let cal = Calendar.current
        switch kind {
        case .interval:
            return now.timeIntervalSince(lastRun ?? created) >= Double(max(1, intervalMinutes)) * 60
        case .daily, .weekly:
            guard var target = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return false }
            if kind == .weekly {
                let wd = cal.component(.weekday, from: now)
                if wd != weekday { return false }
                target = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? target
            }
            return now >= target && (lastRun ?? created) < target
        case .folder, .manual, .diskMounted, .appLaunched, .wake:
            return false
        }
    }
}

struct AutomationRun: Codable, Identifiable, Hashable {
    var id = UUID()
    var taskId: UUID
    var taskName: String
    var date = Date()
    var output = ""
    var log = ""
    var ok = true
}

@MainActor
final class AutomationStore: ObservableObject {
    @Published var tasks: [AutomationTask] = []
    @Published var runs: [AutomationRun] = []
    @Published var runningTask: UUID?
    @Published var selected: UUID?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    weak var photoStore: Store?
    private var timer: Timer?
    private let tasksFile = AppPaths.dataFile("automations.json")
    private let runsFile = AppPaths.dataFile("automation_runs.json")

    init() {
        if let t = SafeJSON.load([AutomationTask].self, from: tasksFile) { tasks = t }
        if let r = SafeJSON.load([AutomationRun].self, from: runsFile) { runs = r }
        selected = tasks.first?.id
    }

    func save() {
        let t = tasks, r = Array(runs.prefix(200))
        let tf = tasksFile, rf = runsFile
        Task.detached {
            SafeJSON.save(t, to: tf)
            SafeJSON.save(r, to: rf)
        }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in self.tick() }
        }
        // 系统事件触发: 插入磁盘、打开程序、电脑唤醒
        let nc = NSWorkspace.shared.notificationCenter
        observers = [
            nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { n in
                let url = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                Task { @MainActor in self.event(.diskMounted, detail: url) }
            },
            nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let info = (app?.localizedName ?? "", app?.bundleIdentifier ?? "")
                Task { @MainActor in self.appLaunched(name: info.0, bundle: info.1) }
            },
            nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in self.event(.wake, detail: nil) }
            },
        ]
    }

    private var observers: [NSObjectProtocol] = []
    /// 正在跑别的任务时, 事件触发的任务先排着
    private var pending: [(UUID, String)] = []

    func event(_ kind: TriggerKind, detail: URL?) {
        for t in tasks where t.enabled && t.kind == kind {
            switch kind {
            case .diskMounted:
                guard let u = detail else { continue }
                // 系统自己挂载的 (例如安装器的临时卷) 不算
                if u.path.hasPrefix("/System") || u.path == "/" { continue }
                fire(t.id, extra: "\n\n【触发原因】刚插入了磁盘「\(u.lastPathComponent)」，路径：\(u.path)")
            case .wake:
                fire(t.id, extra: "\n\n【触发原因】电脑刚从睡眠中唤醒。")
            default: break
            }
        }
    }

    func appLaunched(name: String, bundle: String) {
        for t in tasks where t.enabled && t.kind == .appLaunched {
            let key = (t.appName ?? "").trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, name.localizedCaseInsensitiveContains(key) || bundle.localizedCaseInsensitiveContains(key) else { continue }
            fire(t.id, extra: "\n\n【触发原因】用户刚打开了「\(name)」。")
        }
    }

    /// 事件触发: 空闲就马上跑, 否则排队 (同一个任务不重复排)
    func fire(_ id: UUID, extra: String) {
        if runningTask == nil { run(id, extra: extra); return }
        if !pending.contains(where: { $0.0 == id }) { pending.append((id, extra)) }
    }

    func add(_ template: AutomationTask? = nil) {
        var t = template ?? AutomationTask(model: ModelManager.shared.chatModel)
        t.id = UUID()
        t.created = Date()
        tasks.insert(t, at: 0)
        selected = t.id
        save()
    }

    func delete(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        if selected == id { selected = tasks.first?.id }
        save()
    }

    func update(_ id: UUID, _ f: (inout AutomationTask) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        f(&tasks[i])
        save()
    }

    /// 选文件夹后, 现有文件都算"看过", 只有之后新增的才触发
    func setFolder(_ id: UUID, _ path: String) {
        update(id) { t in
            t.folder = path
            t.seen = Self.listFiles(path)
        }
    }

    nonisolated static func listFiles(_ path: String) -> [String] {
        guard !path.isEmpty, let items = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        return items.filter { !$0.hasPrefix(".") }.sorted()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("login item: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: 调度

    private func tick() {
        guard runningTask == nil else { return }
        if !pending.isEmpty {
            let (id, extra) = pending.removeFirst()
            run(id, extra: extra)
            return
        }
        let now = Date()
        for t in tasks where t.enabled {
            if t.kind == .folder, !t.folder.isEmpty {
                let files = Self.listFiles(t.folder)
                let new = files.filter { !t.seen.contains($0) }
                if !new.isEmpty {
                    // 等文件写完 (例如正在从相机导入): 两次检查都在才处理
                    update(t.id) { $0.seen = files }
                    let paths = new.map { (t.folder as NSString).appendingPathComponent($0) }
                    run(t.id, extra: "\n\n【触发原因】文件夹 \(t.folder) 里新增了 \(new.count) 个文件：\n" + paths.joined(separator: "\n"))
                    return
                }
            } else if t.isDue(now) {
                run(t.id)
                return
            }
        }
    }

    func run(_ id: UUID, extra: String = "") {
        guard runningTask == nil, let t = tasks.first(where: { $0.id == id }) else { return }
        runningTask = id
        update(id) { $0.lastRun = Date() }
        if t.notify { Notifier.requestPermission() }
        let photo = photoStore
        Task {
            let (output, log, ok) = await AutomationRunner.run(task: t, extra: extra, photoStore: photo)
            runs.insert(AutomationRun(taskId: t.id, taskName: t.name, output: output, log: log, ok: ok), at: 0)
            runningTask = nil
            save()
            if t.notify { Notifier.send(title: "✅ \(t.name)" + (ok ? "" : String(localized: "（出错）")), body: output) }
        }
    }
}

/// 无人值守地跑一次任务
enum AutomationRunner {
    @MainActor
    static func run(task: AutomationTask, extra: String, photoStore: Store?) async -> (String, String, Bool) {
        let info = ModelManager.shared.model(task.model)
        let tools = (info?.toolUse ?? true) ? Tools.definitions(photo: photoStore != nil, automation: true) : nil
        let policy = "\n请用\(Lang.aiLanguage)写结果。" + (task.allowActions
            ? "\n这是一个无人值守的自动化任务，用户已授权你直接执行命令和写文件，不会有人确认；只做任务需要的操作，避免任何删除或破坏性操作。"
            : "\n这是一个无人值守的自动化任务。你只能查看信息（列目录、读文件、只读命令会被拒绝执行），不能执行命令或写文件；需要这些操作时请在结果里说明。")
        let system = Agent.systemPrompt(workDir: NSHomeDirectory(), tools: tools != nil, extra: policy)
        let ctx = ToolContext(workDir: URL(fileURLWithPath: NSHomeDirectory()), approve: { _, _ in task.allowActions }, photoStore: photoStore)
        let r = await AgentRunner.run(prompt: task.prompt + extra, model: task.model, system: system, tools: tools, ctx: ctx)
        return (r.ok ? r.text : r.text, r.log, r.ok)
    }
}

/// 不显示在对话里的一次完整任务 (自动化、子助手共用): 发一条消息, 调用工具直到模型给出结论
enum AgentRunner {
    struct Result { var text: String; var log: String; var ok: Bool; var steps: Int }

    @MainActor
    static func run(prompt: String, model: String, system: String, tools: [[String: Any]]?, ctx: ToolContext,
                    maxSteps: Int = ChatStore.maxSteps) async -> Result {
        var messages = [ChatMessage(role: "user", text: prompt)]
        var log = ""
        var steps = 0
        let info = ModelManager.shared.model(model)
        var guardrail = AgentGuard()
        for _ in 0..<maxSteps {
            if Task.isCancelled { return Result(text: String(localized: "已停止。"), log: log, ok: false, steps: steps) }
            let msgs = Agent.apiMessages(system: system, messages: messages, vision: info?.vision ?? false)
            do {
                let r = try await LLMClient.stream(model: model, messages: msgs, tools: tools, reasoning: "none") { _, _ in }
                var m = ChatMessage(role: "assistant", text: r.content)
                m.toolCalls = r.toolCalls
                messages.append(m)
                if r.toolCalls.isEmpty {
                    let turn = Array(messages.suffix(from: messages.lastIndex { $0.role == "user" && $0.hidden != true } ?? 0))
                    if let nudge = guardrail.finishNudge(turn) {
                        var n = ChatMessage(role: "user", text: nudge); n.hidden = true
                        messages.append(n)
                        continue
                    }
                    return Result(text: r.content, log: log, ok: true, steps: steps)
                }
                for call in r.toolCalls {
                    steps += 1
                    log += "▶ \(call.name) \(call.arguments)\n"
                    ctx.progress?(ToolCallCard.describe(call))
                    var out: String
                    if let blocked = guardrail.before(call) { out = blocked } else { out = await Tools.run(call, ctx: ctx) }
                    out = guardrail.after(call, out)
                    log += String(out.prefix(800)) + "\n\n"
                    messages.append(ChatMessage(role: "tool", text: out, toolCallId: call.id, toolName: call.name))
                }
            } catch {
                return Result(text: String(localized: "出错：\((error as? LLMError)?.errorDescription ?? error.localizedDescription)"), log: log, ok: false, steps: steps)
            }
        }
        return Result(text: String(localized: "步骤太多，已停止。"), log: log, ok: false, steps: steps)
    }
}
