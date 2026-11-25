import AppKit
import AVFoundation
import Foundation
import SwiftUI

// MARK: - ComfyUI 引擎 (用来跑 MiniMax H3 视频模型)

@MainActor
final class ComfyEngine: ObservableObject {
    static let shared = ComfyEngine()

    @Published var online = false
    @Published var port = 8188
    @Published var starting = false
    @Published var message: String?
    @Published var unet: String?
    @Published var clip: String?
    @Published var videoVAE: String?
    @Published var audioVAE: String?
    @Published var lora: String?
    private var process: Process?

    var base: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var ready: Bool { online && unet != nil && clip != nil && videoVAE != nil && audioVAE != nil }
    var turboSteps: Int { (lora ?? "").contains("8step") ? 8 : 4 }

    /// Comfy Desktop 的安装信息 (用来在后台启动 ComfyUI, 不用打开 Comfy 窗口)
    struct Install { let dir: URL; let python: URL; let config: URL?; let input: URL?; let output: URL?; var managed = false }

    /// 自测用: 有 Comfy Desktop 也优先用 Toolula 自己装的
    nonisolated(unsafe) static var preferManaged = false
    nonisolated(unsafe) static var simulateMissing = false

    /// Toolula 自己装的 ComfyUI (设置向导装的)
    static func managedInstall() -> Install? {
        guard ComfySetup.installed else { return nil }
        // 如果这台电脑也有 Comfy Desktop, 顺便用上它已经下载的模型
        let desktopCfg = desktopInstall().flatMap(\.config)
        let src = ComfySetup.dir.appendingPathComponent("ComfyUI")
        return Install(dir: ComfySetup.dir, python: ComfySetup.python, config: desktopCfg,
                       input: src.appendingPathComponent("input"), output: src.appendingPathComponent("output"), managed: true)
    }

    static func findInstall() -> Install? {
        if simulateMissing { return managedInstall() }
        if preferManaged, let m = managedInstall() { return m }
        return desktopInstall() ?? managedInstall()
    }

