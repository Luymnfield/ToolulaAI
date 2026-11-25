import Foundation
import SwiftUI

// MARK: - Toolula 自己管理的运行环境
//
// 别人的 Mac 上可能什么都没装. 这里的东西都由 Toolula 按需下载到
// ~/Library/Application Support/ToolulaAI/Engines, 不需要用户自己装 LM Studio / ComfyUI / Python.
//   - 内置对话引擎: llama.cpp 的 llama-server (开源, MIT), 跑 GGUF 模型, 能看图, 支持工具调用
//   - 视频引擎: ComfyUI (开源, GPL) + 独立的 Python 环境 (用 uv 安装)
//   - Python: 修图脚本需要; 没装 Xcode 命令行工具的 Mac 上 /usr/bin/python3 不能用

enum EnginePaths {
    static let root: URL = AppPaths.support.appendingPathComponent("Engines")
    static let llama = root.appendingPathComponent("llama")
    static let llamaServer = llama.appendingPathComponent("llama-server")
    static let uv = root.appendingPathComponent("uv/uv")
    static let pythonInstalls = root.appendingPathComponent("python")
    static let pyenv = root.appendingPathComponent("pyenv")
    static let comfy = root.appendingPathComponent("Comfy")
    static let uvCache = root.appendingPathComponent("uv-cache")
    /// 内置引擎的模型 (每个模型一个文件夹: 模型 .gguf + 看图用的 mmproj .gguf)
    static let models = AppPaths.support.appendingPathComponent("LocalModels")
    /// 给修图脚本 (Lightroom 插件也会用) 的启动信息
    static let engineInfo = AppPaths.support.appendingPathComponent("engine.json")
    static let log = AppPaths.support.appendingPathComponent("engines.log")
}

/// 固定版本 (测试过的), 不跟着上游每天变
enum EngineVersions {
    static let llama = "b12722"
    static let uv = "0.13.10"
    static let comfy = "v0.46.3"
    static let python = "3.12"

    static var llamaURL: URL {
        let arch = Recommender.appleSilicon ? "arm64" : "x64"
        return URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/\(llama)/llama-\(llama)-bin-macos-\(arch).tar.gz")!
    }
    static var uvURL: URL {
        let arch = Recommender.appleSilicon ? "aarch64" : "x86_64"
        return URL(string: "https://github.com/astral-sh/uv/releases/download/\(uv)/uv-\(arch)-apple-darwin.tar.gz")!
    }
    static let comfyURL = URL(string: "https://github.com/Comfy-Org/ComfyUI/archive/refs/tags/\(comfy).tar.gz")!
}

struct EngineError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

// MARK: - 命令行工具

enum Run {
    /// 在后台运行命令, 输出追加到 engines.log. 失败时抛出错误 (带最后几行输出)
    static func command(_ exe: URL, _ args: [String], cwd: URL? = nil, env extra: [String: String] = [:]) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            if let cwd { p.currentDirectoryURL = cwd }
            var env = ProcessInfo.processInfo.environment
            for (k, v) in extra { env[k] = v }
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            Self.appendLog("$ \(exe.lastPathComponent) \(args.joined(separator: " "))\n\(text)\n")
            if p.terminationStatus != 0 {
                let tail = text.split(separator: "\n").suffix(4).joined(separator: "\n")
                throw EngineError(String(localized: "安装命令失败（\(exe.lastPathComponent)，退出码 \(String(p.terminationStatus))）：\(tail)"))
            }
        }.value
    }

    static func appendLog(_ s: String) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: EnginePaths.log.path) { fm.createFile(atPath: EnginePaths.log.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: EnginePaths.log) {
            h.seekToEndOfFile(); h.write(Data(s.utf8)); try? h.close()
        }
    }

    /// 下载并解压 .tar.gz 到 dest (先解到临时文件夹, 成功后再换上去)
    static func downloadTar(_ url: URL, to dest: URL, stripTopFolder: Bool, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let fm = FileManager.default
        let tmp = EnginePaths.root.appendingPathComponent("tmp-\(UUID().uuidString.prefix(6))")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let archive = tmp.appendingPathComponent("a.tar.gz")
        try await ModelDownloader.fetch(url: url, to: archive, progress: progress)
        let out = tmp.appendingPathComponent("x")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        try await command(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", out.path])
        var src = out
        if stripTopFolder, let items = try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil).filter({ !$0.lastPathComponent.hasPrefix(".") }),
           items.count == 1 { src = items[0] }
        try? fm.removeItem(at: dest)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: src, to: dest)
        // 自己下载的文件不带隔离标记, 保险起见再清一次
        _ = try? await command(URL(fileURLWithPath: "/usr/bin/xattr"), ["-dr", "com.apple.quarantine", dest.path])
    }
}

