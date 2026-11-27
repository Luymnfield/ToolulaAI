import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

// MARK: - 人像精修
// 用 macOS 自带 Vision 的人脸关键点 (眼睛、瞳孔、眉毛、嘴唇、脸部轮廓) 画出各个部位的蒙版,
// 皮肤用「这张脸自己的肤色」做颜色判断 (舞台灯光、偏色的照片也能认出来), 再做专业人像修图常用的几步:
// 保留质感的磨皮 (分频: 只抹平中间频率的斑驳, 毛孔纹理加回去)、去瑕疵 (痘印小斑点, 很深的痣保留)、
// 淡化眼袋、肤色均匀、光影塑形 (加深减淡)、眼睛 / 牙齿 / 嘴唇。

/// 人像精修的各项强度 (0~100, 0 = 不做)
struct PortraitRetouch: Codable, Hashable, Sendable {
    var values: [String: Double] = [:]

    subscript(_ key: String) -> Double {
        get { values[key] ?? 0 }
        set { values[key] = newValue == 0 ? nil : max(0, min(100, newValue)) }
    }
    var isEmpty: Bool { !values.values.contains { $0 != 0 } }
    /// 只能在 Toolula 里渲染、Lightroom 参数表达不了的项目 (像素级修改)
    var hasPixelOnly: Bool { Self.specs.contains { $0.pixelOnly && self[$0.key] != 0 } }

    struct Spec: Identifiable {
        let key: String
        let label: String
        let help: String
        let icon: String
        /// Lightroom 里没有对应的参数 (发送 RAW 时带不过去)
        let pixelOnly: Bool
        var id: String { key }
    }

    static let specs: [Spec] = [
        Spec(key: "smooth", label: "磨皮", help: "柔化皮肤的斑驳和细纹，保留毛孔质感", icon: "drop", pixelOnly: false),
        Spec(key: "blemish", label: "去瑕疵", help: "去掉痘印和小斑点，明显的痣会保留", icon: "bandage", pixelOnly: true),
        Spec(key: "undereye", label: "淡化眼袋", help: "提亮并柔化眼睛下方的阴影", icon: "eye.trianglebadge.exclamationmark", pixelOnly: true),
        Spec(key: "even", label: "肤色均匀", help: "减少泛红和色斑，让肤色更统一", icon: "circle.lefthalf.filled", pixelOnly: true),
        Spec(key: "sculpt", label: "光影塑形", help: "提亮额头、鼻梁、颧骨，压暗脸颊下方和下颌，让脸更立体", icon: "light.max", pixelOnly: true),
        Spec(key: "eyes", label: "眼睛提亮", help: "提亮眼白、让眼神更清澈", icon: "eye", pixelOnly: false),
        Spec(key: "teeth", label: "牙齿美白", help: "去掉牙齿发黄", icon: "mouth", pixelOnly: false),
        Spec(key: "lips", label: "嘴唇气色", help: "让嘴唇颜色更饱满", icon: "heart", pixelOnly: false),
    ]
    static let keys = specs.map(\.key)
}

/// 一张照片的人像分析结果: 各部位蒙版 (灰度, 白 = 选中) 和瑕疵位置. 坐标和 Core Image 一样, 原点在左下
final class PortraitAnalysis: @unchecked Sendable {
    let size: CGSize            // 分析用的图的大小 (蒙版都是这个大小)
    let faceCount: Int
    let faceWidth: CGFloat      // 最大的人脸宽度 (占图宽的比例)
    let faceHeight: CGFloat     // 最大的人脸高度 (占图高的比例)
    let skin: CIImage           // 皮肤 (脸 + 脖子、手臂等露出的皮肤), 不含眼睛眉毛嘴唇
    let sclera: CIImage         // 眼白
    let iris: CIImage           // 虹膜 + 瞳孔
    let lips: CIImage
    let teeth: CIImage
    let underEye: CIImage
    let light: CIImage          // 光影塑形: 要提亮的地方
    let dark: CIImage           // 光影塑形: 要压暗的地方
    /// 瑕疵: 圆心 (0~1, 左下原点) 和半径 (占图宽的比例)
    let spots: [(CGPoint, CGFloat)]

    init(size: CGSize, faceCount: Int, faceWidth: CGFloat, faceHeight: CGFloat, skin: CIImage, sclera: CIImage, iris: CIImage, lips: CIImage,
         teeth: CIImage, underEye: CIImage, light: CIImage, dark: CIImage, spots: [(CGPoint, CGFloat)]) {
        self.size = size; self.faceCount = faceCount; self.faceWidth = faceWidth; self.faceHeight = faceHeight
        self.skin = skin; self.sclera = sclera; self.iris = iris; self.lips = lips; self.teeth = teeth
        self.underEye = underEye; self.light = light; self.dark = dark; self.spots = spots
    }

