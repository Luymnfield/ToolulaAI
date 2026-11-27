import CoreGraphics
import Foundation
import SwiftUI

/// 一个磁盘 (系统盘 / 外接硬盘)
struct DiskInfo: Identifiable, Hashable {
    let id: String          // 挂载路径
    let name: String
    let total: Int64
    let free: Int64
    let isSystem: Bool
    let isInternal: Bool
    var used: Int64 { max(0, total - free) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

/// 自动检测当前电脑: 型号、芯片 (Apple 芯片或 Intel)、内存、CPU/GPU、所有磁盘; 实时更新内存和磁盘占用
@MainActor
final class SystemInfo: ObservableObject {
    static let shared = SystemInfo()
    /// 自测截图用 (--demo-mac): 显示成 MacBook Pro 16 英寸 M4 Max 128 GB / 2 TB, 做产品介绍图
    nonisolated(unsafe) static var demoMac = false
    private func applyDemoMac() {
        machine = String(localized: "\("MacBook Pro") \("16") 英寸")
        modelId = "Mac16,5"
        chip = "Apple M4 Max"
        memory = "128 GB"
        cores = String(localized: "\(16) 核 CPU") + String(localized: "（\(12) 性能 + \(4) 能效）")
        gpuCores = String(localized: "\("40") 核 GPU")
        totalGB = 128
        usedGB = 26
        disks = [DiskInfo(id: "/", name: "Macintosh HD", total: 2_000_000_000_000, free: 1_480_000_000_000, isSystem: true, isInternal: true)]
        SystemInfoSnapshot.text = promptText
    }

    @Published var machine = "Mac"
    @Published var chip = ""
    @Published var memory = ""
    @Published var modelId = ""
    @Published var cores = ""
    @Published var gpuCores = ""
    @Published var usedGB: Double = 0
    @Published var totalGB: Double = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    @Published var disks: [DiskInfo] = []

    var summary: String { [machine, chip, memory].filter { !$0.isEmpty }.joined(separator: " · ") }
    var systemDisk: DiskInfo? { disks.first { $0.isSystem } ?? disks.first }

    /// 给 AI 的一句话描述
    var promptText: String {
        var s = summary
        if !cores.isEmpty { s += " · " + cores }
        if !gpuCores.isEmpty { s += " · " + gpuCores }
        for d in disks {
            s += "；磁盘「\(d.name)」\(d.isSystem ? "(系统盘)" : "") 共 \(Self.size(d.total))，可用 \(Self.size(d.free))"
        }
        return s
    }

    /// 内置屏幕尺寸 (英寸): 13.6"→13, 14.2"→14, 15.3"→15, 16.2"→16, iMac 23.5"→24.
    /// 合盖接外接显示器时内置屏不在线, 用上次记住的值
    nonisolated static func builtInScreenInches(isLaptop: Bool) -> String? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        for d in ids.prefix(Int(n)) where CGDisplayIsBuiltin(d) != 0 {
            let s = CGDisplayScreenSize(d)  // 毫米
            let diag = (s.width * s.width + s.height * s.height).squareRoot() / 25.4
            guard diag > 5 else { continue }
            let v = isLaptop ? Int((diag + 0.2).rounded(.down)) : Int(diag.rounded())
            UserDefaults.standard.set(v, forKey: "builtInScreenInches")
            return "\(v)"
        }
        let saved = UserDefaults.standard.integer(forKey: "builtInScreenInches")
        return saved > 0 ? "\(saved)" : nil
    }

    nonisolated static func size(_ bytes: Int64) -> String {
        // 和访达一样用十进制 (1 TB = 1000 GB)
        let gb = Double(bytes) / 1e9
        if gb >= 1000 { return String(format: "%.2f TB", gb / 1000) }
        return String(format: "%.0f GB", gb)
    }

    private var timer: Timer?
    private var tick = 0

    func start() {
        Task.detached {
            let (code, out) = Exporter.shell("/usr/sbin/system_profiler", ["SPHardwareDataType", "SPDisplaysDataType", "-json"])
            guard code == 0, let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else { return }
            let hw = (obj["SPHardwareDataType"] as? [[String: Any]])?.first ?? [:]
            let gpus = (obj["SPDisplaysDataType"] as? [[String: Any]]) ?? []

            // 芯片: Apple 芯片有 chip_type; Intel Mac 用 cpu_type + 主频
            var chip = hw["chip_type"] as? String ?? ""
            if chip.isEmpty, let cpu = hw["cpu_type"] as? String {
                chip = cpu
                if let speed = hw["current_processor_speed"] as? String { chip += " \(speed)" }
            }
            // CPU 核心: Apple 芯片是 "proc 14:10:4", Intel 是数字
            var coreText = ""
            if let s = hw["number_processors"] as? String {
                let parts = s.replacingOccurrences(of: "proc ", with: "").split(separator: ":").compactMap { Int($0) }
                if let total = parts.first {
                    coreText = String(localized: "\(total) 核 CPU")
                    if parts.count >= 3 { coreText += String(localized: "（\(parts[parts.count - 2]) 性能 + \(parts[parts.count - 1]) 能效）") }
                }
            } else if let n = hw["number_processors"] as? Int {
                coreText = String(localized: "\(n) 核 CPU")
            }
            // GPU: Apple 芯片显示核心数; 独立显卡显示型号
            let gpuText = gpus.compactMap { g -> String? in
                if let c = g["sppci_cores"] as? String { return String(localized: "\(c) 核 GPU") }
                return g["sppci_model"] as? String
            }.joined(separator: " + ")

            let name = hw["machine_name"] as? String ?? "Mac"
            let inches = SystemInfo.builtInScreenInches(isLaptop: name.contains("Book"))
            let modelId = hw["machine_model"] as? String ?? ""
            await MainActor.run {
                self.machine = inches.map { String(localized: "\(name) \($0) 英寸") } ?? name
                self.modelId = modelId
                self.chip = chip
                self.memory = hw["physical_memory"] as? String ?? String(format: "%.0f GB", self.totalGB)
                self.cores = coreText
                self.gpuCores = gpuText
                SystemInfoSnapshot.text = self.promptText
                if SystemInfo.demoMac { self.applyDemoMac() }
            }
        }
        updateMemory()
        updateDisks()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in
                let s = SystemInfo.shared
                s.updateMemory()
                s.tick += 1
                if s.tick % 10 == 0 { s.updateDisks() }  // 磁盘每 30 秒刷新 (也能发现新插的硬盘)
            }
        }
    }

    func updateMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS, !SystemInfo.demoMac else { return }
        let page = Double(vm_kernel_page_size)
        let used = (Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        usedGB = used / 1_073_741_824
    }

    func updateDisks() {
        if SystemInfo.demoMac { applyDemoMac(); return }
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var list: [DiskInfo] = []
        for u in urls {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false,
                  let total = v.volumeTotalCapacity, total > 2_000_000_000 else { continue }
            let isRoot = v.volumeIsRootFileSystem ?? (u.path == "/")
            // 系统盘用"重要用途可用空间" (包含可清除空间, 和访达显示一致)
            let free = isRoot ? (v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0))
                              : Int64(v.volumeAvailableCapacity ?? 0)
            list.append(DiskInfo(id: u.path, name: v.volumeName ?? u.lastPathComponent, total: Int64(total), free: free,
                                 isSystem: isRoot, isInternal: v.volumeIsInternal ?? isRoot))
        }
        disks = list.sorted { ($0.isSystem ? 0 : 1, $0.name) < ($1.isSystem ? 0 : 1, $1.name) }
        if !chip.isEmpty { SystemInfoSnapshot.text = promptText }
    }
}

