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
    /// 只允许改动这些文件夹里的东西 (空 = 不限); 超出范围的操作发通知请用户确认
    var allowedFolders: [String]?
    /// 上次运行留下的笔记 (处理过哪些、下次从哪开始), 每次运行带上
    var notes: String?
    /// 下一次是试运行: 只查看、列出打算做什么, 不改动; 用户确认后才正式执行
    var trial: Bool?
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
    var trial: Bool?
    var attempts: Int?
}

/// 自动化运行中需要用户确认的操作 (超出允许的文件夹)
struct AutomationApproval: Identifiable {
    let id = UUID()
    let taskId: UUID
    let taskName: String
    let summary: String
    let continuation: CheckedContinuation<Bool, Never>
}

@MainActor
final class AutomationStore: ObservableObject {
    @Published var tasks: [AutomationTask] = []
    @Published var runs: [AutomationRun] = []
    @Published var runningTask: UUID?
    @Published var selected: UUID?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    weak var photoStore: Store?
    /// 给工具 (create_automation) 和网址动作用
    static weak var shared: AutomationStore?
    @Published var approval: AutomationApproval?
    private var timer: Timer?
    private let tasksFile: URL
    private let runsFile: URL

    /// folder: 测试时用临时文件夹, 平时用 ~/Toolula/Data
    init(folder: URL? = nil) {
        tasksFile = folder?.appendingPathComponent("automations.json") ?? AppPaths.dataFile("automations.json")
        runsFile = folder?.appendingPathComponent("automation_runs.json") ?? AppPaths.dataFile("automation_runs.json")
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
        Notifier.requestPermission()
        let photo = photoStore
        Task {
            let runId = UUID()
            let trial = t.trial == true
            var r = await AutomationRunner.run(task: t, extra: extra, runId: runId, photoStore: photo, approve: approver(for: t))
            var attempts = 1
            // 没成功: 带上失败原因, 换个做法再试一次
            if !r.ok, !trial, !Task.isCancelled {
                attempts = 2
                let again = extra + "\n\n【上次没成功】\(r.text.prefix(600))\n请换一个做法再试一次；还是做不到就说明卡在哪里、需要用户做什么。"
                let r2 = await AutomationRunner.run(task: t, extra: again, runId: runId, photoStore: photo, approve: approver(for: t))
                r = AgentRunner.Result(text: r2.text, log: r.log + "\n──── " + String(localized: "第二次尝试") + " ────\n" + r2.log, ok: r2.ok, steps: r.steps + r2.steps, stuck: r2.stuck)
            }
            var run = AutomationRun(taskId: t.id, taskName: t.name, output: r.text, log: r.log, ok: r.ok)
            run.id = runId
            run.trial = trial ? true : nil
            run.attempts = attempts > 1 ? attempts : nil
            runs.insert(run, at: 0)
            runningTask = nil
            save()
            let link = "toolula://automation/\(t.id.uuidString)"
            if trial {
                Notifier.send(title: "🧪 " + String(localized: "「\(t.name)」试运行完成，请看一下打算做的事"), body: r.text, link: link)
            } else if t.notify || !r.ok {
                Notifier.send(title: (r.ok ? "✅ " : "⚠️ ") + t.name + (r.ok ? "" : String(localized: "（没有完成）")), body: r.text, link: link)
            }
        }
    }

    /// 试运行没问题: 以后正式执行
    func confirmTrial(_ id: UUID) { update(id) { $0.trial = nil } }

    /// 这个任务的操作要不要批准
    func approver(for t: AutomationTask) -> @MainActor (ToolCall, String) async -> Bool {
        { [weak self] call, summary in
            guard t.trial != true, t.allowActions else { return false }
            let folders = (t.allowedFolders ?? []).filter { !$0.isEmpty }
            if folders.isEmpty || AutomationScope.allowed(call, folders: folders) { return true }
            // 超出允许的文件夹: 发通知请用户确认, 最多等 30 分钟
            guard let self else { return false }
            return await self.ask(t, summary)
        }
    }

