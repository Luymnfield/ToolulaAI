import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

/// 修图引擎: Core Image 渲染所有参数
/// 色调/白平衡/HSL/饱和度/颜色分级/去朦胧 -> 一个 3D LUT; 曝光/清晰度/纹理/暗角/颗粒 -> Core Image 滤镜
final class Renderer: @unchecked Sendable {
    static let shared = Renderer()

    let context: CIContext = {
        let cs = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        return CIContext(options: [.workingColorSpace: cs, .cacheIntermediates: false])
    }()
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static let rawExtensions: Set<String> = ["cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2",
                                             "pef", "srw", "x3f", "3fr", "iiq", "erf", "mef", "mos", "rwl", "kdc", "dcr", "dng"]
    static let imageExtensions: Set<String> = rawExtensions.union(["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp"])

    static func isRaw(_ url: URL) -> Bool { rawExtensions.contains(url.pathExtension.lowercased()) }

    // MARK: 读取

    /// RAW「底片」向 Lightroom 看齐: 苹果的 RAW 解码比 Lightroom (Adobe Standard 配置文件) 更浓、对比更强.
    /// 同样的参数发到 Lightroom 后效果要和这里看到的一样, 所以起点也要一样 (数值用 Lightroom 实际渲染的照片对比校准).
    /// 可以用 defaults 覆盖 (校准时用): rawLookBoost / rawLookSaturation / rawLookExposure
    struct RawLook: Equatable {
        var boost: Double = 1, saturation: Double = 1, exposure: Double = 0
        /// 亮度降噪: 苹果默认 0.64 (画面偏糊), Lightroom 默认 0
        var noiseReduction: Double = 0
        /// 2026-11 用 Lightroom Classic 14.3 (Adobe Standard) 渲染的两张 Sony RAW 校准: 起点色差 ΔE 3.8 -> 2.6
        static let lightroom = RawLook(boost: 1, saturation: 0.815, exposure: -0.05, noiseReduction: 0)
        nonisolated(unsafe) static var override: RawLook?   // 校准时临时指定
        static var current: RawLook {
            if let o = override { return o }
            let d = UserDefaults.standard
            var l = lightroom
            if d.object(forKey: "rawLookBoost") != nil { l.boost = d.double(forKey: "rawLookBoost") }
            if d.object(forKey: "rawLookSaturation") != nil { l.saturation = d.double(forKey: "rawLookSaturation") }
            if d.object(forKey: "rawLookExposure") != nil { l.exposure = d.double(forKey: "rawLookExposure") }
            return l
        }
    }

