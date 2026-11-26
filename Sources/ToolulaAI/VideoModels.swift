import Foundation
import SwiftUI

/// 视频模型需要的一个文件
struct VideoModelFile: Identifiable, Hashable {
    let dir: String            // ComfyUI models 下的文件夹
    let names: [String]        // 可以接受的文件名 (按优先级), 第一个是下载用的
    let url: String            // 下载地址
    let sizeGB: Double
    var optional = false
    var id: String { dir + "/" + names[0] }
}

/// 一个视频模型 (通过 ComfyUI 运行)
struct VideoModelSpec: Identifiable, Hashable {
    let id: String
    let name: String
    let note: String
    let audio: Bool
    let ramGB: Double          // 舒服运行需要的内存
    let files: [VideoModelFile]
    let qualities: [VideoQuality]
    let maxSeconds: Double
    let quality: Int           // 画质排序

    var downloadGB: Double { files.filter { !$0.optional }.reduce(0) { $0 + $1.sizeGB } }
    /// 加速 LoRA
    var loraFile: VideoModelFile? { files.first { $0.dir == "loras" } }
    /// 出预览用的轻量解码器
    var previewDecoder: VideoModelFile? { files.first { $0.dir == "vae_approx" } }
    /// 更快的完整解码器 (H3 的 Sol VAE)
    var fastDecoder: VideoModelFile? { files.first { $0.dir == "vae" && $0.names[0].contains("sol_vae") } }

    static func == (a: VideoModelSpec, b: VideoModelSpec) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    static let h3 = VideoModelSpec(
        id: "minimax-h3", name: "MiniMax H3", note: "画质最好的开源视频模型，画面和声音一起生成",
        audio: true, ramGB: 96,
        files: [
            VideoModelFile(dir: "diffusion_models", names: ["minimax_h3_fl2va_pruned_bf16.safetensors", "minimax_h3_fl2va_bf16.safetensors"],
                           url: "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/diffusion_models/minimax_h3_fl2va_pruned_bf16.safetensors", sizeGB: 40.2),
            VideoModelFile(dir: "text_encoders", names: ["qwen3vl_32b_minimax_h3_bf16.safetensors"],
                           url: "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/text_encoders/qwen3vl_32b_minimax_h3_bf16.safetensors", sizeGB: 51.5),
            VideoModelFile(dir: "vae", names: ["minimax_h3_video_vae_fp16.safetensors"],
                           url: "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_video_vae_fp16.safetensors", sizeGB: 5.2),
            VideoModelFile(dir: "vae", names: ["minimax_h3_audio_vae_fp32.safetensors"],
                           url: "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_audio_vae_fp32.safetensors", sizeGB: 0.6),
            VideoModelFile(dir: "loras", names: ["minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors", "minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors"],
                           url: "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/loras/minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors", sizeGB: 2.0, optional: true),
            // 加速组件 (可选): 轻量解码器几秒出预览; Sol-H3 VAE 是官方蒸馏的解码器, 画质接近原版, 解码快 4~7 倍
            // (ComfyUI 按文件名识别轻量解码器, 名字必须正好是 taeh3.safetensors)
            VideoModelFile(dir: "vae_approx", names: ["taeh3.safetensors"],
                           url: "https://huggingface.co/OzzyGT/taeh3/resolve/main/taeh3.safetensors", sizeGB: 0.02, optional: true),
            VideoModelFile(dir: "vae", names: ["minimax_h3_sol_vae_fp16.safetensors"],
                           url: "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_sol_vae_fp16.safetensors", sizeGB: 3.6, optional: true),
        ],
        qualities: [.p480, .p576, .p720, .p768], maxSeconds: 15, quality: 100)

