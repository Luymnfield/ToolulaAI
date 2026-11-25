import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import ScreenCaptureKit
import SwiftUI

// MARK: - 让 AI 操作 Mac 上的程序
//
// 三层能力 (从稳到灵活):
//   1. 快捷指令 / AppleScript: 程序自己提供的自动化接口, 最稳
//   2. 辅助功能 (Accessibility): 读出任意程序窗口里的按钮、输入框、菜单, 按编号点击和输入
//   3. 截屏 + 坐标点击: 读不出元素的界面 (游戏、自绘界面) 的兜底办法
// 安全: 默认关闭; 每次点击/输入先问用户 (除非本对话设为都允许); 不碰密码类程序和密码框; 按 Esc 立即停止

@MainActor
final class ComputerControl: ObservableObject {
    static let shared = ComputerControl()

    @Published var enabled = UserDefaults.standard.bool(forKey: "computerControl") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "computerControl")
            if enabled { refreshPermissions(); if !axTrusted { requestAccessibility() } }
        }
    }
    @Published var axTrusted = AXIsProcessTrusted()
    @Published var screenAllowed = CGPreflightScreenCaptureAccess()
    @Published var activeApp: String?          // 正在操作的程序 (显示提示条)
    @Published var lastAction = ""
    @Published var showPanel = false          // 打开助手页的「操作电脑」设置 (小组件按钮)

    /// 当前对话的停止方法 (按 Esc 时调用)
    var stopHandler: (() -> Void)?
    private var escMonitors: [Any] = []
    private var hideTask: Task<Void, Never>?
    private var overlay: NSPanel?

    /// 最近一次读取的界面元素 (编号 -> 元素)
    private(set) var elements: [Int: AXUIElement] = [:]
    private(set) var elementsApp: pid_t = 0
    /// 最近一次截图: 截图坐标 (0~1000) -> 屏幕坐标
    private var shotFrame: CGRect?

    /// 不允许操作的程序 (密码管理、钥匙串)
    static let blocked: [String] = ["com.apple.keychainaccess", "com.apple.Passwords", "com.1password", "com.agilebits",
                                    "com.bitwarden", "com.lastpass", "com.dashlane", "com.apple.systempreferences", "com.apple.Settings"]

    func refreshPermissions() {
        axTrusted = AXIsProcessTrusted()
        screenAllowed = CGPreflightScreenCaptureAccess()
    }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        axTrusted = AXIsProcessTrustedWithOptions(opts)
    }

    func requestScreen() {
        screenAllowed = CGRequestScreenCaptureAccess()
    }

    static func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    // MARK: 提示条 + Esc 停止

    func begin(_ app: String, _ action: String) {
        activeApp = app
        lastAction = action
        showOverlay()
        if escMonitors.isEmpty {
            let handler: (NSEvent) -> Void = { [weak self] e in
                if e.keyCode == UInt16(kVK_Escape) { Task { @MainActor in self?.stopNow() } }
            }
            if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) { escMonitors.append(g) }
            if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in handler(e); return e }) { escMonitors.append(l) }
        }
        hideTask?.cancel()
        hideTask = Task { try? await Task.sleep(for: .seconds(8)); if !Task.isCancelled { self.end() } }
    }

    func end() {
        activeApp = nil
        overlay?.orderOut(nil)
        for m in escMonitors { NSEvent.removeMonitor(m) }
        escMonitors = []
    }

    func stopNow() {
        stopHandler?()
        lastAction = String(localized: "已停止")
        end()
    }

    private func showOverlay() {
        if overlay == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 40), styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: ControlBanner())
            overlay = p
        }
        if let screen = NSScreen.main, let p = overlay {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - 210, y: f.maxY - 52))
            p.orderFrontRegardless()
        }
    }

    // MARK: 找程序

    func findApp(_ name: String?) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        guard let n = name?.trimmingCharacters(in: .whitespaces).lowercased(), !n.isEmpty else {
            return NSWorkspace.shared.frontmostApplication
        }
        return apps.first { ($0.localizedName ?? "").lowercased() == n || ($0.bundleIdentifier ?? "").lowercased() == n }
            ?? apps.first { ($0.localizedName ?? "").lowercased().contains(n) || ($0.bundleIdentifier ?? "").lowercased().contains(n) }
    }

    func isBlocked(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return Self.blocked.contains { id.hasPrefix($0) }
    }

    // MARK: 第 2 层: 读界面元素

    private static let interactive: Set<String> = ["AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
                                                   "AXMenuButton", "AXComboBox", "AXLink", "AXSlider", "AXMenuItem", "AXRow", "AXCell",
                                                   "AXDisclosureTriangle", "AXIncrementor", "AXSearchField", "AXTab", "AXImage", "AXStaticText"]

    static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
    static func str(_ el: AXUIElement, _ name: String) -> String? {
        guard let v = attr(el, name) else { return nil }
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    /// 读出程序当前窗口里的元素, 返回给 AI 看的文字
    func readApp(_ name: String?) -> String {
        guard axTrusted else { return Self.needAX }
        guard let app = findApp(name) else { return String(localized: "没有找到正在运行的程序「\(name ?? "")」。可以先用 open_app 打开它。") }
        if isBlocked(app) { return String(localized: "为了安全，Toolula 不操作「\(app.localizedName ?? "")」（密码 / 系统设置类程序）。") }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var lines: [String] = []
        var map: [Int: AXUIElement] = [:]
        var next = 1
        var count = 0

        func walk(_ el: AXUIElement, depth: Int) {
            guard depth < 30, count < 400 else { return }
            let role = Self.str(el, kAXRoleAttribute) ?? ""
            let sub = Self.str(el, kAXSubroleAttribute) ?? ""
            if Self.interactive.contains(role) {
                let title = Self.str(el, kAXTitleAttribute) ?? Self.str(el, kAXDescriptionAttribute) ?? Self.str(el, kAXHelpAttribute) ?? ""
                var value = sub == "AXSecureTextField" ? String(localized: "（密码框）") : (Self.str(el, kAXValueAttribute) ?? "")
                if value.count > 120 { value = String(value.prefix(120)) + "…" }
                let placeholder = Self.str(el, kAXPlaceholderValueAttribute) ?? ""
                if role == "AXStaticText" {
                    if !value.isEmpty || !title.isEmpty { lines.append(String(repeating: " ", count: min(depth, 8)) + "· " + (value.isEmpty ? title : value)) }
                } else if !(role == "AXImage" && title.isEmpty) && !(role == "AXRow" || role == "AXCell") || !title.isEmpty || !value.isEmpty {
                    let enabled = (Self.attr(el, kAXEnabledAttribute) as? Bool) ?? true
                    var t = "[\(next)] \(role.replacingOccurrences(of: "AX", with: ""))"
                    if !title.isEmpty { t += " \"\(title)\"" }
                    if !value.isEmpty { t += " 值=\"\(value)\"" }
                    if !placeholder.isEmpty && value.isEmpty { t += " 提示=\"\(placeholder)\"" }
                    if !enabled { t += " (不可用)" }
                    lines.append(String(repeating: " ", count: min(depth, 8)) + t)
                    map[next] = el
                    next += 1
                }
                count += 1
            }
            if let kids = Self.attr(el, kAXChildrenAttribute) as? [AXUIElement] {
                for k in kids { walk(k, depth: depth + 1) }
            }
        }

        let windows = (Self.attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        let focused = Self.attr(root, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
        let main = focused ?? windows.first
        if let w = main {
            lines.append(String(localized: "窗口：\(Self.str(w, kAXTitleAttribute) ?? "")"))
            walk(w, depth: 0)
        } else {
            lines.append(String(localized: "（这个程序没有打开的窗口）"))
        }
        // 菜单栏只列出顶层名字, 用 app_menu 操作
        if let bar = Self.attr(root, kAXMenuBarAttribute), let items = Self.attr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] {
            let names = items.compactMap { Self.str($0, kAXTitleAttribute) }.filter { !$0.isEmpty && $0 != "Apple" }
            lines.append(String(localized: "菜单栏：\(names.joined(separator: " | "))（用 app_menu 点菜单）"))
        }
        elements = map
        elementsApp = app.processIdentifier
        var text = String(localized: "程序：\(app.localizedName ?? "")") + "\n" + lines.joined(separator: "\n")
        if text.count > 14000 { text = String(text.prefix(14000)) + "\n" + String(localized: "…（太长，已截断）") }
        return text
    }

    static let needAX = String(localized: "还没有「辅助功能」权限。请用户在 Toolula 助手页右上角打开「操作电脑」，按提示在系统设置里允许 Toolula AI。")

    private func element(_ id: Int) -> AXUIElement? { elements[id] }

    private func app(for el: AXUIElement) -> NSRunningApplication? {
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        return NSRunningApplication(processIdentifier: pid)
    }

    func describe(_ id: Int) -> String {
        guard let el = element(id) else { return "#\(id)" }
        let role = (Self.str(el, kAXRoleAttribute) ?? "").replacingOccurrences(of: "AX", with: "")
        let title = Self.str(el, kAXTitleAttribute) ?? Self.str(el, kAXDescriptionAttribute) ?? Self.str(el, kAXValueAttribute) ?? ""
        return "[\(id)] \(role) \"\(title.prefix(40))\""
    }

    func appName(of id: Int) -> String {
        element(id).flatMap { app(for: $0) }?.localizedName ?? ""
    }

    func click(_ id: Int) -> String {
        guard axTrusted else { return Self.needAX }
        guard let el = element(id) else { return String(localized: "没有编号 \(id) 的元素，请先用 app_read 重新读取界面。") }
        let a = app(for: el)
        if isBlocked(a) { return String(localized: "为了安全，不操作这个程序。") }
        a?.activate()
        if AXUIElementPerformAction(el, kAXPressAction as CFString) == .success {
            return String(localized: "已点击 \(describe(id))。界面可能已经变化，需要时用 app_read 重新读取。")
        }
        // 不支持「按下」的元素 (列表行等): 用鼠标点中心
        guard let f = Self.frame(el) else { return String(localized: "这个元素点不了") }
        Self.mouseClick(CGPoint(x: f.midX, y: f.midY))
        return String(localized: "已用鼠标点击 \(describe(id))。需要时用 app_read 重新读取。")
    }

    func type(_ id: Int?, _ text: String, replace: Bool, submit: Bool) async -> String {
        guard axTrusted else { return Self.needAX }
        var target: NSRunningApplication? = NSWorkspace.shared.frontmostApplication
        if let id {
            guard let el = element(id) else { return String(localized: "没有编号 \(id) 的元素，请先用 app_read 重新读取界面。") }
            if Self.str(el, kAXSubroleAttribute) == "AXSecureTextField" {
                return String(localized: "这是密码框。为了安全 Toolula 不输入密码，请用户自己输入。")
            }
            target = app(for: el)
            if isBlocked(target) { return String(localized: "为了安全，不操作这个程序。") }
            target?.activate()
            try? await Task.sleep(for: .milliseconds(150))
            AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if Self.str(el, kAXRoleAttribute) != "AXTextField" && Self.str(el, kAXRoleAttribute) != "AXTextArea", let f = Self.frame(el) {
                Self.mouseClick(CGPoint(x: f.midX, y: f.midY))
            }
        }
        if isBlocked(target) { return String(localized: "为了安全，不操作这个程序。") }
        try? await Task.sleep(for: .milliseconds(150))
        if replace { Self.key("cmd+a") }
        Self.typeText(text)
        if submit { try? await Task.sleep(for: .milliseconds(100)); Self.key("return") }
        return String(localized: "已输入 \(text.count) 个字\(submit ? String(localized: "并按了回车") : "")。")
    }

    func menu(_ appName: String?, _ path: String) async -> String {
        guard axTrusted else { return Self.needAX }
        guard let app = findApp(appName) else { return String(localized: "没有找到程序「\(appName ?? "")」") }
        if isBlocked(app) { return String(localized: "为了安全，不操作这个程序。") }
        let parts = path.split(whereSeparator: { ">›/".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty, let bar = Self.attr(AXUIElementCreateApplication(app.processIdentifier), kAXMenuBarAttribute) else {
            return String(localized: "读不到这个程序的菜单")
        }
        app.activate()
        try? await Task.sleep(for: .milliseconds(200))
        var current = bar as! AXUIElement
        for (i, name) in parts.enumerated() {
            var kids = (Self.attr(current, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            // 菜单栏项 / 子菜单项下面先有一层 AXMenu
            if kids.count == 1, Self.str(kids[0], kAXRoleAttribute) == "AXMenu" {
                kids = (Self.attr(kids[0], kAXChildrenAttribute) as? [AXUIElement]) ?? []
            }
            let lower = name.lowercased()
            guard let hit = kids.first(where: { (Self.str($0, kAXTitleAttribute) ?? "").lowercased() == lower })
                ?? kids.first(where: { (Self.str($0, kAXTitleAttribute) ?? "").lowercased().hasPrefix(lower) }) else {
                let names = kids.compactMap { Self.str($0, kAXTitleAttribute) }.filter { !$0.isEmpty }
                return String(localized: "菜单里没有「\(name)」。这一层有：\(names.prefix(40).joined(separator: " | "))")
            }
            if i == parts.count - 1 {
                if (Self.attr(hit, kAXEnabledAttribute) as? Bool) == false { return String(localized: "菜单「\(path)」现在不可用") }
                AXUIElementPerformAction(hit, kAXPressAction as CFString)
                return String(localized: "已点击菜单「\(path)」")
            }
            current = hit
        }
        return String(localized: "菜单路径不完整")
    }

    // MARK: 第 3 层: 截屏 + 坐标点击

    /// 截取某个程序的窗口 (或整个主屏幕), 返回 JPEG 路径
    func screenshot(_ name: String?) async -> (String?, String) {
        refreshPermissions()
        guard screenAllowed else {
            return (nil, String(localized: "还没有「屏幕录制」权限。请用户在 Toolula 助手页的「操作电脑」里按提示允许。"))
        }
        do {
            var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if content.displays.isEmpty {   // 刚启动时第一次查询偶尔是空的，稍等再试
                try? await Task.sleep(for: .milliseconds(400))
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            }
            let filter: SCContentFilter
            var frame: CGRect
            if let n = name, !n.isEmpty, let app = findApp(n) {
                if isBlocked(app) { return (nil, String(localized: "为了安全，不截取这个程序的画面。")) }
                guard let w = content.windows.filter({ $0.owningApplication?.processID == app.processIdentifier && $0.isOnScreen && $0.frame.width > 80 })
                    .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                    return (nil, String(localized: "「\(app.localizedName ?? n)」没有显示在屏幕上的窗口"))
                }
                filter = SCContentFilter(desktopIndependentWindow: w)
                frame = w.frame
            } else {
                guard let d = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                    return (nil, String(localized: "找不到屏幕"))
                }
                filter = SCContentFilter(display: d, excludingWindows: [])
                frame = d.frame
            }
            let cfg = SCStreamConfiguration()
            let scale = min(1, 1440 / max(frame.width, frame.height))
            cfg.width = Int(frame.width * scale * 2) / 2
            cfg.height = Int(frame.height * scale * 2) / 2
            cfg.showsCursor = false
            let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            shotFrame = frame
            let sw = String(cg.width), sh = String(cg.height)
            let url = AppPaths.attachments.appendingPathComponent("screen_\(UUID().uuidString.prefix(8)).jpg")
            let ci = CIImage(cgImage: cg)
            try Renderer.shared.writeJPEG(ci, to: url, quality: 0.8)
            return (url.path, String(localized: "已截图（\(sw)×\(sh)）。要点击画面里的某个位置，用 mouse_click，坐标按截图宽高换算成 0~1000（左上角是 0,0）。"))
        } catch {
            return (nil, String(localized: "截图失败：\(error.localizedDescription)"))
        }
    }

    /// x, y: 0~1000 (相对最近一次截图)
    func clickAt(x: Double, y: Double, double: Bool, right: Bool) -> String {
        guard axTrusted else { return Self.needAX }
        guard let f = shotFrame else { return String(localized: "请先用 screenshot 截图，再按截图里的位置点击。") }
        let p = CGPoint(x: f.minX + f.width * min(1000, max(0, x)) / 1000, y: f.minY + f.height * min(1000, max(0, y)) / 1000)
        // 点击位置属于被禁止的程序时拒绝
        if let el = Self.elementAt(p), isBlocked(app(for: el)) { return String(localized: "为了安全，不操作这个程序。") }
        Self.mouseClick(p, double: double, right: right)
        return String(localized: "已在屏幕 (\(Int(p.x)), \(Int(p.y))) 点击。需要时再截图确认结果。")
    }

    static func elementAt(_ p: CGPoint) -> AXUIElement? {
        var el: AXUIElement?
        AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el)
        return el
    }

    // MARK: 鼠标 / 键盘

    static func mouseClick(_ p: CGPoint, double: Bool = false, right: Bool = false) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
        let btn: CGMouseButton = right ? .right : .left
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: btn)?.post(tap: .cghidEventTap)
        for n in 1...(double ? 2 : 1) {
            let d = CGEvent(mouseEventSource: src, mouseType: down, mouseCursorPosition: p, mouseButton: btn)
            let u = CGEvent(mouseEventSource: src, mouseType: up, mouseCursorPosition: p, mouseButton: btn)
            d?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            u?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            d?.post(tap: .cghidEventTap)
            u?.post(tap: .cghidEventTap)
        }
    }

    static func typeText(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 16, units.count)])
            let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            let u = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            d?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            u?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            d?.post(tap: .cghidEventTap)
            u?.post(tap: .cghidEventTap)
            i += 16
            usleep(8000)
        }
    }

    static let keyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G,
        "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
        "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
        "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6,
        "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9, "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, ",": kVK_ANSI_Comma,
        ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, ";": kVK_ANSI_Semicolon, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "space": kVK_Space, "delete": kVK_Delete, "backspace": kVK_Delete,
        "forwarddelete": kVK_ForwardDelete, "esc": kVK_Escape, "escape": kVK_Escape,
        "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
        "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
        "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
    ]

    /// 例: "cmd+s", "cmd+shift+n", "return", "esc". 返回是否认识这个组合
    @discardableResult
    static func key(_ combo: String) -> Bool {
        let parts = combo.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init)
        guard let last = parts.last, let code = keyCodes[last] else { return false }
        var flags: CGEventFlags = []
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "alt", "option", "opt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: return false
            }
        }
        let src = CGEventSource(stateID: .hidSystemState)
        let d = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: true)
        let u = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: false)
        d?.flags = flags; u?.flags = flags
        d?.post(tap: .cghidEventTap); u?.post(tap: .cghidEventTap)
        return true
    }
}