    static func desktopInstall() -> Install? {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Comfy Desktop")
        guard let data = try? Data(contentsOf: support.appendingPathComponent("installations.json")),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        for inst in list {
            guard let path = inst["installPath"] as? String, let id = inst["id"] as? String else { continue }
            let dir = URL(fileURLWithPath: path)
            let candidates = [dir.appendingPathComponent("ComfyUI/.venv/bin/python3"), dir.appendingPathComponent("standalone-env/bin/python3")]
            guard let py = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }),
                  FileManager.default.fileExists(atPath: dir.appendingPathComponent("ComfyUI/main.py").path) else { continue }
            let cfg = support.appendingPathComponent("instance-model-paths/\(id).yaml")
            var shared: URL?
            if let y = try? String(contentsOf: cfg, encoding: .utf8),
               let line = y.split(separator: "\n").first(where: { $0.contains("base_path:") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }) {
                let p = line.split(separator: ":", maxSplits: 1).last.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) } ?? ""
                if !p.isEmpty { shared = URL(fileURLWithPath: p).deletingLastPathComponent() }
            }
            return Install(dir: dir, python: py, config: FileManager.default.fileExists(atPath: cfg.path) ? cfg : nil,
                           input: shared?.appendingPathComponent("input"), output: shared?.appendingPathComponent("output"))
        }
        return nil
    }

    static var installed: Bool {
        if simulateMissing { return managedInstall() != nil }
        return findInstall() != nil || FileManager.default.fileExists(atPath: "/Applications/Comfy Desktop.app")
            || FileManager.default.fileExists(atPath: "/Applications/ComfyUI.app")
    }

    func check() async {
        for p in [port, 8188, 8189, 8190, 8000] {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(p)/system_stats")!)
            req.timeoutInterval = 2
            if let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
               String(decoding: data, as: UTF8.self).contains("comfyui_version") {
                port = p
                online = true
                await detectModels()
                return
            }
        }
        online = false
    }

    /// 在后台启动 ComfyUI (和 Comfy Desktop 用同一套模型和文件夹)
    func start() async {
        await check()
        if online { return }
        starting = true
        defer { starting = false }
        if let inst = Self.findInstall() {
            let p = Process()
            p.executableURL = inst.python
            p.currentDirectoryURL = inst.dir
            var args = ["-s", "ComfyUI/main.py", "--listen", "127.0.0.1", "--port", "8188"]
            if !inst.managed { args.append("--enable-manager") }
            if let c = inst.config { args += ["--extra-model-paths-config", c.path] }
            if let i = inst.input { args += ["--input-directory", i.path] }
            if let o = inst.output { args += ["--output-directory", o.path] }
            p.arguments = args
            let log = AppPaths.support.appendingPathComponent("comfyui.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            if let h = try? FileHandle(forWritingTo: log) { p.standardOutput = h; p.standardError = h }
            do { try p.run(); process = p } catch { message = error.localizedDescription; return }
            port = 8188
        } else if !Self.simulateMissing && FileManager.default.fileExists(atPath: "/Applications/Comfy Desktop.app") {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Comfy Desktop.app"))
        } else {
            message = String(localized: "还没有视频引擎。请打开设置向导一键安装。")
            return
        }
        for _ in 0..<120 {
            try? await Task.sleep(for: .seconds(2))
            await check()
            if online { message = nil; return }
        }
        message = String(localized: "ComfyUI 启动超时，可以打开 Comfy Desktop 看看有没有报错。")
    }

    /// Toolula 退出时关掉自己启动的 ComfyUI
    func stopOwned() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }

    private func options(_ node: String, _ field: String) async -> [String] {
        guard let (data, _) = try? await URLSession.shared.data(from: base.appendingPathComponent("object_info/\(node)")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let n = obj[node] as? [String: Any], let input = n["input"] as? [String: Any],
              let req = input["required"] as? [String: Any], let f = req[field] as? [Any] else { return [] }
        if let list = f.first as? [String] { return list }
        if let opts = (f.count > 1 ? f[1] : nil) as? [String: Any], let list = opts["options"] as? [String] { return list }
        return []
    }

    /// 找到已安装的 H3 文件 (Mac 上优先 bf16/fp16, int8/fp8/nvfp4 需要 NVIDIA)
    func detectModels() async {
        func pick(_ list: [String], _ must: String, prefer: [String]) -> String? {
            let c = list.filter { $0.lowercased().contains(must) }
            for p in prefer { if let x = c.first(where: { $0.lowercased().contains(p) }) { return x } }
            return c.first
        }
        let mac = ["bf16", "fp16", "fp32"]
        unet = pick(await options("UNETLoader", "unet_name"), "minimax_h3_fl2va", prefer: ["pruned_bf16", "bf16"])
        clip = pick(await options("CLIPLoader", "clip_name"), "minimax_h3", prefer: mac)
        let vaes = await options("VAELoader", "vae_name")
        videoVAE = pick(vaes, "minimax_h3_video_vae", prefer: mac)
        audioVAE = pick(vaes, "minimax_h3_audio_vae", prefer: mac)
        lora = pick(await options("LoraLoaderModelOnly", "lora_name"), "minimax_h3_fl2v_turbo", prefer: ["4step", "8step"])
    }

    func free() async {
        var req = URLRequest(url: base.appendingPathComponent("free"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["unload_models": true, "free_memory": true])
        _ = try? await URLSession.shared.data(for: req)
    }

    func interrupt() async {
        var req = URLRequest(url: base.appendingPathComponent("interrupt"))
        req.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: req)
    }

    /// 上传首帧图片到 ComfyUI, 返回文件名
    func upload(_ file: URL) async throws -> String {
        let boundary = "toolula-\(UUID().uuidString)"
        var req = URLRequest(url: base.appendingPathComponent("upload/image"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let name = "toolula_" + UUID().uuidString.prefix(8) + ".png"
        // 统一转成 PNG (HEIC/RAW 也能用)
        guard let img = Renderer.shared.loadFull(file), let png = Renderer.shared.context.pngRepresentation(
            of: Renderer.shared.scale(img, maxSide: 2048), format: .RGBA8, colorSpace: Renderer.shared.sRGB) else {
            throw URLError(.cannotDecodeContentData)
        }
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(name)\"\r\nContent-Type: image/png\r\n\r\n".utf8))
        body.append(png)
        body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\ntrue\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body
        let (data, _) = try await URLSession.shared.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["name"] as? String ?? name
    }
}

// MARK: - 视频设置

