import Foundation
import SwiftUI

/// 根据这台电脑的配置推荐能跑的本地模型
enum Recommender {
    enum Role: String, CaseIterable, Identifiable {
        case allround = "全能（对话 + 看图 + 修图）"
        case coding = "写代码 / 执行命令"
        case fast = "轻快（反应最快）"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .allround: return "eye"
            case .coding: return "terminal"
            case .fast: return "hare"
            }
        }
    }

    struct Entry: Identifiable, Hashable {
        let id: String          // Hugging Face 仓库
        let role: Role
        let sizeGB: Double      // 实际下载大小
        let score: Int          // 同一类里的质量排序
        let note: String
        var gguf: String? = nil // GGUF 仓库要下载的量化版本 (Intel Mac)
        var vision: Bool { role == .allround }
    }

    /// Apple 芯片 (MLX 格式). 大小是从 Hugging Face 实测的
    static let mlx: [Entry] = [
        Entry(id: "lmstudio-community/Qwen3.8-27B-MLX-8bit", role: .allround, sizeGB: 29.5, score: 100, note: "目前最好的本地全能模型"),
        Entry(id: "lmstudio-community/Qwen3.8-27B-MLX-6bit", role: .allround, sizeGB: 22.8, score: 96, note: "同上，稍微小一点"),
        Entry(id: "lmstudio-community/Qwen3.8-27B-MLX-4bit", role: .allround, sizeGB: 16.1, score: 92, note: "同上，32GB 内存也能跑"),
        Entry(id: "lmstudio-community/gemma-4-26B-A4B-it-QAT-MLX-4bit", role: .allround, sizeGB: 15.6, score: 84, note: "Google Gemma 4，速度快，能看图"),
        Entry(id: "lmstudio-community/gemma-4-12B-it-MLX-8bit", role: .allround, sizeGB: 12.7, score: 76, note: "Google Gemma 4 中型，能看图"),
        Entry(id: "lmstudio-community/Qwen3-VL-8B-Instruct-MLX-8bit", role: .allround, sizeGB: 9.9, score: 70, note: "看图准确的中小模型"),
        Entry(id: "lmstudio-community/gemma-4-E4B-it-MLX-8bit", role: .allround, sizeGB: 9.0, score: 66, note: "小巧的 Gemma 4，能看图"),
        Entry(id: "lmstudio-community/Qwen3-VL-8B-Instruct-MLX-4bit", role: .allround, sizeGB: 5.8, score: 60, note: "16GB 内存的好选择"),
        Entry(id: "lmstudio-community/Qwen3-VL-4B-Instruct-MLX-8bit", role: .allround, sizeGB: 5.1, score: 52, note: "很小的看图模型"),
        Entry(id: "lmstudio-community/gemma-4-E2B-it-MLX-4bit", role: .allround, sizeGB: 4.4, score: 44, note: "8GB 内存也能跑"),

        Entry(id: "lmstudio-community/Qwen3-Coder-Next-MLX-6bit", role: .coding, sizeGB: 64.8, score: 100, note: "写代码、执行命令最强"),
        Entry(id: "lmstudio-community/Qwen3-Coder-Next-MLX-4bit", role: .coding, sizeGB: 44.9, score: 95, note: "同上，更小"),
        Entry(id: "lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit", role: .coding, sizeGB: 32.5, score: 86, note: "快速的编程模型"),
        Entry(id: "lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-4bit", role: .coding, sizeGB: 17.2, score: 80, note: "32GB 内存能跑的编程模型"),
        Entry(id: "lmstudio-community/Qwen3.5-9B-MLX-8bit", role: .coding, sizeGB: 10.5, score: 64, note: "中小型通用模型"),
        Entry(id: "lmstudio-community/Qwen3.5-9B-MLX-4bit", role: .coding, sizeGB: 6.0, score: 58, note: "16GB 内存的通用模型"),
        Entry(id: "lmstudio-community/Qwen3.5-4B-MLX-4bit", role: .coding, sizeGB: 3.1, score: 42, note: "8GB 内存也能跑"),

        Entry(id: "lmstudio-community/gemma-4-26B-A4B-it-QAT-MLX-4bit", role: .fast, sizeGB: 15.6, score: 90, note: "混合专家模型，又快又聪明"),
        Entry(id: "lmstudio-community/gemma-4-E4B-it-MLX-4bit", role: .fast, sizeGB: 6.9, score: 70, note: "小巧快速，能看图"),
        Entry(id: "lmstudio-community/Qwen3.5-4B-MLX-4bit", role: .fast, sizeGB: 3.1, score: 55, note: "最小最快"),
    ]

    /// Apple 芯片 + Toolula 内置引擎 (llama.cpp 用 GGUF 格式). 大小包含看图用的 mmproj 文件, 从 Hugging Face 实测
    static let ggufMac: [Entry] = [
        Entry(id: "lmstudio-community/Qwen3.8-27B-GGUF", role: .allround, sizeGB: 30.0, score: 100, note: "目前最好的本地全能模型", gguf: "Q8_0"),
        Entry(id: "lmstudio-community/Qwen3.8-27B-GGUF", role: .allround, sizeGB: 23.4, score: 96, note: "同上，稍微小一点", gguf: "Q6_K"),
        Entry(id: "lmstudio-community/Qwen3.8-27B-GGUF", role: .allround, sizeGB: 17.7, score: 92, note: "同上，32GB 内存也能跑", gguf: "Q4_K_M"),
        Entry(id: "lmstudio-community/gemma-4-26B-A4B-it-GGUF", role: .allround, sizeGB: 18.0, score: 84, note: "Google Gemma 4，速度快，能看图", gguf: "Q4_K_M"),
        Entry(id: "lmstudio-community/Qwen3-VL-8B-Instruct-GGUF", role: .allround, sizeGB: 9.9, score: 70, note: "看图准确的中小模型", gguf: "Q8_0"),
        Entry(id: "lmstudio-community/gemma-4-E4B-it-GGUF", role: .allround, sizeGB: 9.0, score: 66, note: "小巧的 Gemma 4，能看图", gguf: "Q8_0"),
        Entry(id: "lmstudio-community/Qwen3-VL-8B-Instruct-GGUF", role: .allround, sizeGB: 6.2, score: 60, note: "16GB 内存的好选择", gguf: "Q4_K_M"),
        Entry(id: "lmstudio-community/Qwen3-VL-4B-Instruct-GGUF", role: .allround, sizeGB: 5.1, score: 52, note: "很小的看图模型", gguf: "Q8_0"),
        Entry(id: "lmstudio-community/gemma-4-E2B-it-GGUF", role: .allround, sizeGB: 4.4, score: 44, note: "8GB 内存也能跑", gguf: "Q4_K_M"),

        Entry(id: "lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-GGUF", role: .coding, sizeGB: 32.5, score: 86, note: "快速的编程模型", gguf: "Q8_0"),
        Entry(id: "lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-GGUF", role: .coding, sizeGB: 18.6, score: 80, note: "32GB 内存能跑的编程模型", gguf: "Q4_K_M"),
        Entry(id: "lmstudio-community/Qwen3.5-9B-GGUF", role: .coding, sizeGB: 10.5, score: 64, note: "中小型通用模型", gguf: "Q8_0"),
        Entry(id: "lmstudio-community/Qwen3.5-9B-GGUF", role: .coding, sizeGB: 6.6, score: 58, note: "16GB 内存的通用模型", gguf: "Q4_K_M"),
        Entry(id: "lmstudio-community/Qwen3.5-4B-GGUF", role: .coding, sizeGB: 3.4, score: 42, note: "8GB 内存也能跑", gguf: "Q4_K_M"),

        Entry(id: "lmstudio-community/gemma-4-26B-A4B-it-GGUF", role: .fast, sizeGB: 18.0, score: 90, note: "混合专家模型，又快又聪明", gguf: "Q4_K_M"),
        Entry(id: "lmstudio-community/gemma-4-E4B-it-GGUF", role: .fast, sizeGB: 6.3, score: 70, note: "小巧快速，能看图", gguf: "Q4_K_M"),
        Entry(id: "lmstudio-community/Qwen3.5-4B-GGUF", role: .fast, sizeGB: 3.4, score: 55, note: "最小最快", gguf: "Q4_K_M"),
    ]

    /// Intel Mac (只能用 GGUF, 靠 CPU 运行, 所以只推荐小模型)
    static let gguf: [Entry] = [
        Entry(id: "lmstudio-community/Qwen3.5-9B-GGUF", role: .allround, sizeGB: 6.5, score: 70, note: "能看图（需要 32GB 内存）", gguf: "Q4_K_M"),
        Entry(id: "lmstudio-community/Qwen3-VL-4B-Instruct-GGUF", role: .allround, sizeGB: 3.3, score: 55, note: "小巧的看图模型", gguf: "Q4_K_M"),
        Entry(id: "lmstudio-community/Qwen3.5-9B-GGUF", role: .coding, sizeGB: 6.5, score: 65, note: "通用模型", gguf: "Q4_K_M"),
        Entry(id: "lmstudio-community/Qwen3.5-4B-GGUF", role: .coding, sizeGB: 3.4, score: 50, note: "小而快", gguf: "Q4_K_M"),
        Entry(id: "lmstudio-community/Qwen3.5-4B-GGUF", role: .fast, sizeGB: 3.4, score: 60, note: "最快", gguf: "Q4_K_M"),
    ]

    // MARK: 这台电脑

    /// 自测用: 模拟别的电脑 (内存 GB / 是否 Intel)
    nonisolated(unsafe) static var simulatedRAM: Double?
    nonisolated(unsafe) static var simulateIntel = false

    static var appleSilicon: Bool {
        if simulateIntel { return false }
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &v, &size, nil, 0) == 0 && v == 1
    }

    static var ramGB: Double { simulatedRAM ?? (Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded() }

    /// 模型最多能占多少 (留给系统和其他软件)
    static var budgetGB: Double {
        let ram = ramGB
        if !appleSilicon { return ram * 0.45 }      // Intel: 模型在 CPU 内存里跑, 更保守
        return ram >= 32 ? ram * 0.7 - 2 : ram * 0.6
    }

    enum Advice { case local, localSmall, cloudOnly }
    static var advice: Advice {
        if ramGB < 8 || (!appleSilicon && ramGB < 16) { return .cloudOnly }
        if ramGB < 16 || !appleSilicon { return .localSmall }
        return .local
    }

    /// 每个用途推荐 1 个最好的 + 1 个更快的备选
    /// 当前对话引擎能用的模型目录
    static var catalog: [Entry] {
        if !appleSilicon { return gguf }
        return LocalEngine.preferred == .lmStudio ? mlx : ggufMac
    }

    static func picks() -> [(role: Role, best: Entry?, alt: Entry?)] {
        let list = catalog
        let budget = budgetGB
        return Role.allCases.map { role in
            let fits = list.filter { $0.role == role && $0.sizeGB <= budget }.sorted { $0.score > $1.score }
            let best = fits.first
            let alt = fits.first { $0.id != best?.id && $0.sizeGB < (best?.sizeGB ?? 0) * 0.65 }
            return (role, best, alt)
        }
    }

    /// 某个模型在这台电脑上跑起来怎样
    static func fit(_ sizeGB: Double) -> (LocalizedStringKey, Color) {
        let b = budgetGB
        if sizeGB <= b * 0.85 { return ("能流畅运行", .green) }
        if sizeGB <= b * 1.1 { return ("能运行，内存较紧", .orange) }
        return ("内存不够", .red)
    }

    // MARK: 默认模型

    /// 给已安装的本地模型打分 (用来自动选默认模型)
    static func score(localId: String, vision: Bool, forPhoto: Bool) -> Int {
        let lid = localId.replacingOccurrences(of: "builtin:", with: "").lowercased()
        let key = lid.split(separator: "/").last.map(String.init) ?? lid
        let base = key.replacingOccurrences(of: "-mlx", with: "").replacingOccurrences(of: "-gguf", with: "")
        let match = (mlx + gguf + ggufMac).filter { e in
            let n = e.id.lowercased().split(separator: "/").last.map(String.init) ?? ""
            return n.hasPrefix(base) || base.hasPrefix(n.components(separatedBy: "-mlx").first ?? n)
                || base.hasPrefix(n.components(separatedBy: "-gguf").first ?? n)
        }
        var s = match.map(\.score).max() ?? 30
        if forPhoto && !vision { return -1 }
        if vision { s += 5 }   // 能看图的模型更通用
        return s
    }
}