// MARK: - 第 1 层: 快捷指令 / AppleScript / 打开程序

enum MacAutomation {
    static func listShortcuts() -> String {
        let (code, out) = Exporter.shell("/usr/bin/shortcuts", ["list"])
        guard code == 0 else { return String(localized: "读取快捷指令失败：\(out)") }
        let names = out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return names.isEmpty ? String(localized: "这台 Mac 上还没有快捷指令。") : String(localized: "这台 Mac 上的快捷指令（\(names.count) 个）：") + "\n" + names.joined(separator: "\n")
    }

    static func runShortcut(_ name: String, input: String?) -> String {
        var args = ["run", name]
        var tmpIn: URL?
        if let input, !input.isEmpty {
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("toolula_sc_\(UUID().uuidString.prefix(6)).txt")
            try? input.write(to: u, atomically: true, encoding: .utf8)
            args += ["--input-path", u.path]
            tmpIn = u
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("toolula_sc_out_\(UUID().uuidString.prefix(6))")
        args += ["--output-path", out.path]
        let (code, text) = Exporter.shell("/usr/bin/shortcuts", args)
        defer { if let tmpIn { try? FileManager.default.removeItem(at: tmpIn) }; try? FileManager.default.removeItem(at: out) }
        guard code == 0 else { return String(localized: "快捷指令「\(name)」运行失败：\(text)") }
        let result = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        return String(localized: "快捷指令「\(name)」已运行。") + (result.isEmpty ? "" : "\n" + String(localized: "输出：") + String(result.prefix(8000)))
    }

    static func runAppleScript(_ script: String, javascript: Bool) -> String {
        var args = ["-e", script]
        if javascript { args = ["-l", "JavaScript"] + args }
        let (code, out) = Exporter.shell("/usr/bin/osascript", args)
        let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if code != 0 {
            if text.contains("-1743") || text.lowercased().contains("not authorized") {
                return String(localized: "macOS 没有允许 Toolula 控制这个程序。请用户在「系统设置 → 隐私与安全性 → 自动化」里允许 Toolula AI。原始错误：\(text)")
            }
            return String(localized: "脚本出错：\(text)")
        }
        return text.isEmpty ? String(localized: "脚本已执行（没有返回内容）。") : String(text.prefix(12000))
    }

    /// 按中文名 / 英文名 / Bundle ID 找到程序 (open -a 只认英文名, 例如「计算器」要找成 Calculator.app)
    static func appURL(_ name: String) -> URL? {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ".app", with: "")
        guard !n.isEmpty else { return nil }
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) { return u }
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities", "/System/Library/CoreServices",
                    NSHomeDirectory() + "/Applications"]
        var partial: URL?
        for d in dirs {
            for item in (try? fm.contentsOfDirectory(atPath: d)) ?? [] where item.hasSuffix(".app") {
                let path = d + "/" + item
                let file = String(item.dropLast(4)).lowercased()
                let shown = fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: "").lowercased()
                let info = Bundle(path: path)?.infoDictionary ?? [:]
                let names = [file, shown, (info["CFBundleDisplayName"] as? String ?? "").lowercased(), (info["CFBundleName"] as? String ?? "").lowercased()]
                    + localizedNames(path)
                if names.contains(n) { return URL(fileURLWithPath: path) }
                if partial == nil, names.contains(where: { !$0.isEmpty && ($0.contains(n) || n.contains($0)) }) { partial = URL(fileURLWithPath: path) }
            }
        }
        return partial
    }

    /// 程序在各种语言里的名字 (系统程序存在 InfoPlist.loctable, 老程序在 xx.lproj/InfoPlist.strings)
    static func localizedNames(_ appPath: String) -> [String] {
        let res = appPath + "/Contents/Resources/"
        var out: [String] = []
        if let d = FileManager.default.contents(atPath: res + "InfoPlist.loctable"),
           let table = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] {
            for (_, v) in table {
                if let dict = v as? [String: Any] {
                    for k in ["CFBundleDisplayName", "CFBundleName"] { if let n = dict[k] as? String { out.append(n.lowercased()) } }
                }
            }
        }
        for lang in ["zh_CN", "zh-Hans", "zh_Hans", "de", "en"] {
            if let d = FileManager.default.contents(atPath: res + lang + ".lproj/InfoPlist.strings"),
               let dict = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: String] {
                for k in ["CFBundleDisplayName", "CFBundleName"] { if let n = dict[k] { out.append(n.lowercased()) } }
            }
        }
        return out
    }

    static func openApp(_ name: String) -> String {
        guard let url = appURL(name) else { return String(localized: "找不到叫「\(name)」的程序。可以用 list_apps 看看正在运行的程序。") }
        let (code, out) = Exporter.shell("/usr/bin/open", [url.path])
        let shown = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return code == 0 ? String(localized: "已打开「\(shown)」。") : String(localized: "打不开「\(name)」：\(out)")
    }

    @MainActor
    static func listApps() -> String {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return String(localized: "正在运行的程序：") + "\n" + apps.map {
            "- \($0.localizedName ?? "?")" + ($0.processIdentifier == front ? String(localized: "（最前面）") : "") + "  [\($0.bundleIdentifier ?? "")]"
        }.joined(separator: "\n")
    }
}