enum VideoQuality: String, CaseIterable, Identifiable {
    case p480 = "480p（快，适合试效果）"
    case p576 = "576p"
    case p720 = "720p"
    case p768 = "768p（最清晰，模型原生）"
    var id: String { rawValue }
    var megapixels: Double {
        switch self {
        case .p480: return 0.415
        case .p576: return 0.59
        case .p720: return 0.92
        case .p768: return 1.03
        }
    }
}

enum VideoAspect: String, CaseIterable, Identifiable {
    case wide = "16:9 横屏"
    case tall = "9:16 竖屏"
    case square = "1:1 方形"
    case classic = "4:3"
    case portrait = "3:4"
    var id: String { rawValue }
    var ratio: Double {
        switch self {
        case .wide: return 16.0 / 9
        case .tall: return 9.0 / 16
        case .square: return 1
        case .classic: return 4.0 / 3
        case .portrait: return 3.0 / 4
        }
    }
}

struct VideoItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var prompt: String
    var path: String
    var created = Date()
    var width: Int
    var height: Int
    var seconds: Double
    var seed: Int
    var fromImage: Bool
    var elapsed: Double
    var model: String?
}

enum VideoMath {
    /// 宽高: 按画面比例和像素数, 取 32 的倍数
    static func size(_ q: VideoQuality, ratio: Double) -> (Int, Int) {
        let px = q.megapixels * 1_000_000
        let w = (px * ratio).squareRoot(), h = w / ratio
        func r32(_ v: Double) -> Int { max(256, Int((v / 32).rounded()) * 32) }
        return (r32(w), r32(h))
    }

    /// 帧数: 24fps, 对齐到模型要求的 17k+5
    static func frames(_ seconds: Double) -> Int {
        let n = max(5, Int((seconds * 24).rounded()))
        return n + ((5 - n % 17) % 17 + 17) % 17
    }

    /// 估算时间 (分钟). 依据: 这台 M3 Max 上 864×480、5 秒、4 步 = 采样约 9 分钟
    static func estimate(w: Int, h: Int, frames: Int, steps: Int, loaded: Bool) -> Double {
        let work = Double(w * h * frames) / Double(864 * 480 * 124)
        let sampling = 9.2 * pow(work, 1.25) * Double(steps) / 4
        let decode = 0.6 * work
        let load = loaded ? 0.3 : 5
        return sampling + decode + load
    }
}

// MARK: - 生成

@MainActor
final class VideoStore: ObservableObject {
    static let shared = VideoStore()

