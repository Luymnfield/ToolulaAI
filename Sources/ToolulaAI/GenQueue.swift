import AppKit
import SwiftUI

/// 绘图 / 视频的任务队列: 生成中再点「生成」就排到后面, 一个接一个做 (共用 ComfyUI, 同时只跑一个)。
/// 也能一次加入多个提示词 (每行一个)。
@MainActor
final class GenQueue: ObservableObject {
    static let shared = GenQueue()

    enum Kind: String { case image, video }
    enum State: Equatable { case waiting, running, done, failed(String), cancelled }

    struct Job: Identifiable, Equatable {
        let id = UUID()
        let kind: Kind
        let prompt: String
        let model: String
        let modelName: String
        var imageAspect: ImageAspect = .square
        var imageQuality: ImageQuality = .standard
        var count = 1
        var seed: Int?
        var firstFrame: URL?
        var seconds: Double = 5
        var videoQuality: VideoQuality = .p480
        var videoAspect: VideoAspect = .wide
        var state: State = .waiting
        let created = Date()
        var started: Date?
        var finished: Date?
        var results: [UUID] = []        // 生成好的 ImageItem / VideoItem

        var isFinished: Bool { if case .waiting = state { return false }; if case .running = state { return false }; return true }
    }

    @Published private(set) var jobs: [Job] = []
    private var worker: Task<Void, Never>?

    var waiting: [Job] { jobs.filter { $0.state == .waiting } }
    var running: Job? { jobs.first { $0.state == .running } }
    func waiting(_ k: Kind) -> Int { jobs.filter { $0.kind == k && $0.state == .waiting }.count }
    var busy: Bool { running != nil || ImageStore.shared.running || VideoStore.shared.running }

    /// 用绘图页现在的设置加一个 (或多个, 每个提示词一个) 任务
    func addImages(_ prompts: [String]) {
        let st = ImageStore.shared, spec = ImageModels.shared.selected
        for p in prompts.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !p.isEmpty {
            jobs.append(Job(kind: .image, prompt: p, model: spec.id, modelName: spec.name, imageAspect: st.aspect, imageQuality: st.quality,
                            count: st.count, seed: st.randomSeed ? nil : st.seed))
        }
        pump()
    }

    func addVideos(_ prompts: [String]) {
        let st = VideoStore.shared, spec = VideoModels.shared.selected
        for p in prompts.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !p.isEmpty {
            jobs.append(Job(kind: .video, prompt: p, model: spec.id, modelName: spec.name, firstFrame: st.firstFrame,
                            seconds: st.seconds, videoQuality: st.quality, videoAspect: st.aspect))
        }
        pump()
    }

    /// 等待中的直接移出队列; 正在做的让 ComfyUI 停下
    func cancel(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[i].state {
        case .waiting: jobs[i].state = .cancelled; jobs[i].finished = Date()
        case .running: jobs[i].kind == .image ? ImageStore.shared.cancel() : VideoStore.shared.cancel()
        default: break
        }
    }

    func cancelAllWaiting() { for j in waiting { cancel(j.id) } }

    /// 等待中的往前挪一位
    func moveUp(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state == .waiting,
              let j = jobs[..<i].lastIndex(where: { $0.state == .waiting }) else { return }
        jobs.swapAt(i, j)
    }

    func clearFinished() { jobs.removeAll { $0.isFinished } }

    private func pump() {
        guard worker == nil else { return }
        worker = Task {
            while let i = jobs.firstIndex(where: { $0.state == .waiting }) {
                // 用户直接在页面上点了生成 (不经过队列) 或 AI 工具在生成: 等它做完
                while ImageStore.shared.running || VideoStore.shared.running { try? await Task.sleep(for: .seconds(1)) }
                guard i < jobs.count, jobs[i].state == .waiting else { continue }
                jobs[i].state = .running; jobs[i].started = Date()
                let job = jobs[i]
                var ok = false, err = ""
                switch job.kind {
                case .image:
                    let st = ImageStore.shared
                    let made = await st.generate(prompt: job.prompt, aspect: job.imageAspect, quality: job.imageQuality, count: job.count,
                                                 model: job.model, seed: job.seed)
                    ok = !made.isEmpty; err = st.error ?? ""
                    if let k = jobs.firstIndex(where: { $0.id == job.id }) { jobs[k].results = made.map(\.id) }
                case .video:
                    let st = VideoStore.shared
                    let item = await st.generate(prompt: job.prompt, image: job.firstFrame, seconds: job.seconds, quality: job.videoQuality,
                                                 aspect: job.videoAspect, model: job.model)
                    ok = item != nil; err = st.error ?? ""
                    if let k = jobs.firstIndex(where: { $0.id == job.id }), let item { jobs[k].results = [item.id] }
                }
                if let k = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[k].finished = Date()
                    jobs[k].state = ok ? .done : (err.contains("取消") || err.contains("中断") || err.isEmpty ? .cancelled : .failed(err))
                }
                // 队列全部做完: 一条汇总通知 (单个任务的通知由生成本身发)
                if waiting.isEmpty, jobs.filter({ $0.finished != nil && $0.finished! > Date().addingTimeInterval(-3600) }).count > 1 {
                    let done = jobs.filter { $0.state == .done }.count
                    Notifier.send(title: String(localized: "队列里的任务都做完了"), body: String(localized: "完成 \(done) 个"), link: "toolula://tasks")
                }
            }
            worker = nil
        }
    }
}

