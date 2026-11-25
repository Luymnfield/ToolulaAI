import Foundation

/// 一个可调参数 (名字和 Lightroom 的参数名一致, 方便和 AI / Lightroom 互通)
struct ParamSpec: Identifiable {
    let key: String
    let label: String
    let min: Double
    let max: Double
    let step: Double
    var id: String { key }
}

enum Params {
    static let colors: [(key: String, label: String, hue: Double)] = [
        ("Red", "红", 0), ("Orange", "橙", 30), ("Yellow", "黄", 60), ("Green", "绿", 120),
        ("Aqua", "青", 180), ("Blue", "蓝", 235), ("Purple", "紫", 275), ("Magenta", "洋红", 315),
    ]

    static let basic: [ParamSpec] = [
        ParamSpec(key: "Exposure2012", label: "曝光", min: -5, max: 5, step: 0.05),
        ParamSpec(key: "Contrast2012", label: "对比度", min: -100, max: 100, step: 1),
        ParamSpec(key: "Highlights2012", label: "高光", min: -100, max: 100, step: 1),
        ParamSpec(key: "Shadows2012", label: "阴影", min: -100, max: 100, step: 1),
        ParamSpec(key: "Whites2012", label: "白色色阶", min: -100, max: 100, step: 1),
        ParamSpec(key: "Blacks2012", label: "黑色色阶", min: -100, max: 100, step: 1),
    ]
    static let color: [ParamSpec] = [
        ParamSpec(key: "IncrementalTemperature", label: "色温", min: -100, max: 100, step: 1),
        ParamSpec(key: "IncrementalTint", label: "色调", min: -100, max: 100, step: 1),
        ParamSpec(key: "Vibrance", label: "自然饱和度", min: -100, max: 100, step: 1),
        ParamSpec(key: "Saturation", label: "饱和度", min: -100, max: 100, step: 1),
    ]
    static let presence: [ParamSpec] = [
        ParamSpec(key: "Texture", label: "纹理", min: -100, max: 100, step: 1),
        ParamSpec(key: "Clarity2012", label: "清晰度", min: -100, max: 100, step: 1),
        ParamSpec(key: "Dehaze", label: "去朦胧", min: -100, max: 100, step: 1),
    ]
    static let curve: [ParamSpec] = [
        ParamSpec(key: "ParametricHighlights", label: "高光", min: -100, max: 100, step: 1),
        ParamSpec(key: "ParametricLights", label: "亮调", min: -100, max: 100, step: 1),
        ParamSpec(key: "ParametricDarks", label: "暗调", min: -100, max: 100, step: 1),
        ParamSpec(key: "ParametricShadows", label: "阴影", min: -100, max: 100, step: 1),
    ]
    static let grading: [ParamSpec] = [
        ParamSpec(key: "SplitToningShadowHue", label: "阴影色相", min: 0, max: 360, step: 1),
        ParamSpec(key: "SplitToningShadowSaturation", label: "阴影饱和度", min: 0, max: 100, step: 1),
        ParamSpec(key: "SplitToningHighlightHue", label: "高光色相", min: 0, max: 360, step: 1),
        ParamSpec(key: "SplitToningHighlightSaturation", label: "高光饱和度", min: 0, max: 100, step: 1),
        ParamSpec(key: "SplitToningBalance", label: "平衡", min: -100, max: 100, step: 1),
    ]
    static let effects: [ParamSpec] = [
        ParamSpec(key: "PostCropVignetteAmount", label: "暗角", min: -100, max: 100, step: 1),
        ParamSpec(key: "GrainAmount", label: "颗粒", min: 0, max: 100, step: 1),
    ]
    static func hsl(_ kind: String) -> [ParamSpec] {
        // kind: Hue / Saturation / Luminance
        colors.map { ParamSpec(key: "\(kind)Adjustment\($0.key)", label: $0.label, min: -100, max: 100, step: 1) }
    }

    static var all: [ParamSpec] {
        basic + color + presence + curve + grading + effects + hsl("Hue") + hsl("Saturation") + hsl("Luminance")
    }
    static let specByKey: [String: ParamSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    /// 不参与强度缩放的参数 (色相是角度)
    static let noBlend: Set<String> = ["SplitToningShadowHue", "SplitToningHighlightHue"]

    static func clamp(_ key: String, _ v: Double) -> Double {
        guard let s = specByKey[key] else { return v }
        return Swift.min(s.max, Swift.max(s.min, v))
    }

    static var styles: [String] { stylesRaw.map { $0.loc } }
    static let stylesRaw: [String] = [
        "自动优化，让照片自然好看",
        "日系清新：明亮通透，低饱和，暗部发灰，略偏青",
        "电影感：青橙色调，暗部偏青，肤色偏暖，略压暗",
        "人像通透：肤色干净红润，提亮面部，柔化皮肤",
        "港风复古：暖色调，高对比，浓郁的红绿色，颗粒感",
        "胶片质感：低对比，黑色发灰，偏暖，加颗粒",
        "黑白高对比：去色，强对比，深黑色",
        "清冷氛围：偏蓝冷色调，低饱和，安静",
        "风光通透：压暗天空高光，提亮阴影，增强蓝天和绿植",
        "夜景：压暗高光防过曝，提亮暗部，色彩干净",
        "修正偏黄 / 偏色，还原真实颜色",
    ]
}

typealias Settings = [String: Double]