    @Published var items: [VideoItem] = []
    @Published var selected: UUID?
    @Published var prompt = UserDefaults.standard.string(forKey: "videoPrompt") ?? "" {
        didSet { UserDefaults.standard.set(prompt, forKey: "videoPrompt") }
    }
    @Published var firstFrame: URL?
    @Published var quality: VideoQuality = .p480
    @Published var aspect: VideoAspect = .wide
    @Published var seconds: Double = 5
    @Published var randomSeed = true
    @Published var seed = 42
    @Published var turbo = true
    @Published var autoFree = UserDefaults.standard.object(forKey: "videoAutoFree") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoFree, forKey: "videoAutoFree") }
    }

    @Published var running = false
    @Published var stage = ""
    @Published var step = 0
    @Published var steps = 0
    @Published var startedAt: Date?
    @Published var estimateMinutes: Double = 0
    @Published var error: String?
    @Published var improving = false
    private var modelsLoaded = false
    private var lastSpec: String?
    private var runningSpec = ""
    private var socket: URLSessionWebSocketTask?
    private let file = AppPaths.support.appendingPathComponent("videos.json")

    init() {
        if let list = SafeJSON.load([VideoItem].self, from: file) {
            items = list.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        selected = items.first?.id
    }

    func save() {
        SafeJSON.save(items, to: file)
    }

    var currentSize: (Int, Int) {
        if let f = firstFrame, let img = NSImage(contentsOf: f), img.size.height > 0 {
            return VideoMath.size(quality, ratio: img.size.width / img.size.height)
        }
        return VideoMath.size(quality, ratio: aspect.ratio)
    }

    var currentEstimate: Double {
        let (w, h) = currentSize
        let spec = VideoModels.shared.selected
        let lora = VideoModels.shared.file(spec, spec.files.last!)
        return spec.estimate(w: w, h: h, frames: spec.frames(seconds), steps: spec.steps(turbo: turbo, lora: lora), loaded: modelsLoaded)
    }

    /// 生成视频. 返回生成好的视频 (失败返回 nil, 错误在 error 里)
    @discardableResult
    func generate(prompt p: String? = nil, image: URL? = nil, seconds sec: Double? = nil, quality q: VideoQuality? = nil,
                  aspect a: VideoAspect? = nil) async -> VideoItem? {
        guard !running else { error = String(localized: "已经有一个视频在生成了"); return nil }
        let engine = ComfyEngine.shared
        let models = VideoModels.shared
        let text = (p ?? prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { error = String(localized: "请先写下想要的视频内容"); return nil }
        models.scan()
        let spec = models.selected
        guard models.isReady(spec) else {
            error = String(localized: "还没有下载 \(spec.name) 模型。请在上面的「视频模型」里点下载。")
            return nil
        }
        guard !ImageStore.shared.running else { error = String(localized: "正在画图，请等它完成后再生成视频"); return nil }
        let frame = image ?? firstFrame
        let secs = min(sec ?? seconds, spec.maxSeconds)
        let qual = spec.qualities.contains(q ?? quality) ? (q ?? quality) : spec.qualities.last!
        let asp = a ?? aspect
        running = true; error = nil; step = 0; steps = 0; startedAt = Date(); runningSpec = spec.id
        defer { running = false; startedAt = nil; stage = "" }

        stage = String(localized: "启动视频引擎…")
        await engine.start()
        guard engine.online else { error = engine.message ?? String(localized: "视频引擎没有启动"); return nil }
        if lastSpec != spec.id { modelsLoaded = false }

        // 视频模型很占内存: 先让对话引擎 (LM Studio / 内置引擎) 把对话模型放下
        stage = String(localized: "释放对话模型占用的内存…")
        BuiltinEngine.shared.stop()
        MLXEngine.shared.stop()
        _ = await Task.detached { FileManager.default.fileExists(atPath: ModelManager.lms) ? Exporter.shell(ModelManager.lms, ["unload", "--all"]) : (0, "") }.value

        var uploaded: String?
        if let frame {
            stage = String(localized: "上传首帧图片…")
            do { uploaded = try await engine.upload(frame) } catch { self.error = String(localized: "首帧图片读取失败"); return nil }
        }
        let (w, h) = {
            if let frame, let img = NSImage(contentsOf: frame), img.size.height > 0 { return VideoMath.size(qual, ratio: img.size.width / img.size.height) }
            return VideoMath.size(qual, ratio: asp.ratio)
        }()
        let length = spec.frames(secs)
        let s = randomSeed ? Int.random(in: 1...999_999_999) : seed
        let lora = models.file(spec, spec.files.last!)
        estimateMinutes = spec.estimate(w: w, h: h, frames: length, steps: spec.steps(turbo: turbo, lora: lora), loaded: modelsLoaded)
        guard let g = spec.graph(VideoJobParams(prompt: text, width: w, height: h, seconds: secs, seed: s, turbo: turbo, firstFrame: uploaded),
                                 files: models.installed[spec.id] ?? [:]) else {
            error = String(localized: "模型文件不完整"); return nil
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
            return nil
        }
        if let ne = obj["node_errors"] as? [String: Any], !ne.isEmpty { error = "\(ne)"; return nil }
        stage = modelsLoaded ? String(localized: "准备中…") : String(localized: "加载视频模型（约 90GB，第一次要几分钟）…")

        // 等结果
        while true {
            try? await Task.sleep(for: .seconds(3))
            guard let (hd, _) = try? await URLSession.shared.data(from: engine.base.appendingPathComponent("history/\(pid)")),
                  let hist = (try? JSONSerialization.jsonObject(with: hd) as? [String: Any])?[pid] as? [String: Any] else { continue }
            let status = hist["status"] as? [String: Any]
            if status?["status_str"] as? String == "error" {
                let msgs = status?["messages"] as? [[Any]] ?? []
                let detail = msgs.first { ($0.first as? String) == "execution_error" }.flatMap { ($0.last as? [String: Any])?["exception_message"] as? String }
                error = String(localized: "生成失败：\(detail ?? String(localized: "未知错误"))")
                return nil
            }
            guard status?["completed"] as? Bool == true else { continue }
            let outputs = hist["outputs"] as? [String: Any]
            let saved = outputs?["16"] as? [String: Any]
            let files = (saved?["images"] ?? saved?["videos"] ?? saved?["gifs"]) as? [[String: Any]] ?? []
            guard let f = files.first, let fname = f["filename"] as? String else {
                error = String(localized: "没有找到生成的视频文件"); return nil
            }
            let sub = f["subfolder"] as? String ?? ""
            let dest = Self.videosFolder.appendingPathComponent(fname)
            // 优先直接从 ComfyUI 的输出文件夹复制, 不行再下载
            if let out = ComfyEngine.findInstall()?.output?.appendingPathComponent(sub).appendingPathComponent(fname),
               FileManager.default.fileExists(atPath: out.path) {
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.copyItem(at: out, to: dest)
            }
            if !FileManager.default.fileExists(atPath: dest.path) {
                var c = URLComponents(url: engine.base.appendingPathComponent("view"), resolvingAgainstBaseURL: false)!
                c.queryItems = [URLQueryItem(name: "filename", value: fname), URLQueryItem(name: "subfolder", value: sub),
                                URLQueryItem(name: "type", value: "output")]
                if let (vd, _) = try? await URLSession.shared.data(from: c.url!) { try? vd.write(to: dest) }
            }
            var item = VideoItem(prompt: text, path: dest.path, width: w, height: h, seconds: Double(length) / 24, seed: s,
                                 fromImage: uploaded != nil, elapsed: Date().timeIntervalSince(startedAt ?? Date()))
            item.model = spec.name
            items.insert(item, at: 0)
            selected = item.id
            save()
            modelsLoaded = true
            lastSpec = spec.id
            if autoFree {
                await engine.free()
                modelsLoaded = false
            }
            Notifier.send(title: String(localized: "视频生成好了"), body: String(text.prefix(80)))
            return item
        }
    }

    func cancel() {
        Task { await ComfyEngine.shared.interrupt() }
    }

    func freeMemory() {
        Task { await ComfyEngine.shared.free(); modelsLoaded = false }
    }

    /// 监听 ComfyUI 的进度
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
            guard let node = data["node"] as? String else { return }
            if runningSpec == "wan22-5b" {
                switch node {
                case "1", "2", "3": stage = String(localized: "准备模型…")
                case "5", "6": stage = String(localized: "理解提示词…")
                case "8": stage = String(localized: "生成画面…")
                case "9": stage = String(localized: "解码画面和声音…")
                case "15", "16": stage = String(localized: "保存视频…")
                default: break
                }
                return
            }
            switch node {
            case "1", "2", "3", "4", "5": stage = modelsLoaded ? String(localized: "准备模型…") : String(localized: "加载视频模型（约 90GB，第一次要几分钟）…")
            case "6": stage = String(localized: "理解提示词…")
            case "12": stage = String(localized: "生成画面…")
            case "13", "14": stage = String(localized: "解码画面和声音…")
            case "15", "16": stage = String(localized: "保存视频…")
            default: break
            }
        case "progress":
            if let v = data["value"] as? Int, let m = data["max"] as? Int, m <= 60 {
                step = v; steps = m
                stage = String(localized: "生成画面：第 \(v)/\(m) 步")
            }
        default: break
        }
    }

    static var videosFolder: URL {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Toolula AI")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// 用对话模型把一句话想法扩写成 H3 擅长的英文提示词
    func improvePrompt() {
        let idea = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idea.isEmpty, !improving else { return }
        improving = true
        Task {
            defer { improving = false }
            let system = """
            You write prompts for the MiniMax H3 text-to-video model (it also generates synchronized audio).
            Rewrite the user's idea into one English prompt of 80-160 words: subject and action, setting, camera movement and shot type, lighting, visual style,
            then a line starting with "Audio:" describing sound effects, ambience and music, then a line "No text, subtitles, logos or watermarks.".
            The clip is about \(Int(seconds)) seconds, so describe one or two actions only. Output only the prompt.
            """
            let msgs: [[String: Any]] = [["role": "system", "content": system], ["role": "user", "content": idea]]
            if let r = try? await LLMClient.stream(model: ModelManager.shared.chatModel, messages: msgs, tools: nil, reasoning: "none", onDelta: { _, _ in }) {
                let t = r.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { prompt = t }
            } else {
                error = String(localized: "优化提示词失败（对话模型没有响应）")
            }
        }
    }
}
