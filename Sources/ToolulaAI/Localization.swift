import AppKit
import SwiftUI

/// 界面语言: 默认跟随系统, 也可以在设置里单独给 Leonix 选一种。
/// 支持: 简体中文、繁體中文、English、日本語、한국어、Deutsch、Français、Español、Português、Русский (其他语言用英文)
enum Lang {
    /// 实际使用的界面语言 (zh-Hans / zh-Hant / en / ja / ko / de / fr / es / pt-BR / pt / ru)
    static var code: String { Bundle.main.preferredLocalizations.first ?? "zh-Hans" }
    static var isChinese: Bool { code.hasPrefix("zh") }

    struct Option: Identifiable, Hashable {
        let code: String        // 写进 AppleLanguages 的代码
        let name: String        // 用这种语言自己的写法
        let ai: String          // 告诉 AI 用什么语言回答
        var id: String { code }
    }

    static let options: [Option] = [
        Option(code: "zh-Hans", name: "简体中文", ai: "简体中文"),
        Option(code: "zh-Hant", name: "繁體中文", ai: "繁體中文（台灣用語）"),
        Option(code: "en", name: "English", ai: "English"),
        Option(code: "ja", name: "日本語", ai: "日本語 (Japanese)"),
        Option(code: "ko", name: "한국어", ai: "한국어 (Korean)"),
        Option(code: "de", name: "Deutsch", ai: "Deutsch (German)"),
        Option(code: "fr", name: "Français", ai: "Français (French)"),
        Option(code: "es", name: "Español", ai: "Español (Spanish)"),
        Option(code: "pt-BR", name: "Português", ai: "Português (Portuguese)"),
        Option(code: "ru", name: "Русский", ai: "Русский (Russian)"),
    ]

    /// 当前界面语言对应的选项
    static var current: Option {
        let c = code
        if c.hasPrefix("zh") { return c.contains("Hant") || c.hasSuffix("TW") || c.hasSuffix("HK") ? options[1] : options[0] }
        if c.hasPrefix("pt") { return options[8] }
        return options.first { c.hasPrefix($0.code) } ?? options[2]
    }

    /// 告诉 AI 默认用什么语言回答
    static var aiLanguage: String { current.ai }

    /// 传给 Python 修图脚本的语言代码 (脚本里没有的语言会用英文)
    static var scriptLanguage: String {
        let c = current.code
        if c == "zh-Hans" { return "zh" }
        return c == "pt-BR" ? "pt" : c
    }

    // MARK: 单独给 Leonix 选语言 (写进 Leonix 自己的 AppleLanguages, 不改系统设置)

    /// nil = 跟随系统
    static var override: String? {
        get { (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String])?.first }
        set {
            if let v = newValue { UserDefaults.standard.set([v], forKey: "AppleLanguages") }
            else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        }
    }

    /// 换语言后重新打开 Leonix
    @MainActor
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// 设置里的「界面语言」选择
struct LanguagePicker: View {
    @State private var choice: String = Lang.override ?? ""
    @State private var changed = false

    var body: some View {
        Picker("界面语言", selection: $choice) {
            Text("跟随系统").tag("")
            ForEach(Lang.options) { o in Text(verbatim: o.name).tag(o.code) }
        }
        .onChange(of: choice) { _, v in
            Lang.override = v.isEmpty ? nil : v
            changed = true
        }
        if changed {
            HStack {
                Text("重新打开 Leonix 后生效。").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("立即重新打开") { Lang.relaunch() }
            }
        }
    }
}

extension String {
    /// 运行时才知道的文字 (枚举名、参数名、风格预设等) 的翻译
    var loc: String { NSLocalizedString(self, comment: "") }
    var locKey: LocalizedStringKey { LocalizedStringKey(self) }
}