// MARK: - 显示

struct UsageBar: View {
    let fraction: Double
    var height: CGFloat? = nil     // 设了就画成圆角粗条（主页大卡片用）
    var color: Color { fraction > 0.9 ? .red : fraction > 0.75 ? .orange : .green }
    var body: some View {
        if let h = height {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(color).frame(width: g.size.width * min(1, max(0, fraction)))
                }
            }
            .frame(height: h)
        } else {
            ProgressView(value: min(1, max(0, fraction))).tint(color)
        }
    }
}

/// 电脑信息卡片 (compact = 左侧窄栏用)
struct MachineBadge: View {
    @ObservedObject var info = SystemInfo.shared
    var compact = false
    var large = false      // 主页右上角的大卡片

    var body: some View {
        if compact { compactBody } else { fullBody }
    }

    var compactBody: some View {
        VStack(spacing: 3) {
            Image(systemName: info.machine.contains("Book") ? "laptopcomputer" : "desktopcomputer").foregroundStyle(.secondary)
            Text(info.chip.replacingOccurrences(of: "Apple ", with: "")).font(.caption2.bold()).lineLimit(1).minimumScaleFactor(0.6)
            Text(info.memory).font(.caption2).foregroundStyle(.secondary)
            UsageBar(fraction: info.usedGB / max(info.totalGB, 1))
            Text("内存 \(Int(info.usedGB.rounded())) GB").font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
            if let d = info.systemDisk {
                UsageBar(fraction: d.usedFraction).padding(.top, 3)
                Text("硬盘剩 \(SystemInfo.size(d.free))").font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .help(helpText)
    }

    var fullBody: some View {
        VStack(alignment: .leading, spacing: large ? 12 : 6) {
            HStack(spacing: large ? 10 : 6) {
                Image(systemName: info.machine.contains("Book") ? "laptopcomputer" : "desktopcomputer")
                    .font(large ? .title2 : .body).foregroundStyle(.secondary)
                Text(info.summary).font(large ? .headline : .caption.bold()).lineLimit(1).minimumScaleFactor(0.8)
            }
            if !info.cores.isEmpty || !info.gpuCores.isEmpty {
                Text([info.cores, info.gpuCores].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(large ? .callout : .caption2).foregroundStyle(.secondary)
            }
            row(icon: "memorychip", title: String(localized: "内存"), detail: String(localized: "已用 \(Int(info.usedGB.rounded())) / \(Int(info.totalGB.rounded())) GB"),
                fraction: info.usedGB / max(info.totalGB, 1))
            ForEach(info.disks) { d in
                row(icon: d.isInternal ? "internaldrive" : "externaldrive",
                    title: d.isSystem ? String(localized: "硬盘（\(d.name)）") : d.name,
                    detail: String(localized: "可用 \(SystemInfo.size(d.free)) / 共 \(SystemInfo.size(d.total))"),
                    fraction: d.usedFraction)
            }
        }
        .help(helpText)
    }

    func row(icon: String, title: String, detail: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: large ? 6 : 2) {
            HStack {
                Label(title, systemImage: icon).font(large ? .body : .caption2)
                Spacer()
                Text(detail).font(large ? .callout : .caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            UsageBar(fraction: fraction, height: large ? 8 : nil)
        }
    }

    var helpText: String {
        var s = "\(info.summary) (\(info.modelId))\n\(info.cores) \(info.gpuCores)\n" + String(localized: "内存已用 \(Int(info.usedGB)) / \(Int(info.totalGB)) GB")
        for d in info.disks { s += "\n\(d.name): " + String(localized: "可用 \(SystemInfo.size(d.free)) / 共 \(SystemInfo.size(d.total))") }
        return s
    }
}