// MARK: - uv (装 Python 和 ComfyUI 用)

enum UV {
    static var installed: Bool { FileManager.default.isExecutableFile(atPath: EnginePaths.uv.path) }

    static func ensure(progress: @escaping @Sendable (Int64) -> Void) async throws {
        if installed { return }
        try await Run.downloadTar(EngineVersions.uvURL, to: EnginePaths.uv.deletingLastPathComponent(), stripTopFolder: true, progress: progress)
        guard installed else { throw EngineError(String(localized: "uv 安装失败")) }
    }

    static var env: [String: String] {
        ["UV_PYTHON_INSTALL_DIR": EnginePaths.pythonInstalls.path, "UV_CACHE_DIR": EnginePaths.uvCache.path,
         "UV_PYTHON_PREFERENCE": "only-managed", "UV_NO_CONFIG": "1"]
    }

    static func run(_ args: [String], cwd: URL? = nil) async throws {
        try await Run.command(EnginePaths.uv, args, cwd: cwd, env: env)
    }

    static func cleanCache() { try? FileManager.default.removeItem(at: EnginePaths.uvCache) }
}

// MARK: - Python (修图脚本用)

enum PythonRuntime {
    static let system = "/usr/bin/python3"
    static var managed: URL { EnginePaths.pyenv.appendingPathComponent("bin/python3") }

    /// /usr/bin/python3 只有装了 Xcode 或命令行工具才能用 (否则会弹出安装提示)
    nonisolated(unsafe) static var simulateMissing = false
    static var systemUsable: Bool {
        if simulateMissing { return false }
        return Exporter.shell("/usr/bin/xcode-select", ["-p"]).0 == 0
    }
    static var managedInstalled: Bool { FileManager.default.isExecutableFile(atPath: managed.path) }
    static var ready: Bool { systemUsable || managedInstalled }

    /// 修图脚本用哪个 Python
    static var path: String { managedInstalled ? managed.path : system }

    static func install(progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await UV.ensure(progress: progress)
        try await UV.run(["venv", "--python", EngineVersions.python, "--clear", EnginePaths.pyenv.path])
        UV.cleanCache()
        guard managedInstalled else { throw EngineError(String(localized: "Python 安装失败")) }
    }
}

// MARK: - 内置对话引擎 (llama.cpp)

@MainActor
final class BuiltinEngine: ObservableObject {
    static let shared = BuiltinEngine()
    nonisolated static let port = 1236
    nonisolated static let base = URL(string: "http://127.0.0.1:\(port)")!

    @Published var online = false
    private var process: Process?

    nonisolated static var installed: Bool { FileManager.default.isExecutableFile(atPath: EnginePaths.llamaServer.path) }

