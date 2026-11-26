import AppKit
import Foundation
import SwiftUI

// MARK: - 文字生成图片 (通过 ComfyUI, 和视频共用一个引擎和模型文件夹)

struct ImageModelSpec: Identifiable, Hashable {
    let id: String
    let name: String
    let note: String
    let ramGB: Double          // 舒服运行需要的内存
    let files: [VideoModelFile]
    let steps: Int
    let quality: Int           // 画质排序
    let secPerStepMP: Double   // 每步每百万像素多少秒 (M3 Max 实测)
    let loadSec: Double        // 第一次加载模型的秒数
    var textGood = false       // 擅长画文字 (含中文)

    var downloadGB: Double { files.reduce(0) { $0 + $1.sizeGB } }
    static func == (a: ImageModelSpec, b: ImageModelSpec) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    static let qwen21 = ImageModelSpec(
        id: "qwen-image-21-turbo", name: "Qwen Image 2.1 Turbo", note: "通义千问最新的图片模型，画质最好，能准确画出中英文文字",
        ramGB: 48,
        files: [
            VideoModelFile(dir: "diffusion_models", names: ["qwen_image_2.1_turbo_bf16.safetensors"],
                           url: "https://huggingface.co/Comfy-Org/Qwen-Image-2.1/resolve/main/diffusion_models/qwen_image_2.1_turbo_bf16.safetensors", sizeGB: 14.23),
            VideoModelFile(dir: "text_encoders", names: ["qwen3vl_8b_bf16.safetensors"],
                           url: "https://huggingface.co/Comfy-Org/Qwen-Image-2.1/resolve/main/text_encoders/qwen3vl_8b_bf16.safetensors", sizeGB: 17.53),
            VideoModelFile(dir: "vae", names: ["qwen_image_2.1_vae_bf16.safetensors"],
                           url: "https://huggingface.co/Comfy-Org/Qwen-Image-2.1/resolve/main/vae/qwen_image_2.1_vae_bf16.safetensors", sizeGB: 0.68),
        ],
        steps: 8, quality: 100, secPerStepMP: 8, loadSec: 15, textGood: true)

    static let zimage = ImageModelSpec(
        id: "z-image-turbo", name: "Z-Image Turbo", note: "阿里通义的快速图片模型，写实效果好，32GB 内存就能跑",
        ramGB: 32,
        files: [
            VideoModelFile(dir: "diffusion_models", names: ["z_image_turbo_bf16.safetensors"],
                           url: "https://huggingface.co/Comfy-Org/Z-Image-Turbo/resolve/main/split_files/diffusion_models/z_image_turbo_bf16.safetensors", sizeGB: 12.31),
            VideoModelFile(dir: "text_encoders", names: ["qwen_3_4b.safetensors"],
                           url: "https://huggingface.co/Comfy-Org/Z-Image-Turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors", sizeGB: 8.04),
            VideoModelFile(dir: "vae", names: ["ae.safetensors"],
                           url: "https://huggingface.co/Comfy-Org/Z-Image-Turbo/resolve/main/split_files/vae/ae.safetensors", sizeGB: 0.34),
        ],
        steps: 8, quality: 90, secPerStepMP: 6.2, loadSec: 28, textGood: true)

    static let flux2klein = ImageModelSpec(
        id: "flux2-klein-4b", name: "FLUX.2 Klein 4B", note: "小巧快速，4 步出图，16GB 内存也能跑",
        ramGB: 16,
        files: [
            VideoModelFile(dir: "diffusion_models", names: ["flux-2-klein-4b.safetensors"],
                           url: "https://huggingface.co/Comfy-Org/Flux-2-Klein-4B/resolve/main/split_files/diffusion_models/flux-2-klein-4b.safetensors", sizeGB: 7.75),
            VideoModelFile(dir: "text_encoders", names: ["qwen_3_4b.safetensors"],
                           url: "https://huggingface.co/Comfy-Org/Flux-2-Klein-4B/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors", sizeGB: 8.04),
            VideoModelFile(dir: "vae", names: ["flux2-vae.safetensors"],
                           url: "https://huggingface.co/Comfy-Org/Flux-2-Klein-4B/resolve/main/split_files/vae/flux2-vae.safetensors", sizeGB: 0.34),
        ],
        steps: 4, quality: 75, secPerStepMP: 3.6, loadSec: 20)