// MARK: - 任务中心: 所有后台任务集中在一处查看和取消

/// 工具栏上的按钮: 有任务在跑时显示数量
struct TaskCenterButton: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var chat: ChatStore
    @EnvironmentObject var store: Store
    @EnvironmentObject var automations: AutomationStore
    @ObservedObject var queue = GenQueue.shared
    @ObservedObject var images = ImageStore.shared
    @ObservedObject var videos = VideoStore.shared
    @ObservedObject var imageModels = ImageModels.shared
    @ObservedObject var videoModels = VideoModels.shared

    var count: Int {
        chat.running.count + queue.waiting.count + (images.running || videos.running ? 1 : 0)
            + (store.working ? 1 : 0) + (automations.runningTask != nil ? 1 : 0)
            + imageModels.downloading.count + videoModels.downloading.count
    }

    var body: some View {
        Button { app.showTasks.toggle() } label: {
            Label {
                Text("任务")
            } icon: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: count > 0 ? "clock.arrow.2.circlepath" : "checklist")
                    if count > 0 {
                        Text("\(count)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 3).background(Capsule().fill(Color.toolula)).offset(x: 8, y: -6)
                    }
                }
            }
        }
        .help(Text("任务中心：正在进行和排队中的任务"))
        .accessibilityLabel(Text(count > 0 ? "任务中心，\(count) 个任务进行中" : "任务中心"))
        .popover(isPresented: $app.showTasks, arrowEdge: .bottom) { TaskCenterView().frame(width: 420) }
    }
}

