import AppKit
import SwiftUI

/// 自测开关只在自测构建里存在: `./build_app.sh --selftest` (编译条件 TOOLULA_SELFTEST)。
/// 正式版里这些命令行参数全部无效。
enum SelfTest {
    #if TOOLULA_SELFTEST
    static let isActive = CommandLine.arguments.contains("--snapshot")
    #else
    static let isActive = false
    #endif
}

#if TOOLULA_SELFTEST
extension AppDelegate {
    /// 自测: 模拟一台什么都没装的 Mac (不影响真实文件, 只影响检测结果)
    func applySelfTestFlags() {
        let args = CommandLine.arguments
        if args.contains("--sim-fresh") {
            LocalEngine.simulateMissing = true
            ComfyEngine.simulateMissing = true
            PythonRuntime.simulateMissing = true
        }
        if args.contains("--prefer-managed-comfy") { ComfyEngine.preferManaged = true }
        if args.contains("--no-exiftool") { Exporter.simulateNoExiftool = true }
    }

    /// 开发自测:
    ///   ToolulaAI --snapshot out.png [--section chat|photo|automation|models] [--chat "消息" [--auto-approve]]
    ///             [--ai 风格] [--split] [--export 文件夹] 照片...
    func runSelfTestIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        func val(_ flag: String) -> String? {
            guard let j = args.firstIndex(of: flag), j + 1 < args.count else { return nil }
            return args[j + 1]
        }
        let out = URL(fileURLWithPath: args[i + 1])
        if let r = val("--sim-ram").flatMap(Double.init) { Recommender.simulatedRAM = r }
        if args.contains("--sim-intel") { Recommender.simulateIntel = true }
        let values = Set(["--snapshot", "--section", "--chat", "--ai", "--export", "--download", "--gh-import", "--sim-ram", "--video", "--video-model", "--bench", "--setup-install", "--setup-model", "--chat-model", "--image", "--image-model", "--local", "--show-mask", "--erase", "--brush", "--link", "--diagnostics", "--quick", "--hotkey-test"].compactMap(val))
        let files = args.dropFirst().filter { !values.contains($0) && !$0.hasPrefix("--")
            && Renderer.imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard let store = self.store, let chat = self.chat, let app = self.app else { return }
            if let s = val("--section"), let sec = AppSection.allCases.first(where: { "\($0)" == s }) { app.section = sec }
            var log = ""
            if !files.isEmpty {
                store.add(urls: files.map { URL(fileURLWithPath: $0) })
                try? await Task.sleep(for: .seconds(2))
                store.selection = Set(store.photos.map { $0.id })
                store.viewMode = args.contains("--split") ? .split : .after
            }
            if args.contains("--recognize"), let item = store.current {
                let t0 = Date()
                store.recognize()
                try? await Task.sleep(for: .seconds(1))
                while item.recognizing { try? await Task.sleep(for: .seconds(0.5)) }
                log += "recognize: \(String(format: "%.1f", Date().timeIntervalSince(t0)))s\nscene: \(item.scene)\nissues: \(item.issues)\n"
                for p in item.plans {
                    log += "plan \(p.name): \(p.why) | " + p.changes.map { "\($0.label) \($0.display) (\($0.reason))" }.joined(separator: "; ") + " | settings=\(p.settings.count)\n"
                }
                if item.plans.count > 1 { store.applyPlan(item.plans[1], to: item); try? await Task.sleep(for: .seconds(2)) }
            }
            if let style = val("--ai") {
                store.style = style
                store.aiEdit()
                while store.working { try? await Task.sleep(for: .seconds(1)) }
                try? await Task.sleep(for: .seconds(1.5))
            }
            if let spec = val("--local"), let item = store.current {
                // 例: "sky:Highlights2012=-60,Exposure2012=-0.3;face:Exposure2012=0.5"
                var ls: [LocalAdjustment] = []
                for part in spec.split(separator: ";") {
                    let kv = part.split(separator: ":", maxSplits: 1)
                    guard kv.count == 2, let area = MaskKind(rawValue: String(kv[0])) else { continue }
                    var l = LocalAdjustment(area: area)
                    for p in kv[1].split(separator: ",") {
                        let x = p.split(separator: "=")
                        if x.count == 2, let v = Double(x[1]) { l.settings[String(x[0])] = v }
                    }
                    ls.append(l)
                }
                if let base = item.previewBase {
                    for k in MaskKind.allCases {
                        let t0 = Date()
                        let m = await Task.detached { Masks.compute(k, for: base) }.value
                        log += "mask \(k.rawValue): \(m == nil ? "not found" : "ok") \(String(format: "%.2f", Date().timeIntervalSince(t0)))s\n"
                    }
                }
                item.locals = ls
                if let sm = val("--show-mask").flatMap(MaskKind.init(rawValue:)) { item.showMask = sm }
                try? await Task.sleep(for: .seconds(3))
            }
            if let er = val("--erase"), let item = store.current {
                store.eraseMode = true
                store.eraseBrush = val("--brush").flatMap(Double.init) ?? 0.03
                store.eraseStrokes = er.split(separator: "|").map { s in
                    s.split(separator: ";").compactMap { p -> CGPoint? in
                        let c = p.split(separator: ",").compactMap { Double($0) }
                        return c.count == 2 ? CGPoint(x: c[0], y: c[1]) : nil
                    }
                }
                let t0 = Date()
                store.eraseNow()
                try? await Task.sleep(for: .seconds(1))
                while store.erasing { try? await Task.sleep(for: .seconds(0.5)) }
                log += "erase: patches=\(item.patches.count) \(String(format: "%.1f", Date().timeIntervalSince(t0)))s status=\(store.status) alert=\(store.alert ?? "-")\n"
                try? await Task.sleep(for: .seconds(2))
            }
            if let dirPath = val("--export") {
                let dir = URL(fileURLWithPath: dirPath)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for job in store.jobs(store.photos) {
                    let e1 = await Task.detached { Exporter.exportJPEG(job, to: dir, maxSide: nil) }.value
                    let lr = await Task.detached { Exporter.prepareForLightroom(job, folder: dir.appendingPathComponent("lr")) }.value
                    log += "jpeg: \(e1 ?? "ok")\nlr: \(lr.0?.path ?? "-") \(lr.1 ?? "ok")\n"
                }
            }
            if let repo = val("--download") {
                let dl = ModelDownloader.shared
                dl.download(repo)
                while let j = dl.jobs.first(where: { $0.id == repo }), !j.done && !j.failed { try? await Task.sleep(for: .seconds(1)) }
                let j = dl.jobs.first { $0.id == repo }
                log += "download: \(j?.state ?? "-") \(j?.received ?? 0)/\(j?.total ?? 0) installed=\(ModelDownloader.isInstalled(repo))\n"
            }
            if args.contains("--lut-test") {
                // 1) 空参数 -> 必须是恒等 LUT; 2) 饱和度 -100 -> 每个输出都是灰色
                func parse(_ t: String) -> [[Double]] {
                    t.split(separator: "\n").compactMap { l -> [Double]? in
                        if let f = l.first, f.isLetter || f == "#" { return nil }
                        let v = l.split(separator: " ").compactMap { Double($0) }
                        return v.count == 3 ? v : nil
                    }
                }
                let n = 33
                let id = parse(Integrations.cube(for: [:], title: "id") ?? "")
                var maxErr = 0.0
                for (k, v) in id.enumerated() {
                    let r = Double(k % n) / 32, g = Double((k / n) % n) / 32, b = Double(k / (n * n)) / 32
                    maxErr = max(maxErr, abs(v[0] - r), abs(v[1] - g), abs(v[2] - b))
                }
                let gray = parse(Integrations.cube(for: ["Saturation": -100], title: "bw") ?? "")
                let grayErr = gray.map { max(abs($0[0] - $0[1]), abs($0[1] - $0[2])) }.max() ?? 1
                log += "lut identity entries=\(id.count) maxErr=\(String(format: "%.4f", maxErr)) | bw maxChannelDiff=\(String(format: "%.4f", grayErr))\n"
            }
            if let link = val("--gh-import"), let p = GitHub.parse(link) {
                do {
                    let list = try await GitHub.skills(in: p.repo, branch: p.branch, onlyPath: p.path)
                    log += "gh: repo=\(p.repo) branch=\(p.branch ?? "-") path=\(p.path ?? "-") skills=\(list.map(\.name))\n"
                    if let s = list.first {
                        let risks = GitBrowserRisk.scan(s)
                        log += "gh: files=\(s.files.count) risks=\(risks)\n"
                        let err = await SkillStore.shared.importSkill(s)
                        let saved = SkillStore.shared.skills.first { $0.source == p.repo && $0.name == s.name }
                        log += "gh: import err=\(err ?? "none") folder=\(saved?.folder ?? "-") localFiles=\(saved.map { SkillStore.shared.fileList($0).count } ?? 0)\n"
                        if let saved { log += "gh: update=\((try? await SkillStore.shared.checkUpdate(saved)) == nil ? "up to date" : "update available")\n" }
                    }
                } catch { log += "gh error: \(error.localizedDescription)\n" }
            }
            log += "recommend: RAM=\(Recommender.ramGB) appleSilicon=\(Recommender.appleSilicon) budget=\(String(format: "%.1f", Recommender.budgetGB)) advice=\(Recommender.advice)\n"
            for p in Recommender.picks() {
                log += "  \(p.role): \(p.best.map { "\($0.id.split(separator: "/").last!) \($0.sizeGB)GB" } ?? "-") | alt: \(p.alt.map { "\($0.id.split(separator: "/").last!) \($0.sizeGB)GB" } ?? "-")\n"
            }
            log += "defaults: chat=\(ModelManager.shared.chatModel) photo=\(ModelManager.shared.photoModel)\n"
            if let l = val("--link").flatMap(URL.init(string:)) {
                self.handleLink(l)
                try? await Task.sleep(for: .seconds(1))
                log += "link: \(l.absoluteString) -> section=\(app.section) computerPanel=\(ComputerControl.shared.showPanel) conversations=\(chat.conversations.count)\n"
            }
            if args.contains("--setup") || val("--setup-install") != nil {
                let st = SetupWizardState.shared
                st.detect()
                st.show = true
                try? await Task.sleep(for: .seconds(1))
                log += "setup items: " + st.items.map { "\($0.title) [\(String(format: "%.2f", $0.sizeGB))GB on=\($0.on)]" }.joined(separator: " | ") + "\n"
                log += "setup ready: " + st.ready.map(\.text).joined(separator: " | ") + "\nsetup notes: " + st.notes.joined(separator: " | ") + "\n"
                if let which = val("--setup-install") {
                    let want = Set(which.split(separator: ","))
                    // --setup-model 仓库:量化 换成小模型测试, 不用下载 30GB
                    if let sm = val("--setup-model"), let c = sm.lastIndex(of: ":") {
                        let e = Recommender.Entry(id: String(sm[..<c]), role: .allround, sizeGB: 2, score: 1, note: "test", gguf: String(sm[sm.index(after: c)...]))
                        if let i = st.items.firstIndex(where: { if case .chatModel = $0.kind { return true }; return false }) {
                            st.items[i] = SetupWizardState.Item(kind: .chatModel(e), icon: "eye", title: "test model", detail: "", sizeGB: 2, on: true)
                        } else {
                            st.items.append(SetupWizardState.Item(kind: .chatModel(e), icon: "eye", title: "test model", detail: "", sizeGB: 2, on: true))
                        }
                    }
                    for i in st.items.indices {
                        let k: String
                        switch st.items[i].kind {
                        case .builtinEngine: k = "engine"
                        case .python: k = "python"
                        case .chatModel: k = "model"
                        case .comfy: k = "comfy"
                        case .videoModel: k = "video"
                        case .imageModel: k = "image"
                        }
                        st.items[i].on = want.contains(Substring(k)) || want.contains("all")
                    }
                    let t0 = Date()
                    st.start()
                    try? await Task.sleep(for: .seconds(1))
                    while st.running { try? await Task.sleep(for: .seconds(2)) }
                    log += "setup install (\(Int(Date().timeIntervalSince(t0)))s): " + st.items.map { "\($0.title)=\($0.status)" }.joined(separator: " | ") + "\n"
                    try? await Task.sleep(for: .seconds(3))
                    log += "local models: " + ModelManager.shared.localChatModels.map { "\($0.id)\($0.vision ? "[vision]" : "")" }.joined(separator: ", ") + "\n"
                    log += "python: \(PythonRuntime.path) ready=\(PythonRuntime.ready) | comfy installed=\(ComfyEngine.installed) managed=\(ComfySetup.installed)\n"
                }
            }
            if let cm = val("--chat-model") { ModelManager.shared.chatModel = cm; ModelManager.shared.photoModel = cm }
            if let mid = val("--video-model") {
                VideoModels.shared.scan()
                VideoModels.shared.selectedId = mid
                if args.contains("--video-download") {
                    let vm = VideoModels.shared
                    vm.download(vm.selected)
                    while let j = vm.downloading[mid], !j.done && !j.failed { try? await Task.sleep(for: .seconds(2)) }
                    log += "video-download: \(vm.downloading[mid]?.state ?? "-") ready=\(vm.isReady(vm.selected))\n"
                }
                log += "roots: \(VideoModels.modelRoots.map(\.path)) installed: \(VideoModels.shared.installed)\n"
                log += "video-model: \(VideoModels.shared.selected.name) ready=\(VideoModels.shared.isReady(VideoModels.shared.selected)) recommended=\(VideoModels.shared.recommended?.name ?? "-")\n"
            }
            if let ip = val("--image") {
                let im = ImageModels.shared
                im.scan()
                if let mid = val("--image-model") { im.selectedId = mid }
                let st = ImageStore.shared
                let t0 = Date()
                let made = await st.generate(prompt: ip, aspect: .wide, quality: .standard, count: 1)
                log += "image: \(im.selected.name) \(made.map { "\($0.path) \($0.width)x\($0.height)" }.joined(separator: ", ")) \(Int(Date().timeIntervalSince(t0)))s est=\(Int(st.estimateSeconds))s err=\(st.error ?? "-")\n"
                if args.contains("--image-twice") {
                    let t1 = Date()
                    let m2 = await st.generate(prompt: ip, aspect: .wide, quality: .standard, count: 1)
                    log += "image2 (loaded): \(m2.first?.path ?? "-") \(Int(Date().timeIntervalSince(t1)))s est=\(Int(st.estimateSeconds))s\n"
                }
            }
            if let vp = val("--video") {
                let vs = VideoStore.shared
                vs.autoFree = false
                let item = await vs.generate(prompt: vp, seconds: 2, quality: .p480, aspect: .wide)
                log += "video: \(item.map { "\($0.path) \($0.width)x\($0.height) \(Int($0.elapsed))s" } ?? "failed: \(vs.error ?? "-")")\n"
                vs.autoFree = true
            }
            if let dd = val("--diagnostics") {
                do {
                    let zip = try await Diagnostics.export(to: URL(fileURLWithPath: dd))
                    log += "diagnostics: \(zip.path)\n"
                } catch { log += "diagnostics error: \(error.localizedDescription)\n" }
            }
            if args.contains("--hotkey-check") {
                log += "hotkey check: \(HotKeyCenter.shared.quickAsk.display) error=\(HotKeyCenter.shared.error ?? "-") conflict(⌘Space)=\(HotKey(keyCode: 49, modifiers: 256).systemConflict ?? "-")\n"
                if args.contains("--hotkey-press") {
                    // 模拟在别的程序里按下快捷键 (需要辅助功能权限)
                    let k = HotKeyCenter.shared.quickAsk
                    var flags: CGEventFlags = []
                    if k.modifiers & 2048 != 0 { flags.insert(.maskAlternate) }
                    if k.modifiers & 256 != 0 { flags.insert(.maskCommand) }
                    if k.modifiers & 4096 != 0 { flags.insert(.maskControl) }
                    if k.modifiers & 512 != 0 { flags.insert(.maskShift) }
                    for down in [true, false] {
                        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(k.keyCode), keyDown: down)
                        e?.flags = flags
                        e?.post(tap: .cghidEventTap)
                    }
                    try? await Task.sleep(for: .seconds(1))
                    log += "hotkey press: trusted=\(AXIsProcessTrusted()) panelVisible=\(QuickAsk.shared.isVisible)\n"
                    QuickAsk.shared.close()
                }
            }
            if let q = val("--quick") {
                // 快速提问小窗: 显示, 提问, 等回答完, 单独截一张小窗的图
                log += "hotkey: \(HotKeyCenter.shared.quickAsk.display) error=\(HotKeyCenter.shared.error ?? "-")\n"
                if let k = val("--hotkey-test") {
                    // 例: "49:2048" (Space + ⌥)
                    let p = k.split(separator: ":").compactMap { UInt32($0) }
                    if p.count == 2 { log += "hotkey set \(HotKey(keyCode: p[0], modifiers: p[1]).display): \(HotKeyCenter.shared.set(HotKey(keyCode: p[0], modifiers: p[1])) ?? "ok")\n" }
                }
                let qa = QuickAsk.shared
                qa.show()
                qa.text = q
                try? await Task.sleep(for: .seconds(0.5))
                qa.ask()
                let qid = qa.conversationId
                try? await Task.sleep(for: .seconds(1))
                while let qid, chat.running.contains(qid) { try? await Task.sleep(for: .seconds(0.5)) }
                try? await Task.sleep(for: .seconds(1.5))
                if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "quick-ask" }), let v = w.contentView,
                   let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: out.deletingPathExtension().appendingPathExtension("quick.png"))
                }
                let c = chat.conversations.first { $0.id == qid }
                log += "quick: selectedUnchanged=\(chat.selected != qid) agent=\(c?.agent ?? true) answer=\(c?.messages.last?.text.prefix(200) ?? "-") error=\(c?.messages.last?.error ?? "-")\n"
                if args.contains("--quick-continue") {
                    qa.continueInAssistant()
                    try? await Task.sleep(for: .seconds(1))
                    log += "quick continue: section=\(app.section) selected=\(chat.selected == qid) panelVisible=\(qa.isVisible)\n"
                }
                qa.close()
                if let qid { chat.delete(qid) }
            }
            if args.contains("--wait") { try? await Task.sleep(for: .seconds(4)) }
            log += "scroller style: \(NSScroller.preferredScrollerStyle == .overlay ? "overlay" : "legacy")\n"
            log += "apps: " + EditorApp.allCases.map { "\($0.rawValue)=\($0.url?.path ?? "not installed")" }.joined(separator: " | ") + "\n"
            log += "windows: " + NSApp.windows.map { $0.identifier?.rawValue ?? "nil" }.joined(separator: ", ") + "\n"
            if args.contains("--mtp-install") {
                let p = MTPPair.qwen38_27b
                let t0 = Date()
                await MLXEngine.shared.install(p)
                log += "mtp install: ready=\(MLXEngine.shared.ready(p)) \(String(format: "%.0f", Date().timeIntervalSince(t0)))s error=\(MLXEngine.shared.error ?? "-") target=\(p.target?.path ?? "-")\n"
                ModelManager.shared.refresh(); try? await Task.sleep(for: .seconds(2))
                log += "models: \(ModelManager.shared.localChatModels.map(\.displayName))\n"
            }
            if let bm = val("--bench") {
                let e = await ModelManager.shared.benchmark(bm)
                log += "bench \(bm): \(e ?? "ok") \(ModelManager.shared.bench[bm] ?? [:])\n"
            }
            if args.contains("--route-test") {
                let mm = ModelManager.shared
                let (oldFast, oldAuto) = (mm.fastModel, mm.autoRoute)
                mm.fastModel = mm.localChatModels.first { $0.id != mm.chatModel }?.id ?? ""
                mm.autoRoute = true
                for q in ["你好", "把这句话翻译成英文：今天天气很好", "帮我整理一下下载文件夹", "写一个 Python 脚本批量改名", "MLX 和 GGUF 有什么区别？", "打开 Chrome 搜索天气", "讲个笑话"] {
                    var c = Conversation(model: mm.chatModel)
                    c.messages = [ChatMessage(role: "user", text: q)]
                    log += "route \(q) -> \(chat.routeModel(c) == c.model ? "主模型" : "快模型")\n"
                }
                mm.fastModel = oldFast; mm.autoRoute = oldAuto
            }
            if args.contains("--warm-test") {
                // 自测: 先预热再发第一句话, 看开始回答前等了多久
                app.section = .chat
                let id = chat.newConversation()
                if !args.contains("--no-warm") {
                    // 和真实使用一样: 打开新对话后, 对话页会自动预热当前对话
                    let t0 = Date()
                    try? await Task.sleep(for: .seconds(2))
                    log += "warm task: \(chat.warming == nil ? "none" : "started")\n"
                    await chat.warming?.value
                    log += "warm error: \(ChatStore.lastWarmError ?? "-")\n"
                    log += "warm-up took \(String(format: "%.1f", Date().timeIntervalSince(t0)))s\n"
                    try? await Task.sleep(for: .seconds(3))
                }
                chat.send("你好，用一句话介绍你自己。不要调用工具。")
                try? await Task.sleep(for: .seconds(1))
                while chat.running.contains(id) { try? await Task.sleep(for: .seconds(0.5)) }
                if let c = chat.conversations.first(where: { $0.id == id }) {
                    log += "warm-test: \(String(describing: c.lastStats))\n"
                }
                chat.delete(id)
            }
            if args.contains("--compress-test") {
                // 自测: 造一个较长的对话 (含很长的工具结果), 压缩, 再问早期的细节, 看摘要有没有保住关键信息
                app.section = .chat
                let id = chat.newConversation()
                var listing = ""
                for i in 0..<120 { listing += "/Users/demo/QingShan/Sources/Feature\(i)/View\(i).swift  \(1000 + i * 37) bytes\n" }
                listing += "/Users/demo/QingShan/Sources/Map/MapView.swift  48211 bytes\n"
                let call = ToolCall(id: "call_t1", name: "run_shell", arguments: "{\"command\":\"find ~/QingShan -name '*.swift' -size +1k\"}")
                chat.update(id) { c in
                    c.title = "压缩自测"
                    c.messages = [
                        ChatMessage(role: "user", text: "我叫小林，在用 SwiftUI 做一个叫「青山」的旅行 App，项目在 ~/QingShan。"),
                        ChatMessage(role: "assistant", text: "你好小林！「青山」听起来不错，需要我帮你看哪部分？"),
                        ChatMessage(role: "user", text: "帮我看看项目里有哪些 Swift 文件。"),
                        ChatMessage(role: "assistant", text: "", toolCalls: [call]),
                        ChatMessage(role: "tool", text: listing, toolCallId: "call_t1", toolName: "run_shell"),
                        ChatMessage(role: "assistant", text: "项目里有 121 个 Swift 文件，最大的是 Sources/Map/MapView.swift（48 KB）。"),
                        ChatMessage(role: "user", text: "地图页加载很慢，可能是什么原因？"),
                        ChatMessage(role: "assistant", text: "MapView 每次出现都会重新请求全部 POI（大约 3000 个），而且在主线程解析 JSON。建议：1）把 POI 缓存到本地；2）改成按可见区域分页加载；3）JSON 解析放到后台。"),
                        ChatMessage(role: "user", text: "好，先做缓存。用什么存比较好？"),
                        ChatMessage(role: "assistant", text: "3000 个 POI 不算多，用 SwiftData 存就行，每条记 id、坐标、名称和更新时间，启动时先读缓存再后台刷新。"),
                        ChatMessage(role: "user", text: "明白了，谢谢。"),
                        ChatMessage(role: "assistant", text: "不客气，有需要再叫我。"),
                    ]
                }
                let t0 = Date()
                let ok = await chat.compress(id)
                let c1 = chat.conversations.first { $0.id == id }
                log += "compress ok=\(ok) \(String(format: "%.1f", Date().timeIntervalSince(t0)))s tokens=\(c1?.compressedTokens ?? [])\nsummary:\n\(c1?.summary ?? "-")\n"
                chat.send("我叫什么？项目叫什么、在哪个文件夹？地图页慢的原因是什么，我们决定先做什么、用什么存？请简短回答。不要调用工具。")
                try? await Task.sleep(for: .seconds(1))
                while chat.running.contains(id) { try? await Task.sleep(for: .seconds(1)) }
                if let c = chat.conversations.first(where: { $0.id == id }) {
                    log += "answer: \(c.messages.last?.text ?? "-")\nstats: \(String(describing: c.lastStats))\nused: \(chat.usedTokens(c))\n"
                }
                if !args.contains("--keep-test-chat") { chat.delete(id) }
            }
            if let msg = val("--chat") {
                app.section = .chat
                let id = chat.newConversation()
                if args.contains("--auto-approve") { chat.update(id) { $0.autoApprove = true } }
                chat.send(msg)
                try? await Task.sleep(for: .seconds(1))
                while chat.running.contains(id) { try? await Task.sleep(for: .seconds(1)) }
                try? await Task.sleep(for: .seconds(1))
                for m in chat.current?.messages ?? [] {
                    log += "[\(m.role)] \(m.text.prefix(300)) \(m.toolCalls.map { "\($0.name)(\($0.arguments))" }.joined(separator: ", ")) \(m.error ?? "")\n"
                }
            }
            try? await Task.sleep(for: .seconds(1))
            if let w0 = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil }), let w = Optional(w0.attachedSheet ?? w0), let v = w.contentView,
               let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out)
            }
            log += store.photos.map { "\($0.name)\t\($0.status)\t\($0.analysis.prefix(120))\t\($0.settings.count) params" }.joined(separator: "\n")
            log += "\nmachine: \(SystemInfo.shared.summary)\nalert: \(store.alert ?? "-")\ntaste: \(store.tasteSummary)\n"
            try? log.write(to: out.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
            SetupWizardState.shared.show = false   // 打开着的窗口会挡住退出
            try? await Task.sleep(for: .seconds(0.5))
            if args.contains("--keep-test-chat") == false, val("--chat") != nil, let id = chat.selected { chat.delete(id) }
            NSApp.terminate(nil)
        }
    }
}
#endif