    static let wan5b = VideoModelSpec(
        id: "wan22-5b", name: "Wan 2.2 5B", note: "轻量的开源视频模型，32GB 内存也能跑（没有声音）",
        audio: false, ramGB: 32,
        files: [
            VideoModelFile(dir: "diffusion_models", names: ["wan2.2_ti2v_5B_fp16.safetensors"],
                           url: "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_ti2v_5B_fp16.safetensors", sizeGB: 10.0),
            VideoModelFile(dir: "text_encoders", names: ["umt5_xxl_fp16.safetensors"],
                           url: "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp16.safetensors", sizeGB: 11.4),
            VideoModelFile(dir: "vae", names: ["wan2.2_vae.safetensors"],
                           url: "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan2.2_vae.safetensors", sizeGB: 1.4),
            // 4 步蒸馏加速 (Wan2.2-TI2V-5B-Turbo, Kijai 转成 LoRA): 不需要 CFG, 采样快约 10 倍
            VideoModelFile(dir: "loras", names: ["Wan22_TI2V_5B_Turbo_lora_rank_64_fp16.safetensors"],
                           url: "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Wan22-Turbo/Wan22_TI2V_5B_Turbo_lora_rank_64_fp16.safetensors", sizeGB: 0.33, optional: true),
            // 轻量解码器 (lightx2v LightTAE v2, 可选): 1~2 秒出预览。ComfyUI 按文件名识别, 必须叫 lighttaew2_2.safetensors
            VideoModelFile(dir: "vae_approx", names: ["lighttaew2_2.safetensors"],
                           url: "https://huggingface.co/lightx2v/Autoencoders/resolve/main/lighttaew2_2_v2.safetensors", sizeGB: 0.05, optional: true),
        ],
        qualities: [.p480, .p576, .p720], maxSeconds: 8, quality: 70)

    static let all: [VideoModelSpec] = [.h3, .wan5b]
}

// MARK: - 检测 / 下载 / 推荐

@MainActor
final class VideoModels: ObservableObject {
    static let shared = VideoModels()

    @Published var selectedId: String = UserDefaults.standard.string(forKey: "videoModel") ?? "" {
        didSet {
            UserDefaults.standard.set(selectedId, forKey: "videoModel")
            let vs = VideoStore.shared, s = selected
            if vs.seconds > s.maxSeconds { vs.seconds = s.maxSeconds }
            if !s.qualities.contains(vs.quality) { vs.quality = s.qualities.first! }
        }
    }
    @Published var installed: [String: [String: String]] = [:]   // 模型 id -> (文件 id -> 实际文件名)
    @Published var downloading: [String: DownloadJob] = [:]       // 模型 id -> 下载任务

    var selected: VideoModelSpec { VideoModelSpec.all.first { $0.id == selectedId } ?? VideoModelSpec.all[0] }

