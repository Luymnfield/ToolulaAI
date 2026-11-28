import AppKit
import CoreImage
import SwiftUI

/// 一张照片
@MainActor
final class PhotoItem: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let isRaw: Bool
    let captureDate: Date?
    var name: String { url.lastPathComponent }

    /// AI 修图前的参数
    var base: Settings = [:]
    /// AI 给出的参数 (绝对值)
    var ai: Settings?
    /// AI 之后用户手动改的量 (叠加)
    var manual: Settings = [:]
    @Published var strength: Double = 100 { didSet { changed() } }

    @Published var preview: NSImage?
    @Published var original: NSImage?
    @Published var thumb: NSImage?
    @Published var status: String = ""
    @Published var analysis: String = ""
    @Published var busy = false

    // AI 识别照片 + 推荐方案
    @Published var scene = ""
    @Published var issues: [String] = []
    @Published var plans: [PhotoPlan] = []
    @Published var chosenPlan: UUID?
    @Published var recognizing = false

    // 局部调整 / AI 消除
    @Published var locals: [LocalAdjustment] = [] { didSet { changed() } }
    @Published var patches: [RetouchPatch] = [] { didSet { changed() } }
    @Published var showMask: MaskKind? { didSet { if showMask != oldValue { changed() } } }
    /// 人像精修 (磨皮、去瑕疵、眼袋、肤色均匀、光影塑形、眼睛、牙齿、嘴唇)
    @Published var portrait = PortraitRetouch() { didSet { if portrait != oldValue { changed() } } }
    let maskCache = MaskCache()
    var retouched: Bool { !patches.isEmpty || !portrait.isEmpty || locals.contains { $0.settings.contains { $0.value != 0 } } }

    // 选片 / 关键词
    @Published var score: Int?
    @Published var stars: Int = 0
    @Published var reject = false
    @Published var reason = ""
    @Published var title = ""
    @Published var caption = ""
    @Published var keywords: [String] = []

    /// 预览用的缩小底图 (已冻结成位图)
    var previewBase: CIImage?
    var revision = 0
    var onChange: (() -> Void)?

    init(url: URL) {
        self.url = url
        self.isRaw = Renderer.isRaw(url)
        self.captureDate = Renderer.captureDate(url)
    }

    /// 最终参数 = 原参数 + (AI - 原参数) × 强度 + 手动调整
    var settings: Settings {
        var out = base
        if let ai {
            let k = strength / 100
            for (key, v) in ai {
                let b = base[key] ?? 0
                out[key] = Params.noBlend.contains(key) ? v : b + (v - b) * k
            }
        }
        for (key, d) in manual { out[key] = Params.clamp(key, (out[key] ?? 0) + d) }
        return out.filter { $0.value != 0 || Params.noBlend.contains($0.key) }
    }

    func value(_ key: String) -> Double { settings[key] ?? 0 }

    func setValue(_ key: String, _ newValue: Double) {
        var without = manual
        without[key] = 0
        let saved = manual
        manual = without
        let current = settings[key] ?? 0
        manual = saved
        manual[key] = newValue - current
        if abs(manual[key]!) < 1e-9 { manual[key] = nil }
        changed()
    }

    /// 把当前结果"定下来"作为新的起点
    func commitAsBase() {
        base = settings
        ai = nil
        manual = [:]
    }

    func applyAI(_ s: Settings, analysis text: String) {
        base = settings
        var merged = base
        for (k, v) in s { merged[k] = v }
        ai = merged
        manual = [:]
        analysis = text
        changed()
    }

    func resetAll() {
        base = [:]; ai = nil; manual = [:]; strength = 100; analysis = ""
        locals = []; patches = []; showMask = nil
        changed()
    }

    func changed() {
        revision += 1
        objectWillChange.send()
        onChange?()
    }
}

enum BatchMode: String, CaseIterable, Identifiable {
    case group = "按场景分组（推荐）"
    case each = "每张单独分析"
    case all = "全部统一"
    var id: String { rawValue }
}

enum ViewMode: String, CaseIterable, Identifiable {
    case after = "修图效果"
    case split = "对比"
    case before = "原图"
    var id: String { rawValue }
}

enum ListFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case picks = "精选 ★4+"
    case hideRejects = "隐藏废片"
    var id: String { rawValue }
}

