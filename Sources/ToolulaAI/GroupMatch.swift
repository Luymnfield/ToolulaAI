import CoreImage
import Foundation

// MARK: - 整组一致: 一场拍摄里, 其他照片的风格照搬代表照片, 曝光和白平衡逐张对齐 (量出来的, 不是照搬数值)
// 和 Lightroom 的「同步设置」+「匹配总曝光」一样, 另外还对齐中性色 (白平衡)

extension Store {
    /// 影响「风格」的参数会照搬; 曝光、白平衡每张单独对齐; 角度 (构图) 每张不同, 不碰
    nonisolated static let perPhotoKeys: Set<String> = ["Exposure2012", "IncrementalTemperature", "IncrementalTint", "Temperature", "Tint", "CropAngle"]

    func matchGroupToCurrent() {
        guard let ref = current, let refBase = ref.previewBase, !working else { return }
        let targets = selectedItems.filter { $0 !== ref && $0.previewBase != nil }
        guard !targets.isEmpty else { return }
        working = true
        status = String(localized: "整组对齐：量代表照片…")
        let refSettings = ref.settings, refPatches = ref.patches, refPortrait = ref.portrait, refLocals = ref.locals
        Task {
            defer { working = false }
            let refStats = await Task.detached { Self.groupStats(base: refBase, settings: refSettings, patches: refPatches, portrait: refPortrait, locals: refLocals) }.value
            guard let refStats else { status = String(localized: "整组对齐失败：量不出代表照片"); return }
            for (i, t) in targets.enumerated() {
                if cancelRequested { break }
                status = String(localized: "整组对齐：\(i + 1)/\(targets.count) · \(t.name)")
                guard let base = t.previewBase else { continue }
                // 1. 风格照搬 (保留这张自己的曝光、白平衡、角度)
                var s = refSettings
                for k in Self.perPhotoKeys { s[k] = t.settings[k] }
                let patches = t.patches, locals = refLocals
                // 2. 曝光和白平衡对齐到代表照片 (量 → 调 → 再量, 3 轮)
                let fixed = await Task.detached { Self.alignExposureAndWB(base: base, settings: s, patches: patches, portrait: refPortrait, locals: locals, to: refStats) }.value
                t.base = fixed
                t.ai = nil
                t.manual = [:]
                t.locals = refLocals
                t.portrait = refPortrait
                t.analysis = String(localized: "（已对齐到 \(ref.name)：风格相同，曝光和白平衡按这张照片单独调整）")
                t.changed()
            }
            status = String(localized: "整组对齐完成：\(targets.count) 张已对齐到 \(ref.name)")
        }
    }

    nonisolated static func groupStats(base: CIImage, settings: Settings, patches: [RetouchPatch], portrait: PortraitRetouch, locals: [LocalAdjustment]) -> PhotoMeasure.Stats? {
        let r = Renderer.shared
        let small = r.scale(base, maxSide: PhotoMeasure.side * 2)
        let img = r.renderEdited(small, settings: settings, patches: patches, locals: locals, portrait: portrait, cache: MaskCache())
        return PhotoMeasure.stats(img)
    }

    /// 用中位亮度对齐曝光, 用中性色区域的偏色对齐色温 / 色调. 每轮按测量差值修正, 一般 2~3 轮就收敛
    nonisolated static func alignExposureAndWB(base: CIImage, settings: Settings, patches: [RetouchPatch], portrait: PortraitRetouch,
                                               locals: [LocalAdjustment], to ref: PhotoMeasure.Stats) -> Settings {
        var s = settings
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        for _ in 0..<3 {
            guard let cur = groupStats(base: base, settings: s, patches: patches, portrait: portrait, locals: locals) else { break }
            var changed = false
            // 曝光: 线性亮度之比 → EV
            let a = lin(max(0.01, cur.p50)), b = lin(max(0.01, ref.p50))
            let dEV = max(-1.5, min(1.5, log2(b / a)))
            if abs(dEV) > 0.04 {
                s["Exposure2012"] = Params.clamp("Exposure2012", (s["Exposure2012"] ?? 0) + dEV * 0.9)
                changed = true
            }
            // 白平衡: 只有两张都有足够的中性色时才对齐 (否则可能把本来的颜色当成偏色)
            if cur.neutralShare > 0.05 && ref.neutralShare > 0.05 {
                let dB = ref.castB - cur.castB, dA = ref.castA - cur.castA
                if abs(dB) > 2 { s["IncrementalTemperature"] = Params.clamp("IncrementalTemperature", (s["IncrementalTemperature"] ?? 0) + dB * 1.6); changed = true }
                if abs(dA) > 2 { s["IncrementalTint"] = Params.clamp("IncrementalTint", (s["IncrementalTint"] ?? 0) + dA * 1.6); changed = true }
            }
            if !changed { break }
        }
        // 总的曝光改动不超过 ±1.5 EV (远景、逆光这类本来就该暗一些的照片不要硬拉到一样亮)
        let start = settings["Exposure2012"] ?? 0
        s["Exposure2012"] = max(start - 1.5, min(start + 1.5, s["Exposure2012"] ?? 0))
        // 最后和 AI 修图一样检查: 高光修爆、暗部压死就往回收
        let r = Renderer.shared
        let small = r.scale(base, maxSide: PhotoMeasure.side)
        let (fixed, _) = PhotoMeasure.guardClipping(before: settings, after: s) { st in
            r.renderEdited(small, settings: st, patches: patches, locals: locals, portrait: portrait, cache: MaskCache())
        }
        return fixed
    }
}
