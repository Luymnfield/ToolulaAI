import SwiftUI

// 修图 / 绘图 / 视频页共用的界面零件: 深灰画布、空状态、浮动操作条、折叠的模型选择、固定在底部的主按钮区

/// 深灰的看图区 (判断颜色和曝光更准, 和专业修图软件一样)
struct DarkCanvas<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ZStack {
            Color(white: 0.13)
            content
        }
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 画布上的空状态
struct CanvasEmpty<Extra: View>: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 46, weight: .light)).foregroundStyle(.white.opacity(0.55))
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.92))
            Text(subtitle).font(.callout).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
            extra.padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: 480)
    }
}

/// 浮在作品下面的一条操作按钮
struct FloatingBar<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 2) { content }
            .buttonStyle(FloatingBarButton())
            .padding(3)
            .background(Color(white: 0.22), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.08)))
    }
}

struct FloatingBarButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .foregroundStyle(.white.opacity(configuration.isPressed ? 1 : 0.8))
            .background(configuration.isPressed ? Color.white.opacity(0.18) : .clear, in: Capsule())
            .contentShape(Capsule())
    }
}

/// 生成中的进度 (画布上)
struct CanvasProgress: View {
    let value: Double?
    let stage: String
    let detail: Text?
    let stop: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            ProgressView(value: value).frame(width: 320).tint(Color.toolula)
            Text(stage).font(.headline).foregroundStyle(.white.opacity(0.92))
            if let detail { detail.font(.callout).foregroundStyle(.white.opacity(0.6)).monospacedDigit() }
            Button("停止", action: stop)
        }
    }
}

/// 模型: 平时只显示当前用的是哪个, 点开再换
struct ModelDisclosure<Picker: View>: View {
    let name: String
    let ready: Bool
    @Binding var open: Bool
    @ViewBuilder var picker: Picker

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Circle().fill(ready ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(verbatim: name).font(.callout.weight(.medium)).lineLimit(1)
                    if !ready { Text("需要下载").font(.caption2).foregroundStyle(.orange) }
                    Spacer()
                    Text(open ? "收起" : "更换").font(.caption).foregroundStyle(.secondary)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { picker }
        }
    }
}

/// 右边设置区: 上面可以滚动的卡片, 下面固定的主按钮区
struct SettingsColumn<Cards: View, Footer: View>: View {
    @ViewBuilder var cards: Cards
    @ViewBuilder var footer: Footer
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) { cards }.padding(12)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) { footer }
                .padding(12)
                .background(.bar)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// 提示词输入框
struct PromptEditor: View {
    @Binding var text: String
    var height: CGFloat = 110
    var body: some View {
        TextEditor(text: $text)
            .font(.callout).frame(height: height)
            .scrollContentBackground(.hidden).padding(5)
            .background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
    }
}
