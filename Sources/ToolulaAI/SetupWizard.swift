import SwiftUI

// MARK: - 设置向导: 检测这台 Mac 缺什么, 一键装好

@MainActor
final class SetupWizardState: ObservableObject {
    static let shared = SetupWizardState()
    @Published var show = false

    enum Kind: Hashable {
        case builtinEngine
        case python
        case chatModel(Recommender.Entry)
        case comfy
        case videoModel(String)   // VideoModelSpec.id
        case imageModel(String)   // ImageModelSpec.id
    }

    enum Status: Equatable {
        case waiting, running, done, skipped
        case failed(String)
    }

    struct Item: Identifiable {
        let kind: Kind
        let icon: String
        let title: String
        let detail: String
        let sizeGB: Double
        var on: Bool
        var status: Status = .waiting
        var id: Kind { kind }
    }

    /// 已经满足的项目 (只显示, 不用装)
    struct Ready: Identifiable { let id = UUID(); let icon: String; let text: String }

    @Published var items: [Item] = []
    @Published var ready: [Ready] = []
    @Published var notes: [String] = []
    @Published var running = false
    @Published var finished = false
    @Published var stage = ""
    @Published var bytes: Int64 = 0
    @Published var fraction: Double?   // nil = 不知道总量
    private var runTask: Task<Void, Never>?

    /// 这台电脑有没有能用的对话模型 (本地或云端)
    var chatReady: Bool {
        let m = ModelManager.shared
        return !m.cloudModels.isEmpty || LocalEngine.installed || (BuiltinEngine.installed && !BuiltinEngine.modelFolders.isEmpty)
    }

