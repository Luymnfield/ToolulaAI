import CoreImage
import Foundation

/// 在照片上精确地量几样东西, 交给 AI 参考 (看缩略图判断曝光和偏色并不准), 也用来在 AI 修完后检查有没有过曝 / 死黑
enum PhotoMeasure {
    struct Stats {
        var p1 = 0.0, p50 = 0.0, p99 = 0.0      // 亮度分位 (0~1)
        var clipHi = 0.0, clipLo = 0.0           // 过曝 / 死黑像素占比 (%)
        var castA = 0.0, castB = 0.0             // 中性色区域的偏色: A 正 = 偏品红 / 负 = 偏绿; B 正 = 偏黄 / 负 = 偏蓝 (0~255 单位)
        var neutralShare = 0.0
        var meanSat = 0.0                          // 平均饱和度 (0~1)
        var globalA = 0.0, globalB = 0.0           // 所有中间调的平均偏色 (强烈偏色时中性色本身也会被染色, 这个更能看出来)
        var skin: (luma: Double, hue: Double, sat: Double)?
    }

    static let side: CGFloat = 320

    /// 量一张 (已经调好色的) 图. skin 是同一张图的皮肤蒙版 (可以是任意大小, 会对齐)
    static func stats(_ img: CIImage, skin: CIImage? = nil) -> Stats? {
        let r = Renderer.shared
        let small = r.scale(img, maxSide: side)
        let E = small.extent
        let w = Int(E.width), h = Int(E.height)
        guard w > 4, h > 4, let cg = r.context.createCGImage(small, from: E, format: .RGBA8, colorSpace: r.sRGB) else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: r.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var mask: [Float]?
        if let skin {
            let m = skin.transformed(by: CGAffineTransform(scaleX: E.width / skin.extent.width, y: E.height / skin.extent.height)
                .concatenating(CGAffineTransform(translationX: E.minX - skin.extent.minX * E.width / skin.extent.width,
                                                 y: E.minY - skin.extent.minY * E.height / skin.extent.height)))
            var out = [Float](repeating: 0, count: w * h)
            // 和像素数组一样, 第 0 行在最上面 (Masks.subjectGrid 等处同样的用法)
            r.context.render(m, toBitmap: &out, rowBytes: w * 4, bounds: E, format: .Rf, colorSpace: nil)
            mask = out
        }

        var hist = [Int](repeating: 0, count: 256)
        var hi = 0, lo = 0, nN = 0, nG = 0
        var gA = 0.0, gB = 0.0, satSum = 0.0
        var sumA = 0.0, sumB = 0.0
        var sk = (r: 0.0, g: 0.0, b: 0.0, n: 0.0)
        let n = w * h
        for i in 0..<n {
            let R = Double(px[i * 4]), G = Double(px[i * 4 + 1]), B = Double(px[i * 4 + 2])
            let Y = 0.2126 * R + 0.7152 * G + 0.0722 * B
            hist[min(255, Int(Y))] += 1
            if max(R, G, B) >= 250 { hi += 1 }
            if Y <= 4 { lo += 1 }
            let mx = max(R, G, B), mn = min(R, G, B)
            let sat = mx > 0 ? (mx - mn) / mx : 0
            satSum += sat
            if Y > 40 && Y < 215 { nG += 1; gA += R - G; gB += (R + G) / 2 - B }
            if sat < 0.25 && Y > 40 && Y < 235 {
                nN += 1
                sumA += R - G
                sumB += (R + G) / 2 - B
            }
            if let mask, mask[i] > 0.5 {
                sk.r += R; sk.g += G; sk.b += B; sk.n += 1
            }
        }
        func pct(_ q: Double) -> Double {
            var acc = 0
            let target = Int(Double(n) * q)
            for (v, c) in hist.enumerated() { acc += c; if acc >= target { return Double(v) / 255 } }
            return 1
        }
        var s = Stats()
        s.p1 = pct(0.01); s.p50 = pct(0.5); s.p99 = pct(0.99)
        s.clipHi = Double(hi) / Double(n) * 100
        s.clipLo = Double(lo) / Double(n) * 100
        s.neutralShare = Double(nN) / Double(n)
        if nN > 0 { s.castA = sumA / Double(nN); s.castB = sumB / Double(nN) }
        if nG > 0 { s.globalA = gA / Double(nG); s.globalB = gB / Double(nG) }
        s.meanSat = satSum / Double(n)
        if sk.n > 30 {
            let R = sk.r / sk.n, G = sk.g / sk.n, B = sk.b / sk.n
            let mx = max(R, G, B), mn = min(R, G, B)
            var hue = 0.0
            if mx > mn {
                if mx == R { hue = 60 * ((G - B) / (mx - mn)) } else if mx == G { hue = 60 * ((B - R) / (mx - mn) + 2) } else { hue = 60 * ((R - G) / (mx - mn) + 4) }
                if hue < 0 { hue += 360 }
            }
            s.skin = ((0.2126 * R + 0.7152 * G + 0.0722 * B) / 255, hue, mx > 0 ? (mx - mn) / mx : 0)
        }
        return s
    }

