import AppKit
import SwiftUI

/// 后台常驻 (可选): 关闭窗口后留在菜单栏, 自动化继续运行
enum BackgroundMode {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "backgroundMode") }
}

struct MenuBarContent: View {
    @EnvironmentObject var automations: AutomationStore
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("打开 Leonix") { show(nil) }
        Divider()
        if let id = automations.runningTask, let t = automations.tasks.first(where: { $0.id == id }) {
            Text("正在运行：\(t.name)")
        } else {
            Text("\(automations.tasks.filter(\.enabled).count) 个自动化任务待命")
        }
        Button("新对话") { show(.chat) }
        Button("自动化") { show(.automation) }
        Divider()
        Button("退出 Leonix") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    func show(_ section: AppSection?) {
        NSApp.setActivationPolicy(.regular)
        if let section { app.section = section }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 设置开关: 后台常驻
struct BackgroundToggle: View {
    @AppStorage("backgroundMode") private var backgroundMode = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("后台常驻（关闭窗口后在菜单栏继续运行）", isOn: $backgroundMode)
            Text("打开后，关闭窗口不会退出：Leonix 留在屏幕顶部的菜单栏，自动化照常运行。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 8)
    }
}
