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

    /// 常用风格, 按类别分组 (菜单里每类一个子菜单). 文字就是交给 AI 的修图要求
    struct StyleGroup: Identifiable {
        let name: String
        let icon: String
        let styles: [String]
        var id: String { name }
    }
    static let styleGroups: [StyleGroup] = [
        StyleGroup(name: "通用", icon: "wand.and.stars", styles: [
            "自动优化，让照片自然好看",
            "修正偏黄 / 偏色，还原真实颜色",
            "曝光修正：偏暗的提亮，过曝的找回高光，层次自然",
            "逆光补救：提亮逆光的主体和阴影，压暗过亮的背景",
            "室内暖光修正：去掉灯光的偏黄偏橙，还原白墙和肤色",
            "阴天提亮：让灰暗的阴天更明亮，加一点对比和色彩",
            "高光阴影平衡：压暗高光，提亮阴影，接近人眼看到的效果",
            "清晰锐利：增加清晰度和纹理，细节更清楚但不过度",
            "干净柔和：降低对比和纹理，画面干净柔和，适合高感光照片",
            "色彩鲜艳：提高自然饱和度，颜色更饱满但不失真",
            "低饱和淡雅：降低饱和度，柔和的中性色调",
            "美食诱人：暖调，提亮，食物颜色饱满有食欲",
            "产品电商：背景干净，颜色准确，明亮通透",
        ]),
        StyleGroup(name: "人像", icon: "person.crop.circle", styles: [
            "人像通透：肤色干净红润，提亮面部，柔化皮肤",
            "自然肤色：还原真实肤色，轻微提亮面部，保留皮肤质感",
            "日系人像：明亮通透，低对比，肤色白皙微粉，背景略偏青",
            "韩系奶油：柔和低对比，奶油暖白色调，肤色干净，高光柔和",
            "电影人像：青橙色调，肤色偏暖，背景压暗偏青，略加暗角",
            "港风人像：暖色调，浓郁的红绿色，高对比，肤色偏暖，颗粒感",
            "杂志时尚：干净高级，对比稍强，肤色均匀，细节清晰",
            "暗调人像：整体压暗，突出脸上的光，背景深沉，情绪浓郁",
            "胶片人像：低对比，暖调，黑色发灰，柔和颗粒",
            "舞台演出：压暗背景和观众，提亮表演者面部，保留舞台灯光氛围",
            "婚礼纪实：明亮柔和，白色礼服不过曝，肤色温暖自然",
            "儿童家庭：明亮温暖，肤色红润，干净清新",
            "黑白人像：去色，保留皮肤层次，面部明亮，对比柔和",
        ]),
        StyleGroup(name: "风光", icon: "mountain.2", styles: [
            "风光通透：压暗天空高光，提亮阴影，增强蓝天和绿植",
            "日出日落：增强金色暖光，压暗天空高光，保留云层层次",
            "蓝调时刻：偏蓝冷调，城市灯光暖色点缀，暗部干净",
            "山川大气：去朦胧，增强层次和清晰度，天空深蓝",
            "森林绿意：绿色深沉自然，提亮阴影，略偏暖",
            "海边清爽：海水青蓝通透，沙滩干净，明亮高调",
            "雪景：白雪纯净不偏蓝，提亮但不过曝，保留雪的层次",
            "秋色：增强橙黄和红色的树叶，暖调，绿色往黄偏",
            "城市建筑：线条清晰，对比较强，冷暖对比，天空干净",
            "星空银河：压暗天空，增强银河细节，去掉光污染的偏色",
            "雾气氛围：保留雾的柔和感，低对比，淡雅",
            "夜景：压暗高光防过曝，提亮暗部，色彩干净",
            "清冷氛围：偏蓝冷色调，低饱和，安静",
        ]),
        StyleGroup(name: "风格调色", icon: "paintpalette", styles: [
            "日系清新：明亮通透，低饱和，暗部发灰，略偏青",
            "电影感：青橙色调，暗部偏青，肤色偏暖，略压暗",
            "港风复古：暖色调，高对比，浓郁的红绿色，颗粒感",
            "胶片质感：低对比，黑色发灰，偏暖，加颗粒",
            "黑白高对比：去色，强对比，深黑色",
            "莫兰迪：低饱和的灰调，柔和的中间色，安静高级",
            "赛博朋克：洋红和青色的霓虹感，暗部深，高对比",
            "复古暖棕：暖棕色调，褪色感，柔和的老照片质感",
            "清新薄荷：偏青绿，明亮，低对比，夏日感",
            "黑金：只保留暖黄和金色，其他颜色去饱和，暗部深沉",
            "高调明亮：大面积亮调，阴影很浅，干净轻盈",
            "拿铁咖啡：奶咖色调，暖棕和米白，柔和",
            "宝丽来：偏暖偏黄，高光略褪色，暗部偏青，复古即时成像感",
        ]),
    ]
    static var styles: [String] { stylesRaw.map { $0.loc } }
    static let stylesRaw: [String] = styleGroups.flatMap(\.styles)
}

typealias Settings = [String: Double]