    /// 第一次打开时自动弹出 (只在什么都没有的时候)
    func showOnLaunchIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "setupShown") else { return }
        if !chatReady || !PythonRuntime.ready { show = true }
    }

    // MARK: 检测

    func detect() {
        guard !running else { return }
        finished = false
        var list: [Item] = []
        var ok: [Ready] = []
        var tips: [String] = []
        let advice = Recommender.advice
        let smallMac = advice == .cloudOnly

        // 1) 对话引擎 + 模型
        let bestChat = Recommender.picks().first { $0.role == .allround }?.best
        if LocalEngine.installed {
            ok.append(Ready(icon: "checkmark.circle.fill", text: String(localized: "已检测到 LM Studio，Toolula 会直接使用它")))
            let hasModel = !ModelManager.shared.localChatModels.filter { !$0.isBuiltin }.isEmpty
                || (bestChat.map { ModelDownloader.isInstalled($0.id) } ?? false)
            if !hasModel, let e = bestChat {
                list.append(Item(kind: .chatModel(e), icon: "eye", title: String(localized: "对话和修图模型：\(Self.name(e))"),
                                 detail: e.note.loc, sizeGB: e.sizeGB, on: !smallMac))
            }
        } else {
            if BuiltinEngine.installed {
                ok.append(Ready(icon: "checkmark.circle.fill", text: String(localized: "Toolula 内置 AI 引擎已安装")))
            } else {
                list.append(Item(kind: .builtinEngine, icon: "cpu", title: String(localized: "内置 AI 引擎（llama.cpp，开源）"),
                                 detail: String(localized: "在本机运行对话和修图模型，不需要另外安装 LM Studio"), sizeGB: 0.02, on: !smallMac))
            }
            if BuiltinEngine.modelFolders.isEmpty, let e = bestChat {
                list.append(Item(kind: .chatModel(e), icon: "eye", title: String(localized: "对话和修图模型：\(Self.name(e))"),
                                 detail: e.note.loc, sizeGB: e.sizeGB, on: !smallMac))
            } else if !BuiltinEngine.modelFolders.isEmpty {
                ok.append(Ready(icon: "checkmark.circle.fill", text: String(localized: "已有本地模型：\(BuiltinEngine.modelFolders.joined(separator: "、"))")))
            }
        }
        if smallMac {
            tips.append(String(localized: "这台电脑内存较小，本地模型会很慢。建议连接云端 API（OpenAI、Claude、Gemini、DeepSeek 等），对话和修图都能用。"))
        }
        if !ModelManager.shared.cloudModels.isEmpty {
            ok.append(Ready(icon: "checkmark.circle.fill", text: String(localized: "已连接云端 API")))
        }

        // 2) Python (修图脚本)
        if PythonRuntime.ready {
            ok.append(Ready(icon: "checkmark.circle.fill", text: String(localized: "修图功能需要的 Python 已就绪")))
        } else {
            list.append(Item(kind: .python, icon: "chevron.left.forwardslash.chevron.right", title: String(localized: "Python 运行环境"),
                             detail: String(localized: "修图和 Lightroom 插件需要；这台 Mac 没有装 Xcode 命令行工具"), sizeGB: 0.06, on: true))
        }

        // 3) 视频
        let vm = VideoModels.shared
        vm.scan()
        if let rec = vm.recommended {
            if ComfyEngine.installed {
                ok.append(Ready(icon: "checkmark.circle.fill", text: String(localized: "图片和视频引擎（ComfyUI）已安装")))
            } else {
                list.append(Item(kind: .comfy, icon: "film", title: String(localized: "图片和视频引擎（ComfyUI，开源）"),
                                 detail: String(localized: "在后台运行，不会打开额外的窗口"), sizeGB: 1.3, on: true))
            }
            let readyVideo = VideoModelSpec.all.filter { vm.isReady($0) }
            if !readyVideo.isEmpty {
                ok.append(Ready(icon: "checkmark.circle.fill", text: String(localized: "视频模型已下载：\(readyVideo.map(\.name).joined(separator: "、"))")))
            } else {
                // 列出这台电脑能跑的所有视频模型, 默认只勾最小的那个 (大模型让用户自己决定)
                let fits = VideoModelSpec.all.filter { [.good, .tight].contains(vm.fit($0)) }
                let smallest = fits.min { vm.missingGB($0) < vm.missingGB($1) }
                for spec in fits.sorted(by: { $0.quality > $1.quality }) {
                    list.append(Item(kind: .videoModel(spec.id), icon: "square.stack.3d.up", title: String(localized: "视频模型：\(spec.name)"),
                                     detail: spec.note.loc, sizeGB: vm.missingGB(spec), on: spec.id == smallest?.id))
                }
            }
        } else {
            tips.append(Recommender.appleSilicon
                ? String(localized: "这台电脑内存不够在本机生成视频（至少需要 32GB）。其他功能都可以正常使用。")
                : String(localized: "Intel 芯片的 Mac 不能在本机生成视频。其他功能都可以正常使用。"))
        }
        // 4) 图片模型 (和视频共用 ComfyUI 引擎; 16GB 的电脑也能跑小模型)
        if Recommender.appleSilicon && ImageModels.shared.fit(.flux2klein) != .tooBig {
            if !ComfyEngine.installed && !list.contains(where: { $0.kind == .comfy }) {
                list.append(Item(kind: .comfy, icon: "film", title: String(localized: "图片和视频引擎（ComfyUI，开源）"),
                                 detail: String(localized: "在后台运行，不会打开额外的窗口"), sizeGB: 1.3, on: true))
            }
            // 图片模型 (和视频共用引擎)
            let im = ImageModels.shared
            im.scan()
            let readyImg = ImageModelSpec.all.filter { im.isReady($0) }
            if !readyImg.isEmpty {
                ok.append(Ready(icon: "checkmark.circle.fill", text: String(localized: "图片模型已下载：\(readyImg.map(\.name).joined(separator: "、"))")))
            } else {
                let fits = ImageModelSpec.all.filter { [.good, .tight].contains(im.fit($0)) }
                let smallest = fits.min { im.missingGB($0) < im.missingGB($1) }
                for spec in fits {
                    list.append(Item(kind: .imageModel(spec.id), icon: "paintbrush.pointed", title: String(localized: "图片模型：\(spec.name)"),
                                     detail: spec.note.loc, sizeGB: im.missingGB(spec), on: spec.id == smallest?.id))
                }
            }
        }

        // 安装顺序: 小的、别的步骤依赖的先装
        func order(_ k: Kind) -> Int {
            switch k {
            case .builtinEngine: return 0
            case .python: return 1
            case .chatModel: return 2
            case .comfy: return 3
            case .videoModel: return 4
            case .imageModel: return 5
            }
        }
        items = list.enumerated().sorted { (order($0.element.kind), $0.offset) < (order($1.element.kind), $1.offset) }.map(\.element)
        ready = ok
        notes = tips
    }

    static func name(_ e: Recommender.Entry) -> String {
        let n = e.id.split(separator: "/").last.map(String.init) ?? e.id
        return e.gguf.map { "\(n.replacingOccurrences(of: "-GGUF", with: "")) \($0)" } ?? n
    }

    var totalGB: Double { items.filter(\.on).reduce(0) { $0 + $1.sizeGB } }

    static var freeGB: Double {
        let v = try? AppPaths.support.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Double(v?.volumeAvailableCapacityForImportantUsage ?? 0) / 1e9
    }

    // MARK: 安装

    func start() {
        guard !running else { return }
        running = true
        runTask = Task { await runAll() }
    }

    func cancel() {
        runTask?.cancel()
        for j in ModelDownloader.shared.jobs where !j.done && !j.failed { ModelDownloader.shared.cancel(j) }
        for s in VideoModelSpec.all { if VideoModels.shared.downloading[s.id]?.done == false { VideoModels.shared.cancel(s) } }
    }

    private func set(_ k: Kind, _ s: Status) {
        if let i = items.firstIndex(where: { $0.kind == k }) { items[i].status = s }
    }

    private func runAll() async {
        defer { running = false; finished = true; runTask = nil }
        var comfyFailed = false
        for item in items {
            if Task.isCancelled { break }
            guard item.on else { set(item.kind, .skipped); continue }
            if item.status == .done { continue }
            if case .imageModel = item.kind, comfyFailed { set(item.kind, .failed(String(localized: "视频引擎没装好，先跳过"))); continue }
            if case .videoModel = item.kind, comfyFailed { set(item.kind, .failed(String(localized: "视频引擎没装好，先跳过"))); continue }
            set(item.kind, .running)
            bytes = 0; fraction = nil; stage = item.title
            do {
                try await install(item)
                set(item.kind, .done)
            } catch {
                if case .comfy = item.kind { comfyFailed = true }
                set(item.kind, .failed(Task.isCancelled ? String(localized: "已取消") : error.localizedDescription))
            }
        }
        // 装好后: 刷新模型列表, 自动选好默认模型
        ModelManager.shared.refresh()
        VideoModels.shared.scan()
        ImageModels.shared.scan()
        await ComfyEngine.shared.check()
        UserDefaults.standard.set(true, forKey: "setupShown")
    }

    private func install(_ item: Item) async throws {
        let progress: @Sendable (Int64) -> Void = { got in Task { @MainActor in SetupWizardState.shared.bytes = got } }
        switch item.kind {
        case .builtinEngine:
            stage = String(localized: "下载内置 AI 引擎…")
            try await BuiltinEngine.install(progress: progress)
        case .python:
            stage = String(localized: "安装 Python…")
            try await PythonRuntime.install(progress: progress)
        case .comfy:
            try await ComfySetup.install(stage: { SetupWizardState.shared.stage = $0 }, progress: progress)
        case .chatModel(let e):
            stage = String(localized: "下载模型 \(Self.name(e))…")
            let dl = ModelDownloader.shared
            dl.download(e.id, quant: e.gguf)
            while let j = dl.jobs.first(where: { $0.id == e.id }), !j.done && !j.failed {
                fraction = j.fraction; bytes = j.received
                if Task.isCancelled { dl.cancel(j) }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard let j = dl.jobs.first(where: { $0.id == e.id }), j.done else {
                throw EngineError(dl.jobs.first(where: { $0.id == e.id })?.state ?? String(localized: "下载失败"))
            }
        case .imageModel(let id):
            guard let spec = ImageModelSpec.all.first(where: { $0.id == id }) else { return }
            stage = String(localized: "下载图片模型 \(spec.name)…")
            let im = ImageModels.shared
            im.scan()
            im.selectedId = spec.id
            im.download(spec)
            while let j = im.downloading[spec.id], !j.done && !j.failed {
                fraction = j.fraction; bytes = j.received
                if Task.isCancelled { im.cancel(spec) }
                try? await Task.sleep(for: .milliseconds(500))
            }
            im.scan()
            guard im.isReady(spec) else { throw EngineError(im.downloading[spec.id]?.state ?? String(localized: "下载失败")) }
        case .videoModel(let id):
            guard let spec = VideoModelSpec.all.first(where: { $0.id == id }) else { return }
            stage = String(localized: "下载视频模型 \(spec.name)…")
            let vm = VideoModels.shared
            vm.scan()
            vm.selectedId = spec.id
            vm.download(spec)
            while let j = vm.downloading[spec.id], !j.done && !j.failed {
                fraction = j.fraction; bytes = j.received
                if Task.isCancelled { vm.cancel(spec) }
                try? await Task.sleep(for: .milliseconds(500))
            }
            vm.scan()
            guard vm.isReady(spec) else { throw EngineError(vm.downloading[spec.id]?.state ?? String(localized: "下载失败")) }
        }
    }
}

