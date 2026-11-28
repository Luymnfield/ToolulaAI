import Foundation
import Security
import SwiftUI

// MARK: - 模型 (本地 LM Studio 或云端 API)

struct LMModel: Identifiable, Hashable {
    let id: String            // 本地: LM Studio 的 id; 云端: "cloud:<服务商id>/<模型名>"
    let type: String          // llm / vlm / embeddings
    var loaded: Bool
    let context: Int
    let toolUse: Bool
    var providerName: String = ""
    var remoteName: String = ""
    var isCloud: Bool { id.hasPrefix("cloud:") }
    var vision: Bool { type == "vlm" }
    var isChat: Bool { type == "llm" || type == "vlm" }
    var displayName: String {
        if isCloud { return "\(remoteName) · \(providerName)" }
        if isBuiltin { return String(id.dropFirst(8)) }
        if isMLX { return String(id.dropFirst(4)) + " ⚡MTP" }
        return id.split(separator: "/").last.map(String.init) ?? id
    }
    var isBuiltin: Bool { id.hasPrefix("builtin:") }
    var isMLX: Bool { id.hasPrefix("mlx:") }
}

// MARK: - 云端服务商

struct Provider: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var baseURL: String
    var needsKey = true
    var models: [String] = []          // 获取到 (或手动填写) 的模型
    var enabledModels: [String] = []   // 显示在模型选择里的
    var kind = "openai"                // openai / anthropic (只影响请求头)

    struct Preset: Identifiable {
        let name: String
        let baseURL: String
        let needsKey: Bool
        let kind: String
        let defaults: [String]
        let keyURL: String
        var id: String { name }
    }

    static let presets: [Preset] = [
        Preset(name: "OpenAI", baseURL: "https://api.openai.com/v1", needsKey: true, kind: "openai", defaults: [],
               keyURL: "https://platform.openai.com/api-keys"),
        Preset(name: "Anthropic Claude", baseURL: "https://api.anthropic.com/v1", needsKey: true, kind: "anthropic",
               defaults: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"], keyURL: "https://console.anthropic.com/settings/keys"),
        Preset(name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", needsKey: true, kind: "openai",
               defaults: [], keyURL: "https://aistudio.google.com/apikey"),
        Preset(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", needsKey: true, kind: "openai", defaults: ["deepseek-chat", "deepseek-reasoner"],
               keyURL: "https://platform.deepseek.com/api_keys"),
        Preset(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", needsKey: true, kind: "openai", defaults: [],
               keyURL: "https://openrouter.ai/keys"),
        Preset(name: "Groq", baseURL: "https://api.groq.com/openai/v1", needsKey: true, kind: "openai", defaults: [],
               keyURL: "https://console.groq.com/keys"),
        Preset(name: "Mistral", baseURL: "https://api.mistral.ai/v1", needsKey: true, kind: "openai", defaults: [],
               keyURL: "https://console.mistral.ai/api-keys"),
        Preset(name: "Ollama", baseURL: "http://127.0.0.1:11434/v1", needsKey: false, kind: "openai", defaults: [], keyURL: ""),
    ]

    /// 粗略判断云端模型能不能看图
    static func guessVision(_ m: String) -> Bool {
        let s = m.lowercased()
        return ["gpt-4o", "gpt-4.1", "gpt-5", "claude", "gemini", "vision", "-vl", "pixtral", "llama-4", "grok"].contains { s.contains($0) }
    }
}

/// API Key 存在 macOS 钥匙串里, 不写进普通文件
enum Keychain {
    static let service = "com.toolula.ai.provider"

    static func set(_ key: String, for id: UUID) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: id.uuidString]
        SecItemDelete(q as CFDictionary)
        guard !key.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ id: UUID) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

struct Endpoint {
    let base: URL
    let key: String?
    let model: String
    let isLocal: Bool
    let kind: String
}

