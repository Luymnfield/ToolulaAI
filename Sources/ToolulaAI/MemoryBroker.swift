import AppKit
import SwiftUI

/// 统一调度内存: 对话模型 (LM Studio / MTP 引擎 / 内置引擎) 和 ComfyUI 里的绘图、视频模型共用一份内存。
///
/// 规则:
/// - 要加载新模型时先算一下: 剩余内存够就什么都不卸 (96 GB 的 Mac 上, 对话模型和绘图模型可以同时留在内存里, 来回切换不用等);
/// - 不够时按「最久没用」的顺序请别的模型让位, 直到够为止;
/// - 正在工作的 (正在回答、正在生成) 绝不卸载;
/// - 给系统和其他程序留 `reserveGB`。
@MainActor
final class MemoryBroker: ObservableObject {
    static let shared = MemoryBroker()

    enum Tenant: Hashable {
        case lmstudio(String)   // LM Studio 里加载的模型 (id)
        case mlx                // MTP 加速引擎
        case builtin            // 内置 llama.cpp 引擎
        case comfy              // ComfyUI 里加载的绘图 / 视频模型

        /// 对话模型 id 对应谁
        static func forModel(_ id: String) -> Tenant? {
            if id.hasPrefix("cloud:") { return nil }
            if id.hasPrefix("mlx:") { return .mlx }
            if id.hasPrefix("builtin:") { return .builtin }
            return .lmstudio(id)
        }
    }

    struct Resident: Identifiable, Equatable {
        let tenant: Tenant
        let name: String
        let gb: Double
        let lastUsed: Date?
        let busy: Bool
        var id: String { "\(tenant)" }
        var kind: String {
            switch tenant {
            case .lmstudio: return String(localized: "对话模型 · LM Studio")
            case .mlx: return String(localized: "对话模型 · MTP 加速引擎")
            case .builtin: return String(localized: "对话模型 · 内置引擎")
            case .comfy: return String(localized: "绘图 / 视频模型 · ComfyUI")
            }
        }
    }

    /// 给系统和其他程序留的内存
    var reserveGB: Double { max(6, SystemInfo.shared.totalGB * 0.08) }

    @Published private(set) var residents: [Resident] = []
    @Published private(set) var lastEvent: String?
    private var lastUsed: [Tenant: Date] = [:]
    private var busyCount: [Tenant: Int] = [:]
    private var lmsSizes: [String: Double] = [:]       // LM Studio 模型 id -> GB (来自 lms ls --json)
    private var sizesLoaded: Date?

    // MARK: 使用记录

    func touch(_ t: Tenant) { lastUsed[t] = Date() }

    /// 在 body 执行期间把 t 标记为「正在用」, 不会被请去让位
    func using<T>(_ t: Tenant?, _ body: () async throws -> T) async rethrows -> T {
        guard let t else { return try await body() }
        busyCount[t, default: 0] += 1
        touch(t)
        defer { busyCount[t, default: 1] -= 1; touch(t) }
        return try await body()
    }

    /// 给不在主线程上的调用方用 (LLMClient.stream): 开始 / 结束使用
    func begin(_ t: Tenant) { busyCount[t, default: 0] += 1; touch(t) }
    func end(_ t: Tenant) { busyCount[t, default: 1] -= 1; touch(t) }

    func isBusy(_ t: Tenant) -> Bool {
        if (busyCount[t] ?? 0) > 0 { return true }
        // "qwen/qwen3.8-27b:2" 和 "qwen/qwen3.8-27b" 是同一个模型的两个实例
        if case .lmstudio(let id) = t, let base = Self.baseId(id), (busyCount[.lmstudio(base)] ?? 0) > 0 { return true }
        if t == .comfy { return ImageStore.shared.running || VideoStore.shared.running || ComfyWarmup.isWarming }
        return false
    }

    // MARK: 现在谁在内存里