// MARK: - LM Studio 是否安装

enum LocalEngine {
    /// 自测用: 假装没装 LM Studio
    nonisolated(unsafe) static var simulateMissing = false
    static var installed: Bool {
        if simulateMissing { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: ModelManager.lms)
            || ["/Applications/LM Studio.app", "/Applications/Bionic.app"].contains { fm.fileExists(atPath: $0) }
    }
    static let downloadURL = URL(string: "https://lmstudio.ai")!
}

// MARK: - 推荐卡片

struct RecommendationPanel: View {
    @ObservedObject var downloader = ModelDownloader.shared
    @ObservedObject var info = SystemInfo.shared
    var showMachine = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if showMachine {
                        Text(info.summary.isEmpty ? "这台电脑" : info.summary).font(.headline)
                        Text("能流畅运行约 \(Int(Recommender.budgetGB)) GB 以内的模型")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !Recommender.appleSilicon {
                        Text("这是 Intel 芯片的 Mac：本地模型只能用 CPU 运行，速度较慢，所以只推荐小模型。追求效果建议连接云端 API。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    switch Recommender.advice {
                    case .cloudOnly:
                        Text("这台电脑内存较小，本地模型会很慢或跑不动。建议在「云端 API」里连接一个服务（例如 OpenAI、Claude、Gemini、DeepSeek），日常对话和修图都能用。")
                            .font(.caption).foregroundStyle(.orange)
                    case .localSmall:
                        Text("可以跑小型本地模型，适合简单对话和看图；复杂任务可以同时连接一个云端 API。")
                            .font(.caption).foregroundStyle(.secondary)
                    case .local:
                        EmptyView()
                    }
                }
                Spacer()
            }
            ForEach(Recommender.picks(), id: \.role) { p in
                if let best = p.best {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(p.role.rawValue.locKey, systemImage: p.role.icon).font(.caption.bold()).foregroundStyle(.secondary)
                        RecommendedRow(entry: best, tag: "推荐")
                        if let alt = p.alt { RecommendedRow(entry: alt, tag: "更快") }
                    }
                }
            }
            if Recommender.picks().allSatisfy({ $0.best == nil }) {
                Text("没有适合这台电脑的本地模型，请使用云端 API。").foregroundStyle(.orange)
            }
        }
    }
}

