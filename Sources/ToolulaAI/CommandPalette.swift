import SwiftUI

/// ⌘K 命令面板: 搜索对话、跳到各页面、切换对话模型、新建对话、导出诊断……全程键盘操作。
struct PaletteCommand: Identifiable {
    enum Kind { case action, page, conversation, model, setting }
    let id: String
    let kind: Kind
    let icon: String
    let title: String
    var subtitle: String = ""
    var keywords: String = ""
    let run: @MainActor () -> Void

    /// 搜索打分: 0 = 不匹配。标题开头 > 标题包含 > 关键词/副标题包含 > 字母按顺序出现
    func score(_ query: String) -> Int {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return 1 }
        let t = title.lowercased()
        if t.hasPrefix(q) { return 100 }
        if t.contains(q) { return 80 }
        let extra = (subtitle + " " + keywords).lowercased()
        if extra.contains(q) { return 60 }
        // 所有词都出现
        let words = q.split(separator: " ")
        if words.count > 1, words.allSatisfy({ t.contains($0) || extra.contains($0) }) { return 50 }
        // 子序列 (如 "nc" 匹配 "new chat")
        var it = t.makeIterator()
        for ch in q where ch != " " {
            var found = false
            while let c = it.next() { if c == ch { found = true; break } }
            if !found { return 0 }
        }
        return 20
    }
}

enum PaletteSearch {
    static func filter(_ cmds: [PaletteCommand], _ query: String, limit: Int = 60) -> [PaletteCommand] {
        let scored = cmds.enumerated().compactMap { i, c -> (Int, Int, PaletteCommand)? in
            let s = c.score(query)
            return s > 0 ? (s, i, c) : nil
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }.prefix(limit).map(\.2)
    }
}

struct CommandPalette: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var chat: ChatStore
    @ObservedObject var models = ModelManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    nonisolated(unsafe) static var seed = ""      // 自测用: 打开时预填的搜索词
    @State private var query = CommandPalette.seed
    @State private var index = 0
    @FocusState private var focused: Bool

    var commands: [PaletteCommand] {
        var c: [PaletteCommand] = []
        c.append(.init(id: "new", kind: .action, icon: "square.and.pencil", title: String(localized: "新建对话"), keywords: "new chat") {
            app.section = .chat; chat.newConversation()
        })
        c.append(.init(id: "quick", kind: .action, icon: "sparkles", title: String(localized: "快速提问小窗"), subtitle: HotKeyCenter.shared.quickAsk.display, keywords: "quick ask") {
            QuickAsk.shared.show()
        })
        for s in AppSection.allCases {
            c.append(.init(id: "page-\(s.rawValue)", kind: .page, icon: s.icon, title: String(localized: "前往：\(String(localized: String.LocalizationValue(s.rawValue)))"),
                           keywords: "\(s) go page \(s.rawValue)") { app.section = s })
        }
        c.append(.init(id: "settings", kind: .setting, icon: "gearshape", title: String(localized: "打开设置"), subtitle: "⌘,", keywords: "settings preferences") {
            openSettings()
        })
        c.append(.init(id: "diag", kind: .action, icon: "stethoscope", title: String(localized: "导出诊断报告"), keywords: "diagnostics log") {
            Diagnostics.exportAndReveal()
        })
        for a in AppAppearance.allCases {
            c.append(.init(id: "appearance-\(a.rawValue)", kind: .setting, icon: "circle.lefthalf.filled", title: String(localized: "外观：\(a.title)"), keywords: "appearance theme dark light") {
                AppAppearance.apply(a)
            })
        }
        let current = chat.current
        for m in models.chatModels {
            let isCurrent = (current?.model ?? models.chatModel) == m.id
            c.append(.init(id: "model-\(m.id)", kind: .model, icon: isCurrent ? "checkmark.circle.fill" : "cpu",
                           title: String(localized: "对话模型：\(m.displayName)"), subtitle: m.isCloud ? String(localized: "云端") : String(localized: "本地"),
                           keywords: "model \(m.id)") {
                models.chatModel = m.id
                if let id = chat.selected, !chat.running.contains(id) { chat.update(id) { $0.model = m.id }; chat.save() }
            })
        }
        for conv in chat.conversations where !conv.messages.isEmpty {
            let title = conv.title.isEmpty ? String(localized: "新对话") : conv.title
            c.append(.init(id: "conv-\(conv.id)", kind: .conversation, icon: "bubble.left", title: title,
                           subtitle: conv.updated.formatted(date: .abbreviated, time: .shortened),
                           keywords: conv.messages.prefix(4).map { String($0.text.prefix(200)) }.joined(separator: " ")) {
                app.section = .chat; chat.selected = conv.id
            })
        }
        return c
    }

    var body: some View {
        let results = PaletteSearch.filter(commands, query)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("搜索命令、页面、对话、模型…", text: $query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($focused)
                    .onSubmit { run(results) }
                    .accessibilityLabel(Text("命令面板搜索"))
                Text("esc").font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { i, cmd in
                            row(cmd, selected: i == index)
                                .id(i)
                                .onTapGesture { index = i; run(results) }
                        }
                        if results.isEmpty { Text("没有匹配的结果").foregroundStyle(.secondary).padding(20) }
                    }
                    .padding(6)
                }
                .onChange(of: index) { _, i in proxy.scrollTo(i) }
            }
        }
        .frame(width: 620, height: 420)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in index = 0 }
        .onKeyPress(.downArrow) { index = min(index + 1, max(results.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
        .onExitCommand { dismiss() }
    }

    func row(_ c: PaletteCommand, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: c.icon).frame(width: 22).foregroundStyle(selected ? .white : .secondary).accessibilityHidden(true)
            Text(c.title).lineLimit(1)
            Spacer()
            if !c.subtitle.isEmpty { Text(c.subtitle).font(.caption).foregroundStyle(selected ? .white.opacity(0.85) : .secondary).lineLimit(1) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .foregroundStyle(selected ? .white : .primary)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.toolula : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    func run(_ results: [PaletteCommand]) {
        guard results.indices.contains(index) else { return }
        let cmd = results[index]
        dismiss()
        DispatchQueue.main.async { cmd.run() }
    }
}
