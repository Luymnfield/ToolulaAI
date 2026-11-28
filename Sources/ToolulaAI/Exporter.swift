import AppKit
import CoreImage
import ImageIO

enum Exporter {
    /// exiftool 不是每台 Mac 都有 (要用 Homebrew 装); 没有时用系统自带的 ImageIO 写参数
    nonisolated(unsafe) static var simulateNoExiftool = false
    static var exiftool: String {
        if simulateNoExiftool { return "/nonexistent/exiftool" }
        return ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool"].first { FileManager.default.fileExists(atPath: $0) } ?? "/opt/homebrew/bin/exiftool"
    }
    static var hasExiftool: Bool { FileManager.default.fileExists(atPath: exiftool) }

    /// 用系统自带的 ImageIO 把 XMP (修图参数) 无损写进 JPEG / TIFF / PNG / HEIC (不重新压缩画面)
    static func embedXMP(_ xmpText: String, into file: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil), let type = CGImageSourceGetType(src),
              let meta = CGImageMetadataCreateFromXMPData(Data(xmpText.utf8) as CFData) else { return false }
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".toolula_\(UUID().uuidString.prefix(6)).\(file.pathExtension)")
        guard let dst = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else { return false }
        let opts: [CFString: Any] = [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: true]
        var err: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dst, src, opts as CFDictionary, &err) else { try? FileManager.default.removeItem(at: tmp); return false }
        do { _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp) } catch { try? FileManager.default.removeItem(at: tmp); return false }
        return true
    }

    struct Job: Sendable {
        let url: URL
        let settings: Settings
        let isRaw: Bool
        let title: String
        let caption: String
        let keywords: [String]
        let stars: Int
        var patches: [RetouchPatch] = []
        var locals: [LocalAdjustment] = []
        var portrait = PortraitRetouch()
        var retouched: Bool { !patches.isEmpty || !portrait.isEmpty || locals.contains { $0.settings.contains { $0.value != 0 } } }
        /// 有 Lightroom 参数表达不了的像素级修改 (人像精修的一部分、亮度蒙版)
        var hasPixelOnly: Bool {
            portrait.hasPixelOnly || locals.contains { Exporter.lightroomUnsupported.contains($0.area) && $0.settings.contains { $0.value != 0 } }
        }
    }

    @discardableResult
    static func shell(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func uniqueURL(_ folder: URL, _ name: String) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var u = folder.appendingPathComponent(name)
        var i = 2
        while FileManager.default.fileExists(atPath: u.path) {
            u = folder.appendingPathComponent("\(base)_\(i).\(ext)")
            i += 1
        }
        return u
    }

    static func metadataArgs(_ job: Job) -> [String] {
        var a: [String] = []
        if !job.title.isEmpty { a += ["-XMP-dc:Title=\(job.title)", "-IPTC:ObjectName=\(job.title)"] }
        if !job.caption.isEmpty { a += ["-XMP-dc:Description=\(job.caption)", "-IPTC:Caption-Abstract=\(job.caption)"] }
        for k in job.keywords { a += ["-XMP-dc:Subject+=\(k)", "-IPTC:Keywords+=\(k)"] }
        if job.stars > 0 { a += ["-XMP-xmp:Rating=\(job.stars)"] }
        if !job.keywords.isEmpty || !job.caption.isEmpty { a += ["-IPTC:CodedCharacterSet=UTF8"] }
        return a
    }

    /// 导出成 JPEG (全分辨率, 保留原片 EXIF, 写入标题/关键词)
    static func exportJPEG(_ job: Job, to folder: URL, maxSide: CGFloat?) -> String? {
        let r = Renderer.shared
        guard var img = r.loadFull(job.url) else { return String(localized: "无法读取 \(job.url.lastPathComponent)") }
        if let maxSide { img = r.scale(img, maxSide: maxSide) } else {
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        }
        let out = r.renderEdited(img, settings: job.settings, patches: job.patches, locals: job.locals, portrait: job.portrait, cache: MaskCache())
        let name = (job.url.deletingPathExtension().lastPathComponent) + ".jpg"
        let dest = uniqueURL(folder, name)
        do { try r.writeJPEG(out, to: dest) } catch { return String(localized: "写入失败：\(error.localizedDescription)") }
        if FileManager.default.fileExists(atPath: exiftool) {
            // 复制原片的拍摄信息; 方向已经转正, 所以设成 1
            var args = ["-q", "-q", "-overwrite_original", "-tagsfromfile", job.url.path, "-all:all", "-unsafe",
                        "-Orientation#=1", "-ThumbnailImage=", "-PreviewImage="]
            args += metadataArgs(job)
            args.append(dest.path)
            shell(exiftool, args)
        }
        return nil
    }

    // MARK: 发送到 Lightroom

    static func xmp(_ settings: Settings, extra: [String: String] = [:]) -> String {
        var attrs = ["crs:Version=\"15.0\"", "crs:ProcessVersion=\"11.0\"", "crs:HasSettings=\"True\""]
        for (k, v) in extra.sorted(by: { $0.key < $1.key }) { attrs.append("crs:\(k)=\"\(v)\"") }
        for (k, v) in settings.sorted(by: { $0.key < $1.key }) {
            let s: String
            if k == "Exposure2012" { s = String(format: "%+.2f", v) } else if k == "CropAngle" { s = String(format: "%.2f", v) } else { s = String(Int(v.rounded())) }
            attrs.append("crs:\(k)=\"\(s)\"")
        }
        return """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Leonix 修图">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            \(attrs.joined(separator: "\n    "))/>
         </rdf:RDF>
        </x:xmpmeta>

        """
    }

    /// 复制原片到 folder, 写入 Lightroom 修图参数和元数据, 返回副本路径
    /// masks: 局部调整交给 Lightroom 插件做成蒙版 (只有 Lightroom 有插件; Photoshop 收到的还是修好的 TIFF)
    static func prepareForLightroom(_ job: Job, folder: URL, masks: Bool = false) -> (URL?, String?) {
        if job.retouched && !masks { return Integrations.renderTIFF(job, to: folder) }
        let (dest, err) = copyForLightroom(job, folder: folder)
        // 发的是原片 (不是修好的 TIFF) 又有局部调整: 留任务给 Lightroom 插件加蒙版
        if masks, let dest, dest.pathExtension.lowercased() == job.url.pathExtension.lowercased(),
           let text = lightroomMaskJob(job, sent: dest) {
            let dir = AppPaths.data.appendingPathComponent("LightroomMasks")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? text.write(to: dir.appendingPathComponent(UUID().uuidString + ".txt"), atomically: true, encoding: .utf8)
        }
        return (dest, err)
    }

    /// Leonix 的区域 -> Lightroom 的 AI 蒙版.
    /// people:<编号> 是 Lightroom「人物」蒙版的部位 (2 面部皮肤, 3 虹膜和瞳孔, 6 嘴唇, 8 眼白, 12 牙齿, 13 整个人),
    /// 插件写进修图参数再让 Lightroom 计算; 这个 Lightroom 版本做不出来时, 人脸 / 人物 / 皮肤退回「主体」蒙版, 其他的跳过
    static let lightroomMaskType: [MaskKind: String] = [.subject: "subject", .person: "people:13", .face: "people:2",
                                                         .sky: "sky", .background: "background",
                                                         .skin: "people:2", .eyes: "people:8+3", .lips: "people:6", .teeth: "people:12",
                                                         .greenery: "landscape:50005", .water: "landscape:50007",
                                                         .mountains: "landscape:50002", .buildings: "landscape:50001"]
    /// Lightroom 的蒙版做不出来的区域 (亮度蒙版): 发 RAW 时带不过去
    static let lightroomUnsupported: Set<MaskKind> = [.brights, .darks]
    /// 人像精修里 Lightroom 能表达的项目 -> (蒙版, 区域名, 每 100 强度对应的局部参数)
    static let lightroomRetouch: [(key: String, mask: String, area: String, values: [String: Double])] = [
        ("smooth", "people:2", "skin", ["Texture": -45, "Clarity2012": -12]),
        ("eyes", "people:8", "eyes", ["Exposure2012": 0.3, "Saturation": -30]),
        ("eyes", "people:3", "eyes", ["Exposure2012": 0.15, "Clarity2012": 35]),
        ("teeth", "people:12", "teeth", ["Exposure2012": 0.2, "Saturation": -50]),
        ("lips", "people:6", "lips", ["Saturation": 25, "Contrast2012": 10]),
    ]
    /// Leonix 的局部参数 -> Lightroom 蒙版里的滑块 (LrDevelopController 的名字)
    static let lightroomLocalParam: [String: String] = [
        "Exposure2012": "local_Exposure", "Contrast2012": "local_Contrast", "Highlights2012": "local_Highlights",
        "Shadows2012": "local_Shadows", "IncrementalTemperature": "local_Temperature", "Saturation": "local_Saturation",
        "Clarity2012": "local_Clarity", "Texture": "local_Texture",
    ]

    /// 给 Lightroom 插件的任务文件 (一行一项, Lua 好读): 没有要加的局部调整返回 nil
    static func lightroomMaskJob(_ job: Job, sent: URL) -> String? {
        var masks: [String] = []
        for l in job.locals {
            guard let type = lightroomMaskType[l.area] else { continue }
            let vals = l.settings.sorted { $0.key < $1.key }.compactMap { k, v -> String? in
                guard v != 0, let name = lightroomLocalParam[k] else { return nil }
                return name + "=" + (k == "Exposure2012" ? String(format: "%.2f", v) : String(Int(v.rounded())))
            }
            if vals.isEmpty { continue }
            masks.append((["mask=" + type, l.area.rawValue] + vals).joined(separator: "\t"))
        }
        // 人像精修 (能用 Lightroom 蒙版表达的部分)
        for item in lightroomRetouch {
            let k = job.portrait[item.key] / 100
            guard k > 0 else { continue }
            let vals = item.values.sorted { $0.key < $1.key }.compactMap { key, v -> String? in
                guard let name = lightroomLocalParam[key] else { return nil }
                return name + "=" + (key == "Exposure2012" ? String(format: "%.2f", v * k) : String(Int((v * k).rounded())))
            }
            masks.append((["mask=" + item.mask, item.area] + vals).joined(separator: "\t"))
        }
        if masks.isEmpty { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: sent.path)[.size] as? Int) ?? 0
        return (["path=" + sent.path, "name=" + sent.lastPathComponent, "size=\(size)",
                 "created=\(Int(Date().timeIntervalSince1970))"] + masks).joined(separator: "\n") + "\n"
    }

    private static func copyForLightroom(_ job: Job, folder: URL) -> (URL?, String?) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // 有 AI 消除: Lightroom 的参数文件表达不了, 改成发送已经修好的 16 位 TIFF.
        // 局部调整 (人脸/背景/天空…) 不在这里处理: 照常发 RAW + 参数, 另外留一个任务文件,
        // Lightroom 里的 Leonix 插件看到照片导入后, 用 Lightroom 自己的 AI 蒙版把局部调整加上 (还能继续改)
        if !job.patches.isEmpty { return Integrations.renderTIFF(job, to: folder) }
        let dest = uniqueURL(folder, job.url.lastPathComponent)
        do { try FileManager.default.copyItem(at: job.url, to: dest) } catch { return (nil, String(localized: "复制失败：\(error.localizedDescription)")) }
        var s = job.settings
        var extra: [String: String] = [:]
        let rawNotDNG = job.isRaw && job.url.pathExtension.lowercased() != "dng"
        if job.isRaw {
            // RAW 的白平衡在 Lightroom 里是开尔文绝对值: 用相机记录的白平衡 (系统 RAW 解码读出) 换算
            let inc = s["IncrementalTemperature"] ?? 0, incT = s["IncrementalTint"] ?? 0
            s["IncrementalTemperature"] = nil
            s["IncrementalTint"] = nil
            if inc != 0 || incT != 0, let f = CIRAWFilter(imageURL: job.url), f.neutralTemperature > 0 {
                s["Temperature"] = min(50000, max(2000, (Double(f.neutralTemperature) * exp(inc / 100 * 0.35)).rounded()))
                s["Tint"] = min(150, max(-150, (Double(f.neutralTint) + incT * 0.5).rounded()))
                extra["WhiteBalance"] = "Custom"
            }
        } else if s["IncrementalTemperature"] != nil || s["IncrementalTint"] != nil {
            extra["WhiteBalance"] = "Custom"
        }
        // 拉正: Lightroom 的角度 + 同样比例、转了以后不带空角的居中裁剪
        if let ang = s["CropAngle"], abs(ang) > 0.01, let src = CGImageSourceCreateWithURL(job.url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           var pw = props[kCGImagePropertyPixelWidth] as? Double, var ph = props[kCGImagePropertyPixelHeight] as? Double {
            // 竖拍的照片 (方向 5~8) 宽高对调
            if let o = props[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&pw, &ph) }
            let k = Renderer.straightenScale(w: pw, h: ph, degrees: ang)
            let m = (1 - k) / 2
            extra["HasCrop"] = "True"
            extra["CropTop"] = String(format: "%.6f", m); extra["CropBottom"] = String(format: "%.6f", 1 - m)
            extra["CropLeft"] = String(format: "%.6f", m); extra["CropRight"] = String(format: "%.6f", 1 - m)
        }
        let xmpText = xmp(s, extra: extra)
        if rawNotDNG {
            let side = dest.deletingPathExtension().appendingPathExtension("xmp")
            let packet = "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n" + xmpText + "<?xpacket end=\"w\"?>\n"
            try? packet.write(to: side, atomically: true, encoding: .utf8)
            if !metadataArgs(job).isEmpty && hasExiftool {
                shell(exiftool, ["-q", "-q", "-overwrite_original"] + metadataArgs(job) + [side.path])
            }
        } else if !hasExiftool {
            // 没有 exiftool: JPEG / TIFF 等用系统 ImageIO 写进去; DNG 写不了, 改发修好的 16 位 TIFF
            if embedXMP(xmpText, into: dest) { return (dest, nil) }
            try? FileManager.default.removeItem(at: dest)
            return Integrations.renderTIFF(job, to: folder)
        } else {
            let tmp = AIBridge.workDir.appendingPathComponent("lr_\(UUID().uuidString.prefix(6)).xmp")
            try? xmpText.write(to: tmp, atomically: true, encoding: .utf8)
            let (code, out) = shell(exiftool, ["-q", "-q", "-overwrite_original", "-tagsfromfile", tmp.path, "-XMP-crs:all"]
                                    + metadataArgs(job) + [dest.path])
            try? FileManager.default.removeItem(at: tmp)
            if code != 0 { return (dest, String(localized: "写入参数失败：\(out)")) }
        }
        return (dest, nil)
    }
}