    /// 读取原图 (RAW 用系统的 RAW 解码, 再调成 Lightroom 的起点)
    func loadFull(_ url: URL) -> CIImage? {
        if Renderer.isRaw(url), let raw = CIRAWFilter(imageURL: url) {
            let look = RawLook.current
            raw.boostAmount = Float(look.boost)
            if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = Float(look.noiseReduction) }
            if look.exposure != 0 { raw.exposure = Float(look.exposure) }
            guard var img = raw.outputImage else { return nil }
            if look.saturation != 1 {
                let f = CIFilter.colorControls()
                f.inputImage = img
                f.saturation = Float(look.saturation)
                img = f.outputImage ?? img
            }
            return img
        }
        return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }

    /// 缩小到长边 maxSide 并"冻结"成位图 (调滑块时不用每次重新解码 RAW)
    func loadPreviewBase(_ url: URL, maxSide: CGFloat) -> CIImage? {
        guard let full = loadFull(url) else { return nil }
        let scaled = scale(full, maxSide: maxSide)
        guard let cg = context.createCGImage(scaled, from: scaled.extent, format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)) else { return nil }
        return CIImage(cgImage: cg)
    }

    func scale(_ img: CIImage, maxSide: CGFloat) -> CIImage {
        let long = max(img.extent.width, img.extent.height)
        guard long > maxSide else { return img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY)) }
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        f.scale = Float(maxSide / long)
        f.aspectRatio = 1
        return f.outputImage ?? img
    }

    // MARK: 渲染

    func apply(_ lrSettings: Settings, to input: CIImage) -> CIImage {
        let settings = SliderCalibration.map(lrSettings)
        let extent = input.extent
        let long = max(extent.width, extent.height)
        var img = input
        func v(_ k: String) -> Double { settings[k] ?? 0 }

        // 1. 曝光 (线性空间)
        let ev = v("Exposure2012")
        if ev != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = img
            f.ev = Float(ev)
            img = f.outputImage ?? img
        }

        // 2. 颜色 / 色调 LUT
        if LUT.needed(settings) {
            let f = CIFilter.colorCubeWithColorSpace()
            f.inputImage = img
            f.cubeDimension = Float(LUT.size)
            f.cubeData = LUT.build(settings)
            f.colorSpace = sRGB
            img = f.outputImage ?? img
        }

        // 3. 清晰度 (大半径反锐化) / 纹理 (小半径)
        let clarity = v("Clarity2012")
        if clarity != 0 {
            let f = CIFilter.unsharpMask()
            f.inputImage = img.clampedToExtent()
            f.radius = Float(long * 0.012)
            f.intensity = Float(clarity / 100 * 0.55)
            img = (f.outputImage ?? img).cropped(to: extent)
        }
        let texture = v("Texture")
        if texture != 0 {
            let f = CIFilter.unsharpMask()
            f.inputImage = img.clampedToExtent()
            f.radius = Float(max(1, long * 0.0018))
            f.intensity = Float(texture / 100 * 0.9)
            img = (f.outputImage ?? img).cropped(to: extent)
        }

        // 4. 暗角: 按 Lightroom 实测的形状 (中间约 30% 不变, 往外快速变暗; -50 时四角约 -3 档)
        let vig = v("PostCropVignetteAmount")
        if vig != 0 {
            img = applyVignette(img, amount: vig)
        }

        // 5. 颗粒
        let grain = v("GrainAmount")
        if grain > 0, let noise = CIFilter.randomGenerator().outputImage {
            let size = max(1, long / 1400)  // 颗粒大小跟随图片尺寸
            // 灰色噪点, 以 0 为中心 (可正可负), 直接加到图片上
            let k = CGFloat(grain / 100 * 0.16)
            let mono = noise
                .transformed(by: CGAffineTransform(scaleX: size, y: size))
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: k, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: k, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: -k / 2, y: -k / 2, z: -k / 2, w: 0),
                ])
                .cropped(to: extent)
            img = mono.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: img]).cropped(to: extent)
        }
        return img
    }

    /// 暗角系数图: 每个点的亮度倍数 (线性). 形状来自 Lightroom 渲染的对比测量:
    /// -50 时 1 - 0.89 × smoothstep(0.33, 0.9, r), r = 到中心的距离 (四角 = 1, 按画面宽高各自归一化, 所以是椭圆);
    /// 强度按「档」缩放: 倍数 = (-50 时的倍数) 的 |amount|/50 次方. 正值 (变亮) 用一半的强度往反方向.
    static func vignetteFactor(r: Double, amount: Double) -> Double {
        let t = min(1, max(0, (r - 0.33) / (0.9 - 0.33)))
        let s = t * t * (3 - 2 * t)
        let base = 1 - 0.89 * s
        let k = abs(amount) / 50
        return amount < 0 ? pow(base, k) : pow(base, -k * 0.5)
    }

    private func applyVignette(_ img: CIImage, amount: Double) -> CIImage {
        let extent = img.extent
        let n = 256
        var px = [Float](repeating: 1, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let dx = (Double(x) + 0.5) / Double(n) * 2 - 1, dy = (Double(y) + 0.5) / Double(n) * 2 - 1
                let f = Float(Self.vignetteFactor(r: sqrt(dx * dx + dy * dy) / sqrt(2), amount: amount))
                let i = (y * n + x) * 4
                px[i] = f; px[i + 1] = f; px[i + 2] = f
            }
        }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let map = CIImage(bitmapData: data, bytesPerRow: n * 16, size: CGSize(width: n, height: n), format: .RGBAf, colorSpace: linear)
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(n), y: extent.height / CGFloat(n))
                .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY)))
            .clampedToExtent().cropped(to: extent)
        return img.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: map]).cropped(to: extent)
    }

    func makeNSImage(_ img: CIImage) -> NSImage? {
        guard let cg = context.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: sRGB) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: img.extent.width, height: img.extent.height))
    }

    func writeJPEG(_ img: CIImage, to url: URL, quality: Double = 0.92) throws {
        try context.writeJPEGRepresentation(of: img, to: url, colorSpace: sRGB,
                                            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
    }

    /// 拍摄时间 (用来按场景分组)
    static func captureDate(_ url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let s = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: s)
    }
}

// MARK: - 滑块校准

