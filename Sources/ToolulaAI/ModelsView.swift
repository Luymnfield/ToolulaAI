import SwiftUI

struct ModelsView: View {
    @ObservedObject var models = ModelManager.shared
    @ObservedObject var downloader = ModelDownloader.shared
    @ObservedObject var info = SystemInfo.shared
    @State private var query = ""
    @AppStorage("modelsTab") private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            switch tab {
            case 0: ScrollView { localPage.padding(24) }
            case 1: ScrollView { downloadPage.padding(24) }
            default: Form { cloudSection }.formStyle(.grouped)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { models.refresh(); VideoModels.shared.scan() }
    }

    // MARK: 顶部: 这台电脑 + 切换

    var topBar: some View {
        HStack(alignment: .center, spacing: 24) {
            HStack(spacing: 10) {
                Image(systemName: info.machine.contains("Book") ? "laptopcomputer" : "desktopcomputer")
                    .font(.title2).foregroundStyle(Color.toolula)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.summary.isEmpty ? String(localized: "这台电脑") : info.summary).font(.headline).lineLimit(1).fixedSize()
                    Text("能流畅运行约 \(Int(Recommender.budgetGB)) GB 以内的模型").font(.caption).foregroundStyle(.secondary)
                }
            }
            meter(String(localized: "内存"), String(localized: "已用 \(Int(info.usedGB.rounded())) / \(Int(info.totalGB.rounded())) GB"),
                  info.usedGB / max(info.totalGB, 1))
            if let d = info.systemDisk {
                meter(String(localized: "硬盘"), String(localized: "可用 \(SystemInfo.size(d.free))"), d.usedFraction)
            }
            Spacer(minLength: 12)
            Picker("模型", selection: $tab) {
                Text("本地模型").tag(0)
                Text("下载新模型").tag(1)
                Text("云端 API").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 360)
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    func meter(_ title: String, _ detail: String, _ f: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption.bold())
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            UsageBar(fraction: f)
        }
        .frame(minWidth: 130, maxWidth: 190)
    }

    /// 左边对话模型, 右边视频模型
    func columns<L: View, R: View>(@ViewBuilder _ left: () -> L, @ViewBuilder _ right: () -> R) -> some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 20) { left() }.frame(maxWidth: .infinity).layoutPriority(1)
            VStack(spacing: 20) { right() }.frame(minWidth: 380, idealWidth: 500, maxWidth: 540)
        }
        .frame(maxWidth: 1600)
        .frame(maxWidth: .infinity)
    }

    // MARK: 本地

    var localPage: some View {
        columns {
            ModelCard(title: "对话和修图模型", icon: "bubble.left.and.text.bubble.right") {
                engineStatus
                if models.localChatModels.isEmpty {
                    Text("还没有下载模型。到「下载新模型」里挑一个推荐给这台电脑的。").foregroundStyle(.secondary).font(.callout)
                }
                ForEach(Array(models.localChatModels.enumerated()), id: \.element.id) { i, m in
                    if i > 0 { Divider() }
                    ModelRow(model: m)
                }
                Divider()
                HStack {
                    Button("卸载所有模型（释放内存）") { models.unloadAll() }
                    Button("在访达中打开模型文件夹") {
                        NSWorkspace.shared.open(LocalEngine.installed ? ModelDownloader.modelsDir : EnginePaths.models)
                    }
                    Spacer()
                }
                .controlSize(.small)
                Text("每个对话都可以在顶部单独选模型。切换模型时会自动卸载上一个、加载新的（第一次回复会慢几十秒）。修图必须用能看图的模型。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ModelCard(title: "图片模型（文字生成图片）", icon: "paintbrush.pointed") {
                ImageModelPicker()
                Text("点一下选择绘图页默认用的模型。和视频模型共用一个引擎。").font(.caption).foregroundStyle(.secondary)
            }
        } _: {
            ModelCard(title: "视频模型", icon: "film") {
                VideoModelsBlock()
                Text("点一下选择视频页默认用的模型。也可以在视频页随时切换。").font(.caption).foregroundStyle(.secondary)
            }
            ModelCard(title: "加速", icon: "bolt") {
                AccelerationBlock()
            }
            ModelCard(title: "可选组件", icon: "puzzlepiece.extension") {
                OptionalComponentsBlock()
            }
        }
    }

    @ViewBuilder var engineStatus: some View {
        if LocalEngine.installed {
            HStack {
                Circle().fill(models.lmOnline ? .green : .red).frame(width: 8, height: 8)
                (models.lmOnline ? Text("LM Studio 本地服务在线（127.0.0.1:1234）") : Text("LM Studio 本地服务没有运行")).font(.callout)
                Spacer()
                if !models.lmOnline { Button("启动") { models.startServer() }.controlSize(.small) }
                Button("刷新") { models.refresh() }.controlSize(.small)
            }
        }
        if BuiltinEngine.installed {
            HStack {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("Toolula 内置 AI 引擎（llama.cpp）已安装，用到时自动启动，空闲 15 分钟自动释放内存").font(.callout)
                Spacer()
            }
        }
        if !LocalEngine.installed && !BuiltinEngine.installed {
            HStack {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text("还没有本地 AI 引擎").font(.callout)
                Spacer()
                Button("打开设置向导") { SetupWizardState.shared.show = true }.buttonStyle(.borderedProminent).tint(Color.toolula)
            }
        }
        Divider()
    }

    // MARK: 下载

    var downloadPage: some View {
        columns {
            if !downloader.jobs.isEmpty {
                ModelCard(title: "下载任务", icon: "arrow.down.circle") {
                    ForEach(downloader.jobs) { DownloadRow(job: $0) }
                }
            }
            ModelCard(title: "对话和修图模型 · 为这台电脑推荐", icon: "sparkles") {
                RecommendationPanel(showMachine: false)
            }
            ModelCard(title: "搜索更多模型（Hugging Face）", icon: "magnifyingglass") {
                HStack {
                    TextField("搜索模型，例如 qwen、gemma、llama、coder", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { downloader.search(query) }
                    Button("搜索") { downloader.search(query) }.disabled(downloader.searching)
                    if downloader.searching { ProgressView().controlSize(.small) }
                }
                if let e = downloader.searchError { Text(e).foregroundStyle(.orange).font(.caption) }
                ForEach(Array(downloader.results.enumerated()), id: \.element.id) { i, m in
                    if i > 0 { Divider() }
                    HFRow(model: m)
                }
                Text("下载完成后在「本地模型」里就能用。断网或取消后再点下载会接着下。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } _: {
            ModelCard(title: "视频模型", icon: "film") {
                VideoModelsBlock()
            }
            ModelCard(title: "图片模型（文字生成图片）", icon: "paintbrush.pointed") {
                ImageModelPicker()
            }
        }
    }

    // MARK: 云端

    @ViewBuilder var cloudSection: some View {
        Section {
            Label("使用云端模型时，对话内容（包括图片和文件内容）会发送给对应的服务商；本地模型则完全不出这台电脑。",
                  systemImage: "exclamationmark.shield")
                .font(.callout).foregroundStyle(.orange)
            Menu {
                ForEach(Provider.presets) { p in Button(p.name) { _ = models.addProvider(p) } }
                Divider()
                Button("自定义（OpenAI 兼容接口）") {
                    _ = models.addProvider(Provider.Preset(name: String(localized: "自定义"), baseURL: "https://", needsKey: true,
                                                           kind: "openai", defaults: [], keyURL: ""))
                }
            } label: { Label("添加服务商", systemImage: "plus") }
            .fixedSize()
        } header: { Text("云端 API") }

        ForEach(models.providers) { p in ProviderCard(providerId: p.id) }
    }
}

// MARK: - 卡片

struct ModelCard<Content: View>: View {
    let title: LocalizedStringKey
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(.primary)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }
}

// MARK: - 一行模型 (本地或云端)

struct ModelRow: View {
    @ObservedObject var models = ModelManager.shared
    let model: LMModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.displayName).bold()
                HStack(spacing: 6) {
                    pill((model.vision ? "能看图" : "纯文字").locKey, model.vision ? .blue : .gray)
                    if model.toolUse { pill("会用工具", .purple) }
                    if model.isCloud { pill("云端", .orange) }
                    if model.context > 0 { pill("上下文 \(model.context / 1024)K", .gray) }
                    if model.loaded { pill("已加载到内存", .green) }
                    if models.fastModel == model.id && models.autoRoute { pill("⚡︎ 快速模型", .yellow) }
                }
                if let b = models.bench[model.id], let g = b["gen"] {
                    Text(benchText(b, g)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if !model.isCloud {
                    Button {
                        Task { if let e = await models.benchmark(model.id) { models.lastError = e } }
                    } label: {
                        if models.benchmarking == model.id { HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("测速中…") } }
                        else { Label("测速", systemImage: "speedometer") }
                    }
                    .disabled(models.benchmarking != nil)
                    .help(Text("在这台 Mac 上实际跑一次：加载时间、读提示速度、输出速度"))
                }
                Button((models.chatModel == model.id ? "✓ 对话默认" : "设为对话默认").locKey) { models.chatModel = model.id }
                    .disabled(models.chatModel == model.id)
                if model.vision {
                    Button((models.photoModel == model.id ? "✓ 修图模型" : "设为修图模型").locKey) { models.photoModel = model.id }
                        .disabled(models.photoModel == model.id)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

func benchText(_ b: [String: Double], _ gen: Double) -> String {
    var p = [String(localized: "实测输出 \(String(Int(gen.rounded()))) token/秒")]
    if let t = b["ttft"] { p.append(String(localized: "开始回答 \(String(format: "%.1f", t)) 秒")) }
    if let l = b["load"], l > 2 { p.append(String(localized: "加载 \(String(Int(l.rounded()))) 秒")) }
    return p.joined(separator: " · ")
}

func pill(_ s: LocalizedStringKey, _ c: Color) -> some View {
    Text(s).font(.caption2).lineLimit(1).fixedSize().padding(.horizontal, 6).padding(.vertical, 2).background(c.opacity(0.18)).clipShape(Capsule())
}

// MARK: - Hugging Face 结果

struct HFRow: View {
    @ObservedObject var downloader = ModelDownloader.shared
    @ObservedObject var info = SystemInfo.shared
    let model: HFModel

    var note: String? { (Recommender.mlx + Recommender.gguf).first { $0.id == model.id }?.note }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.id.split(separator: "/").last.map(String.init) ?? model.id).bold()
                HStack(spacing: 6) {
                    Text(model.id.split(separator: "/").first.map(String.init) ?? "").font(.caption).foregroundStyle(.secondary)
                    if let size = model.size {
                        Text(SystemInfo.size(size)).font(.caption).foregroundStyle(.secondary)
                        fit(size)
                    }
                    if model.downloads > 0 {
                        Label("\(model.downloads)", systemImage: "arrow.down.circle").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if let note { Text(note.locKey).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if model.installed {
                Label("已下载", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            } else {
                Button("下载") { downloader.download(model.id) }
                    .disabled(downloader.jobs.contains { $0.id == model.id && !$0.done && !$0.failed })
            }
        }
        .padding(.vertical, 3)
    }

    /// 按这台电脑的内存判断能不能跑
    @ViewBuilder func fit(_ size: Int64) -> some View {
        let f = Recommender.fit(Double(size) / 1e9)
        pill(f.0, f.1)
    }
}

struct DownloadRow: View {
    @ObservedObject var job: DownloadJob
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(job.id).font(.callout.bold()).lineLimit(1).truncationMode(.middle)
                Spacer()
                if !job.done && !job.failed {
                    Button("取消") { ModelDownloader.shared.cancel(job) }.controlSize(.small)
                } else if job.failed {
                    Button("继续下载") { ModelDownloader.shared.download(job.id) }.controlSize(.small)
                }
            }
            ProgressView(value: job.fraction).tint(job.failed ? .red : .green)
            HStack {
                Text(job.state).font(.caption).foregroundStyle(job.failed ? .orange : .secondary)
                Spacer()
                Text("\(SystemInfo.size(job.received)) / \(SystemInfo.size(job.total))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - 云端服务商卡片

struct ProviderCard: View {
    @ObservedObject var models = ModelManager.shared
    let providerId: UUID
    @State private var key = ""
    @State private var keySaved = false
    @State private var status: String?
    @State private var loading = false
    @State private var manualModel = ""

    var provider: Provider? { models.providers.first { $0.id == providerId } }
    var preset: Provider.Preset? { Provider.presets.first { $0.name == provider?.name } }

    var body: some View {
        if let p = provider {
            Section {
                TextField("名称", text: Binding(get: { p.name }, set: { v in models.updateProvider(providerId) { $0.name = v } }))
                TextField("API 地址", text: Binding(get: { p.baseURL }, set: { v in models.updateProvider(providerId) { $0.baseURL = v } }))
                    .font(.system(.body, design: .monospaced))
                if p.needsKey {
                    HStack {
                        SecureField(keySaved ? String(localized: "已保存在钥匙串（输入新的可替换）") : "API Key", text: $key)
                        Button("保存") {
                            Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: providerId)
                            key = ""
                            keySaved = Keychain.get(providerId) != nil
                            Task { await refreshModels() }
                        }
                        .disabled(key.isEmpty)
                        if let url = preset?.keyURL, !url.isEmpty, let u = URL(string: url) {
                            Link("获取 Key", destination: u).font(.caption)
                        }
                    }
                }
                HStack {
                    Button("获取模型列表") { Task { await refreshModels() } }.disabled(loading)
                    if loading { ProgressView().controlSize(.small) }
                    if let status { Text(status).font(.caption).foregroundStyle(status.hasPrefix("✓") ? .green : .orange).lineLimit(2) }
                    Spacer()
                    Button("删除服务商", role: .destructive) { models.removeProvider(providerId) }
                }
                if !p.models.isEmpty {
                    Text("勾选要在 Toolula 里使用的模型：").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(p.models, id: \.self) { m in
                                Toggle(m, isOn: Binding(
                                    get: { p.enabledModels.contains(m) },
                                    set: { on in models.updateProvider(providerId) { pr in
                                        if on { if !pr.enabledModels.contains(m) { pr.enabledModels.append(m) } }
                                        else { pr.enabledModels.removeAll { $0 == m } }
                                    } }))
                                .toggleStyle(.checkbox)
                                .font(.system(.callout, design: .monospaced))
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
                HStack {
                    TextField("手动添加模型名，例如 gpt-5", text: $manualModel)
                    Button("添加") {
                        let m = manualModel.trimmingCharacters(in: .whitespaces)
                        guard !m.isEmpty else { return }
                        models.updateProvider(providerId) { pr in
                            if !pr.models.contains(m) { pr.models.append(m) }
                            if !pr.enabledModels.contains(m) { pr.enabledModels.append(m) }
                        }
                        manualModel = ""
                    }
                }
                ForEach(models.cloudModels.filter { $0.id.hasPrefix("cloud:\(providerId.uuidString)/") }) { ModelRow(model: $0) }
            } header: {
                Label(p.name, systemImage: "cloud")
            }
            .onAppear { keySaved = Keychain.get(providerId) != nil }
        }
    }

    func refreshModels() async {
        loading = true
        let err = await models.fetchModels(providerId)
        loading = false
        status = err ?? String(localized: "✓ 已连接")
    }
}

/// 模型页里的视频模型: 自动检测已安装的, 按这台电脑推荐, 可以直接下载和选择
struct VideoModelsBlock: View {
    @ObservedObject var vm = VideoModels.shared
    @ObservedObject var engine = ComfyEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !ComfyEngine.installed && Recommender.appleSilicon {
                HStack {
                    Label("还没有视频引擎。设置向导可以一键安装（不需要另外装 ComfyUI）。", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("打开设置向导") { SetupWizardState.shared.show = true }.controlSize(.small)
                }
            }
            VideoModelPicker()
        }
        .onAppear { vm.scan() }
    }
}


// MARK: - 加速设置

struct AccelerationBlock: View {
    @ObservedObject var models = ModelManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            feature("tray.full", "提示词缓存", "对话里没变的部分不再重新读，长对话每轮开始回答快很多")
            feature("text.line.first.and.arrowtriangle.forward", "推测解码", "内置引擎从已有文字里预测接下来的内容（改代码、引用文件时快好几倍），结果和不加速完全一样")
            feature("memorychip", "Flash Attention + 8 位缓存", "内置引擎读长内容更快，上下文占用内存减半（这台 Mac 可放 \(Self.k(BuiltinEngine.contextSize)) token）")

            Divider()
            MTPEngineBlock()

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $models.autoRoute) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("快慢模型自动分流")
                        Text("简单的问题（聊天、翻译、问答）交给快模型，写代码、操作电脑、修图、看图仍用对话默认模型")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if models.autoRoute {
                    HStack {
                        Text("快速模型").font(.callout)
                        Spacer()
                        Picker("快速模型", selection: $models.fastModel) {
                            Text("不使用").tag("")
                            ForEach(models.localChatModels.filter { $0.id != models.chatModel }) { m in
                                Text(m.displayName + (models.bench[m.id]?["gen"].map { "  ·  \(Int($0.rounded())) token/秒" } ?? "")).tag(m.id)
                            }
                        }
                        .labelsHidden().frame(width: 240)
                    }
                    if models.fastModel.isEmpty {
                        Text(fastHint).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(fastMemText).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider()
            Toggle(isOn: $models.autoCompress) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("对话太长时自动压缩")
                    Text("超过 3.2 万 token（或模型上下文的 75%）时，把较早的对话写成摘要；也可以在对话页随时手动压缩")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()
            ComfyWarmupToggle()

            if LocalEngine.installed, let main = models.model(models.chatModel), !main.isBuiltin, !main.isCloud {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("LM Studio 草稿模型")
                        Spacer()
                        Picker("LM Studio 草稿模型", selection: Binding(get: { models.draftModels[main.id] ?? "" },
                                                      set: { models.draftModels[main.id] = $0.isEmpty ? nil : $0 })) {
                            Text("不使用").tag("")
                            ForEach(models.draftCandidates(for: main.id)) { m in Text(m.displayName).tag(m.id) }
                        }
                        .labelsHidden().frame(width: 200)
                    }
                    Text("给「\(main.displayName)」配一个同系列的小模型先打草稿，输出通常快 1.5–2.5 倍。要和主模型同一系列（例如 Qwen 配 Qwen 的小模型）；不配套时会自动改回不用。能看图的模型在 LM Studio 里可能不支持。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()
            Label {
                Text("想要更快：选「混合专家（MoE）」模型，例如 Gemma 4 26B-A4B、Qwen3 Coder 30B-A3B。它们每个字只动用一小部分参数，比同级别的普通模型快 3–5 倍。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } icon: { Image(systemName: "lightbulb").foregroundStyle(.yellow) }
        }
    }

    func feature(_ icon: String, _ title: LocalizedStringKey, _ note: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.toolula).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    Text("已开启").font(.caption2.weight(.medium)).foregroundStyle(.green)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(.green.opacity(0.12)))
                }
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func k(_ n: Int) -> String { "\(n / 1024)K" }

    var fastHint: String {
        if models.localChatModels.count < 2 {
            return String(localized: "还没有第二个模型。到「下载新模型 → 轻快」里下载一个，例如 Gemma 4 26B-A4B（混合专家，又快又聪明）。")
        }
        return String(localized: "选一个比对话默认模型小、快的模型。点模型旁边的「测速」可以看实际速度。")
    }

    var fastMemText: String {
        let gb = (Recommender.ramGB * 0.55).rounded()
        return String(localized: "两个模型会同时留在内存里，切换不用重新加载（两个加起来最好不超过 \(String(Int(gb))) GB）。")
    }
}

/// 绘图 / 视频页预热的开关 (设置窗口「模型与加速」和模型页都会显示)
struct ComfyWarmupToggle: View {
    @AppStorage("comfyWarmup") private var on = true
    var body: some View {
        Toggle(isOn: Binding(get: { on }, set: { on = $0; ComfyWarmup.setEnabled($0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("绘图 / 视频页预热")
                Text("打开绘图或视频页时，在后台先启动 ComfyUI 并加载模型，第一次生成少等 15–50 秒。离开页面 5 分钟后自动释放内存。关掉后，已预加载的模型会立即卸载。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityLabel(Text("绘图 / 视频页预热"))
    }
}


// MARK: - 可选组件: 修图用的小模型, 不随 App 发布, 用户自己决定要不要下载

struct OptionalComponentsBlock: View {
    @EnvironmentObject var store: Store
    @State private var tick = 0   // 下载 / 删除后刷新

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(name: "语义分割模型", detail: "认出水面、山、建筑、天空，在修图里单独调这些区域；也让 AI 知道画面构成。Apple 发布的 DETR（Apache-2.0）。",
                sizeMB: SceneSegmenter.sizeMB, installed: SceneSegmenter.installed,
                download: { store.downloadSegmenter() }, folder: SceneSegmenter.dir)
            Divider()
            row(name: "AI 消除模型", detail: "修图里的「AI 消除」：涂掉路人、杂物、电线，自动补上背景。LaMa（Apache-2.0）。第一次用 AI 消除时也会自动下载。",
                sizeMB: 216, installed: Inpainter.installed, download: nil, folder: Inpainter.dir)
            Text("这些模型不在 App 里，也不在 Toolula 的代码仓库里；下载后放在 ~/Toolula/Models，只在这台 Mac 上用。")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .id(tick)
        .onChange(of: store.working) { tick += 1 }
    }

    @ViewBuilder func row(name: String, detail: String, sizeMB: Int, installed: Bool, download: (() -> Void)?, folder: URL) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name.locKey).bold()
                    Text(verbatim: "\(sizeMB) MB").font(.caption).foregroundStyle(.secondary)
                    if installed { Label("已安装", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                }
                Text(detail.locKey).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if installed {
                Button("删除") {
                    // 移到废纸篓 (可以从废纸篓找回)
                    try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
                    if folder == SceneSegmenter.dir { SceneSegmenter.shared.unload() }
                    tick += 1
                    for p in store.photos { p.changed() }
                }
                .controlSize(.small)
                .help(Text("移到废纸篓，需要时可以重新下载"))
            } else if let download {
                Button("下载") { download() }.controlSize(.small).disabled(store.working)
            }
        }
    }
}