struct TaskCenterView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var chat: ChatStore
    @EnvironmentObject var store: Store
    @EnvironmentObject var automations: AutomationStore
    @ObservedObject var queue = GenQueue.shared
    @ObservedObject var images = ImageStore.shared
    @ObservedObject var videos = VideoStore.shared
    @ObservedObject var imageModels = ImageModels.shared
    @ObservedObject var videoModels = VideoModels.shared

    var empty: Bool {
        chat.running.isEmpty && queue.jobs.isEmpty && !images.running && !videos.running && !store.working
            && automations.runningTask == nil && imageModels.downloading.isEmpty && videoModels.downloading.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("任务中心").font(.headline)
                Spacer()
                if queue.jobs.contains(where: \.isFinished) { Button("清除已完成") { queue.clearFinished() }.controlSize(.small) }
            }
            .padding(12)
            Divider()
            if empty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.title).foregroundStyle(.secondary)
                    Text("没有正在进行的任务").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(30)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        generationSection
                        chatSection
                        otherSection
                    }
                    .padding(12)
                }
                .frame(maxHeight: 460)
            }
        }
    }

    // 绘图 / 视频: 正在做的 (含不经过队列直接点的) + 排队 + 最近完成
    @ViewBuilder var generationSection: some View {
        let direct = (images.running || videos.running) && queue.running == nil
        if direct || !queue.jobs.isEmpty {
            Text("绘图和视频").font(.caption).foregroundStyle(.secondary)
            if direct {
                if images.running { progressRow(icon: "paintbrush.pointed", title: images.prompt, step: images.step, steps: images.steps, stage: images.stage) { images.cancel() } open: { app.section = .image } }
                if videos.running { progressRow(icon: "film", title: videos.prompt, step: videos.step, steps: videos.steps, stage: videos.stage) { videos.cancel() } open: { app.section = .video } }
            }
            ForEach(queue.jobs) { j in jobRow(j) }
        }
    }

    @ViewBuilder func jobRow(_ j: GenQueue.Job) -> some View {
        let icon = j.kind == .image ? "paintbrush.pointed" : "film"
        let open = {
            app.section = j.kind == .image ? .image : .video
            if let r = j.results.first { if j.kind == .image { images.selected = r } else { videos.selected = r } }
            app.showTasks = false
        }
        switch j.state {
        case .running:
            let st = j.kind == .image ? (images.step, images.steps, images.stage) : (videos.step, videos.steps, videos.stage)
            progressRow(icon: icon, title: j.prompt, step: st.0, steps: st.1, stage: st.2) { queue.cancel(j.id) } open: { open() }
        case .waiting:
            row(icon: icon, title: j.prompt, detail: String(localized: "排队中 · \(j.modelName)")) {
                Button { queue.moveUp(j.id) } label: { Image(systemName: "arrow.up") }.help(Text("往前排")).accessibilityLabel(Text("往前排"))
                Button { queue.cancel(j.id) } label: { Image(systemName: "xmark") }.help(Text("移出队列")).accessibilityLabel(Text("移出队列"))
            }
        case .done:
            row(icon: icon, title: j.prompt, detail: String(localized: "完成 · \(elapsed(j))"), tint: .green) {
                Button("查看") { open() }
            }
        case .failed(let e):
            row(icon: icon, title: j.prompt, detail: e, tint: .orange) { EmptyView() }
        case .cancelled:
            row(icon: icon, title: j.prompt, detail: String(localized: "已取消"), tint: .secondary) { EmptyView() }
        }
    }

    @ViewBuilder var chatSection: some View {
        let running = chat.conversations.filter { chat.running.contains($0.id) }
        if !running.isEmpty {
            Text("对话").font(.caption).foregroundStyle(.secondary)
            ForEach(running) { c in
                row(icon: "bubble.left", title: c.title.isEmpty ? String(localized: "新对话") : c.title,
                    detail: chat.live.status[c.id] ?? String(localized: "正在回答…"), spinning: true) {
                    Button("打开") { app.section = .chat; chat.selected = c.id; app.showTasks = false }
                    Button { chat.stop(c.id) } label: { Image(systemName: "stop.fill") }.help(Text("停止")).accessibilityLabel(Text("停止"))
                }
            }
        }
    }

    @ViewBuilder var otherSection: some View {
        let downloads = imageModels.downloading.map { ($0.key, $0.value) } + videoModels.downloading.map { ($0.key, $0.value) }
        if store.working || automations.runningTask != nil || !downloads.isEmpty {
            Text("其他").font(.caption).foregroundStyle(.secondary)
            if store.working {
                row(icon: "wand.and.stars", title: String(localized: "AI 修图"), detail: store.status, spinning: true) {
                    Button("打开") { app.section = .photo; app.showTasks = false }
                }
            }
            if let tid = automations.runningTask {
                let t = automations.tasks.first { $0.id == tid }?.name ?? String(localized: "自动化任务")
                row(icon: "clock.arrow.circlepath", title: t, detail: String(localized: "自动化任务运行中"), spinning: true) {
                    Button("打开") { app.section = .automation; app.showTasks = false }
                }
            }
            ForEach(downloads, id: \.0) { name, job in
                row(icon: "arrow.down.circle", title: String(localized: "下载模型：\(name)"), detail: job.total > 0 ? "\(job.state) · \(Int(Double(job.received) / Double(job.total) * 100))%" : job.state, spinning: true) {
                    Button("打开") { app.section = .models; app.showTasks = false }
                }
            }
        }
    }

    func elapsed(_ j: GenQueue.Job) -> String {
        guard let s = j.started, let f = j.finished else { return "" }
        let t = Int(f.timeIntervalSince(s))
        return t >= 60 ? String(localized: "\(t / 60) 分 \(t % 60) 秒") : String(localized: "\(t) 秒")
    }

    func progressRow(icon: String, title: String, step: Int, steps: Int, stage: String, cancel: @escaping () -> Void, open: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            row(icon: icon, title: title, detail: stage.isEmpty ? String(localized: "生成中…") : stage, spinning: steps == 0) {
                Button("查看") { open() }
                Button { cancel() } label: { Image(systemName: "stop.fill") }.help(Text("停止")).accessibilityLabel(Text("停止"))
            }
            if steps > 0 { ProgressView(value: Double(step), total: Double(steps)).padding(.leading, 26) }
        }
    }

    func row<B: View>(icon: String, title: String, detail: String, tint: Color = .primary, spinning: Bool = false, @ViewBuilder buttons: () -> B) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint == .primary ? Color.secondary : tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1).truncationMode(.tail)
                HStack(spacing: 4) {
                    if spinning { ProgressView().controlSize(.mini) }
                    Text(detail).font(.caption).foregroundStyle(tint == .primary ? Color.secondary : tint).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            buttons().buttonStyle(.borderless).controlSize(.small)
        }
    }
}

/// 绘图 / 视频页上的「批量…」: 每行一个提示词, 一起加入队列
struct BatchPromptSheet: View {
    let kind: GenQueue.Kind
    @Binding var isPresented: Bool
    @State private var text = ""
    var lines: [String] { text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(kind == .image ? "批量画图" : "批量生成视频").font(.headline)
            Text("每行一个提示词，会用现在的模型和设置一个接一个生成。可以先加入，晚上让它慢慢做。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.body).frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button("取消") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("加入 \(lines.count) 个任务") {
                    kind == .image ? GenQueue.shared.addImages(lines) : GenQueue.shared.addVideos(lines)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(lines.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}

/// 页面上「生成」按钮下面: 排队情况一行字
struct QueueHint: View {
    let kind: GenQueue.Kind
    @EnvironmentObject var app: AppState
    @ObservedObject var queue = GenQueue.shared
    var body: some View {
        let n = queue.waiting(kind)
        if n > 0 {
            HStack {
                Text("还有 \(n) 个在排队").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("查看") { app.showTasks = true }.controlSize(.small)
            }
        }
    }
}