@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    @Published var models: [LMModel] = []          // 本地
    @Published var providers: [Provider] = [] { didSet { saveProviders() } }
    @Published var online = false
    @Published var lastError: String?
    @Published var chatModel: String = UserDefaults.standard.string(forKey: "chatModel") ?? "qwen/qwen3.8-27b" {
        didSet { UserDefaults.standard.set(chatModel, forKey: "chatModel") }
    }
    @Published var photoModel: String = UserDefaults.standard.string(forKey: "photoModel") ?? "qwen/qwen3.8-27b" {
        didSet { UserDefaults.standard.set(photoModel, forKey: "photoModel"); exportPhotoEndpoint() }
    }

    /// LM Studio 推测解码: 主模型 id -> 打草稿的小模型 id
    @Published var draftModels: [String: String] = UserDefaults.standard.dictionary(forKey: "draftModels") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(draftModels, forKey: "draftModels") }
    }
    /// 对话超过上下文的这个比例时自动压缩
    @Published var autoCompress = UserDefaults.standard.object(forKey: "autoCompress") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCompress, forKey: "autoCompress") }
    }
    private var contextCache: [String: (Int, Date)] = [:]

    /// 快慢分流: 简单的问题交给这个快模型 (空 = 不分流)
    @Published var fastModel: String = UserDefaults.standard.string(forKey: "fastModel") ?? "" {
        didSet { UserDefaults.standard.set(fastModel, forKey: "fastModel") }
    }
    @Published var autoRoute = UserDefaults.standard.object(forKey: "autoRoute") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoRoute, forKey: "autoRoute") }
    }
    /// 实测速度: 模型 id -> ["gen": 输出 token/秒, "prompt": 读提示 token/秒, "load": 加载秒数, "date": 时间]
    @Published var bench: [String: [String: Double]] = UserDefaults.standard.dictionary(forKey: "modelBench") as? [String: [String: Double]] ?? [:] {
        didSet { UserDefaults.standard.set(bench, forKey: "modelBench") }
    }
    @Published var benchmarking: String?

    /// 分流用的快模型 (设置了、还在、而且不是主模型本身)
    /// 能看图、又能用工具的本地模型 (先用快模型: 它通常已经在内存里)
    func visionHelper(excluding main: String) -> String? {
        let local = localChatModels.filter { $0.id != main && $0.vision && $0.toolUse && !$0.isCloud }
        if let f = local.first(where: { $0.id == fastModel }) { return f.id }
        return local.first(where: { $0.loaded })?.id
    }

    func fastModel(for main: String) -> String? {
        guard autoRoute, !fastModel.isEmpty, fastModel != main, model(fastModel) != nil, !main.hasPrefix("cloud:") else { return nil }
        return fastModel
    }

    /// LM Studio: 确保模型已加载 (用 lms load 明确加载的模型不会被"按需加载"挤掉, 快慢两个模型可以同时留在内存里)
    func ensureLoaded(_ id: String) async {
        guard !id.hasPrefix("builtin:"), !id.hasPrefix("cloud:"), !id.hasPrefix("mlx:"), FileManager.default.fileExists(atPath: Self.lms) else { return }
        let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        if let url = URL(string: "\(LLMClient.base.absoluteString)/api/v0/models/\(enc)"),
           let (d, _) = try? await URLSession.shared.data(from: url),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any], obj["state"] as? String == "loaded" { return }
        // 正在加载 (例如预热触发的按需加载) 也算: 不要再加载第二份 (会变成 "id:2", 占两倍内存)
        if await MemoryBroker.lmsInstances().contains(where: { $0.modelKey == id || $0.identifier == id }) { return }
        await MemoryBroker.shared.prepareChat(id)
        let lms = Self.lms
        _ = await Task.detached { Exporter.shell(lms, ["load", id, "--ttl", "3600", "-y"]) }.value
        refresh()
    }

    /// 测速: 加载时间、读提示速度、输出速度 (固定的测试内容, 每次开头加随机数避免命中缓存)
    func benchmark(_ id: String) async -> String? {
        benchmarking = id
        defer { benchmarking = nil }
        var r: [String: Double] = ["date": Date().timeIntervalSince1970]
        do {
            let t0 = Date()
            _ = try await LLMClient.stream(model: id, messages: [["role": "user", "content": "hi"]], tools: nil, reasoning: "none", useDraft: false, maxTokens: 1) { _, _ in }
            r["load"] = Date().timeIntervalSince(t0)
            let filler = String(repeating: "Leonix 是一个在 Mac 本机运行的 AI 应用，可以聊天、修图、绘图、生成视频和操作电脑。", count: 40)
            let msgs: [[String: Any]] = [["role": "user", "content": "[\(UUID().uuidString)]\n" + filler + "\n请写一段 200 字左右的产品介绍。"]]
            let t1 = Date()
            var first: Date?
            let res = try await LLMClient.stream(model: id, messages: msgs, tools: nil, reasoning: "none", useDraft: false, maxTokens: 200) { c, _ in
                if first == nil, !c.isEmpty { first = Date() }
            }
            let end = Date()
            let st = res.stats
            let ttft = (first ?? end).timeIntervalSince(t1)
            r["ttft"] = ttft
            if let st, st.tokensPerSecond > 0 { r["gen"] = st.tokensPerSecond }
            else if let f = first { r["gen"] = Double(max(1, res.content.count / 2)) / max(0.1, end.timeIntervalSince(f)) }
            if let st, st.promptTokens > 0 { r["prompt"] = Double(st.promptTokens) / max(0.05, st.promptSeconds > 0 ? st.promptSeconds : ttft) }
            bench[id] = r
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private let providersFile = AppPaths.dataFile("providers.json")

    /// 自动压缩的触发点: 上下文的 75%, 但最多 3.2 万 token (再长读起来就明显变慢了)
    nonisolated static func compressThreshold(_ limit: Int) -> Int { min(Int(Double(limit) * 0.75), 32_000) }

    func draftModel(for id: String) -> String? {
        guard let d = draftModels[id], !d.isEmpty, models.contains(where: { $0.id == d }) else { return nil }
        return d
    }

    /// 能当草稿模型的: 本机 LM Studio 里比主模型小的对话模型 (同一系列才有用)
    func draftCandidates(for id: String) -> [LMModel] {
        localChatModels.filter { !$0.isBuiltin && $0.id != id }
    }

    /// 这个模型实际能用的上下文长度 (token)。LM Studio 看当前加载时设的长度; 没加载就按 LM Studio 默认的 4096 估。
    func contextLimit(_ id: String) async -> Int {
        if id.hasPrefix("builtin:") { return BuiltinEngine.contextSize }
        if id.hasPrefix("mlx:") { return 262_144 }
        if id.hasPrefix("cloud:") { return 128_000 }
        if let (n, t) = contextCache[id], Date().timeIntervalSince(t) < 30 { return n }
        var n = 0
        let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        if let url = URL(string: "\(LLMClient.base.absoluteString)/api/v0/models/\(enc)"),
           let (d, _) = try? await URLSession.shared.data(from: url),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            n = obj["loaded_context_length"] as? Int ?? 0
        }
        if n == 0 { n = 4096 }
        contextCache[id] = (n, Date())
        return n
    }

    init() {
        if let p = SafeJSON.load([Provider].self, from: providersFile) { providers = p }
    }

    private func saveProviders() {
        SafeJSON.save(providers, to: providersFile)
    }

    var cloudModels: [LMModel] {
        providers.flatMap { p in
            p.enabledModels.map { m in
                LMModel(id: "cloud:\(p.id.uuidString)/\(m)", type: Provider.guessVision(m) ? "vlm" : "llm", loaded: false,
                        context: 0, toolUse: true, providerName: p.name, remoteName: m)
            }
        }
    }
    var localChatModels: [LMModel] { models.filter { $0.isChat && !$0.id.contains("phonon") } }
    var chatModels: [LMModel] { localChatModels + cloudModels }
    var visionModels: [LMModel] { chatModels.filter { $0.vision } }
    func model(_ id: String) -> LMModel? { chatModels.first { $0.id == id } ?? models.first { $0.id == id } }

    /// 这个模型应该发到哪里
    func endpoint(_ id: String) -> Endpoint {
        if id.hasPrefix("cloud:") {
            let rest = id.dropFirst(6)
            if let slash = rest.firstIndex(of: "/"), let pid = UUID(uuidString: String(rest[..<slash])),
               let p = providers.first(where: { $0.id == pid }), let url = URL(string: p.baseURL) {
                return Endpoint(base: url, key: Keychain.get(p.id), model: String(rest[rest.index(after: slash)...]), isLocal: false, kind: p.kind)
            }
        }
        if id.hasPrefix("builtin:") {
            return Endpoint(base: BuiltinEngine.base.appendingPathComponent("v1"), key: nil, model: String(id.dropFirst(8)), isLocal: true, kind: "openai")
        }
        if let p = MTPPair.pair(for: id) {
            return Endpoint(base: MLXEngine.base.appendingPathComponent("v1"), key: nil, model: p.target?.path ?? p.key, isLocal: true, kind: "openai")
        }
        return Endpoint(base: LLMClient.base.appendingPathComponent("v1"), key: nil, model: id, isLocal: true, kind: "openai")
    }

    /// 修图脚本 (Python) 也要知道修图模型在哪
    func exportPhotoEndpoint() {
        let ep = endpoint(photoModel)
        let d = UserDefaults.standard
        let ownEngine = photoModel.hasPrefix("builtin:") || photoModel.hasPrefix("mlx:")
        d.set(ep.isLocal && !ownEngine ? "" : ep.base.absoluteString, forKey: "photoAPIBase")
        d.set(ep.model, forKey: "photoAPIModel")
        // 只记服务商 id, Key 用的时候再从钥匙串取
        var pid = ""
        if photoModel.hasPrefix("cloud:"), let slash = photoModel.dropFirst(6).firstIndex(of: "/") {
            pid = String(photoModel.dropFirst(6)[..<slash])
        }
        d.set(pid, forKey: "photoAPIProvider")
        d.removeObject(forKey: "photoAPIKeyCache")
        // Lightroom 插件单独运行时读这个文件, 知道用哪个模型 (不含 API Key)
        // (MTP 引擎只在 Leonix 运行时才开着, 插件单独用时改用 LM Studio 里的同一个模型)
        let lmFallback = MTPPair.pair(for: photoModel).flatMap { p in models.first { !$0.isMLX && !$0.isBuiltin && !$0.isCloud && p.lmStudioMatches($0.id) }?.id }
        let cfg: [String: Any] = lmFallback != nil ? ["base": "", "model": lmFallback!, "builtin": false, "cloud": false] :
            ["base": ep.isLocal && !photoModel.hasPrefix("builtin:") ? "" : ep.base.absoluteString,
             "model": ep.model, "builtin": photoModel.hasPrefix("builtin:"), "cloud": !ep.isLocal]
        if let data = try? JSONSerialization.data(withJSONObject: cfg, options: .prettyPrinted) {
            try? data.write(to: AppPaths.dataFile("photo_model.json"))
        }
    }

    nonisolated static let lms = NSHomeDirectory() + "/.lmstudio/bin/lms"

    /// 默认模型不存在时 (例如在别的电脑上), 自动换成已安装的最合适的模型
    func ensureDefaults() {
        let all = chatModels
        guard !all.isEmpty else { return }
        if model(chatModel) == nil, let best = all.max(by: {
            Recommender.score(localId: $0.id, vision: $0.vision, forPhoto: false) < Recommender.score(localId: $1.id, vision: $1.vision, forPhoto: false)
        }) { chatModel = best.id }
        let visions = all.filter(\.vision)
        if model(photoModel)?.vision != true, let best = visions.max(by: {
            Recommender.score(localId: $0.id, vision: true, forPhoto: true) < Recommender.score(localId: $1.id, vision: true, forPhoto: true)
        }) { photoModel = best.id }
    }

    @Published var lmOnline = false

    func refresh() {
        Task {
            var list: [LMModel] = []
            var lmErr: String?
            // 1) LM Studio
            if LocalEngine.installed {
                do {
                    var req = URLRequest(url: LLMClient.base.appendingPathComponent("api/v0/models"))
                    req.timeoutInterval = 5
                    let (data, _) = try await URLSession.shared.data(for: req)
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    list += ((json?["data"] as? [[String: Any]]) ?? []).compactMap { m in
                        guard let id = m["id"] as? String else { return nil }
                        let caps = m["capabilities"] as? [String] ?? []
                        return LMModel(id: id, type: m["type"] as? String ?? "llm", loaded: (m["state"] as? String) == "loaded",
                                       context: m["max_context_length"] as? Int ?? 0, toolUse: caps.contains("tool_use"))
                    }
                    lmOnline = true
                } catch {
                    lmOnline = false
                    lmErr = String(localized: "连不上 LM Studio（127.0.0.1:1234）")
                }
            } else { lmOnline = false }
            // 2) Leonix 内置引擎 (没在跑也列出已下载的模型, 用到时自动启动)
            if BuiltinEngine.installed {
                let eng = BuiltinEngine.shared
                let infos = await eng.check() ? await eng.models() : BuiltinEngine.offlineModels()
                list += infos.map { LMModel(id: "builtin:" + $0.id, type: $0.vision ? "vlm" : "llm", loaded: $0.loaded, context: BuiltinEngine.contextSize, toolUse: true) }
            }
            // 3) MTP 加速引擎 (用 LM Studio 的模型文件)
            for p in MTPPair.all where MLXEngine.shared.ready(p) {
                list.append(LMModel(id: p.id, type: "vlm", loaded: MLXEngine.shared.online, context: 262_144, toolUse: true))
            }
            models = list
            online = lmOnline || BuiltinEngine.installed
            lastError = online ? nil : (lmErr ?? String(localized: "本地 AI 引擎还没有安装"))
            ensureDefaults()
            exportPhotoEndpoint()
        }
    }

    func startServer() {
        if !LocalEngine.installed {
            Task { try? await BuiltinEngine.shared.ensureRunning(); refresh() }
            return
        }
        Task.detached {
            _ = Exporter.shell(ModelManager.lms, ["server", "start", "--port", "1234"])
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { self.refresh() }
        }
    }

    func unloadAll() {
        BuiltinEngine.shared.stop()
        MLXEngine.shared.stop()
        Task.detached {
            if FileManager.default.fileExists(atPath: ModelManager.lms) { _ = Exporter.shell(ModelManager.lms, ["unload", "--all"]) }
            await MainActor.run { self.refresh() }
        }
    }

    // MARK: 服务商管理

    func addProvider(_ preset: Provider.Preset) -> UUID {
        let p = Provider(name: preset.name, baseURL: preset.baseURL, needsKey: preset.needsKey, models: preset.defaults,
                         enabledModels: preset.defaults, kind: preset.kind)
        providers.append(p)
        return p.id
    }

    func updateProvider(_ id: UUID, _ f: (inout Provider) -> Void) {
        guard let i = providers.firstIndex(where: { $0.id == id }) else { return }
        f(&providers[i])
    }

    func removeProvider(_ id: UUID) {
        Keychain.set("", for: id)
        providers.removeAll { $0.id == id }
    }

    /// 从服务商获取模型列表. 返回错误信息 (nil = 成功)
    func fetchModels(_ id: UUID) async -> String? {
        guard let p = providers.first(where: { $0.id == id }), let base = URL(string: p.baseURL) else { return String(localized: "地址不对") }
        var req = URLRequest(url: base.appendingPathComponent("models"))
        req.timeoutInterval = 20
        LLMClient.authorize(&req, key: Keychain.get(id), kind: p.kind)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                return String(localized: "服务商返回错误 \(code)：\(String(String(decoding: data, as: UTF8.self).prefix(200)))")
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let ids = ((json?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
                .map { $0.replacingOccurrences(of: "models/", with: "") }.sorted()
            guard !ids.isEmpty else { return String(localized: "没有获取到模型") }
            updateProvider(id) { pr in
                pr.models = ids
                if pr.enabledModels.isEmpty { pr.enabledModels = Array(ids.prefix(3)) }
                pr.enabledModels = pr.enabledModels.filter { ids.contains($0) }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - 流式对话客户端 (OpenAI 兼容)

struct ToolCall: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var arguments: String

    var args: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]) ?? [:]
    }
}

struct LLMResult {
    var content = ""
    var reasoning = ""
    var toolCalls: [ToolCall] = []
    var finishReason: String?
    var stats: ChatStats?         // 引擎返回的用量 (本地引擎才有)
}

enum LLMError: LocalizedError {
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return String(localized: "模型服务返回错误 \(code)：\(String(body.prefix(400)))")
        }
    }
}