    /// 眼睛 (眼白 + 虹膜), 给局部调整用
    var eyes: CIImage { sclera.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: iris]) }

    /// 把分析用大小的蒙版放大到 extent
    static func fit(_ m: CIImage, from size: CGSize, to extent: CGRect) -> CIImage {
        m.transformed(by: CGAffineTransform(scaleX: extent.width / size.width, y: extent.height / size.height)
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY)))
            .cropped(to: extent)
    }

    // MARK: 分析

    /// 一张脸的关键点 (分析图的像素坐标, 原点左下)
    struct Face {
        var box: CGRect
        var jaw: [CGPoint]
        var leftEye: [CGPoint], rightEye: [CGPoint]
        var leftPupil: CGPoint?, rightPupil: CGPoint?
        var leftBrow: [CGPoint], rightBrow: [CGPoint]
        var outerLips: [CGPoint], innerLips: [CGPoint]
        var noseCrest: [CGPoint]
        var nose: [CGPoint]
        /// 脸朝上的方向 (下巴 -> 两眼中间), 头歪也对
        var up: CGVector
        var eyesMid: CGPoint
        var chin: CGPoint
        var width: CGFloat { (jaw.map(\.x).max() ?? 0) - (jaw.map(\.x).min() ?? 0) }
    }

    static let analysisSide: CGFloat = 1600

    static func compute(for image: CIImage) -> PortraitAnalysis? {
        let r = Renderer.shared
        let small = r.scale(image, maxSide: analysisSide)
        guard let cg = r.context.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: r.sRGB) else { return nil }
        let W = cg.width, H = cg.height
        let size = CGSize(width: W, height: H)
        let req = VNDetectFaceLandmarksRequest()
        guard (try? VNImageRequestHandler(cgImage: cg).perform([req])) != nil, let obs = req.results, !obs.isEmpty else { return nil }
        let faces = obs.compactMap { face(from: $0, size: size) }.filter { $0.width > CGFloat(W) * 0.015 }
        guard !faces.isEmpty else { return nil }

        // 像素 (第 0 行在最上面)
        guard let px = pixels(cg) else { return nil }
        let person = (personInstances(cg, faces: faces) ?? Masks.person(cg)).flatMap { gray(of: $0, w: W, h: H) }

        // 几何蒙版
        let oval = draw(W, H) { ctx in for f in faces { fill(ctx, ovalPath(f)) } }
        let features = draw(W, H) { ctx in
            for f in faces {
                let ew = eyeWidth(f)
                for eye in [f.leftEye, f.rightEye] where eye.count > 2 {
                    fill(ctx, polygon(eye)); stroke(ctx, polygon(eye), width: ew * 0.22)
                }
                for brow in [f.leftBrow, f.rightBrow] where brow.count > 1 { stroke(ctx, polyline(brow), width: ew * 0.3) }
                if f.outerLips.count > 2 { fill(ctx, polygon(f.outerLips)); stroke(ctx, polygon(f.outerLips), width: ew * 0.08) }
            }
        }

        // 取样区域: 两颊和鼻子 (眼睛下方到嘴巴上方), 不会碰到头发
        let core = draw(W, H) { ctx in
            for f in faces {
                let ew = eyeWidth(f), fh = hypot(f.eyesMid.x - f.chin.x, f.eyesMid.y - f.chin.y)
                ellipse(ctx, center: offset(f.eyesMid, f.up, -fh * 0.38), along: perpendicular(f.up), a: ew * 1.5, b: fh * 0.22)
            }
        }
        // 这张脸自己的肤色 (两颊鼻子去掉五官), 用来判断哪里是皮肤
        var sumCb = 0.0, sumCr = 0.0, sumCb2 = 0.0, sumCr2 = 0.0, sumY = 0.0, sumY2 = 0.0, n = 0.0
        for y in 0..<H {
            let row = H - 1 - y     // oval / features 数组也是第 0 行在最上面
            for x in 0..<W {
                let i = row * W + x
                guard core[i] > 0.9, features[i] < 0.1 else { continue }
                let (yy, cb, cr) = ycc(px, i)
                guard yy > 30 else { continue }
                sumCb += cb; sumCr += cr; sumCb2 += cb * cb; sumCr2 += cr * cr; sumY += yy; sumY2 += yy * yy; n += 1
            }
        }
        guard n > 50 else { return nil }
        let mCb = sumCb / n, mCr = sumCr / n
        let sCb = max(3.5, (sumCb2 / n - mCb * mCb).squareRoot()), sCr = max(3.5, (sumCr2 / n - mCr * mCr).squareRoot())
        // 亮度: 头发和皮肤颜色接近, 但通常暗得多
        let mY = sumY / n, sY0 = max(3, (sumY2 / n - mY * mY).squareRoot()), sY = max(8, sY0)
        let yLow = mY - 2.2 * sY
        // 身体的皮肤 (脖子、肩膀、手臂) 只在人脸附近找: 人物分割会把背对镜头的观众也算进去
        let body = draw(W, H) { ctx in
            for f in faces {
                let fw = f.width, fh = hypot(f.eyesMid.x - f.chin.x, f.eyesMid.y - f.chin.y)
                ellipse(ctx, center: offset(f.chin, f.up, -fh * 2.2), along: perpendicular(f.up), a: fw * 2.6, b: fh * 3.6)
            }
        }

        // 椭圆稍微扩大 (下巴、脖子过渡), 加上人物分割里的其他皮肤 (脖子、肩膀、手臂)
        let ovalSoft = blurred(oval, W, H, radius: max(2, Int(faces.map(\.width).max()! * 0.08)))
        // 纹理: 头发是一丝一丝的 (局部亮度起伏大), 皮肤平滑
        var lumA = [Float](repeating: 0, count: W * H)
        for i in 0..<(W * H) { lumA[i] = Float(ycc(px, i).0) }
        let tr = max(1, Int(faces.map(\.width).max()! * 0.012))
        let mL = boxMean(lumA, W, H, radius: tr), mL2 = boxMean(lumA.map { $0 * $0 }, W, H, radius: tr)
        var skin = [Float](repeating: 0, count: W * H)
        for i in 0..<(W * H) {
            let region = max(ovalSoft[i] * 1.6, (person?[i] ?? 0) * body[i])
            guard region > 0.02 else { continue }
            let (yy, cb, cr) = ycc(px, i)
            guard yy > 22 else { continue }
            let d = (((cb - mCb) / sCb) * ((cb - mCb) / sCb) + ((cr - mCr) / sCr) * ((cr - mCr) / sCr)).squareRoot()
            let bright = max(0, min(1, (yy - yLow) / (0.8 * sY)))
            let sd = Double(max(0, mL2[i] - mL[i] * mL[i])).squareRoot()
            let smooth = max(0, min(1, (3.2 * sY0 - sd) / (1.6 * sY0)))
            let likely = Float(max(0, min(1, 1.6 - d / 2.4)) * bright * smooth)
            skin[i] = min(1, region) * likely * (1 - features[i])
        }

        // 五官
        let sclera = draw(W, H) { ctx in for f in faces { for e in [f.leftEye, f.rightEye] where e.count > 2 { fill(ctx, polygon(e)) } } }
        let iris = draw(W, H) { ctx in
            for f in faces {
                let ew = eyeWidth(f)
                for (e, p) in [(f.leftEye, f.leftPupil), (f.rightEye, f.rightPupil)] where e.count > 2 {
                    guard let p else { continue }
                    ctx.saveGState()
                    ctx.addPath(polygon(e)); ctx.clip()
                    let rr = ew * 0.21
                    ctx.fillEllipse(in: CGRect(x: p.x - rr, y: p.y - rr, width: rr * 2, height: rr * 2))
                    ctx.restoreGState()
                }
            }
        }
        let scleraOnly = zip(sclera, iris).map { max(0, $0 - $1) }
        let mouth = draw(W, H) { ctx in for f in faces where f.innerLips.count > 2 { fill(ctx, polygon(f.innerLips)) } }
        let lips = draw(W, H) { ctx in
            for f in faces where f.outerLips.count > 2 {
                let p = CGMutablePath(); p.addPath(polygon(f.outerLips))
                if f.innerLips.count > 2 { p.addPath(polygon(f.innerLips)) }
                ctx.addPath(p); ctx.fillPath(using: .evenOdd)
            }
        }
        // 牙齿: 嘴里亮、颜色淡的地方
        var teeth = [Float](repeating: 0, count: W * H)
        for y in 0..<H {
            let row = H - 1 - y
            for x in 0..<W {
                let i = row * W + x
                guard mouth[i] > 0.05 else { continue }
                let r0 = Double(px[i * 4]), g0 = Double(px[i * 4 + 1]), b0 = Double(px[i * 4 + 2])
                let mx = max(r0, g0, b0), mn = min(r0, g0, b0)
                let sat = mx > 0 ? (mx - mn) / mx : 0
                let bright = max(0, min(1, (mx - 95) / 50)), pale = max(0, min(1, (0.55 - sat) / 0.25))
                teeth[i] = mouth[i] * Float(bright * pale)
            }
        }
        let underEye = draw(W, H) { ctx in
            for f in faces {
                let ew = eyeWidth(f)
                for e in [f.leftEye, f.rightEye] where e.count > 2 {
                    let c = centroid(e)
                    let center = CGPoint(x: c.x - f.up.dx * ew * 0.42, y: c.y - f.up.dy * ew * 0.42)
                    ellipse(ctx, center: center, along: perpendicular(f.up), a: ew * 0.55, b: ew * 0.26)
                }
            }
            ctx.setFillColor(gray: 0, alpha: 1)
            for f in faces { for e in [f.leftEye, f.rightEye] where e.count > 2 { ctx.addPath(polygon(e)); ctx.fillPath() } }
        }
        // 光影塑形: 提亮额头中间、鼻梁、颧骨上方、下巴; 压暗颧骨下方的凹陷、下颌两侧、太阳穴
        let light = draw(W, H) { ctx in
            for f in faces {
                let fw = f.width, fh = hypot(f.eyesMid.x - f.chin.x, f.eyesMid.y - f.chin.y)
                let side = perpendicular(f.up)
                soft(ctx, offset(f.eyesMid, f.up, fh * 0.4), radius: fw * 0.17)
                if f.noseCrest.count > 1 { ctx.setLineCap(.round); stroke(ctx, polyline(f.noseCrest), width: fw * 0.07) }
                soft(ctx, offset(f.chin, f.up, fh * 0.12), radius: fw * 0.09)
                for s in [-1.0, 1.0] {
                    let p = offset(offset(f.eyesMid, side, CGFloat(s) * fw * 0.24), f.up, -fh * 0.22)
                    soft(ctx, p, radius: fw * 0.1)
                }
            }
        }
        let dark = draw(W, H) { ctx in
            for f in faces {
                let fw = f.width, fh = hypot(f.eyesMid.x - f.chin.x, f.eyesMid.y - f.chin.y)
                let side = perpendicular(f.up)
                for s in [-1.0, 1.0] {
                    soft(ctx, offset(offset(f.eyesMid, side, CGFloat(s) * fw * 0.36), f.up, -fh * 0.55), radius: fw * 0.12)   // 颧骨下方
                    soft(ctx, offset(offset(f.chin, side, CGFloat(s) * fw * 0.33), f.up, fh * 0.15), radius: fw * 0.11)       // 下颌两侧
                    soft(ctx, offset(offset(f.eyesMid, side, CGFloat(s) * fw * 0.47), f.up, fh * 0.3), radius: fw * 0.08)     // 太阳穴
                }
            }
        }

        // 瑕疵: 每张脸单独放大到宽 600 像素再找 (小斑点在整张图上只有一两个像素)
        var spots: [(CGPoint, CGFloat)] = []
        for f in faces { spots += findSpots(f, image: image, analysisSize: size, mCb: mCb, mCr: mCr, sCb: sCb, sCr: sCr, yLow: yLow + 0.4 * sY) }

        let feather = Double(max(1, faces.map(\.width).max()! * 0.006))
        func ci(_ a: [Float], blur: Double) -> CIImage { maskImage(a, W, H, blur: blur) }
        let big = faces.max { $0.width < $1.width }!
        return PortraitAnalysis(size: size, faceCount: faces.count, faceWidth: big.width / CGFloat(W), faceHeight: big.box.height / CGFloat(H),
                                skin: ci(skin, blur: feather * 1.5), sclera: ci(scleraOnly, blur: feather * 0.5), iris: ci(iris, blur: feather * 0.5),
                                lips: ci(lips, blur: feather * 0.6), teeth: ci(teeth, blur: feather * 0.4), underEye: ci(underEye, blur: feather * 4),
                                light: ci(light, blur: feather * 8), dark: ci(dark, blur: feather * 8), spots: spots)
    }

    // MARK: 瑕疵

    private static func findSpots(_ f: Face, image: CIImage, analysisSize: CGSize, mCb: Double, mCr: Double, sCb: Double, sCr: Double, yLow: Double) -> [(CGPoint, CGFloat)] {
        let r = Renderer.shared
        let E = image.extent
        let sx = E.width / analysisSize.width, sy = E.height / analysisSize.height
        // 脸在原图上的范围
        let oval = ovalPath(f).boundingBox
        let region = CGRect(x: E.minX + oval.minX * sx, y: E.minY + oval.minY * sy, width: oval.width * sx, height: oval.height * sy)
            .insetBy(dx: -oval.width * sx * 0.05, dy: -oval.height * sy * 0.05).intersection(E)
        guard region.width > 80 else { return [] }      // 脸太小, 找不到也没必要
        let target: CGFloat = 600
        let k = min(1, target / region.width)            // 不放大, 只缩小
        let crop = image.cropped(to: region).transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
        guard let cg = r.context.createCGImage(crop, from: CGRect(x: 0, y: 0, width: floor(region.width * k), height: floor(region.height * k)),
                                               format: .RGBA8, colorSpace: r.sRGB), let px = pixels(cg) else { return [] }
        let w = cg.width, h = cg.height
        // 分析图坐标 -> 裁切图坐标
        let toCrop = CGAffineTransform(translationX: -(region.minX - E.minX) / sx, y: -(region.minY - E.minY) / sy)
            .concatenating(CGAffineTransform(scaleX: sx * k, y: sy * k))
        let ew = eyeWidth(f) * sx * k
        let ovalM = draw(w, h) { ctx in ctx.concatenate(toCrop); fill(ctx, ovalPath(f)) }
        let feat = draw(w, h) { ctx in
            ctx.concatenate(toCrop)
            let e0 = eyeWidth(f)
            for eye in [f.leftEye, f.rightEye] where eye.count > 2 { fill(ctx, polygon(eye)); stroke(ctx, polygon(eye), width: e0 * 0.6) }
            for brow in [f.leftBrow, f.rightBrow] where brow.count > 1 { stroke(ctx, polyline(brow), width: e0 * 0.5) }
            if f.outerLips.count > 2 { fill(ctx, polygon(f.outerLips)); stroke(ctx, polygon(f.outerLips), width: e0 * 0.35) }
            // 鼻子两侧的阴影和鼻孔 (是轮廓, 不是瑕疵)
            if f.nose.count > 2 { fill(ctx, polygon(f.nose)); stroke(ctx, polygon(f.nose), width: e0 * 0.35) }
            if f.noseCrest.count > 1, let tip = f.noseCrest.last {
                // 鼻孔一带 (很暗, 不是瑕疵)
                ctx.fillEllipse(in: CGRect(x: tip.x - e0 * 0.55, y: tip.y - e0 * 0.45, width: e0 * 1.1, height: e0 * 0.6))
            }
        }
        // 只在脸部椭圆收缩一点的范围里找 (发际线、脸的边缘不算)
        let inner = eroded(ovalM, w, h, radius: max(2, Int(ew * 0.25)))
        var lum = [Float](repeating: 0, count: w * h), cr = [Float](repeating: 0, count: w * h)
        var skinOK = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) {
            let (yy, cb, crv) = ycc(px, i)
            lum[i] = Float(yy); cr[i] = Float(crv)
            let d = (((cb - mCb) / sCb) * ((cb - mCb) / sCb) + ((crv - mCr) / sCr) * ((crv - mCr) / sCr)).squareRoot()
            skinOK[i] = d < 3.5 && yy > yLow
        }
        let rad = max(4, Int(Double(w) * 0.022))
        let meanL = boxMean(lum, w, h, radius: rad), meanCr = boxMean(cr, w, h, radius: rad)
        // 周围几乎都是皮肤才算 (发丝、发际线、衣服边缘附近不找)
        let skinFrac = boxMean(skinOK.map { $0 ? 1 : 0 }, w, h, radius: rad)
        var cand = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) where inner[i] > 0.5 && feat[i] < 0.1 && skinFrac[i] > 0.85 {
            let m = max(1, meanL[i])
            let darker = (m - lum[i]) / m
            let redder = cr[i] - meanCr[i]
            // 比周围暗一些、或者明显更红; 特别暗的 (痣) 不算
            if (darker > 0.075 && darker < 0.34) || (redder > 7 && darker > 0.01 && darker < 0.34) { cand[i] = true }
        }
        // 连通区域, 按大小筛选
        let minA = max(3, Int(Double(w * w) * 0.000012)), maxA = Int(Double(w * w) * 0.0011)
        var seen = [Bool](repeating: false, count: w * h)
        var out: [(CGPoint, CGFloat)] = []
        let inv = toCrop.inverted()
        for start in 0..<(w * h) where cand[start] && !seen[start] {
            var stack = [start], area = 0, sx0 = 0, sy0 = 0, minX = Int.max, maxX = 0, minY = Int.max, maxY = 0
            seen[start] = true
            while let i = stack.popLast() {
                area += 1
                let x = i % w, y = i / w
                sx0 += x; sy0 += y; minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let j = ny * w + nx
                    if cand[j] && !seen[j] { seen[j] = true; stack.append(j) }
                }
                if area > maxA * 2 { break }
            }
            guard area >= minA, area <= maxA else { continue }
            // 细长的 (皱纹、发丝、阴影边缘) 不算
            let bw = maxX - minX + 1, bh = maxY - minY + 1
            guard Double(max(bw, bh)) / Double(max(1, min(bw, bh))) < 3 else { continue }
            let cx = Double(sx0) / Double(area), cyTop = Double(sy0) / Double(area)
            let pCrop = CGPoint(x: cx, y: Double(h) - 1 - cyTop)          // 数组第 0 行在最上面 -> 左下原点
            let pA = pCrop.applying(inv)                                    // 分析图坐标
            let radius = (Double(area) / .pi).squareRoot() * 1.9 / Double(k)  // 原图像素 (含一圈过渡)
            out.append((CGPoint(x: pA.x / analysisSize.width, y: pA.y / analysisSize.height), CGFloat(radius) / E.width))
            if out.count >= 160 { break }
        }
        return out
    }

    /// 只要人脸所在的那几个人 (人物实例分割), 背对镜头的观众等不算. 系统不支持时返回 nil
    private static func personInstances(_ cg: CGImage, faces: [Face]) -> CIImage? {
        let req = VNGeneratePersonInstanceMaskRequest()
        let h = VNImageRequestHandler(cgImage: cg)
        guard (try? h.perform([req])) != nil, let obs = req.results?.first else { return nil }
        let labels = obs.instanceMask
        CVPixelBufferLockBaseAddress(labels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(labels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(labels) else { return nil }
        let lw = CVPixelBufferGetWidth(labels), lh = CVPixelBufferGetHeight(labels), stride = CVPixelBufferGetBytesPerRow(labels)
        var keep = IndexSet()
        for f in faces {
            // 两眼中间和下巴之间取几个点 (像素坐标左下原点 -> 标签图第 0 行在最上面)
            for t in [0.0, 0.3, 0.6] {
                let p = CGPoint(x: f.eyesMid.x + (f.chin.x - f.eyesMid.x) * t, y: f.eyesMid.y + (f.chin.y - f.eyesMid.y) * t)
                let x = min(lw - 1, max(0, Int(p.x / CGFloat(cg.width) * CGFloat(lw))))
                let y = min(lh - 1, max(0, Int((1 - p.y / CGFloat(cg.height)) * CGFloat(lh))))
                let v = base.load(fromByteOffset: y * stride + x, as: UInt8.self)
                if v > 0 { keep.insert(Int(v)) }
            }
        }
        guard !keep.isEmpty, let pb = try? obs.generateScaledMaskForImage(forInstances: keep, from: h) else { return nil }
        return CIImage(cvPixelBuffer: pb)
    }

    // MARK: 关键点

    private static func face(from o: VNFaceObservation, size: CGSize) -> Face? {
        guard let lm = o.landmarks else { return nil }
        func pts(_ r: VNFaceLandmarkRegion2D?) -> [CGPoint] { r?.pointsInImage(imageSize: size) ?? [] }
        let jaw = pts(lm.faceContour)
        guard jaw.count >= 5 else { return nil }
        let le = pts(lm.leftEye), re = pts(lm.rightEye)
        guard le.count > 2, re.count > 2 else { return nil }
        let eyesMid = CGPoint(x: (centroid(le).x + centroid(re).x) / 2, y: (centroid(le).y + centroid(re).y) / 2)
        // 下巴: 轮廓上离两眼中间最远的点
        let chin = jaw.max { hypot($0.x - eyesMid.x, $0.y - eyesMid.y) < hypot($1.x - eyesMid.x, $1.y - eyesMid.y) }!
        let len = max(1, hypot(eyesMid.x - chin.x, eyesMid.y - chin.y))
        let up = CGVector(dx: (eyesMid.x - chin.x) / len, dy: (eyesMid.y - chin.y) / len)
        let b = o.boundingBox
        return Face(box: CGRect(x: b.minX * size.width, y: b.minY * size.height, width: b.width * size.width, height: b.height * size.height),
                    jaw: jaw, leftEye: le, rightEye: re, leftPupil: pts(lm.leftPupil).first, rightPupil: pts(lm.rightPupil).first,
                    leftBrow: pts(lm.leftEyebrow), rightBrow: pts(lm.rightEyebrow), outerLips: pts(lm.outerLips), innerLips: pts(lm.innerLips),
                    noseCrest: pts(lm.noseCrest), nose: pts(lm.nose), up: up, eyesMid: eyesMid, chin: chin)
    }

    /// 脸部椭圆: 下颌轮廓 + 往上补出额头
    private static func ovalPath(_ f: Face) -> CGPath {
        let p = CGMutablePath()
        guard let first = f.jaw.first, let last = f.jaw.last else { return p }
        p.addLines(between: f.jaw)
        let m = CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2)
        let half = CGVector(dx: (last.x - m.x), dy: (last.y - m.y))
        let fh = hypot(f.eyesMid.x - f.chin.x, f.eyesMid.y - f.chin.y)
        // 额头高度: 从下颌轮廓两端的中点往上
        let top = max(fh * 0.95, hypot(f.eyesMid.x - m.x, f.eyesMid.y - m.y) + fh * 0.6)
        for i in 0...16 {
            let t = Double(i) / 16 * .pi
            p.addLine(to: CGPoint(x: m.x + half.dx * CGFloat(cos(t)) + f.up.dx * top * CGFloat(sin(t)),
                                  y: m.y + half.dy * CGFloat(cos(t)) + f.up.dy * top * CGFloat(sin(t))))
        }
        p.closeSubpath()
        return p
    }

    private static func eyeWidth(_ f: Face) -> CGFloat {
        func w(_ e: [CGPoint]) -> CGFloat {
            var best: CGFloat = 0
            for a in e { for b in e { best = max(best, hypot(a.x - b.x, a.y - b.y)) } }
            return best
        }
        return max(2, (w(f.leftEye) + w(f.rightEye)) / 2)
    }

    // MARK: 画图 / 像素小工具

    private static func centroid(_ p: [CGPoint]) -> CGPoint {
        CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(max(1, p.count)), y: p.map(\.y).reduce(0, +) / CGFloat(max(1, p.count)))
    }
    private static func perpendicular(_ v: CGVector) -> CGVector { CGVector(dx: v.dy, dy: -v.dx) }
    private static func offset(_ p: CGPoint, _ v: CGVector, _ d: CGFloat) -> CGPoint { CGPoint(x: p.x + v.dx * d, y: p.y + v.dy * d) }
    private static func polygon(_ p: [CGPoint]) -> CGPath { let m = CGMutablePath(); m.addLines(between: p); m.closeSubpath(); return m }
    private static func polyline(_ p: [CGPoint]) -> CGPath { let m = CGMutablePath(); m.addLines(between: p); return m }
    private static func fill(_ ctx: CGContext, _ p: CGPath) { ctx.addPath(p); ctx.fillPath() }
    private static func stroke(_ ctx: CGContext, _ p: CGPath, width: CGFloat) {
        ctx.setLineWidth(width); ctx.setLineJoin(.round); ctx.addPath(p); ctx.strokePath()
    }
    private static func ellipse(_ ctx: CGContext, center: CGPoint, along: CGVector, a: CGFloat, b: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: atan2(along.dy, along.dx))
        ctx.fillEllipse(in: CGRect(x: -a, y: -b, width: a * 2, height: b * 2))
        ctx.restoreGState()
    }
    /// 中心最亮、往外渐暗的圆
    private static func soft(_ ctx: CGContext, _ c: CGPoint, radius: CGFloat) {
        let space = CGColorSpaceCreateDeviceGray()
        guard let g = CGGradient(colorSpace: space, colorComponents: [1, 1, 0, 1], locations: [0, 1], count: 2) else { return }
        ctx.saveGState()
        ctx.setBlendMode(.lighten)
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
        ctx.restoreGState()
    }

    /// 画一张 w×h 的灰度图, 返回 0~1 数组 (第 0 行在最上面)
    private static func draw(_ w: Int, _ h: Int, _ body: (CGContext) -> Void) -> [Float] {
        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.setStrokeColor(gray: 1, alpha: 1)
            ctx.setShouldAntialias(true)
            body(ctx)
        }
        return bytes.map { Float($0) / 255 }
    }

    private static func pixels(_ cg: CGImage) -> [UInt8]? {
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? px : nil
    }

    /// 灰度 CIImage 缩到 w×h 的数组 (第 0 行在最上面)
    private static func gray(of m: CIImage, w: Int, h: Int) -> [Float]? {
        let scaled = m.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / m.extent.width, y: CGFloat(h) / m.extent.height)
            .concatenating(CGAffineTransform(translationX: -m.extent.minX * CGFloat(w) / m.extent.width, y: -m.extent.minY * CGFloat(h) / m.extent.height)))
        var out = [Float](repeating: 0, count: w * h)
        Renderer.shared.context.render(scaled, toBitmap: &out, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .Rf, colorSpace: nil)
        return out
    }

    @inline(__always) private static func ycc(_ px: [UInt8], _ i: Int) -> (Double, Double, Double) {
        let r = Double(px[i * 4]), g = Double(px[i * 4 + 1]), b = Double(px[i * 4 + 2])
        return (0.299 * r + 0.587 * g + 0.114 * b, 128 - 0.168736 * r - 0.331264 * g + 0.5 * b, 128 + 0.5 * r - 0.418688 * g - 0.081312 * b)
    }

    /// 方框平均 (积分图)
    private static func boxMean(_ a: [Float], _ w: Int, _ h: Int, radius r: Int) -> [Float] {
        var sat = [Double](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row = 0.0
            for x in 0..<w {
                row += Double(a[y * w + x])
                sat[(y + 1) * (w + 1) + x + 1] = sat[y * (w + 1) + x + 1] + row
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let y0 = max(0, y - r), y1 = min(h, y + r + 1)
            for x in 0..<w {
                let x0 = max(0, x - r), x1 = min(w, x + r + 1)
                let s = sat[y1 * (w + 1) + x1] - sat[y0 * (w + 1) + x1] - sat[y1 * (w + 1) + x0] + sat[y0 * (w + 1) + x0]
                out[y * w + x] = Float(s / Double((x1 - x0) * (y1 - y0)))
            }
        }
        return out
    }
    private static func blurred(_ a: [Float], _ w: Int, _ h: Int, radius: Int) -> [Float] { boxMean(boxMean(a, w, h, radius: radius / 2), w, h, radius: radius / 2) }
    /// 收缩: 周围都是 1 才保留
    private static func eroded(_ a: [Float], _ w: Int, _ h: Int, radius: Int) -> [Float] { boxMean(a, w, h, radius: radius).map { $0 > 0.97 ? 1 : 0 } }

    /// 数组 (第 0 行在最上面) -> CIImage (左下原点), 可选羽化
    private static func maskImage(_ a: [Float], _ w: Int, _ h: Int, blur: Double) -> CIImage {
        let bytes = a.map { UInt8(max(0, min(255, $0 * 255))) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: w, height: h)) }
        let m = CIImage(cgImage: cg)
        guard blur > 0.3 else { return m }
        return m.clampedToExtent().applyingGaussianBlur(sigma: blur).cropped(to: m.extent)
    }
}

