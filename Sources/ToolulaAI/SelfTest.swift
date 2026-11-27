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
import Carbon.HIToolbox

/// 用 CGEvent 模拟按键 (自测用)
enum SelfTestKeys {
    static let named: [String: Int] = ["return": kVK_Return, "down": kVK_DownArrow, "up": kVK_UpArrow, "esc": kVK_Escape,
                                       "tab": kVK_Tab, "space": kVK_Space, "k": kVK_ANSI_K, "n": kVK_ANSI_N, ",": kVK_ANSI_Comma]
    static func post(_ step: String) {
        if step.hasPrefix("text:") {
            for ch in step.dropFirst(5) {
                let u = Array(String(ch).utf16)
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                    e?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
                    e?.postToPid(getpid())
                }
                usleep(30_000)
            }
            return
        }
        var parts = step.split(separator: "+").map(String.init)
        let key = parts.removeLast()
        var flags: CGEventFlags = []
        for m in parts {
            switch m {
            case "cmd": flags.insert(.maskCommand)
            case "opt": flags.insert(.maskAlternate)
            case "ctrl": flags.insert(.maskControl)
            case "shift": flags.insert(.maskShift)
            default: break
            }
        }
        guard let code = named[key] else { return }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }
}

enum SelfTestAX {
    struct Report { var total = 0; var unnamed: [String] = []; var named: [String] = [] }
    static func attr(_ e: AXUIElement, _ k: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success else { return nil }
        if let s = v as? String { return s }
        return nil
    }
    static func audit() -> Report {
        var r = Report()
        let app = AXUIElementCreateApplication(getpid())
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < 40 else { return }
            let role = attr(e, kAXRoleAttribute) ?? ""
            if ["AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton"].contains(role) {
                // VoiceOver 没有标题时会读里面的文字
                func texts(_ x: AXUIElement, _ d: Int) -> [String] {
                    guard d < 6 else { return [] }
                    var out: [String] = []
                    if attr(x, kAXRoleAttribute) == "AXStaticText" { var v: CFTypeRef?; if AXUIElementCopyAttributeValue(x, kAXValueAttribute as CFString, &v) == .success, let t = v as? String { out.append(t) } }
                    var kids: CFTypeRef?
                    if AXUIElementCopyAttributeValue(x, kAXChildrenAttribute as CFString, &kids) == .success, let arr = kids as? [AXUIElement] { for k in arr { out += texts(k, d + 1) } }
                    return out
                }
                var titleEl: CFTypeRef?
                var linked: String?
                if AXUIElementCopyAttributeValue(e, kAXTitleUIElementAttribute as CFString, &titleEl) == .success, let t = titleEl {
                    linked = texts(t as! AXUIElement, 0).joined(separator: " ")
                }
                let name = ([attr(e, kAXTitleAttribute), attr(e, kAXDescriptionAttribute), linked].compactMap { $0 } + [texts(e, 0).joined(separator: " ")]).filter { !$0.isEmpty }.first
                let help = attr(e, kAXHelpAttribute) ?? ""
                let sub = attr(e, kAXSubroleAttribute) ?? ""
                // 窗口的红黄绿按钮系统自己会读
                if !sub.contains("CloseButton") && !sub.contains("MinimizeButton") && !sub.contains("ZoomButton") && !sub.contains("FullScreenButton")
                    && !sub.contains("Increment") && !sub.contains("Decrement") {   // 滚动条的箭头, 系统自己处理
                    r.total += 1
                    if let name, !name.contains(".") || name.contains(" ") { r.named.append("\(role) \(name)") }
                    else {
                        var pos: CFTypeRef?; var pt = CGPoint.zero
                        if AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pos) == .success { AXValueGetValue(pos as! AXValue, .cgPoint, &pt) }
                        var kids: CFTypeRef?; var kr: [String] = []
                        if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids) == .success, let arr = kids as? [AXUIElement] { kr = arr.map { attr($0, kAXRoleAttribute) ?? "?" } }
                        r.unnamed.append("\(role) sub=\(sub) id=\(attr(e, kAXIdentifierAttribute) ?? "-") at=\(Int(pt.x)),\(Int(pt.y)) kids=\(kr) help=\(help)")
                    }
                }
            }
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids) == .success, let arr = kids as? [AXUIElement] {
                for k in arr { walk(k, depth + 1) }
            }
        }
        walk(app, 0)
        return r
    }
}

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
        if let j = args.firstIndex(of: "--calib-batch"), j + 1 < args.count {
            runCalibrationBatch(URL(fileURLWithPath: args[j + 1]))
            exit(0)
        }
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        func val(_ flag: String) -> String? {
            guard let j = args.firstIndex(of: flag), j + 1 < args.count else { return nil }
            return args[j + 1]
        }
        let out = URL(fileURLWithPath: args[i + 1])
        if let r = val("--sim-ram").flatMap(Double.init) { Recommender.simulatedRAM = r }
        if args.contains("--sim-intel") { Recommender.simulateIntel = true }
        if args.contains("--demo-mac") { SystemInfo.demoMac = true; Recommender.simulatedRAM = 128 }
        let values = Set(["--snapshot", "--section", "--chat", "--ai", "--export", "--download", "--gh-import", "--sim-ram", "--settings", "--export-side", "--video", "--video-model", "--video-seconds", "--comfy-warmup", "--dump-prompt", "--bench", "--setup-install", "--setup-model", "--chat-model", "--image", "--image-model", "--local", "--show-mask", "--erase", "--brush", "--link", "--diagnostics", "--quick", "--hotkey-test", "--keys", "--palette-query", "--doc-test", "--doc-ask", "--queue-test", "--assist-test", "--use-chat-model", "--doc-model", "--broker-model"].compactMap(val))
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
            if let spec = val("--settings"), let item = store.current {
                // 例: "Exposure2012=0.4,Contrast2012=18" (和发给 Lightroom 的参数一样, 用来对比两边的效果)
                var st: Settings = [:]
                for p in spec.split(separator: ",") {
                    let x = p.split(separator: "=")
                    if x.count == 2, let v = Double(x[1]) { st[String(x[0])] = v }
                }
                for (k, v) in st { item.setValue(k, v) }
                try? await Task.sleep(for: .seconds(2))
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
                    let side = val("--export-side").flatMap(Double.init).map { CGFloat($0) }
                    let e1 = await Task.detached { Exporter.exportJPEG(job, to: dir, maxSide: side) }.value
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
            // 自测时临时换对话模型 (测完换回来, 不改用户设置)
            let savedChatModel = ModelManager.shared.chatModel
            if let m = val("--use-chat-model") { ModelManager.shared.chatModel = m }
            defer { if val("--use-chat-model") != nil { ModelManager.shared.chatModel = savedChatModel } }
            if let l = val("--link").flatMap(URL.init(string:)) {
                let before = Set(chat.conversations.map(\.id))
                self.handleLink(l)
                try? await Task.sleep(for: .seconds(1))
                log += "link: \(l.absoluteString) -> section=\(app.section) computerPanel=\(ComputerControl.shared.showPanel) conversations=\(chat.conversations.count) quickVisible=\(QuickAsk.shared.isVisible) queue=\(GenQueue.shared.jobs.count)\n"
                // 网址提问: 等回答完, 记下回答, 删掉测试对话
                let added = chat.conversations.filter { !before.contains($0.id) }
                for c in added {
                    while chat.running.contains(c.id) { try? await Task.sleep(for: .seconds(0.5)) }
                    let a = chat.conversations.first { $0.id == c.id }?.messages.last { $0.role == "assistant" }
                    log += "link-answer: \((a?.text ?? a?.error ?? "-").replacingOccurrences(of: "\n", with: " "))\n"
                    chat.delete(c.id)
                }
                GenQueue.shared.cancelAllWaiting()
                QuickAsk.shared.close()
            }
            if let text = val("--assist-test") {
                // 选中文字处理: 直接给文字, 依次翻译和润色
                let t = TextAssist.shared
                t.source = text
                for a in [TextAssist.Action.translate, .polish] {
                    let t0 = Date()
                    t.run(a)
                    try? await Task.sleep(for: .seconds(0.5))
                    while t.running { try? await Task.sleep(for: .seconds(0.3)) }
                    log += "assist \(a.rawValue): \(String(format: "%.1f", Date().timeIntervalSince(t0)))s \(t.error ?? "") \(t.result.replacingOccurrences(of: "\n", with: " "))\n"
                }
            }
            if args.contains("--spotlight-test") {
                // 聚焦搜索: 造一个带特殊词的对话 -> 能搜到 -> 删掉 -> 搜不到
                let word = "Zebrafinch\(Int.random(in: 1000...9999))"
                let id = chat.newConversation()
                chat.update(id) { c in c.title = "聚焦自测"; c.messages = [ChatMessage(role: "user", text: "测试 \(word)"), ChatMessage(role: "assistant", text: "好的")] }
                chat.save()
                func count() async -> Int {
                    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
                    p.arguments = ["-onlyin", SpotlightIndex.folder.path, word]
                    let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); p.waitUntilExit()
                    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").count
                }
                try? await Task.sleep(for: .seconds(6))
                log += "spotlight: indexed found=\(await count())\n"
                chat.delete(id)
                try? await Task.sleep(for: .seconds(6))
                log += "spotlight: after delete found=\(await count())\n"
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
            if let dp = val("--dump-prompt") {
                // 导出实际发给模型的系统提示和工具定义 (操作电脑关 / 开两种), 用来统计 token 和对比工具调用
                let cc = ComputerControl.shared
                let was = cc.enabled
                var out: [String: Any] = [:]
                for on in [false, true] {
                    cc.enabled = on
                    out[on ? "cu" : "base"] = ["system": Agent.systemPrompt(workDir: NSHomeDirectory(), tools: true),
                                               "tools": Tools.definitions(photo: true)]
                }
                cc.enabled = was
                if let d = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .prettyPrinted]) {
                    try? d.write(to: URL(fileURLWithPath: dp))
                }
                log += "dump-prompt: \(dp)\n"
            }
            if let page = val("--comfy-warmup") {
                if page == "image", let mid = val("--image-model") { ImageModels.shared.scan(); ImageModels.shared.selectedId = mid }
                let t0 = Date()
                ComfyWarmup.enter(page)
                try? await Task.sleep(for: .seconds(1))
                while ComfyWarmup.isWarming { try? await Task.sleep(for: .seconds(1)) }
                log += "comfy-warmup \(page): \(ComfyWarmup.lastResult) (\(Int(Date().timeIntervalSince(t0)))s) patched=\(ComfyEngine.shared.patched)\n"
                if args.contains("--comfy-toggle-test") {
                    // 设置里关掉预热: 已预加载的模型要立刻卸载; 关着时进页面不预热; 再打开又会预热
                    ComfyWarmup.setEnabled(false)
                    try? await Task.sleep(for: .seconds(4))
                    log += "comfy-toggle off: \(ComfyWarmup.lastResult) loaded=\(ImageStore.shared.isLoaded(ImageModels.shared.selectedId))\n"
                    ComfyWarmup.leave(page); ComfyWarmup.enter(page)
                    try? await Task.sleep(for: .seconds(1))
                    log += "comfy-toggle enter while off: warming=\(ComfyWarmup.isWarming)\n"
                    ComfyWarmup.setEnabled(true)
                    try? await Task.sleep(for: .seconds(1))
                    while ComfyWarmup.isWarming { try? await Task.sleep(for: .seconds(1)) }
                    log += "comfy-toggle on: \(ComfyWarmup.lastResult) loaded=\(ImageStore.shared.isLoaded(ImageModels.shared.selectedId))\n"
                }
                if args.contains("--comfy-release-test") {
                    // 离开页面后自动释放: 把等待时间缩短到几秒来测
                    ComfyWarmup.unloadAfter = .seconds(3); ComfyWarmup.stopAfter = .seconds(3)
                    ComfyWarmup.leave("image"); ComfyWarmup.leave("video")
                    try? await Task.sleep(for: .seconds(15))
                    log += "comfy-release: \(ComfyWarmup.lastResult) online=\(ComfyEngine.shared.online)\n"
                }
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
                let secs = val("--video-seconds").flatMap(Double.init) ?? 2
                let t0 = Date()
                var previewAt: Double?
                let watch = Task { @MainActor in
                    while !Task.isCancelled { if previewAt == nil, vs.previewPath != nil { previewAt = Date().timeIntervalSince(t0) }; try? await Task.sleep(for: .milliseconds(500)) }
                }
                let item = await vs.generate(prompt: vp, seconds: secs, quality: .p480, aspect: .wide)
                watch.cancel()
                log += "video: \(item.map { "\($0.path) \($0.width)x\($0.height) \(Int($0.elapsed))s" } ?? "failed: \(vs.error ?? "-")") preview=\(previewAt.map { "\(Int($0))s" } ?? "-") est=\(String(format: "%.1f", vs.estimateMinutes))min patched=\(ComfyEngine.shared.patched)\n"
                vs.autoFree = true
            }
            if let dd = val("--diagnostics") {
                do {
                    let zip = try await Diagnostics.export(to: URL(fileURLWithPath: dd))
                    log += "diagnostics: \(zip.path)\n"
                } catch { log += "diagnostics error: \(error.localizedDescription)\n" }
            }
            if let pq = val("--palette-query") { CommandPalette.seed = pq }
            if args.contains("--markdown-demo") {
                // 显示一条包含各种 Markdown 的回答, 截图后删掉
                app.section = .chat
                let id = chat.newConversation()
                let md = """
                # 一级标题
                ## 二级标题：对比 **MLX** 和 *GGUF*
                普通段落，带 `行内代码`、[链接](https://example.com) 和公式 $E=mc^2$、\\(\\alpha + \\beta \\leq \\frac{1}{2}\\)。价格 $5 和 $10 不是公式。

                | 格式 | 速度 | 内存 | 说明 |
                |:---|:---:|---:|---|
                | MLX | 快 | 16 GB | Apple 芯片原生 |
                | GGUF | 中 | 18 GB | 通用，`llama.cpp` |

                - 第一项
                - 第二项，**加粗**
                  - 子项目
                1. 有序一
                2. 有序二
                - [x] 已完成的任务
                - [ ] 未完成的任务

                > 引用：本地模型不联网，数据留在自己的 Mac 上。

                ---

                ```swift
                // 计算平方
                func square(_ x: Int) -> Int {
                    let s = "结果"
                    return x * x  // 42
                }
                ```

                ```json
                {"model": "qwen3.8-27b", "ctx": 262144, "mtp": true}
                ```

                $$
                \\sum_{i=1}^{n} x_i^2 = \\sqrt{\\frac{a}{b}} \\times \\pi
                $$
                """
                chat.update(id) { c in
                    c.title = "Markdown 自测"
                    c.messages = [ChatMessage(role: "user", text: "展示一下 Markdown"), ChatMessage(role: "assistant", text: md)]
                }
                try? await Task.sleep(for: .seconds(2))
                if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true }), let v = w.contentView,
                   let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: out.deletingPathExtension().appendingPathExtension("markdown.png"))
                }
                log += "markdown blocks: \(MarkdownParser.parse(md).map { "\($0)".prefix(20) })\n"
                chat.delete(id)
            }
            if let spec = val("--queue-test") {
                // 自测: 竖线分隔的几个提示词一起加入绘图队列, 第一个开始后打开任务中心截图, 全部做完后记下结果并删掉测试图片
                app.section = .image
                let q = GenQueue.shared
                if let m = val("--image-model") { ImageModels.shared.scan(); ImageModels.shared.selectedId = m }
                let t0 = Date()
                q.addImages(spec.split(separator: "|").map(String.init))
                log += "queue: added=\(q.jobs.count) waiting=\(q.waiting.count) busy=\(q.busy)\n"
                while q.running == nil || ImageStore.shared.steps == 0 { try? await Task.sleep(for: .seconds(1)); if Date().timeIntervalSince(t0) > 300 { break } }
                app.showTasks = true
                try? await Task.sleep(for: .seconds(2))
                for (n, w) in NSApp.windows.filter({ $0.isVisible && $0.className.contains("Popover") }).enumerated() {
                    if let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: out.deletingPathExtension().appendingPathExtension("tasks\(n).png"))
                    }
                }
                app.showTasks = false
                while q.busy || !q.waiting.isEmpty { try? await Task.sleep(for: .seconds(1)) }
                for j in q.jobs {
                    log += "queue-job: \(j.prompt) state=\(j.state) started=+\(Int(j.started?.timeIntervalSince(t0) ?? -1))s finished=+\(Int(j.finished?.timeIntervalSince(t0) ?? -1))s results=\(j.results.count)\n"
                    for r in j.results { if let it = ImageStore.shared.items.first(where: { $0.id == r }) { ImageStore.shared.delete(it) } }
                }
            }
            if args.contains("--broker-test") {
                // 内存调度: 先加载一个对话模型 -> 小需求不卸 -> 正在用时大需求也不卸 -> 不在用时大需求按最久没用让位
                let b = MemoryBroker.shared
                let model = val("--broker-model") ?? "qwen/qwen3.8-27b"
                @MainActor func state(_ tag: String) async {
                    await b.refresh(); SystemInfo.shared.updateMemory()
                    log += "broker \(tag): avail=\(Int(b.availableGB))GB residents=\(b.residents.map { "\($0.name)=\(Int($0.gb))GB busy=\($0.busy)" })\n"
                }
                await ModelManager.shared.ensureLoaded(model)
                await state("loaded")
                let small = await b.makeRoom(20, for: .comfy)
                await state("after small(20GB) ok=\(small)")
                b.begin(.lmstudio(model))
                let bigBusy = await b.makeRoom(200, for: .comfy)
                await state("after big while busy ok=\(bigBusy)")
                b.end(.lmstudio(model))
                let big = await b.makeRoom(200, for: .comfy)
                await state("after big idle ok=\(big) event=\(b.lastEvent ?? "-")")
                // 面板截图 (重新加载模型让面板里有内容)
                await ModelManager.shared.ensureLoaded(model)
                let host = NSHostingView(rootView: MemoryUsageView())
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
                w.contentView = host
                w.orderFront(nil)
                try? await Task.sleep(for: .seconds(3))
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: out.deletingPathExtension().appendingPathExtension("memory.png"))
                }
                w.orderOut(nil)
                await b.evict(.lmstudio(model))
            }
            if let spec = val("--doc-test") {
                // 自测: 读文档 (竖线分隔的路径), 可选 --doc-ask 把它们发给 AI 提问, 记录回答后删掉测试对话
                var docs: [DocAttachment] = []
                for p in spec.split(separator: "|").map(String.init) {
                    let t0 = Date()
                    do {
                        let d = try await Task.detached { try DocReader.load(URL(fileURLWithPath: p)) }.value
                        docs.append(d)
                        log += "doc: \(d.name) chars=\(d.chars) pages=\(d.pages.map(String.init) ?? "-") tokens=\(d.tokens) long=\(d.isLong) note=\(d.note ?? "-") \(String(format: "%.1f", Date().timeIntervalSince(t0)))s head=\(d.text.prefix(60).replacingOccurrences(of: "\n", with: " "))\n"
                    } catch { log += "doc: \((p as NSString).lastPathComponent) error=\(error.localizedDescription)\n" }
                }
                if args.contains("--doc-show"), !docs.isEmpty {
                    // 截图: 带文档的消息怎么显示
                    app.section = .chat
                    let id = chat.newConversation()
                    chat.update(id) { c in
                        c.title = "文档自测"
                        var u = ChatMessage(role: "user", text: "这几份文件分别讲了什么？"); u.docs = docs
                        c.messages = [u, ChatMessage(role: "assistant", text: "第一份是会议纪要，第二份是销售表，第三份是发布计划。")]
                    }
                    try? await Task.sleep(for: .seconds(2))
                    if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true }), let v = w.contentView,
                       let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: out.deletingPathExtension().appendingPathExtension("docs.png"))
                    }
                    chat.delete(id)
                }
                if let q = val("--doc-ask"), !docs.isEmpty {
                    app.section = .chat
                    let id = chat.newConversation()
                    if let m = val("--doc-model") { chat.update(id) { $0.model = m } }
                    let t0 = Date()
                    chat.send(q, docs: docs, to: id)
                    try? await Task.sleep(for: .seconds(1))
                    while chat.running.contains(id) {
                        // 要执行命令等需要确认的操作: 记下来并拒绝 (自测不替用户批准)
                        if let a = chat.approval, a.conversationId == id {
                            log += "doc-approval: \(a.call.name) \(a.summary)\n"
                            chat.approval = nil
                            a.continuation.resume(returning: false)
                        }
                        try? await Task.sleep(for: .seconds(0.5))
                    }
                    if let c = chat.conversations.first(where: { $0.id == id }) {
                        for m in c.messages where m.role != "user" {
                            if m.role == "assistant" { log += "doc-answer: \(m.text.replacingOccurrences(of: "\n", with: " ⏎ "))\n" }
                            for t in m.toolCalls { log += "doc-tool: \(t.name) \(t.arguments)\n" }
                        }
                        log += "doc-digest: \((c.messages.first?.docs ?? []).map { ($0.digest ?? "-").prefix(300).replacingOccurrences(of: "\n", with: " ") })\n"
                        log += "doc-time: \(Int(Date().timeIntervalSince(t0)))s stats=\(String(describing: c.lastStats))\n"
                    }
                    chat.delete(id)
                }
            }
            if args.contains("--settings-shots") {
                // 打开设置窗口, 每个标签截一张
                NSApp.activate(ignoringOtherApps: true)
                try? await Task.sleep(for: .seconds(0.5))
                SelfTestKeys.post("cmd+,")      // 和用户一样按 ⌘,
                try? await Task.sleep(for: .seconds(1.5))
                for t in SettingsTab.allCases {
                    UserDefaults.standard.set(t.rawValue, forKey: "settingsTab")
                    try? await Task.sleep(for: .seconds(1.2))
                    if let w = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true }), let v = w.contentView?.superview ?? w.contentView,
                       let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: out.deletingPathExtension().appendingPathExtension("settings-\(t.rawValue).png"))
                    }
                }
                log += "settings windows: " + NSApp.windows.filter(\.isVisible).map { "\($0.identifier?.rawValue ?? "nil")[\($0.title)]" }.joined(separator: ", ") + "\n"
                UserDefaults.standard.set(0, forKey: "settingsTab")
                NSApp.windows.first { $0.identifier?.rawValue.contains("Settings") == true }?.close()
            }
            if args.contains("--ax-dump") {
                // 和 VoiceOver 读到的一样: 遍历自己的辅助功能树, 找没有名字的按钮
                try? await Task.sleep(for: .seconds(1))
                let report = SelfTestAX.audit()
                log += "ax: buttons=\(report.total) unnamed=\(report.unnamed.count)\n" + report.unnamed.map { "  ax unnamed: \($0)\n" }.joined()
                log += report.named.prefix(200).map { "  ax: \($0)\n" }.joined()
            }
            if let spec = val("--keys") {
                // 模拟键盘操作 (需要辅助功能权限), 例: "cmd+k|text:模型|down|return"
                NSApp.activate(ignoringOtherApps: true)
                try? await Task.sleep(for: .seconds(0.5))
                for step in spec.split(separator: "|").map(String.init) {
                    SelfTestKeys.post(step)
                    try? await Task.sleep(for: .seconds(0.6))
                }
                try? await Task.sleep(for: .seconds(1))
                log += "keys: section=\(app.section) palette=\(app.showPalette) chatModel=\(ModelManager.shared.chatModel) selected=\(chat.current?.title ?? "-")\n"
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
            if let spec = val("--eval-task") {
                log += await EvalTask.run(spec: URL(fileURLWithPath: spec), chat: chat, app: app)
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
            app.showPalette = false
            QuickAsk.shared.close()
            for w in NSApp.windows { w.attachedSheet.map { w.endSheet($0) } }
            try? await Task.sleep(for: .seconds(0.5))
            if args.contains("--keep-test-chat") == false, val("--chat") != nil, let id = chat.selected { chat.delete(id) }
            NSApp.terminate(nil)
            // 万一有什么挡住了正常退出, 5 秒后强制退出 (自测不能留在后台)
            try? await Task.sleep(for: .seconds(5))
            chat.save(); chat.storage.flush()
            exit(0)
        }
    }
}
#endif

