import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreML
import Foundation
import Vision

// MARK: - 局部调整: 用 macOS 自带的 Vision 找出主体 / 人物 / 人脸, 天空用颜色和位置判断

enum MaskKind: String, Codable, CaseIterable, Identifiable {
    case subject, person, face, sky, background
    // 人像部位 (人脸关键点 + 肤色)
    case skin, eyes, lips, teeth
    // 风光: 亮度蒙版 (亮部 / 暗部) 和植被
    case brights, darks, greenery
    var id: String { rawValue }
    var label: String {
        switch self {
        case .subject: return String(localized: "主体")
        case .person: return String(localized: "人物")
        case .face: return String(localized: "人脸")
        case .sky: return String(localized: "天空")
        case .background: return String(localized: "背景")
        case .skin: return String(localized: "皮肤")
        case .eyes: return String(localized: "眼睛")
        case .lips: return String(localized: "嘴唇")
        case .teeth: return String(localized: "牙齿")
        case .brights: return String(localized: "亮部")
        case .darks: return String(localized: "暗部")
        case .greenery: return String(localized: "植被")
        }
    }
    var icon: String {
        switch self {
        case .subject: return "viewfinder"
        case .person: return "person.fill"
        case .face: return "face.smiling"
        case .sky: return "cloud.sun"
        case .background: return "square.dashed"
        case .skin: return "hand.raised"
        case .eyes: return "eye"
        case .lips: return "mouth"
        case .teeth: return "mouth.fill"
        case .brights: return "sun.max"
        case .darks: return "moon"
        case .greenery: return "leaf"
        }
    }
}

/// 一个局部调整: 只作用在某个区域的一组参数 (0 = 不变)
struct LocalAdjustment: Identifiable, Codable, Hashable {
    var id = UUID()
    var area: MaskKind
    var settings: Settings = [:]
    var note = ""

    /// 局部能调的参数
    static let params: [ParamSpec] = [
        ParamSpec(key: "Exposure2012", label: "曝光", min: -3, max: 3, step: 0.05),
        ParamSpec(key: "Contrast2012", label: "对比度", min: -100, max: 100, step: 1),
        ParamSpec(key: "Highlights2012", label: "高光", min: -100, max: 100, step: 1),
        ParamSpec(key: "Shadows2012", label: "阴影", min: -100, max: 100, step: 1),
        ParamSpec(key: "IncrementalTemperature", label: "色温", min: -100, max: 100, step: 1),
        ParamSpec(key: "Saturation", label: "饱和度", min: -100, max: 100, step: 1),
        ParamSpec(key: "Clarity2012", label: "清晰度", min: -100, max: 100, step: 1),
        ParamSpec(key: "Texture", label: "纹理（负值柔肤）", min: -100, max: 100, step: 1),
    ]
}

/// 一次「AI 消除」的结果: 一块补好的图 (带羽化的透明边缘), 位置用 0~1 的比例记录 (Core Image 坐标, 原点在左下)
struct RetouchPatch: Identifiable, @unchecked Sendable {
    let id = UUID()
    let rect: CGRect
    let image: CGImage
}

/// 预览用的蒙版缓存 (每张照片一个)
final class MaskCache: @unchecked Sendable {
    private var dict: [MaskKind: CIImage] = [:]
    private let lock = NSLock()
    func get(_ k: MaskKind) -> CIImage? { lock.lock(); defer { lock.unlock() }; return dict[k] }
    func set(_ k: MaskKind, _ v: CIImage) { lock.lock(); dict[k] = v; lock.unlock() }

    /// 人像分析 (人脸关键点、各部位蒙版、瑕疵位置), 算一次就留着
    private var portrait: PortraitAnalysis?
    private var portraitDone = false
    func portraitAnalysis(for image: CIImage) -> PortraitAnalysis? {
        lock.lock()
        if portraitDone { let p = portrait; lock.unlock(); return p }
        lock.unlock()
        let p = PortraitAnalysis.compute(for: image)
        lock.lock(); portrait = p; portraitDone = true; lock.unlock()
        return p
    }
}

