import AppIntents
import AppKit

// 快捷指令 / Siri 动作。在「快捷指令」App 里搜 Leonix 就能用, 也能放进自动化。
// 元数据由 build_app.sh 里的 appintentsmetadataprocessor 生成 (项目不是 Xcode 工程)。

struct AskToolulaIntent: AppIntent {
    static var title: LocalizedStringResource = "问 Leonix"
    static var description = IntentDescription("用本机 AI 回答一个问题，返回回答的文字。不联网，不打开窗口。")
    static var openAppWhenRun = false

    @Parameter(title: "问题") var question: String

    static var parameterSummary: some ParameterSummary { Summary("问 Leonix：\(\.$question)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = try await IntentRunner.ask(question)
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

struct SummarizeFilesIntent: AppIntent {
    static var title: LocalizedStringResource = "用 Leonix 总结文件"
    static var description = IntentDescription("读 PDF、Word、Excel、PPT、文本等文件，返回要点总结。")
    static var openAppWhenRun = false

    @Parameter(title: "文件") var files: [IntentFile]
    @Parameter(title: "要求", default: "总结主要内容，列出关键信息") var instruction: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        var blocks: [String] = []
        for f in files {
            let url = try IntentRunner.localURL(f)
            let d = try await Task.detached { try DocReader.load(url) }.value
            blocks.append(d.isLong ? String(d.text.prefix(40_000)) : d.promptBlock())
        }
        let answer = try await IntentRunner.ask(instruction + "\n\n" + blocks.joined(separator: "\n\n"))
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

struct GenerateImageIntent: AppIntent {
    static var title: LocalizedStringResource = "用 Leonix 画图"
    static var description = IntentDescription("用绘图页现在的模型和设置生成图片（加入队列，生成好会发通知）。")
    static var openAppWhenRun = true

    @Parameter(title: "画面描述") var prompt: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        GenQueue.shared.addImages([prompt])
        return .result(dialog: IntentDialog(stringLiteral: String(localized: "已加入绘图队列，生成好会通知你。")))
    }
}

struct GenerateVideoIntent: AppIntent {
    static var title: LocalizedStringResource = "用 Leonix 生成视频"
    static var description = IntentDescription("用视频页现在的模型和设置生成视频（加入队列，生成好会发通知）。")
    static var openAppWhenRun = true

    @Parameter(title: "视频描述") var prompt: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        GenQueue.shared.addVideos([prompt])
        return .result(dialog: IntentDialog(stringLiteral: String(localized: "已加入视频队列，生成好会通知你。")))
    }
}

struct EditPhotosIntent: AppIntent {
    static var title: LocalizedStringResource = "用 Leonix 修图"
    static var description = IntentDescription("把照片加到 Leonix 的修图页。")
    static var openAppWhenRun = true

    @Parameter(title: "照片") var photos: [IntentFile]

    @MainActor
    func perform() async throws -> some IntentResult {
        let urls = try photos.map { try IntentRunner.localURL($0) }
        IntentRunner.app?.section = .photo
        IntentRunner.store?.add(urls: urls)
        return .result()
    }
}

struct ToolulaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskToolulaIntent(), phrases: ["Ask \(.applicationName)", "问 \(.applicationName)"],
                    shortTitle: "问 Leonix", systemImageName: "sparkles")
        AppShortcut(intent: SummarizeFilesIntent(), phrases: ["Summarize files with \(.applicationName)", "用 \(.applicationName) 总结文件"],
                    shortTitle: "总结文件", systemImageName: "doc.text.magnifyingglass")
        AppShortcut(intent: GenerateImageIntent(), phrases: ["Draw with \(.applicationName)", "用 \(.applicationName) 画图"],
                    shortTitle: "画图", systemImageName: "paintbrush.pointed")
        AppShortcut(intent: GenerateVideoIntent(), phrases: ["Make a video with \(.applicationName)", "用 \(.applicationName) 生成视频"],
                    shortTitle: "生成视频", systemImageName: "film")
        AppShortcut(intent: EditPhotosIntent(), phrases: ["Edit photos with \(.applicationName)", "用 \(.applicationName) 修图"],
                    shortTitle: "修图", systemImageName: "wand.and.stars")
    }
}

/// 动作共用的小工具
@MainActor
enum IntentRunner {
    static weak var app: AppState?
    static weak var store: Store?

    enum Failure: LocalizedError {
        case noModel, noFile
        var errorDescription: String? {
            switch self {
            case .noModel: return String(localized: "还没有可用的对话模型。请先打开 Leonix 设置一个模型。")
            case .noFile: return String(localized: "读不到这个文件")
            }
        }
    }

    /// 不用工具的一问一答 (有快速模型时用快速模型)
    static func ask(_ question: String) async throws -> String {
        let mm = ModelManager.shared
        if mm.models.isEmpty { mm.refresh(); try? await Task.sleep(for: .seconds(1)) }
        guard !mm.chatModel.isEmpty else { throw Failure.noModel }
        let model = mm.fastModel(for: mm.chatModel) ?? mm.chatModel
        if mm.model(model) != nil { await mm.ensureLoaded(model) }
        let msgs: [[String: Any]] = [
            ["role": "system", "content": "你是 Leonix，运行在用户 Mac 本机。默认用\(Lang.aiLanguage)回答，简洁清楚。回答会显示在快捷指令里，少用 Markdown 表格。"],
            ["role": "user", "content": question],
        ]
        let r = try await LLMClient.stream(model: model, messages: msgs, tools: nil, reasoning: "none") { _, _ in }
        return DocReader.clean(r.content)
    }

    /// 快捷指令传来的文件: 有路径就用路径, 只有数据就先存到缓存文件夹
    static func localURL(_ f: IntentFile) throws -> URL {
        if let u = f.fileURL, FileManager.default.fileExists(atPath: u.path) { return u }
        let dest = AppPaths.cacheDir("Shortcuts").appendingPathComponent(f.filename.isEmpty ? UUID().uuidString : f.filename)
        guard (try? f.data.write(to: dest)) != nil else { throw Failure.noFile }
        return dest
    }
}
