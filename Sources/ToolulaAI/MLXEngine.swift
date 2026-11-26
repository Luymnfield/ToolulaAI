import Foundation
import SwiftUI

// MTP 加速引擎 (第三个对话引擎)
//   - 用开源的 mlx-vlm (MIT) 跑 LM Studio 里已经下载的 MLX 模型, 再加上模型自带的
//     多 token 预测 (MTP) 小模块提前猜后面几个字, 大模型一次确认: 输出快约 1.5–2.4 倍
//   - 目前支持 Qwen3.8 27B (官方提供了 MTP 权重); 模型文件直接用 LM Studio 的, 不用重新下载
//   - 只在本机 127.0.0.1:1237 上服务; 不用时 15 分钟自动关掉释放内存

struct MTPPair {
    let key: String            // 在 Toolula 里的模型 id: "mlx:" + key
    let name: String
    let match: [String]        // LM Studio 模型文件夹名需要包含的词 (小写)
    let draftRepo: String
    let draftFiles: [String]
    let draftGB: Double

    static let qwen38_27b = MTPPair(
        key: "qwen3.8-27b", name: "Qwen3.8 27B",
        match: ["qwen3.8-27b", "mlx"],
        draftRepo: "mlx-community/Qwen3.8-27B-MTP-mxfp4",
        draftFiles: ["config.json", "model.safetensors", "model.safetensors.index.json", "tokenizer.json",
                     "tokenizer_config.json", "vocab.json", "chat_template.jinja"],
        draftGB: 0.23)

    static let all: [MTPPair] = [.qwen38_27b]

    var id: String { "mlx:" + key }
    var draftDir: URL { EnginePaths.root.appendingPathComponent("mtp/\(key)") }
    var draftReady: Bool { FileManager.default.fileExists(atPath: draftDir.appendingPathComponent("model.safetensors").path) }

    /// LM Studio 里对应的 MLX 模型文件夹 (8bit 优先)
    var target: URL? {
        let root = URL(fileURLWithPath: NSHomeDirectory() + "/.lmstudio/models")
        guard let pubs = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return nil }
        var found: [URL] = []
        for pub in pubs {
            let pdir = root.appendingPathComponent(pub)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: pdir.path)) ?? [] {
                let l = name.lowercased()
                guard match.allSatisfy({ l.contains($0) }), !l.contains("mtp") else { continue }
                let dir = pdir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path) { found.append(dir) }
            }
        }
        return found.sorted { a, b in
            func rank(_ u: URL) -> Int { let l = u.lastPathComponent.lowercased(); return l.contains("8bit") ? 0 : l.contains("6bit") ? 1 : 2 }
            return rank(a) < rank(b)
        }.first
    }

    /// LM Studio 里同一个模型的 id (两个引擎不要同时把它放进内存)
    var lmStudioMatches: (String) -> Bool { { id in id.lowercased().contains(key) } }

    static func pair(for modelId: String) -> MTPPair? { all.first { $0.id == modelId } }
}

@MainActor
final class MLXEngine: ObservableObject {
    static let shared = MLXEngine()
    nonisolated static let port = 1237
    nonisolated static let base = URL(string: "http://127.0.0.1:\(port)")!
    /// mlx-vlm 的版本固定下来 (实测过工具调用、看图、MTP、前缀缓存都正常)
    nonisolated static let mlxVLMVersion = "0.8.1"

    nonisolated static var envDir: URL { EnginePaths.root.appendingPathComponent("mlx") }
    nonisolated static var python: URL { envDir.appendingPathComponent("bin/python3") }
    nonisolated static var cacheDir: URL { AppPaths.cache.appendingPathComponent("MLX") }
    nonisolated static var runtimeInstalled: Bool { FileManager.default.isExecutableFile(atPath: python.path) }

    @Published var installing = false
    @Published var stage = ""
    @Published var progress: Double = 0
    @Published var error: String?
    @Published var online = false
    @Published var loadedTarget: String?
    @Published var starting = false

    private var process: Process?
    private var lastUsed = Date()
    private var idleTimer: Timer?

    /// 这个模型可以用 MTP 加速吗 (引擎装好 + MTP 权重下好 + LM Studio 里有对应的 MLX 模型)
    func ready(_ p: MTPPair) -> Bool { Self.runtimeInstalled && p.draftReady && p.target != nil }

    // MARK: 安装

    func install(_ p: MTPPair) async {
        guard !installing else { return }
        installing = true; error = nil; progress = 0
        defer { installing = false }
        do {
            stage = String(localized: "准备 Python…")
            try await UV.ensure { _ in }
            if !Self.runtimeInstalled {
                try await UV.run(["venv", "--python", "3.12", "--clear", Self.envDir.path])
            }
            stage = String(localized: "安装 MLX 引擎（约 800 MB）…")
            progress = 0.1
            try await UV.run(["pip", "install", "--python", Self.python.path, "mlx-vlm==\(Self.mlxVLMVersion)"])
            UV.cleanCache()
            progress = 0.6
            stage = String(localized: "下载 MTP 预测模块…")
            try? FileManager.default.createDirectory(at: p.draftDir, withIntermediateDirectories: true)
            for (i, f) in p.draftFiles.enumerated() {
                let dest = p.draftDir.appendingPathComponent(f)
                if FileManager.default.fileExists(atPath: dest.path) { continue }
                try await ModelDownloader.fetch(url: URL(string: "https://huggingface.co/\(p.draftRepo)/resolve/main/\(f)")!, to: dest) { _ in }
                progress = 0.6 + 0.4 * Double(i + 1) / Double(p.draftFiles.count)
            }
            guard ready(p) else { throw EngineError(String(localized: "MTP 加速引擎安装不完整")) }
            stage = String(localized: "完成")
            progress = 1
            ModelManager.shared.refresh()
        } catch {
            self.error = error.localizedDescription
            stage = ""
        }
    }

