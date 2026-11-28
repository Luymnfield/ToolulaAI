import AppKit
import Foundation

// MARK: - 控制用户自己的 Chrome (用 Chrome 自带的 AppleScript 接口, 已登录的网站可以直接用)
//
// 读网页 / 点击 / 输入需要用户在 Chrome 里打开一次:
//   菜单「显示 → 开发者 → 允许 Apple 事件中的 JavaScript」
// 第一次控制时 macOS 会问用户是否允许 Leonix 控制 Chrome.

@MainActor
final class ChromeControl {
    static let shared = ChromeControl()
    private var elements: [Int: (tag: String, type: String, text: String)] = [:]

    static var installed: Bool { FileManager.default.fileExists(atPath: "/Applications/Google Chrome.app") }
    nonisolated static let jsOffHelp = String(localized: "Chrome 没有允许脚本读取网页。请用户在 Chrome 菜单「显示 → 开发者 → 允许 Apple 事件中的 JavaScript」打开一次（只需要一次）。")

    /// 运行 AppleScript, 返回 (成功, 输出)
    nonisolated static func osa(_ script: String) -> (Bool, String) {
        let (code, out) = Exporter.shell("/usr/bin/osascript", ["-e", script])
        return (code == 0, out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    nonisolated static func explain(_ out: String) -> String {
        if out.contains("JavaScript") && (out.contains("Apple Events") || out.contains("Apple 事件") || out.contains("turned off")) { return jsOffHelp }
        if out.contains("-1743") || out.lowercased().contains("not authorized") {
            return String(localized: "macOS 没有允许 Leonix 控制 Chrome。请用户在「系统设置 → 隐私与安全性 → 自动化」里允许 Leonix 控制 Google Chrome。")
        }
        return String(localized: "Chrome 出错：\(out)")
    }

    /// 在当前标签页里执行 JavaScript (脚本先写到文件, 避免引号转义问题)
    nonisolated static func runJS(_ js: String) async -> (Bool, String) {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("toolula_chrome_\(UUID().uuidString.prefix(6)).js")
        try? js.write(to: f, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: f) }
        let script = """
        set js to read (POSIX file "\(f.path)") as «class utf8»
        tell application "Google Chrome"
            if (count of windows) = 0 then make new window
            return execute active tab of front window javascript js
        end tell
        """
        return await Task.detached { osa(script) }.value
    }

    func tabs() async -> String {
        guard Self.installed else { return String(localized: "这台 Mac 没有安装 Google Chrome。") }
        let script = """
        tell application "Google Chrome"
            set out to ""
            set wi to 0
            repeat with w in windows
                set wi to wi + 1
                set ti to 0
                repeat with t in tabs of w
                    set ti to ti + 1
                    set mark to ""
                    if ti = (active tab index of w) then set mark to " ★"
                    set out to out & "窗口" & wi & " 标签" & ti & mark & "：" & (title of t) & " — " & (URL of t) & linefeed
                end repeat
            end repeat
            return out
        end tell
        """
        let (ok, out) = await Task.detached { Self.osa(script) }.value
        guard ok else { return Self.explain(out) }
        return out.isEmpty ? String(localized: "Chrome 没有打开的标签页。") : String(localized: "Chrome 的标签页（★ 是当前标签）：") + "\n" + out
    }

    func open(_ url: String, newTab: Bool) async -> String {
        guard Self.installed else { return String(localized: "这台 Mac 没有安装 Google Chrome。") }
        var u = url.trimmingCharacters(in: .whitespaces)
        if !u.contains("://") { u = "https://" + u }
        guard let parsed = URL(string: u), ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else {
            return String(localized: "只能打开 http / https 网址")
        }
        let esc = u.replacingOccurrences(of: "\\", with: "%5C").replacingOccurrences(of: "\"", with: "%22")
        let script = newTab ? """
        tell application "Google Chrome"
            activate
            if (count of windows) = 0 then make new window
            tell front window to make new tab with properties {URL:"\(esc)"}
        end tell
        """ : """
        tell application "Google Chrome"
            activate
            if (count of windows) = 0 then make new window
            set URL of active tab of front window to "\(esc)"
        end tell
        """
        let (ok, out) = await Task.detached { Self.osa(script) }.value
        guard ok else { return Self.explain(out) }
        // 等页面加载
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(500))
            let (_, loading) = await Task.detached { Self.osa("tell application \"Google Chrome\" to return loading of active tab of front window") }.value
            if loading == "false" { break }
        }
        return await read(tab: nil)
    }

    /// 读当前标签页 (可选: 先切换到第几个标签)
    func read(tab: Int?) async -> String {
        guard Self.installed else { return String(localized: "这台 Mac 没有安装 Google Chrome。") }
        if let tab {
            let (ok, out) = await Task.detached { Self.osa("tell application \"Google Chrome\" to set active tab index of front window to \(tab)") }.value
            if !ok { return Self.explain(out) }
            try? await Task.sleep(for: .milliseconds(300))
        }
        let (ok, raw) = await Self.runJS(BrowserController.extractJS)
        guard ok else { return Self.explain(raw) }
        guard let (text, els) = BrowserController.format(raw) else { return String(localized: "读不到这个页面的内容") }
        elements = els
        return text
    }

    func needsApproval(_ id: Int) -> Bool { elements[id]?.tag != "a" }
    func isPassword(_ id: Int) -> Bool { elements[id]?.type == "password" }
    func describe(_ id: Int) -> String { elements[id].map { "「\($0.text)」(\($0.tag))" } ?? "#\(id)" }

    func click(_ id: Int) async -> String {
        let (ok, r) = await Self.runJS(BrowserController.clickJS(id))
        guard ok else { return Self.explain(r) }
        if r != "ok" { return String(localized: "找不到编号 \(id) 的元素，请先用 chrome_open（url 留空）重新读取页面") }
        try? await Task.sleep(for: .milliseconds(1500))
        return await read(tab: nil)
    }

    func type(_ id: Int, _ text: String, submit: Bool) async -> String {
        if isPassword(id) { return String(localized: "这是密码框。为了安全 Leonix 不输入密码，请用户自己输入。") }
        guard let js = BrowserController.typeJS(id, text: text, submit: submit) else { return String(localized: "无法输入") }
        let (ok, r) = await Self.runJS(js)
        guard ok else { return Self.explain(r) }
        if r != "ok" { return String(localized: "找不到编号 \(id) 的输入框，请先用 chrome_open（url 留空）重新读取页面") }
        try? await Task.sleep(for: .milliseconds(submit ? 2000 : 500))
        return await read(tab: nil)
    }

    func back() async -> String {
        let (ok, out) = await Task.detached { Self.osa("tell application \"Google Chrome\" to go back active tab of front window") }.value
        guard ok else { return Self.explain(out) }
        try? await Task.sleep(for: .milliseconds(1200))
        return await read(tab: nil)
    }
}
