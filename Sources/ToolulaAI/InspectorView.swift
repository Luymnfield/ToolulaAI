import SwiftUI
import UniformTypeIdentifiers

// MARK: - 右边: 分步骤的卡片 (识别 → 风格 → 人像精修 → 调整), 底部固定 AI 修图按钮

struct InspectorView: View {
    @EnvironmentObject var store: Store
    @State private var hslKind = "Hue"
    @AppStorage("photoAdvancedOpen") private var advancedOpen = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    StepCard(number: 1, title: "AI 识别", icon: "eye") {
                        if let item = store.current, !item.plans.isEmpty, !item.recognizing {
                            Button { store.recognize() } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.borderless).help(Text("重新识别")).accessibilityLabel(Text("重新识别"))
                                .disabled(store.working)
                        }
                    } content: {
                        if let item = store.current {
                            RecognizeArea(item: item)
                        } else {
                            Text("添加照片后，AI 会先看一看照片，说出问题并给 3 个修法。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    StepCard(number: 2, title: "风格", icon: "paintpalette") { EmptyView() } content: { StylePicker() }
                    if let item = store.current {
                        PortraitPanel(item: item)
                        ItemPanels(item: item, hslKind: $hslKind)
                    }
                }
                .padding(12)
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: 底部: 主按钮 + 发送到 + 高级

    var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(store.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("停止") { store.cancel() }.controlSize(.small)
                }
                .frame(height: 30)
            } else {
                Button {
                    if store.selection.isEmpty { openPanel(store) } else { store.aiEdit() }
                } label: {
                    Group {
                        if store.photos.isEmpty {
                            Label("添加照片", systemImage: "plus")
                        } else if store.selection.count > 1 {
                            Label("AI 修图（\(store.selection.count) 张）", systemImage: "wand.and.stars")
                        } else {
                            Label("AI 修图", systemImage: "wand.and.stars")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.toolula)
                .controlSize(.large)
                .help("用上面选的风格修选中的照片 (⌘E)")
            }
            HStack(spacing: 10) {
                let apps = EditorApp.allCases.filter(\.installed)
                if !apps.isEmpty {
                    Text("发送到").font(.caption).foregroundStyle(.secondary)
                    ForEach(apps) { app in
                        Button { store.send(to: app) } label: {
                            HStack(spacing: 4) {
                                Image(nsImage: app.icon).resizable().frame(width: 14, height: 14)
                                Text(app.shortName).font(.caption).lineLimit(1)
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(store.selection.isEmpty || store.working)
                        .help(Text(app.menuTitle))
                    }
                }
                Spacer()
                Button { withAnimation(.easeOut(duration: 0.15)) { advancedOpen.toggle() } } label: {
                    HStack(spacing: 2) {
                        Text("高级").font(.caption)
                        Image(systemName: advancedOpen ? "chevron.down" : "chevron.up").font(.caption2)
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            if advancedOpen {
                VStack(alignment: .leading, spacing: 6) {
                    if store.selection.count > 1 {
                        Picker("多张照片", selection: $store.batchMode) {
                            ForEach(BatchMode.allCases) { Text($0.rawValue.locKey).tag($0) }
                        }
                        .controlSize(.small)
                    }
                    Toggle("二次检查（更准，时间约翻倍）", isOn: $store.selfCheck).controlSize(.small)
                    Toggle("参考我的修图习惯", isOn: $store.useTaste).controlSize(.small)
                    if store.useTaste && !store.tasteSummary.isEmpty {
                        HStack(alignment: .top) {
                            Text(store.tasteSummary).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("清空") { store.resetTaste() }.controlSize(.mini)
                        }
                    }
                }
                .font(.caption)
            }
        }
        .padding(12)
        .background(.bar)
    }
}

/// 带编号的步骤卡片
struct StepCard<Trailing: View, Content: View>: View {
    var number: Int? = nil
    let title: LocalizedStringKey
    let icon: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                if let number {
                    Text(verbatim: "\(number)").font(.caption2.weight(.bold)).foregroundStyle(Color.toolula)
                        .frame(width: 18, height: 18).background(Color.toolula.opacity(0.16), in: Circle())
                } else {
                    Image(systemName: icon).font(.caption).foregroundStyle(.secondary).frame(width: 18, height: 18)
                }
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                trailing
            }
            content
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
    }
}

/// 第一步: AI 识别照片, 给出推荐方案
struct RecognizeArea: View {
    @EnvironmentObject var store: Store
    @ObservedObject var item: PhotoItem

    var body: some View {
        if item.plans.isEmpty && item.scene.isEmpty {
            RecognizeButton(item: item)
        } else {
            PlansPanel(item: item)
        }
    }
}

/// 第二步: 按类别选风格 (标签), 下面可以写自己的要求、加参考图
struct StylePicker: View {
    @EnvironmentObject var store: Store
    @AppStorage("styleGroup") private var group = "通用"
    @AppStorage("styleCustomOpen") private var customOpen = false
    static let mine = "★"

    var styles: [String] {
        if group == Self.mine { return store.customStyles }
        return (Params.styleGroups.first { $0.name == group } ?? Params.styleGroups[0]).styles.map(\.loc)
    }
    /// 当前要求不是任何一个标签时, 显示出来
    var isCustom: Bool { !Params.styles.contains(store.style) && !store.customStyles.contains(store.style) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Picker("类别", selection: $group) {
                ForEach(Params.styleGroups) { g in Text(g.name.locKey).tag(g.name) }
                if !store.customStyles.isEmpty { Text("我的").tag(Self.mine) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            FlowLayout(spacing: 6) {
                ForEach(styles, id: \.self) { full in
                    let on = store.style == full
                    Button { store.style = full } label: {
                        Text(verbatim: Self.shortName(full)).font(.caption).lineLimit(1)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .foregroundStyle(on ? Color.toolula : .primary)
                            .background(on ? Color.toolula.opacity(0.16) : Color.primary.opacity(0.06), in: Capsule())
                            .overlay(Capsule().stroke(on ? Color.toolula.opacity(0.55) : .clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(Text(verbatim: full))
                    .contextMenu {
                        if group == Self.mine { Button("删除这个风格") { store.customStyles.removeAll { $0 == full } } }
                    }
                }
            }

            if !store.style.isEmpty {
                Text(verbatim: store.style).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup(isExpanded: $customOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $store.style)
                        .font(.callout)
                        .frame(height: 58)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    HStack {
                        Text("写下你想要的效果，越具体越好").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("存为常用") { store.saveCustomStyle(); group = Self.mine }.controlSize(.small)
                            .disabled(!isCustom)
                    }
                    ReferenceBox()
                }
                .padding(.top, 6)
            } label: {
                Label(store.referenceURL == nil ? "自定义要求和参考图" : "自定义要求和参考图（已选参考图）", systemImage: "pencil")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 标签上只显示名字: 「人像通透：肤色干净…」-> 「人像通透」
    static func shortName(_ s: String) -> String {
        for sep in ["：", ":", "，", ","] {
            if let r = s.range(of: sep) {
                let head = s[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                if !head.isEmpty && head.count <= 24 { return head }
            }
        }
        return s.count > 18 ? String(s.prefix(18)) + "…" : s
    }
}

struct ReferenceBox: View {
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15))
                if let img = store.referenceImage {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo.badge.plus").foregroundStyle(.secondary)
                }
            }
            .frame(width: 56, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onDrop(of: [.fileURL], isTargeted: nil) { p in
                loadURLs(p) { if let u = $0.first { store.setReference(u) } }
                return true
            }
            VStack(alignment: .leading, spacing: 4) {
                (store.referenceURL == nil ? Text("参考图（可选）") : Text("照着这张图的风格调")).font(.caption)
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

/// 一行放不下就换行的排列 (风格标签用)
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

// MARK: - 当前照片的面板

struct ItemPanels: View {
    @EnvironmentObject var store: Store
    @ObservedObject var item: PhotoItem
    @Binding var hslKind: String
    @AppStorage("photoAdjustOpen") private var adjustOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !item.analysis.isEmpty || item.ai != nil {
                StepCard(title: "AI 的分析", icon: "text.bubble") { EmptyView() } content: {
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
                    }
                }
            }

            QualityCard(item: item)

            if item.score != nil || !item.keywords.isEmpty {
                StepCard(title: "选片 / 关键词", icon: "star") { EmptyView() } content: {
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
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            LocalPanel(item: item)

            HStack {
                Button("复制设置") { store.copySettings() }
                Button("粘贴") { store.pasteSettings() }.disabled(store.clipboard == nil)
                if store.selection.count > 1 {
                    Button("同步到所选") { store.syncFromCurrent() }
                    Button("整组对齐") { store.matchGroupToCurrent() }
                        .help(Text("其他选中的照片照搬这张的风格，曝光和白平衡按每张照片单独对齐到这张（同一场拍摄用）"))
                }
                Spacer()
                Button("重置") { item.resetAll() }
            }
            .controlSize(.small)

            StepCard(title: "构图", icon: "level") {
                Button {
                    guard let base = item.previewBase else { return }
                    Task {
                        let a = await Task.detached { Renderer.horizonAngle(base) }.value
                        if let a { item.setValue("CropAngle", a); store.status = String(localized: "已拉正 \(String(format: "%.1f", a))°") }
                        else { store.status = String(localized: "没有找到明显倾斜的地平线") }
                    }
                } label: { Label("自动拉正", systemImage: "level").font(.caption) }
                .buttonStyle(.borderless).foregroundStyle(Color.toolula)
                .help(Text("用 Vision 找出地平线, 把照片转平, 再裁掉转出来的空角"))
            } content: {
                HStack(spacing: 6) {
                    Text("角度").font(.caption).frame(width: 40, alignment: .leading)
                    Slider(value: Binding(get: { item.value("CropAngle") }, set: { item.setValue("CropAngle", ($0 * 10).rounded() / 10) }), in: -10...10)
                        .controlSize(.mini)
                    Text(verbatim: String(format: "%+.1f°", item.value("CropAngle"))).font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
                        .onTapGesture(count: 2) { item.setValue("CropAngle", 0) }
                }
            }

            DisclosureGroup(isExpanded: $adjustOpen) {
                VStack(alignment: .leading, spacing: 14) {
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
                }
                .padding(.top, 8)
            } label: {
                let changed = Params.all.filter { item.value($0.key) != 0 }.count
                Label(changed > 0 ? "调整 · \(Params.all.count) 项（已改 \(changed) 项）" : "调整 · \(Params.all.count) 项", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
            }

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
    @State private var blind = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
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
                let done = item.plans.filter(\.complete)
                if done.count >= 2 && !item.recognizing {
                    Button { blind = true } label: { Label("盲选比较（不看名字选更好的）", systemImage: "eye.slash").font(.caption) }
                        .buttonStyle(.borderless).foregroundStyle(Color.toolula)
                        .help(Text("两个方案并排、随机左右，选更好的。你的选择会记下来，以后修类似的照片时告诉 AI 你的偏好"))
                }
                ForEach(item.plans) { plan in PlanCard(item: item, plan: plan) }
            }
        }
        .sheet(isPresented: $blind) { BlindCompareSheet(item: item, isPresented: $blind, plans: item.plans.filter(\.complete)) }
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
    @State private var showAll = false

    var body: some View {
        ZStack {
            if let faces, faces > 0 {
                StepCard(number: 3, title: "人像精修", icon: "person.crop.circle") {
                    if item.portrait.isEmpty {
                        Button("一键精修") { item.portrait = Self.recommended(faceWidth: faceWidth) }
                            .buttonStyle(.borderless).foregroundStyle(Color.toolula).font(.caption)
                    } else {
                        Button("全部归零") { item.portrait = PortraitRetouch() }.buttonStyle(.borderless).font(.caption)
                    }
                } content: {
                    let specs = showAll ? PortraitRetouch.specs : Array(PortraitRetouch.specs.prefix(4))
                    VStack(spacing: 3) {
                        ForEach(specs) { spec in
                            HStack(spacing: 6) {
                                Text(spec.label.locKey).font(.caption).frame(width: 70, alignment: .leading).lineLimit(1).minimumScaleFactor(0.8)
                                Slider(value: Binding(get: { item.portrait[spec.key] }, set: { item.portrait[spec.key] = $0.rounded() }), in: 0...100)
                                    .controlSize(.mini)
                                Text(verbatim: "\(Int(item.portrait[spec.key]))").font(.caption.monospacedDigit())
                                    .foregroundStyle(item.portrait[spec.key] == 0 ? .secondary : .primary)
                                    .frame(width: 24, alignment: .trailing)
                            }
                            .help(Text(spec.help.locKey))
                        }
                    }
                    Button { withAnimation(.easeOut(duration: 0.15)) { showAll.toggle() } } label: {
                        Text(showAll ? "收起" : "更多 \(PortraitRetouch.specs.count - 4) 项").font(.caption)
                    }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    if item.portrait.hasPixelOnly {
                        Text("去瑕疵、淡化眼袋、肤色均匀、光影塑形是像素级修改，Lightroom 的参数表达不了；发送到 Lightroom 时可以选择发修好的 TIFF，或者发可编辑的 RAW（这几项不带过去）。")
                            .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                // 找人脸的任务挂在这里 (没有内容的视图上 .task 不会运行)
                Color.clear.frame(height: 0)
            }
        }
        .task(id: "\(item.id)-\(item.original != nil)") {
            faces = nil
            guard let base = item.previewBase else { return }
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
        StepCard(title: "局部调整", icon: "circle.lefthalf.filled") { EmptyView() } content: {
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                    if MaskKind.lightroomOnly.contains(l.area) {
                        Text("只在发送到 Lightroom 后生效（由 Lightroom 的 AI 风景蒙版做），Toolula 的预览里看不到").font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
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