    /// ComfyUI 的模型文件夹 (Comfy Desktop 的共享文件夹 + 安装目录里的 models)
    static var modelRoots: [URL] {
        var roots: [URL] = []
        if ComfyEngine.simulateMissing { return ComfyEngine.managedInstall().map { [$0.dir.appendingPathComponent("ComfyUI/models")] } ?? [] }
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Comfy Desktop/instance-model-paths")
        for f in (try? FileManager.default.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)) ?? [] {
            if let y = try? String(contentsOf: f, encoding: .utf8),
               let line = y.split(separator: "\n").first(where: { $0.contains("base_path:") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }) {
                let p = line.split(separator: ":", maxSplits: 1).last.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) } ?? ""
                if !p.isEmpty { roots.append(URL(fileURLWithPath: p)) }
            }
        }
        if let inst = ComfyEngine.findInstall() { roots.append(inst.dir.appendingPathComponent("ComfyUI/models")) }
        return roots
    }

    /// 下载到哪里 (第一个共享模型文件夹)
    static var downloadRoot: URL? { modelRoots.first }

    static func altDirs(_ dir: String) -> [String] {
        switch dir {
        case "diffusion_models": return ["diffusion_models", "unet"]
        case "text_encoders": return ["text_encoders", "clip"]
        default: return [dir]
        }
    }

    func scan() {
        var out: [String: [String: String]] = [:]
        for spec in VideoModelSpec.all {
            var found: [String: String] = [:]
            for f in spec.files {
                outer: for name in f.names {
                    for root in Self.modelRoots {
                        for d in Self.altDirs(f.dir) {
                            let p = root.appendingPathComponent(d).appendingPathComponent(name)
                            if let a = try? FileManager.default.attributesOfItem(atPath: p.path), (a[.size] as? Int64 ?? 0) > 1_000_000 {
                                found[f.id] = name
                                break outer
                            }
                        }
                    }
                }
            }
            out[spec.id] = found
        }
        installed = out
        // 默认选: 已安装且适合这台电脑的里面画质最好的; 都没装就选推荐的
        // 只在还没选过 (或选的模型已不存在) 时自动选; 用户选了还没下载的模型, 保留他的选择
        if VideoModelSpec.all.first(where: { $0.id == selectedId }) == nil {
            if let best = VideoModelSpec.all.filter({ isReady($0) }).sorted(by: { $0.quality > $1.quality }).first {
                selectedId = best.id
            } else if let rec = recommended {
                selectedId = rec.id
            }
        }
    }

    func isReady(_ s: VideoModelSpec) -> Bool {
        s.files.filter { !$0.optional }.allSatisfy { installed[s.id]?[$0.id] != nil }
    }

    func file(_ s: VideoModelSpec, _ f: VideoModelFile) -> String? { installed[s.id]?[f.id] }

    /// 还没下载的可选组件 (加速 LoRA、轻量解码器等)
    func missingOptionalGB(_ s: VideoModelSpec) -> Double {
        s.files.filter { installed[s.id]?[$0.id] == nil && $0.optional }.reduce(0) { $0 + $1.sizeGB }
    }

    func missingGB(_ s: VideoModelSpec) -> Double {
        s.files.filter { installed[s.id]?[$0.id] == nil && !$0.optional }.reduce(0) { $0 + $1.sizeGB }
    }

    // MARK: 推荐

    enum Fit { case good, tight, tooBig, unsupported }

    func fit(_ s: VideoModelSpec) -> Fit {
        if !Recommender.appleSilicon { return .unsupported }
        let ram = Recommender.ramGB
        if ram >= s.ramGB { return .good }
        if ram >= s.ramGB * 0.75 { return .tight }
        return .tooBig
    }

    /// 这台电脑上最值得用的视频模型
    var recommended: VideoModelSpec? {
        VideoModelSpec.all.filter { fit($0) == .good }.sorted { $0.quality > $1.quality }.first
            ?? VideoModelSpec.all.filter { fit($0) == .tight }.sorted { $0.quality > $1.quality }.first
    }

    // MARK: 下载

    func download(_ s: VideoModelSpec) {
        guard downloading[s.id] == nil || downloading[s.id]!.done || downloading[s.id]!.failed,
              let root = Self.downloadRoot else { return }
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

    func cancel(_ s: VideoModelSpec) {
        downloading[s.id]?.task?.cancel()
        downloading[s.id]?.failed = true
        downloading[s.id]?.state = String(localized: "已取消")
    }
}

// MARK: - 工作流 (ComfyUI API 格式)

struct VideoJobParams {
    let prompt: String
    let width: Int
    let height: Int
    let seconds: Double
    let seed: Int
    let turbo: Bool
    let firstFrame: String?    // 已上传到 ComfyUI 的文件名
}

extension VideoModelSpec {
    /// 帧数 (各模型要求的帧数网格不同)
    func frames(_ seconds: Double) -> Int {
        switch id {
        case "wan22-5b":   // 24fps, 4k+1
            let n = max(5, Int((seconds * 24).rounded()))
            return n - (n - 1) % 4
        default:            // H3: 24fps, 17k+5
            return VideoMath.frames(seconds)
        }
    }

    func steps(turbo: Bool, lora: String?) -> Int {
        switch id {
        case "wan22-5b": return turbo && lora != nil ? 4 : 20
        default: return turbo && lora != nil ? ((lora ?? "").contains("8step") ? 8 : 4) : 20
        }
    }

