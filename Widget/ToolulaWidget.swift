import SwiftUI
import WidgetKit

// Leonix 桌面小组件: 一键开始对话 / 修图 / 绘图 / 视频 (点按钮打开 Leonix 对应的页面)

struct ToolulaEntry: TimelineEntry { let date: Date }

struct ToolulaProvider: TimelineProvider {
    func placeholder(in context: Context) -> ToolulaEntry { ToolulaEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (ToolulaEntry) -> Void) { completion(ToolulaEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ToolulaEntry>) -> Void) {
        completion(Timeline(entries: [ToolulaEntry(date: .now)], policy: .never))
    }
}

private let green = Color(red: 0.29, green: 0.78, blue: 0.52)
private let card = Color.white.opacity(0.13)

struct Logo: View {
    var size: CGFloat
    var body: some View {
        if let u = Bundle.main.url(forResource: "logo", withExtension: "png"), let img = NSImage(contentsOf: u) {
            Image(nsImage: img).resizable().interpolation(.high).desaturatedWhenTinted().frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            Image(systemName: "sparkles").font(.system(size: size * 0.6)).foregroundStyle(green).frame(width: size, height: size)
        }
    }
}

extension Image {
    /// 桌面着色模式下把图片变成灰度，而不是整块染成单色
    @ViewBuilder func desaturatedWhenTinted() -> some View {
        if #available(macOS 15.0, *) { self.widgetAccentedRenderingMode(.desaturated) } else { self }
    }
}

struct RoundButton: View {
    let icon: String
    let title: LocalizedStringKey
    let url: String
    var body: some View {
        Link(destination: URL(string: url)!) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 19, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(card))
                Text(title).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct ToolulaWidgetView: View {
    @Environment(\.widgetFamily) var family
    var entry: ToolulaEntry

    var body: some View {
        switch family {
        case .systemSmall: small
        default: medium
        }
    }

    var ask: some View {
        Link(destination: URL(string: "toolula://chat")!) {
            HStack(spacing: 10) {
                Logo(size: 26)
                Text("问问 Leonix…").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).frame(height: 50)
            .background(Capsule().fill(card))
        }
    }

    var medium: some View {
        VStack(spacing: 12) {
            ask
            HStack(spacing: 4) {
                RoundButton(icon: "camera.filters", title: "修图", url: "toolula://photo/add")
                RoundButton(icon: "paintbrush.pointed", title: "绘图", url: "toolula://image")
                RoundButton(icon: "film", title: "视频", url: "toolula://video")
                RoundButton(icon: "cursorarrow.click", title: "操作电脑", url: "toolula://chat/computer")
            }
        }
        .padding(4)
    }

    var small: some View {
        Link(destination: URL(string: "toolula://chat")!) {
            VStack(alignment: .leading, spacing: 10) {
                Logo(size: 44)
                Spacer(minLength: 0)
                Text("问问 Leonix").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Text("对话 · 修图 · 绘图").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

struct ToolulaAskWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ToolulaAsk", provider: ToolulaProvider()) { entry in
            ToolulaWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(white: 0.09) }
        }
        .configurationDisplayName("Leonix")
        .description("问问 Leonix，或一键开始修图、绘图、生成视频")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct ToolulaWidgets: WidgetBundle {
    var body: some Widget { ToolulaAskWidget() }
}