    static let all: [ImageModelSpec] = [.qwen21, .zimage, .flux2klein]

    /// 预计秒数
    func estimate(w: Int, h: Int, count: Int, loaded: Bool) -> Double {
        let mp = Double(w * h) / 1_000_000
        return secPerStepMP * pow(mp, 1.15) * Double(steps) * Double(count) + 3 * Double(count) + (loaded ? 2 : loadSec)
    }

    /// ComfyUI API 格式的工作流. 保存节点固定是 "9"
    func graph(prompt: String, width w: Int, height h: Int, count: Int, seed: Int, files: [String: String]) -> [String: Any]? {
        func name(_ i: Int) -> String? { files[self.files[i].id] }
        guard let unet = name(0), let clip = name(1), let vae = name(2) else { return nil }
        var g: [String: Any] = [
            "1": ["class_type": "UNETLoader", "inputs": ["unet_name": unet, "weight_dtype": "default"]],
            "3": ["class_type": "VAELoader", "inputs": ["vae_name": vae]],
            "10": ["class_type": "VAEDecode", "inputs": ["samples": ["8", 0], "vae": ["3", 0]]],
            "9": ["class_type": "SaveImage", "inputs": ["images": ["10", 0], "filename_prefix": "Toolula/\(id)"]],
        ]
        switch id {
        case "z-image-turbo":
            g["2"] = ["class_type": "CLIPLoader", "inputs": ["clip_name": clip, "type": "lumina2", "device": "default"]]
            g["4"] = ["class_type": "ModelSamplingAuraFlow", "inputs": ["model": ["1", 0], "shift": 3]]
            g["5"] = ["class_type": "CLIPTextEncode", "inputs": ["clip": ["2", 0], "text": prompt]]
            g["6"] = ["class_type": "ConditioningZeroOut", "inputs": ["conditioning": ["5", 0]]]
            g["7"] = ["class_type": "EmptySD3LatentImage", "inputs": ["width": w, "height": h, "batch_size": count]]
            g["8"] = ["class_type": "KSampler", "inputs": ["model": ["4", 0], "seed": seed, "steps": steps, "cfg": 1, "sampler_name": "res_multistep",
                                                           "scheduler": "simple", "positive": ["5", 0], "negative": ["6", 0], "latent_image": ["7", 0], "denoise": 1]]
        case "flux2-klein-4b":
            g["2"] = ["class_type": "CLIPLoader", "inputs": ["clip_name": clip, "type": "flux2", "device": "default"]]
            g["5"] = ["class_type": "CLIPTextEncode", "inputs": ["clip": ["2", 0], "text": prompt]]
            g["6"] = ["class_type": "ConditioningZeroOut", "inputs": ["conditioning": ["5", 0]]]
            g["7"] = ["class_type": "EmptyFlux2LatentImage", "inputs": ["width": w, "height": h, "batch_size": count]]
            g["11"] = ["class_type": "RandomNoise", "inputs": ["noise_seed": seed]]
            g["12"] = ["class_type": "KSamplerSelect", "inputs": ["sampler_name": "euler"]]
            g["13"] = ["class_type": "Flux2Scheduler", "inputs": ["steps": steps, "width": w, "height": h]]
            g["14"] = ["class_type": "CFGGuider", "inputs": ["model": ["1", 0], "positive": ["5", 0], "negative": ["6", 0], "cfg": 1]]
            g["8"] = ["class_type": "SamplerCustomAdvanced", "inputs": ["noise": ["11", 0], "guider": ["14", 0], "sampler": ["12", 0],
                                                                        "sigmas": ["13", 0], "latent_image": ["7", 0]]]
        default: // Qwen Image 2.1 Turbo
            g["2"] = ["class_type": "CLIPLoader", "inputs": ["clip_name": clip, "type": "qwen_image", "device": "default"]]
            g["5"] = ["class_type": "TextEncodeQwenImage21", "inputs": ["clip": ["2", 0], "prompt": prompt, "negative_prompt": "", "resolution": 1024]]
            g["7"] = ["class_type": "EmptyLatentImage", "inputs": ["width": w, "height": h, "batch_size": count]]
            g["11"] = ["class_type": "RandomNoise", "inputs": ["noise_seed": seed]]
            g["12"] = ["class_type": "KSamplerSelect", "inputs": ["sampler_name": "euler"]]
            g["13"] = ["class_type": "ManualSigmas", "inputs": ["sigmas": "1.0, 0.978453, 0.95418, 0.926626, 0.89508, 0.845148, 0.704534, 0.414568, 0"]]
            g["14"] = ["class_type": "CFGGuider", "inputs": ["model": ["1", 0], "positive": ["5", 0], "negative": ["5", 1], "cfg": 1]]
            g["8"] = ["class_type": "SamplerCustomAdvanced", "inputs": ["noise": ["11", 0], "guider": ["14", 0], "sampler": ["12", 0],
                                                                        "sigmas": ["13", 0], "latent_image": ["7", 0]]]
        }
        return g
    }
}

