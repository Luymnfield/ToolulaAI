import Foundation
import SwiftUI

/// 界面语言跟随系统: 简体中文 / English / Deutsch (其他语言用英文)
enum Lang {
    /// 实际使用的界面语言 (zh-Hans / en / de)
    static var code: String { Bundle.main.preferredLocalizations.first ?? "zh-Hans" }
    static var isChinese: Bool { code.hasPrefix("zh") }

    /// 告诉 AI 默认用什么语言回答
    static var aiLanguage: String {
        if code.hasPrefix("de") { return "Deutsch (German)" }
        if code.hasPrefix("en") { return "English" }
        return "简体中文"
    }

    /// 传给 Python 修图脚本的语言
    static var scriptLanguage: String {
        if code.hasPrefix("de") { return "de" }
        if code.hasPrefix("en") { return "en" }
        return "zh"
    }
}

extension String {
    /// 运行时才知道的文字 (枚举名、参数名、风格预设等) 的翻译
    var loc: String { NSLocalizedString(self, comment: "") }
    var locKey: LocalizedStringKey { LocalizedStringKey(self) }
}