// MARK: - 渲染

extension Renderer {
    /// 在已经调好色的图上做人像精修. analysis 是同一张照片的分析结果 (任何大小都行, 会按比例对齐)
    func applyPortrait(_ p: PortraitRetouch, to img: CIImage, analysis a: PortraitAnalysis) -> CIImage {
        guard !p.isEmpty else { return img }
        let E = img.extent
        func fit(_ m: CIImage) -> CIImage { PortraitAnalysis.fit(m, from: a.size, to: E) }
        func k(_ key: String) -> Double { p[key] / 100 }
        func blend(_ top: CIImage, over bottom: CIImage, mask: CIImage, amount: Double = 1) -> CIImage {
            var m = mask
            if amount < 0.999 { m = m.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0),
                                                                                   "inputGVector": CIVector(x: 0, y: amount, z: 0, w: 0),
                                                                                   "inputBVector": CIVector(x: 0, y: 0, z: amount, w: 0)]) }
            return top.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: bottom, kCIInputMaskImageKey: m]).cropped(to: E)
        }
        func blur(_ i: CIImage, _ s: Double) -> CIImage { i.clampedToExtent().applyingGaussianBlur(sigma: s).cropped(to: E) }
        func scaled(_ i: CIImage, _ s: Double, alpha: Bool = false) -> CIImage {
            i.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: s, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: s, z: 0, w: 0),
                                                           "inputBVector": CIVector(x: 0, y: 0, z: s, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha ? 1 : 0)])
        }
        func add(_ a0: CIImage, _ b0: CIImage) -> CIImage { a0.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: b0]).cropped(to: E) }

        let skin = fit(a.skin)
        let faceW = Double(a.faceWidth * E.width)
        var out = img

        // 皮肤平均颜色 (调色之后的), 用来填充皮肤以外的地方, 磨皮时不会把头发眼睛的颜色糊进皮肤
        let mean = averageColor(out, mask: skin)
        let meanImg = CIImage(color: mean).cropped(to: E)

        // 1. 肤色均匀: 皮肤往平均肤色靠 (亮度不变)
        if k("even") > 0 {
            let lm = 0.2126 * Double(mean.red) + 0.7152 * Double(mean.green) + 0.0722 * Double(mean.blue)
            if lm > 0.001 {
                let cr = Double(mean.red) / lm, cg = Double(mean.green) / lm, cb = Double(mean.blue) / lm
                let tinted = out.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.2126 * cr, y: 0.7152 * cr, z: 0.0722 * cr, w: 0),
                    "inputGVector": CIVector(x: 0.2126 * cg, y: 0.7152 * cg, z: 0.0722 * cg, w: 0),
                    "inputBVector": CIVector(x: 0.2126 * cb, y: 0.7152 * cb, z: 0.0722 * cb, w: 0)]).cropped(to: E)
                // 只换低频的颜色: 细节 (毛孔) 的颜色保留
                let fineSig = max(0.8, faceW * 0.006)
                let detail = add(out, scaled(blur(out, fineSig), -1))
                let lowTinted = add(blur(tinted, fineSig), detail)
                out = blend(lowTinted, over: out, mask: skin, amount: k("even") * 0.4)
            }
        }

        // 2. 磨皮 (分频): 细纹理 = 原图 - 小半径模糊; 斑驳 = 大半径模糊; 结果 = 大半径模糊 + 细纹理
        let sigF = max(0.7, faceW * 0.0035), sigM = max(2, faceW * 0.022)
        let fine = add(out, scaled(blur(out, sigF), -1))
        let base = blur(blend(out, over: meanImg, mask: skin), sigM)
        let smoothed = add(base, fine)
        if k("smooth") > 0 { out = blend(smoothed, over: out, mask: skin, amount: k("smooth") * 0.75) }

        // 3. 去瑕疵: 每个斑点用周围的皮肤补上, 加回一点细纹理
        if k("blemish") > 0, !a.spots.isEmpty {
            let radii = a.spots.map { Double($0.1) * E.width }.sorted()
            let heal = add(blur(blend(out, over: meanImg, mask: skin), max(1.5, radii[radii.count / 2] * 1.3)), scaled(fine, 0.5))
            if let spotMask = spotMask(a.spots, extent: E) { out = blend(heal, over: out, mask: spotMask, amount: min(1, k("blemish") * 1.15)) }
        }

        // 4. 淡化眼袋: 提亮 + 柔化
        if k("undereye") > 0 {
            let lifted = add(blur(blend(out, over: meanImg, mask: skin), sigM * 0.8), scaled(fine, 0.85))
                .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.45 * k("undereye")]).cropped(to: E)
            let m = fit(a.underEye).applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: skin]).cropped(to: E)
            out = blend(lifted, over: out, mask: m, amount: min(1, k("undereye") * 1.1))
        }

        // 5. 光影塑形: 线性空间里乘一个增益 (1 + 提亮 - 压暗), 只在皮肤上
        if k("sculpt") > 0 {
            let s = k("sculpt")
            let lightM = fit(a.light).applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: skin]).cropped(to: E)
            let darkM = fit(a.dark).applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: skin]).cropped(to: E)
            let one = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: E)
            let gain = add(add(one, scaled(lightM, 0.32 * s)), scaled(darkM, -0.3 * s))
            out = out.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: gain]).cropped(to: E)
        }

        // 6. 五官 (用普通的调整参数, 只作用在对应部位)
        func local(_ settings: Settings, _ mask: CIImage) {
            out = blend(apply(settings, to: out), over: out, mask: fit(mask))
        }
        if k("eyes") > 0 {
            let e = k("eyes")
            local(["Exposure2012": 0.35 * e, "Saturation": -35 * e], a.sclera)
            local(["Exposure2012": 0.2 * e, "Clarity2012": 40 * e, "Saturation": 10 * e], a.iris)
        }
        if k("teeth") > 0 {
            let t = k("teeth")
            local(["Exposure2012": 0.25 * t, "Saturation": -60 * t, "IncrementalTemperature": -12 * t], a.teeth)
        }
        if k("lips") > 0 {
            let l = k("lips")
            local(["Saturation": 30 * l, "Contrast2012": 12 * l], a.lips)
        }
        return out.cropped(to: E)
    }

    /// 蒙版范围内的平均颜色 (工作色彩空间)
    func averageColor(_ img: CIImage, mask: CIImage) -> CIColor {
        let E = img.extent
        let masked = img.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: mask]).cropped(to: E)
        func avg(_ i: CIImage) -> [Float] {
            var v = [Float](repeating: 0, count: 4)
            let a = i.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: E)])
            context.render(a, toBitmap: &v, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            return v
        }
        let c = avg(masked), m = avg(mask)
        let d = max(0.0001, m[0])
        return CIColor(red: CGFloat(c[0] / d), green: CGFloat(c[1] / d), blue: CGFloat(c[2] / d), alpha: 1,
                       colorSpace: context.workingColorSpace ?? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!) ?? CIColor(red: 0.5, green: 0.4, blue: 0.35)
    }

    /// 瑕疵位置画成蒙版 (最长边不超过 3000 像素, 再放大)
    private func spotMask(_ spots: [(CGPoint, CGFloat)], extent E: CGRect) -> CIImage? {
        let s = min(1, 3000 / max(E.width, E.height))
        let w = Int(E.width * s), h = Int(E.height * s)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let g = CGGradient(colorSpace: CGColorSpaceCreateDeviceGray(), colorComponents: [1, 1, 1, 1, 0, 1], locations: [0, 0.55, 1], count: 3)
        else { return nil }
        ctx.setBlendMode(.lighten)
        for (c, r) in spots {
            let p = CGPoint(x: c.x * CGFloat(w), y: c.y * CGFloat(h))
            ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: max(1, r * CGFloat(w)), options: [])
        }
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: E.width / CGFloat(w), y: E.height / CGFloat(h))
            .concatenating(CGAffineTransform(translationX: E.minX, y: E.minY))).cropped(to: E)
    }
}