enum ImageAspect: String, CaseIterable, Identifiable {
    case square = "1:1 方形"
    case wide = "16:9 横屏"
    case tall = "9:16 竖屏"
    case classic = "4:3"
    case portrait = "3:4"
    var id: String { rawValue }
    var ratio: Double {
        switch self {
        case .square: return 1
        case .wide: return 16.0 / 9
        case .tall: return 9.0 / 16
        case .classic: return 4.0 / 3
        case .portrait: return 3.0 / 4
        }
    }
}

enum ImageQuality: String, CaseIterable, Identifiable {
    case standard = "标准（约 100 万像素）"
    case high = "高清（约 200 万像素）"
    var id: String { rawValue }
    var megapixels: Double { self == .standard ? 1.05 : 2.1 }

    func size(_ a: ImageAspect) -> (Int, Int) {
        let px = megapixels * 1_000_000
        let w = (px * a.ratio).squareRoot(), h = w / a.ratio
        func r32(_ v: Double) -> Int { max(256, Int((v / 32).rounded()) * 32) }
        return (r32(w), r32(h))
    }
}

// MARK: - 检测 / 下载 / 推荐

@MainActor
final class ImageModels: ObservableObject {
    static let shared = ImageModels()

    @Published var selectedId: String = UserDefaults.standard.string(forKey: "imageModel") ?? "" {
        didSet { UserDefaults.standard.set(selectedId, forKey: "imageModel") }
    }
    @Published var installed: [String: [String: String]] = [:]
    @Published var downloading: [String: DownloadJob] = [:]

    var selected: ImageModelSpec { ImageModelSpec.all.first { $0.id == selectedId } ?? ImageModelSpec.all[0] }

    func scan() {
        var out: [String: [String: String]] = [:]
        let roots = VideoModels.modelRoots
        for spec in ImageModelSpec.all {
            var found: [String: String] = [:]
            for f in spec.files {
                outer: for n in f.names {
                    for root in roots {
                        for d in VideoModels.altDirs(f.dir) {
                            let p = root.appendingPathComponent(d).appendingPathComponent(n)
                            if let a = try? FileManager.default.attributesOfItem(atPath: p.path), (a[.size] as? Int64 ?? 0) > 1_000_000 {
                                found[f.id] = n
                                break outer
                            }
                        }
                    }
                }
            }
            out[spec.id] = found
        }
        installed = out
        if ImageModelSpec.all.first(where: { $0.id == selectedId }) == nil {
            selectedId = (ImageModelSpec.all.filter { isReady($0) }.max { $0.quality < $1.quality } ?? recommended ?? ImageModelSpec.all[0]).id
        }
    }

    func isReady(_ s: ImageModelSpec) -> Bool { s.files.allSatisfy { installed[s.id]?[$0.id] != nil } }

    func missingGB(_ s: ImageModelSpec) -> Double {
        s.files.filter { installed[s.id]?[$0.id] == nil }.reduce(0) { $0 + $1.sizeGB }
    }

    func fit(_ s: ImageModelSpec) -> VideoModels.Fit {
        if !Recommender.appleSilicon { return .unsupported }
        let ram = Recommender.ramGB
        if ram >= s.ramGB { return .good }
        if ram >= s.ramGB * 0.75 { return .tight }
        return .tooBig
    }

    var recommended: ImageModelSpec? {
        ImageModelSpec.all.filter { fit($0) == .good }.max { $0.quality < $1.quality }
            ?? ImageModelSpec.all.filter { fit($0) == .tight }.max { $0.quality < $1.quality }
    }

