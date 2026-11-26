import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 360)
        } detail: {
            HStack(spacing: 0) {
                ViewerView()
                Divider()
                InspectorView()
                    .frame(width: 340)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { openPanel(store) } label: { Label("添加照片", systemImage: "plus") }
                    .help("添加照片或文件夹（也可以直接拖进窗口）")
            }
            ToolbarItem(placement: .principal) {
                Picker("视图", selection: $store.viewMode) {
                    ForEach(ViewMode.allCases) { Text($0.rawValue.locKey).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .help("效果 / 左右对比 / 原图")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if store.working {
                    ProgressView().controlSize(.small)
                    Button("停止") { store.cancel() }
                }
                Button { store.aiEdit() } label: { Label("AI 修图", systemImage: "wand.and.stars") }
                    .disabled(store.selection.isEmpty || store.working)
                    .help("用右边设置的风格修选中的照片 (⌘E)")
                Toggle(isOn: Binding(get: { store.eraseMode }, set: { on in
                    store.eraseMode = on
                    if on { store.viewMode = .after }
                })) { Label("AI 消除", systemImage: "eraser") }
                    .toggleStyle(.button)
                    .disabled(store.current == nil)
                    .help("用笔刷涂掉路人、杂物、电线，AI 自动补上背景")
                Menu {
                    Button("AI 选片（打分、找废片）") { store.cull() }
                    Button("AI 关键词和描述") { store.tag() }
                } label: { Label("更多 AI", systemImage: "sparkles") }
                    .disabled(store.selection.isEmpty || store.working)
                Menu {
                    ForEach(EditorApp.allCases) { app in
                        Button { store.send(to: app) } label: {
                            Label { Text(app.menuTitle) } icon: { Image(nsImage: app.icon) }
                        }
                        .disabled(!app.installed)
                    }
                } label: { Label("发送到", systemImage: "arrow.up.forward.app") }
                    .disabled(store.selection.isEmpty || store.working)
                    .help("把修好的照片发送到 Lightroom、Photoshop 或 Luminar Neo 继续编辑")
                Menu {
                    Button("导出 JPEG（原尺寸）…") { store.exportJPEG(maxSide: nil) }
                    Button("导出 JPEG（长边 2048，适合发图）…") { store.exportJPEG(maxSide: 2048) }
                    Divider()
                    Button("存成 Lightroom / Photoshop 预设…") { store.savePresetForAdobe() }
                    Button("导出 LUT（Photoshop / Luminar / 视频软件通用）") { store.exportLUT() }
                } label: { Label("导出", systemImage: "square.and.arrow.up") }
                    .disabled(store.selection.isEmpty || store.working)
            }
        }
        .safeAreaInset(edge: .bottom) {
            // 底部状态栏: 左边是进度/结果, 右边是照片数量
            if !store.photos.isEmpty || !store.status.isEmpty {
                HStack {
                    Text(store.status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if !store.photos.isEmpty {
                        Text("\(store.photos.count) 张 · 已选 \(store.selection.count) 张（⌘A 全选）")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay(alignment: .top) { Divider() }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadURLs(providers) { store.add(urls: $0) }
            return true
        }
        .alert("提示", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })) {
            Button("好") { store.alert = nil }
        } message: {
            Text(store.alert ?? "")
        }
    }
}

func loadURLs(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([URL]) -> Void) {
    var urls: [URL] = []
    let group = DispatchGroup()
    for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { DispatchQueue.main.async { urls.append(url) } }
            group.leave()
        }
    }
    group.notify(queue: .main) { MainActor.assumeIsolated { done(urls) } }
}

// MARK: - 左边: 照片列表