    /// 预计时间 (分钟). H3 依据实测: 864×480、5 秒、4 步采样约 9 分钟
    /// fastConv: ComfyUI 是 Toolula 用启动包装启动的 (conv3d 加速); fastVAE: H3 装了 Sol VAE
    func estimate(w: Int, h: Int, frames: Int, steps: Int, loaded: Bool, fastConv: Bool = false, fastVAE: Bool = false) -> Double {
        let work = Double(w * h * frames) / Double(864 * 480 * 124)
        switch id {
        case "wan22-5b":
            // 实测 M3 Max: 864×480×121 帧, 4 步加速 = 采样 2.15 分钟; 解码 6.9 分钟 (conv3d 加速后 1.8 分钟)
            let cfgFactor = steps <= 4 ? 0.5 : 1.0      // 加速模式 CFG=1, 每步只算一次
            return 4.4 * pow(work, 1.2) * Double(steps) / 4 * cfgFactor + (fastConv ? 1.8 : 6.9) * work + (loaded ? 0.2 : 0.9)
        default:
            return VideoMath.estimate(w: w, h: h, frames: frames, steps: steps, loaded: loaded, fastVAE: fastVAE)
        }
    }

    func graph(_ p: VideoJobParams, files: [String: String]) -> [String: Any]? {
        func name(_ i: Int) -> String? { files[self.files[i].id] }
        let lora = loraFile.flatMap { files[$0.id] }
        switch id {
        case "wan22-5b":
            guard let unet = name(0), let te = name(1), let vae = name(2) else { return nil }
            let turbo = p.turbo && lora != nil
            var latent: [String: Any] = ["vae": ["3", 0], "width": p.width, "height": p.height, "length": frames(p.seconds), "batch_size": 1]
            var g: [String: Any] = [
                "1": ["class_type": "UNETLoader", "inputs": ["unet_name": unet, "weight_dtype": "default"]],
                "2": ["class_type": "CLIPLoader", "inputs": ["clip_name": te, "type": "wan", "device": "default"]],
                "3": ["class_type": "VAELoader", "inputs": ["vae_name": vae]],
                "4": ["class_type": "ModelSamplingSD3", "inputs": ["model": turbo ? ["11", 0] : ["1", 0], "shift": 8.0]],
                "5": ["class_type": "CLIPTextEncode", "inputs": ["clip": ["2", 0], "text": p.prompt]],
                "6": ["class_type": "CLIPTextEncode", "inputs": ["clip": ["2", 0], "text": Self.wanNegative]],
                // 加速: 4 步、CFG 1 (蒸馏过, 不需要负面提示词的引导, 每步也只算一次)
                "8": ["class_type": "KSampler", "inputs": ["model": ["4", 0], "positive": ["5", 0], "negative": ["6", 0], "latent_image": ["7", 0],
                                                           "seed": p.seed, "steps": turbo ? 4 : 20, "cfg": turbo ? 1.0 : 5.0,
                                                           "sampler_name": turbo ? "euler" : "uni_pc",
                                                           "scheduler": "simple", "denoise": 1.0]],
                "9": ["class_type": "VAEDecode", "inputs": ["samples": ["8", 0], "vae": ["3", 0]]],
                "15": ["class_type": "CreateVideo", "inputs": ["images": ["9", 0], "fps": 24]],
                "16": ["class_type": "SaveVideo", "inputs": ["video": ["15", 0], "filename_prefix": "Toolula/Wan22", "format": "auto", "codec": "auto"]],
            ]
            if turbo, let lora {
                g["11"] = ["class_type": "LoraLoaderModelOnly", "inputs": ["model": ["1", 0], "lora_name": lora, "strength_model": 1.0]]
            }
            if let img = p.firstFrame {
                g["10"] = ["class_type": "LoadImage", "inputs": ["image": img]]
                latent["start_image"] = ["10", 0]
            }
            g["7"] = ["class_type": "Wan22ImageToVideoLatent", "inputs": latent]
            return g

        default: // MiniMax H3 (和 ComfyUI 官方模板同样的节点)
            guard let unet = name(0), let clip = name(1), let vv = name(2), let av = name(3) else { return nil }
            let useTurbo = p.turbo && lora != nil
            var g: [String: Any] = [
                "1": ["class_type": "UNETLoader", "inputs": ["unet_name": unet, "weight_dtype": "default"]],
                "2": ["class_type": "CLIPLoader", "inputs": ["clip_name": clip, "type": "minimax", "device": "default"]],
                "3": ["class_type": "VAELoader", "inputs": ["vae_name": vv]],
                "4": ["class_type": "VAELoader", "inputs": ["vae_name": av]],
                "7": ["class_type": "RandomNoise", "inputs": ["noise_seed": p.seed]],
                "8": ["class_type": "KSamplerSelect", "inputs": ["sampler_name": "res_multistep"]],
                "12": ["class_type": "SamplerCustomAdvanced", "inputs": ["noise": ["7", 0], "guider": ["11", 0], "sampler": ["8", 0],
                                                                        "sigmas": ["9", 0], "latent_image": ["6", 1]]],
                "13": ["class_type": "VAEDecode", "inputs": ["samples": ["12", 0], "vae": ["3", 0]]],
                "14": ["class_type": "VAEDecodeAudio", "inputs": ["samples": ["12", 0], "vae": ["4", 0]]],
                "15": ["class_type": "CreateVideo", "inputs": ["images": ["13", 0], "audio": ["14", 0], "fps": 24]],
                "16": ["class_type": "SaveVideo", "inputs": ["video": ["15", 0], "filename_prefix": "Toolula/H3", "format": "auto", "codec": "auto"]],
            ]
            let model: [Any] = useTurbo ? ["5", 0] : ["1", 0]
            if useTurbo, let lora {
                g["5"] = ["class_type": "LoraLoaderModelOnly", "inputs": ["model": ["1", 0], "lora_name": lora, "strength_model": 1.0]]
            }
            var h3: [String: Any] = ["clip": ["2", 0], "vae": ["3", 0], "prompt": p.prompt, "width": p.width, "height": p.height,
                                     "length": frames(p.seconds)]
            if let img = p.firstFrame {
                g["10"] = ["class_type": "LoadImage", "inputs": ["image": img]]
                h3["first_frame"] = ["10", 0]
            }
            g["6"] = ["class_type": "MiniMaxH3ImageToVideo", "inputs": h3]
            // 有 Sol-H3 VAE 就用它解码 (编码首帧仍用原版 VAE)
            if let sol = fastDecoder.flatMap({ files[$0.id] }) {
                g["21"] = ["class_type": "VAELoader", "inputs": ["vae_name": sol]]
                g["13"] = ["class_type": "VAEDecode", "inputs": ["samples": ["12", 0], "vae": ["21", 0]]]
            }
            g["9"] = ["class_type": "BasicScheduler", "inputs": ["model": model, "scheduler": "simple",
                                                                 "steps": steps(turbo: p.turbo, lora: lora), "denoise": 1.0]]
            g["11"] = ["class_type": "BasicGuider", "inputs": ["model": model, "conditioning": ["6", 0]]]
            return g
        }
    }

