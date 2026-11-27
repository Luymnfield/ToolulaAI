import SwiftUI
import UniformTypeIdentifiers

// MARK: - 右边: AI 设置 + 全部滑块

struct InspectorView: View {
    @EnvironmentObject var store: Store
    @State private var hslKind = "Hue"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                aiSection
                if let item = store.current {
                    ItemPanels(item: item, hslKind: $hslKind)
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: AI 区域

    var aiSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                recognizeBox

                Menu {
                    ForEach(Params.styleGroups) { g in
                        Menu {
                            ForEach(g.styles, id: \.self) { raw in Button(raw.loc) { store.style = raw.loc } }
                        } label: { Label(g.name.locKey, systemImage: g.icon) }
                    }
                    if !store.customStyles.isEmpty {
                        Divider()
                        ForEach(store.customStyles, id: \.self) { s in Button("★ " + s) { store.style = s } }
                        Divider()
                        Menu("删除常用风格") {
                            ForEach(store.customStyles, id: \.self) { s in
                                Button(s) { store.customStyles.removeAll { $0 == s } }
                            }
                        }
                    }
                } label: { Label("常用风格", systemImage: "list.bullet") }

                TextEditor(text: $store.style)
                    .font(.body)
                    .frame(height: 64)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                HStack {
                    Text("写下你想要的效果，越具体越好").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("存为常用") { store.saveCustomStyle() }.controlSize(.small)
                }

                referenceBox

                if store.selection.count > 1 {
                    Picker("多张照片", selection: $store.batchMode) {
                        ForEach(BatchMode.allCases) { Text($0.rawValue.locKey).tag($0) }
                    }
                }
                Toggle("二次检查（更准，时间约翻倍）", isOn: $store.selfCheck)
                Toggle("参考我的修图习惯", isOn: $store.useTaste)
                if store.useTaste && !store.tasteSummary.isEmpty {
                    HStack(alignment: .top) {
                        Text(store.tasteSummary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("清空") { store.resetTaste() }.controlSize(.mini)
                    }
                }

                Button {
                    store.aiEdit()
                } label: {
                    (store.selection.count > 1 ? Label("AI 修图（\(store.selection.count) 张）", systemImage: "wand.and.stars") : Label("AI 修图", systemImage: "wand.and.stars"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .disabled(store.selection.isEmpty || store.working)

                SendToBar()
            }
            .padding(4)
        } label: {
            Label("AI 修图", systemImage: "sparkles").font(.headline)
        }
    }

    /// 第一步: 让 AI 先识别照片, 给出推荐方案
    @ViewBuilder var recognizeBox: some View {
        if let item = store.current {
            RecognizeButton(item: item)
            if !item.plans.isEmpty || !item.scene.isEmpty {
                PlansPanel(item: item)
                HStack {
                    VStack { Divider() }
                    Text("或者自己写想要的效果").font(.caption).foregroundStyle(.secondary).fixedSize()
                    VStack { Divider() }
                }
            }
        }
    }

    var referenceBox: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15))
                if let img = store.referenceImage {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo.badge.plus").foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onDrop(of: [.fileURL], isTargeted: nil) { p in
                loadURLs(p) { if let u = $0.first { store.setReference(u) } }
                return true
            }
            VStack(alignment: .leading, spacing: 4) {
                (store.referenceURL == nil ? Text("参考图（可选）") : Text("照着这张图的风格调")).font(.callout)
                HStack {
                    Button("选择…") {
                        let p = NSOpenPanel()
                        p.allowedContentTypes = [.image]
                        if p.runModal() == .OK { store.setReference(p.url) }
                    }.controlSize(.small)
                    if store.referenceURL != nil {
                        Button("清除") { store.setReference(nil) }.controlSize(.small)
                    }
                }
            }
        }
    }
}

// MARK: - 当前照片的面板