    func download(_ s: ImageModelSpec) {
        guard downloading[s.id] == nil || downloading[s.id]!.done || downloading[s.id]!.failed,
              let root = VideoModels.downloadRoot else { return }
        let missing = s.files.filter { installed[s.id]?[$0.id] == nil }
        guard !missing.isEmpty else { return }
        let job = DownloadJob(id: s.name)
        job.total = Int64(missing.reduce(0) { $0 + $1.sizeGB } * 1e9)
        job.state = String(localized: "下载中…")
        downloading[s.id] = job
        job.task = Task {
            do {
                for f in missing {
                    let dest = root.appendingPathComponent(f.dir).appendingPathComponent(f.names[0])
                    try await ModelDownloader.fetch(url: URL(string: f.url)!, to: dest) { got in
                        Task { @MainActor in job.parts[f.id] = got; job.update() }
                    }
                    job.finishedBytes += Int64(f.sizeGB * 1e9)
                    job.parts[f.id] = nil
                    job.update()
                }
                job.done = true
                job.state = String(localized: "完成")
                scan()
            } catch {
                if !job.failed {
                    job.failed = true
                    job.state = String(localized: "下载失败：\(error.localizedDescription)（再点下载会接着下）")
                }
            }
        }
    }

    func cancel(_ s: ImageModelSpec) {
        downloading[s.id]?.task?.cancel()
        downloading[s.id]?.failed = true
        downloading[s.id]?.state = String(localized: "已取消")
    }
}

// MARK: - 生成

struct ImageItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var prompt: String
    var path: String
    var width: Int
    var height: Int
    var seed: Int
    var model: String
    var elapsed: Double
    var date = Date()
}

@MainActor
final class ImageStore: ObservableObject {
    static let shared = ImageStore()

    @Published var items: [ImageItem] = []
    @Published var selected: UUID?
    @Published var prompt = UserDefaults.standard.string(forKey: "imagePrompt") ?? "" {
        didSet { UserDefaults.standard.set(prompt, forKey: "imagePrompt") }
    }
    @Published var aspect: ImageAspect = .square
    @Published var quality: ImageQuality = .standard
    @Published var count = 1
    @Published var randomSeed = true
    @Published var seed = 42
    @Published var running = false
    @Published var stage = ""
    @Published var step = 0
    @Published var steps = 0
    @Published var startedAt: Date?
    @Published var estimateSeconds: Double = 0
    @Published var error: String?
    @Published var improving = false
    private var loadedSpec: String?
    private var socket: URLSessionWebSocketTask?
    private let file = AppPaths.dataFile("images.json")

