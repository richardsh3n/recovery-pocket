import SwiftUI
import WidgetKit

struct PocketEntry: TimelineEntry { let date: Date; let status: PocketStatus }
struct PocketProvider: TimelineProvider {
    func placeholder(in context: Context) -> PocketEntry { PocketEntry(date: .now, status: BatteryDemo.status()) }
    func getSnapshot(in context: Context, completion: @escaping (PocketEntry) -> Void) { completion(PocketEntry(date: .now, status: context.isPreview ? BatteryDemo.status() : StatusStore.read())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PocketEntry>) -> Void) {
        let now = Date(), status = StatusStore.read()
        // Future entries expire the display; they never manufacture future battery values.
        var dates = [now]
        if let measured = status.measuredAt {
            let expiry = min(measured.addingTimeInterval(7201), Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: measured))!)
            if expiry > now { dates.append(expiry) }
        }
        completion(Timeline(entries: dates.map { PocketEntry(date: $0, status: status) }, policy: .after(now.addingTimeInterval(1800))))
    }
}
struct PocketWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PocketEntry
    private var mint: Color {
        #if os(iOS)
        Color(red: PocketPalette.green.0, green: PocketPalette.green.1, blue: PocketPalette.green.2)
        #else
        Color(red: PocketPalette.nightGreen.0, green: PocketPalette.nightGreen.1, blue: PocketPalette.nightGreen.2)
        #endif
    }
    private var widgetInk: Color {
        #if os(iOS)
        family == .systemSmall || family == .systemMedium ? Color(red: PocketPalette.ink.0, green: PocketPalette.ink.1, blue: PocketPalette.ink.2) : Color.primary
        #else
        .white
        #endif
    }
    private var widgetPaper: Color {
        #if os(iOS)
        Color(red: PocketPalette.paper.0, green: PocketPalette.paper.1, blue: PocketPalette.paper.2)
        #else
        .black
        #endif
    }
    private var value: Int? { entry.status.displayValue(at: entry.date) }
    private var label: String { entry.status.demo ? "演示" : value == nil ? "待同步" : "身体电量" }
    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                Gauge(value: Double(value ?? 5), in: 5...100) { if entry.status.demo { Text("演示").font(.caption2) } else { Image(systemName: "battery.75percent") } } currentValueLabel: { Text(value.map(String.init) ?? "—") }.gaugeStyle(.accessoryCircular)
            case .accessoryInline:
                Text("\(label) \(value.map(String.init) ?? "—")")
            case .accessoryRectangular:
                VStack(alignment: .leading) { HStack { Text(label); Spacer(); Text(value.map(String.init) ?? "—").bold() }; Gauge(value: Double(value ?? 5), in: 5...100) { EmptyView() }; Text(timestamp).font(.caption2) }
            #if os(watchOS)
            case .accessoryCorner:
                Text(value.map(String.init) ?? "—").widgetLabel { Text(label) }
            #endif
            default:
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Label(label, systemImage: "battery.75percent").font(.caption); Spacer(); Text("实验估计").font(.caption2).foregroundStyle(.secondary) }
                    HStack(alignment: .firstTextBaseline) { Text(value.map(String.init) ?? "—").font(.system(size: 42, weight: .light, design: .rounded)); Spacer(); if showEnergy && value != nil { VStack(alignment: .trailing) { Text("今日补充 +\(entry.status.charged)"); Text("今日消耗 −\(entry.status.drained)") }.font(.caption) } }
                    Gauge(value: Double(value ?? 5), in: 5...100) { EmptyView() }
                    Text(timestamp).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.foregroundStyle(widgetInk).privacySensitive().tint(mint).containerBackground(for: .widget) { widgetPaper }
            .widgetURL(URL(string: "recoverypocket://battery"))
            .accessibilityLabel("\(label)，\(value.map(String.init) ?? "暂无新鲜数据")，\(timestamp)")
    }
    private var showEnergy: Bool {
        #if os(iOS)
        return family == .systemMedium
        #else
        return false
        #endif
    }
    private var timestamp: String {
        guard let measured = entry.status.measuredAt else { return "打开 App 连接健康数据" }
        return value == nil ? "数据已过期 · 打开 App 刷新" : "观测至 \(measured.formatted(date: .omitted, time: .shortened))"
    }
}
struct PocketBatteryWidget: Widget {
    let kind = "PocketBattery"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PocketProvider()) { PocketWidgetView(entry: $0) }
            .configurationDisplayName("身体电量参考")
            .description("查看电量参考和观测时间；过期数据自动隐藏。")
            #if os(watchOS)
            .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
            #else
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
            #endif
    }
}
@main struct PocketWidgetBundle: WidgetBundle { var body: some Widget { PocketBatteryWidget() } }