struct ItemPanels: View {
    @EnvironmentObject var store: Store
    @ObservedObject var item: PhotoItem
    @Binding var hslKind: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !item.analysis.isEmpty || item.ai != nil {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        if !item.analysis.isEmpty {
                            Text(item.analysis).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                        if item.ai != nil {
                            HStack {
                                Text("强度")
                                Slider(value: $item.strength, in: 0...150)
                                Text("\(Int(item.strength))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                            }
                        }
                    }.padding(4)
                } label: { Label("AI 的分析", systemImage: "text.bubble") }
            }

            if item.score != nil || !item.keywords.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        if let s = item.score {
                            HStack {
                                Text("\(s) 分").bold()
                                Text(String(repeating: "★", count: item.stars)).foregroundStyle(.yellow)
                                if item.reject { Text("废片").foregroundStyle(.red) }
                            }
                            Text(item.reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if !item.title.isEmpty { Text(item.title).bold() }
                        if !item.caption.isEmpty { Text(item.caption).font(.callout).fixedSize(horizontal: false, vertical: true) }
                        if !item.keywords.isEmpty {
                            Text(item.keywords.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
                } label: { Label("选片 / 关键词", systemImage: "star") }
            }

            PortraitPanel(item: item)
            LocalPanel(item: item)

            HStack {
                Button("复制设置") { store.copySettings() }
                Button("粘贴") { store.pasteSettings() }.disabled(store.clipboard == nil)
                if store.selection.count > 1 { Button("同步到所选") { store.syncFromCurrent() } }
                Spacer()
                Button("重置") { item.resetAll() }
            }
            .controlSize(.small)

            Panel(title: "基础", icon: "sun.max", item: item, specs: Params.basic)
            Panel(title: "颜色", icon: "thermometer.medium", item: item, specs: Params.color)
            Panel(title: "细节与氛围", icon: "aqi.medium", item: item, specs: Params.presence)
            Panel(title: "色调曲线", icon: "point.topleft.down.to.point.bottomright.curvepath", item: item, specs: Params.curve)

            GroupBox {
                VStack(alignment: .leading) {
                    Picker("HSL", selection: $hslKind) {
                        Text("色相").tag("Hue"); Text("饱和度").tag("Saturation"); Text("明亮度").tag("Luminance")
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    ForEach(Array(Params.hsl(hslKind).enumerated()), id: \.element.key) { i, spec in
                        SliderRow(item: item, spec: spec, dot: Color(hue: Params.colors[i].hue / 360, saturation: 0.8, brightness: 0.9))
                    }
                }.padding(4)
            } label: { Label("HSL 颜色", systemImage: "paintpalette") }

            Panel(title: "颜色分级", icon: "circle.lefthalf.filled", item: item, specs: Params.grading)
            Panel(title: "效果", icon: "camera.filters", item: item, specs: Params.effects)

            Text("预览由 Toolula 自己的引擎渲染；「发送到 Lightroom」后由 Lightroom 渲染，效果会略有不同。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

struct Panel: View {
    let title: String
    let icon: String
    @ObservedObject var item: PhotoItem
    let specs: [ParamSpec]
    @State private var open = true

    var body: some View {
        GroupBox {
            if open {
                VStack(spacing: 2) {
                    ForEach(specs) { SliderRow(item: item, spec: $0, dot: nil) }
                }.padding(4)
            }
        } label: {
            Button { withAnimation(.easeInOut(duration: 0.15)) { open.toggle() } } label: {
                HStack {
                    Label(title.locKey, systemImage: icon)
                    Spacer()
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

struct SliderRow: View {
    @ObservedObject var item: PhotoItem
    let spec: ParamSpec
    let dot: Color?

    var body: some View {
        let binding = Binding<Double>(
            get: { item.value(spec.key) },
            set: { item.setValue(spec.key, ($0 / spec.step).rounded() * spec.step) }
        )
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 9, height: 9) }
            Text(spec.label.locKey)
                .frame(width: 70, alignment: .leading)
                .lineLimit(1)
                .onTapGesture(count: 2) { item.setValue(spec.key, 0) }
                .help("双击恢复为 0")
            Slider(value: binding, in: spec.min...spec.max)
                .controlSize(.small)
            Text(format(binding.wrappedValue))
                .monospacedDigit()
                .font(.callout)
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(binding.wrappedValue == 0 ? .secondary : .primary)
        }
    }

    func format(_ v: Double) -> String {
        spec.step < 1 ? String(format: "%+.2f", v) : (v > 0 && spec.min < 0 ? "+\(Int(v.rounded()))" : "\(Int(v.rounded()))")
    }
}


// MARK: - 识别照片 + 推荐方案

struct RecognizeButton: View {
    @EnvironmentObject var store: Store
    @ObservedObject var item: PhotoItem

    var body: some View {
        Button { store.recognize() } label: {
            HStack {
                if item.recognizing { ProgressView().controlSize(.small) } else { Image(systemName: "eye") }
                Text(item.recognizing ? "AI 正在看这张照片…" : (item.plans.isEmpty ? "先让 AI 识别照片，推荐修法" : "重新识别"))
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(item.recognizing || store.working)
        .help(Text("AI 先说出照片的场景和问题，给 3 个带解释的方案，你选一个再决定在哪里继续修"))
    }
}

struct PlansPanel: View {
    @EnvironmentObject var store: Store
    @ObservedObject var item: PhotoItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                Label("AI 识别和推荐", systemImage: "eye").font(.caption.bold()).foregroundStyle(.secondary)
                if !item.scene.isEmpty {
                    Text(item.scene).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if !item.issues.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(item.issues, id: \.self) { i in
                            Label(i, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                ForEach(item.plans) { plan in PlanCard(item: item, plan: plan) }
            }
        }
    }
}

struct PlanCard: View {
    @EnvironmentObject var store: Store
    @ObservedObject var item: PhotoItem
    let plan: PhotoPlan
    @State private var open = false

    var chosen: Bool { item.chosenPlan == plan.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle").foregroundStyle(chosen ? Color.toolula : .secondary)
                Text(plan.name).bold()
                Spacer()
                Button(open ? "收起" : "看参数") { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } }
                    .buttonStyle(.borderless).controlSize(.small)
            }
            Text(plan.why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !plan.complete {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("AI 正在写这个方案的参数…").font(.caption2).foregroundStyle(.secondary) }
            }
            if open || chosen {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(plan.changes) { c in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(c.label).font(.caption.bold()).frame(width: 96, alignment: .leading).lineLimit(1).minimumScaleFactor(0.85)
                            Text(c.display).font(.caption.monospacedDigit()).foregroundStyle(Color.toolula).frame(width: 64, alignment: .leading)
                            Text(c.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            if chosen {
                Divider()
                Text("接下来在哪里继续？").font(.caption.bold())
                HStack(spacing: 6) {
                    ForEach(EditorApp.allCases.filter(\.installed)) { app in
                        Button { store.send(to: app) } label: {
                            HStack(spacing: 4) {
                                Image(nsImage: app.icon).resizable().frame(width: 14, height: 14)
                                Text(app.shortName).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .help(Text(app.menuTitle))
                    }
                }
                .controlSize(.small)
                Button { store.refinePlan(plan) } label: {
                    Label("按这个方案让 AI 精修所有参数", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                Text("也可以直接在下面的滑块里继续微调。").font(.caption2).foregroundStyle(.tertiary)
            } else {
                Button("用这个方案预览") { store.applyPlan(plan, to: item) }.controlSize(.small).disabled(!plan.complete)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(chosen ? Color.toolula.opacity(0.10) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(chosen ? Color.toolula.opacity(0.5) : .clear))
    }
}


// MARK: - 人像精修

struct PortraitPanel: View {
    @ObservedObject var item: PhotoItem
    /// nil = 还在找人脸
    @State private var faces: Int?
    @State private var faceWidth: CGFloat = 0

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if faces == nil {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("正在找人脸…").font(.caption).foregroundStyle(.secondary) }
                } else if faces == 0 {
                    Text("这张照片里没有找到人脸。").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button { item.portrait = Self.recommended(faceWidth: faceWidth) } label: { Label("一键人像精修", systemImage: "wand.and.stars") }
                        Spacer()
                        if !item.portrait.isEmpty {
                            Button("全部归零") { item.portrait = PortraitRetouch() }.controlSize(.small)
                        }
                    }
                    ForEach(PortraitRetouch.specs) { spec in
                        HStack(spacing: 6) {
                            Image(systemName: spec.icon).foregroundStyle(Color.toolula).frame(width: 18)
                            Text(spec.label.locKey).font(.caption).frame(width: 74, alignment: .leading).lineLimit(1).minimumScaleFactor(0.8)
                            Slider(value: Binding(get: { item.portrait[spec.key] }, set: { item.portrait[spec.key] = $0.rounded() }), in: 0...100)
                                .controlSize(.small)
                            Text("\(Int(item.portrait[spec.key]))").font(.caption.monospacedDigit()).frame(width: 28, alignment: .trailing)
                        }
                        .help(Text(spec.help.locKey))
                    }
                    if item.portrait.hasPixelOnly {
                        Text("去瑕疵、淡化眼袋、肤色均匀、光影塑形是像素级修改，Lightroom 的参数表达不了；发送到 Lightroom 时可以选择发修好的 TIFF，或者发可编辑的 RAW（这几项不带过去）。")
                            .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label("人像精修", systemImage: "person.crop.circle") }
        .task(id: item.id) {
            faces = nil
            guard let base = item.previewBase else { faces = 0; return }
            let cache = item.maskCache
            let a = await Task.detached(priority: .userInitiated) { cache.portraitAnalysis(for: base) }.value
            faces = a?.faceCount ?? 0
            faceWidth = a?.faceWidth ?? 0
        }
    }

    /// 没有 AI 时的默认精修: 人脸越小越轻 (合影、舞台远景只需要轻微处理)
    static func recommended(faceWidth: CGFloat) -> PortraitRetouch {
        let k = Double(max(0.35, min(1, faceWidth / 0.12)))
        var p = PortraitRetouch()
        for (key, v) in [("smooth", 30.0), ("blemish", 60), ("undereye", 30), ("even", 20), ("sculpt", 20), ("eyes", 25), ("teeth", 25), ("lips", 10)] {
            p[key] = (v * (key == "eyes" || key == "teeth" ? 1 : k)).rounded()
        }
        return p
    }
}

// MARK: - 局部调整

struct LocalPanel: View {
    @EnvironmentObject var store: Store
    @ObservedObject var item: PhotoItem
    @State private var open: UUID?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if item.locals.isEmpty {
                    Text("只调某一块：例如提亮人脸、压暗天空找回云层、压暗背景突出主体。AI 会自动找出这些区域。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(item.locals) { l in row(l) }
                Menu {
                    ForEach(MaskKind.allCases) { k in
                        Button { store.addLocal(k); open = item.locals.last?.id } label: { Label(k.label, systemImage: k.icon) }
                    }
                } label: { Label("添加局部调整", systemImage: "plus.circle") }
                .fixedSize()
                if !item.patches.isEmpty {
                    Text("已 AI 消除 \(item.patches.count) 处").font(.caption).foregroundStyle(.secondary)
                }
                if !item.patches.isEmpty {
                    Text("发送到 Lightroom / Photoshop 时，会发送已经修好的 16 位 TIFF（AI 消除无法写进它们的参数文件）。")
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                } else if item.retouched {
                    Text("发送到 Lightroom 时，局部调整会在导入后由 Toolula 插件自动做成 Lightroom 的 AI 蒙版，可以继续调；发送到 Photoshop 时是修好的 16 位 TIFF。")
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label("局部调整", systemImage: "circle.lefthalf.filled") }
    }

    func summary(_ l: LocalAdjustment) -> String {
        let parts = LocalAdjustment.params.compactMap { p -> String? in
            guard let v = l.settings[p.key], v != 0 else { return nil }
            return p.label.loc + " " + (p.key == "Exposure2012" ? String(format: "%+.2f", v) : String(format: "%+.0f", v))
        }
        return parts.isEmpty ? String(localized: "还没有调整") : parts.joined(separator: "，")
    }

    @ViewBuilder func row(_ l: LocalAdjustment) -> some View {
        let isOpen = open == l.id
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: l.area.icon).foregroundStyle(Color.toolula).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(l.area.label).bold()
                    Text(summary(l)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { item.showMask = item.showMask == l.area ? nil : l.area } label: {
                    Image(systemName: item.showMask == l.area ? "eye.fill" : "eye")
                }
                .buttonStyle(.borderless).help(Text("用红色显示这个区域")).accessibilityLabel(Text("用红色显示这个区域"))
                Button { open = isOpen ? nil : l.id } label: { Image(systemName: isOpen ? "chevron.up" : "chevron.down") }
                    .buttonStyle(.borderless).accessibilityLabel(isOpen ? Text("收起") : Text("展开"))
                Button { item.locals.removeAll { $0.id == l.id }; if item.showMask == l.area { item.showMask = nil } } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help(Text("删除这个局部调整")).accessibilityLabel(Text("删除这个局部调整"))
            }
            if isOpen {
                ForEach(LocalAdjustment.params) { p in
                    HStack(spacing: 6) {
                        Text(p.label.locKey).font(.caption).frame(width: 92, alignment: .leading).lineLimit(1).minimumScaleFactor(0.8)
                        Slider(value: Binding(
                            get: { item.locals.first { $0.id == l.id }?.settings[p.key] ?? 0 },
                            set: { v in
                                if let i = item.locals.firstIndex(where: { $0.id == l.id }) {
                                    item.locals[i].settings[p.key] = (v / p.step).rounded() * p.step
                                }
                            }), in: p.min...p.max)
                        .controlSize(.small)
                        Text(p.key == "Exposure2012" ? String(format: "%+.2f", l.settings[p.key] ?? 0) : String(format: "%+.0f", l.settings[p.key] ?? 0))
                            .font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}
