import AppKit
import CoreImage

/// 连接的修图软件
enum EditorApp: String, CaseIterable, Identifiable {
    case lightroom = "Lightroom Classic"
    case photoshop = "Photoshop"
    case luminar = "Luminar Neo"
    var id: String { rawValue }

    var bundleIds: [String] {
        switch self {
        case .lightroom: return ["com.adobe.LightroomClassicCC7"]
        case .photoshop: return ["com.adobe.Photoshop"]
        case .luminar: return ["com.skylum.luminarneo", "com.skylum.LuminarNeo", "com.skylum.luminar-neo", "com.skylum.luminarneo.mas"]
        }
    }

    var nameHint: String {
        switch self {
        case .lightroom: return "Lightroom Classic"
        case .photoshop: return "Adobe Photoshop"
        case .luminar: return "Luminar Neo"
        }
    }

    /// 找到这台电脑上安装的 App (找不到返回 nil)
    var url: URL? {
        for id in bundleIds {
            if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return u }
        }
        // 按名字找 (Photoshop 的文件夹带年份, 例如 Adobe Photoshop 2026)
        let fm = FileManager.default
        for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.localizedCaseInsensitiveContains(nameHint) {
                let path = (dir as NSString).appendingPathComponent(item)
                if item.hasSuffix(".app") { return URL(fileURLWithPath: path) }
                if let inner = try? fm.contentsOfDirectory(atPath: path),
                   let app = inner.first(where: { $0.hasSuffix(".app") && $0.localizedCaseInsensitiveContains(nameHint.components(separatedBy: " ").last ?? "") }) {
                    return URL(fileURLWithPath: (path as NSString).appendingPathComponent(app))
                }
            }
        }
        return nil
    }

    var installed: Bool { url != nil }
}

enum Integrations {
    static var baseFolder: URL {
        AppPaths.exports
    }

    static func stampFolder(_ name: String) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        let u = baseFolder.appendingPathComponent(name).appendingPathComponent(f.string(from: Date()))
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func open(_ files: [URL], with app: EditorApp) -> Bool {
        guard let appURL = app.url, !files.isEmpty else { return false }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open(files, withApplicationAt: appURL, configuration: cfg)
        return true
    }

    // MARK: Luminar Neo: 全尺寸 16 位 TIFF

    static func renderTIFF(_ job: Exporter.Job, to folder: URL) -> (URL?, String?) {
        let r = Renderer.shared
        guard var img = r.loadFull(job.url) else { return (nil, String(localized: "无法读取 \(job.url.lastPathComponent)")) }
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        let out = r.renderEdited(img, settings: job.settings, patches: job.patches, locals: job.locals)
        let dest = Exporter.uniqueURL(folder, job.url.deletingPathExtension().lastPathComponent + ".tif")
        do {
            try r.context.writeTIFFRepresentation(of: out, to: dest, format: .RGBA16, colorSpace: r.sRGB, options: [:])
        } catch {
            return (nil, String(localized: "写入失败：\(error.localizedDescription)"))
        }
        if FileManager.default.fileExists(atPath: Exporter.exiftool) {
            Exporter.shell(Exporter.exiftool, ["-q", "-q", "-overwrite_original", "-tagsfromfile", job.url.path, "-all:all", "-unsafe",
                                               "-Orientation#=1", "-ThumbnailImage=", "-PreviewImage="] + Exporter.metadataArgs(job) + [dest.path])
        }
        return (dest, nil)
    }

    // MARK: LUT (.cube)

    /// 只包含颜色/色调的参数 (清晰度、纹理、暗角、颗粒这类和位置有关的效果放不进 LUT)
    static let lutKeysExcluded: Set<String> = ["Clarity2012", "Texture", "PostCropVignetteAmount", "GrainAmount"]