    func refresh() async {
        await loadSizes()
        var list: [Resident] = []
        let mm = ModelManager.shared
        // LM Studio: 以 lms ps 为准 (用户自己在 LM Studio 里加载的也算; 同一个模型可能有 ":2" 这样的第二个实例)
        for m in await Self.lmsInstances() {
            let t = Tenant.lmstudio(m.identifier)
            list.append(Resident(tenant: t, name: mm.model(m.modelKey)?.displayName ?? m.identifier, gb: m.gb * 1.1 + 1,
                                 lastUsed: lastUsed[t] ?? lastUsed[.lmstudio(m.modelKey)], busy: isBusy(t) || isBusy(.lmstudio(m.modelKey))))
        }
        let mlx = MLXEngine.shared
        if mlx.online, let target = mlx.loadedTarget {
            let gb = Self.folderGB(target) * 1.1 + 2
            list.append(Resident(tenant: .mlx, name: (target as NSString).lastPathComponent + " ⚡MTP", gb: gb, lastUsed: lastUsed[.mlx], busy: isBusy(.mlx)))
        }
        if BuiltinEngine.shared.online {
            let name = UserDefaults.standard.string(forKey: "chatModel").flatMap { $0.hasPrefix("builtin:") ? String($0.dropFirst(8)) : nil } ?? String(localized: "内置模型")
            list.append(Resident(tenant: .builtin, name: name, gb: Self.folderGB(EnginePaths.models.appendingPathComponent(name).path) * 1.1 + 1,
                                 lastUsed: lastUsed[.builtin], busy: isBusy(.builtin)))
        }
        if let c = comfyResident() { list.append(c) }
        residents = list.sorted { $0.gb > $1.gb }
    }

    private func comfyResident() -> Resident? {
        guard ComfyEngine.shared.online else { return nil }
        var name: String?, gb = 0.0
        if let id = ImageStore.shared.loadedId, let s = ImageModelSpec.all.first(where: { $0.id == id }) {
            name = s.name; gb = s.files.reduce(0) { $0 + $1.sizeGB } * 1.15
        }
        if let id = VideoStore.shared.loadedId, let s = VideoModelSpec.all.first(where: { $0.id == id }) {
            name = [name, s.name].compactMap { $0 }.joined(separator: " + ")
            gb += s.files.filter { !$0.optional }.reduce(0) { $0 + $1.sizeGB } * 1.15
        }
        guard let name, gb > 0 else { return nil }
        return Resident(tenant: .comfy, name: name, gb: gb, lastUsed: lastUsed[.comfy], busy: isBusy(.comfy))
    }

    /// 现在还能放多少 GB (不卸载任何东西)
    var availableGB: Double { SystemInfo.shared.totalGB - SystemInfo.shared.usedGB - reserveGB }

    func fits(_ gb: Double) -> Bool { SystemInfo.shared.updateMemory(); return gb <= availableGB }

    // MARK: 腾地方