    /// 预览工作流: 和完整工作流前半段完全相同 (ComfyUI 会缓存这些节点的结果, 之后提交完整工作流时不用重新采样),
    /// 只是用轻量解码器解码, 几秒就能看到结果。没装轻量解码器时返回 nil。
    func previewGraph(from full: [String: Any], files: [String: String]) -> [String: Any]? {
        guard let tae = previewDecoder.flatMap({ files[$0.id] }) else { return nil }
        var g = full
        let samples: [Any]
        var video: [String: Any] = ["fps": 24]
        if id == "wan22-5b" {
            samples = ["8", 0]
            for k in ["9", "15", "16"] { g[k] = nil }
        } else {
            samples = ["12", 0]
            video["audio"] = ["14", 0]
            for k in ["13", "15", "16", "21"] { g[k] = nil }
        }
        video["images"] = ["18", 0]
        g["17"] = ["class_type": "VAELoader", "inputs": ["vae_name": tae]]
        g["18"] = ["class_type": "VAEDecode", "inputs": ["samples": samples, "vae": ["17", 0]]]
        g["19"] = ["class_type": "CreateVideo", "inputs": video]
        g["20"] = ["class_type": "SaveVideo", "inputs": ["video": ["19", 0], "filename_prefix": "Toolula/preview", "format": "auto", "codec": "auto"]]
        return g
    }

