import SwiftUI
import Charts

private enum WatchStyle {
    static let green = Color(red: PocketPalette.nightGreen.0, green: PocketPalette.nightGreen.1, blue: PocketPalette.nightGreen.2)
    static let mint = Color(red: PocketPalette.mint.0, green: PocketPalette.mint.1, blue: PocketPalette.mint.2)
    static let drain = Color.orange
}
@main struct RecoveryWatchApp: App {
    @StateObject private var bridge = WatchBridge.shared
    @State private var homeID = UUID()
    var body: some Scene { WindowGroup { WatchHome().id(homeID).environmentObject(bridge).onOpenURL { url in if url.scheme == "recoverypocket" && url.host == "battery" { homeID = UUID() } } } }
}
struct WatchHome: View {
    @EnvironmentObject private var bridge: WatchBridge
    private var status: PocketStatus { bridge.status }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("POCKET").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .firstTextBaseline, spacing: 9) {
                                Text(status.displayValue(at: context.date).map(String.init) ?? "—").font(.system(size: 56, weight: .light)).monospacedDigit().foregroundStyle(WatchStyle.green)
                                VStack(alignment: .leading) { Text(status.scoreMeaning.title); Text(status.demo ? "演示数据":status.usesStateEstimate ? "非剩余电量":"实验估计").foregroundStyle(.secondary) }.font(.caption2)
                            }
                            ProgressView(value: Double(status.displayValue(at: context.date) ?? 0), total: 100).tint(WatchStyle.green)
                            Text(status.isFresh(at: context.date) ? "观测至 \(status.displayDate!.formatted(date: .omitted, time: .shortened))" : "暂无新鲜数据 · 请同步").font(.caption2).foregroundStyle(.secondary)
                            if status.isFresh(at: context.date) && !status.usesStateEstimate {
                                HStack { amount("补充", value: "+\(status.charged)", color: WatchStyle.green); Spacer(); amount("消耗", value: "−\(status.drained)", color: WatchStyle.drain) }
                            }
                        }
                    }
                    if let action=status.visibleAction(at:Date()){Text("今天的一步").font(.caption2).foregroundStyle(.secondary);Text(action).font(.caption)}
                    NavigationLink("记录此刻精力"){WatchFeeling()}
                    Text(status.scoreMeaning.headline).font(.caption2).foregroundStyle(.secondary)
                    Text(status.evidenceLabel).font(.caption2).foregroundStyle(.secondary)
                    Divider()
                    if status.usesStateEstimate {
                        NavigationLink { ScrollView { VStack(alignment:.leading,spacing:12) { Text(status.scoreMeaning.title+"依据").font(.headline);Text(status.scoreMeaning.detail);Text(status.evidenceLabel); if let estimate=status.stateEstimate { Text("参考范围 \(estimate.lower)–\(estimate.upper) · 未校准"); Text(estimate.note) }; Text("状态估计不换算为补充或消耗。") }.font(.caption) } } label: { row("状态依据",icon:"waveform.path.ecg",value:"查看") }; Divider()
                    } else {
                        NavigationLink { WatchRhythm(status: status) } label: { row("今日电量回顾", icon: "chart.xyaxis.line", value: "查看") }; Divider()
                    }
                    NavigationLink { WatchRecovery(status: status) } label: { row("恢复参考", icon: "waveform.path.ecg", value: status.recoverySummary?.recovery.map(String.init) ?? "—") }; Divider()
                    NavigationLink { WatchDayHRV(status: status) } label: { row("日间 HRV", icon: "heart", value: status.dayHRV.map { String(format:"%.0f ms",$0.sdnn) } ?? "—") }; Divider()
                    NavigationLink { WatchSleep(status: status) } label: { row("睡眠", icon: "moon", value: shortDuration(status.recoverySummary?.sleepHours)) }; Divider()
                    NavigationLink { WatchRest() } label: { row("短休息", icon: "cup.and.saucer", value: "计时") }
                    Button("从 iPhone 同步") { bridge.requestLatest() }.font(.caption)
                    Text(bridge.connection).font(.caption2).foregroundStyle(.secondary)
                    if status.demo { Text("合成演示 · 非你的健康数据").font(.caption2).foregroundStyle(WatchStyle.green) }
                }.padding(.horizontal, 6)
            }.toolbar(.hidden, for: .navigationBar)
        }.tint(WatchStyle.green).buttonStyle(.plain)
    }
    private func amount(_ title: String, value: String, color: Color) -> some View { VStack(alignment: .leading, spacing: 2) { Text(title).font(.caption2).foregroundStyle(.secondary); Text(value).font(.system(size: 23, weight: .light)).monospacedDigit().foregroundStyle(color) } }
    private func row(_ title: String, icon: String, value: String) -> some View { HStack(spacing: 6) { Image(systemName: icon).frame(width: 17); Text(title); Spacer(); Text(value).foregroundStyle(WatchStyle.green) }.font(.caption).frame(minHeight: 44) }
}
private func shortDuration(_ hours: Double?) -> String {
    guard let hours, hours.isFinite, hours >= 0 else { return "—" }
    let minutes = Int((hours * 60).rounded()); return "\(minutes / 60)时\(minutes % 60)分"
}
private struct WatchRhythm: View {
    let status: PocketStatus
    @State private var selected: Date?
    private var points: [BatteryPoint] { status.points.filter { Calendar.current.isDateInToday($0.date) } }
    private var point: BatteryPoint? { guard let selected, let row = points.min(by: { abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected)) }), abs(row.date.timeIntervalSince(selected)) <= 1800 else { return nil }; return row }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 12) {
            if status.demo { Text("演示数据").font(.caption2).foregroundStyle(WatchStyle.green) }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                dailySummary(at: context.date)
            }
            Chart {
                ForEach(points) { row in if let value = row.value { PointMark(x: .value("时间", row.date), y: .value("电量", value)).symbolSize(15).foregroundStyle(row.mode.contains("补充") ? WatchStyle.mint : WatchStyle.drain) } }
                if let point { RuleMark(x: .value("选中", point.date)).foregroundStyle(WatchStyle.green.opacity(0.5)) }
            }.chartYScale(domain: 0...100).chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { axis in AxisValueLabel(anchor:.center) { if let date = axis.as(Date.self) { Text(String(format: "%02d", Calendar.current.component(.hour, from: date))) } } } }.chartXSelection(value: $selected).chartGesture { proxy in SpatialTapGesture().onEnded { proxy.selectXValue(at: $0.location.x) } }.frame(height: 130)
            if let point { Text("\(point.date.formatted(date: .omitted, time: .shortened)) · \(point.value.map { String(Int($0.rounded())) } ?? "缺少观测")").font(.caption); Text(point.mode).font(.caption2).foregroundStyle(.secondary) }
            else { Text(points.isEmpty ? "暂无今日观测" : "轻点曲线查看时段").font(.caption2).foregroundStyle(.secondary) }
            if status.isFresh(at: .now), let lower = status.lower, let upper = status.upper {
                Text("当前估计范围 \(lower)–\(upper) · 未校准").font(.caption2)
            }
            Text("没有记录的时段留空。轻点曲线可以回看已有观测。").font(.caption2).foregroundStyle(.secondary)
        } }.navigationTitle("今日电量回顾")
    }

    private func dailySummary(at now: Date) -> some View {
        let stats = DailyBatteryStatistics.calculate(points: status.points, day: now, now: now)
        return VStack(alignment: .leading, spacing: 8) {
            if stats.coveredSeconds > 0 {
                HStack {
                    summaryValue("曲线补充", "+\(Int(stats.charged.rounded()))", color: WatchStyle.mint)
                    Spacer(minLength: 8)
                    summaryValue("曲线消耗", "−\(Int(stats.drained.rounded()))", color: WatchStyle.drain)
                }
                if let low = stats.minimum, let high = stats.maximum {
                    Text("今日曲线范围 \(Int(low.rounded()))–\(Int(high.rounded())) 点").font(.caption)
                }
                let duration = stats.coveredSeconds < 60 ? "不足 1 分钟" : shortDuration(stats.coveredSeconds / 3600)
                Text("可比较曲线覆盖 \(duration)").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("今天的曲线点还不足以比较补充和消耗。").font(.caption)
                Text("有新记录后，在 iPhone 打开 App 刷新。").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func summaryValue(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.title3).monospacedDigit().foregroundStyle(color)
        }
    }
}
private struct WatchRecovery: View {
    let status: PocketStatus
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 12) {
        if status.demo { Text("演示数据").font(.caption2).foregroundStyle(WatchStyle.green) }
        if let summary = status.recoverySummary {
            Text(summary.date.formatted(.dateTime.month().day())).font(.caption2).foregroundStyle(.secondary)
            Text(summary.recovery.map(String.init) ?? "—").font(.system(size: 48, weight: .light)).foregroundStyle(WatchStyle.green)
            Text("\(summary.baselineNights) 个有效历史夜晚").font(.caption2)
            if let basis=summary.recoveryBasis { Text(basis).font(.caption2).foregroundStyle(.secondary) }
            Divider(); LabeledContent("HRV · SDNN", value: summary.hrv.map { String(format: "%.0f ms", $0) } ?? "—").font(.caption)
            LabeledContent("睡眠心率", value: summary.heartRate.map { String(format: "%.0f 次/分", $0) } ?? "—").font(.caption)
            Text(summary.recoveryModelRevision != nil ? "65 接近个人惯常状态；不是剩余电量。由 iPhone 计算同步。" : "旧版恢复摘要；请在 iPhone 刷新。").font(.caption2).foregroundStyle(.secondary)
        } else { Text("请在 iPhone 刷新，获取恢复摘要。").font(.caption) }
    } } .navigationTitle("恢复参考") }
}
private struct WatchSleep: View {
    let status: PocketStatus
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 12) {
        if status.demo { Text("演示数据").font(.caption2).foregroundStyle(WatchStyle.green) }
        if let summary = status.recoverySummary {
            Text(summary.date.formatted(.dateTime.month().day())).font(.caption2).foregroundStyle(.secondary)
            Text(shortDuration(summary.sleepHours)).font(.system(size: 28, weight: .light)).foregroundStyle(WatchStyle.green)
            Text("只计算睡眠记录，卧床不计为睡眠。摘要日期如不是今天，请在手机刷新。").font(.caption2).foregroundStyle(.secondary)
        } else { Text("请在 iPhone 刷新，获取睡眠摘要。").font(.caption) }
    } }.navigationTitle("睡眠") }
}
private struct WatchRest: View {
    @AppStorage("shortRestEnd") private var end = 0.0
    var body: some View { ScrollView { VStack(spacing: 12) {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(ceil(end - context.date.timeIntervalSince1970)))
            Text(remaining > 0 ? String(format: "%02d:%02d", remaining / 60, remaining % 60) : end > 0 ? "休息结束" : "留一点空白").font(.system(size: remaining > 0 ? 40 : 22, weight: .light)).monospacedDigit().foregroundStyle(WatchStyle.green)
        }
        HStack { ForEach([5, 10, 20], id: \.self) { minutes in Button { end = Date().addingTimeInterval(Double(minutes * 60)).timeIntervalSince1970 } label: { Text("\(minutes)分").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) } } }.font(.caption)
        if end > 0 { Button("结束计时") { end = 0 }.font(.caption) }
        Text("只计时，不自动补充电量。离开页面仍按结束时间计算；无后台提醒。").font(.caption2).foregroundStyle(.secondary)
    } }.navigationTitle("短休息") }
}

