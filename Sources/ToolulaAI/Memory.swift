import Foundation
import SwiftUI

/// 一条长期记忆
struct MemoryItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var created = Date()
    var shortId: String { String(id.uuidString.prefix(6)).lowercased() }
}

/// 长期记忆: AI 记住的关于用户的事, 每个新对话都会带上
@MainActor
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()

    @Published var items: [MemoryItem] = [] { didSet { save() } }
    @Published var enabled = UserDefaults.standard.object(forKey: "memoryEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "memoryEnabled") }
    }
    @Published var autoSave = UserDefaults.standard.object(forKey: "memoryAutoSave") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSave, forKey: "memoryAutoSave") }
    }
    private let file = AppPaths.dataFile("memory.json")

    init() {
        if let list = SafeJSON.load([MemoryItem].self, from: file) { items = list }
    }

    private func save() {
        SafeJSON.save(items, to: file)
    }

    @discardableResult
    func add(_ text: String) -> MemoryItem? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let same = items.first(where: { $0.text == t }) { return same }
        let m = MemoryItem(text: t)
        items.insert(m, at: 0)
        if items.count > 200 { items.removeLast(items.count - 200) }
        return m
    }

    func remove(shortId: String) -> Bool {
        let before = items.count
        items.removeAll { $0.shortId == shortId.lowercased() || $0.id.uuidString == shortId }
        return items.count < before
    }

    /// 写进系统提示的部分
    var promptSection: String {
        guard enabled else { return "" }
        var s = "\n\n【长期记忆】"
        if items.isEmpty {
            s += "（暂无）"
        } else {
            s += "关于用户的信息（[id] 内容），回答时自然地用上，不要逐条复述：\n"
            s += items.prefix(80).map { "- [\($0.shortId)] \($0.text)" }.joined(separator: "\n")
        }
        if autoSave {
            s += "\n用户透露以后有用的信息（身份、所在地、偏好、设备、项目、重要的人和约定）时用 memory_save 记一句，不重复；"
            s += "过时或用户要求忘记时用 memory_save 的 delete_id 删除。不记密码、验证码、证件号、卡号等。"
        }
        return s
    }
}

struct MemoryView: View {
    @ObservedObject var memory = MemoryStore.shared
    @State private var newText = ""
    @State private var editing: UUID?
    @State private var editText = ""
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Toggle("使用长期记忆（新对话会带上下面这些信息）", isOn: $memory.enabled)
                Toggle("允许 AI 在聊天中自动记住新信息", isOn: $memory.autoSave).disabled(!memory.enabled)
                Text("记忆只保存在这台电脑上。使用云端模型时，记忆会随对话一起发给服务商。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Label("长期记忆", systemImage: "brain") }

            Section {
                HStack {
                    TextField("手动添加，例如：我住在德国，常用 Lightroom 修图", text: $newText)
                        .onSubmit(addNew)
                    Button("添加", action: addNew).disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section {
                if memory.items.isEmpty {
                    Text("还没有记住任何事。和 AI 聊天时提到你的习惯和偏好，它会自动记下来。").foregroundStyle(.secondary)
                }
                ForEach(memory.items) { m in
                    HStack(alignment: .top) {
                        if editing == m.id {
                            TextField("", text: $editText, axis: .vertical)
                                .onSubmit { commitEdit(m) }
                            Button("保存") { commitEdit(m) }
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.text).textSelection(.enabled)
                                Text(m.created, style: .date).font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button { editing = m.id; editText = m.text } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless).help(Text("编辑")).accessibilityLabel(Text("编辑"))
                            Button { memory.items.removeAll { $0.id == m.id } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help(Text("删除")).accessibilityLabel(Text("删除"))
                        }
                    }
                }
            } header: {
                HStack {
                    Text("记住的内容（\(memory.items.count) 条）")
                    Spacer()
                    if !memory.items.isEmpty { Button("全部清空…") { confirmClear = true }.controlSize(.small) }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(Text("清空全部记忆？"), isPresented: $confirmClear) {
            Button("全部清空", role: .destructive) { memory.items.removeAll() }
            Button("取消", role: .cancel) {}
        } message: { Text("删除后无法恢复。") }
    }

    func addNew() {
        memory.add(newText)
        newText = ""
    }

    func commitEdit(_ m: MemoryItem) {
        if let i = memory.items.firstIndex(where: { $0.id == m.id }) {
            let t = editText.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { memory.items.remove(at: i) } else { memory.items[i].text = t }
        }
        editing = nil
    }
}