    /// Wan 官方模板里的负面提示词
    static let wanNegative = "色调艳丽，过曝，静态，细节模糊不清，字幕，风格，作品，画作，画面，静止，整体发灰，最差质量，低质量，JPEG压缩残留，丑陋的，残缺的，多余的手指，画得不好的手部，画得不好的脸部，畸形的，毁容的，形态畸形的肢体，手指融合，静止不动的画面，杂乱的背景，三条腿，背景人很多，倒着走"
}

// MARK: - 界面: 选择视频模型

struct VideoModelPicker: View {
    @ObservedObject var vm = VideoModels.shared
    @ObservedObject var info = SystemInfo.shared

    static func sizeText(_ gb: Double) -> String { gb >= 1 ? String(format: "%.1f GB", gb) : "\(max(1, Int((gb * 1000).rounded()))) MB" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !Recommender.appleSilicon {
                Text("本地视频模型需要 Apple 芯片的 Mac。这台 Intel Mac 跑不动。").font(.caption).foregroundStyle(.orange)
            } else if let r = vm.recommended {
                Text("这台电脑（\(Int(Recommender.ramGB)) GB 内存）推荐：\(r.name)").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("这台电脑内存较小，跑本地视频模型会很慢或跑不动。").font(.caption).foregroundStyle(.orange)
            }
            ForEach(VideoModelSpec.all) { s in row(s) }
        }
    }

    @ViewBuilder func row(_ s: VideoModelSpec) -> some View {
        let ready = vm.isReady(s)
        let isSel = vm.selectedId == s.id
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSel ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSel ? Color.toolula : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.name).bold().lineLimit(1)
                    HStack(spacing: 6) {
                        if s.audio { pill("带声音", .purple) }
                        fitPill(s)
                        if vm.recommended?.id == s.id { pill("推荐", Color.toolula) }
                    }
                    Text(s.note.locKey).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { vm.selectedId = s.id }

            HStack {
                Text(String(format: "%.1f GB", s.downloadGB)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if ready {
                    Label("已安装", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    let extra = vm.missingOptionalGB(s)
                    if extra > 0 {
                        if let job = vm.downloading[s.id], !job.done && !job.failed {
                            DownloadMini(job: job)
                            Button("取消") { vm.cancel(s) }.controlSize(.mini)
                        } else {
                            Button("下载加速组件（\(Self.sizeText(extra))）") { vm.download(s) }
                                .controlSize(.small)
                                .help(Text("轻量解码器几秒就能出预览，并加快高清解码"))
                        }
                    }
                } else if let job = vm.downloading[s.id], !job.done && !job.failed {
                    DownloadMini(job: job)
                    Button("取消") { vm.cancel(s) }.controlSize(.mini)
                } else {
                    Text("还需下载 \(String(format: "%.1f", vm.missingGB(s))) GB").font(.caption).foregroundStyle(.secondary)
                    Button((vm.downloading[s.id]?.failed == true ? "继续下载" : "下载").locKey) { vm.download(s) }
                        .controlSize(.small)
                        .disabled(vm.fit(s) == .unsupported || VideoModels.downloadRoot == nil)
                }
                if let job = vm.downloading[s.id], job.failed { Text(job.state).font(.caption2).foregroundStyle(.orange).lineLimit(2) }
            }
            .padding(.leading, 26)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSel ? Color.toolula.opacity(0.08) : Color.primary.opacity(0.03)))
    }

    @ViewBuilder func fitPill(_ s: VideoModelSpec) -> some View {
        switch vm.fit(s) {
        case .good: pill("能流畅运行", .green)
        case .tight: pill("能运行，内存较紧", .orange)
        case .tooBig: pill("内存不够", .red)
        case .unsupported: pill("不支持", .gray)
        }
    }
}