    /// 已下载的模型文件夹
    nonisolated static var modelFolders: [String] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: EnginePaths.models.path)) ?? []).filter { name in
            let files = (try? fm.contentsOfDirectory(atPath: EnginePaths.models.appendingPathComponent(name).path)) ?? []
            return files.contains { $0.hasSuffix(".gguf") && !$0.lowercased().hasPrefix("mmproj") }
                && !files.contains { $0.hasSuffix(".download") }
        }.sorted()
    }

    nonisolated static var ramGB: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 }
    /// 上下文长度: KV 缓存用 8 位后占用减半, 内存大的 Mac 可以放更长的对话
    nonisolated static var contextSize: Int { ramGB >= 64 ? 65536 : ramGB >= 24 ? 32768 : 16384 }
    /// 提示词缓存可用的内存 (MB)
    nonisolated static var cacheRAM: Int { ramGB >= 64 ? 16384 : ramGB >= 24 ? 8192 : 2048 }

    /// 启动参数: 一个服务管理所有模型, 用到哪个加载哪个, 同时只放一个, 空闲 15 分钟自动释放内存
    nonisolated static var launchArgs: [String] {
        ["--host", "127.0.0.1", "--port", String(port), "--models-dir", EnginePaths.models.path,
         "--models-max", "1", "--sleep-idle-seconds", "900", "--ctx-size", String(contextSize), "--jinja",
         // 加速:
         "-fa", "on",                          // Flash Attention: 长上下文读得更快
         "-ctk", "q8_0", "-ctv", "q8_0",       // KV 缓存用 8 位: 内存减半, 质量几乎不变
         "--cache-reuse", "256",               // 历史对话中间有改动时, 后面没变的大段仍能复用缓存
         "--cache-ram", String(cacheRAM),      // 切换对话时把之前的缓存留在内存里
         "--spec-type", "ngram-mod"]           // 推测解码: 从已有文字里预测接下来的内容 (不需要额外模型, 结果完全一样)
    }

    static func install(progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await Run.downloadTar(EngineVersions.llamaURL, to: EnginePaths.llama, stripTopFolder: true, progress: progress)
        guard installed else { throw EngineError(String(localized: "内置引擎安装失败")) }
        try? FileManager.default.createDirectory(at: EnginePaths.models, withIntermediateDirectories: true)
        writeInfo()
    }

    /// 写给修图脚本: 它在 Lightroom 里单独运行时也能自己启动引擎
    static func writeInfo() {
        let info: [String: Any] = ["server": EnginePaths.llamaServer.path, "args": launchArgs, "base": base.appendingPathComponent("v1").absoluteString]
        if let d = try? JSONSerialization.data(withJSONObject: info, options: .prettyPrinted) { try? d.write(to: EnginePaths.engineInfo) }
    }

    func check() async -> Bool {
        var req = URLRequest(url: Self.base.appendingPathComponent("v1/models"))
        req.timeoutInterval = 2
        let ok = ((try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse)?.statusCode == 200
        online = ok
        return ok
    }

    /// 需要时启动 (已经在跑就直接返回)
    func ensureRunning() async throws {
        if await check() { return }
        guard Self.installed else { throw EngineError(String(localized: "内置 AI 引擎还没有安装，请先打开设置向导。")) }
        try? FileManager.default.createDirectory(at: EnginePaths.models, withIntermediateDirectories: true)
        Self.writeInfo()
        let p = Process()
        p.executableURL = EnginePaths.llamaServer
        p.arguments = Self.launchArgs
        p.currentDirectoryURL = EnginePaths.llama
        let log = AppPaths.support.appendingPathComponent("llama.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: log) { p.standardOutput = h; p.standardError = h }
        try p.run()
        process = p
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(500))
            if await check() { return }
            if !p.isRunning { break }
        }
        throw EngineError(String(localized: "内置 AI 引擎启动失败，详情见 llama.log"))
    }

    /// 关掉 (释放内存; 下次用到会自动再启动). 只关自己启动的, 以及 Lightroom 插件启动的同一个服务
    func stop() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        _ = Exporter.shell("/usr/bin/pkill", ["-f", EnginePaths.llamaServer.path])
        online = false
    }

    /// 新下载了模型: 重启一下让它认到
    func reload() async {
        let wasOnline = await check()
        stop()
        if wasOnline || Self.installed { try? await Task.sleep(for: .milliseconds(500)); try? await ensureRunning() }
    }

    struct Info { let id: String; let vision: Bool; let loaded: Bool }

    func models() async -> [Info] {
        guard let (data, _) = try? await URLSession.shared.data(from: Self.base.appendingPathComponent("v1/models")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            let mods = ((m["architecture"] as? [String: Any])?["input_modalities"] as? [String]) ?? []
            let state = ((m["status"] as? [String: Any])?["value"] as? String) ?? ""
            return Info(id: id, vision: mods.contains("image"), loaded: state == "loaded")
        }
    }

    /// 没在跑时按文件夹列出模型 (有 mmproj 文件就是能看图的)
    nonisolated static func offlineModels() -> [Info] {
        modelFolders.map { name in
            let files = (try? FileManager.default.contentsOfDirectory(atPath: EnginePaths.models.appendingPathComponent(name).path)) ?? []
            return Info(id: name, vision: files.contains { $0.lowercased().hasPrefix("mmproj") }, loaded: false)
        }
    }

    static func folderName(forRepo repo: String) -> String {
        let n = repo.split(separator: "/").last.map(String.init) ?? repo
        return n.replacingOccurrences(of: "-GGUF", with: "").replacingOccurrences(of: "-gguf", with: "")
    }

    static func isInstalled(repo: String) -> Bool { modelFolders.contains(folderName(forRepo: repo)) }

    func delete(_ id: String) async {
        stop()
        try? FileManager.default.trashItem(at: EnginePaths.models.appendingPathComponent(id), resultingItemURL: nil)
        if !Self.modelFolders.isEmpty { try? await ensureRunning() }
    }
}