enum LLMClient {
    static let base = URL(string: "http://127.0.0.1:1234")!

    static func authorize(_ req: inout URLRequest, key: String?, kind: String) {
        guard let key, !key.isEmpty else { return }
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if kind == "anthropic" {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
    }

    /// 流式请求. onDelta(新增正文, 新增思考) 在主线程回调
    static func stream(model: String, messages: [[String: Any]], tools: [[String: Any]]?, reasoning: String,
                       useDraft: Bool = true, maxTokens: Int? = nil,
                       onDelta: @escaping @MainActor (String, String) -> Void) async throws -> LLMResult {
        // 统一调度内存: 这个模型还没在内存里就先腾地方; 用的期间标记为「正在用」, 不会被请去让位
        let tenant = MemoryBroker.Tenant.forModel(model)
        if let tenant {
            await MemoryBroker.shared.prepareChat(model)
            await MemoryBroker.shared.begin(tenant)
        }
        defer { if let tenant { Task { @MainActor in MemoryBroker.shared.end(tenant) } } }
        let ep = await ModelManager.shared.endpoint(model)
        let draft = useDraft && !model.hasPrefix("builtin:") && !model.hasPrefix("mlx:") && ep.isLocal ? await ModelManager.shared.draftModel(for: model) : nil
        if model.hasPrefix("builtin:") { try await BuiltinEngine.shared.ensureRunning() }
        if let p = MTPPair.pair(for: model) { try await MLXEngine.shared.ensureRunning(p) }
        // 用 LM Studio 里的同一个模型时, 先关掉 MTP 引擎 (两份要 60 GB 内存)
        if !model.hasPrefix("mlx:"), ep.isLocal, !model.hasPrefix("builtin:"),
           let p = MTPPair.all.first(where: { $0.lmStudioMatches(model) }), await MLXEngine.shared.online, await MLXEngine.shared.loadedTarget == p.target?.path {
            await MLXEngine.shared.stop()
        }
        var req = URLRequest(url: ep.base.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 3600
        authorize(&req, key: ep.key, kind: ep.kind)
        var body: [String: Any] = ["model": ep.model, "messages": messages, "stream": true]
        // 云端服务不一定认识 reasoning_effort, 只在需要思考时才发
        if ep.isLocal || reasoning != "none" { body["reasoning_effort"] = reasoning }
        if let tools, !tools.isEmpty { body["tools"] = tools }
        if ep.isLocal {
            body["stream_options"] = ["include_usage": true]   // 最后返回实际用量
            body["cache_prompt"] = true                          // llama.cpp: 复用相同开头的缓存
        }
        if let draft { body["draft_model"] = draft }             // LM Studio: 推测解码 (小模型打草稿)
        if let maxTokens { body["max_tokens"] = maxTokens }
        // 键排序: 工具说明每次序列化成一模一样的文字, 引擎的提示词缓存才能命中 (Swift 字典顺序是随机的)
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let started = Date()
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            var text = ""
            for try await line in bytes.lines { text += line }
            // 草稿模型和这个模型不配套时 LM Studio 会报错: 不用草稿再试一次
            if draft != nil {
                return try await stream(model: model, messages: messages, tools: tools, reasoning: reasoning, useDraft: false, maxTokens: maxTokens, onDelta: onDelta)
            }
            throw LLMError.http(h.statusCode, text)
        }
        var result = LLMResult()
        var calls: [Int: ToolCall] = [:]
        var pendingC = "", pendingR = ""
        var channels = ChannelFilter()
        var lastFlush = Date()
        var firstToken: Date?
        var stats = ChatStats()
        var gotStats = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            if let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
                if let u = obj["usage"] as? [String: Any] {
                    gotStats = true
                    stats.promptTokens = u["prompt_tokens"] as? Int ?? stats.promptTokens
                    stats.genTokens = u["completion_tokens"] as? Int ?? stats.genTokens
                    if let d = u["prompt_tokens_details"] as? [String: Any], let c = d["cached_tokens"] as? Int { stats.cachedTokens = c }
                }
                // llama.cpp 额外返回的计时
                if let t = obj["timings"] as? [String: Any] {
                    gotStats = true
                    let pn = t["prompt_n"] as? Int ?? 0, cn = t["cache_n"] as? Int ?? 0
                    if pn + cn > 0 { stats.promptTokens = pn + cn; stats.cachedTokens = cn }
                    if let ms = t["prompt_ms"] as? Double { stats.promptSeconds = ms / 1000 }
                    if let tps = t["predicted_per_second"] as? Double { stats.tokensPerSecond = tps }
                    if let n = t["predicted_n"] as? Int { stats.genTokens = n }
                }
            }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let choice = (obj["choices"] as? [[String: Any]])?.first else {
                if let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                   let err = obj["error"] { throw LLMError.http(500, "\(err)") }
                continue
            }
            if let fr = choice["finish_reason"] as? String { result.finishReason = fr }
            guard let delta = choice["delta"] as? [String: Any] else { continue }
            if let raw = delta["content"] as? String {
                if firstToken == nil, !raw.isEmpty { firstToken = Date() }
                // Gemma 4 把思考写在正文里 (<|channel>thought … <channel|>): 挪到思考过程里
                let (c, r) = channels.feed(raw)
                result.content += c; pendingC += c
                result.reasoning += r; pendingR += r
            }
            if let r = (delta["reasoning_content"] ?? delta["reasoning"]) as? String { result.reasoning += r; pendingR += r; if firstToken == nil, !r.isEmpty { firstToken = Date() } }
            if firstToken == nil, delta["tool_calls"] != nil { firstToken = Date() }
            if let tcs = delta["tool_calls"] as? [[String: Any]] {
                for tc in tcs {
                    let idx = tc["index"] as? Int ?? 0
                    var call = calls[idx] ?? ToolCall(id: "", name: "", arguments: "")
                    if let id = tc["id"] as? String, !id.isEmpty { call.id = id }
                    if let fn = tc["function"] as? [String: Any] {
                        if let n = fn["name"] as? String, !n.isEmpty { call.name = n }
                        if let a = fn["arguments"] as? String { call.arguments += a }
                    }
                    calls[idx] = call
                }
            }
            if Date().timeIntervalSince(lastFlush) > 0.05, !(pendingC.isEmpty && pendingR.isEmpty) {
                let c = pendingC, r = pendingR
                pendingC = ""; pendingR = ""; lastFlush = Date()
                await onDelta(c, r)
            }
        }
        let (tailC, tailR) = channels.flush()
        result.content += tailC; pendingC += tailC; result.reasoning += tailR; pendingR += tailR
        if !(pendingC.isEmpty && pendingR.isEmpty) { await onDelta(pendingC, pendingR) }
        if gotStats {
            // LM Studio 不返回计时: 用首个字出现的时间和总时间自己算
            let end = Date()
            if stats.promptSeconds == 0, let f = firstToken { stats.promptSeconds = f.timeIntervalSince(started) }
            if stats.tokensPerSecond == 0, let f = firstToken, stats.genTokens > 0, end.timeIntervalSince(f) > 0.05 {
                stats.tokensPerSecond = Double(stats.genTokens) / end.timeIntervalSince(f)
            }
            result.stats = stats
        }
        result.toolCalls = calls.keys.sorted().compactMap { calls[$0] }.map {
            var c = $0
            if c.id.isEmpty { c.id = "call_" + UUID().uuidString.prefix(8) }
            if c.arguments.isEmpty { c.arguments = "{}" }
            c.arguments = ToolCall.repairArguments(c.arguments)
            return c
        }
        if result.toolCalls.isEmpty, tools != nil, let x = ToolCall.extractFromText(result.content) {
            result.toolCalls = x.calls
            result.content = x.rest
        }
        return result
    }
}