struct RecommendedRow: View {
    @ObservedObject var downloader = ModelDownloader.shared
    let entry: Recommender.Entry
    let tag: LocalizedStringKey

    var body: some View {
        let installed = ModelDownloader.isInstalled(entry.id)
        let fit = Recommender.fit(entry.sizeGB)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.id.split(separator: "/").last.map(String.init) ?? entry.id).bold()
                    pill(tag, Color.toolula)
                }
                HStack(spacing: 6) {
                    Text(String(format: "%.1f GB", entry.sizeGB)).font(.caption).foregroundStyle(.secondary)
                    pill(fit.0, fit.1)
                    Text(entry.note.locKey).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if installed {
                Label("已下载", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            } else if let job = downloader.jobs.first(where: { $0.id == entry.id && !$0.done && !$0.failed }) {
                DownloadMini(job: job)
            } else {
                Button("下载") { downloader.download(entry.id, quant: entry.gguf) }
            }
        }
        .padding(.vertical, 2)
    }
}

struct DownloadMini: View {
    @ObservedObject var job: DownloadJob
    var body: some View {
        HStack {
            ProgressView(value: job.fraction).frame(width: 90)
            Text("\(Int(job.fraction * 100))%").font(.caption).monospacedDigit()
        }
    }
}

// MARK: - 主页上的「开始使用」引导