enum Masks {
    /// 生成灰度蒙版 (白 = 选中), 大小和 image 一样. 找不到 (例如没有人脸) 返回 nil
    static func compute(_ kind: MaskKind, for image: CIImage, cache: MaskCache? = nil) -> CIImage? {
        let r = Renderer.shared
        let extent = image.extent
        // 人像部位: 从人像分析里取
        if [.skin, .eyes, .lips, .teeth].contains(kind) {
            guard let a = cache?.portraitAnalysis(for: image) ?? PortraitAnalysis.compute(for: image) else { return nil }
            let m: CIImage
            switch kind {
            case .skin: m = a.skin
            case .eyes: m = a.eyes
            case .lips: m = a.lips
            default: m = a.teeth
            }
            return PortraitAnalysis.fit(m, from: a.size, to: extent)
        }
        // Vision 在 1536 像素左右就足够准, 再放大回去 (边缘会羽化)
        let small = r.scale(image, maxSide: 1536)
        guard let cg = r.context.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: r.sRGB) else { return nil }
        let mask: CIImage?
        switch kind {
        case .subject: mask = subject(cg)
        case .background: mask = subject(cg).map { invert($0) }
        case .person: mask = person(cg)
        case .face: mask = faces(cg)
        case .sky: mask = sky(cg)
        case .skin, .eyes, .lips, .teeth: mask = nil
        case .brights, .darks, .greenery: mask = tonal(kind, cg)
        }
        guard var m = mask else { return nil }
        // 放大到原图大小 + 轻微羽化
        let sx = extent.width / m.extent.width, sy = extent.height / m.extent.height
        m = m.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        m = m.clampedToExtent().applyingGaussianBlur(sigma: Double(max(extent.width, extent.height) * 0.002)).cropped(to: CGRect(origin: .zero, size: extent.size))
        return m.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    static func invert(_ m: CIImage) -> CIImage { m.applyingFilter("CIColorInvert") }

