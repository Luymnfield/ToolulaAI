import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct VideoView: View {
    @ObservedObject var store = VideoStore.shared
    @ObservedObject var engine = ComfyEngine.shared
    @ObservedObject var models = VideoModels.shared
    @ObservedObject var queue = GenQueue.shared
    @State private var showBatch = false
    @AppStorage("videoModelOpen") private var modelOpen = false

    static let examples = ["A small red paper boat drifting on a calm pond at sunrise. Audio: gentle water, distant birds",
                           "Slow dolly shot through a rainy neon street at night, reflections on wet asphalt",
                           "A cat stretching on a sunny windowsill, curtains moving in the breeze"]

    var body: some View {
        HStack(spacing: 0) {
            if !store.items.isEmpty {
                history.frame(width: 150)
                Divider()
            }
            player
            Divider()
            settings.frame(width: 340)
        }
        .task { models.scan(); await engine.check() }
        .onAppear { ComfyWarmup.enter("video") }
        .onDisappear { ComfyWarmup.leave("video") }
        .onChange(of: models.selectedId) { ComfyWarmup.enter("video") }
    }

    // MARK: 左边: 生成过的视频 (窄条)

    var history: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("\(store.items.count) 段").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { NSWorkspace.shared.open(VideoStore.videosFolder) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help(Text("在访达中打开视频文件夹")).accessibilityLabel(Text("在访达中打开视频文件夹"))
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            List(selection: $store.selected) {
                ForEach(store.items) { v in
                    VStack(alignment: .leading, spacing: 3) {
                        VideoThumb(path: v.path).frame(height: 70).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 5))
                        Text("\(String(format: "%.0f", v.seconds)) 秒 · \(v.model ?? "MiniMax H3")").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(v.id)
                    .help(Text(verbatim: v.prompt))
                    .contextMenu {
                        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: v.path)]) }
                        Button("用这个提示词") { store.prompt = v.prompt }
                        Divider()
                        Button("删除视频", role: .destructive) {
                            try? FileManager.default.trashItem(at: URL(fileURLWithPath: v.path), resultingItemURL: nil)
                            store.items.removeAll { $0.id == v.id }
                            store.save()
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: 中间: 深灰画布

    @ViewBuilder var player: some View {
        DarkCanvas {
            if store.running {
                VStack(spacing: 14) {
                    if let p = store.previewPath {
                        PlayerView(url: URL(fileURLWithPath: p))
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .frame(maxWidth: 640, maxHeight: 360)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Text("预览（快速解码，画质略低）。高清版完成后会自动替换。").font(.caption).foregroundStyle(.white.opacity(0.55))
                    }
                    CanvasProgress(value: store.steps > 0 ? Double(store.step) / Double(store.steps) : nil, stage: store.stage,
                                   detail: store.startedAt.map { t in Text(timerInterval: t...Date.distantFuture, countsDown: false) + Text(" · ") + Text("预计共约 \(Int(store.estimateMinutes.rounded())) 分钟") }) {
                        store.cancel()
                    }
                }
                .padding(24)
            } else if let v = store.items.first(where: { $0.id == store.selected }) {
                VStack(spacing: 12) {
                    PlayerView(url: URL(fileURLWithPath: v.path))
                        .id(v.id)
                        .aspectRatio(CGFloat(v.width) / CGFloat(max(v.height, 1)), contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(color: .black.opacity(0.35), radius: 10)
                    Text(verbatim: v.prompt).font(.callout).foregroundStyle(.white.opacity(0.7)).lineLimit(2).textSelection(.enabled)
                        .multilineTextAlignment(.center)
                    Text("\(v.model ?? "MiniMax H3") · \(String(v.width))×\(String(v.height)) · 种子 \(String(v.seed)) · 用时 \(Int(v.elapsed / 60)) 分钟")
                        .font(.caption).foregroundStyle(.white.opacity(0.45))
                    FloatingBar {
                        Button { store.prompt = v.prompt } label: { Label("用这个提示词", systemImage: "text.quote") }
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: v.path)]) } label: { Label("在访达中显示", systemImage: "folder") }
                    }
                }
                .padding(24)
            } else {
                CanvasEmpty(icon: "film.stack", title: "写下想要的视频", subtitle: "用本机的视频模型把文字或图片变成视频。写下想要的画面，或者给一张图片作为第一帧。") {
                    VStack(spacing: 6) {
                        ForEach(Self.examples, id: \.self) { ex in
                            Button { store.prompt = ex } label: {
                                Text(verbatim: ex).font(.caption).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 5)
                                    .foregroundStyle(.white.opacity(0.8))
                                    .background(.white.opacity(0.08), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: 右边: 卡片 + 固定的生成按钮

    var settings: some View {
        SettingsColumn {
            StepCard(number: 1, title: "想要什么视频", icon: "text.quote") {
                Button { store.improvePrompt() } label: {
                    if store.improving { ProgressView().controlSize(.mini) } else { Label("AI 优化", systemImage: "wand.and.stars").font(.caption) }
                }
                .buttonStyle(.borderless).foregroundStyle(Color.toolula)
                .disabled(store.prompt.isEmpty || store.improving || store.running)
                .help(Text("让对话模型把你的想法扩写成详细的英文视频提示词"))
            } content: {
                PromptEditor(text: $store.prompt, height: 120)
                Text("英文效果最好；可以加一行 Audio: 描述声音").font(.caption2).foregroundStyle(.secondary)
            }
            StepCard(number: 2, title: "首帧图片（可选）", icon: "photo") { EmptyView() } content: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15))
                        if let f = store.firstFrame, let img = NSImage(contentsOf: f) {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "photo.badge.plus").foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 80, height: 54).clipShape(RoundedRectangle(cornerRadius: 6))
                    .onDrop(of: [.fileURL], isTargeted: nil) { p in
                        loadURLs(p) { if let u = $0.first { store.firstFrame = u } }
                        return true
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.firstFrame == nil ? "拖一张图片进来，让它动起来" : "从这张图开始动起来").font(.caption)
                        HStack {
                            Button("选择…") {
                                let p = NSOpenPanel(); p.allowedContentTypes = [.image]
                                if p.runModal() == .OK { store.firstFrame = p.url }
                            }.controlSize(.small)
                            if store.firstFrame != nil { Button("清除") { store.firstFrame = nil }.controlSize(.small) }
                        }
                    }
                }
            }
            StepCard(number: 3, title: "视频模型", icon: "square.stack.3d.up") { EmptyView() } content: {
                ModelDisclosure(name: models.selected.name, ready: models.isReady(models.selected), open: $modelOpen) { VideoModelPicker() }
            }
            StepCard(number: 4, title: "设置", icon: "slider.horizontal.3") { EmptyView() } content: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("时长")
                        Slider(value: $store.seconds, in: 2...models.selected.maxSeconds, step: 1)
                        Text("\(Int(store.seconds)) 秒").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    Picker("清晰度", selection: $store.quality) {
                        ForEach(models.selected.qualities) { Text($0.rawValue.locKey).tag($0) }
                    }
                    .accessibilityLabel(Text("清晰度"))
                    if store.firstFrame == nil {
                        Picker("画面比例", selection: $store.aspect) {
                            ForEach(VideoAspect.allCases) { Text($0.rawValue.locKey).tag($0) }
                        }
                        .accessibilityLabel(Text("画面比例"))
                    }
                    let turboFile = models.selected.files.last!
                    if turboFile.optional {
                        if models.file(models.selected, turboFile) != nil {
                            Toggle("加速（Turbo，4 步出片）", isOn: $store.turbo)
                                .help(Text("用蒸馏过的 4 步加速文件，出片快很多，画面细节略少一点"))
                        } else if models.isReady(models.selected) {
                            Button {
                                models.download(models.selected)
                            } label: {
                                Label("下载加速文件（\(String(format: "%.1f", turboFile.sizeGB)) GB，出片快很多）", systemImage: "bolt")
                            }
                            .disabled(models.downloading[models.selected.id].map { !$0.done && !$0.failed } ?? false)
                        }
                    }
                    HStack {
                        Toggle("随机种子", isOn: $store.randomSeed)
                        if !store.randomSeed {
                            TextField("", value: $store.seed, format: .number).frame(width: 110)
                        }
                    }
                    Toggle("生成完释放视频模型占用的内存", isOn: $store.autoFree)
                }
                .controlSize(.small)
            }
        } footer: {
            if let e = store.error {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button { GenQueue.shared.addVideos([store.prompt]) } label: {
                    Label(queue.busy ? "加入队列" : "生成视频", systemImage: queue.busy ? "text.badge.plus" : "film").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Color.toolula).controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(store.prompt.trimmingCharacters(in: .whitespaces).isEmpty || !models.isReady(models.selected))
                Button { showBatch = true } label: { Image(systemName: "list.bullet.rectangle") }
                    .controlSize(.large)
                    .help(Text("批量：每行一个提示词，一个接一个生成"))
                    .accessibilityLabel(Text("批量生成视频"))
                    .disabled(!models.isReady(models.selected))
            }
            .sheet(isPresented: $showBatch) { BatchPromptSheet(kind: .video, isPresented: $showBatch) }
            let (w, h) = store.currentSize
            Text("\(w) × \(h) · \(VideoMath.frames(store.seconds)) 帧 · 预计约 \(Int(store.currentEstimate.rounded())) 分钟")
                .font(.caption).foregroundStyle(.secondary)
            engineLine
            QueueHint(kind: .video)
        }
    }

    /// 视频引擎状态 (一行)
    var engineLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(engine.online ? .green : .gray).frame(width: 7, height: 7)
                (engine.online ? Text("ComfyUI 在线（端口 \(String(engine.port))）") : Text("ComfyUI 未运行（生成时会自动在后台启动）"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if engine.starting { ProgressView().controlSize(.mini) }
                else if engine.online {
                    Button("释放内存") { store.freeMemory() }.buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                        .help(Text("释放视频模型内存"))
                }
            }
            if !ComfyEngine.installed {
                HStack {
                    Text("还没有视频引擎。设置向导可以一键安装（不需要另外装 ComfyUI）。").font(.caption).foregroundStyle(.orange)
                    Button("打开设置向导") { SetupWizardState.shared.show = true }.controlSize(.small)
                }
            }
            if let m = engine.message { Text(m).font(.caption).foregroundStyle(.orange) }
        }
    }
}

/// 视频缩略图
struct VideoThumb: View {
    let path: String
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
        }
        .task(id: path) {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 200, height: 200)
            if let cg = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image {
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
    }
}

/// macOS 原生播放器 (AVPlayerView). SwiftUI 的 VideoPlayer 在这种打包方式下会崩溃, 所以用这个
struct PlayerView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .inline
        v.showsFullScreenToggleButton = true
        v.player = AVPlayer(url: url)
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {
        if (v.player?.currentItem?.asset as? AVURLAsset)?.url != url { v.player = AVPlayer(url: url) }
    }
    static func dismantleNSView(_ v: AVPlayerView, coordinator: ()) { v.player?.pause() }
}
