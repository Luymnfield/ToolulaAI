import CoreImage
import CoreML
import Foundation

// MARK: - 语义分割: 照片里每个像素是什么 (天空、水面、山、建筑、树、草地…)
// 模型: Apple 发布的 DETR ResNet-50 语义分割 Core ML 版 (Apache-2.0, 85 MB, COCO 全景分割的类别), 第一次用时下载.
// 输入 448×448, 输出每个像素的类别编号; 放大回原图时羽化边缘.

final class SceneSegmenter: @unchecked Sendable {
    static let shared = SceneSegmenter()
    static let side = 448
    private var model: MLModel?
    private var labels: [String] = []
    private let lock = NSLock()

    static var dir: URL { AppPaths.models.appendingPathComponent("Segmentation") }
    static var compiled: URL { dir.appendingPathComponent("DETRSemantic.mlmodelc") }
    static var installed: Bool { FileManager.default.fileExists(atPath: compiled.path) }
    static let files = ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"]
    static let repo = "https://huggingface.co/apple/coreml-detr-semantic-segmentation/resolve/main/DETRResnet50SemanticSegmentationF16.mlpackage/"
    static let sizeMB = 85

    /// 每个区域对应的类别 (COCO 全景分割的名字)
    static let groups: [MaskKind: Set<String>] = [
        .sky: ["sky (other)"],
        .water: ["sea", "river", "water (other)"],
        .mountains: ["mountain", "rock"],
        .buildings: ["building (other)", "house", "roof", "bridge", "wall (brick)", "wall (stone)"],
    ]
    /// 给 AI 的画面构成 (名字, 类别)
    static let sceneParts: [(String, Set<String>)] = [
        ("天空", ["sky (other)"]), ("山", ["mountain", "rock"]), ("水面", ["sea", "river", "water (other)"]),
        ("树木", ["tree"]), ("草地", ["grass", "dirt", "sand", "gravel"]), ("雪", ["snow"]),
        ("建筑", ["building (other)", "house", "roof", "bridge"]), ("人", ["person"]),
    ]

    /// 下载 (85 MB) 并编译; 已经装好就直接加载
    func ensureModel(progress: @escaping @Sendable (Int64) -> Void) async throws -> MLModel {
        if let m = lock.withLock({ model }) { return m }
        if !Self.installed {
            let pkg = Self.dir.appendingPathComponent("DETRSemantic.mlpackage")
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
        return try load()
    }

    /// 已经装好时同步加载 (没装返回 nil)
    func loadedModel() -> MLModel? {
        if let m = lock.withLock({ model }) { return m }
        guard Self.installed else { return nil }
        return try? load()
    }

    private func load() throws -> MLModel {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        let m = try MLModel(contentsOf: Self.compiled, configuration: cfg)
        // 类别名字写在模型的说明里
        var names: [String] = []
        if let meta = m.modelDescription.metadata[.creatorDefinedKey] as? [String: String],
           let params = meta["com.apple.coreml.model.preview.params"], let data = params.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let l = obj["labels"] as? [String] {
            names = l
        }
        lock.withLock { model = m; labels = names }
        return m
    }

    /// 每个像素的类别编号 (448×448, 第 0 行在最上面). 照片直接拉伸成正方形送进去 (不裁掉边)
    func classes(_ cg: CGImage) -> [Int32]? {
        guard let m = loadedModel() else { return nil }
        let opts: [MLFeatureValue.ImageOption: Any] = [.cropAndScale: 2]   // 2 = scaleFill (拉伸, 不裁)
        guard let input = try? MLFeatureValue(cgImage: cg, pixelsWide: Self.side, pixelsHigh: Self.side, pixelFormatType: kCVPixelFormatType_32BGRA, options: opts),
              let provider = try? MLDictionaryFeatureProvider(dictionary: ["image": input]),
              let out = try? m.prediction(from: provider),
              let arr = out.featureValue(for: "semanticPredictions")?.multiArrayValue else { return nil }
        let n = Self.side * Self.side
        var result = [Int32](repeating: 0, count: n)
        for i in 0..<min(n, arr.count) { result[i] = arr[i].int32Value }
        return result
    }

    func labelIds(_ names: Set<String>) -> Set<Int32> {
        let l = lock.withLock { labels }
        return Set(l.enumerated().filter { names.contains($0.element) }.map { Int32($0.offset) })
    }

    /// 某一类区域的蒙版 (原图大小, 羽化过); 几乎没有就返回 nil
    func mask(_ kind: MaskKind, classes c: [Int32], size: CGSize) -> CIImage? {
        guard let names = Self.groups[kind] else { return nil }
        let ids = labelIds(names)
        guard !ids.isEmpty else { return nil }
        var bytes = [UInt8](repeating: 0, count: c.count)
        var count = 0
        for i in c.indices where ids.contains(c[i]) { bytes[i] = 255; count += 1 }
        guard Double(count) / Double(c.count) > 0.01 else { return nil }
        let s = Self.side
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let mcg = CGImage(width: s, height: s, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: s, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let m = CIImage(cgImage: mcg).clampedToExtent().applyingGaussianBlur(sigma: 1.2).cropped(to: CGRect(x: 0, y: 0, width: s, height: s))
        return m.transformed(by: CGAffineTransform(scaleX: size.width / CGFloat(s), y: size.height / CGFloat(s)))
    }

    /// 画面构成 (每一类占多少), 给 AI 看
    func composition(_ c: [Int32]) -> [(String, Int)] {
        Self.sceneParts.compactMap { name, set in
            let ids = labelIds(set)
            let n = c.reduce(0) { $0 + (ids.contains($1) ? 1 : 0) }
            let pct = Int((Double(n) / Double(c.count) * 100).rounded())
            return pct >= 3 ? (name, pct) : nil
        }
    }
}

extension Store {
    /// 下载语义分割模型 (Apple 的 DETR, 85 MB). 下好以后水面、山、建筑在 Toolula 里也能单独调
    func downloadSegmenter() {
        guard !working else { return }
        working = true
        status = String(localized: "下载语义分割模型…")
        Task {
            defer { working = false }
            do {
                _ = try await Task.detached {
                    try await SceneSegmenter.shared.ensureModel { got in
                        Task { @MainActor in self.status = String(localized: "下载语义分割模型：\(SystemInfo.size(got)) / 85 MB") }
                    }
                }.value
                status = String(localized: "语义分割模型已装好：水面、山、建筑现在在 Toolula 里也能调")
                for p in photos { p.changed() }
            } catch {
                alert = String(localized: "下载失败：\(error.localizedDescription)")
                status = ""
            }
        }
    }
}