    static func subject(_ cg: CGImage) -> CIImage? {
        let req = VNGenerateForegroundInstanceMaskRequest()
        let h = VNImageRequestHandler(cgImage: cg)
        guard (try? h.perform([req])) != nil, let obs = req.results?.first,
              let pb = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: h) else { return nil }
        return CIImage(cvPixelBuffer: pb)
    }

    static func person(_ cg: CGImage) -> CIImage? {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .accurate
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let h = VNImageRequestHandler(cgImage: cg)
        guard (try? h.perform([req])) != nil, let pb = req.results?.first?.pixelBuffer else { return nil }
        let m = CIImage(cvPixelBuffer: pb)
        // 几乎没有人的时候算没找到
        guard coverage(m) > 0.003 else { return nil }
        return m.transformed(by: CGAffineTransform(scaleX: CGFloat(cg.width) / m.extent.width, y: CGFloat(cg.height) / m.extent.height))
    }

    static func faces(_ cg: CGImage) -> CIImage? {
        let req = VNDetectFaceRectanglesRequest()
        let h = VNImageRequestHandler(cgImage: cg)
        guard (try? h.perform([req])) != nil, let list = req.results, !list.isEmpty else { return nil }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        var out = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        for f in list {
            let b = f.boundingBox   // 0~1, 原点左下
            let cx = b.midX * W, cy = (b.midY + b.height * 0.06) * H
            let rw = b.width * W * 0.62
            let g = CIFilter.radialGradient()
            g.center = CGPoint(x: cx / 1, y: cy)
            g.radius0 = Float(rw * 0.75)
            g.radius1 = Float(rw * 1.15)
            g.color0 = CIColor.white
            g.color1 = CIColor.black
            // 人脸比较长: 纵向拉长一点
            let stretch = max(1, (b.height * H) / (b.width * W)) * 1.15
            let ellipse = g.outputImage!.transformed(by: CGAffineTransform(translationX: -cx, y: -cy)
                .concatenating(CGAffineTransform(scaleX: 1, y: stretch))
                .concatenating(CGAffineTransform(translationX: cx, y: cy)))
            out = ellipse.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: out])
        }
        return out.cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
    }

    /// 天空: 从画面顶部开始, 把颜色相近的蓝色 / 亮白 / 晚霞区域连起来 (不会跑进白墙这类不和顶部连通的区域)
    static func sky(_ cg: CGImage) -> CIImage? {
        let long = max(cg.width, cg.height)
        let s = min(1, 320 / CGFloat(long))
        let w = max(8, Int(CGFloat(cg.width) * s)), h = max(8, Int(CGFloat(cg.height) * s))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // 主体不算天空
        let fg = subjectGrid(cg, w: w, h: h)
        func rgb(_ i: Int) -> (Double, Double, Double) { (Double(px[i * 4]) / 255, Double(px[i * 4 + 1]) / 255, Double(px[i * 4 + 2]) / 255) }
        func candidate(_ i: Int, row: Int) -> Bool {
            if let fg, fg[i] > 0.5 { return false }
            let (r, g, b) = rgb(i)
            let mx = max(r, g, b), mn = min(r, g, b), lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let sat = mx > 0 ? (mx - mn) / mx : 0
            if b > r + 0.03 && b >= g - 0.03 && lum > 0.2 { return true }            // 蓝天
            if lum > 0.62 && sat < 0.22 { return true }                               // 白云 / 阴天
            if Double(row) < Double(h) * 0.55 && r > b && lum > 0.45 && sat < 0.75 { return true }   // 晚霞 (只在上半部分)
            return false
        }
        var sky = [Float](repeating: 0, count: w * h)
        var stack: [Int] = []
        for x in 0..<w where candidate(x, row: 0) { sky[x] = 1; stack.append(x) }   // 第 0 行就是画面最上面
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            let (r0, g0, b0) = rgb(i)
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                let j = ny * w + nx
                guard sky[j] == 0, candidate(j, row: ny) else { continue }
                let (r1, g1, b1) = rgb(j)
                // 颜色突变 (天际线) 就停
                guard abs(r1 - r0) + abs(g1 - g0) + abs(b1 - b0) < 0.16 else { continue }
                sky[j] = 1
                stack.append(j)
            }
        }
        let cover = sky.reduce(0, +) / Float(w * h)
        guard cover > 0.02 else { return nil }
        // 转成灰度图 (第 0 行在最上面)
        let bytes = sky.map { UInt8($0 * 255) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let mcg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let m = CIImage(cgImage: mcg).applyingGaussianBlur(sigma: 1.2).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        return m.transformed(by: CGAffineTransform(scaleX: CGFloat(cg.width) / CGFloat(w), y: CGFloat(cg.height) / CGFloat(h)))
    }

    /// 亮度蒙版和植被: 逐个像素按亮度 / 颜色算 (风光修图最常用的「亮度蒙版」, 不需要模型).
    /// 亮部: 亮度 55% 以上渐渐选中; 暗部: 45% 以下渐渐选中; 植被: 黄绿到青绿、有一定饱和度
    static func tonal(_ kind: MaskKind, _ cg: CGImage) -> CIImage? {
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        func smooth(_ x: Double, _ a: Double, _ b: Double) -> Double { let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t) }
        var m = [UInt8](repeating: 0, count: w * h)
        var total = 0.0
        for i in 0..<(w * h) {
            let r = Double(px[i * 4]) / 255, g = Double(px[i * 4 + 1]) / 255, b = Double(px[i * 4 + 2]) / 255
            let L = 0.2126 * r + 0.7152 * g + 0.0722 * b
            var v: Double
            switch kind {
            case .brights: v = smooth(L, 0.5, 0.85)
            case .darks: v = 1 - smooth(L, 0.12, 0.45)
            default:
                let mx = max(r, g, b), mn = min(r, g, b)
                let sat = mx > 0 ? (mx - mn) / mx : 0
                var hue = 0.0
                if mx > mn {
                    if mx == r { hue = 60 * ((g - b) / (mx - mn)) } else if mx == g { hue = 60 * ((b - r) / (mx - mn) + 2) } else { hue = 60 * ((r - g) / (mx - mn) + 4) }
                    if hue < 0 { hue += 360 }
                }
                let hueOK = smooth(hue, 50, 75) * (1 - smooth(hue, 160, 185))
                v = hueOK * smooth(sat, 0.12, 0.3) * smooth(L, 0.03, 0.1)
            }
            total += v
            m[i] = UInt8(v * 255)
        }
        guard total / Double(w * h) > 0.01 else { return nil }   // 几乎没有: 算没找到
        guard let provider = CGDataProvider(data: Data(m) as CFData),
              let mcg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        // 植被稍微羽化 (叶子之间的缝隙连起来); 亮度蒙版保持精确, 不会在边缘出光晕
        let img = CIImage(cgImage: mcg)
        return kind == .greenery ? img.clampedToExtent().applyingGaussianBlur(sigma: 1.5).cropped(to: img.extent) : img
    }

    /// 主体蒙版缩到 w×h 的数组 (第 0 行在最上面)
    private static func subjectGrid(_ cg: CGImage, w: Int, h: Int) -> [Float]? {
        guard let m = subject(cg) else { return nil }
        let r = Renderer.shared
        let scaled = m.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / m.extent.width, y: CGFloat(h) / m.extent.height))
        var out = [Float](repeating: 0, count: w * h)
        r.context.render(scaled, toBitmap: &out, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .Rf, colorSpace: nil)
        return out
    }

    private static func coverage(_ m: CIImage) -> Double {
        let r = Renderer.shared
        let avg = m.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: m.extent)])
        var v = [UInt8](repeating: 0, count: 4)
        r.context.render(avg, toBitmap: &v, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return Double(v[0]) / 255
    }
}