/// 参数都是 Lightroom 的数值 (界面显示、发给 Lightroom 的都是这个); 渲染前换算成本引擎要用的强度,
/// 让同一个数值在这里和在 Lightroom 里看起来一样 (系数用 Lightroom 自己渲染的参考图对比得出).
/// 校准时可以用 defaults 覆盖: calib.<参数>+ / calib.<参数>- (正值 / 负值的系数)
enum SliderCalibration {
    /// 参数 -> (正值系数, 负值系数); 没列出的不变
    /// 只收了「明显更接近、又不是极端值」的. 高光/阴影/白色/黑色已经改成按 Lightroom 实测的曲线 (lightroomToneTable), 不在这里
    static let gains: [String: (pos: Double, neg: Double)] = [
        "Exposure2012": (1.0, 1.2),
        "Contrast2012": (1.4, 1.4),
        "Vibrance": (0.85, 1.2),
        "SplitToningHighlightSaturation": (0.85, 1.0),
        "SplitToningShadowSaturation": (0.85, 1.0),
    ]

    nonisolated(unsafe) static var overrides: [String: Double] = [:]   // 校准时临时指定, 键 "Contrast2012+"

    static func gain(_ key: String, positive: Bool) -> Double {
        let o = "calib.\(key)" + (positive ? "+" : "-")
        if let v = overrides[key + (positive ? "+" : "-")] { return v }
        if UserDefaults.standard.object(forKey: o) != nil { return UserDefaults.standard.double(forKey: o) }
        guard let g = gains[key] else { return 1 }
        return positive ? g.pos : g.neg
    }

    static func map(_ s: Settings) -> Settings {
        var out = s
        for (k, v) in s where v != 0 && !Params.noBlend.contains(k) {
            out[k] = v * gain(k, positive: v > 0)
        }
        return out
    }
}

// MARK: - 3D LUT

enum LUT {
    static let size = 33
    static let lutKeys: [String] = {
        var k = ["IncrementalTemperature", "IncrementalTint", "Contrast2012", "Highlights2012", "Shadows2012",
                 "Whites2012", "Blacks2012", "Dehaze", "Vibrance", "Saturation",
                 "ParametricHighlights", "ParametricLights", "ParametricDarks", "ParametricShadows",
                 "SplitToningShadowSaturation", "SplitToningHighlightSaturation"]
        for c in Params.colors { k += ["HueAdjustment\(c.key)", "SaturationAdjustment\(c.key)", "LuminanceAdjustment\(c.key)"] }
        return k
    }()

    static func needed(_ s: Settings) -> Bool { lutKeys.contains { (s[$0] ?? 0) != 0 } }

