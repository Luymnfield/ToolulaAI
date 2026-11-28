import AVFoundation
import NaturalLanguage
import Speech
import SwiftUI

// 语音: 说话输入 (本机语音识别, 支持的语言不上传) 和朗读回答。

/// 说话输入: 按一下开始听, 再按一下 (或停顿一会儿) 结束, 识别出的文字放进输入框
@MainActor
final class Dictation: ObservableObject {
    static let shared = Dictation()

    @Published private(set) var listening = false
    @Published var error: String?
    /// 正在识别的文字 (边说边出)
    @Published private(set) var partial = ""

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onFinish: ((String) -> Void)?
    private var silence: Task<Void, Never>?

    /// 界面语言对应的识别语言
    static var locale: Locale {
        let c = Lang.current.code
        let map = ["zh-Hans": "zh-CN", "zh-Hant": "zh-TW", "en": "en-US", "ja": "ja-JP", "ko": "ko-KR", "de": "de-DE",
                   "fr": "fr-FR", "es": "es-ES", "pt-BR": "pt-BR", "ru": "ru-RU"]
        return Locale(identifier: map[c] ?? "en-US")
    }

    func toggle(_ finish: @escaping (String) -> Void) {
        if listening { stop(); return }
        error = nil
        onFinish = finish
        Task { await start() }
    }

    private func start() async {
        // 两个权限: 麦克风、语音识别
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard mic else { error = String(localized: "没有麦克风权限：请在「系统设置 → 隐私与安全性 → 麦克风」里允许 Leonix"); return }
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard speech == .authorized else { error = String(localized: "没有语音识别权限：请在「系统设置 → 隐私与安全性 → 语音识别」里允许 Leonix"); return }
        guard let rec = SFSpeechRecognizer(locale: Self.locale) ?? SFSpeechRecognizer(), rec.isAvailable else {
            error = String(localized: "这台电脑上暂时用不了语音识别"); return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }   // 能在本机识别就不上传
        req.addsPunctuation = true
        request = req
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buf, _ in req?.append(buf) }
        engine.prepare()
        do { try engine.start() } catch { self.error = error.localizedDescription; return }
        partial = ""
        listening = true
        task = rec.recognitionTask(with: req) { [weak self] result, err in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                guard let self else { return }
                if let text { self.partial = text; self.armSilenceTimer() }
                if final || err != nil { self.finish() }
            }
        }
        armSilenceTimer()
    }

    /// 停顿 2.5 秒没再说话就自动结束
    private func armSilenceTimer() {
        silence?.cancel()
        silence = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        guard listening else { return }
        request?.endAudio()
        // 等最后一段识别完再交出文字 (最多 1.5 秒)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.finish()
        }
    }

    private func finish() {
        guard listening else { return }
        listening = false
        silence?.cancel()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel(); task = nil; request = nil
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { onFinish?(text) }
        onFinish = nil
    }
}

/// 朗读回答 (系统自带的声音, 按内容自动选语言)
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()
    @Published private(set) var speaking: UUID?
    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    func toggle(_ id: UUID, _ markdown: String) {
        if speaking == id { stop(); return }
        stop()
        let text = Self.plain(markdown)
        guard !text.isEmpty else { return }
        let u = AVSpeechUtterance(string: text)
        let lang = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? Dictation.locale.identifier
        u.voice = AVSpeechSynthesisVoice(language: Self.voiceLanguage(lang))
        speaking = id
        synth.speak(u)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        speaking = nil
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in if !self.synth.isSpeaking { self.speaking = nil } }
    }

    /// NaturalLanguage 的语言代码 -> 系统声音的语言代码
    nonisolated static func voiceLanguage(_ nl: String) -> String {
        ["zh-Hans": "zh-CN", "zh-Hant": "zh-TW", "en": "en-US", "ja": "ja-JP", "ko": "ko-KR", "de": "de-DE", "fr": "fr-FR",
         "es": "es-ES", "pt": "pt-BR", "ru": "ru-RU", "it": "it-IT"][nl] ?? nl
    }

    /// Markdown 变成适合朗读的纯文字: 代码块不念, 去掉符号和链接地址
    nonisolated static func plain(_ md: String) -> String {
        var s = md.replacingOccurrences(of: #"```[\s\S]*?```"#, with: "（代码略）", options: .regularExpression)
        s = s.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s{0,3}(#{1,6}|>|[-*+]|\d+\.)\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s*\|?\s*:?-{3,}.*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[*_`~|]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 输入框旁边的话筒按钮
struct DictationButton: View {
    @ObservedObject var d = Dictation.shared
    let onText: (String) -> Void

    var body: some View {
        Button { d.toggle(onText) } label: {
            Image(systemName: d.listening ? "mic.fill" : "mic").font(.title3)
                .foregroundStyle(d.listening ? Color.red : Color.primary)
                .symbolEffect(.pulse, isActive: d.listening)
        }
        .buttonStyle(.plain)
        .help(d.listening ? Text("正在听…再按一下结束") : Text("说话输入"))
        .accessibilityLabel(d.listening ? Text("停止听写") : Text("说话输入"))
        .popover(isPresented: Binding(get: { d.error != nil }, set: { if !$0 { d.error = nil } })) {
            Text(d.error ?? "").padding().frame(maxWidth: 300)
        }
    }
}
