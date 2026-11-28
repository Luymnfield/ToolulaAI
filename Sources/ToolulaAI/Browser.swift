import AppKit
import WebKit

/// Leonix 自带的浏览器: AI 通过工具操作它, 用户可以在窗口里看着 (也可以自己登录网站)
@MainActor
final class BrowserController: NSObject, WKNavigationDelegate {
    static let shared = BrowserController()

    let webView: WKWebView
    private var window: NSWindow?
    private var loadContinuation: CheckedContinuation<Void, Never>?
    /// 上次读取页面时给可交互元素编的号 -> (标签, 类型, 文字)
    private(set) var elements: [Int: (tag: String, type: String, text: String)] = [:]

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 780), configuration: cfg)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        super.init()
        webView.navigationDelegate = self
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = String(localized: "Leonix 浏览器")
            w.contentView = webView
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.orderFront(nil)
    }

    // MARK: 加载

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoad() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishLoad() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishLoad() }

    private func finishLoad() {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    private func waitForLoad(timeout: Double = 25) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            loadContinuation?.resume()
            loadContinuation = c
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                self.finishLoad()
            }
        }
        // 给用 JavaScript 渲染的网页一点时间
        try? await Task.sleep(for: .milliseconds(900))
    }

    func open(_ urlString: String) async -> String {
        var s = urlString.trimmingCharacters(in: .whitespaces)
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            return String(localized: "网址不对：\(urlString)")
        }
        show()
        webView.load(URLRequest(url: url))
        await waitForLoad()
        return await readPage()
    }

    func back() async -> String {
        guard webView.canGoBack else { return String(localized: "没有上一页") }
        webView.goBack()
        await waitForLoad()
        return await readPage()
    }

    // MARK: 读取页面

    static let extractJS = """
    (() => {
      const vis = el => { const r = el.getBoundingClientRect(); const st = getComputedStyle(el);
        return r.width > 1 && r.height > 1 && st.visibility !== 'hidden' && st.display !== 'none'; };
      document.querySelectorAll('[data-tid]').forEach(e => e.removeAttribute('data-tid'));
      let n = 0; const els = [];
      for (const el of document.querySelectorAll('a[href], button, input, textarea, select, [role=button], [role=link], [onclick]')) {
        if (n >= 120) break;
        if (!vis(el) || (el.tagName === 'INPUT' && el.type === 'hidden')) continue;
        n++; el.setAttribute('data-tid', String(n));
        els.push({ id: n, tag: el.tagName.toLowerCase(), type: el.type || el.getAttribute('role') || '',
          text: (el.innerText || el.value || el.getAttribute('aria-label') || el.title || el.alt || '').trim().replace(/\\s+/g, ' ').slice(0, 80),
          href: el.href || '', ph: el.placeholder || '' });
      }
      const text = (document.body ? document.body.innerText : '').replace(/\\n{3,}/g, '\\n\\n').slice(0, 12000);
      return JSON.stringify({ title: document.title, url: location.href, text, els });
    })()
    """

    func readPage() async -> String {
        guard let raw = try? await webView.evaluateJavaScript(Self.extractJS) as? String,
              let (text, els) = Self.format(raw) else {
            return String(localized: "读不到这个页面的内容")
        }
        elements = els
        return text
    }

    /// 把页面提取脚本的结果整理成给 AI 看的文字 (内置浏览器和 Chrome 共用)
    static func format(_ raw: String) -> (String, [Int: (tag: String, type: String, text: String)])? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return nil }
        var elements: [Int: (tag: String, type: String, text: String)] = [:]
        var lines: [String] = []
        for e in (obj["els"] as? [[String: Any]]) ?? [] {
            guard let id = e["id"] as? Int else { continue }
            let tag = e["tag"] as? String ?? "", type = e["type"] as? String ?? "", text = e["text"] as? String ?? ""
            elements[id] = (tag, type, text)
            switch tag {
            case "a": lines.append("[\(id)] 链接 「\(text)」 → \(e["href"] as? String ?? "")")
            case "input", "textarea":
                if type == "submit" || type == "button" { lines.append("[\(id)] 按钮 「\(text)」") }
                else { lines.append("[\(id)] 输入框(\(type)) \(e["ph"] as? String ?? "") \(text.isEmpty ? "" : "当前值：\(text)")") }
            case "select": lines.append("[\(id)] 下拉框 \(text)")
            default: lines.append("[\(id)] 按钮 「\(text)」")
            }
        }
        let text = """
        标题：\(obj["title"] as? String ?? "")
        网址：\(obj["url"] as? String ?? "")

        正文：
        \(obj["text"] as? String ?? "")

        可点击 / 可输入的元素（用编号操作）：
        \(lines.joined(separator: "\n"))
        """
        return (text, elements)
    }

    static func clickJS(_ id: Int) -> String {
        "(() => { const el = document.querySelector('[data-tid=\"\(id)\"]'); if (!el) return 'notfound'; el.scrollIntoView({block: 'center'}); el.click(); return 'ok'; })()"
    }

    static func typeJS(_ id: Int, text: String, submit: Bool) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]), let arr = String(data: data, encoding: .utf8) else { return nil }
        return """
        (() => { const el = document.querySelector('[data-tid="\(id)"]'); if (!el) return 'notfound';
          const v = \(arr)[0]; el.focus();
          const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : (el.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype);
          const setter = Object.getOwnPropertyDescriptor(proto, 'value'); if (setter && setter.set) setter.set.call(el, v); else el.value = v;
          el.dispatchEvent(new Event('input', {bubbles: true})); el.dispatchEvent(new Event('change', {bubbles: true}));
          if (\(submit ? "true" : "false")) {
            if (el.form) { if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit(); }
            else { for (const t of ['keydown', 'keypress', 'keyup']) el.dispatchEvent(new KeyboardEvent(t, {key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true})); }
          }
          return 'ok'; })()
        """
    }

    // MARK: 操作

    /// 点击元素是否需要用户确认 (按钮/提交需要, 普通链接不需要)
    func clickNeedsApproval(_ id: Int) -> Bool {
        guard let e = elements[id] else { return true }
        return e.tag != "a"
    }

    func describe(_ id: Int) -> String {
        guard let e = elements[id] else { return "#\(id)" }
        return "「\(e.text)」(\(e.tag))"
    }

    func isPassword(_ id: Int) -> Bool { elements[id]?.type == "password" }

    func click(_ id: Int) async -> String {
        let r = try? await webView.evaluateJavaScript(Self.clickJS(id)) as? String
        if r != "ok" { return String(localized: "找不到编号 \(id) 的元素，请先重新读取页面") }
        try? await Task.sleep(for: .milliseconds(600))
        if webView.isLoading { await waitForLoad() } else { try? await Task.sleep(for: .milliseconds(800)) }
        return await readPage()
    }

    func type(_ id: Int, text: String, submit: Bool) async -> String {
        guard let js = Self.typeJS(id, text: text, submit: submit) else { return String(localized: "无法输入") }
        let r = try? await webView.evaluateJavaScript(js) as? String
        if r != "ok" { return String(localized: "找不到编号 \(id) 的输入框，请先重新读取页面") }
        try? await Task.sleep(for: .milliseconds(600))
        if webView.isLoading { await waitForLoad() } else if submit { try? await Task.sleep(for: .milliseconds(1200)) }
        return await readPage()
    }

    /// 用 DuckDuckGo 搜索 (不需要登录, 不追踪)
    func search(_ query: String) async -> String {
        var comps = URLComponents(string: "https://html.duckduckgo.com/html/")!
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        show()
        webView.load(URLRequest(url: comps.url!))
        await waitForLoad()
        let js = """
        JSON.stringify([...document.querySelectorAll('.result')].slice(0, 10).map(r => ({
          t: (r.querySelector('.result__a') || {}).innerText || '', u: (r.querySelector('.result__a') || {}).href || '',
          s: (r.querySelector('.result__snippet') || {}).innerText || '' })))
        """
        guard let raw = try? await webView.evaluateJavaScript(js) as? String,
              let list = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: String]], !list.isEmpty else {
            return await readPage()
        }
        let lines = list.enumerated().map { i, r -> String in
            var url = r["u"] ?? ""
            // DuckDuckGo 的跳转链接里藏着真正的网址
            if let c = URLComponents(string: url), let real = c.queryItems?.first(where: { $0.name == "uddg" })?.value { url = real }
            return "\(i + 1). \(r["t"] ?? "")\n   \(url)\n   \(r["s"] ?? "")"
        }
        return String(localized: "搜索「\(query)」的结果：") + "\n\n" + lines.joined(separator: "\n\n")
    }
}