    /// 要加载 `gb` 大小的东西给 `requester` 用: 不够就按最久没用的顺序请别人让位。返回最后是否够
    @discardableResult
    func makeRoom(_ gb: Double, for requester: Tenant, protect: Set<Tenant> = []) async -> Bool {
        SystemInfo.shared.updateMemory()
        var free = availableGB
        guard gb > free else { return true }
        await refresh()
        let candidates = residents
            .filter { $0.tenant != requester && !protect.contains($0.tenant) && !$0.busy }
            .sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        var freed: [String] = []
        for r in candidates where gb > free {
            await evict(r.tenant)
            free += r.gb
            freed.append(r.name)
        }
        if !freed.isEmpty {
            // 等系统把内存真的收回来
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(500))
                SystemInfo.shared.updateMemory()
                if availableGB >= gb { break }
            }
            lastEvent = String(localized: "为了腾出 \(Int(gb.rounded())) GB，让 \(freed.joined(separator: "、")) 先让出了内存")
            Run.appendLog("[内存调度] \(lastEvent!)\n")
            await refresh()
        }
        SystemInfo.shared.updateMemory()
        return availableGB >= gb * 0.9
    }

    /// 请某个模型让出内存
    func evict(_ t: Tenant) async {
        switch t {
        case .lmstudio(let id):
            let lms = ModelManager.lms
            if FileManager.default.fileExists(atPath: lms) { _ = await Task.detached { Exporter.shell(lms, ["unload", id]) }.value }
        case .mlx: MLXEngine.shared.stop()
        case .builtin: BuiltinEngine.shared.stop()
        case .comfy:
            await ComfyEngine.shared.free()
            ImageStore.shared.modelsUnloaded()
            VideoStore.shared.modelsUnloaded()
        }
        lastUsed[t] = nil
    }

    // MARK: 对话模型要用之前

    /// 对话模型 (LM Studio 按需加载 / MTP / 内置) 要用之前: 还没在内存里就先腾地方
    func prepareChat(_ id: String) async {
        guard let t = Tenant.forModel(id) else { return }
        touch(t)
        switch t {
        case .lmstudio(let mid):
            if ModelManager.shared.model(mid)?.loaded == true { return }
            if await Self.lmsInstances().contains(where: { $0.modelKey == mid || $0.identifier == mid }) { return }
            await loadSizes()
            await makeRoom((lmsSizes[mid] ?? 8) * 1.1 + 1, for: t)
        case .mlx:
            if MLXEngine.shared.online { return }
            if let p = MTPPair.pair(for: id), let target = p.target { await makeRoom(Self.folderGB(target.path) * 1.1 + 2, for: t) }
        case .builtin:
            if BuiltinEngine.shared.online { return }
            await makeRoom(8, for: t)
        case .comfy: break
        }
    }

    // MARK: 工具

    private func loadSizes() async {
        if let d = sizesLoaded, Date().timeIntervalSince(d) < 300 { return }
        let lms = ModelManager.lms
        guard FileManager.default.fileExists(atPath: lms) else { return }
        let out = await Task.detached { Exporter.shell(lms, ["ls", "--json"]).1 }.value
        if let arr = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]] {
            for m in arr {
                let gb = Double(m["sizeBytes"] as? Int64 ?? Int64(m["sizeBytes"] as? Int ?? 0)) / 1_073_741_824
                for k in ["modelKey", "indexedModelIdentifier", "path"] { if let key = m[k] as? String { lmsSizes[key] = gb } }
            }
            sizesLoaded = Date()
        }
    }

    struct LMSInstance { let identifier: String; let modelKey: String; let gb: Double }

    /// LM Studio 里正在内存中的模型 (含正在加载的)
    nonisolated static func lmsInstances() async -> [LMSInstance] {
        let lms = ModelManager.lms
        guard FileManager.default.fileExists(atPath: lms) else { return [] }
        let out = await Task.detached { Exporter.shell(lms, ["ps", "--json"]).1 }.value
        guard let arr = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]] else { return [] }
        return arr.compactMap { m in
            guard let id = m["identifier"] as? String else { return nil }
            let bytes = (m["sizeBytes"] as? NSNumber)?.doubleValue ?? 0
            return LMSInstance(identifier: id, modelKey: m["modelKey"] as? String ?? id, gb: bytes / 1_073_741_824)
        }
    }

    /// "key:2" -> "key"
    nonisolated static func baseId(_ id: String) -> String? {
        guard let r = id.range(of: ":", options: .backwards), Int(id[r.upperBound...]) != nil else { return nil }
        return String(id[..<r.lowerBound])
    }

    /// 预热用: 这个对话模型已经在内存里, 或者不用请别人让位就放得下 (预热只是「可能会用到」, 不该挤掉别的模型)
    func canWarm(_ id: String) async -> Bool {
        guard let t = Tenant.forModel(id) else { return true }
        switch t {
        case .lmstudio(let mid):
            if await Self.lmsInstances().contains(where: { $0.modelKey == mid || $0.identifier == mid }) { return true }
            await loadSizes()
            return fits((lmsSizes[mid] ?? 8) * 1.1 + 1)
        case .mlx:
            if MLXEngine.shared.online { return true }
            guard let p = MTPPair.pair(for: id), let target = p.target else { return false }
            return fits(Self.folderGB(target.path) * 1.1 + 2)
        case .builtin: return BuiltinEngine.shared.online || fits(8)
        case .comfy: return true
        }
    }

    nonisolated static func folderGB(_ path: String) -> Double {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return Double((try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? 0) / 1_073_741_824 }
        var total = 0
        for case let f as String in fm.enumerator(atPath: path) ?? NSEnumerator() {
            total += (try? fm.attributesOfItem(atPath: (path as NSString).appendingPathComponent(f))[.size] as? Int) ?? 0
        }
        return Double(total) / 1_073_741_824
    }
}