    private func ask(_ t: AutomationTask, _ summary: String) async -> Bool {
        Notifier.send(title: "🔐 " + String(localized: "「\(t.name)」需要你确认一个操作"), body: summary, link: "toolula://automation/\(t.id.uuidString)")
        return await withCheckedContinuation { cont in
            let a = AutomationApproval(taskId: t.id, taskName: t.name, summary: summary, continuation: cont)
            approval = a
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1800))
                guard let self, self.approval?.id == a.id else { return }
                self.approval = nil
                cont.resume(returning: false)
            }
        }
    }

    func answer(_ allow: Bool) {
        guard let a = approval else { return }
        approval = nil
        a.continuation.resume(returning: allow)
    }

    // MARK: 在对话里新建 (create_automation 工具)

    /// 按工具参数建一个自动化; 会改动东西的任务先试运行一次
    func create(from a: [String: Any]) -> (AutomationTask?, String) {
        func str(_ k: String) -> String { (a[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let name = str("name"), prompt = str("prompt")
        guard !name.isEmpty, !prompt.isEmpty else { return (nil, "错误：name 和 prompt 都要填") }
        var t = AutomationTask(model: ModelManager.shared.chatModel)
        t.name = name; t.prompt = prompt
        let kinds: [String: TriggerKind] = ["daily": .daily, "weekly": .weekly, "interval": .interval, "folder": .folder, "disk": .diskMounted,
                                            "app": .appLaunched, "wake": .wake, "manual": .manual]
        guard let k = kinds[str("trigger")] else { return (nil, "错误：trigger 只能是 " + kinds.keys.sorted().joined(separator: "/")) }
        t.kind = k
        let parts = str("time").split(separator: ":").compactMap { Int($0) }
        if parts.count == 2 { t.hour = min(23, max(0, parts[0])); t.minute = min(59, max(0, parts[1])) }
        if let w = (a["weekday"] as? Int) ?? Int(str("weekday")), (1...7).contains(w) { t.weekday = w % 7 + 1 }   // 1=周一 … 7=周日
        if let m = (a["interval_minutes"] as? Int) ?? Int(str("interval_minutes")) { t.intervalMinutes = max(5, m) }
        if k == .folder {
            let f = (str("folder") as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: f) else { return (nil, "错误：要监视的文件夹不存在：\(f)") }
            t.folder = f; t.seen = Self.listFiles(f)
        }
        if k == .appLaunched {
            guard !str("app_name").isEmpty else { return (nil, "错误：trigger=app 时要填 app_name") }
            t.appName = str("app_name")
        }
        t.allowActions = (a["allow_actions"] as? Bool) ?? (str("allow_actions") == "true")
        t.allowedFolders = (a["allowed_folders"] as? [String])?.map { ($0 as NSString).expandingTildeInPath }.filter { !$0.isEmpty }
        if t.allowActions { t.trial = true }
        tasks.insert(t, at: 0)
        selected = t.id
        save()
        var msg = "已建好自动化「\(t.name)」：\(t.triggerText)。"
        msg += t.allowActions ? "第一次会先试运行（只查看、不改动），用户在「自动化」页确认后才正式执行。" : "它只能查看信息，不能改动文件。"
        return (t, msg)
    }

    /// 自动化页: 改允许的文件夹
    func setAllowedFolders(_ id: UUID, _ f: [String]) { update(id) { $0.allowedFolders = f.isEmpty ? nil : f } }
}

/// 自动化的权限范围: 写文件/改文件的路径、命令里提到的路径都在允许的文件夹里, 才算在范围内
enum AutomationScope {
    static func allowed(_ original: ToolCall, folders: [String]) -> Bool {
        let call = Tools.normalize(original)
        let home = NSHomeDirectory()
        let roots = folders.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }
        func inside(_ p: String) -> Bool {
            let u = URL(fileURLWithPath: (p as NSString).expandingTildeInPath, relativeTo: URL(fileURLWithPath: home)).standardizedFileURL.path
            return roots.contains { u == $0 || u.hasPrefix($0 + "/") }
        }
        switch call.name {
        case "write_file", "edit_file":
            return inside(call.args["path"] as? String ?? "")
        case "run_shell":
            let cmd = call.args["command"] as? String ?? ""
            if Tools.permanentDelete(cmd) || cmd.range(of: #"\bsudo\b"#, options: .regularExpression) != nil { return false }
            // 命令里出现的路径都要在范围内; 一个路径都没写 (在主目录里乱动) 不算
            let paths = cmd.split(whereSeparator: { " \t\n;|&><()=".contains($0) })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                .filter { $0.hasPrefix("/") || $0.hasPrefix("~") }
                .filter { !["/dev/null", "/usr/bin/python3", "/bin/zsh", "/bin/bash", "/bin/sh"].contains($0) && !$0.hasPrefix("/usr/") && !$0.hasPrefix("/bin/") && !$0.hasPrefix("/opt/homebrew/") }
            return !paths.isEmpty && paths.allSatisfy(inside)
        default:
            return false
        }
    }
}

/// 无人值守地跑一次任务
enum AutomationRunner {
    @MainActor
    static func run(task: AutomationTask, extra: String, runId: UUID, photoStore: Store?,
                    approve: @escaping @MainActor (ToolCall, String) async -> Bool) async -> AgentRunner.Result {
        let info = ModelManager.shared.model(task.model)
        let tools = (info?.toolUse ?? true) ? Tools.definitions(photo: photoStore != nil, automation: true, delegate: true) : nil
        let trial = task.trial == true
        var policy = "\n请用\(Lang.aiLanguage)写结果。"
        if trial {
            policy += "\n这是一次【试运行】：只查看、不改动任何东西（改动类操作都会被拒绝）。请查清楚情况，然后列出正式运行时打算做的每一步操作（具体到文件和命令），让用户确认。"
        } else if task.allowActions {
            let folders = (task.allowedFolders ?? []).filter { !$0.isEmpty }
            policy += "\n这是一个无人值守的自动化任务，没有人在旁边确认；只做任务需要的操作，删除文件用 trash（移到废纸篓），不要做破坏性操作。"
            if !folders.isEmpty {
                policy += "\n你只能改动这些文件夹里的东西：\(folders.joined(separator: "、"))；命令里要写出完整路径。超出范围的操作会发通知等用户确认，尽量避免。"
            }
        } else {
            policy += "\n这是一个无人值守的自动化任务。你只能查看信息（列目录、读文件），不能执行命令或改文件；需要这些操作时请在结果里说明。"
        }
        if let n = task.notes, !n.isEmpty { policy += "\n\n【上次运行留下的笔记】\n" + n }
        policy += "\n需要下次接着用的进度（处理过哪些、做到哪），用 save_notes 记下来。"
        let system = Agent.systemPrompt(workDir: NSHomeDirectory(), tools: tools != nil, extra: policy)
        var ctx = ToolContext(workDir: URL(fileURLWithPath: NSHomeDirectory()), approve: approve, photoStore: photoStore)
        ctx.beforeChange = { call in await UndoStore.shared.prepare(turn: runId, conversation: task.id, workDir: URL(fileURLWithPath: NSHomeDirectory()), call: call) }
        ctx.saveNotes = { text in AutomationStore.shared?.update(task.id) { $0.notes = String(text.prefix(4000)) } }
        // 子助手: 同样的权限, 不能再分派
        let subSystem = Agent.systemPrompt(workDir: NSHomeDirectory(), tools: true, extra: policy + "\n你是子助手，只负责下面这一个子任务，做完简短汇报结论。")
        var subCtx = ctx
        subCtx.saveNotes = nil
        ctx.delegate = { sub in
            let r = await AgentRunner.run(prompt: sub, model: task.model, system: subSystem, tools: Tools.definitions(photo: photoStore != nil), ctx: subCtx, maxSteps: 25)
            return (r.ok ? "" : "（子助手没能完成）") + String(r.text.prefix(6000))
        }
        return await AgentRunner.run(prompt: task.prompt + extra, model: task.model, system: system, tools: tools, ctx: ctx,
                                     verify: task.allowActions && !trial)
    }
}

/// 不显示在对话里的一次完整任务 (自动化、子助手、核查共用): 发一条消息, 调用工具直到模型给出结论
enum AgentRunner {
    struct Result { var text: String; var log: String; var ok: Bool; var steps: Int; var stuck = false }

    @MainActor
    static func run(prompt: String, model: String, system: String, tools: [[String: Any]]?, ctx: ToolContext,
                    maxSteps: Int = ChatStore.maxSteps, verify: Bool = false) async -> Result {
        var messages = [ChatMessage(role: "user", text: prompt)]
        var log = ""
        var steps = 0
        let info = ModelManager.shared.model(model)
        var guardrail = AgentGuard()
        var verified = false
        var budget = maxSteps, round = 0
        while round < budget {
            round += 1
            if Task.isCancelled { return Result(text: String(localized: "已停止。"), log: log, ok: false, steps: steps) }
            let msgs = Agent.apiMessages(system: system, messages: messages, vision: info?.vision ?? false)
            do {
                let r = try await LLMClient.stream(model: model, messages: msgs, tools: tools, reasoning: "none") { _, _ in }
                var m = ChatMessage(role: "assistant", text: r.content)
                m.toolCalls = r.toolCalls
                messages.append(m)
                if let p = r.toolCalls.last(where: { $0.name == "plan" }) {
                    budget = max(budget, min(150, 10 + PlanState.steps(p.args).count * 10))
                }
                if r.toolCalls.isEmpty {
                    let turn = Array(messages.suffix(from: messages.lastIndex { $0.role == "user" && $0.hidden != true } ?? 0))
                    if let nudge = guardrail.finishNudge(turn) ?? (tools != nil ? guardrail.calcNudge(turn) : nil) {
                        var n = ChatMessage(role: "user", text: nudge); n.hidden = true
                        messages.append(n)
                        continue
                    }
                    if verify, !verified, AgentVerifier.enabled, AgentVerifier.changedFiles(turn) {
                        verified = true
                        log += "▶ " + String(localized: "核查结果") + "\n"
                        if let problem = await AgentVerifier.check(turn: turn, model: model, workDir: ctx.workDir.path) {
                            log += String(localized: "核查发现：") + problem + "\n\n"
                            var n = ChatMessage(role: "user", text: "（核查发现问题）\(problem)\n请先修好，修好后核对一遍再汇报。")
                            n.hidden = true
                            messages.append(n)
                            continue
                        }
                    }
                    return Result(text: r.content, log: log, ok: !guardrail.stuck, steps: steps, stuck: guardrail.stuck)
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
        return Result(text: String(localized: "步骤太多，已停止。"), log: log, ok: false, steps: steps, stuck: true)
    }
}