struct SetupBanner: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var models = ModelManager.shared
    @AppStorage("modelsTab") private var modelsTab = 0

    var body: some View {
        if !LocalEngine.installed && !BuiltinEngine.installed && models.cloudModels.isEmpty {
            banner(icon: "arrow.down.app", title: "第一步：一键安装本地 AI",
                   text: "Toolula 会检测这台 Mac，自动下载适合它的 AI 引擎和模型，不需要另外安装软件。内存较小的电脑也可以直接连接云端 API。") {
                Button("打开设置向导") { SetupWizardState.shared.show = true }.buttonStyle(.borderedProminent).tint(Color.toolula)
                Button("连接云端 API") { modelsTab = 2; app.section = .models }
            }
        } else if models.online && models.localChatModels.isEmpty && models.cloudModels.isEmpty {
            banner(icon: "sparkles", title: "下载第一个模型",
                   text: "已经根据这台电脑的配置挑好了合适的模型，点一下就能下载。") {
                Button("查看推荐") { modelsTab = 1; app.section = .models }.buttonStyle(.borderedProminent).tint(Color.toolula)
            }
        } else if LocalEngine.installed && !models.lmOnline && models.cloudModels.isEmpty && !BuiltinEngine.installed {
            banner(icon: "bolt.horizontal.circle", title: "本地 AI 服务没有运行",
                   text: "LM Studio 已经安装，但它的本地服务没开。点「启动」即可。") {
                Button("启动") { models.startServer() }
            }
        }
    }

    func banner<B: View>(icon: String, title: LocalizedStringKey, text: LocalizedStringKey, @ViewBuilder buttons: () -> B) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title).foregroundStyle(Color.toolula)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack { buttons() }.padding(.top, 2)
            }
            Spacer()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.toolula.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.toolula.opacity(0.35)))
    }
}
