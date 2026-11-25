import Foundation
import ServiceManagement
import SwiftUI

enum TriggerKind: String, Codable, CaseIterable, Identifiable {
    case interval = "每隔一段时间"
    case daily = "每天"
    case weekly = "每周"
    case folder = "文件夹有新文件时"
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
        case .folder, .manual:
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
    private let tasksFile = AppPaths.support.appendingPathComponent("automations.json")
    private let runsFile = AppPaths.support.appendingPathComponent("automation_runs.json")

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
        var messages = [ChatMessage(role: "user", text: task.prompt + extra)]
        var log = ""
        let info = ModelManager.shared.model(task.model)
        let tools = (info?.toolUse ?? true) ? Tools.definitions(photo: photoStore != nil) : nil
        let policy = "\n请用\(Lang.aiLanguage)写结果。" + (task.allowActions
            ? "\n这是一个无人值守的自动化任务，用户已授权你直接执行命令和写文件，不会有人确认；只做任务需要的操作，避免任何删除或破坏性操作。"
            : "\n这是一个无人值守的自动化任务。你只能查看信息（列目录、读文件、只读命令会被拒绝执行），不能执行命令或写文件；需要这些操作时请在结果里说明。")
        let system = Agent.systemPrompt(workDir: NSHomeDirectory(), tools: tools != nil, extra: policy)
        let ctx = ToolContext(workDir: URL(fileURLWithPath: NSHomeDirectory()), approve: { _, _ in task.allowActions }, photoStore: photoStore)
        for _ in 0..<25 {
            let msgs = Agent.apiMessages(system: system, messages: messages, vision: info?.vision ?? false)
            do {
                let r = try await LLMClient.stream(model: task.model, messages: msgs, tools: tools, reasoning: "none") { _, _ in }
                var m = ChatMessage(role: "assistant", text: r.content)
                m.toolCalls = r.toolCalls
                messages.append(m)
                if r.toolCalls.isEmpty { return (r.content, log, true) }
                for call in r.toolCalls {
                    log += "▶ \(call.name) \(call.arguments)\n"
                    let out = await Tools.run(call, ctx: ctx)
                    log += String(out.prefix(800)) + "\n\n"
                    messages.append(ChatMessage(role: "tool", text: out, toolCallId: call.id, toolName: call.name))
                }
            } catch {
                return (String(localized: "出错：\((error as? LLMError)?.errorDescription ?? error.localizedDescription)"), log, false)
            }
        }
        return (String(localized: "步骤太多，已停止。"), log, false)
    }
}