    // MARK: 运行

    func check() async -> Bool {
        var req = URLRequest(url: Self.base.appendingPathComponent("health"))
        req.timeoutInterval = 2
        guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { online = false; return false }
        online = obj["model_ready"] as? Bool ?? false
        loadedTarget = obj["loaded_model"] as? String
        return online
    }

    func touch() { lastUsed = Date() }

    /// 需要时启动 (同一个模型已经在跑就直接返回)
    func ensureRunning(_ p: MTPPair) async throws {
        touch()
        // 正在启动 (另一个请求触发的): 等它启动完, 不要重来
        while starting { try? await Task.sleep(for: .milliseconds(500)) }
        guard let target = p.target else { throw EngineError(String(localized: "LM Studio 里找不到 \(p.name) 的 MLX 模型文件")) }
        if await check(), loadedTarget == target.path { return }
        guard ready(p) else { throw EngineError(String(localized: "MTP 加速引擎还没有安装，请在「模型 → 加速」里安装。")) }
        stop()
        starting = true
        defer { starting = false }
        // 同一个模型不要在 LM Studio 里也放一份 (两份要 60 GB)
        let lms = ModelManager.lms
        let loadedInLMS = ModelManager.shared.models.filter { $0.loaded && !$0.isBuiltin && !$0.isCloud && p.lmStudioMatches($0.id) }.map(\.id)
        if !loadedInLMS.isEmpty, FileManager.default.fileExists(atPath: lms) {
            await Task.detached { for id in loadedInLMS { _ = Exporter.shell(lms, ["unload", id]) } }.value
        }
        try? FileManager.default.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = Self.python
        proc.arguments = ["-m", "mlx_vlm.server", "--host", "127.0.0.1", "--port", String(Self.port),
                          "--model", target.path, "--draft-model", p.draftDir.path, "--draft-kind", "mtp", "--max-num-seqs", "4"]
        var env = ProcessInfo.processInfo.environment
        env["APC_DISK_MAX_GB"] = "4"                      // 硬盘上的提示词缓存最多 4 GB (默认 20 GB), 超过自动删最旧的
        env["APC_ENABLED"] = "1"                          // 前缀缓存: 对话里没变的部分不重新读
        env["APC_CHECKPOINT_INTERVAL_TOKENS"] = "512"     // Qwen3.8 是混合结构, 只能从检查点接着用缓存
        env["MLX_VLM_CACHE_HOME"] = Self.cacheDir.path
        env["HF_HUB_OFFLINE"] = "1"                       // 只用本地文件, 不联网
        proc.environment = env
        let log = AppPaths.log("mlx.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: log) { proc.standardOutput = h; proc.standardError = h }
        try proc.run()
        process = proc
        ProcessJanitor.register("mlx", pid: proc.processIdentifier, signature: "mlx_vlm.server --host 127.0.0.1 --port \(Self.port)")
        startIdleTimer()
        // 加载 27B 模型要几十秒
        for _ in 0..<300 {
            try? await Task.sleep(for: .milliseconds(800))
            if await check() { ModelManager.shared.refresh(); return }
            if !proc.isRunning { break }
        }
        stop()
        throw EngineError(String(localized: "MTP 加速引擎启动失败，详情见 mlx.log"))
    }

    /// 关掉 (释放内存; 下次用到会自动再启动)
    func stop() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        _ = Exporter.shell("/usr/bin/pkill", ["-f", "mlx_vlm.server --host 127.0.0.1 --port \(Self.port)"])
        ProcessJanitor.unregister("mlx")
        online = false
        loadedTarget = nil
        idleTimer?.invalidate(); idleTimer = nil
    }

    /// 15 分钟没用就关掉, 把内存还给系统
    private func startIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if Date().timeIntervalSince(self.lastUsed) > 900 { self.stop(); ModelManager.shared.refresh() }
            }
        }
    }
}

// MARK: - 界面 (模型页「加速」卡片里)

struct MTPEngineBlock: View {
    @ObservedObject var engine = MLXEngine.shared
    @ObservedObject var models = ModelManager.shared
    let pair = MTPPair.qwen38_27b

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("MTP 加速引擎")
                if engine.ready(pair) {
                    Text(engine.online ? "运行中" : "已安装").font(.caption2.weight(.medium)).foregroundStyle(.green)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(.green.opacity(0.12)))
                }
            }
            Text("让 \(pair.name) 输出快约 2 倍（写代码、整理格式时 2.3 倍，中文聊天约 1.6 倍），回答质量不变。用 LM Studio 里已经下载的模型文件，不用重新下载。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if pair.target == nil {
                Text("需要先在「下载新模型」里下载 Qwen3.8-27B 的 MLX 版本。").font(.caption).foregroundStyle(.orange)
            } else if engine.installing {
                ProgressView(value: engine.progress) { Text(engine.stage).font(.caption) }
            } else if !engine.ready(pair) {
                Button { Task { await engine.install(pair); if engine.ready(pair) { switchTo() } } } label: {
                    Label("安装并启用（约 1 GB）", systemImage: "bolt.fill")
                }
            } else if models.chatModel != pair.id || models.photoModel != pair.id {
                Button { switchTo() } label: { Label("用于对话和修图", systemImage: "checkmark.circle") }
            } else {
                Text("对话和修图已经在用 MTP 加速。").font(.caption).foregroundStyle(.green)
            }
            if let e = engine.error { Text(e).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
    }

    func switchTo() {
        models.chatModel = pair.id
        models.photoModel = pair.id
    }
}