// MARK: - 视频引擎 (Toolula 自己装的 ComfyUI)

enum ComfySetup {
    static var dir: URL { EnginePaths.comfy }
    static var main: URL { dir.appendingPathComponent("ComfyUI/main.py") }
    static var python: URL { dir.appendingPathComponent("ComfyUI/.venv/bin/python3") }
    static var installed: Bool {
        FileManager.default.fileExists(atPath: main.path) && FileManager.default.isExecutableFile(atPath: python.path)
            && FileManager.default.fileExists(atPath: dir.appendingPathComponent("ComfyUI/.toolula-ready").path)
    }
    static var modelsDir: URL { dir.appendingPathComponent("ComfyUI/models") }

    /// 步骤: uv -> ComfyUI 源码 -> Python 3.12 虚拟环境 -> 依赖 (PyTorch 等)
    static func install(stage: @escaping @MainActor (String) -> Void, progress: @escaping @Sendable (Int64) -> Void) async throws {
        await stage(String(localized: "下载安装工具…"))
        try await UV.ensure(progress: progress)
        let src = dir.appendingPathComponent("ComfyUI")
        // 已经下好的模型不能丢: 先挪开, 装好源码后再放回去
        let keep = dir.appendingPathComponent("models-keep")
        let fm = FileManager.default
        if fm.fileExists(atPath: src.appendingPathComponent("models").path) {
            try? fm.removeItem(at: keep)
            try fm.moveItem(at: src.appendingPathComponent("models"), to: keep)
        }
        await stage(String(localized: "下载 ComfyUI…"))
        try await Run.downloadTar(EngineVersions.comfyURL, to: src, stripTopFolder: true, progress: progress)
        if fm.fileExists(atPath: keep.path) {
            try? fm.removeItem(at: src.appendingPathComponent("models"))
            try fm.moveItem(at: keep, to: src.appendingPathComponent("models"))
        }
        await stage(String(localized: "安装 Python 环境…"))
        try await UV.run(["venv", "--python", EngineVersions.python, "--clear", src.appendingPathComponent(".venv").path])
        await stage(String(localized: "安装 PyTorch 和依赖（约 1 GB，需要几分钟）…"))
        try await UV.run(["pip", "install", "--python", python.path, "-r", src.appendingPathComponent("requirements.txt").path])
        UV.cleanCache()
        fm.createFile(atPath: src.appendingPathComponent(".toolula-ready").path, contents: Data())
        for d in ["input", "output"] { try? fm.createDirectory(at: src.appendingPathComponent(d), withIntermediateDirectories: true) }
    }
}

// MARK: - 用哪个对话引擎

enum ChatEngineKind { case lmStudio, builtin }

extension LocalEngine {
    /// 装了 LM Studio 就继续用它 (MLX 格式在 Apple 芯片上更快); 没装就用 Toolula 内置引擎
    static var preferred: ChatEngineKind { installed && !simulateMissing ? .lmStudio : .builtin }
}