// MARK: - 渲染: 消除补丁 → 全局参数 → 局部调整

extension Renderer {
    func applyPatches(_ patches: [RetouchPatch], to img: CIImage) -> CIImage {
        guard !patches.isEmpty else { return img }
        let e = img.extent
        var out = img
        for p in patches {
            let pi = CIImage(cgImage: p.image)
            let target = CGRect(x: e.minX + p.rect.minX * e.width, y: e.minY + p.rect.minY * e.height,
                                width: p.rect.width * e.width, height: p.rect.height * e.height)
            let t = pi.transformed(by: CGAffineTransform(scaleX: target.width / pi.extent.width, y: target.height / pi.extent.height)
                .concatenating(CGAffineTransform(translationX: target.minX, y: target.minY)))
            out = t.composited(over: out).cropped(to: e)
        }
        return out
    }

    func applyLocals(_ locals: [LocalAdjustment], to rendered: CIImage, source: CIImage, cache: MaskCache?, showMask: MaskKind? = nil) -> CIImage {
        var out = rendered
        var used: [MaskKind: CIImage] = [:]
        func mask(_ k: MaskKind) -> CIImage? {
            if let m = used[k] { return m }
            if let c = cache?.get(k) { used[k] = c; return c }
            guard let m = Masks.compute(k, for: source, cache: cache) else { return nil }
            cache?.set(k, m)
            used[k] = m
            return m
        }
        for l in locals where l.settings.contains(where: { $0.value != 0 }) {
            guard let m = mask(l.area) else { continue }
            let adj = apply(l.settings, to: out)
            let fitted = m.transformed(by: CGAffineTransform(scaleX: out.extent.width / m.extent.width, y: out.extent.height / m.extent.height))
            out = adj.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: fitted]).cropped(to: rendered.extent)
        }
        // 调局部时显示范围 (红色覆盖)
        if let k = showMask, let m = mask(k) {
            let fitted = m.transformed(by: CGAffineTransform(scaleX: out.extent.width / m.extent.width, y: out.extent.height / m.extent.height))
            let red = CIImage(color: CIColor(red: 1, green: 0.15, blue: 0.2, alpha: 0.45)).cropped(to: out.extent)
            let overlay = red.composited(over: out)
            out = overlay.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: fitted]).cropped(to: rendered.extent)
        }
        return out
    }

    /// 完整渲染 (预览 / 导出 / 给 AI 看都用这一个)
    func renderEdited(_ base: CIImage, settings: Settings, patches: [RetouchPatch], locals: [LocalAdjustment],
                      portrait: PortraitRetouch = PortraitRetouch(), cache: MaskCache? = nil, showMask: MaskKind? = nil) -> CIImage {
        let patched = applyPatches(patches, to: base)
        var global = apply(settings, to: patched)
        if !portrait.isEmpty, let a = cache?.portraitAnalysis(for: patched) ?? PortraitAnalysis.compute(for: patched) {
            global = applyPortrait(portrait, to: global, analysis: a)
        }
        let done = locals.isEmpty && showMask == nil ? global : applyLocals(locals, to: global, source: patched, cache: cache, showMask: showMask)
        // 最后一步: 拉正 (和 Lightroom 的「角度」一样, 正数 = 顺时针转)
        let angle = settings["CropAngle"] ?? 0
        return abs(angle) > 0.01 ? straighten(done, degrees: angle) : done
    }

    /// 转 degrees 度后还能放下的、同样比例的最大矩形, 占原来宽高的比例
    static func straightenScale(w: Double, h: Double, degrees: Double) -> Double {
        let t = abs(degrees) * .pi / 180
        return min(w / (w * cos(t) + h * sin(t)), h / (w * sin(t) + h * cos(t)))
    }

    /// 绕中心顺时针转 degrees 度, 裁出不带空角的最大部分 (原点移回 0)
    func straighten(_ img: CIImage, degrees: Double) -> CIImage {
        let E = img.extent
        let c = CGPoint(x: E.midX, y: E.midY)
        let rot = img.transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(rotationAngle: -degrees * .pi / 180))
            .concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
        let k = Self.straightenScale(w: E.width, h: E.height, degrees: degrees)
        let w = (E.width * k).rounded(.down), h = (E.height * k).rounded(.down)
        let crop = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        return rot.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    }

    /// 用 Vision 找地平线, 返回要转的角度 (Lightroom 的写法: 正数 = 顺时针). 找不到或者已经平了返回 nil
    static func horizonAngle(_ img: CIImage) -> Double? {
        let r = Renderer.shared
        let small = r.scale(img, maxSide: 1024)
        guard let cg = r.context.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: r.sRGB) else { return nil }
        let req = VNDetectHorizonRequest()
        guard (try? VNImageRequestHandler(cgImage: cg).perform([req])) != nil, let h = req.results?.first else { return nil }
        // Vision 给的角度和 Lightroom「角度」的方向相反 (实测: 逆时针歪 4° 的照片, Vision 给 -3.6°, 要顺时针转 3.6° 才平)
        let deg = -Double(h.angle) * 180 / .pi
        guard abs(deg) >= 0.2, abs(deg) <= 15 else { return nil }
        return (deg * 100).rounded() / 100
    }
}