private struct WatchDayHRV: View {
    let status: PocketStatus
    var body: some View { ScrollView { VStack(alignment:.leading,spacing:12) {
        if status.demo { Text("合成演示").font(.caption2).foregroundStyle(WatchStyle.green) }
        if let row = status.dayHRV {
            Text(String(format:"%.0f ms",row.sdnn)).font(.system(size:40,weight:.light)).foregroundStyle(WatchStyle.green)
            Text(row.label).font(.caption)
            Text(row.date.formatted(date:.abbreviated,time:.shortened)).font(.caption2).foregroundStyle(.secondary)
            Text("\(row.baselineDays) 个可比历史日").font(.caption2)
            Text("采样时的参考，不代表现在，也不是心理压力测量。由 iPhone 分析并同步。").font(.caption2).foregroundStyle(.secondary)
        } else { Text("暂无安静候选采样，请在手机查看已有 HRV 记录。").font(.caption) }
    } } .navigationTitle("日间 HRV") }
}

private struct WatchFeeling:View {
    @EnvironmentObject private var bridge:WatchBridge
    @State private var energy:Int?
    @State private var sent=false
    var body:some View {VStack(spacing:10){Text("此刻精力").font(.headline);ForEach(1...5,id:\.self){value in Button("\(value) / 5"){energy=value}.tint(energy == value ? WatchStyle.green:.gray)};Button(sent ? "已提交系统传送":"发送到 iPhone"){if let energy{bridge.sendCheckIn(energy:energy);sent=bridge.connection.contains("已交给")}}.disabled(energy == nil || sent);Text(bridge.connection).font(.caption2)}.navigationTitle("自评")}
}