extension Store {
    func jobs(_ items: [PhotoItem]) -> [Exporter.Job] {
        items.map { Exporter.Job(url: $0.url, settings: $0.settings, isRaw: $0.isRaw, title: $0.title,
                                 caption: $0.caption, keywords: $0.keywords, stars: $0.stars, patches: $0.patches, locals: $0.locals, portrait: $0.portrait) }
    }

    func exportJPEG(maxSide: CGFloat?) {
        let items = selectedItems
        guard !items.isEmpty, !working else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "导出到这里")
        panel.message = String(localized: "选择导出文件夹（原片不会被改动）")
        let def = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/" + String(localized: "Leonix 修图/导出"))
        try? FileManager.default.createDirectory(at: def, withIntermediateDirectories: true)
        panel.directoryURL = def
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let jobs = self.jobs(items)
        recordForLearning(items)
        working = true
        Task {
            var errors: [String] = []
            for (i, job) in jobs.enumerated() {
                status = String(localized: "导出 \(i + 1)/\(jobs.count)：\(job.url.lastPathComponent)")
                if let e = await Task.detached(operation: { Exporter.exportJPEG(job, to: folder, maxSide: maxSide) }).value {
                    errors.append(e)
                }
            }
            working = false
            status = errors.isEmpty ? String(localized: "已导出 \(jobs.count) 张") : String(localized: "导出完成，\(errors.count) 张失败")
            if !errors.isEmpty { alert = errors.joined(separator: "\n") }
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    func sendToLightroom() {
        let items = selectedItems
        guard !items.isEmpty, !working else { return }
        let jobs = self.jobs(items)
        // 有像素级人像精修 (去瑕疵、眼袋、肤色均匀、光影塑形): Lightroom 的参数表达不了, 问用户要哪种
        var bakeRetouch = false
        if jobs.contains(where: { $0.hasPixelOnly && $0.patches.isEmpty }) {
            let a = NSAlert()
            a.messageText = String(localized: "这张照片有 Lightroom 表达不了的修改")
            a.informativeText = String(localized: "去瑕疵、淡化眼袋、肤色均匀、肤色校准、光影塑形、亮部 / 暗部蒙版是 Leonix 直接改像素做的，Lightroom 的参数表达不了。\n\n发修好的 TIFF：效果和 Leonix 里一样，但不能再改 RAW 参数。\n发可编辑的 RAW：参数和蒙版都能继续改（磨皮、眼睛、牙齿、嘴唇、植被会做成蒙版），这几项需要在 Lightroom 里自己做。")
            a.addButton(withTitle: String(localized: "发修好的 TIFF"))
            a.addButton(withTitle: String(localized: "发可编辑的 RAW"))
            a.addButton(withTitle: String(localized: "取消"))
            switch a.runModal() {
            case .alertFirstButtonReturn: bakeRetouch = true
            case .alertSecondButtonReturn: bakeRetouch = false
            default: return
            }
        }
        recordForLearning(items)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        let folder = AppPaths.exports.appendingPathComponent("Edited Photos/\(f.string(from: Date()))")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        working = true
        Task {
            var outs: [URL] = [], errors: [String] = []
            for (i, job) in jobs.enumerated() {
                status = String(localized: "准备发送到 Lightroom \(i + 1)/\(jobs.count)")
                let masks = !(bakeRetouch && job.hasPixelOnly)
                let (u, e) = await Task.detached(operation: { Exporter.prepareForLightroom(job, folder: folder, masks: masks) }).value
                if let u { outs.append(u) }
                if let e { errors.append(e) }
            }
            working = false
            if !outs.isEmpty {
                Exporter.shell("/usr/bin/open", ["-a", "Adobe Lightroom Classic"] + outs.map { $0.path })
                LightroomSetup.wakePlugin()
                let masked = jobs.filter { $0.patches.isEmpty && $0.retouched }.count
                status = masked > 0
                    ? String(localized: "已发送 \(outs.count) 张到 Lightroom（在导入窗口点「导入」）。其中 \(masked) 张的局部调整会由 Leonix 插件在导入后自动加成蒙版")
                    : String(localized: "已发送 \(outs.count) 张到 Lightroom（在导入窗口点「导入」）")
            }
            if !errors.isEmpty { alert = errors.joined(separator: "\n") }
        }
    }
}