// MARK: - AI 消除 (LaMa, 开源 Apache-2.0, Core ML 版本在 Mac 的神经网络引擎上运行)

final class Inpainter: @unchecked Sendable {
    static let shared = Inpainter()
    static let side = 800
    private var model: MLModel?
    private let lock = NSLock()

    static var dir: URL { AppPaths.models.appendingPathComponent("Retouch") }
    static var compiled: URL { dir.appendingPathComponent("LaMa.mlmodelc") }
    static var installed: Bool { FileManager.default.fileExists(atPath: compiled.path) }
    static let files = ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"]
    static let repo = "https://huggingface.co/mlboydaisuke/LaMa-CoreML/resolve/main/LaMa.mlpackage/"

    /// 第一次用时下载 (约 216 MB) 并编译
    func ensureModel(progress: @escaping @Sendable (Int64) -> Void) async throws -> MLModel {
        if let m = lock.withLock({ model }) { return m }
        if !Self.installed {
            let pkg = Self.dir.appendingPathComponent("LaMa.mlpackage")
            var done: Int64 = 0
            for f in Self.files {
                let base = done
                try await ModelDownloader.fetch(url: URL(string: Self.repo + f)!, to: pkg.appendingPathComponent(f)) { got in progress(base + got) }
                done += (try? FileManager.default.attributesOfItem(atPath: pkg.appendingPathComponent(f).path)[.size] as? Int64) ?? 0
            }
            let tmp = try await MLModel.compileModel(at: pkg)
            try? FileManager.default.removeItem(at: Self.compiled)
            try FileManager.default.moveItem(at: tmp, to: Self.compiled)
            try? FileManager.default.removeItem(at: pkg)
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        let m = try MLModel(contentsOf: Self.compiled, configuration: cfg)
        lock.withLock { model = m }
        return m
    }

    /// 在原图上消除笔刷涂过的地方. strokes: 0~1 坐标 (原点左上), brush: 笔刷半径占图片宽度的比例
    func remove(url: URL, existing: [RetouchPatch], strokes: [[CGPoint]], brush: CGFloat,
                progress: @escaping @Sendable (Int64) -> Void) async throws -> RetouchPatch {
        let model = try await ensureModel(progress: progress)
        let r = Renderer.shared
        guard var full = r.loadFull(url) else { throw EngineError(String(localized: "无法读取照片")) }
        full = full.transformed(by: CGAffineTransform(translationX: -full.extent.minX, y: -full.extent.minY))
        full = r.applyPatches(existing, to: full)
        let W = full.extent.width, H = full.extent.height
        let radius = brush * W

        // 涂抹范围 (像素, 原点左上)
        let pts = strokes.flatMap { $0 }
        guard !pts.isEmpty else { throw EngineError(String(localized: "请先在照片上涂出要消除的地方")) }
        let minX = pts.map(\.x).min()! * W - radius, maxX = pts.map(\.x).max()! * W + radius
        let minY = pts.map(\.y).min()! * H - radius, maxY = pts.map(\.y).max()! * H + radius
        // 正方形裁切区域: 给 LaMa 足够的周围画面参考
        var side = max(maxX - minX, maxY - minY) * 1.8 + radius * 2
        side = min(max(side, 512), min(W, H))
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        let x0 = min(max(0, cx - side / 2), W - side), y0Top = min(max(0, cy - side / 2), H - side)
        let ciRect = CGRect(x: x0, y: H - y0Top - side, width: side, height: side).integral

        // 1) 裁出来缩放到 800×800 的 BGRA
        let n = Self.side
        let crop = full.cropped(to: ciRect).transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))
        let scaled = crop.transformed(by: CGAffineTransform(scaleX: CGFloat(n) / ciRect.width, y: CGFloat(n) / ciRect.height))
        var imgPB: CVPixelBuffer?
        CVPixelBufferCreate(nil, n, n, kCVPixelFormatType_32BGRA, [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &imgPB)
        guard let imgPB else { throw EngineError("pixel buffer") }
        r.context.render(scaled, to: imgPB, bounds: CGRect(x: 0, y: 0, width: n, height: n), colorSpace: r.sRGB)

        // 2) 笔刷蒙版 (同样的裁切和缩放)
        func drawMask(into ctx: CGContext, size: CGFloat, extra: CGFloat) {
            ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            ctx.setStrokeColor(gray: 1, alpha: 1); ctx.setFillColor(gray: 1, alpha: 1)
            let k = size / ciRect.width
            ctx.setLineWidth((radius * 2 + extra) * k); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            for s in strokes {
                // CGContext 原点在左下
                let mapped = s.map { CGPoint(x: ($0.x * W - x0) * k, y: size - ($0.y * H - y0Top) * k) }
                if mapped.count == 1 {
                    let p = mapped[0], d = (radius * 2 + extra) * k
                    ctx.fillEllipse(in: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
                } else {
                    ctx.beginPath(); ctx.addLines(between: mapped); ctx.strokePath()
                }
            }
        }
        var maskPB: CVPixelBuffer?
        CVPixelBufferCreate(nil, n, n, kCVPixelFormatType_OneComponent8, nil, &maskPB)
        guard let maskPB else { throw EngineError("mask buffer") }
        CVPixelBufferLockBaseAddress(maskPB, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(maskPB), width: n, height: n, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(maskPB), space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) {
            // 位图内存第 0 行 = 画面最上面 (CGContext 绘图原点在左下), 和 Core ML 读取的顺序一致
            drawMask(into: ctx, size: CGFloat(n), extra: radius * 0.4)
        }
        CVPixelBufferUnlockBaseAddress(maskPB, [])

        // 3) 运行 LaMa
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: imgPB), "mask": MLFeatureValue(pixelBuffer: maskPB)])
        let result = try await model.prediction(from: input)
        guard let outPB = result.featureValue(for: "output")?.imageBufferValue else { throw EngineError(String(localized: "消除失败")) }
        let filled = CIImage(cvPixelBuffer: outPB)
            .transformed(by: CGAffineTransform(scaleX: ciRect.width / CGFloat(n), y: ciRect.height / CGFloat(n)))

        // 4) 羽化蒙版 (原尺寸), 只把涂过的地方换掉
        let S = Int(ciRect.width)
        var feather = [UInt8](repeating: 0, count: S * S)
        if let ctx = CGContext(data: &feather, width: S, height: S, bitsPerComponent: 8, bytesPerRow: S,
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) {
            drawMask(into: ctx, size: CGFloat(S), extra: radius * 0.6)
        }
        guard let fp = CGDataProvider(data: Data(feather) as CFData),
              let fcg = CGImage(width: S, height: S, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: S, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGBitmapInfo(rawValue: 0), provider: fp, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw EngineError("feather")
        }
        let soft = CIImage(cgImage: fcg).clampedToExtent().applyingGaussianBlur(sigma: Double(radius * 0.25)).cropped(to: CGRect(x: 0, y: 0, width: S, height: S))
        let clear = CIImage(color: .clear).cropped(to: soft.extent)
        let patch = filled.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: soft])
            .cropped(to: soft.extent)
        guard let pcg = r.context.createCGImage(patch, from: patch.extent, format: .RGBA8, colorSpace: r.sRGB) else { throw EngineError("patch") }
        let norm = CGRect(x: ciRect.minX / W, y: ciRect.minY / H, width: ciRect.width / W, height: ciRect.height / H)
        return RetouchPatch(rect: norm, image: pcg)
    }
}