// MARK: - 界面

struct SetupWizard: View {
    @ObservedObject var st = SetupWizardState.shared
    @ObservedObject var info = SystemInfo.shared
    @EnvironmentObject var app: AppState
    @AppStorage("modelsTab") private var modelsTab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(st.notes, id: \.self) { n in
                        Label(n, systemImage: "info.circle").font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !st.items.isEmpty {
                        Text(st.finished ? "安装结果" : "需要安装的内容").font(.headline)
                        ForEach($st.items) { $item in row($item) }
                    }
                    if !st.ready.isEmpty {
                        Text("已经就绪").font(.headline).padding(.top, 4)
                        ForEach(st.ready) { r in
                            Label(r.text, systemImage: r.icon).foregroundStyle(.green).font(.callout)
                        }
                    }
                    if st.items.isEmpty && !st.running {
                        Label("这台 Mac 已经全部准备好了。", systemImage: "checkmark.seal.fill").font(.title3).foregroundStyle(Color.toolula)
                    }
                }
                .padding(22)
            }
            Divider()
            footer.padding(16)
        }
        .frame(width: 640, height: 600)
        .onAppear { if !st.running { st.detect() } }
    }

    var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("设置向导").font(.title.bold())
                Text("Toolula 检测了这台 Mac，下面是需要安装的内容。全部由 Toolula 自动下载安装，不需要你另外装软件。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(info.summary.isEmpty ? "" : info.summary).font(.callout.bold())
            }
        }
    }

    @ViewBuilder func row(_ item: Binding<SetupWizardState.Item>) -> some View {
        let it = item.wrappedValue
        HStack(alignment: .top, spacing: 12) {
            if st.running || st.finished {
                statusIcon(it.status).frame(width: 20)
            } else {
                Toggle(it.title, isOn: item.on).labelsHidden().toggleStyle(.checkbox)
            }
            Image(systemName: it.icon).foregroundStyle(Color.toolula).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(it.title).bold()
                    Spacer()
                    Text(Self.size(it.sizeGB)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(it.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if it.status == .running {
                    if let f = st.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
                    Text("\(st.stage)  \(Self.size(Double(st.bytes) / 1e9))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if case .failed(let m) = it.status {
                    Text(m).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .opacity(it.on || st.running || st.finished ? 1 : 0.55)
    }

    @ViewBuilder func statusIcon(_ s: SetupWizardState.Status) -> some View {
        switch s {
        case .waiting: Image(systemName: "circle").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    static func size(_ gb: Double) -> String {
        gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", max(gb * 1000, 1))
    }

    var footer: some View {
        HStack {
            if !st.running && !st.finished && !st.items.isEmpty {
                let free = SetupWizardState.freeGB
                VStack(alignment: .leading, spacing: 2) {
                    Text("共需下载 \(Self.size(st.totalGB)) · 硬盘剩余 \(Self.size(free))").font(.callout).monospacedDigit()
                    if st.totalGB > free * 0.95 {
                        Text("硬盘空间不够，请取消勾选一些项目").font(.caption).foregroundStyle(.red)
                    }
                }
            }
            Spacer()
            Button("连接云端 API") {
                modelsTab = 2; app.section = .models; close()
            }.disabled(st.running)
            if st.running {
                Button("停止") { st.cancel() }
            } else if st.finished {
                if st.items.contains(where: { if case .failed = $0.status { return true }; return false }) {
                    Button("重试失败的项目") {
                        for i in st.items.indices { if case .failed = st.items[i].status { st.items[i].status = .waiting } }
                        st.finished = false
                        st.start()
                    }
                }
                Button("完成") { close() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Color.toolula)
            } else if st.items.isEmpty {
                Button("完成") { close() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Color.toolula)
            } else {
                Button("以后再说") { close() }
                Button("一键安装") { st.start() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Color.toolula)
                    .disabled(st.items.allSatisfy { !$0.on } || st.totalGB > SetupWizardState.freeGB * 0.95)
            }
        }
    }

    func close() {
        UserDefaults.standard.set(true, forKey: "setupShown")
        st.show = false
    }
}