struct SidebarView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 0) {
            Picker("筛选", selection: $store.filter) {
                ForEach(ListFilter.allCases) { Text($0.rawValue.locKey).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            if store.photos.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("把照片或文件夹拖到这里").foregroundStyle(.secondary)
                    Button("选择照片…") { openPanel(store) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $store.selection) {
                    ForEach(store.visiblePhotos) { item in
                        PhotoRow(item: item).tag(item.id)
                            .contextMenu {
                                Button("从列表移除") { store.remove(store.selection.contains(item.id) ? store.selectedItems : [item]) }
                                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                            }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }
}

struct PhotoRow: View {
    @ObservedObject var item: PhotoItem

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if let t = item.thumb {
                    Image(nsImage: t).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.gray.opacity(0.2)
                }
                if item.busy {
                    Color.black.opacity(0.4)
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .opacity(item.reject ? 0.45 : 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    if item.stars > 0 {
                        Text(String(repeating: "★", count: item.stars)).foregroundStyle(.yellow).font(.caption)
                    }
                    if item.reject { Text("废片").font(.caption2).padding(.horizontal, 4).background(.red.opacity(0.25)).clipShape(Capsule()) }
                    if item.ai != nil { Image(systemName: "wand.and.stars").font(.caption).foregroundStyle(.green) }
                    if item.isRaw { Text("RAW").font(.caption2).foregroundStyle(.secondary) }
                }
                if !item.status.isEmpty && item.status != String(localized: "AI 已修") {
                    Text(item.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 中间: 预览 / 对比

struct ViewerView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let item = store.current {
                CompareView(item: item, mode: store.eraseMode ? .after : store.viewMode)
                    .padding(16)
                    .padding(.bottom, store.eraseMode ? 120 : 0)
                if store.eraseMode {
                    VStack { Spacer(); EraseBar(item: item).padding(.bottom, 50) }
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "wand.and.stars").font(.system(size: 52)).foregroundStyle(.green)
                    Text("Toolula AI 修图").font(.title2.bold())
                    Text("把照片拖进窗口 → 在右边选风格 → 点「AI 修图」").foregroundStyle(.secondary)
                    Button("添加照片…") { openPanel(store) }.controlSize(.large)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CompareView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var item: PhotoItem
    let mode: ViewMode
    @State private var split: CGFloat = 0.5

    var body: some View {
        GeometryReader { geo in
            let img = item.preview ?? item.original
            if let img, let orig = item.original {
                let fit = fitSize(img.size, in: geo.size)
                ZStack {
                    switch mode {
                    case .after:
                        Image(nsImage: img).resizable().frame(width: fit.width, height: fit.height)
                            .overlay { if store.eraseMode { BrushOverlay(size: fit) } }
                    case .before:
                        Image(nsImage: orig).resizable().frame(width: fit.width, height: fit.height)
                    case .split:
                        // 底层: 效果图; 左边盖一块裁剪过的原图; 中间是分界线
                        Image(nsImage: img).resizable().frame(width: fit.width, height: fit.height)
                            .overlay(alignment: .leading) {
                                Image(nsImage: orig).resizable().frame(width: fit.width, height: fit.height)
                                    .frame(width: max(1, fit.width * split), height: fit.height, alignment: .leading)
                                    .clipped()
                            }
                            .overlay(alignment: .leading) {
                                ZStack {
                                    Rectangle().fill(.white).frame(width: 2, height: fit.height)
                                    Circle().fill(.white).frame(width: 26, height: 26)
                                        .overlay(Image(systemName: "arrow.left.and.right").font(.caption.bold()).foregroundStyle(.black))
                                }
                                .frame(width: 26)
                                .offset(x: fit.width * split - 13)
                            }
                            .overlay(alignment: .top) {
                                HStack { tag(String(localized: "原图")); Spacer(); tag(String(localized: "修图效果")) }.padding(.top, 8)
                            }
                            .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                            split = min(1, max(0, v.location.x / fit.width))
                        })
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .shadow(color: .black.opacity(0.25), radius: 8)
            } else if item.status == String(localized: "无法读取") {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text("无法读取这张照片（macOS 不支持这个格式，或文件已损坏）").foregroundStyle(.secondary)
                }.frame(width: geo.size.width, height: geo.size.height)
            } else {
                ProgressView("读取中…").frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    func tag(_ s: String) -> some View {
        Text(verbatim: s).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3)
            .background(.black.opacity(0.5)).foregroundStyle(.white).clipShape(Capsule()).padding(.horizontal, 8)
    }

    func fitSize(_ s: NSSize, in box: CGSize) -> CGSize {
        guard s.width > 0, s.height > 0 else { return box }
        let k = min(box.width / s.width, box.height / s.height)
        return CGSize(width: s.width * k, height: s.height * k)
    }
}


// MARK: - AI 消除: 笔刷

struct BrushOverlay: View {
    @EnvironmentObject var store: Store
    let size: CGSize
    @State private var current: [CGPoint] = []
    @State private var hover: CGPoint?

    var body: some View {
        Canvas { ctx, sz in
            let w = store.eraseBrush * 2 * sz.width
            for s in store.eraseStrokes + (current.isEmpty ? [] : [current]) {
                let pts = s.map { CGPoint(x: $0.x * sz.width, y: $0.y * sz.height) }
                if pts.count == 1 {
                    ctx.fill(Path(ellipseIn: CGRect(x: pts[0].x - w / 2, y: pts[0].y - w / 2, width: w, height: w)), with: .color(.red.opacity(0.45)))
                } else {
                    var p = Path(); p.addLines(pts)
                    ctx.stroke(p, with: .color(.red.opacity(0.45)), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
                }
            }
            if let h = hover {
                ctx.stroke(Path(ellipseIn: CGRect(x: h.x - w / 2, y: h.y - w / 2, width: w, height: w)), with: .color(.white), lineWidth: 1.5)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active(let p) = phase { hover = p } else { hover = nil }
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                hover = v.location
                current.append(CGPoint(x: min(1, max(0, v.location.x / size.width)), y: min(1, max(0, v.location.y / size.height))))
            }
            .onEnded { _ in
                if !current.isEmpty { store.eraseStrokes.append(current) }
                current = []
            })
        .allowsHitTesting(!store.erasing)
    }
}

struct EraseBar: View {
    @EnvironmentObject var store: Store
    @ObservedObject var item: PhotoItem

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if store.erasing {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(store.status) }
                } else {
                    Text(store.eraseStrokes.isEmpty ? "用笔刷涂抹要消除的地方（路人、杂物、电线…）" : "涂好了按「消除」或回车")
                }
            }
            .font(.caption).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())

            HStack(spacing: 10) {
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.secondary)
                Slider(value: $store.eraseBrush, in: 0.006...0.08).frame(width: 110)
                    .help(Text("笔刷大小"))
                Image(systemName: "circle.fill").font(.system(size: 13)).foregroundStyle(.secondary)
                Divider().frame(height: 18)
                Button { store.eraseStrokes = [] } label: { Image(systemName: "xmark.circle") }
                    .help(Text("清除笔迹")).accessibilityLabel(Text("清除笔迹")).disabled(store.eraseStrokes.isEmpty || store.erasing)
                Button { store.undoErase() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help(Text("撤销上一次消除")).accessibilityLabel(Text("撤销上一次消除")).disabled(item.patches.isEmpty || store.erasing)
                Button { store.eraseNow() } label: { Label("消除", systemImage: "eraser").fixedSize() }
                    .buttonStyle(.borderedProminent).tint(Color.toolula)
                    .disabled(store.eraseStrokes.isEmpty || store.erasing)
                    .keyboardShortcut(.return, modifiers: [])
                Button("完成") { store.eraseMode = false }.fixedSize()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 6)
        }
    }
}