    @inline(__always) static func toLinear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    @inline(__always) static func toGamma(_ c: Double) -> Double {
        let x = max(0, c)
        return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
    }
    @inline(__always) static func lum(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    @inline(__always) static func bell(_ x: Double, _ c: Double, _ w: Double) -> Double { let d = (x - c) / w; return exp(-d * d) }

    /// Lightroom (PV2012, Adobe Standard) 的高光 / 阴影 / 白色 / 黑色滑块: 每单位滑块 (滑块值 / 100) 让每个亮度 (sRGB 亮度 0, 0.05 … 1) 变化多少.
    /// 来自同一张照片在 Lightroom 里 ±50 / ±60 的实际渲染和原图逐像素对比 (两张校准照片的平均, ~/Toolula/Data/LightroomCalibrate).
    /// 以前用的是手写的钟形曲线, 作用范围太窄: 例如黑色 -50 在 Lightroom 里让 10%~15% 亮度的地方暗 0.08, 以前只暗 0.014.
    static let lightroomToneTable: [String: [Double]] = [
        "Highlights2012+": [0.0016, 0.0050, 0.0098, 0.0158, 0.0220, 0.0285, 0.0361, 0.0467, 0.0643, 0.0893, 0.1151, 0.1372, 0.1552, 0.1657, 0.1653, 0.1568, 0.1449, 0.1289, 0.1045, 0.0770, 0.0000],
        "Highlights2012-": [0.0021, 0.0059, 0.0103, 0.0158, 0.0216, 0.0276, 0.0344, 0.0439, 0.0600, 0.0837, 0.1103, 0.1359, 0.1588, 0.1758, 0.1859, 0.1915, 0.1941, 0.1882, 0.1648, 0.1350, 0.0000],
        "Shadows2012+": [0.0555, 0.1179, 0.1254, 0.1191, 0.1021, 0.0841, 0.0717, 0.0636, 0.0554, 0.0475, 0.0416, 0.0370, 0.0329, 0.0290, 0.0247, 0.0199, 0.0150, 0.0102, 0.0057, 0.0026, 0.0000],
        "Shadows2012-": [0.0208, 0.0515, 0.0702, 0.0812, 0.0803, 0.0721, 0.0637, 0.0575, 0.0514, 0.0454, 0.0409, 0.0373, 0.0335, 0.0296, 0.0253, 0.0203, 0.0150, 0.0094, 0.0045, 0.0017, 0.0000],
        "Whites2012+": [0.0009, 0.0033, 0.0075, 0.0143, 0.0228, 0.0330, 0.0457, 0.0615, 0.0802, 0.0999, 0.1179, 0.1336, 0.1475, 0.1593, 0.1689, 0.1761, 0.1795, 0.1733, 0.1496, 0.1167, 0.0000],
        "Whites2012-": [0.0003, 0.0013, 0.0031, 0.0059, 0.0093, 0.0134, 0.0187, 0.0257, 0.0341, 0.0437, 0.0535, 0.0631, 0.0721, 0.0806, 0.0892, 0.0982, 0.1065, 0.1127, 0.1152, 0.1145, 0.0000],
        "Blacks2012+": [0.0229, 0.0511, 0.0620, 0.0707, 0.0743, 0.0751, 0.0758, 0.0763, 0.0756, 0.0727, 0.0674, 0.0601, 0.0519, 0.0437, 0.0354, 0.0270, 0.0193, 0.0125, 0.0069, 0.0032, 0.0000],
        "Blacks2012-": [0.0366, 0.0945, 0.1315, 0.1466, 0.1380, 0.1212, 0.1058, 0.0949, 0.0872, 0.0800, 0.0719, 0.0627, 0.0531, 0.0440, 0.0354, 0.0271, 0.0196, 0.0131, 0.0079, 0.0047, 0.0000],
    ]

    @inline(__always) static func lightroomTone(_ key: String, positive: Bool, _ x: Double) -> Double {
        guard let t = lightroomToneTable[key + (positive ? "+" : "-")] else { return 0 }
        let p = min(1, max(0, x)) * 20
        let i = min(19, Int(p)), f = p - Double(i)
        return t[i] * (1 - f) + t[i + 1] * f
    }

    /// 色调曲线 (输入/输出都是 0~1 的亮度)
    static func toneCurve(_ x: Double, _ s: Settings) -> Double {
        func v(_ k: String) -> Double { (s[k] ?? 0) / 100 }
        var y = x
        y -= v("Contrast2012") * 0.07 * sin(2 * .pi * x)
        // 高光 / 阴影 / 白色 / 黑色: 用 Lightroom 实际渲染量出来的曲线 (见 lightroomTone)
        for k in ["Highlights2012", "Shadows2012", "Whites2012", "Blacks2012"] {
            let t = v(k)
            if t != 0 { y += t * lightroomTone(k, positive: t > 0, x) }
        }
        y += v("ParametricHighlights") * 0.08 * bell(x, 0.88, 0.10)
        y += v("ParametricLights") * 0.08 * bell(x, 0.63, 0.12)
        y += v("ParametricDarks") * 0.08 * bell(x, 0.37, 0.12)
        y += v("ParametricShadows") * 0.08 * bell(x, 0.13, 0.10)
        return min(1, max(0, y))
    }

    static func hueRGB(_ h: Double) -> (Double, Double, Double) {
        // 纯色 (饱和度 1, 亮度 0.5)
        let hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = 1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1)
        switch Int(hh) {
        case 0: return (1, x, 0)
        case 1: return (x, 1, 0)
        case 2: return (0, 1, x)
        case 3: return (0, x, 1)
        case 4: return (x, 0, 1)
        default: return (1, 0, x)
        }
    }

    static func rgbToHsl(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        guard mx - mn > 1e-6 else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h *= 60
        return (h, s, l)
    }