    init() {
        if let list = SafeJSON.load([ImageItem].self, from: file) {
            items = list.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        selected = items.first?.id
    }

    func save() {
        SafeJSON.save(items, to: file)
    }

    static var folder: URL { AppPaths.images }

    var currentEstimate: Double {
        let (w, h) = quality.size(aspect)
        let spec = ImageModels.shared.selected
        return spec.estimate(w: w, h: h, count: count, loaded: loadedSpec == spec.id)
    }

    /// 生成图片, 返回生成好的图片 (失败返回空, 错误在 error 里)
    @discardableResult
    func generate(prompt p: String? = nil, aspect a: ImageAspect? = nil, quality q: ImageQuality? = nil, count n: Int? = nil,
                  model: String? = nil, seed fixedSeed: Int? = nil) async -> [ImageItem] {
        guard !running else { error = String(localized: "已经有图片在生成了"); return [] }
        let engine = ComfyEngine.shared
        let models = ImageModels.shared
        let text = (p ?? prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { error = String(localized: "请先写下想要的画面"); return [] }
        models.scan()
        let spec = model.flatMap { id in ImageModelSpec.all.first { $0.id == id } } ?? models.selected
        guard models.isReady(spec) else {
            error = String(localized: "还没有下载 \(spec.name) 模型。请在「图片模型」里点下载。")
            return []
        }
        guard !VideoStore.shared.running else { error = String(localized: "视频正在生成，请等它完成后再画图"); return [] }
        let (w, h) = (q ?? quality).size(a ?? aspect)
        let num = max(1, min(4, n ?? count))
        let s = fixedSeed ?? (randomSeed ? Int.random(in: 1...999_999_999) : seed)
        running = true; error = nil; step = 0; steps = 0; startedAt = Date()
        defer { running = false; startedAt = nil; stage = "" }
        estimateSeconds = spec.estimate(w: w, h: h, count: num, loaded: loadedSpec == spec.id)

        stage = String(localized: "启动图片引擎…")
        await engine.start()
        guard engine.online else { error = engine.message ?? String(localized: "ComfyUI 没有启动"); return [] }
        // 统一调度内存: 模型还没加载时, 内存不够才请最久没用的模型让位 (够就都留着, 切回对话不用重新加载)
        if loadedSpec != spec.id {
            let broker = MemoryBroker.shared
            if VideoStore.shared.loadedId != nil || loadedSpec != nil { await broker.evict(.comfy) }   // ComfyUI 里换模型
            let need = spec.files.reduce(0) { $0 + $1.sizeGB } * 1.15
            if !broker.fits(need) { stage = String(localized: "腾出内存…") }
            await broker.makeRoom(need, for: .comfy)
        }
        MemoryBroker.shared.touch(.comfy)
        guard let g = spec.graph(prompt: text, width: w, height: h, count: num, seed: s, files: models.installed[spec.id] ?? [:]) else {
            error = String(localized: "模型文件不完整"); return []
        }

        let clientId = UUID().uuidString
        listen(clientId: clientId)
        defer { socket?.cancel(with: .goingAway, reason: nil); socket = nil }
        stage = String(localized: "提交任务…")
        var req = URLRequest(url: engine.base.appendingPathComponent("prompt"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["prompt": g, "client_id": clientId])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let pid = obj["prompt_id"] as? String else {
            error = String(localized: "ComfyUI 没有接受这个任务")
            return []
        }
        stage = loadedSpec == spec.id ? String(localized: "准备中…") : String(localized: "加载图片模型（第一次要几十秒）…")

        while true {
            try? await Task.sleep(for: .seconds(1))
            guard let (hd, _) = try? await URLSession.shared.data(from: engine.base.appendingPathComponent("history/\(pid)")),
                  let hist = (try? JSONSerialization.jsonObject(with: hd) as? [String: Any])?[pid] as? [String: Any] else { continue }
            let status = hist["status"] as? [String: Any]
            if status?["status_str"] as? String == "error" {
                let msgs = status?["messages"] as? [[Any]] ?? []
                let detail = msgs.first { ($0.first as? String) == "execution_error" }.flatMap { ($0.last as? [String: Any])?["exception_message"] as? String }
                error = String(localized: "生成失败：\(detail ?? String(localized: "未知错误"))")
                return []
            }
            guard status?["completed"] as? Bool == true else { continue }
            let files = ((hist["outputs"] as? [String: Any])?["9"] as? [String: Any])?["images"] as? [[String: Any]] ?? []
            var made: [ImageItem] = []
            let elapsed = Date().timeIntervalSince(startedAt ?? Date())
            for f in files {
                guard let fname = f["filename"] as? String else { continue }
                let sub = f["subfolder"] as? String ?? ""
                // 不覆盖以前的作品; 从 ComfyUI 输出文件夹挪过来 (不留两份)
                let dest = AppPaths.unique(fname, in: Self.folder)
                if let out = ComfyEngine.findInstall()?.output?.appendingPathComponent(sub).appendingPathComponent(fname),
                   FileManager.default.fileExists(atPath: out.path) {
                    ComfyEngine.takeOutput(out, to: dest)
                }
                if !FileManager.default.fileExists(atPath: dest.path) {
                    var c = URLComponents(url: engine.base.appendingPathComponent("view"), resolvingAgainstBaseURL: false)!
                    c.queryItems = [URLQueryItem(name: "filename", value: fname), URLQueryItem(name: "subfolder", value: sub),
                                    URLQueryItem(name: "type", value: "output")]
                    if let (vd, _) = try? await URLSession.shared.data(from: c.url!) { try? vd.write(to: dest) }
                }
                guard FileManager.default.fileExists(atPath: dest.path) else { continue }
                made.append(ImageItem(prompt: text, path: dest.path, width: w, height: h, seed: s, model: spec.name, elapsed: elapsed / Double(max(files.count, 1))))
            }
            guard !made.isEmpty else { error = String(localized: "没有找到生成的图片"); return [] }
            items.insert(contentsOf: made, at: 0)
            selected = made.first?.id
            save()
            loadedSpec = spec.id
            if !NSApp.isActive { Notifier.send(title: String(localized: "图片生成好了"), body: String(text.prefix(80)), link: "toolula://image/\(made[0].id.uuidString)") }
            return made
        }
    }

    func cancel() { Task { await ComfyEngine.shared.interrupt() } }

    func freeMemory() { Task { await ComfyEngine.shared.free(); loadedSpec = nil } }

    // 预热 (ComfyWarmup) 用
    func isLoaded(_ id: String) -> Bool { loadedSpec == id }
    var loadedId: String? { loadedSpec }
    func markLoaded(_ id: String) { loadedSpec = id }
    func modelsUnloaded() { loadedSpec = nil }

    func delete(_ item: ImageItem) {
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
        items.removeAll { $0.id == item.id }
        if selected == item.id { selected = items.first?.id }
        save()
    }

    private func listen(clientId: String) {
        let url = URL(string: "ws://127.0.0.1:\(ComfyEngine.shared.port)/ws?clientId=\(clientId)")!
        let ws = URLSession.shared.webSocketTask(with: url)
        socket = ws
        ws.resume()
        func receive() {
            ws.receive { [weak self] result in
                guard case .success(let msg) = result else { return }
                if case .string(let s) = msg, let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] {
                    let type = obj["type"] as? String ?? ""
                    let data = obj["data"] as? [String: Any] ?? [:]
                    Task { @MainActor in self?.handle(type, data) }
                }
                receive()
            }
        }
        receive()
    }

    private func handle(_ type: String, _ data: [String: Any]) {
        switch type {
        case "executing":
            switch data["node"] as? String {
            case "5": stage = String(localized: "理解提示词…")
            case "8": stage = String(localized: "画图中…")
            case "10", "9": stage = String(localized: "保存图片…")
            default: break
            }
        case "progress":
            if let v = data["value"] as? Int, let m = data["max"] as? Int, m <= 60 {
                step = v; steps = m
                stage = String(localized: "画图中：第 \(v)/\(m) 步")
            }
        default: break
        }
    }

    /// 用对话模型把想法扩写成详细的图片提示词
    func improvePrompt() {
        let idea = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idea.isEmpty, !improving else { return }
        improving = true
        Task {
            defer { improving = false }
            let sys = """
            You write prompts for a text-to-image model. Expand the user's idea into ONE detailed English paragraph (60-120 words): \
            subject, composition, lighting, colors, style, camera/lens if photographic. If the user wants text in the image, \
            keep that exact text in double quotes (do not translate it). Output only the prompt.
            """
            let msgs: [[String: Any]] = [["role": "system", "content": sys], ["role": "user", "content": idea]]
            if let r = try? await LLMClient.stream(model: ModelManager.shared.chatModel, messages: msgs, tools: nil, reasoning: "none", onDelta: { _, _ in }) {
                let t = r.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { prompt = t }
            }
        }
    }
}

// MARK: - 界面

struct ImageView: View {
    @ObservedObject var queue = GenQueue.shared
    @State private var showBatch = false
    @ObservedObject var store = ImageStore.shared
    @ObservedObject var engine = ComfyEngine.shared
    @ObservedObject var models = ImageModels.shared
    @EnvironmentObject var app: AppState
    @EnvironmentObject var photos: Store

    var body: some View {
        HStack(spacing: 0) {
            history.frame(width: 250)
            Divider()
            preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            settings.frame(width: 360)
        }
        .task { models.scan(); await engine.check() }
        .onAppear { ComfyWarmup.enter("image") }
        .onDisappear { ComfyWarmup.leave("image") }
        .onChange(of: models.selectedId) { ComfyWarmup.enter("image") }
    }

    var history: some View {
        VStack(spacing: 0) {
            HStack {
                Text("生成的图片").font(.headline)
                Spacer()
                Button { NSWorkspace.shared.open(ImageStore.folder) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help(Text("在访达中打开图片文件夹")).accessibilityLabel(Text("在访达中打开图片文件夹"))
            }
            .padding(12)
            ScrollView {
                if store.items.isEmpty {
                    Text("还没有生成过图片").foregroundStyle(.secondary).padding(.top, 20)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(store.items) { it in
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(ImageThumb(path: it.path))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(store.selected == it.id ? Color.toolula : .clear, lineWidth: 3))
                            .onTapGesture { store.selected = it.id }
                            .contextMenu { menu(it) }
                    }
                }
                .padding(.horizontal, 10)
            }
        }
    }

    @ViewBuilder func menu(_ it: ImageItem) -> some View {
        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: it.path)]) }
        Button("用这个提示词") { store.prompt = it.prompt }
        Button("在修图中打开") { app.section = .photo; photos.add(urls: [URL(fileURLWithPath: it.path)]) }
        Button("作为视频的第一帧") { VideoStore.shared.firstFrame = URL(fileURLWithPath: it.path); app.section = .video }
        Divider()
        Button("删除图片", role: .destructive) { store.delete(it) }
    }

    @ViewBuilder var preview: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if store.running {
                VStack(spacing: 14) {
                    ProgressView(value: store.steps > 0 ? Double(store.step) / Double(store.steps) : nil).frame(width: 320)
                    Text(store.stage).font(.headline)
                    if let t = store.startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text("已用 \(Int(ctx.date.timeIntervalSince(t))) 秒 · 预计约 \(Int(store.estimateSeconds.rounded())) 秒")
                                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    Button("停止") { store.cancel() }
                }
            } else if let it = store.items.first(where: { $0.id == store.selected }), let img = NSImage(contentsOfFile: it.path) {
                VStack(spacing: 10) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8)).shadow(radius: 8)
                        .onDrag { NSItemProvider(contentsOf: URL(fileURLWithPath: it.path)) ?? NSItemProvider() }
                    Text(it.prompt).font(.callout).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    HStack(spacing: 10) {
                        Text("\(it.model) · \(String(it.width))×\(String(it.height)) · 种子 \(String(it.seed)) · \(Int(it.elapsed)) 秒")
                            .font(.caption).foregroundStyle(.tertiary)
                        Spacer()
                        Button("在修图中打开") { app.section = .photo; photos.add(urls: [URL(fileURLWithPath: it.path)]) }
                        Button("作为视频的第一帧") { VideoStore.shared.firstFrame = URL(fileURLWithPath: it.path); app.section = .video }
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: it.path)]) } label: { Image(systemName: "folder") }
                            .accessibilityLabel(Text("在访达中显示"))
                    }
                    .controlSize(.small)
                }
                .padding(24)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "paintbrush.pointed").font(.system(size: 48)).foregroundStyle(Color.toolula)
                    Text("AI 绘图").font(.title.bold())
                    Text("写下想要的画面，本机的图片模型几十秒就能画出来。\n画好的图可以直接拿去修图，或者作为视频的第一帧。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
            }
        }
    }

    var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !ComfyEngine.installed {
                    GroupBox {
                        HStack {
                            Text("还没有图片引擎（ComfyUI）。设置向导可以一键安装。").font(.caption).foregroundStyle(.orange)
                            Spacer()
                            Button("打开设置向导") { SetupWizardState.shared.show = true }.controlSize(.small)
                        }.padding(4)
                    }
                }
                GroupBox {
                    ImageModelPicker().padding(2)
                } label: { Label("图片模型", systemImage: "square.stack.3d.up") }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $store.prompt)
                            .font(.body).frame(height: 130)
                            .scrollContentBackground(.hidden).padding(4)
                            .background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        HStack {
                            Text("中文英文都可以；想在图里出现的文字用引号括起来").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { store.improvePrompt() } label: {
                                if store.improving { ProgressView().controlSize(.mini) } else { Label("AI 优化", systemImage: "wand.and.stars") }
                            }
                            .controlSize(.small).disabled(store.prompt.isEmpty || store.improving || store.running)
                            .help(Text("让对话模型把你的想法扩写成详细的图片提示词"))
                        }
                    }.padding(4)
                } label: { Label("想要什么画面", systemImage: "text.quote") }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("画面比例", selection: $store.aspect) {
                            ForEach(ImageAspect.allCases) { Text($0.rawValue.locKey).tag($0) }
                        }
                        .accessibilityLabel(Text("画面比例"))
                        Picker("清晰度", selection: $store.quality) {
                            ForEach(ImageQuality.allCases) { Text($0.rawValue.locKey).tag($0) }
                        }
                        .accessibilityLabel(Text("清晰度"))
                        Stepper("一次画 \(store.count) 张", value: $store.count, in: 1...4)
                        HStack {
                            Toggle("随机种子", isOn: $store.randomSeed)
                            if !store.randomSeed { TextField("", value: $store.seed, format: .number).frame(width: 110) }
                        }
                        let (w, h) = store.quality.size(store.aspect)
                        Text("\(String(w)) × \(String(h)) · 预计约 \(Int(store.currentEstimate.rounded())) 秒").font(.caption).foregroundStyle(.secondary)
                    }.padding(4)
                } label: { Label("设置", systemImage: "slider.horizontal.3") }

                if let e = store.error {
                    Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 生成中再点: 排到队列后面
                HStack {
                    Button { GenQueue.shared.addImages([store.prompt]) } label: {
                        Label(queue.busy ? "加入队列" : "生成图片", systemImage: queue.busy ? "text.badge.plus" : "paintbrush.pointed").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(Color.toolula).controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(store.prompt.trimmingCharacters(in: .whitespaces).isEmpty || !models.isReady(models.selected))
                    Button { showBatch = true } label: { Image(systemName: "list.bullet.rectangle") }
                        .controlSize(.large)
                        .help(Text("批量：每行一个提示词，一个接一个生成"))
                        .accessibilityLabel(Text("批量画图"))
                        .disabled(!models.isReady(models.selected))
                }
                .sheet(isPresented: $showBatch) { BatchPromptSheet(kind: .image, isPresented: $showBatch) }
                QueueHint(kind: .image)
                if engine.online {
                    Button("释放图片模型内存") { store.freeMemory() }.controlSize(.small)
                }
            }
            .padding(14)
        }
    }
}

