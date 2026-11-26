import Foundation

/// 绘图 / 视频页的预热: 打开页面就在后台启动 ComfyUI, 内存够时把当前选中的模型先加载好,
/// 第一次生成不用再等 15~50 秒。离开页面一段时间后自动释放内存。
///
/// 内存策略:
/// - 只在 Toolula 自己启动的 ComfyUI 里预加载和释放 (用户自己开着的 Comfy Desktop 不去动它)
/// - 不会为了预热卸载对话模型; 估算放不下就只启动 ComfyUI, 等真正生成时再按原来的流程处理
/// - MiniMax H3 (约 97GB) 永远不预加载
@MainActor
enum ComfyWarmup {
    /// 离开页面多久后卸载模型 / 关掉 ComfyUI
    static var unloadAfter: Duration = .seconds(300)
    static var stopAfter: Duration = .seconds(1800)
    /// 预加载时给系统和其他程序留的内存
    static let marginGB = 8.0

    private static var visible: Set<String> = []
    private static var warmTask: Task<Void, Never>?
    private static var releaseTask: Task<Void, Never>?
    /// 最近一次预热的结果 (自测和日志用)
    private(set) static var lastResult = ""

    static var isWarming: Bool { warmTask != nil }
    static var enabled: Bool { UserDefaults.standard.object(forKey: "comfyWarmup") as? Bool ?? true }

    /// 用户在设置里开关预热。打开: 正在看的绘图/视频页马上预热; 关闭: 不再排队预热,
    /// 已经预加载好的模型立刻卸载腾出内存 (正在生成时不动, Comfy Desktop 不动)。
    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "comfyWarmup")
        if on {
            for p in visible.sorted() { enter(p) }
            return
        }
        queue.removeAll()
        Task {
            await warmTask?.value          // 正在跑的小任务等它跑完, 中途打断 ComfyUI 反而更慢
            guard !enabled, !busy, ComfyEngine.shared.owned, ComfyEngine.shared.online else { return }
            await ComfyEngine.shared.free()
            ImageStore.shared.modelsUnloaded()
            VideoStore.shared.modelsUnloaded()
            lastResult = "预热已关闭，已释放模型内存"
            Run.appendLog("[预热] \(lastResult)\n")
        }
    }

    /// 打开了绘图 ("image") 或视频 ("video") 页, 或者在页面里换了模型
    static func enter(_ page: String) {
        visible.insert(page)
        releaseTask?.cancel(); releaseTask = nil
        guard enabled else { return }
        if !queue.contains(page) { queue.append(page) }
        guard warmTask == nil else { return }   // 正在预热别的: 排队, 做完接着做
        warmTask = Task {
            while !queue.isEmpty {
                let p = queue.removeFirst()
                if visible.contains(p) { await warm(p) }
            }
            warmTask = nil
        }
    }
    private static var queue: [String] = []

    /// 离开页面: 都不在看了就开始倒计时释放
    static func leave(_ page: String) {
        visible.remove(page)
        guard visible.isEmpty else { return }
        releaseTask?.cancel()
        releaseTask = Task {
            try? await Task.sleep(for: unloadAfter)
            guard !Task.isCancelled, visible.isEmpty, !busy, ComfyEngine.shared.owned else { return }
            await ComfyEngine.shared.free()
            ImageStore.shared.modelsUnloaded()
            VideoStore.shared.modelsUnloaded()
            lastResult = "已释放模型内存"
            try? await Task.sleep(for: stopAfter)
            guard !Task.isCancelled, visible.isEmpty, !busy, ComfyEngine.shared.owned else { return }
            ComfyEngine.shared.stopOwned()
            await ComfyEngine.shared.check()
            lastResult = "已关闭空闲的 ComfyUI"
        }
    }

    private static var busy: Bool { ImageStore.shared.running || VideoStore.shared.running }

    /// 模型放得下吗: 按模型文件大小估算, 和现在没被占用的内存比
    static func fits(_ needGB: Double) -> Bool { MemoryBroker.shared.fits(needGB) }

    private static func warm(_ page: String) async {
        guard !busy else { return }
        let engine = ComfyEngine.shared
        let wasOnline = engine.online
        await engine.start()
        guard engine.online else { lastResult = "ComfyUI 没有启动"; return }
        guard engine.owned else { lastResult = wasOnline ? "用的是用户自己开着的 ComfyUI，不预加载" : "ComfyUI 没有启动"; return }
        guard !busy, visible.contains(page) else { return }

        let graph: [String: Any]
        let need: Double
        let key: String
        if page == "image" {
            let models = ImageModels.shared
            models.scan()
            let spec = models.selected
            guard models.isReady(spec), let files = models.installed[spec.id] else { lastResult = "图片模型还没下载"; return }
            guard !ImageStore.shared.isLoaded(spec.id) else { lastResult = "\(spec.name) 已加载"; return }
            guard var g = spec.graph(prompt: "warm up", width: 256, height: 256, count: 1, seed: 1, files: files) else { return }
            // 只预览不保存: 不会出现在图片记录里
            g["9"] = ["class_type": "PreviewImage", "inputs": ["images": ["10", 0]]]
            graph = g; key = spec.id
            need = spec.files.reduce(0) { $0 + $1.sizeGB } * 1.15
        } else {
            let models = VideoModels.shared
            models.scan()
            let spec = models.selected
            guard spec.id != VideoModelSpec.h3.id else { lastResult = "MiniMax H3 太大，不预加载"; return }
            guard models.isReady(spec), let files = models.installed[spec.id] else { lastResult = "视频模型还没下载"; return }
            guard !VideoStore.shared.isLoaded(spec.id) else { lastResult = "\(spec.name) 已加载"; return }
            let p = VideoJobParams(prompt: "warm up", width: 256, height: 256, seconds: 0.2, seed: 1, turbo: true, firstFrame: nil)
            guard var g = spec.graph(p, files: files) else { return }
            g["15"] = nil
            g["16"] = ["class_type": "PreviewImage", "inputs": ["images": ["9", 0]]]
            graph = g; key = spec.id
            need = spec.files.filter { !$0.optional }.reduce(0) { $0 + $1.sizeGB } * 1.15
        }
        guard fits(need) else {
            lastResult = String(format: "内存不够预加载 (需要约 %.0f GB)，只启动了 ComfyUI", need)
            return
        }
        let t0 = Date()
        guard await engine.runQuietly(graph) else { lastResult = "预加载失败"; return }
        if page == "image" { ImageStore.shared.markLoaded(key) } else { VideoStore.shared.markLoaded(key) }
        lastResult = String(format: "已预加载 %@ (%.0f 秒)", key, Date().timeIntervalSince(t0))
        Run.appendLog("[预热] \(lastResult)\n")
    }
}

extension ComfyEngine {
    /// 提交一个工作流并等它跑完 (不监听进度, 不保存结果)。成功返回 true
    func runQuietly(_ graph: [String: Any], timeout: TimeInterval = 600) async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("prompt"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["prompt": graph, "client_id": "toolula-warmup"])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let pid = obj["prompt_id"] as? String else { return false }
        let t0 = Date()
        while Date().timeIntervalSince(t0) < timeout {
            try? await Task.sleep(for: .seconds(1))
            guard let (hd, _) = try? await URLSession.shared.data(from: base.appendingPathComponent("history/\(pid)")),
                  let hist = (try? JSONSerialization.jsonObject(with: hd) as? [String: Any])?[pid] as? [String: Any] else { continue }
            let status = hist["status"] as? [String: Any]
            if status?["status_str"] as? String == "error" { return false }
            if status?["completed"] as? Bool == true { return true }
        }
        return false
    }
}