#if TOOLULA_SELFTEST
/// 校准用: 一次解码 RAW, 按清单渲染很多张 (长边 1560, sRGB JPEG), 和 Lightroom 渲染的参考图对比.
/// 清单 JSON: {"raw": 路径, "renders": [{"out": 路径, "settings": {...}, "gains": {"Contrast2012+": 0.8},
///             "look": {"boost": 1, "saturation": 1, "exposure": 0}}]}
extension AppDelegate {
    func runCalibrationBatch(_ spec: URL) {
        guard let d = try? Data(contentsOf: spec), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let raw = j["raw"] as? String, let renders = j["renders"] as? [[String: Any]] else { print("bad spec"); return }
        let r = Renderer.shared
        var bases: [String: CIImage] = [:]
        for item in renders {
            let lk = item["look"] as? [String: Double] ?? [:]
            let look = Renderer.RawLook(boost: lk["boost"] ?? 1, saturation: lk["saturation"] ?? 1, exposure: lk["exposure"] ?? 0)
            let key = "\(look.boost)/\(look.saturation)/\(look.exposure)"
            if bases[key] == nil {
                Renderer.RawLook.override = look
                bases[key] = r.loadPreviewBase(URL(fileURLWithPath: raw), maxSide: 1560)
            }
            guard let base = bases[key], let out = item["out"] as? String else { continue }
            SliderCalibration.overrides = item["gains"] as? [String: Double] ?? [:]
            let settings = item["settings"] as? [String: Double] ?? [:]
            let img = r.renderEdited(base, settings: settings, patches: [], locals: [])
            try? r.writeJPEG(img, to: URL(fileURLWithPath: out))
        }
        Renderer.RawLook.override = nil
        SliderCalibration.overrides = [:]
        print("rendered \(renders.count)")
    }
}
#endif
