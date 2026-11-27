import SwiftUI
import UniformTypeIdentifiers

/// 修图页: 左边窄缩略图条 (有照片时才出现), 中间深灰看片区, 右边分步骤的设置
struct ContentView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 0) {
            if !store.photos.isEmpty {
                FilmstripView().frame(width: 104)
                Divider()
            }
            ViewerView()
            Divider()
            InspectorView().frame(width: 330)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { openPanel(store) } label: { Label("添加照片", systemImage: "plus") }
                    .help("添加照片或文件夹（也可以直接拖进窗口）")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: Binding(get: { store.eraseMode }, set: { on in
                    store.eraseMode = on
                    if on { store.viewMode = .after }
                })) { Label("AI 消除", systemImage: "eraser") }
                    .toggleStyle(.button)
                    .labelStyle(.titleAndIcon)
                    .disabled(store.current == nil)
                    .help("用笔刷涂掉路人、杂物、电线，AI 自动补上背景")
                Menu {
                    ForEach(MaskKind.allCases) { k in
                        Button { store.addLocal(k) } label: { Label(k.label, systemImage: k.icon) }
                    }
                } label: { Label("局部", systemImage: "circle.lefthalf.filled") }
                    .labelStyle(.titleAndIcon)
                    .disabled(store.current == nil)
                    .help("只调某一块：人脸、皮肤、眼睛、天空、背景…")
                Menu {
                    Button("导出 JPEG（原尺寸）…") { store.exportJPEG(maxSide: nil) }
                    Button("导出 JPEG（长边 2048，适合发图）…") { store.exportJPEG(maxSide: 2048) }
                    Divider()
                    Button("存成 Lightroom / Photoshop 预设…") { store.savePresetForAdobe() }
                    Button("导出 LUT（Photoshop / Luminar / 视频软件通用）") { store.exportLUT() }
                } label: { Label("导出", systemImage: "square.and.arrow.up") }
                    .labelStyle(.titleAndIcon)
                    .disabled(store.selection.isEmpty || store.working)
                Menu {
                    Button("AI 选片（打分、找废片）") { store.cull() }
                    Button("AI 关键词和描述") { store.tag() }
                    Divider()
                    Button("整组对齐到当前照片（风格相同，曝光和白平衡逐张对齐）") { store.matchGroupToCurrent() }
                        .disabled(store.selection.count < 2)
                    Button("把选中的包围曝光合成 HDR") { store.mergeHDR() }
                        .disabled(store.selection.count < 2)
                    Divider()
                    ForEach(EditorApp.allCases) { app in
                        Button { store.send(to: app) } label: {
                            Label { Text(app.menuTitle) } icon: { Image(nsImage: app.icon) }
                        }
                        .disabled(!app.installed)
                    }
                } label: { Label("更多", systemImage: "ellipsis.circle") }
                    .disabled(store.selection.isEmpty || store.working)
                    .help("AI 选片、关键词、发送到其他软件")
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

// MARK: - 左边: 缩略图条

struct FilmstripView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 0) {
            Menu {
                ForEach(ListFilter.allCases) { f in
                    Button { store.filter = f } label: {
                        if store.filter == f { Label(f.rawValue.loc, systemImage: "checkmark") } else { Text(f.rawValue.locKey) }
                    }
                }
            } label: {
                Label(store.filter.rawValue.locKey, systemImage: "line.3.horizontal.decrease").font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.vertical, 8)
            .help("筛选：全部 / 精选 / 隐藏废片")