// MARK: - 「内存去哪了」

struct MemoryUsageView: View {
    @ObservedObject var broker = MemoryBroker.shared
    @ObservedObject var info = SystemInfo.shared
    @State private var timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var modelsGB: Double { broker.residents.reduce(0) { $0 + $1.gb } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("内存去哪了").font(.headline)
                Spacer()
                Text("已用 \(Int(info.usedGB.rounded())) / \(Int(info.totalGB.rounded())) GB").monospacedDigit().foregroundStyle(.secondary)
            }
            // 分段条: 各个模型 + 其他程序 + 空闲
            GeometryReader { g in
                HStack(spacing: 1) {
                    ForEach(broker.residents) { r in
                        Rectangle().fill(color(r)).frame(width: max(2, g.size.width * r.gb / max(info.totalGB, 1)))
                    }
                    Rectangle().fill(Color.gray.opacity(0.45))
                        .frame(width: max(0, g.size.width * (info.usedGB - modelsGB) / max(info.totalGB, 1)))
                    Rectangle().fill(Color.gray.opacity(0.12))
                }
            }
            .frame(height: 14).clipShape(RoundedRectangle(cornerRadius: 4))
            if broker.residents.isEmpty {
                Text("现在没有 AI 模型在内存里。").foregroundStyle(.secondary)
            }
            ForEach(broker.residents) { r in
                HStack(spacing: 8) {
                    Circle().fill(color(r)).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.name).lineLimit(1)
                        Text(r.kind + (r.busy ? " · " + String(localized: "正在使用") : r.lastUsed.map { " · " + String(localized: "\($0.formatted(.relative(presentation: .named))) 用过") } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("约 \(Int(r.gb.rounded())) GB").monospacedDigit().foregroundStyle(.secondary)
                    Button("释放") { Task { await broker.evict(r.tenant); await broker.refresh() } }
                        .controlSize(.small).disabled(r.busy)
                        .accessibilityLabel(Text("释放 \(r.name)"))
                }
            }
            HStack(spacing: 6) {
                Circle().fill(Color.gray.opacity(0.45)).frame(width: 9, height: 9)
                Text("系统和其他程序").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("约 \(Int(max(0, info.usedGB - modelsGB).rounded())) GB").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Divider()
            Text("Toolula 会自动安排：内存够时对话、绘图、视频的模型同时留在内存里，切换不用重新加载；不够时让最久没用的先让位，正在工作的不会被卸载。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let e = broker.lastEvent {
                Label(e, systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 400)
        .task { await broker.refresh() }
        .onReceive(timer) { _ in Task { await broker.refresh() } }
    }

    func color(_ r: MemoryBroker.Resident) -> Color {
        switch r.tenant {
        case .lmstudio: return .blue
        case .mlx: return .purple
        case .builtin: return .teal
        case .comfy: return .orange
        }
    }
}

/// 左侧栏底部的电脑信息: 点一下看「内存去哪了」
struct MemoryBadgeButton: View {
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: { MachineBadge(compact: true).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .help(Text("点一下查看内存被哪些模型占用"))
            .accessibilityLabel(Text("内存去哪了"))
            .popover(isPresented: $show, arrowEdge: .trailing) { MemoryUsageView() }
    }
}