@MainActor
final class Store: ObservableObject {
    @Published var photos: [PhotoItem] = []
    @Published var selection: Set<UUID> = []
    @Published var style: String = UserDefaults.standard.string(forKey: "style") ?? Params.styles[0] {
        didSet { UserDefaults.standard.set(style, forKey: "style") }
    }
    @Published var customStyles: [String] = UserDefaults.standard.stringArray(forKey: "customStyles") ?? [] {
        didSet { UserDefaults.standard.set(customStyles, forKey: "customStyles") }
    }
    @Published var referenceURL: URL?
    @Published var referenceImage: NSImage?
    @Published var batchMode: BatchMode = .group
    @Published var selfCheck = UserDefaults.standard.bool(forKey: "selfCheck") {
        didSet { UserDefaults.standard.set(selfCheck, forKey: "selfCheck") }
    }
    @Published var useTaste = UserDefaults.standard.object(forKey: "useTaste") as? Bool ?? true {
        didSet { UserDefaults.standard.set(useTaste, forKey: "useTaste") }
    }
    @Published var viewMode: ViewMode = .after
    @Published var filter: ListFilter = .all
    @Published var status: String = ""
    @Published var working = false

    // AI 消除: 笔刷
    @Published var eraseMode = false { didSet { if !eraseMode { eraseStrokes = [] } } }
    @Published var eraseStrokes: [[CGPoint]] = []      // 0~1, 原点左上
    @Published var eraseBrush: Double = 0.025          // 笔刷半径占图片宽度的比例
    @Published var erasing = false
    @Published var alert: String?
    @Published var tasteSummary = ""
    var clipboard: Settings?
    var cancelRequested = false

    private let renderQueue = DispatchQueue(label: "render", qos: .userInitiated)
    static let previewSide: CGFloat = 2000

    // MARK: 选择

    var selectedItems: [PhotoItem] { photos.filter { selection.contains($0.id) } }
    var current: PhotoItem? {
        if let first = photos.first(where: { selection.contains($0.id) }) { return first }
        return nil
    }
    var visiblePhotos: [PhotoItem] {
        switch filter {
        case .all: return photos
        case .picks: return photos.filter { $0.stars >= 4 && !$0.reject }
        case .hideRejects: return photos.filter { !$0.reject }
        }
    }

    // MARK: 添加照片