// MARK: - 界面: 屏幕顶部的提示条 / 设置面板

struct ControlBanner: View {
    @ObservedObject var cc = ComputerControl.shared
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.toolula).frame(width: 8, height: 8)
            Text("Toolula AI 正在操作「\(cc.activeApp ?? "")」").font(.callout.bold())
            Text("按 Esc 停止").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .frame(width: 420, height: 40)
    }
}

struct ComputerControlPanel: View {
    @ObservedObject var cc = ComputerControl.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $cc.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("允许 AI 操作电脑上的程序").bold()
                    Text("AI 可以运行快捷指令和 AppleScript、读取程序窗口里的按钮和输入框并点击、输入，必要时截屏查看。每次点击和输入都会先问你（除非本对话设为「都允许」）。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            Divider()
            permission(String(localized: "辅助功能"), String(localized: "读取窗口里的按钮、点击和输入"), cc.axTrusted) {
                cc.requestAccessibility(); ComputerControl.openSettings("Privacy_Accessibility")
            }
            permission(String(localized: "屏幕录制"), String(localized: "截屏查看画面（可选，读不出按钮时才用）"), cc.screenAllowed) {
                cc.requestScreen(); ComputerControl.openSettings("Privacy_ScreenCapture")
            }
            Text("授权后如果仍显示未允许，请重新打开 Toolula AI。安全规则：不操作密码管理器、钥匙串和系统设置；不往密码框里输入；操作时屏幕顶部会显示提示条，按 Esc 立即停止。")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 400)
        .onAppear { cc.refreshPermissions() }
    }

    func permission(_ title: String, _ detail: String, _ ok: Bool, _ open: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title).font(.callout.bold())
                Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok { Button("去允许") { open() }.controlSize(.small) } else { Text("已允许").font(.caption).foregroundStyle(.green) }
        }
    }
}