/// Gemma 4 等模型把思考过程写在正文里: <|channel>thought …思考… <channel|> 正式回答。
/// 流式输出时把标记里面的内容分到「思考过程」, 标记本身去掉 (标记可能被拆在两段里, 所以先留着可能是标记开头的尾巴)。
struct ChannelFilter {
    static let open = "<|channel>", close = "<channel|>"
    private var inThought = false
    private var buffer = ""
    private var labelPending = false

    mutating func feed(_ s: String) -> (content: String, reasoning: String) {
        buffer += s
        var c = "", r = ""
        while true {
            let marker = inThought ? Self.close : Self.open
            if let range = buffer.range(of: marker) {
                let before = String(buffer[..<range.lowerBound])
                if inThought { r += stripLabel(before) } else { c += before }
                buffer = String(buffer[range.upperBound...])
                inThought.toggle()
                labelPending = inThought
                label = ""
                continue
            }
            // 末尾可能是标记的开头: 先留着
            var keep = 0
            for k in stride(from: min(marker.count - 1, buffer.count), to: 0, by: -1) where marker.hasPrefix(String(buffer.suffix(k))) { keep = k; break }
            let out = String(buffer.dropLast(keep))
            buffer = String(buffer.suffix(keep))
            if inThought { r += stripLabel(out) } else { c += out }
            return (c, r)
        }
    }

    /// 结束时剩下的部分
    mutating func flush() -> (content: String, reasoning: String) {
        defer { buffer = "" }
        return inThought ? ("", stripLabel(buffer)) : (buffer, "")
    }

    /// 思考段开头的 "thought" 标签不要 (标签也可能被拆开, 没收完整就先存着)
    private var label = ""
    private mutating func stripLabel(_ s: String) -> String {
        guard labelPending, !s.isEmpty else { return s }
        let t = label + s
        if "thought\n".hasPrefix(t) { label = t; return "" }
        label = ""
        labelPending = false
        var out = Substring(t)
        if out.hasPrefix("thought") { out = out.dropFirst(7) }
        if out.hasPrefix("\n") { out = out.dropFirst() }
        return String(out)
    }
}