    func add(urls: [URL]) {
        var files: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                let items = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []
                files += items.sorted { $0.lastPathComponent < $1.lastPathComponent }
            } else {
                files.append(u)
            }
        }
        let existing = Set(photos.map { $0.url })
        let new = files.filter { Renderer.imageExtensions.contains($0.pathExtension.lowercased()) && !existing.contains($0) }
            .map { PhotoItem(url: $0) }
        guard !new.isEmpty else { return }
        for item in new {
            item.onChange = { [weak self, weak item] in
                guard let self, let item else { return }
                self.scheduleRender(item)
            }
            photos.append(item)
            loadPreview(item)
        }
        if selection.isEmpty, let f = new.first { selection = [f.id] }
    }

    func remove(_ items: [PhotoItem]) {
        let ids = Set(items.map { $0.id })
        photos.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    // MARK: 渲染

    private func loadPreview(_ item: PhotoItem) {
        item.status = String(localized: "读取中…")
        let url = item.url
        renderQueue.async {
            let base = Renderer.shared.loadPreviewBase(url, maxSide: Store.previewSide)
            let orig = base.flatMap { Renderer.shared.makeNSImage($0) }
            let thumb = base.flatMap { Renderer.shared.makeNSImage(Renderer.shared.scale($0, maxSide: 160)) }
            DispatchQueue.main.async {
                item.previewBase = base
                item.original = orig
                item.preview = orig
                item.thumb = thumb
                item.status = base == nil ? String(localized: "无法读取") : ""
            }
        }
    }

    func scheduleRender(_ item: PhotoItem) {
        guard let base = item.previewBase else { return }
        let rev = item.revision
        let settings = item.settings
        let locals = item.locals, patches = item.patches, showMask = item.showMask, cache = item.maskCache, portrait = item.portrait
        renderQueue.async {
            // 只渲染最新的一次 (拖动滑块时跳过中间状态)
            var stale = false
            DispatchQueue.main.sync { stale = rev != item.revision }
            if stale { return }
            let out = Renderer.shared.renderEdited(base, settings: settings, patches: patches, locals: locals, portrait: portrait, cache: cache, showMask: showMask)
            let img = Renderer.shared.makeNSImage(out)
            let thumb = Renderer.shared.makeNSImage(Renderer.shared.scale(out, maxSide: 160))
            DispatchQueue.main.async {
                guard rev == item.revision else { return }
                item.preview = img
                item.thumb = thumb
            }
        }
    }

    /// 把当前效果渲染成 1024 像素 JPEG 给 AI 看
    nonisolated func renderForAI(base: CIImage, settings: Settings, name: String, patches: [RetouchPatch] = [],
                                 locals: [LocalAdjustment] = [], portrait: PortraitRetouch = PortraitRetouch(), maxSide: CGFloat = 1024) -> URL? {
        let r = Renderer.shared
        let img = r.renderEdited(r.scale(base, maxSide: maxSide), settings: settings, patches: patches, locals: locals, portrait: portrait, cache: MaskCache())
        let url = AIBridge.workDir.appendingPathComponent("ai_\(name)_\(UUID().uuidString.prefix(6)).jpg")
        do { try r.writeJPEG(img, to: url, quality: 0.85) } catch { return nil }
        return url
    }

    // MARK: 参考图

    func setReference(_ url: URL?) {
        referenceURL = url
        referenceImage = url.flatMap { NSImage(contentsOf: $0) }
    }

    private func referenceJPEG() -> URL? {
        guard let referenceURL else { return nil }
        let dest = AIBridge.workDir.appendingPathComponent("reference.jpg")
        try? FileManager.default.removeItem(at: dest)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        p.arguments = ["-s", "format", "jpeg", "-s", "formatOptions", "85", "-Z", "1024", referenceURL.path, "--out", dest.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return FileManager.default.fileExists(atPath: dest.path) ? dest : nil
    }

    // MARK: AI 修图

    func cancel() { cancelRequested = true; status = String(localized: "正在停止…") }

    func aiEdit() {
        let selected = selectedItems
        guard !selected.isEmpty, !working else { return }
        working = true
        cancelRequested = false
        let style = self.style, selfCheck = self.selfCheck, useTaste = self.useTaste
        Task {
            // 刚导入的 RAW 还在解码时就点了 AI 修图: 先等它们加载好 (以前会悄悄跳过还没加载完的照片)
            let t0 = Date()
            while selected.contains(where: { $0.previewBase == nil }) && Date().timeIntervalSince(t0) < 120 && !cancelRequested {
                let n = selected.filter { $0.previewBase != nil }.count
                status = String(localized: "等照片加载：\(n)/\(selected.count)")
                try? await Task.sleep(for: .milliseconds(300))
            }
            let targets = selected.filter { $0.previewBase != nil }
            guard !targets.isEmpty else { status = ""; working = false; return }
            let groups = makeGroups(targets)
            let ref = await Task.detached { await self.referenceJPEG() }.value
            if self.referenceURL != nil && ref == nil { self.alert = String(localized: "无法读取参考图"); self.working = false; return }
            var failed = 0
            for (gi, group) in groups.enumerated() {
                if cancelRequested { break }
                let rep = group[group.count / 2]
                status = String(localized: "AI 修图：第 \(gi + 1)/\(groups.count) 组 · \(rep.name)") + (gi == 0 ? String(localized: "（第一次要加载模型）") : "")
                group.forEach { $0.busy = true }
                let ok = await analyze(rep, style: style, ref: ref, selfCheck: selfCheck, useTaste: useTaste)
                if ok, let s = rep.ai {
                    for other in group where other !== rep {
                        other.applyAI(s, analysis: String(localized: "（与 \(rep.name) 同一场景，使用相同参数）"))
                        // 同一场景的人像精修也一起用 (蒙版和瑕疵是每张照片自己找的)
                        if !rep.portrait.isEmpty { other.portrait = rep.portrait }
                    }
                } else {
                    failed += group.count
                }
                group.forEach { $0.busy = false }
                if rep.status.contains("1234") { break }  // 连不上本地 AI
            }
            status = failed > 0 ? String(localized: "完成，\(failed) 张失败") : String(localized: "AI 修图完成")
            working = false
        }
    }

    private func makeGroups(_ items: [PhotoItem]) -> [[PhotoItem]] {
        switch batchMode {
        case .each: return items.map { [$0] }
        case .all: return [items]
        case .group:
            let sorted = items.sorted { ($0.captureDate ?? .distantPast) < ($1.captureDate ?? .distantPast) }
            var groups: [[PhotoItem]] = []
            var last: Date?
            for it in sorted {
                if let d = it.captureDate, let l = last, d.timeIntervalSince(l) <= 20 * 60, !groups.isEmpty {
                    groups[groups.count - 1].append(it)
                } else {
                    groups.append([it])
                }
                if let d = it.captureDate { last = d } else { last = nil }
            }
            return groups
        }
    }

    /// 分析一张照片 (可选二次检查). 返回是否成功
    private func analyze(_ item: PhotoItem, style: String, ref: URL?, selfCheck: Bool, useTaste: Bool) async -> Bool {
        guard let base = item.previewBase else { return false }
        let current = item.settings
        let name = item.name
        let patches = item.patches, cache = item.maskCache, portrait0 = item.portrait
        let scene = StylePicks.scene(of: item)
        let result: (Settings, String, String?, PortraitRetouch?) = await Task.detached {
            guard let img = self.renderForAI(base: base, settings: current, name: name, patches: patches, portrait: portrait0) else { return ([:], "", String(localized: "无法生成预览"), nil) }
            var req: [String: Any] = ["style": style, "is_raw": false, "current": AIBridge.numeric(current), "use_taste": useTaste]
            if let a = cache.portraitAnalysis(for: base) { req["portrait"] = ["faces": a.faceCount, "face_size": Double(a.faceWidth)] }
            if let m = self.measureForAI(base: base, settings: current, patches: patches, portrait: portrait0, cache: cache) { req["measure"] = m }
            if let h = StylePicks.hint(scene: scene) { req["picks_hint"] = h }
            let r = AIBridge.run("analyze", image: img, reference: ref, request: req)
            if let e = r.error { return ([:], "", e, nil) }
            var s = AIBridge.settings(from: r)
            var text = r.kv["__analysis"] ?? ""
            var portrait = Self.retouch(from: r)
            if selfCheck {
                var merged = current
                for (k, v) in s { merged[k] = v }
                if let img2 = self.renderForAI(base: base, settings: merged, name: name + "_check", patches: patches, portrait: portrait ?? portrait0) {
                    var req2: [String: Any] = ["style": style, "is_raw": false, "current": AIBridge.numeric(merged), "use_taste": false]
                    req2["portrait"] = req["portrait"]
                    if let m = self.measureForAI(base: base, settings: merged, patches: patches, portrait: portrait ?? portrait0, cache: cache) { req2["measure"] = m }
                    let r2 = AIBridge.run("refine", image: img2, reference: ref, request: req2)
                    if r2.error == nil {
                        for (k, v) in AIBridge.settings(from: r2) { s[k] = v }
                        if let p2 = Self.retouch(from: r2) { portrait = p2 }
                        if let t = r2.kv["__analysis"], !t.isEmpty { text += "\n\n" + String(localized: "【二次检查】") + t }
                    }
                }
            }
            // 自动检查: AI 的参数有没有把高光修爆、暗部压死
            var merged = current
            for (k, v) in s { merged[k] = v }
            let (fixed, note) = self.guardSettings(base: base, before: current, after: merged, patches: patches, portrait: portrait ?? portrait0)
            // 只改自动检查动过的参数 (其他的照旧, 手动调过的不会被算两次)
            for (k, v) in fixed where merged[k] != v { s[k] = v }
            // 鲜活度检查: 颜色比专业修图明显偏淡时自动加自然饱和度
            var merged2 = merged
            for (k, v) in fixed { merged2[k] = v }
            let isLandscape = ((req["measure"] as? [String: Any])?["landscape"] as? Bool) == true
            let faces = cache.portraitAnalysis(for: base)
            let sceneKind = faces != nil ? "portrait" : isLandscape ? "landscape" : "other"
            let r0 = Renderer.shared, small0 = r0.scale(base, maxSide: PhotoMeasure.side)
            // 本来就要淡的风格 (黑白、低饱和、莫兰迪、清冷、胶片、褪色…) 或者 AI 自己明显降了饱和度: 不加
            let muted = ["黑白", "去色", "低饱和", "淡雅", "莫兰迪", "清冷", "冷色", "褪色", "胶片", "复古", "暗调", "高调", "黑金", "宝丽来", "日系",
                         "black", "white", "mono", "muted", "film", "vintage", "faded"].contains { style.lowercased().contains($0) }
                || (merged2["Saturation"] ?? 0) <= -30
            // 风光收尾 (先按颜色区域补齐, 再整体检查鲜活度)
            if !muted && sceneKind == "landscape" {
                let (fin, fnote) = PhotoMeasure.finishLandscape(merged2) { st in
                    r0.renderEdited(small0, settings: st, patches: patches, locals: [], portrait: portrait ?? portrait0, cache: MaskCache())
                }
                for (k, v) in fin where merged2[k] != v { s[k] = v; merged2[k] = v }
                if let fnote { text += "\n\n" + fnote }
            }
            let (vivid, vnote) = muted ? (merged2, nil) : PhotoMeasure.guardVividness(merged2, scene: sceneKind, skin: faces?.skin) { st in
                r0.renderEdited(small0, settings: st, patches: patches, locals: [], portrait: portrait ?? portrait0, cache: MaskCache())
            }
            for (k, v) in vivid where merged2[k] != v { s[k] = v }
            if let vnote { text += "\n\n" + vnote }
            // 地平线检测在没有清楚地平线的照片上会出错 (实测一张湖景: 歪 2.5°, Vision 说 5.6°), 所以不自动拉正, 由用户在「构图」里点
            if let note { text += "\n\n" + note }
            return (s, text, nil, portrait)
        }.value
        if let e = result.2 {
            item.status = e
            alert = e
            return false
        }
        item.applyAI(result.0, analysis: result.1)
        if let p = result.3 { item.portrait = p }
        item.status = String(localized: "AI 已修")
        return true
    }

    /// 在当前效果上量曝光、过曝、偏色、肤色, 交给 AI (Leonix 量得比模型看缩略图准)
    nonisolated func measureForAI(base: CIImage, settings: Settings, patches: [RetouchPatch], portrait: PortraitRetouch, cache: MaskCache) -> [String: Any]? {
        let r = Renderer.shared
        let small = r.scale(base, maxSide: PhotoMeasure.side * 2)
        let img = r.renderEdited(small, settings: settings, patches: patches, locals: [], portrait: portrait, cache: MaskCache())
        let faces = cache.portraitAnalysis(for: base)
        guard let st0 = PhotoMeasure.stats(img, skin: faces?.skin) else { return nil }
        var m = PhotoMeasure.forAI(st0)
        // 白平衡: 量出把中性色校正到完全中性大约要偏移多少 (看图判断偏色不准, 尤其是室内暖光)
        if st0.neutralShare > 0.03, max(abs(st0.castA), abs(st0.castB)) > 4 {
            var t = settings["IncrementalTemperature"] ?? 0, n = settings["IncrementalTint"] ?? 0
            let start = (t, n)
            var cur = st0
            for _ in 0..<4 {
                guard abs(cur.castB) > 2 || abs(cur.castA) > 2 else { break }
                t = Params.clamp("IncrementalTemperature", t - cur.castB * 1.6)
                n = Params.clamp("IncrementalTint", n - cur.castA * 1.6)
                var s2 = settings; s2["IncrementalTemperature"] = t; s2["IncrementalTint"] = n
                guard let next = PhotoMeasure.stats(r.renderEdited(small, settings: s2, patches: patches, locals: [], portrait: portrait, cache: MaskCache())) else { break }
                cur = next
            }
            let dt = Int((t - start.0).rounded()), dn = Int((n - start.1).rounded())
            if abs(dt) >= 5 || abs(dn) >= 5 { m["wb_fix"] = "TempShift \(dt >= 0 ? "+" : "")\(dt), TintShift \(dn >= 0 ? "+" : "")\(dn)" }
        }
        // 风光: 天空和植被占多少、地平线歪了多少 (没有人脸、天空或植被够多时算风光照)
        if faces == nil {
            // 和「局部调整」用同一套蒙版 (同样的大小、同一份缓存), 两边判断一致
            func share(_ k: MaskKind) -> Double {
                let mask: CIImage? = cache.get(k) ?? Masks.compute(k, for: base, cache: cache).map { cache.set(k, $0); return $0 }
                guard let mask else { return 0 }
                let avg = mask.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: mask.extent)])
                var v = [Float](repeating: 0, count: 4)
                r.context.render(avg, toBitmap: &v, rowBytes: 16, bounds: CGRect(x: mask.extent.minX, y: mask.extent.minY, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                return Double(v[0])
            }
            let sky = share(.sky), green = share(.greenery)
            // 有语义分割模型时: 画面构成 (天空、山、水面、树木…各占多少)
            var parts: [(String, Int)] = []
            if SceneSegmenter.installed {
                let small = r.scale(base, maxSide: 1536)
                if let cg = r.context.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: r.sRGB), let c = cache.segmentation(cg) {
                    parts = SceneSegmenter.shared.composition(c)
                }
            }
            let natural = parts.contains { ["山", "水面", "树木", "草地", "雪"].contains($0.0) && $0.1 >= 10 }
            if sky > 0.08 || green > 0.15 || natural {
                m["landscape"] = true
                // 天空有多亮、有多少已经过曝 (风光修图最怕把天空修白)
                if sky > 0.05, let skyMask = cache.get(.sky), let st = PhotoMeasure.stats(img, skin: skyMask), let k = st.skin {
                    m["sky_luma"] = Int((k.luma * 100).rounded())
                }
                m["sky"] = Int((sky * 100).rounded())
                m["greenery"] = Int((green * 100).rounded())
                if !parts.isEmpty { m["parts"] = parts.map { "\($0.0) \($0.1)%" }.joined(separator: "、") }
            }
        }
        return m
    }

    /// AI 修完后的自动检查: 高光修爆 / 暗部压死就往回收
    nonisolated func guardSettings(base: CIImage, before: Settings, after: Settings, patches: [RetouchPatch], portrait: PortraitRetouch) -> (Settings, String?) {
        let r = Renderer.shared
        let small = r.scale(base, maxSide: PhotoMeasure.side)
        return PhotoMeasure.guardClipping(before: before, after: after) { s in
            r.renderEdited(small, settings: s, patches: patches, locals: [], portrait: portrait, cache: MaskCache())
        }
    }

    /// AI 给出的人像精修 (__retouch=key|value), 没有就是 nil
    nonisolated static func retouch(from r: AIBridge.Result) -> PortraitRetouch? {
        let lines = r.lists["__retouch"] ?? []
        guard !lines.isEmpty else { return nil }
        var p = PortraitRetouch()
        for line in lines {
            let parts = line.split(separator: "|").map(String.init)
            if parts.count == 2, PortraitRetouch.keys.contains(parts[0]), let v = Double(parts[1]) { p[parts[0]] = v }
        }
        return p
    }

    // MARK: AI 消除

    func eraseNow() {
        guard let item = current, !eraseStrokes.isEmpty, !erasing else { return }
        let strokes = eraseStrokes, brush = CGFloat(eraseBrush), url = item.url, existing = item.patches
        erasing = true
        status = Inpainter.installed ? String(localized: "AI 正在消除…") : String(localized: "第一次使用：下载消除模型（约 216 MB）…")
        Task {
            defer { erasing = false }
            do {
                let p = try await Task.detached {
                    try await Inpainter.shared.remove(url: url, existing: existing, strokes: strokes, brush: brush) { got in
                        Task { @MainActor in
                            if !Inpainter.installed { self.status = String(localized: "下载消除模型：\(SystemInfo.size(got)) / 216 MB") }
                        }
                    }
                }.value
                item.patches.append(p)
                eraseStrokes = []
                status = String(localized: "已消除（可以继续涂，或撤销）")
            } catch {
                status = error.localizedDescription
                alert = String(localized: "消除失败：\(error.localizedDescription)")
            }
        }
    }

    func undoErase() {
        guard let item = current, !item.patches.isEmpty else { return }
        item.patches.removeLast()
        status = String(localized: "已撤销一次消除")
    }

    // MARK: 局部调整

    func addLocal(_ area: MaskKind) {
        guard let item = current else { return }
        let l = LocalAdjustment(area: area)
        item.locals.append(l)
        // 只在 Lightroom 里生效的区域: Leonix 里找不到也留着 (发送到 Lightroom 时由它的 AI 蒙版做)
        if MaskKind.lightroomOnly.contains(area) { return }
        // 先确认能找到这个区域
        if let base = item.previewBase {
            let cache = item.maskCache
            Task {
                let found = await Task.detached { () -> Bool in
                    if cache.get(area) != nil { return true }
                    guard let m = Masks.compute(area, for: base, cache: cache) else { return false }
                    cache.set(area, m)
                    return true
                }.value
                if !found {
                    item.locals.removeAll { $0.id == l.id }
                    if item.showMask == area { item.showMask = nil }
                    alert = String(localized: "这张照片里没有找到「\(area.label)」")
                }
            }
        }
    }

    // MARK: 识别照片 + 推荐方案

    /// 先让 AI 看看照片: 说出场景和问题, 给 3 个带解释的方案, 用户再决定用哪个、在哪里继续修
    func recognize() {
        guard let item = current, !item.recognizing, let base = item.previewBase else { return }
        let current = item.settings, name = item.name, useTaste = self.useTaste, isRaw = item.isRaw, patches = item.patches
        let portraitNow = item.portrait
        let scene = StylePicks.scene(of: item)
        item.recognizing = true
        item.status = String(localized: "AI 正在识别照片…")
        status = String(localized: "AI 正在识别照片…")
        let cache = item.maskCache
        item.scene = ""; item.issues = []; item.plans = []; item.chosenPlan = nil
        Task {
            let r: AIBridge.Result = await Task.detached {
                // 识别只需要看清内容和光线: 768 像素足够, 图片 token 少一半, 读得更快
                guard let img = self.renderForAI(base: base, settings: current, name: name + "_suggest", patches: patches, maxSide: 768) else {
                    return AIBridge.Result(error: String(localized: "无法生成预览"))
                }
                var req: [String: Any] = ["is_raw": isRaw, "current": AIBridge.numeric(current), "use_taste": useTaste]
                if let a = cache.portraitAnalysis(for: base) { req["portrait"] = ["faces": a.faceCount, "face_size": Double(a.faceWidth)] }
                if let m = self.measureForAI(base: base, settings: current, patches: patches, portrait: portraitNow, cache: cache) { req["measure"] = m }
                if let h = StylePicks.hint(scene: scene) { req["picks_hint"] = h }
                // 一边写一边显示: 场景、问题、每个方案读到就先出来
                return AIBridge.run("suggest", image: img, request: req) { partial in
                    Task { @MainActor in if item.recognizing { self.showPlans(partial, on: item, final: false) } }
                }
            }.value
            item.recognizing = false
            if let e = r.error { item.status = e; alert = e; status = e; return }
            showPlans(r, on: item, final: true)
            item.chosenPlan = nil
            item.status = String(localized: "已识别")
            status = String(localized: "识别完成：选一个方案预览")
        }
    }

    /// 把识别结果 (可能还没写完) 显示出来
    private func showPlans(_ r: AIBridge.Result, on item: PhotoItem, final: Bool) {
            item.scene = r.kv["scene"] ?? ""
            item.issues = r.lists["issue"] ?? []
            let old = item.plans
            item.plans = (0..<3).compactMap { i in
                let p = "p\(i)."
                guard let n = r.kv[p + "name"], !n.isEmpty else { return nil }
                let changes: [PhotoPlan.Change] = (r.lists[p + "change"] ?? []).compactMap { line in
                    let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                    guard parts.count == 3 else { return nil }
                    return PhotoPlan.Change(key: parts[0], value: parts[1], reason: parts[2])
                }
                var s = Settings()
                for line in r.lists[p + "set"] ?? [] {
                    let parts = line.split(separator: "|").map(String.init)
                    if parts.count == 2, let v = Double(parts[1]) { s[parts[0]] = Params.clamp(parts[0], v) }
                }
                // 局部调整: area|param|value|reason
                var locals: [MaskKind: LocalAdjustment] = [:]
                var localChanges: [PhotoPlan.Change] = []
                for line in r.lists[p + "local"] ?? [] {
                    let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                    guard parts.count == 4, let area = MaskKind(rawValue: parts[0]), let v = Double(parts[2]) else { continue }
                    var l = locals[area] ?? LocalAdjustment(area: area, note: String(localized: "AI 推荐"))
                    l.settings[parts[1]] = v
                    locals[area] = l
                    localChanges.append(PhotoPlan.Change(key: parts[1], value: parts[2], reason: parts[3], area: area))
                }
                // 人像精修: key|value|reason (写在方案前面的是 3 个方案共用的)
                var portrait = PortraitRetouch()
                var retouchChanges: [PhotoPlan.Change] = []
                let own = r.lists[p + "retouch"] ?? []
                for line in own.isEmpty ? (r.lists["retouch"] ?? []) : own {
                    let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                    guard parts.count >= 2, let v = Double(parts[1]), PortraitRetouch.keys.contains(parts[0]) else { continue }
                    portrait[parts[0]] = v
                    retouchChanges.append(PhotoPlan.Change(key: parts[0], value: parts[1], reason: parts.count > 2 ? parts[2] : "", retouch: true))
                }
                var plan = PhotoPlan(name: n, why: r.kv[p + "why"] ?? "", style: r.kv[p + "style"] ?? "", changes: changes + localChanges + retouchChanges,
                                     settings: s, locals: Array(locals.values), portrait: portrait,
                                     complete: final || r.kv[p + "done"] != nil)
                if i < old.count { plan.id = old[i].id }   // 同一个方案保持同一个 id (界面不会跳)
                return plan
            }
    }

    /// 在 Leonix 里预览某个方案 (之后可以继续微调, 或发送到别的软件)
    func applyPlan(_ plan: PhotoPlan, to item: PhotoItem) {
        let before = item.settings
        item.applyAI(plan.settings, analysis: "【\(plan.name)】\(plan.why)")
        item.locals = plan.locals
        item.portrait = plan.portrait
        item.chosenPlan = plan.id
        item.status = String(localized: "已应用方案：\(plan.name)")
        // 自动检查: 这个方案会不会把高光修爆、暗部压死
        guard let base = item.previewBase else { return }
        let after = item.settings, patches = item.patches, portrait = item.portrait, manual = item.manual, planId = plan.id
        Task {
            let (fixed, note) = await Task.detached { self.guardSettings(base: base, before: before, after: after, patches: patches, portrait: portrait) }.value
            guard let note, item.chosenPlan == planId, item.ai != nil else { return }
            for (k, v) in fixed where after[k] != v { item.ai?[k] = v - (manual[k] ?? 0) }
            item.analysis += "\n\n" + note
            item.changed()
        }
    }

    /// 按这个方案让 AI 再完整精修一遍
    func refinePlan(_ plan: PhotoPlan) {
        style = plan.style
        aiEdit()
    }

    // MARK: 选片 / 关键词

    func cull() {
        runPerPhoto(title: String(localized: "AI 选片")) { item, img in
            let r = AIBridge.run("cull", image: img)
            return { [weak item] in
                guard let item else { return r.error }
                if let e = r.error { return e }
                item.score = r.number("score").map { Int($0) }
                item.stars = Int(r.number("stars") ?? 0)
                item.reject = (r.number("reject") ?? 0) == 1
                item.reason = r.kv["reason"] ?? ""
                return nil
            }
        }
    }

    func tag() {
        runPerPhoto(title: String(localized: "AI 关键词")) { item, img in
            let r = AIBridge.run("tag", image: img)
            return { [weak item] in
                guard let item else { return r.error }
                if let e = r.error { return e }
                item.title = r.kv["title"] ?? ""
                item.caption = r.kv["caption"] ?? ""
                item.keywords = r.lists["keyword"] ?? []
                return nil
            }
        }
    }

    /// 逐张: 在后台跑 work, 回到主线程执行它返回的更新
    private func runPerPhoto(title: String, work: @escaping @Sendable (PhotoItem, URL) -> (@MainActor () -> String?)) {
        let targets = selectedItems.filter { $0.previewBase != nil }
        guard !targets.isEmpty, !working else { return }
        working = true
        cancelRequested = false
        Task {
            var failed = 0
            for (i, item) in targets.enumerated() {
                if cancelRequested { break }
                status = String(localized: "\(title)：\(i + 1)/\(targets.count) · \(item.name)")
                item.busy = true
                let base = item.previewBase!, settings = item.settings, name = item.name
                let update = await Task.detached { () -> (@MainActor () -> String?) in
                    guard let img = self.renderForAI(base: base, settings: settings, name: name) else { return { String(localized: "无法生成预览") } }
                    return work(item, img)
                }.value
                if let e = update() {
                    failed += 1
                    alert = e
                    item.busy = false
                    if e.contains("1234") { break }  // 连不上本地 AI
                    continue
                }
                item.busy = false
            }
            status = failed > 0 ? String(localized: "\(title)完成，\(failed) 张失败") : String(localized: "\(title)完成")
            working = false
        }
    }

    // MARK: 学习习惯

    /// 导出时记录: AI 给的 vs 你最后定下的, 用来学习你的口味
    func recordForLearning(_ items: [PhotoItem]) {
        let pairs: [(String, [String: Any], [String: Any])] = items.compactMap { item in
            guard let ai = item.ai else { return nil }
            var applied = item.base
            let k = item.strength / 100
            for (key, v) in ai { let b = item.base[key] ?? 0; applied[key] = Params.noBlend.contains(key) ? v : b + (v - b) * k }
            return (item.id.uuidString, AIBridge.numeric(applied), AIBridge.numeric(item.settings))
        }
        guard !pairs.isEmpty else { return }
        Task.detached {
            _ = AIBridge.run("record", request: ["photos": pairs.map { ["uuid": $0.0, "applied": $0.1] }])
            _ = AIBridge.run("learn", request: ["photos": pairs.map { ["uuid": $0.0, "current": $0.2] }])
            let t = AIBridge.run("taste")
            await MainActor.run { self.tasteSummary = t.kv["summary"] ?? "" }
        }
    }


    func refreshTaste() {
        Task.detached {
            let t = AIBridge.run("taste")
            await MainActor.run { self.tasteSummary = t.kv["summary"] ?? "" }
        }
    }

    func resetTaste() {
        Task.detached {
            let t = AIBridge.run("taste", extra: ["--reset"])
            await MainActor.run { self.tasteSummary = t.kv["summary"] ?? "" }
        }
    }

    // MARK: 复制 / 粘贴 / 同步

    func copySettings() { clipboard = current?.settings }

    func pasteSettings() {
        guard let clip = clipboard else { return }
        for item in selectedItems { item.base = clip; item.ai = nil; item.manual = [:]; item.changed() }
    }

    func syncFromCurrent() {
        guard let cur = current else { return }
        let s = cur.settings
        for item in selectedItems where item !== cur { item.base = s; item.ai = nil; item.manual = [:]; item.changed() }
    }

    func saveCustomStyle() {
        let s = style.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !customStyles.contains(s), !Params.styles.contains(s) else { return }
        customStyles.append(s)
    }
}


