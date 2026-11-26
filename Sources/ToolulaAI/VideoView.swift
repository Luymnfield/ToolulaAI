import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct VideoView: View {
    @ObservedObject var store = VideoStore.shared
    @ObservedObject var engine = ComfyEngine.shared
    @ObservedObject var models = VideoModels.shared

    var body: some View {
        HStack(spacing: 0) {
            history.frame(width: 250)
            Divider()
            player.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            settings.frame(width: 360)
        }
        .task { models.scan(); await engine.check() }
    }

    // MARK: 左边: 生成过的视频

    var history: some View {
        VStack(spacing: 0) {
            HStack {
                Text("生成的视频").font(.headline)
                Spacer()
                Button { NSWorkspace.shared.open(VideoStore.videosFolder) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help(Text("在访达中打开视频文件夹")).accessibilityLabel(Text("在访达中打开视频文件夹"))
            }
            .padding(12)
            List(selection: $store.selected) {
                if store.items.isEmpty {
                    Text("还没有生成过视频").foregroundStyle(.secondary)
                }
                ForEach(store.items) { v in
                    HStack(spacing: 8) {
                        VideoThumb(path: v.path).frame(width: 64, height: 40).clipShape(RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.prompt).lineLimit(2).font(.caption)
                            Text("\(v.model ?? "MiniMax H3") · \(v.width)×\(v.height) · \(String(format: "%.0f", v.seconds))s").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .tag(v.id)
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
        }
    }

    // MARK: 中间: 播放

    @ViewBuilder var player: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if store.running {
                VStack(spacing: 14) {
                    if let p = store.previewPath {
                        PlayerView(url: URL(fileURLWithPath: p))
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .frame(maxWidth: 640, maxHeight: 360)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text("预览（快速解码，画质略低）。高清版完成后会自动替换。").font(.caption).foregroundStyle(.secondary)
                    }
                    ProgressView(value: store.steps > 0 ? Double(store.step) / Double(store.steps) : nil)
                        .frame(width: 320)
                    Text(store.stage).font(.headline)
                    if let t = store.startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let el = ctx.date.timeIntervalSince(t)
                            Text("已用 \(Int(el) / 60) 分 \(Int(el) % 60) 秒 · 预计共约 \(Int(store.estimateMinutes.rounded())) 分钟")
                                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    Button("停止") { store.cancel() }
                }
            } else if let v = store.items.first(where: { $0.id == store.selected }) {
                VStack(spacing: 10) {
                    PlayerView(url: URL(fileURLWithPath: v.path))
                        .id(v.id)
                        .aspectRatio(CGFloat(v.width) / CGFloat(max(v.height, 1)), contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(radius: 8)
                    Text(v.prompt).font(.callout).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    Text("种子 \(String(v.seed)) · 用时 \(Int(v.elapsed / 60)) 分钟").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(24)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "film.stack").font(.system(size: 48)).foregroundStyle(Color.toolula)
                    Text("AI 视频").font(.title.bold())
                    Text("用本机的视频模型把文字或图片变成视频。\n写下想要的画面，或者给一张图片作为第一帧。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 右边: 设置

    var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                engineBox

                GroupBox {
                    VideoModelPicker().padding(2)
                } label: { Label("视频模型", systemImage: "square.stack.3d.up") }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $store.prompt)
                            .font(.body).frame(height: 130)
                            .scrollContentBackground(.hidden).padding(4)
                            .background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        HStack {
                            Text("英文效果最好；可以加一行 Audio: 描述声音").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { store.improvePrompt() } label: {
                                if store.improving { ProgressView().controlSize(.mini) } else { Label("AI 优化", systemImage: "wand.and.stars") }
                            }
                            .controlSize(.small).disabled(store.prompt.isEmpty || store.improving || store.running)
                            .help(Text("让对话模型把你的想法扩写成详细的英文视频提示词"))
                        }
                    }.padding(4)
                } label: { Label("想要什么视频", systemImage: "text.quote") }

                GroupBox {
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
                            Text(store.firstFrame == nil ? "首帧图片（可选）" : "从这张图开始动起来").font(.callout)
                            HStack {
                                Button("选择…") {
                                    let p = NSOpenPanel(); p.allowedContentTypes = [.image]
                                    if p.runModal() == .OK { store.firstFrame = p.url }
                                }.controlSize(.small)
                                if store.firstFrame != nil { Button("清除") { store.firstFrame = nil }.controlSize(.small) }
                            }
                        }
                    }.padding(4)
                } label: { Label("图生视频", systemImage: "photo") }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
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
                        let (w, h) = store.currentSize
                        Text("\(w) × \(h) · \(VideoMath.frames(store.seconds)) 帧 · 预计约 \(Int(store.currentEstimate.rounded())) 分钟")
                            .font(.caption).foregroundStyle(.secondary)
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
                    }.padding(4)
                } label: { Label("设置", systemImage: "slider.horizontal.3") }

                if let e = store.error {
                    Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Task { await store.generate() }
                } label: {
                    Label("生成视频", systemImage: "film").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Color.toolula).controlSize(.large)
                .disabled(store.running || store.prompt.trimmingCharacters(in: .whitespaces).isEmpty || !models.isReady(models.selected))

                Text("生成时会暂时让出对话模型占用的内存，对话时会自动重新加载。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(14)
        }
    }

    var engineBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Circle().fill(engine.online ? .green : .gray).frame(width: 9, height: 9)
                    (engine.online ? Text("ComfyUI 在线（端口 \(String(engine.port))）") : Text("ComfyUI 未运行（生成时会自动在后台启动）"))
                        .font(.callout)
                    Spacer()
                    if engine.starting { ProgressView().controlSize(.small) }
                    else if !engine.online && ComfyEngine.installed { Button("启动") { Task { await engine.start() } }.controlSize(.small) }
                }
                if engine.online {
                    Button("释放视频模型内存") { store.freeMemory() }.controlSize(.small)
                }
                if !ComfyEngine.installed {
                    Text("还没有视频引擎。设置向导可以一键安装（不需要另外装 ComfyUI）。").font(.caption).foregroundStyle(.orange)
                    Button("打开设置向导") { SetupWizardState.shared.show = true }.controlSize(.small)
                }
                if let m = engine.message { Text(m).font(.caption).foregroundStyle(.orange) }
            }.padding(4)
        } label: { Label("视频引擎", systemImage: "cpu") }
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