            List(selection: $store.selection) {
                ForEach(store.visiblePhotos) { item in
                    ThumbCell(item: item).tag(item.id)
                        .listRowInsets(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4))
                        .contextMenu {
                            Button("从列表移除") { store.remove(store.selection.contains(item.id) ? store.selectedItems : [item]) }
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Text("\(store.visiblePhotos.count) 张").font(.caption2).foregroundStyle(.secondary).padding(.vertical, 6)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// 缩略图: 星级、AI 已修、废片、正在处理都画在图上
struct ThumbCell: View {
    @ObservedObject var item: PhotoItem

    var body: some View {
        ZStack {
            if let t = item.thumb {
                Image(nsImage: t).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.2)
            }
            if item.busy {
                Color.black.opacity(0.45)
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 80, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .opacity(item.reject ? 0.4 : 1)
        .overlay(alignment: .bottomLeading) {
            if item.stars > 0 {
                Text(String(repeating: "★", count: item.stars)).font(.system(size: 8)).foregroundStyle(.yellow)
                    .padding(.horizontal, 3).padding(.vertical, 1).background(.black.opacity(0.55), in: Capsule()).padding(3)
            }
        }
        .overlay(alignment: .topTrailing) {
            if item.ai != nil || !item.portrait.isEmpty {
                Image(systemName: "wand.and.stars").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                    .padding(3).background(Color.toolula.opacity(0.9), in: Circle()).padding(3)
            }
        }
        .frame(maxWidth: .infinity)
        .help(Text(verbatim: item.name + (item.status.isEmpty ? "" : " · " + item.status)))
        .accessibilityLabel(Text(verbatim: item.name))
    }
}

// MARK: - 中间: 深灰看片区

struct ViewerView: View {
    @EnvironmentObject var store: Store
    /// 按住 \ 看原图 (和 Lightroom 一样)
    @State private var holdOriginal = false
    @State private var monitor: Any?

    var body: some View {
        ZStack {
            Color(white: 0.13)
            if let item = store.current {
                CompareView(item: item, mode: store.eraseMode ? .after : (holdOriginal ? .before : store.viewMode))
                    .padding(24)
                    .padding(.bottom, store.eraseMode ? 120 : 40)
                VStack {
                    Spacer()
                    if store.eraseMode {
                        EraseBar(item: item).padding(.bottom, 50)
                    } else {
                        ViewModeBar(holdOriginal: holdOriginal).padding(.bottom, 14)
                    }
                }
            } else {
                EmptyDropView()
            }
        }
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { e in
                // 输入文字时不拦截
                guard e.charactersIgnoringModifiers == "\\", !(NSApp.keyWindow?.firstResponder is NSTextView) else { return e }
                holdOriginal = e.type == .keyDown
                return nil
            }
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}

/// 浮在照片下面的小条: 修图后 / 左右对比 / 原图
struct ViewModeBar: View {
    @EnvironmentObject var store: Store
    let holdOriginal: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ViewMode.allCases) { m in
                let on = holdOriginal ? m == .before : store.viewMode == m
                Button { store.viewMode = m } label: {
                    Text(label(m)).font(.caption).padding(.horizontal, 11).padding(.vertical, 5)
                        .foregroundStyle(on ? Color.white : Color.white.opacity(0.7))
                        .background(on ? Color.white.opacity(0.18) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Text("按住 \\ 看原图").font(.caption2).foregroundStyle(.white.opacity(0.45)).padding(.horizontal, 8)
        }
        .padding(3)
        .background(Color(white: 0.22), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.08)))
    }

    func label(_ m: ViewMode) -> LocalizedStringKey {
        switch m {
        case .after: return "修图后"
        case .split: return "左右对比"
        case .before: return "原图"
        }
    }
}

/// 还没有照片: 一个大的拖放区
struct EmptyDropView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 46, weight: .light)).foregroundStyle(.white.opacity(0.55))
            Text("把照片拖到这里开始修图").font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.92))
            Text("支持 RAW、JPEG、HEIC，也可以拖入整个文件夹").font(.callout).foregroundStyle(.white.opacity(0.55))
            Button { openPanel(store) } label: { Text("选择照片…").padding(.horizontal, 10) }
                .buttonStyle(.borderedProminent).tint(Color.toolula).controlSize(.large)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: 460)
        .background(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])))
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