    static func hslToRgb(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        guard s > 1e-6 else { return (l, l, l) }
        func f(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        let hh = h / 360
        return (f(p, q, hh + 1.0 / 3), f(p, q, hh), f(p, q, hh - 1.0 / 3))
    }

    static func build(_ s: Settings) -> Data {
        func v(_ k: String) -> Double { (s[k] ?? 0) / 100 }
        let n = size
        var data = [Float](repeating: 0, count: n * n * n * 4)
        let temp = v("IncrementalTemperature"), tint = v("IncrementalTint")
        let dehaze = v("Dehaze"), vib = v("Vibrance"), sat = v("Saturation")
        let hueAdj = Params.colors.map { v("HueAdjustment\($0.key)") }
        let satAdj = Params.colors.map { v("SaturationAdjustment\($0.key)") }
        let lumAdj = Params.colors.map { v("LuminanceAdjustment\($0.key)") }
        let hasHSL = (hueAdj + satAdj + lumAdj).contains { $0 != 0 }
        let shHue = s["SplitToningShadowHue"] ?? 0, shSat = v("SplitToningShadowSaturation")
        let hiHue = s["SplitToningHighlightHue"] ?? 0, hiSat = v("SplitToningHighlightSaturation")
        let balance = v("SplitToningBalance")
        let shCol = hueRGB(shHue), hiCol = hueRGB(hiHue)
        // 白平衡通道倍数
        let wr = 1 + 0.28 * temp, wb = 1 - 0.28 * temp, wg = 1 - 0.18 * tint

        // 预先算好色调曲线
        let curveN = 1024
        let curve = (0...curveN).map { toneCurve(Double($0) / Double(curveN), s) }
        func applyCurve(_ x: Double) -> Double {
            let p = min(1, max(0, x)) * Double(curveN)
            let i = Int(p), f = p - Double(i)
            return i >= curveN ? curve[curveN] : curve[i] * (1 - f) + curve[i + 1] * f
        }

        var idx = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    var r = Double(ri) / Double(n - 1), g = Double(gi) / Double(n - 1), b = Double(bi) / Double(n - 1)

                    // 白平衡 (线性空间, 保持亮度)
                    if temp != 0 || tint != 0 {
                        var lr = toLinear(r), lg = toLinear(g), lb = toLinear(b)
                        let y0 = lum(lr, lg, lb)
                        lr *= wr; lg *= wg; lb *= wb
                        let y1 = lum(lr, lg, lb)
                        if y1 > 1e-6 { let k = y0 / y1; lr *= k; lg *= k; lb *= k }
                        r = toGamma(lr); g = toGamma(lg); b = toGamma(lb)
                    }

                    // 去朦胧
                    if dehaze > 0 {
                        let d = 0.10 * dehaze
                        r = (r - d) / (1 - d); g = (g - d) / (1 - d); b = (b - d) / (1 - d)
                    } else if dehaze < 0 {
                        let d = -dehaze * 0.30
                        r = r * (1 - d) + 0.78 * d; g = g * (1 - d) + 0.78 * d; b = b * (1 - d) + 0.80 * d
                    }

                    // 色调曲线 (作用在亮度上, 保持色相)
                    let L = lum(r, g, b)
                    let dL = applyCurve(L) - L
                    r += dL; g += dL; b += dL
                    r = min(1, max(0, r)); g = min(1, max(0, g)); b = min(1, max(0, b))

                    // HSL / 饱和度
                    var (h, sl, l) = rgbToHsl(r, g, b)
                    if hasHSL && sl > 0.001 {
                        var dh = 0.0, ds = 0.0, dl = 0.0
                        for (i, c) in Params.colors.enumerated() {
                            var dist = abs(h - c.hue)
                            if dist > 180 { dist = 360 - dist }
                            let w = max(0, 1 - dist / 42)
                            if w > 0 {
                                dh += w * hueAdj[i]; ds += w * satAdj[i]; dl += w * lumAdj[i]
                            }
                        }
                        h = (h + dh * 35 + 360).truncatingRemainder(dividingBy: 360)
                        sl *= max(0, 1 + ds)
                        l += dl * 0.22 * min(1, sl * 2) * (1 - abs(2 * l - 1) * 0.5)
                    }
                    if vib != 0 { sl *= max(0, 1 + vib * (vib > 0 ? (1 - sl) * 0.9 : 0.8)) }
                    if sat != 0 { sl *= max(0, 1 + sat) }
                    if dehaze > 0 { sl *= 1 + dehaze * 0.2 }
                    sl = min(1, max(0, sl)); l = min(1, max(0, l))
                    (r, g, b) = hslToRgb(h, sl, l)

                    // 颜色分级 (阴影/高光上色)
                    if shSat > 0 || hiSat > 0 {
                        let LL = lum(r, g, b)
                        let mid = 0.5 + balance * 0.3
                        let wsh = shSat * 0.22 * pow(max(0, 1 - LL / max(0.05, mid * 2)), 1.5)
                        let whi = hiSat * 0.22 * pow(max(0, (LL - (1 - (1 - mid) * 2)) / max(0.05, (1 - mid) * 2)), 1.5)
                        r += (shCol.0 - 0.5) * wsh + (hiCol.0 - 0.5) * whi
                        g += (shCol.1 - 0.5) * wsh + (hiCol.1 - 0.5) * whi
                        b += (shCol.2 - 0.5) * wsh + (hiCol.2 - 0.5) * whi
                    }

                    data[idx] = Float(min(1, max(0, r)))
                    data[idx + 1] = Float(min(1, max(0, g)))
                    data[idx + 2] = Float(min(1, max(0, b)))
                    data[idx + 3] = 1
                    idx += 4
                }
            }
        }
        return data.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
