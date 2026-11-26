import Foundation

/// 调用 App 里自带的 ai_edit.py (它再调用本机 LM Studio 的 Qwen3.8)
enum AIBridge {
    struct Result {
        var kv: [String: String] = [:]
        var lists: [String: [String]] = [:]
        var error: String?
        func number(_ k: String) -> Double? { kv[k].flatMap(Double.init) }
    }

    static var scriptURL: URL? {
        if let u = Bundle.main.url(forResource: "ai_edit", withExtension: "py") { return u }
        let dev = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Adobe/Lightroom/Modules/AIPhotoEdit.lrplugin/ai_edit.py")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    static let workDir: URL = {
        AppPaths.cacheDir("Photo")
    }()

    /// 同步执行, 请在后台线程调用
    static func run(_ mode: String, image: URL? = nil, reference: URL? = nil, request: [String: Any]? = nil,
                    extra: [String] = []) -> Result {
        guard let script = scriptURL else { return Result(error: String(localized: "找不到 AI 脚本 ai_edit.py")) }
        guard PythonRuntime.ready else { return Result(error: String(localized: "修图功能需要 Python。请打开设置向导一键安装。")) }
        // 只读本地记录的命令 (修图习惯 taste / record / learn) 用不到模型, 不要为它们启动引擎
        // (以前每次打开 Toolula 读一下修图习惯, 就会把 32 GB 的 MTP 引擎拉起来)
        let needsModel = !["taste", "record", "learn"].contains(mode)
        // 修图模型在内置引擎上: 先确保引擎在跑
        if needsModel, UserDefaults.standard.string(forKey: "photoModel")?.hasPrefix("builtin:") == true {
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor in try? await BuiltinEngine.shared.ensureRunning(); sem.signal() }
            sem.wait()
        }
        if needsModel, let pm = UserDefaults.standard.string(forKey: "photoModel"), let pair = MTPPair.pair(for: pm) {
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor in try? await MLXEngine.shared.ensureRunning(pair); sem.signal() }
            sem.wait()
        }
        // 修图期间修图模型标记为「正在用」, 不会被请去让位
        let photoTenant = needsModel ? UserDefaults.standard.string(forKey: "photoModel").flatMap(MemoryBroker.Tenant.forModel) : nil
        if let photoTenant {
            if Thread.isMainThread { MainActor.assumeIsolated { MemoryBroker.shared.begin(photoTenant) } }
            else { DispatchQueue.main.sync { MainActor.assumeIsolated { MemoryBroker.shared.begin(photoTenant) } } }
        }
        defer { if let photoTenant { DispatchQueue.main.async { MainActor.assumeIsolated { MemoryBroker.shared.end(photoTenant) } } } }
        let id = UUID().uuidString.prefix(8)
        let out = workDir.appendingPathComponent("out_\(mode)_\(id).txt")
        var args = ["-I", script.path, mode, "--out", out.path]
        if let image { args += ["--image", image.path] }
        if let reference { args += ["--reference", reference.path] }
        if let request {
            let req = workDir.appendingPathComponent("req_\(mode)_\(id).json")
            if let data = try? JSONSerialization.data(withJSONObject: request) { try? data.write(to: req) }
            args += ["--request", req.path]
        }
        args += extra

        let p = Process()
        p.executableURL = URL(fileURLWithPath: PythonRuntime.path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        if let m = UserDefaults.standard.string(forKey: "photoModel"), !m.isEmpty { env["TOOLULA_MODEL"] = m }
        env["TOOLULA_LANG"] = Lang.scriptLanguage
        env["TOOLULA_LANG_NAME"] = Lang.aiLanguage
        // 修图模型可以是云端 API
        let d = UserDefaults.standard
        if let base = d.string(forKey: "photoAPIBase"), !base.isEmpty {
            env["TOOLULA_API_BASE"] = base
            env["TOOLULA_MODEL"] = d.string(forKey: "photoAPIModel") ?? ""
            if let pid = d.string(forKey: "photoAPIProvider").flatMap(UUID.init(uuidString:)), let key = Keychain.get(pid) {
                env["TOOLULA_API_KEY"] = key
            }
        }
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return Result(error: String(localized: "无法启动 Python：\(error.localizedDescription)")) }
        p.waitUntilExit()

        guard let text = try? String(contentsOf: out, encoding: .utf8) else {
            return Result(error: String(localized: "AI 没有返回结果（退出码 \(p.terminationStatus)）"))
        }
        try? FileManager.default.removeItem(at: out)
        var r = Result()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]), v = String(line[line.index(after: eq)...])
            if k == "__error" { r.error = v; continue }
            r.kv[k] = v
            r.lists[k, default: []].append(v)
        }
        return r
    }

    /// 从 AI 结果里取出修图参数
    static func settings(from r: Result) -> Settings {
        var s = Settings()
        for (k, v) in r.kv where !k.hasPrefix("__") {
            if let d = Double(v), Params.specByKey[k] != nil { s[k] = Params.clamp(k, d) }
        }
        return s
    }

    static func numeric(_ s: Settings) -> [String: Any] { s.mapValues { $0 as Any } }
}