    /// 交给 ai_edit.py 的测量数据 (文字已经写好, 中文, 给模型看)
    static func forAI(_ s: Stats) -> [String: Any] {
        var m: [String: Any] = ["p1": Int((s.p1 * 100).rounded()), "p50": Int((s.p50 * 100).rounded()), "p99": Int((s.p99 * 100).rounded()),
                                "clip_hi": (s.clipHi * 10).rounded() / 10, "clip_lo": (s.clipLo * 10).rounded() / 10,
                                "sat": Int((s.meanSat * 100).rounded()), "contrast": Int(((s.p99 - s.p1) * 100).rounded())]
        if s.neutralShare > 0.03 {
            var parts: [String] = []
            func level(_ v: Double) -> String { abs(v) > 20 ? "明显" : abs(v) > 10 ? "中等" : "轻微" }
            if abs(s.castB) > 4 { parts.append((s.castB > 0 ? "偏暖偏黄" : "偏冷偏蓝") + " (" + level(s.castB) + ")") }
            if abs(s.castA) > 4 { parts.append((s.castA > 0 ? "偏品红" : "偏绿") + " (" + level(s.castA) + ")") }
            m["cast"] = parts.isEmpty ? "基本中性" : parts.joined(separator: "、")
        }
        // 整体色调: 中性色看起来还好、但整张图明显偏某个颜色时, 偏色可能把灰色也染了 (室内钨丝灯常见)
        if abs(s.globalB) > 25 || abs(s.globalA) > 20 {
            var parts: [String] = []
            if abs(s.globalB) > 25 { parts.append(s.globalB > 0 ? "整体明显偏暖偏黄" : "整体明显偏冷偏蓝") }
            if abs(s.globalA) > 20 { parts.append(s.globalA > 0 ? "整体偏品红" : "整体偏绿") }
            m["global_cast"] = parts.joined(separator: "、") + String(format: " (暖冷 %+.0f, 绿品红 %+.0f)", s.globalB, s.globalA)
        }
        if let k = s.skin {
            var d: [String] = []
            if k.luma < 0.35 { d.append("偏暗") } else if k.luma > 0.82 { d.append("偏亮") }
            if k.hue < 10 || k.hue > 300 { d.append("偏红偏粉") } else if k.hue > 38 { d.append("偏黄") }
            if k.sat < 0.15 { d.append("发灰") } else if k.sat > 0.6 { d.append("太浓") }
            m["skin"] = (d.isEmpty ? "自然" : d.joined(separator: "、")) + String(format: ", 亮度 %d%%, 色相 %d°, 饱和度 %d%%", Int(k.luma * 100), Int(k.hue), Int(k.sat * 100))
        }
        return m
    }

    // MARK: 风光收尾: 按颜色区域量 (Lab), 和专业修图对比后补齐
    /// FiveK 专家 C 修的风光照 (sRGB, Lab 单位): 最暗 5% 的亮度约 8, 植物的彩度约 29, 暖色 (土、石、夕阳) 约 28, 蓝色 (天、水) 约 18.
    /// AI 修完的平均: 暗部 13.6 (发灰)、植物 20、暖色 23 —— 这几项一项一项补, 每一步都检查不会修爆 / 压死.
    struct Regions {
        var L5 = 0.0, clipLo = 0.0, clipHi = 0.0
        var green = (share: 0.0, chroma: 0.0), warm = (share: 0.0, chroma: 0.0), blue = (share: 0.0, chroma: 0.0)
    }

    private static let linLUT: [Double] = (0..<256).map { i in let v = Double(i) / 255; return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }

    static func regions(_ img: CIImage) -> Regions? {
        let r = Renderer.shared
        let small = r.scale(img, maxSide: side)
        let E = small.extent
        let w = Int(E.width), h = Int(E.height)
        guard w > 4, h > 4 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        r.context.render(small, toBitmap: &px, rowBytes: w * 4, bounds: E, format: .RGBA8, colorSpace: r.sRGB)
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        let n = w * h
        var Ls = [Double](); Ls.reserveCapacity(n)
        var g = (0, 0.0), wa = (0, 0.0), b = (0, 0.0), hi = 0, lo = 0
        for i in 0..<n {
            let R = linLUT[Int(px[i * 4])], G = linLUT[Int(px[i * 4 + 1])], B = linLUT[Int(px[i * 4 + 2])]
            if max(px[i * 4], px[i * 4 + 1], px[i * 4 + 2]) >= 250 { hi += 1 }
            let X = (0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.95047, Y = 0.2126 * R + 0.7152 * G + 0.0722 * B, Z = (0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.08883
            let fy = f(Y), L = 116 * fy - 16, a = 500 * (f(X) - fy), bb = 200 * (fy - f(Z))
            Ls.append(L)
            if L < 4 { lo += 1 }
            let C = (a * a + bb * bb).squareRoot()
            guard C > 6 else { continue }
            var hue = atan2(bb, a) * 180 / .pi
            if hue < 0 { hue += 360 }
            if hue > 95 && hue < 200 { g.0 += 1; g.1 += C } else if hue > 200 && hue < 290 { b.0 += 1; b.1 += C } else if hue < 95 || hue > 330 { wa.0 += 1; wa.1 += C }
        }
        Ls.sort()
        var out = Regions()
        out.L5 = Ls[n / 20]
        out.clipLo = Double(lo) / Double(n) * 100; out.clipHi = Double(hi) / Double(n) * 100
        func pair(_ p: (Int, Double)) -> (share: Double, chroma: Double) { (Double(p.0) / Double(n), p.0 > 0 ? p.1 / Double(p.0) : 0) }
        out.green = pair(g); out.warm = pair(wa); out.blue = pair(b)
        return out
    }

    /// 风光收尾: 黑色色阶压到专业水平 (通透), 植物 / 暖色 / 蓝天的颜色补到专业水平 (HSL 饱和度). 只补不减, 每项有上限.
    static func finishLandscape(_ settings: Settings, render: (Settings) -> CIImage?) -> (Settings, String?) {
        guard let start = render(settings).flatMap({ regions($0) }) else { return (settings, nil) }
        var s = settings, cur = start
        var added: [String: Double] = [:]
        let lo0 = start.clipLo, hi0 = start.clipHi
        // (检查条件, 要调的参数和每步的量, 总上限)
        typealias Step = (name: String, need: (Regions) -> Bool, keys: [(String, Double)], cap: Double)
        let steps: [Step] = [
            ("black", { $0.L5 > 10.5 }, [("Blacks2012", -5)], 30),
            ("green", { $0.green.share > 0.04 && $0.green.chroma < 26 }, [("SaturationAdjustmentGreen", 8), ("SaturationAdjustmentYellow", 5)], 40),
            ("warm", { $0.warm.share > 0.04 && $0.warm.chroma < 25 }, [("SaturationAdjustmentOrange", 6), ("SaturationAdjustmentRed", 4)], 30),
            ("blue", { $0.blue.share > 0.04 && $0.blue.chroma < 17 }, [("SaturationAdjustmentBlue", 6), ("SaturationAdjustmentAqua", 4)], 24),
        ]
        for _ in 0..<8 {
            var moved = false
            for st in steps where st.need(cur) && abs(added[st.name] ?? 0) < st.cap {
                var t = s
                for (k, d) in st.keys { t[k] = Params.clamp(k, (s[k] ?? 0) + d) }
                guard let next = render(t).flatMap({ regions($0) }) else { continue }
                if next.clipLo > max(0.6, lo0 * 1.5 + 0.3) || next.clipHi > max(1.0, hi0 * 1.3 + 0.5) { continue }
                s = t; cur = next; moved = true
                added[st.name, default: 0] += abs(st.keys[0].1)
            }
            if !moved { break }
        }
        guard !added.isEmpty else { return (settings, nil) }
        var parts: [String] = []
        if let v = added["black"] { parts.append(String(localized: "暗部更通透（黑色色阶 -\(Int(v))）")) }
        if let v = added["green"] { parts.append(String(localized: "植物更鲜（绿色饱和度 +\(Int(v))）")) }
        if let v = added["warm"] { parts.append(String(localized: "暖色更饱满（橙色饱和度 +\(Int(v))）")) }
        if let v = added["blue"] { parts.append(String(localized: "天空和水更蓝（蓝色饱和度 +\(Int(v))）")) }
        return (s, String(localized: "【风光收尾】") + parts.joined(separator: String(localized: "，")))
    }

    /// 鲜活度检查: 专业修图后的照片比相机原片明显更鲜艳 (FiveK 专家修图: 风光平均饱和度约 46%, 人像约 39%),
    /// AI 往往偏保守. 不够时一小步一小步加「自然饱和度」(它本来就护肤色), 每一步都检查不会修爆、肤色不会太浓.
    /// scene: "landscape" / "portrait" / 其他
    static func guardVividness(_ settings: Settings, scene: String, skin: CIImage?, render: (Settings) -> CIImage?) -> (Settings, String?) {
        let target: Double, maxAdd: Double
        switch scene {
        case "landscape": target = 0.42; maxAdd = 40
        case "portrait": target = 0.36; maxAdd = 20
        default: target = 0.38; maxAdd = 25
        }
        guard let start = render(settings).flatMap({ stats($0, skin: skin) }), start.meanSat < target - 0.03 else { return (settings, nil) }
        var s = settings, cur = start, added = 0.0
        let hi0 = start.clipHi
        while cur.meanSat < target - 0.02 && added < maxAdd {
            var t = s
            t["Vibrance"] = Params.clamp("Vibrance", (s["Vibrance"] ?? 0) + 8)
            guard let next = render(t).flatMap({ stats($0, skin: skin) }) else { break }
            // 不能把高光修爆, 人像的肤色不能太浓
            if next.clipHi > max(1.0, hi0 * 1.3 + 0.5) { break }
            if scene == "portrait", let k = next.skin, k.sat > 0.55 { break }
            s = t; cur = next; added += 8
        }
        guard added > 0 else { return (settings, nil) }
        return (s, String(localized: "【自动检查】") + String(localized: "颜色偏淡，自然饱和度 +\(Int(added))（平均饱和度 \(QualityCard.pct(start.meanSat)) → \(QualityCard.pct(cur.meanSat))）"))
    }

    /// AI 给出的参数会不会把高光修爆、把暗部压死? 会的话一小步一小步往回收 (只管这两样客观的问题).
    /// render: 用一组参数渲染出图. 返回修正后的参数和一句说明
    static func guardClipping(before: Settings, after: Settings, render: (Settings) -> CIImage?) -> (Settings, String?) {
        guard let b0 = render(before).flatMap({ stats($0) }), let a0 = render(after).flatMap({ stats($0) }) else { return (after, nil) }
        var s = after, a = a0
        var notes: [String] = []
        // 高光: 允许比原图多一点 (灯、太阳本来就是白的)
        let hiLimit = max(1.0, b0.clipHi * 1.3 + 0.6)
        var steps = 0
        while a.clipHi > hiLimit && steps < 6 {
            if (s["Highlights2012"] ?? 0) > -70 {
                s["Highlights2012"] = Params.clamp("Highlights2012", (s["Highlights2012"] ?? 0) - 15)
            } else {
                s["Exposure2012"] = Params.clamp("Exposure2012", (s["Exposure2012"] ?? 0) - 0.15)
            }
            if (s["Whites2012"] ?? 0) > 0 { s["Whites2012"] = max(0, (s["Whites2012"] ?? 0) - 10) }
            guard let n = render(s).flatMap({ stats($0) }) else { break }
            a = n; steps += 1
        }
        if steps > 0 { notes.append(String(localized: "高光过曝 \(String(format: "%.1f%%", a0.clipHi)) → \(String(format: "%.1f%%", a.clipHi))")) }
        let loLimit = max(2.0, b0.clipLo * 1.3 + 1.5)
        var lsteps = 0
        let startLo = a.clipLo
        while a.clipLo > loLimit && lsteps < 5 {
            s["Shadows2012"] = Params.clamp("Shadows2012", (s["Shadows2012"] ?? 0) + 10)
            s["Blacks2012"] = Params.clamp("Blacks2012", (s["Blacks2012"] ?? 0) + 6)
            guard let n = render(s).flatMap({ stats($0) }) else { break }
            a = n; lsteps += 1
        }
        if lsteps > 0 { notes.append(String(localized: "暗部死黑 \(String(format: "%.1f%%", startLo)) → \(String(format: "%.1f%%", a.clipLo))")) }
        return (s, notes.isEmpty ? nil : String(localized: "【自动检查】") + notes.joined(separator: "；"))
    }
}