/// AI 推荐的一个修图方案
struct PhotoPlan: Identifiable {
    struct Change: Identifiable {
        let id = UUID()
        let key: String
        let value: String
        let reason: String
        var area: MaskKind? = nil
        /// 人像精修项目 (key 是 smooth / blemish ...)
        var retouch = false

        /// 参数的显示名字
        var label: String {
            if retouch { return String(localized: "人像") + " · " + (PortraitRetouch.specs.first { $0.key == key }?.label.loc ?? key) }
            if let area { return area.label + " · " + (LocalAdjustment.params.first { $0.key == key }?.label.loc ?? key) }
            switch key {
            case "TempShift": return String(localized: "色温")
            case "TintShift": return String(localized: "色调")
            default: break
            }
            for kind in ["Hue", "Saturation", "Luminance"] where key.hasPrefix(kind + "Adjustment") {
                let color = Params.colors.first { key.hasSuffix($0.key) }?.label.loc ?? ""
                let k = kind == "Hue" ? String(localized: "色相") : kind == "Saturation" ? String(localized: "饱和度") : String(localized: "明亮度")
                return "HSL \(k) · \(color)"
            }
            if key.hasPrefix("Parametric"), let s = Params.specByKey[key] { return String(localized: "曲线") + " · " + s.label.loc }
            if key.hasPrefix("SplitToning"), let s = Params.specByKey[key] { return String(localized: "颜色分级") + " · " + s.label.loc }
            return Params.specByKey[key]?.label.loc ?? key
        }
        var display: String {
            if key == "Exposure2012" { return value + " EV" }
            if key == "TempShift", let v = Double(value) { return value + (v < 0 ? String(localized: "（更冷）") : String(localized: "（更暖）")) }
            return value
        }
    }
    var id = UUID()
    let name: String
    let why: String
    let style: String
    let changes: [Change]
    let settings: Settings
    var locals: [LocalAdjustment] = []
    var portrait = PortraitRetouch()
    /// AI 还在写这个方案的参数 (识别结果是一边写一边显示的)
    var complete = true
}