    /// 把一组参数做成 33×33×33 的 3D LUT
    static func cube(for settings: Settings, title: String, size n: Int = 33) -> String? {
        let s = settings.filter { !lutKeysExcluded.contains($0.key) }
        let r = Renderer.shared
        // 一张 n*n × n 的图, 每个像素是网格上的一个颜色 (sRGB 编码)
        let w = n * n, h = n
        var px = [Float](repeating: 1, count: w * h * 4)
        for b in 0..<n {
            for g in 0..<n {
                for rr in 0..<n {
                    let x = g * n + rr, y = b
                    let i = (y * w + x) * 4
                    px[i] = Float(rr) / Float(n - 1); px[i + 1] = Float(g) / Float(n - 1); px[i + 2] = Float(b) / Float(n - 1)
                }
            }
        }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        let input = CIImage(bitmapData: data, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: r.sRGB)
        let output = r.apply(s, to: input)
        var outPx = [Float](repeating: 0, count: w * h * 4)
        r.context.render(output, toBitmap: &outPx, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: r.sRGB)
        var lines = ["TITLE \"\(title.replacingOccurrences(of: "\"", with: "'"))\"", "# Toolula AI", "LUT_3D_SIZE \(n)",
                     "DOMAIN_MIN 0.0 0.0 0.0", "DOMAIN_MAX 1.0 1.0 1.0"]
        lines.reserveCapacity(n * n * n + 6)
        // .cube 顺序: 红色变化最快, 然后绿, 然后蓝
        // 输入和输出用同一种行顺序, 第 b 行就是蓝色第 b 档
        for b in 0..<n {
            for g in 0..<n {
                for rr in 0..<n {
                    let x = g * n + rr, row = b
                    let i = (row * w + x) * 4
                    func c(_ v: Float) -> String { String(format: "%.6f", min(1, max(0, v))) }
                    lines.append("\(c(outPx[i])) \(c(outPx[i + 1])) \(c(outPx[i + 2]))")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func saveLUT(_ settings: Settings, name: String) -> (URL?, String?) {
        let dir = baseFolder.appendingPathComponent("LUTs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let dest = Exporter.uniqueURL(dir, safe + ".cube")
        guard let text = cube(for: settings, title: name) else { return (nil, String(localized: "生成 LUT 失败")) }
        do { try text.write(to: dest, atomically: true, encoding: .utf8) } catch { return (nil, error.localizedDescription) }
        return (dest, nil)
    }
}

// MARK: - 修图页的操作

extension Store {
    func sendToPhotoshop() {
        let items = selectedItems
        guard !items.isEmpty, !working else { return }
        guard EditorApp.photoshop.installed else { alert = String(localized: "没有找到 Photoshop。安装后这里会自动连接。"); return }
        let jobs = self.jobs(items)
        recordForLearning(items)
        let folder = Integrations.stampFolder("Photoshop")
        working = true
        Task {
            var outs: [URL] = [], errors: [String] = []
            for (i, job) in jobs.enumerated() {
                status = String(localized: "准备发送到 Photoshop \(i + 1)/\(jobs.count)")
                let (u, e) = await Task.detached { Exporter.prepareForLightroom(job, folder: folder) }.value
                if let u { outs.append(u) }
                if let e { errors.append(e) }
            }
            working = false
            if Integrations.open(outs, with: .photoshop) {
                status = String(localized: "已发送 \(outs.count) 张到 Photoshop（会在 Camera Raw 里打开，AI 的参数已经填好）")
            }
            if !errors.isEmpty { alert = errors.joined(separator: "\n") }
        }
    }

    func sendToLuminar() {
        let items = selectedItems
        guard !items.isEmpty, !working else { return }
        guard EditorApp.luminar.installed else { alert = String(localized: "没有找到 Luminar Neo。安装后这里会自动连接。"); return }
        let jobs = self.jobs(items)
        recordForLearning(items)
        let folder = Integrations.stampFolder("Luminar Neo")
        working = true
        Task {
            var outs: [URL] = [], errors: [String] = []
            for (i, job) in jobs.enumerated() {
                status = String(localized: "准备发送到 Luminar Neo \(i + 1)/\(jobs.count)（16 位 TIFF）")
                let (u, e) = await Task.detached { Integrations.renderTIFF(job, to: folder) }.value
                if let u { outs.append(u) }
                if let e { errors.append(e) }
            }
            working = false
            if Integrations.open(outs, with: .luminar) {
                status = String(localized: "已发送 \(outs.count) 张到 Luminar Neo（已带上 AI 的调色）")
            }
            if !errors.isEmpty { alert = errors.joined(separator: "\n") }
        }
    }

    func exportLUT() {
        guard let item = current else { return }
        let name = "Toolula " + (item.url.deletingPathExtension().lastPathComponent)
        let settings = item.settings
        Task {
            let (u, e) = await Task.detached { Integrations.saveLUT(settings, name: name) }.value
            if let u {
                status = String(localized: "LUT 已保存：\(u.lastPathComponent)")
                alert = String(localized: "LUT 已保存到「图片/Toolula AI/LUTs」。\n\n• Photoshop：图层 → 新建调整图层 → 颜色查找 → 载入 3D LUT\n• Luminar Neo：编辑 → LUT 映射 → 载入自定义 LUT\n\n清晰度、纹理、暗角、颗粒这类效果放不进 LUT。")
                NSWorkspace.shared.activateFileViewerSelecting([u])
            } else {
                alert = e
            }
        }
    }

    /// 存成 Camera Raw 预设: Lightroom Classic 和 Photoshop 共用同一个预设文件夹
    func savePresetForAdobe() {
        guard let item = current else { return }
        let a = NSAlert()
        a.messageText = String(localized: "存成 Lightroom / Photoshop 预设")
        a.informativeText = String(localized: "预设会出现在 Lightroom「修改照片 → 预设」和 Photoshop「Camera Raw → 预设」里（Toolula AI 修图 分组）。")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = "Toolula " + DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
        a.accessoryView = field
        a.addButton(withTitle: String(localized: "保存"))
        a.addButton(withTitle: String(localized: "取消"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        let settings = AIBridge.numeric(item.settings)
        Task {
            let r = await Task.detached { AIBridge.run("preset", request: ["name": name, "settings": settings]) }.value
            if let e = r.error { alert = e } else {
                status = String(localized: "已存成预设「\(name)」（重启 Lightroom / Photoshop 后可见）")
            }
        }
    }
}

extension Store {
    /// 给 AI 工具用: 把刚修好的照片发送到指定软件
    func sendEdited(urls: [URL], to target: String) async -> String {
        let app: EditorApp
        switch target {
        case "lightroom": app = .lightroom
        case "photoshop": app = .photoshop
        case "luminar": app = .luminar
        default: return ""
        }
        guard app.installed else { return String(localized: "没有安装 \(app.rawValue)，没有发送。") }
        var expanded: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                expanded += (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []
            } else { expanded.append(u) }
        }
        let wanted = Set(expanded.map { $0.standardizedFileURL })
        let items = photos.filter { wanted.contains($0.url.standardizedFileURL) && $0.ai != nil }
        guard !items.isEmpty else { return String(localized: "没有修好的照片可以发送") }
        let jobs = self.jobs(items)
        let folder = Integrations.stampFolder(app.rawValue)
        var outs: [URL] = []
        for job in jobs {
            let r: (URL?, String?) = await Task.detached {
                app == .luminar ? Integrations.renderTIFF(job, to: folder) : Exporter.prepareForLightroom(job, folder: folder)
            }.value
            if let u = r.0 { outs.append(u) }
        }
        _ = Integrations.open(outs, with: app)
        return String(localized: "已发送 \(outs.count) 张到 \(app.rawValue)")
    }
}

/// 自动配置 Lightroom: App 里带着 Lightroom 插件, 启动时如果 Lightroom 装了就自动安装/更新
enum LightroomSetup {
    static var modulesDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Adobe/Lightroom/Modules")
    }

    /// 返回: nil = 不需要/没装 Lightroom, true = 已安装或更新, false = 失败
    @discardableResult
    static func syncPlugin() -> Bool? {
        guard EditorApp.lightroom.installed,
              let bundled = Bundle.main.url(forResource: "AIPhotoEdit", withExtension: "lrplugin") else { return nil }
        let fm = FileManager.default
        let dest = modulesDir.appendingPathComponent("AIPhotoEdit.lrplugin")
        let files = (try? fm.contentsOfDirectory(atPath: bundled.path)) ?? []
        let same = files.allSatisfy { f in
            fm.contentsEqual(atPath: bundled.appendingPathComponent(f).path, andPath: dest.appendingPathComponent(f).path)
        }
        if same && !files.isEmpty { return nil }
        do {
            try fm.createDirectory(at: modulesDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: bundled, to: dest)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - 「发送到」按钮

extension EditorApp {
    /// App 图标 (没装就用系统的通用图标, 显示成灰色)
    var icon: NSImage {
        let img: NSImage
        if let u = url { img = NSWorkspace.shared.icon(forFile: u.path) }
        else { img = NSWorkspace.shared.icon(for: .application) }
        img.size = NSSize(width: 18, height: 18)
        return img
    }

    var menuTitle: LocalizedStringKey {
        switch self {
        case .lightroom: return installed ? "Lightroom Classic（可调参数）" : "Lightroom Classic（未安装）"
        case .photoshop: return installed ? "Photoshop（Camera Raw，可调参数）" : "Photoshop（未安装）"
        case .luminar: return installed ? "Luminar Neo（调好色的 16 位 TIFF）" : "Luminar Neo（未安装）"
        }
    }

    var shortName: String {
        switch self {
        case .lightroom: return "Lightroom"
        case .photoshop: return "Photoshop"
        case .luminar: return "Luminar Neo"
        }
    }

    var downloadURL: URL {
        switch self {
        case .lightroom: return URL(string: "https://www.adobe.com/products/photoshop-lightroom-classic.html")!
        case .photoshop: return URL(string: "https://www.adobe.com/products/photoshop.html")!
        case .luminar: return URL(string: "https://skylum.com/luminar")!
        }
    }
}

extension Store {
    func send(to app: EditorApp) {
        switch app {
        case .lightroom: sendToLightroom()
        case .photoshop: sendToPhotoshop()
        case .luminar: sendToLuminar()
        }
    }
}

import SwiftUI

/// 修图页右边的「发送到」三个按钮
struct SendToBar: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("发送到其他软件继续编辑").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(EditorApp.allCases) { app in
                    Button {
                        if app.installed { store.send(to: app) } else { NSWorkspace.shared.open(app.downloadURL) }
                    } label: {
                        VStack(spacing: 4) {
                            Image(nsImage: app.icon).resizable().frame(width: 28, height: 28)
                                .opacity(app.installed ? 1 : 0.35)
                            Text(app.shortName).font(.caption2).lineLimit(1)
                            if !app.installed { Text("未安装").font(.system(size: 9)).foregroundStyle(.tertiary) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 62)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .disabled(app.installed && (store.selection.isEmpty || store.working))
                    .help(app.installed ? Text(app.menuTitle) : Text("还没安装，点一下打开官网"))
                }
            }
        }
    }
}
