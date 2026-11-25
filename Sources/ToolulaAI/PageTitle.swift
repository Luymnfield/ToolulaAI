import SwiftUI

/// 窗口标题栏：标题是当前页面（助手页显示对话名），副标题是这个页面此刻的状态。
/// 视频或绘图正在生成时，不管在哪个页面都在副标题前面显示进度。
struct PageTitle: ViewModifier {
    let section: AppSection
    @EnvironmentObject var store: Store
    @EnvironmentObject var chat: ChatStore
    @EnvironmentObject var automations: AutomationStore
    @ObservedObject var models = ModelManager.shared
    @ObservedObject var images = ImageStore.shared
    @ObservedObject var imageModels = ImageModels.shared
    @ObservedObject var videos = VideoStore.shared
    @ObservedObject var videoModels = VideoModels.shared
    @ObservedObject var skills = SkillStore.shared
    @ObservedObject var memory = MemoryStore.shared

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
    }

    var title: String {
        switch section {
        case .home: return "Toolula AI"
        case .chat:
            if let c = chat.current, !c.title.isEmpty { return c.title }
            return String(localized: "新对话")
        default: return String(localized: String.LocalizationValue(section.rawValue))
        }
    }

    var subtitle: String {
        var parts: [String] = []
        // 后台生成的进度：在别的页面也能看到
        if videos.running, section != .video { parts.append(String(localized: "视频生成中 \(percent(videos.step, videos.steps))")) }
        if images.running, section != .image { parts.append(String(localized: "绘图中 \(percent(images.step, images.steps))")) }
        parts += pageParts
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var pageParts: [String] {
        switch section {
        case .home:
            return [models.online ? String(localized: "本地 AI 在线") : String(localized: "本地 AI 离线"), modelName(models.chatModel)]
        case .chat:
            // 模型和思考档位在右边工具栏里已经有了，这里显示对话本身的状态
            guard let c = chat.current else { return [] }
            let n = c.messages.filter { $0.role == "user" || ($0.role == "assistant" && !$0.text.isEmpty) }.count
            var p: [String] = []
            if n > 0 { p.append(String(localized: "\(String(n)) 条消息")) }
            let dir = (c.workDir as NSString).abbreviatingWithTildeInPath
            if dir != "~" { p.append(String(localized: "文件夹：\(dir)")) }
            if chat.running.contains(c.id) { p.append(String(localized: "正在回答…")) }
            return p
        case .photo:
            if store.photos.isEmpty { return [String(localized: "拖入照片开始")] }
            let edited = store.photos.filter { $0.ai != nil || !$0.manual.isEmpty }.count
            var p = [String(localized: "\(String(store.photos.count)) 张照片"), String(localized: "已调 \(String(edited)) 张")]
            if store.selection.count == 1, let id = store.selection.first, let ph = store.photos.first(where: { $0.id == id }) {
                p.append(String(localized: "当前：\(ph.name)"))
            } else if store.selection.count > 1 {
                p.append(String(localized: "已选 \(String(store.selection.count)) 张"))
            }
            if store.working, !store.status.isEmpty { p.append(store.status) }
            return p
        case .image:
            let spec = imageModels.selected
            var p = [spec.name]
            if images.running { p.append(String(localized: "正在生成 \(percent(images.step, images.steps))")) }
            else if images.estimateSeconds > 0 { p.append(String(localized: "约 \(String(Int(images.estimateSeconds.rounded()))) 秒一张")) }
            p.append(String(localized: "已生成 \(String(images.items.count)) 张"))
            return p
        case .video:
            var p = [videoModels.selected.name]
            if videos.running {
                p.append(String(localized: "正在生成 \(percent(videos.step, videos.steps))"))
                if let left = videoLeft { p.append(left) }
            }
            p.append(String(localized: "已生成 \(String(videos.items.count)) 个"))
            return p
        case .automation:
            let on = automations.tasks.filter(\.enabled).count
            var p = [String(localized: "\(String(automations.tasks.count)) 个任务"), String(localized: "\(String(on)) 个已开启")]
            if automations.runningTask != nil { p.append(String(localized: "正在运行")) }
            return p
        case .skills:
            return [String(localized: "\(String(skills.skills.count)) 个技能")]
        case .memory:
            return [String(localized: "\(String(memory.items.count)) 条记忆"), memory.enabled ? String(localized: "记忆已开启") : String(localized: "记忆已关闭")]
        case .models:
            let local = models.models.filter { !$0.isCloud && $0.isChat }.count
            return [String(localized: "\(String(local)) 个本地对话模型"), String(localized: "当前：\(modelName(models.chatModel))")]
        }
    }

    func modelName(_ id: String) -> String {
        if let m = models.models.first(where: { $0.id == id }) { return m.displayName }
        if id.hasPrefix("builtin:") { return String(id.dropFirst(8)) }
        if id.hasPrefix("mlx:") { return String(id.dropFirst(4)) + " ⚡MTP" }
        return id.split(separator: "/").last.map(String.init) ?? id
    }

    func percent(_ step: Int, _ steps: Int) -> String {
        steps > 0 ? "\(String(min(100, step * 100 / steps)))%" : ""
    }

    var videoLeft: String? {
        guard let start = videos.startedAt, videos.steps > 0, videos.step > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        let left = elapsed / Double(videos.step) * Double(videos.steps - videos.step)
        let m = Int((left / 60).rounded(.up))
        return m > 0 ? String(localized: "剩约 \(String(m)) 分钟") : nil
    }
}
