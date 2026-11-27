import AppKit
import CoreImage
import SwiftUI

// MARK: - 质量检查: 当前效果的客观指标 (过曝、死黑、白平衡、肤色、亮度), 改一下就重新量

struct QualityCard: View {
    @ObservedObject var item: PhotoItem
    @State private var rows: [(String, String, Bool)] = []   // 名字, 数值, 是否正常

    var body: some View {
        StepCard(title: "质量检查", icon: "checkmark.seal") { EmptyView() } content: {
            if rows.isEmpty {
                Text("正在量…").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows, id: \.0) { r in
                        HStack(spacing: 6) {
                            Image(systemName: r.2 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(r.2 ? Color.green : Color.orange).font(.caption)
                            Text(r.0.locKey).font(.caption).frame(width: 52, alignment: .leading)
                            Text(verbatim: r.1).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                Text("程序在当前效果上量出来的，比用眼睛看缩略图准。橙色的地方值得看一眼（舞台、夜景等本来就暗的照片，死黑多一些是正常的）。")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: "\(item.id)-\(item.revision)") {
            try? await Task.sleep(for: .milliseconds(450))   // 拖滑块时不要每一下都量
            guard !Task.isCancelled, let base = item.previewBase else { return }
            let settings = item.settings, patches = item.patches, portrait = item.portrait, locals = item.locals, cache = item.maskCache
            let result = await Task.detached(priority: .utility) { () -> [(String, String, Bool)] in
                let r = Renderer.shared
                let small = r.scale(base, maxSide: PhotoMeasure.side * 2)
                let img = r.renderEdited(small, settings: settings, patches: patches, locals: locals, portrait: portrait, cache: MaskCache())
                guard let s = PhotoMeasure.stats(img, skin: cache.portraitAnalysis(for: base)?.skin) else { return [] }
                return QualityCard.rows(s)
            }.value
            if !Task.isCancelled { rows = result }
        }
    }

    nonisolated static func rows(_ s: PhotoMeasure.Stats) -> [(String, String, Bool)] {
        var out: [(String, String, Bool)] = []
        out.append(("高光", String(localized: "过曝 \(String(format: "%.1f%%", s.clipHi))"), s.clipHi < 1.5))
        out.append(("暗部", String(localized: "死黑 \(String(format: "%.1f%%", s.clipLo))"), s.clipLo < 4))
        if s.neutralShare > 0.03 {
            let m = PhotoMeasure.forAI(s)["cast"] as? String ?? ""
            let strong = m.contains("中等") || m.contains("明显")
            out.append(("白平衡", Self.castText(s), !strong))
        }
        if let k = s.skin {
            let ok = k.luma >= 0.35 && k.luma <= 0.82 && k.hue >= 10 && k.hue <= 38 && k.sat >= 0.15 && k.sat <= 0.6
            out.append(("肤色", String(localized: "亮度 \(pct(k.luma)) · 色相 \(String(Int(k.hue)))° · 饱和度 \(pct(k.sat))"), ok))
        }
        out.append(("亮度", String(localized: "中位 \(pct(s.p50))（暗部 \(pct(s.p1)) ~ 亮部 \(pct(s.p99))）"), s.p50 > 0.12 && s.p50 < 0.85))
        return out
    }

    nonisolated static func pct(_ v: Double) -> String { String(format: "%d%%", Int((v * 100).rounded())) }

    nonisolated static func castText(_ s: PhotoMeasure.Stats) -> String {
        var parts: [String] = []
        if abs(s.castB) > 4 { parts.append(s.castB > 0 ? String(localized: "偏暖") : String(localized: "偏冷")) }
        if abs(s.castA) > 4 { parts.append(s.castA > 0 ? String(localized: "偏品红") : String(localized: "偏绿")) }
        let level = max(abs(s.castA), abs(s.castB))
        if parts.isEmpty { return String(localized: "基本中性") }
        return parts.joined(separator: "、") + " (" + (level > 20 ? String(localized: "明显") : level > 10 ? String(localized: "中等") : String(localized: "轻微")) + ")"
    }
}

// MARK: - 盲选: 两个方案并排、不告诉你哪个是哪个, 选更好的那个. 选择记下来, 以后修图时告诉 AI 你的偏好

enum StylePicks {
    struct Pick: Codable {
        var date = Date()
        var scene: String          // portrait / landscape / other
        var winner: Settings
        var loser: Settings
    }

    static var file: URL { AppPaths.dataFile("style_picks.json") }

    static func load() -> [Pick] { SafeJSON.load([Pick].self, from: file) ?? [] }

    static func record(_ p: Pick) {
        var all = load()
        all.append(p)
        if all.count > 500 { all.removeFirst(all.count - 500) }
        _ = SafeJSON.save(all, to: file)
    }

    /// 这类照片里你更喜欢的方向 (至少 3 次盲选才说), 给 AI 看的一句话
    static func hint(scene: String) -> String? {
        let picks = load().filter { $0.scene == scene }
        guard picks.count >= 3 else { return nil }
        var sum: [String: Double] = [:]
        for p in picks {
            for k in Set(p.winner.keys).union(p.loser.keys) where Params.specByKey[k] != nil {
                sum[k, default: 0] += (p.winner[k] ?? 0) - (p.loser[k] ?? 0)
            }
        }
        let n = Double(picks.count)
        let parts = sum.compactMap { k, v -> (String, Double)? in
            let avg = v / n
            let big = k == "Exposure2012" ? abs(avg) >= 0.08 : abs(avg) >= 4
            guard big else { return nil }
            return (k, avg)
        }
        .sorted { abs($0.1) > abs($1.1) }
        .prefix(6)
        .map { k, v in k + " " + (k == "Exposure2012" ? String(format: "%+.2f", v) : String(format: "%+.0f", v)) }
        guard !parts.isEmpty else { return nil }
        return "在 \(picks.count) 次盲选里, 用户选中的方案平均比没选中的: " + parts.joined(separator: ", ")
    }

    /// 照片属于哪一类 (人像 / 风光 / 其他)
    @MainActor static func scene(of item: PhotoItem) -> String {
        guard let base = item.previewBase else { return "other" }
        if item.maskCache.portraitAnalysis(for: base) != nil { return "portrait" }
        if item.maskCache.get(.sky) != nil || item.maskCache.get(.greenery) != nil { return "landscape" }
        return "other"
    }
}

struct BlindCompareSheet: View {
    @EnvironmentObject var store: Store
    @ObservedObject var item: PhotoItem
    @Binding var isPresented: Bool
    let plans: [PhotoPlan]

    @State private var images: [UUID: NSImage] = [:]
    @State private var champion = 0          // 目前胜出的方案 (下标)
    @State private var challenger = 1
    @State private var leftIsChampion = Bool.random()
    @State private var scene = "other"

    var body: some View {
        VStack(spacing: 14) {
            Text("哪一张更好？").font(.title3.weight(.semibold))
            Text("两个方案随机放在左右，不告诉你是哪个。点更好的那张（也可以按 ← →）。").font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                side(leftIsChampion ? champion : challenger, key: "←")
                side(leftIsChampion ? challenger : champion, key: "→")
            }
            .frame(minHeight: 380)
            HStack {
                Text("第 \(String(challenger)) / \(String(max(1, plans.count - 1))) 组").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("差不多，跳过") { next(winner: nil) }
                Button("取消") { isPresented = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 960, height: 560)
        .background(Color(white: 0.13)).environment(\.colorScheme, .dark)
        .task { await renderAll() }
    }

    @ViewBuilder func side(_ i: Int, key: String) -> some View {
        Button { next(winner: i) } label: {
            ZStack {
                Color.black.opacity(0.25)
                if let img = images[plans[i].id] {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .bottom) {
                Text(verbatim: key).font(.caption.bold()).padding(6).background(.black.opacity(0.5), in: Capsule()).padding(8)
            }
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key == "←" ? KeyEquivalent.leftArrow : KeyEquivalent.rightArrow, modifiers: [])
    }

    func next(winner: Int?) {
        let loser = winner == champion ? challenger : champion
        if let winner {
            StylePicks.record(.init(scene: scene, winner: merged(plans[winner]), loser: merged(plans[loser])))
            champion = winner
        }
        if challenger + 1 < plans.count {
            challenger += 1
            if challenger == champion { challenger += 1 }
            if challenger >= plans.count { finish(); return }
            leftIsChampion = Bool.random()
        } else {
            finish()
        }
    }

    func finish() {
        store.applyPlan(plans[champion], to: item)
        store.status = String(localized: "盲选结果：\(plans[champion].name)（已记下你的选择）")
        isPresented = false
    }

    /// 方案的完整参数 (在当前参数上叠加方案的改动)
    func merged(_ p: PhotoPlan) -> Settings {
        var s = item.settings
        for (k, v) in p.settings { s[k] = v }
        return s
    }

    func renderAll() async {
        guard let base = item.previewBase else { return }
        scene = StylePicks.scene(of: item)
        let cache = item.maskCache, patches = item.patches
        for p in plans {
            let s = merged(p)
            let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                let r = Renderer.shared
                return r.makeNSImage(r.renderEdited(r.scale(base, maxSide: 1100), settings: s, patches: patches, locals: p.locals, portrait: p.portrait, cache: cache))
            }.value
            if let img { images[p.id] = img }
        }
    }
}
