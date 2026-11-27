import AppKit
import CoreImage
import Foundation
import Vision

// MARK: - HDR 合成: 包围曝光的几张照片 → 一张亮部暗部都有细节的 16 位 TIFF (不需要模型)
// 1. 以中间那张为准, 用 Vision 的图像配准对齐 (手持拍的会有一点位移)
// 2. 每张的相对曝光直接从像素量 (两张都曝光正常的地方亮度之比), 不依赖 EXIF
// 3. 在线性光下合成: 每个像素以「在这张里曝光正常」的程度加权, 过曝和太暗的地方不用
// 4. 色调映射回正常范围 (保留中间调亮度, 高光柔和压缩), 存成 16 位 TIFF 加进列表继续修

enum HDRMerge {
    struct Frame { let url: URL; let image: CIImage }

    enum Failure: Error, LocalizedError {
        case notEnough, cannotRead(String), sameExposure
        var errorDescription: String? {
            switch self {
            case .notEnough: return String(localized: "HDR 合成至少要 2 张包围曝光的照片")
            case .cannotRead(let n): return String(localized: "无法读取 \(n)")
            case .sameExposure: return String(localized: "这几张照片的曝光差不多，不是包围曝光（相差至少要 2/3 档）")
            }
        }
    }

    /// 合成, 返回写好的 TIFF. maxSide 用来测试时缩小
    static func merge(_ urls: [URL], to folder: URL, maxSide: CGFloat? = nil) throws -> URL {
        guard urls.count >= 2 else { throw Failure.notEnough }
        let r = Renderer.shared
        var frames: [CIImage] = []
        for u in urls {
            guard var img = r.loadFull(u) else { throw Failure.cannotRead(u.lastPathComponent) }
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
            if let maxSide { img = r.scale(img, maxSide: maxSide) }
            frames.append(img)
        }
        // 所有照片统一成第一张的大小
        let size = frames[0].extent.size
        frames = frames.map { f in
            f.extent.size == size ? f : f.transformed(by: CGAffineTransform(scaleX: size.width / f.extent.width, y: size.height / f.extent.height))
        }
        let W = Int(size.width), H = Int(size.height)

        // 读成线性的浮点像素
        func pixels(_ img: CIImage) -> [Float] {
            var buf = [Float](repeating: 0, count: W * H * 4)
            r.context.render(img, toBitmap: &buf, rowBytes: W * 16, bounds: CGRect(x: 0, y: 0, width: W, height: H), format: .RGBAf, colorSpace: nil)
            return buf
        }
        // 先按亮度排好顺序, 以中间那张为参考
        let means = frames.map { avgLuma($0) }
        let order = means.indices.sorted { means[$0] < means[$1] }
        let refIdx = order[order.count / 2]

        // 对齐到参考张
        let aligned = frames.enumerated().map { i, f in i == refIdx ? f : align(f, to: frames[refIdx]) }
        let px = aligned.map { pixels($0) }

        // 相对曝光: 两张都曝光正常的像素, 亮度之比的中位数 (参考张 = 1)
        func lum(_ p: [Float], _ i: Int) -> Float { 0.2126 * p[i * 4] + 0.7152 * p[i * 4 + 1] + 0.0722 * p[i * 4 + 2] }
        var scale = [Float](repeating: 1, count: px.count)
        let step = max(1, (W * H) / 200_000)
        for k in px.indices where k != refIdx {
            var ratios: [Float] = []
            var i = 0
            while i < W * H {
                let a = lum(px[k], i), b = lum(px[refIdx], i)
                if a > 0.02 && a < 0.85 && b > 0.02 && b < 0.85 { ratios.append(b / a) }
                i += step
            }
            guard ratios.count > 100 else { continue }
            ratios.sort()
            scale[k] = ratios[ratios.count / 2]
        }
        let spread = (scale.max() ?? 1) / (scale.min() ?? 1)
        guard spread > 1.55 else { throw Failure.sameExposure }   // 至少约 2/3 档

        // 合成 (线性光): 权重 = 这张里曝光正常的程度 (中间调最高, 接近过曝 / 太暗降到 0)
        var out = [Float](repeating: 0, count: W * H * 4)
        DispatchQueue.concurrentPerform(iterations: H) { y in
            for x in 0..<W {
                let i = y * W + x
                var acc: (Float, Float, Float) = (0, 0, 0), wsum: Float = 0
                for k in px.indices {
                    let p = px[k]
                    let mx = max(p[i * 4], p[i * 4 + 1], p[i * 4 + 2])
                    // 帽形权重: 0.003 以下 (噪点) 和 0.92 以上 (快过曝) 不用
                    var w: Float = mx <= 0.003 || mx >= 0.92 ? 0 : 1 - abs(2 * min(1, max(0, (mx - 0.003) / 0.917)) - 1)
                    w = w * w + 1e-4
                    if k == refIdx { w += 1e-3 }   // 都不好时以参考张为准
                    acc.0 += p[i * 4] * scale[k] * w
                    acc.1 += p[i * 4 + 1] * scale[k] * w
                    acc.2 += p[i * 4 + 2] * scale[k] * w
                    wsum += w
                }
                out[i * 4] = acc.0 / wsum; out[i * 4 + 1] = acc.1 / wsum; out[i * 4 + 2] = acc.2 / wsum; out[i * 4 + 3] = 1
            }
        }

        // 色调映射: 亮度用扩展的 Reinhard (白点 = 99.7% 处), 颜色比例不变
        var lums: [Float] = []
        var i = 0
        while i < W * H { lums.append(0.2126 * out[i * 4] + 0.7152 * out[i * 4 + 1] + 0.0722 * out[i * 4 + 2]); i += step }
        lums.sort()
        let white = max(1, lums[min(lums.count - 1, Int(Double(lums.count) * 0.997))])
        let w2 = white * white
        DispatchQueue.concurrentPerform(iterations: H) { y in
            for x in 0..<W {
                let i = y * W + x
                let L = 0.2126 * out[i * 4] + 0.7152 * out[i * 4 + 1] + 0.0722 * out[i * 4 + 2]
                guard L > 1e-6 else { continue }
                let Ld = L * (1 + L / w2) / (1 + L)   // 白点正好到 1: 高光细节全部保留 (中间调会稍暗, 之后提一点曝光就好)
                let k = Ld / L
                out[i * 4] *= k; out[i * 4 + 1] *= k; out[i * 4 + 2] *= k
            }
        }

        let data = out.withUnsafeBufferPointer { Data(buffer: $0) }
        let merged = CIImage(bitmapData: data, bytesPerRow: W * 16, size: size, format: .RGBAf,
                             colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = Exporter.uniqueURL(folder, urls[refIdx].deletingPathExtension().lastPathComponent + "-HDR.tif")
        try r.context.writeTIFFRepresentation(of: merged, to: dest, format: .RGBA16, colorSpace: r.sRGB, options: [:])
        return dest
    }

    private static func avgLuma(_ img: CIImage) -> Double {
        let r = Renderer.shared
        let avg = r.scale(img, maxSide: 256).applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r.scale(img, maxSide: 256).extent)])
        var v = [Float](repeating: 0, count: 4)
        r.context.render(avg, toBitmap: &v, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return Double(0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2])
    }

    /// 用 Vision 的平移配准把 img 对齐到 ref (先把两张调到差不多亮再比, 曝光不同也能对上)
    private static func align(_ img: CIImage, to ref: CIImage) -> CIImage {
        let r = Renderer.shared
        let side: CGFloat = 1024
        let a = r.scale(img, maxSide: side), b = r.scale(ref, maxSide: side)
        let gain = avgLuma(ref) / max(1e-4, avgLuma(img))
        let an = a.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: log2(max(1e-3, gain))])
        guard let ca = r.context.createCGImage(an, from: an.extent, format: .RGBA8, colorSpace: r.sRGB),
              let cb = r.context.createCGImage(b, from: b.extent, format: .RGBA8, colorSpace: r.sRGB) else { return img }
        let req = VNTranslationalImageRegistrationRequest(targetedCGImage: ca)
        guard (try? VNImageRequestHandler(cgImage: cb).perform([req])) != nil, let obs = req.results?.first else { return img }
        let t = obs.alignmentTransform
        let k = img.extent.width / a.extent.width
        let moved = img.transformed(by: CGAffineTransform(translationX: t.tx * k, y: t.ty * k))
        // 移出去的边用边缘像素补上 (最后会被参考张的大小裁掉)
        return moved.clampedToExtent().cropped(to: img.extent)
    }
}

extension Store {
    /// 把选中的包围曝光照片合成 HDR, 结果加进列表
    func mergeHDR() {
        let items = selectedItems
        guard items.count >= 2, !working else { alert = HDRMerge.Failure.notEnough.errorDescription; return }
        working = true
        status = String(localized: "HDR 合成中（\(items.count) 张）…")
        let urls = items.map(\.url)
        let folder = AppPaths.exports.appendingPathComponent("HDR")
        Task {
            defer { working = false }
            let result = await Task.detached { () -> Result<URL, Error> in
                do { return .success(try HDRMerge.merge(urls, to: folder)) } catch { return .failure(error) }
            }.value
            switch result {
            case .success(let url):
                add(urls: [url])
                status = String(localized: "HDR 合成完成：\(url.lastPathComponent)（已加进列表，可以继续修）")
            case .failure(let e):
                alert = e.localizedDescription
                status = ""
            }
        }
    }
}