struct ImageThumb: View {
    let path: String
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            Color.black.opacity(0.15)
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
        }
        .task(id: path) {
            let p = path
            let cg = await Task.detached { () -> CGImage? in
                guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: 300] as CFDictionary)
            }.value
            if let cg { image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
        }
    }
}

/// 选择图片模型 (自动检测 + 按这台电脑推荐 + 下载)
struct ImageModelPicker: View {
    @ObservedObject var im = ImageModels.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !Recommender.appleSilicon {
                Text("本地图片模型需要 Apple 芯片的 Mac。").font(.caption).foregroundStyle(.orange)
            } else if let r = im.recommended {
                Text("这台电脑（\(Int(Recommender.ramGB)) GB 内存）推荐：\(r.name)").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("这台电脑内存较小，跑本地图片模型会很慢。").font(.caption).foregroundStyle(.orange)
            }
            ForEach(ImageModelSpec.all) { s in row(s) }
        }
        .onAppear { im.scan() }
    }

    @ViewBuilder func row(_ s: ImageModelSpec) -> some View {
        let isSel = im.selectedId == s.id
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSel ? "largecircle.fill.circle" : "circle").foregroundStyle(isSel ? Color.toolula : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.name).bold().lineLimit(1)
                    HStack(spacing: 6) {
                        if s.textGood { pill("会写字", .blue) }
                        switch im.fit(s) {
                        case .good: pill("能流畅运行", .green)
                        case .tight: pill("能运行，内存较紧", .orange)
                        case .tooBig: pill("内存不够", .red)
                        case .unsupported: pill("不支持", .gray)
                        }
                        if im.recommended?.id == s.id { pill("推荐", Color.toolula) }
                    }
                    Text(s.note.locKey).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { im.selectedId = s.id }
            HStack {
                Text(String(format: "%.1f GB", s.downloadGB)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if im.isReady(s) {
                    Label("已安装", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                } else if let job = im.downloading[s.id], !job.done && !job.failed {
                    DownloadMini(job: job)
                    Button("取消") { im.cancel(s) }.controlSize(.mini)
                } else {
                    if im.missingGB(s) < s.downloadGB - 0.05 {
                        Text("还需下载 \(String(format: "%.1f", im.missingGB(s))) GB").font(.caption).foregroundStyle(.secondary)
                    }
                    Button((im.downloading[s.id]?.failed == true ? "继续下载" : "下载").locKey) { im.download(s) }
                        .controlSize(.small)
                        .disabled(im.fit(s) == .unsupported || VideoModels.downloadRoot == nil)
                }
                if let job = im.downloading[s.id], job.failed { Text(job.state).font(.caption2).foregroundStyle(.orange).lineLimit(2) }
            }
            .padding(.leading, 26)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSel ? Color.toolula.opacity(0.08) : Color.primary.opacity(0.03)))
    }
}
