import SwiftUI
import Charts

private enum PocketStyle {
    static let paper = Color(red: PocketPalette.paper.0, green: PocketPalette.paper.1, blue: PocketPalette.paper.2)
    static let ink = Color(red: PocketPalette.ink.0, green: PocketPalette.ink.1, blue: PocketPalette.ink.2)
    static let green = Color(red: PocketPalette.green.0, green: PocketPalette.green.1, blue: PocketPalette.green.2)
    static let drain = Color(red: PocketPalette.drain.0, green: PocketPalette.drain.1, blue: PocketPalette.drain.2)
    static let mint = Color(red: PocketPalette.mint.0, green: PocketPalette.mint.1, blue: PocketPalette.mint.2)
    static let rule = Color.black.opacity(0.10)
}
struct PocketEvent: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var kind: String
    var energy: Int
    var note: String
}
@MainActor final class PocketExperience: ObservableObject {
    @Published var demo = false
    @Published var demoBattery = BatteryDemo.status()
    @Published var events: [PocketEvent] = []
    @Published var demoEvents: [PocketEvent] = []
    @Published var error: String?
    @Published private(set) var canUndoDeletion = false
    private var deletedEvents: [PocketEvent] = []
    private var deletedInDemo = false
    private var eventsReadFailed = false
    private var eventsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RecoveryPocket/events-v1.json")
    }
    init() { reloadEvents() }
    func reloadEvents() {
        guard FileManager.default.fileExists(atPath: eventsURL.path) else { eventsReadFailed = false; return }
        do {
            let loaded = try JSONDecoder().decode([PocketEvent].self, from: Data(contentsOf: eventsURL))
            events = loaded; eventsReadFailed = false; error = nil
        } catch {
            eventsReadFailed = true
            self.error = "已有记录暂时无法读取，已保留原文件。解锁后重新打开 App 重试。"
        }
    }
    var recordsUnavailable: Bool { !demo && eventsReadFailed }
    var visibleEvents: [PocketEvent] { (demo ? demoEvents : events).sorted { $0.date > $1.date } }
    @discardableResult func add(_ event: PocketEvent) -> Bool {
        error = nil
        if demo { demoEvents.append(event); return true }
        guard !eventsReadFailed else { error = "已有记录未能读取，暂不覆盖文件。请解锁后重新打开 App。"; return false }
        let next = events + [event]
        do {
            let folder = eventsURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: eventsURL, options: [.atomic, .completeFileProtection])
            var url = folder; var flags = URLResourceValues(); flags.isExcludedFromBackup = true; try url.setResourceValues(flags)
            events = next; return true
        } catch { self.error = "记录未保存，请稍后重试"; return false }
    }
    @discardableResult private func commit(_ next: [PocketEvent]) -> Bool {
        if demo { demoEvents = next; error = nil; return true }
        guard !eventsReadFailed else { error = "已有记录未能读取，暂不修改文件。"; return false }
        do {
            try JSONEncoder().encode(next).write(to: eventsURL, options: [.atomic, .completeFileProtection])
            events = next; error = nil; return true
        } catch { self.error = "修改未保存，请稍后重试"; return false }
    }
    @discardableResult func update(_ event: PocketEvent) -> Bool {
        var next = demo ? demoEvents : events
        guard let index = next.firstIndex(where: { $0.id == event.id }) else { error = "这条记录已经不存在，请返回时间线。"; return false }
        next[index] = event
        return commit(next)
    }
    func remove(_ ids: Set<UUID>) {
        let rows = demo ? demoEvents : events
        let removed = rows.filter { ids.contains($0.id) }
        guard !removed.isEmpty, commit(rows.filter { !ids.contains($0.id) }) else { return }
        deletedEvents = removed; deletedInDemo = demo; canUndoDeletion = true
    }
    func undoDeletion() {
        guard canUndoDeletion, deletedInDemo == demo else { return }
        let rows = demo ? demoEvents : events
        let existing = Set(rows.map(\.id))
        guard commit(rows + deletedEvents.filter { !existing.contains($0.id) }) else { return }
        deletedEvents = []; canUndoDeletion = false
    }
    func toggleDemo(_ enabled: Bool, health: HealthStore) {
        if demo != enabled { deletedEvents = []; canUndoDeletion = false }
        demo = enabled
        if enabled {
            demoBattery = BatteryDemo.status()
            demoBattery.dayHRV = DayHRVModel.summary(DayHRVModel.demo(), now:Date())
            let rows = estimates(health, target: UserDefaults.standard.double(forKey: "sleepTarget") > 0 ? UserDefaults.standard.double(forKey: "sleepTarget") : 8)
            if let night = nights(health).max(by: { $0.date < $1.date }) {
                let result = rows.first { Calendar.current.isDate($0.date, inSameDayAs: night.date) }
                demoBattery.recoverySummary = WearableSummary(date: night.date, recovery: result?.score, sleepHours: night.sleepHours, hrv: night.hrv, heartRate: night.heartRate, baselineNights: result?.baselineNights ?? 0)
            }
        }
        WatchBridge.shared.presentationOverride = enabled ? demoBattery : nil
        WatchBridge.shared.publishHealth(health.battery)
    }
    func status(_ health: HealthStore) -> PocketStatus { demo ? demoBattery : health.battery }
    func nights(_ health: HealthStore) -> [NightRecord] {
        guard demo else { return health.snapshot?.nights ?? [] }
        let calendar = Calendar.current, today = calendar.startOfDay(for: Date())
        return (0..<43).map { offset in
            let wave = sin(Double(offset) * 0.63)
            return NightRecord(date: calendar.date(byAdding: .day, value: -offset, to: today)!, sleepHours: offset == 0 ? 7.7 : 7.6 + wave * 0.7, hrv: 52 + wave * 9, heartRate: 55 - wave * 3, hrvCount: 5, heartRateCount: 42)
        }
    }
    func estimates(_ health: HealthStore, target: Double) -> [RecoveryEstimate] {
        let days = nights(health).map { night in
            let prior = Calendar.current.date(byAdding: .day, value: -1, to: night.date)!
            return RecoveryDay(night: night, activeKcal: demo ? 420 : health.snapshot?.energy.first { Calendar.current.isDate($0.date, inSameDayAs: prior) }?.kcal, sleepMidpointHour: nil)
        }
        return RecoveryModelV2.calculate(days: days, sleepTarget: target)
    }
}

struct PocketRoot: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var health: HealthStore
    @StateObject private var experience = PocketExperience()
    @AppStorage("sleepTarget") private var sharedTarget = 8.0
    @State private var selected = 0
    private let tabs = [("今日", "house"), ("趋势", "chart.bar"), ("记录", "doc.text"), ("我的", "person")]
    var body: some View {
        TabView(selection: $selected) {
            BatteryHome().tabItem { Label("今日", systemImage: "house") }.tag(0)
            PocketBody().tabItem { Label("身体", systemImage: "heart.text.clipboard") }.tag(4)
            PocketTrends().tabItem { Label("趋势", systemImage: "chart.bar") }.tag(1)
            PocketJournal().tabItem { Label("记录", systemImage: "doc.text") }.tag(2)
            PocketProfile().tabItem { Label("我的", systemImage: "person") }.tag(3)
        }.environmentObject(experience)
            .tint(PocketStyle.green).preferredColorScheme(.light)
            .onChange(of: scenePhase) { _, phase in if phase == .active { experience.reloadEvents() } }
            .onChange(of: sharedTarget) { _, _ in if experience.demo { experience.toggleDemo(true, health: health) } else if health.requested { Task { await health.refresh() } } }
            .onChange(of: health.cacheRevision) { _, _ in experience.toggleDemo(false, health: health) }
            .onOpenURL { url in if url.scheme == "recoverypocket" { selected = 0 } }
    }
}
private struct FlatRule: View { var body: some View { Rectangle().fill(PocketStyle.rule).frame(height: 0.5).padding(.vertical, 14) } }
private struct PageHeader: View {
    let title: String
    var body: some View { VStack(alignment: .leading, spacing: 8) { Text("RECOVERY  /  POCKET").font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(.secondary); Text(title).font(.system(size: 32, weight: .semibold)) }.foregroundStyle(PocketStyle.ink) }
}
private struct DemoNote: View { @EnvironmentObject var experience: PocketExperience; var body: some View { if experience.demo { Text("演示数据 · 非你的健康记录").font(.caption).foregroundStyle(PocketStyle.green) } } }

struct BatteryHome: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var experience: PocketExperience
    @AppStorage("sleepTarget") private var target = 8.0
    @AppStorage("dailyIntentV4") private var intent = "工作"
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var calendarOpen = false
    @State private var composer = false
    @State private var resting = false
    @State private var connection = false
    private var status: PocketStatus { experience.status(health) }
    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var isFuture: Bool { day > Calendar.current.startOfDay(for: Date()) }
    private var allPoints: [BatteryPoint] { experience.demo ? experience.demoBattery.points : health.batteryHistory }
    private var dayPoints: [BatteryPoint] {
        let start = Calendar.current.startOfDay(for: day), end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return allPoints.filter { $0.date > start && $0.date <= end && $0.date <= Date() }
    }
    private var stats: DailyBatteryStatistics { DailyBatteryStatistics.calculate(points: allPoints, day: day, now: Date()) }
    private var lastNight: NightRecord? { experience.nights(health).filter { $0.sleepHours != nil && (isToday || Calendar.current.isDate($0.date, inSameDayAs: day)) }.max { $0.date < $1.date } }
    private var workouts: [PocketWorkout] { let end = Calendar.current.date(byAdding: .day, value: 1, to: day)!; return (experience.demo ? WorkoutAnalysis.demoWorkouts(day: day) : health.snapshot?.workouts ?? []).filter { $0.start < end && $0.end > day && $0.end <= Date() } }
    private var kcal: Double? { experience.demo ? (isFuture ? nil : 420) : health.snapshot?.energy.first { Calendar.current.isDate($0.date, inSameDayAs: day) }?.kcal }
    private var eventCount: Int { experience.visibleEvents.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }.count }
    private func moveDay(_ offset: Int) { day = Calendar.current.date(byAdding: .day, value: offset, to: day) ?? day }
    private func statCell(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.subheadline.weight(.medium)) }.frame(maxWidth: .infinity, alignment: .leading) }
    private var dateBar: some View {
        HStack {
            Button { moveDay(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("前一天")
            Spacer()
            Button { calendarOpen = true } label: { HStack { Text(day.formatted(.dateTime.month().day().weekday())); Image(systemName: "calendar") }.font(.subheadline).frame(minHeight: 44) }.accessibilityLabel("选择回看日期")
            Spacer()
            Button { moveDay(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.accessibilityLabel("后一天")
        }.contentShape(Rectangle()).highPriorityGesture(DragGesture(minimumDistance: 30).onEnded { value in
            if abs(value.translation.width) > 60 && abs(value.translation.width) > abs(value.translation.height) * 1.5 { moveDay(value.translation.width < 0 ? 1 : -1) }
        })
    }
    private var estimate: RecoveryEstimate? {
        guard experience.demo || health.snapshot.map({ Date().timeIntervalSince($0.fetchedAt) < 21600 }) == true,
              let result = experience.estimates(health, target: target).filter({ $0.score != nil && (isToday || Calendar.current.isDate($0.date, inSameDayAs: day)) }).last else { return nil }
        return result
    }
    private var suggestion: String { intent == "训练" ? "结合实际感受安排强度" : intent == "恢复" ? "留出一段不赶时间的休息" : "下午留出一次短休息" }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PageHeader(title: isToday ? "今天" : "电量日历")
                    dateBar
                    HStack { DemoNote(); Spacer(); if !isToday { Button("回到今天") { day = Calendar.current.startOfDay(for: Date()) }.font(.caption) } }
                    
                    TimelineView(.periodic(from:.now,by:60)) { context in
                        let value = isFuture ? nil : isToday ? status.displayValue(at:context.date) : stats.latest?.value.map { Int($0.rounded()) }
                        let stale = isToday && value == nil && status.value != nil && status.measuredAt != nil
                        VStack(alignment:.leading,spacing:16) {
                            HStack { Text("身体电量").font(.subheadline.weight(.medium)); Spacer(); Text(isToday ? "实验估计 · 未校准" : "历史估计").font(.caption).foregroundStyle(.secondary) }
                            HStack(alignment:.firstTextBaseline,spacing:10) { Text(value.map(String.init) ?? (stale ? "等待新观测" : "尚无观测")).font(.system(size:value == nil ? 30 : 96,weight:.light)).monospacedDigit().foregroundStyle(PocketStyle.green); if value != nil { Text("/ 100").font(.subheadline).foregroundStyle(.secondary) } }
                            if let value { ProgressView(value:Double(value),total:100).tint(PocketStyle.green) }
                            HStack(alignment:.top) {
                                VStack(alignment:.leading,spacing:5) {
                                    Text(value == nil ? (isFuture ? "未来日期" : stale ? "最近记录已过期" : "等待可用记录") : isToday ? status.evidenceLabel : "当天最后观测").font(.subheadline.weight(.medium))
                                    if stale, let last = status.value, let date = status.measuredAt { Text("最近观测 \(last) · " + date.formatted(date:.abbreviated,time:.shortened)).font(.subheadline).foregroundStyle(PocketStyle.green) }
                                    else if let date = isToday ? status.measuredAt : stats.latest?.date { Text("观测至 " + date.formatted(date:isToday ? .omitted : .abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer(); NavigationLink { EstimateDetails() } label: { Image(systemName:"info.circle").font(.title3).frame(width:44,height:44) }.accessibilityLabel("查看电量计算依据")
                            }
                            if (value != nil || stale) && isToday, let note = status.dataNote(at:context.date) { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
                            if value == nil && !isFuture { NavigationLink("检查健康连接与数据") { HealthConnectionView() }.font(.subheadline).buttonStyle(.bordered) }
                        }.padding(22).frame(maxWidth:.infinity,alignment:.leading).background(PocketStyle.green.opacity(0.055),in:RoundedRectangle(cornerRadius:24)).padding(.top,16)
                    }
                    FlatRule()
                    HStack {
                        amount("补充", value: stats.coveredSeconds > 0 ? String(format: "+%.1f", stats.charged) : "—", color: PocketStyle.green)
                        Rectangle().fill(PocketStyle.rule).frame(width: 0.5, height: 52).padding(.horizontal, 20)
                        amount("消耗", value: stats.coveredSeconds > 0 ? String(format: "−%.1f", stats.drained) : "—", color: PocketStyle.drain)
                    }
                    FlatRule()
                    HStack { Text(isToday ? "今天的节奏" : "当天的节奏").font(.title3.weight(.semibold)); Spacer(); NavigationLink("回看") { BatteryHistory(day: day) }.font(.subheadline) }
                    BatteryPlot(points: dayPoints, height: 130).padding(.top, 12)
                    HStack(spacing: 18) { HStack(spacing: 5) { Image(systemName: "circle.fill").foregroundStyle(PocketStyle.mint); Text("补充").foregroundStyle(PocketStyle.green) }; HStack(spacing: 5) { Image(systemName: "circle.fill").foregroundStyle(.orange); Text("消耗").foregroundStyle(PocketStyle.drain) }; Spacer(); Text("缺少记录处留空").foregroundStyle(.secondary) }.font(.caption2).padding(.top, 8)
                    FlatRule()
                    DisclosureGroup("当天数据与统计") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 20) {
                        statCell("电量最高 / 最低", stats.minimum.flatMap { low in stats.maximum.map { high in "\(Int(high.rounded())) / \(Int(low.rounded()))" } } ?? "—")
                        statCell("可比较观测", String(format: "%.1f 小时", stats.coveredSeconds / 3600))
                        statCell("活动能量", kcal.map { String(format: "%.0f kcal", $0) } ?? "暂无记录")
                        statCell("步数", experience.demo ? (isFuture ? "暂无记录" : "6,420 步") : health.snapshot?.steps?.first { Calendar.current.isDate($0.date, inSameDayAs: day) }?.count.map { String(format: "%.0f 步", $0) } ?? "暂无记录")
                        statCell("训练 / 手动记录", "\(workouts.count) 次 / \(eventCount) 条")
                    }
                    Text("历史电量按当前实验模型重算。补充与消耗只统计相邻有效观测的净变化；缺失时段不补算。").font(.caption2).foregroundStyle(.secondary).padding(.top, 14)
                    }.font(.subheadline).padding(.vertical,4)
                    FlatRule()
                    NavigationLink { WorkoutImpactView(day: day) } label: { summaryRow("训练与消耗时段", value: "查看这一天 →", icon: "figure.run") }.buttonStyle(.plain)
                    FlatRule()
                    if isToday {
                    HStack { Text("安排今天").font(.title3.weight(.semibold)); Spacer(); Text("让节奏更适合你").font(.caption).foregroundStyle(.secondary) }
                    HStack(spacing: 8) {
                        ForEach([("工作", "laptopcomputer"), ("训练", "dumbbell"), ("恢复", "leaf")], id: \.0) { item in
                            Button { intent = item.0 } label: { HStack(spacing: 6) { Image(systemName: item.1); Text(item.0) }.font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 13).foregroundStyle(intent == item.0 ? .white : PocketStyle.ink).background(intent == item.0 ? PocketStyle.green : .clear, in: Capsule()).overlay { Capsule().stroke(intent == item.0 ? .clear : PocketStyle.rule, lineWidth: 1) } }.buttonStyle(.plain)
                        }
                    }.padding(.top, 15)
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: intent == "工作" ? "cup.and.saucer" : intent == "训练" ? "figure.walk" : "leaf").font(.title3).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 6) { Text(suggestion).font(.subheadline.weight(.medium)); Text("以实际感受为准，记录后再回看变化。") .font(.caption).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                        Button { composer = true } label: { Text("记录 →").font(.subheadline) }.accessibilityLabel("记录休息或当前感受")
                    }.padding(.top, 20)
                    FlatRule()
                    Button { resting = true } label: { summaryRow("短休息", value: "5 / 10 / 20 分钟", icon: "cup.and.saucer") }; FlatRule()
                    }
                    NavigationLink { if isToday { SleepDetails() } else if let lastNight { NightDetail(night: lastNight) } else { BatteryHistory(day: day) } } label: { summaryRow(isToday ? "最近睡眠" : "当天睡眠", value: lastNight.map { "\(sleepLabel($0.sleepHours)) · \($0.date.formatted(.dateTime.month().day()))" } ?? "暂无记录", icon: "moon") }.buttonStyle(.plain)
                    FlatRule()
                    NavigationLink { RecoveryDetails(day: isToday ? estimate?.date : day) } label: { summaryRow(isToday ? "最近恢复参考" : "当天恢复参考", value: estimate.map { "\($0.score.map(String.init) ?? "—") · \($0.date.formatted(.dateTime.month().day()))" } ?? "建立基线中", icon: "waveform.path.ecg") }.buttonStyle(.plain)
                    if !health.requested && !experience.demo { Button("连接 Apple 健康") { connection = true }.buttonStyle(.borderedProminent).padding(.top, 28).disabled(health.busy) }
                    if let notice = health.notice, !experience.demo { Text(notice).font(.caption).foregroundStyle(.secondary).padding(.top, 20) }
                }.padding(24).padding(.bottom, 12)
            }.safeAreaPadding(.bottom, 24).background(PocketStyle.paper).foregroundStyle(PocketStyle.ink).toolbar(.hidden, for: .navigationBar)
                .refreshable { if experience.demo { experience.toggleDemo(true, health: health) } else { await health.refresh() } }
                .sheet(isPresented: $calendarOpen) { NavigationStack { DatePicker("选择日期", selection: $day, displayedComponents: .date).datePickerStyle(.graphical).padding(24).navigationTitle("选择日期").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { calendarOpen = false } } } }.tint(PocketStyle.green) }
                .sheet(isPresented: $composer) { EventComposer(defaultKind: intent == "训练" ? "训练" : "休息") }
                .sheet(isPresented: $resting) { PhoneRest() }
                .sheet(isPresented: $connection) { NavigationStack { HealthConnectionView() } }
        }
    }
    private func amount(_ title: String, value: String, color: Color) -> some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(.subheadline).foregroundStyle(.secondary); Text(value).font(.system(size: 32, weight: .light)).monospacedDigit().foregroundStyle(color) }.frame(maxWidth: .infinity, alignment: .leading) }
    private func summaryRow(_ name: String, value: String, icon: String) -> some View { HStack(spacing: 18) { Image(systemName: icon).font(.title2).frame(width: 26); VStack(alignment: .leading, spacing: 4) { Text(name).font(.subheadline.weight(.medium)); Text(value).font(.title3) }; Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }.foregroundStyle(PocketStyle.ink) }
}
private struct PhoneRest: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("shortRestEnd") private var end = 0.0
    var body: some View {
        NavigationStack { VStack(alignment: .leading, spacing: 28) {
            Text("给今天留一点空白").font(.title2.weight(.semibold))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(ceil(end - context.date.timeIntervalSince1970)))
                Text(remaining > 0 ? String(format: "%02d:%02d", remaining / 60, remaining % 60) : end > 0 ? "休息结束" : "准备休息")
                    .font(.system(size: 64, weight: .light)).monospacedDigit().foregroundStyle(PocketStyle.green)
            }
            HStack { ForEach([5, 10, 20], id: \.self) { minutes in Button("\(minutes) 分钟") { end = Date().addingTimeInterval(Double(minutes * 60)).timeIntervalSince1970 }.buttonStyle(.bordered) } }
            if end > 0 { Button("结束计时") { end = 0 } }
            Text("只计时，不自动补充电量。离开页面后仍按结束时间计算；无后台提醒。手机与手表计时各自独立。").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
        }.padding(24).background(PocketStyle.paper).navigationTitle("短休息").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } } }.tint(PocketStyle.green)
    }
}
private func sleepLabel(_ hours: Double?) -> String { guard let hours, hours.isFinite else { return "暂无记录" }; let minutes = Int((hours * 60).rounded()); return "\(minutes / 60)小时\(minutes % 60)分" }
private struct BatteryPlot: View {
    @State private var selectedDate: Date?
    var points: [BatteryPoint]
    var height: CGFloat = 180
    private var selectedPoint: BatteryPoint? {
        guard let selectedDate, let point = points.min(by: { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }), abs(point.date.timeIntervalSince(selectedDate)) <= 1800 else { return nil }
        return point
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
        Group {
            if points.contains(where: { $0.value != nil }) {
                Chart {
                    ForEach(points) { point in if let value = point.value { PointMark(x: .value("时间", point.date), y: .value("电量", value)).symbolSize(24).foregroundStyle(point.mode.contains("补充") ? PocketStyle.mint : .orange) } }
                    if let point = selectedPoint { RuleMark(x: .value("选中时间", point.date)).foregroundStyle(PocketStyle.green.opacity(0.4)) }
                }.chartXSelection(value: $selectedDate).chartGesture { proxy in SpatialTapGesture().onEnded { event in proxy.selectXValue(at: event.location.x) } }
                    .chartYScale(domain: 0...100).chartXAxis { AxisMarks(values: .stride(by: .hour, count: 4)) { tick in AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])); AxisValueLabel(anchor:.center) { if let date = tick.as(Date.self) { Text(String(format: "%02d:00", Calendar.current.component(.hour, from: date))) } } } }
                    .chartYAxis { AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) }.accessibilityLabel("已记录时段的电量参考，缺失留空")
            } else { VStack(alignment: .leading, spacing: 8) { Text("还没有可回看的观测").font(.subheadline); Text("读到睡眠与活动后，在这里显示日内变化。") .font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading) }
        }.frame(height: height)
        if let point = selectedPoint {
            HStack { Text(point.date.formatted(date: .omitted, time: .shortened)); Text(point.value.map { "\(Int($0.rounded())) / 100" } ?? "缺少观测"); Spacer(); Text(point.mode) }.font(.caption).foregroundStyle(PocketStyle.green)
            if let effect = point.effect {
                Text(String(format:"本段补充 %.1f · 基础消耗 %.1f · 活动 %.1f · 心率 %.2f · 日间 HRV %.2f",effect.sleepRecharge+effect.restRecharge,effect.awakeDrain,effect.activityDrain,effect.heartRateDrain,effect.hrvDrain)).font(.caption2).foregroundStyle(.secondary)
                if abs(effect.sleepHRVAdjustment) > 0.005 { Text(String(format:"睡眠 HRV 对本段补充的调节 %+.2f",effect.sleepHRVAdjustment)).font(.caption2).foregroundStyle(.secondary) }
            }
        } else if points.contains(where: { $0.value != nil }) { Text("轻点曲线，查看时段与观测值").font(.caption2).foregroundStyle(.secondary) }
        }.onChange(of: points.map(\.date)) { _, _ in selectedDate = nil }
    }
}
struct BatteryHistory: View {
    @EnvironmentObject var health: HealthStore
    @EnvironmentObject var experience: PocketExperience
    @AppStorage("sleepTarget") private var target = 8.0
    @State private var day: Date
    @State private var editing: PocketEvent?
    @State private var composer = false
    init(day: Date = Date()) { _day = State(initialValue: Calendar.current.startOfDay(for: day)) }
    private var points: [BatteryPoint] { (experience.demo ? experience.demoBattery.points : health.batteryHistory).filter { Calendar.current.isDate($0.date, inSameDayAs: day) } }
    private var night: NightRecord? { experience.nights(health).first { Calendar.current.isDate($0.date, inSameDayAs: day) } }
    private var score: Int? { experience.estimates(health, target: target).first { Calendar.current.isDate($0.date, inSameDayAs: day) }?.score }
    private var events: [PocketEvent] { experience.visibleEvents.filter { Calendar.current.isDate($0.date, inSameDayAs: day) } }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            DemoNote(); DatePicker("回看日期", selection: $day, in: ...Date(), displayedComponents: .date)
            Text("身体电量").font(.headline); BatteryPlot(points: points)
            Text("只展示保存过的观测，缺失不代表休息或零电量。").font(.caption).foregroundStyle(.secondary)
            FlatRule()
            NavigationLink { RecoveryDetails(day: day) } label: { HStack { Text("恢复参考"); Spacer(); Text(score.map(String.init) ?? "数据不足"); Image(systemName: "chevron.right").font(.caption) } }
            if let night { NavigationLink { NightDetail(night: night) } label: { HStack { Text("睡眠"); Spacer(); Text(sleepLabel(night.sleepHours)); Image(systemName: "chevron.right").font(.caption) } } }
            NavigationLink("训练与消耗时段") { WorkoutImpactView(day: day) }; FlatRule(); HStack { Text("当天记录").font(.headline); Spacer(); Button("补记") { composer = true } }
            if events.isEmpty { Text(experience.recordsUnavailable ? "已有记录暂时无法读取。" : "这一天还没有记录。").font(.subheadline).foregroundStyle(.secondary) }
            ForEach(events) { event in
                Button { editing = event } label: { VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(event.kind); Spacer(); Text(event.date.formatted(date: .omitted, time: .shortened)) }
                    Text("精力 \(event.energy)/5").foregroundStyle(PocketStyle.green)
                    if !event.note.isEmpty { Text(event.note).foregroundStyle(.secondary) }
                }.font(.subheadline).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain); Divider()
            }
            Text("把同一天的观测与记录放在一起回看，不据此判断某个习惯导致了状态变化。").font(.caption).foregroundStyle(.secondary)
        }.padding(24) }.safeAreaPadding(.bottom, 24).background(PocketStyle.paper).navigationTitle("一天回看").toolbar(.visible, for: .navigationBar)
        .sheet(item: $editing) { EventComposer(defaultKind: $0.kind, editing: $0) }
        .sheet(isPresented: $composer) { EventComposer(defaultKind: "自评", initialDate: day) }
    }
}
struct PocketTrends: View {
    @EnvironmentObject var health: HealthStore
    @EnvironmentObject var experience: PocketExperience
    @AppStorage("sleepTarget") private var target = 8.0
    @State private var period = 7
    @State private var metric = "恢复"
    @State private var selectedDate: Date?
    private var nights: [NightRecord] { experience.nights(health).sorted { $0.date < $1.date } }
    private var estimates: [RecoveryEstimate] { experience.estimates(health, target: target) }
    private var series: [(Date, Double)] {
        let start = Calendar.current.date(byAdding: .day, value: -(period - 1), to: Calendar.current.startOfDay(for: Date()))!
        if metric == "精力" {
            let entries = experience.visibleEvents.filter { $0.date >= start && (1...5).contains($0.energy) }
            return Dictionary(grouping: entries, by: { Calendar.current.startOfDay(for: $0.date) }).map { date, rows in (date, Double(rows.map(\.energy).reduce(0, +)) / Double(rows.count)) }.sorted { $0.0 < $1.0 }
        }
        if metric == "恢复" { return estimates.filter { $0.date >= start }.compactMap { item in item.score.map { (item.date, Double($0)) } } }
        return nights.filter { $0.date >= start }.compactMap { n in (metric == "睡眠" ? n.sleepHours : n.hrv).map { (n.date, $0) } }
    }
    private var selectedDay: Date? {
        guard let selectedDate else { return nil }
        return series.first { Calendar.current.isDate($0.0, inSameDayAs: selectedDate) }?.0
    }
    private var chartDates: ClosedRange<Date> {
        let today = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: -(period - 1), to: today)!...Calendar.current.date(byAdding: .day, value: 1, to: today)!
    }
    var body: some View {
        NavigationStack { ScrollView { VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "趋势"); DemoNote()
            Picker("观察范围", selection: $period) { Text("7天").tag(7); Text("30天").tag(30) }.pickerStyle(.segmented)
            Picker("指标", selection: $metric) { ForEach(["恢复", "睡眠", "HRV", "精力"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            if !series.isEmpty {
                Text(metric == "精力" ? "有记录日的平均自评" : "\(period)天平均").font(.subheadline).foregroundStyle(.secondary)
                Text(String(format: "%.1f", series.map(\.1).reduce(0, +) / Double(series.count)) + (metric == "睡眠" ? " 小时" : metric == "HRV" ? " ms" : metric == "精力" ? " / 5" : "")) .font(.system(size: 52, weight: .light)).foregroundStyle(PocketStyle.green)
                Chart(Array(series.enumerated()), id: \.offset) { entry in PointMark(x: .value("日期", entry.element.0, unit: .day), y: .value(metric, entry.element.1)).symbolSize(36).foregroundStyle(PocketStyle.green) }.chartXSelection(value: $selectedDate).chartGesture { proxy in SpatialTapGesture().onEnded { event in proxy.selectXValue(at: event.location.x) } }.chartXScale(domain: chartDates).chartYScale(domain: metric == "精力" ? 1.0...5.0 : metric == "恢复" ? 0.0...100.0 : 0.0...max(1, (series.map(\.1).max() ?? 1) * 1.15)).frame(height: 190)
                if let day = selectedDay {
                    NavigationLink { if metric == "恢复" { RecoveryDetails(day: day) } else { BatteryHistory(day: day) } } label: { HStack { Text(day.formatted(.dateTime.month().day())); Spacer(); Text(metric == "恢复" ? "查看这天的恢复因素 →" : "查看这一天 →") }.font(.subheadline) }
                } else { Text("轻点图表选择一天，查看详情").font(.caption).foregroundStyle(.secondary) }
                Text("\(series.count) / \(period) 天有可用记录 · 缺失留空").font(.caption).foregroundStyle(.secondary)
            } else { Text("积累记录后，趋势会出现在这里。") .foregroundStyle(.secondary).frame(height: 180) }
            if metric == "精力" { Text("同一天多条自评先取日均值；未记录日留空。自评独立于生理评分，不自动改写电量。") .font(.caption).foregroundStyle(.secondary) }
            FlatRule(); Text("对照自己的历史").font(.title3.weight(.semibold))
            Text("恢复分数和身体电量含义不同。看趋势时，也留意采样覆盖和实际感受；短期变化不能直接归因于某个习惯。") .font(.subheadline).foregroundStyle(.secondary)
            if metric == "精力" {
                ForEach(series.reversed(), id: \.0) { row in NavigationLink { BatteryHistory(day: row.0) } label: { HStack { Text(row.0.formatted(.dateTime.month().day())); Spacer(); Text(String(format: "%.1f / 5", row.1)); Image(systemName: "chevron.right").font(.caption) }.font(.subheadline).foregroundStyle(PocketStyle.ink).padding(.vertical, 10) }; Divider() }
            } else {
            ForEach(nights.suffix(period).reversed()) { night in NavigationLink { if metric == "恢复" { RecoveryDetails(day: night.date) } else { NightDetail(night: night) } } label: { HStack { Text(night.date.formatted(.dateTime.month().day())); Spacer(); Text(sleepLabel(night.sleepHours)); Image(systemName: "chevron.right").font(.caption) }.font(.subheadline).foregroundStyle(PocketStyle.ink).padding(.vertical, 10) }; Divider() }
            }
        }.padding(24) }.safeAreaPadding(.bottom, 24).background(PocketStyle.paper).toolbar(.hidden, for: .navigationBar) }
    }
}
struct SleepDetails: View {
    @EnvironmentObject var health: HealthStore
    @EnvironmentObject var experience: PocketExperience
    var body: some View { Group { if let latest = experience.nights(health).max(by: { $0.date < $1.date }) { NightDetail(night: latest) } else { Text("暂无睡眠记录").foregroundStyle(.secondary) } }.navigationTitle("睡眠").toolbar(.visible, for: .navigationBar) }
}
struct NightDetail: View {
    let night: NightRecord
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 24) { DemoNote(); Text(night.date.formatted(date: .abbreviated, time: .omitted)).font(.subheadline).foregroundStyle(.secondary); Text(sleepLabel(night.sleepHours)).font(.system(size: 38, weight: .light)).foregroundStyle(PocketStyle.green); Divider(); LabeledContent("睡眠 HRV · SDNN", value: night.hrv.map { String(format: "%.0f ms", $0) } ?? "暂无"); LabeledContent("睡眠心率", value: night.heartRate.map { String(format: "%.0f 次/分", $0) } ?? "暂无"); LabeledContent("HRV / 心率采样", value: "\(night.hrvCount) / \(night.heartRateCount)"); Text("只使用睡眠窗口内已记录的观测。不把卧床时长算作睡眠，不把 SDNN 换算成 RMSSD。") .font(.caption).foregroundStyle(.secondary) }.padding(24) }.safeAreaPadding(.bottom, 24).background(PocketStyle.paper).navigationTitle("这一夜").toolbar(.visible, for: .navigationBar) }
}
struct RecoveryDetails: View {
    var day: Date? = nil
    @EnvironmentObject var health: HealthStore
    @EnvironmentObject var experience: PocketExperience
    @AppStorage("sleepTarget") private var target = 8.0
    private var result: RecoveryEstimate? { let rows = experience.estimates(health, target: target); return day.flatMap { date in rows.first { Calendar.current.isDate($0.date, inSameDayAs: date) } } ?? (day == nil ? rows.filter { $0.score != nil }.last : nil) }
    private var reference: Int? {
        let nights = experience.nights(health)
        let latest = day.flatMap { date in nights.first { Calendar.current.isDate($0.date,inSameDayAs:date) } } ?? nights.filter { $0.hrv != nil && $0.sleepHours != nil }.max { $0.date < $1.date }
        guard let latest, let hrv = latest.hrv else { return nil }
        let prior = nights.filter { $0.date < latest.date && $0.hrvCount > 0 && $0.hrv.map { $0.isFinite && $0 > 0 } == true }
        let resting:[VitalRecord] = experience.demo ? (0..<42).map { offset in VitalRecord(name:"静息心率",date:Calendar.current.date(byAdding:.day,value:-offset,to:Calendar.current.startOfDay(for:Date()))!,value:55+sin(Double(offset))*0.6,unit:"次/分",source:"合成演示") } : (health.snapshot?.vitals ?? []).filter { $0.name == "静息心率" }
        guard let rhr = resting.first(where:{ Calendar.current.isDate($0.date,inSameDayAs:latest.date) }) else { return nil }
        let pastRHR = resting.filter { $0.date < rhr.date && $0.source == rhr.source && $0.date >= rhr.date.addingTimeInterval(-28*86400) }
        guard prior.count >= 14, pastRHR.count >= 14 else { return nil }
        return OpenRecoveryReference.score(hrv:hrv,baselineHRV:RecoveryEngine.median(prior.compactMap(\.hrv)),restingHR:rhr.value,baselineRestingHR:RecoveryEngine.median(pastRHR.map(\.value)),sleepMinutes:latest.sleepHours.map { $0*60 },needMinutes:target*60)
    }
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 20) { DemoNote(); if let date = result?.date { Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }; Text(result?.score.map(String.init) ?? "—").font(.system(size: 72, weight: .light)).foregroundStyle(PocketStyle.green); Text(result?.state ?? "建立基线中").font(.title3); Text("\(result?.baselineNights ?? 0) 个有效历史夜晚 · \(result?.reliability ?? "等待数据")").font(.caption).foregroundStyle(.secondary); FlatRule(); Text("影响这次估计的因素").font(.headline); ForEach(result?.reasons ?? []) { reason in VStack(alignment: .leading, spacing: 6) { Text(reason.name).font(.subheadline.weight(.medium)); Text(reason.detail).font(.caption).foregroundStyle(.secondary) }; Divider() }; LabeledContent("开源算法对照", value: reference.map(String.init) ?? "数据不足"); Text("Whoordan 部分公式，Apache 2.0。使用睡眠 SDNN 与静息心率各自匹配的历史，未读到静息心率时不代替；分数标尺不同，只作对照。两种算法都未经个人准确性验证。") .font(.caption).foregroundStyle(.secondary) }.padding(24) }.safeAreaPadding(.bottom, 24).background(PocketStyle.paper).navigationTitle("恢复参考").toolbar(.visible, for: .navigationBar) }
}
struct PocketJournal: View {
    @State private var editing: PocketEvent?
    @State private var filter = "全部"
    @EnvironmentObject var experience: PocketExperience
    @State private var composer = false
    @AppStorage("dailyJournalEntriesV3") private var legacyJSON = "{}"
    private var filteredEvents: [PocketEvent] { experience.visibleEvents.filter { filter == "全部" || $0.kind == filter } }
    private var legacy: [String: String] { (try? JSONDecoder().decode([String: String].self, from: Data(legacyJSON.utf8))) ?? [:] }
    var body: some View {
        NavigationStack { List {
            Section { VStack(alignment: .leading, spacing: 18) { PageHeader(title: "记录"); DemoNote(); Text("记录休息、训练、咖啡或当下精力。之后回看它们与状态如何一起变化。") .font(.subheadline).foregroundStyle(.secondary); Button("记录此刻") { composer = true }.buttonStyle(.borderedProminent); Picker("记录类型", selection: $filter) { ForEach(["全部", "自评", "休息", "训练", "咖啡", "饮酒", "晚睡"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu) } }.listRowSeparator(.hidden).listRowBackground(PocketStyle.paper)
            Section("时间线") {
                if filteredEvents.isEmpty { Text(experience.recordsUnavailable ? "已有记录暂时无法显示。" : filter == "全部" ? "你的第一条记录，从此刻开始。" : "还没有这一类记录。") .foregroundStyle(.secondary) }
                ForEach(filteredEvents) { event in Button { editing = event } label: { VStack(alignment: .leading, spacing: 7) { HStack { Text(event.kind).font(.headline); Spacer(); Text("精力 \(event.energy)/5").font(.caption).foregroundStyle(PocketStyle.green) }; Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary); if !event.note.isEmpty { Text(event.note).font(.subheadline) } } }.buttonStyle(.plain).accessibilityHint("编辑记录") }
                    .onDelete { offsets in let rows = filteredEvents; experience.remove(Set(offsets.map { rows[$0].id })) }
            }.listRowBackground(PocketStyle.paper)
            if !legacy.isEmpty && !experience.demo { Section("以前的自评") { ForEach(legacy.keys.sorted().reversed(), id: \.self) { date in VStack(alignment: .leading) { Text(date); Text(legacy[date] ?? "").font(.caption).foregroundStyle(.secondary) } } }.listRowBackground(PocketStyle.paper) }
            if experience.canUndoDeletion { Section { Button("撤销最近删除") { experience.undoDeletion() }; Text("可撤销本次打开内的最近一批删除。切换演示或退出 App 后不保留撤销。") .font(.caption).foregroundStyle(.secondary) }.listRowBackground(PocketStyle.paper) }
            Section { Text(experience.demo ? "演示记录只保存在本次会话，不混入真实记录。" : "本机保存，不改写生理评分。点记录可编辑，左滑可删除。") .font(.caption).foregroundStyle(.secondary); if let error = experience.error { Text(error).foregroundStyle(.orange) } }.listRowBackground(PocketStyle.paper)
        }.listStyle(.plain).scrollContentBackground(.hidden).background(PocketStyle.paper).toolbar(.hidden, for: .navigationBar).sheet(isPresented: $composer) { EventComposer(defaultKind: "自评") }.sheet(item: $editing) { event in EventComposer(defaultKind: event.kind, editing: event) } }
    }
}
struct EventComposer: View {
    @EnvironmentObject var experience: PocketExperience
    @Environment(\.dismiss) var dismiss
    let defaultKind: String
    var editing: PocketEvent? = nil
    var initialDate: Date? = nil
    @State private var kind = "自评"
    @State private var energy = 3
    @State private var note = ""
    @State private var date = Date()
    var body: some View { NavigationStack { Form { Section { DemoNote(); Picker("记录什么", selection: $kind) { ForEach(["自评", "休息", "训练", "咖啡", "饮酒", "晚睡"], id: \.self) { Text($0) } }; DatePicker("时间", selection: $date, in: ...Date()); Stepper("此刻精力 \(energy)/5", value: $energy, in: 1...5); TextField("一句话记录（可选）", text: $note, axis: .vertical).lineLimit(3...5); if let error = experience.error { Text(error).foregroundStyle(.orange) } }; Section { Text("记录用于回看，不会自动改变电量或解释因果。") .font(.caption).foregroundStyle(.secondary) } }.navigationTitle(editing == nil ? "记录此刻" : "编辑记录").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("保存") { let event = PocketEvent(id: editing?.id ?? UUID(), date: date, kind: kind, energy: energy, note: String(note.prefix(500))); if editing == nil ? experience.add(event) : experience.update(event) { dismiss() } } } }.onAppear { kind = defaultKind; if let initialDate { date = min(Date(), Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: initialDate) ?? initialDate) }; if let editing { energy = editing.energy; note = editing.note; date = editing.date }; experience.error = nil }.tint(PocketStyle.green) }
    }
}
struct PocketProfile: View {
    @ObservedObject private var bridge = WatchBridge.shared
    @EnvironmentObject var health: HealthStore
    @EnvironmentObject var experience: PocketExperience
    @AppStorage("sleepTarget") private var target = 8.0
    @State private var settings = false
    var body: some View { NavigationStack { ScrollView { VStack(alignment: .leading, spacing: 20) { PageHeader(title: "我的"); Text("只对照自己的节奏。").foregroundStyle(.secondary); FlatRule(); Toggle("体验演示数据", isOn: Binding(get: { experience.demo }, set: { experience.toggleDemo($0, health: health) })); Text("演示会同步到手表和组件，并明确标记。关闭后恢复真实摘要。") .font(.caption).foregroundStyle(.secondary); FlatRule(); Text("健康与设备").font(.title3.weight(.semibold)); NavigationLink(health.requested ? "健康连接与读取检查" : "连接 Apple 健康") { HealthConnectionView() }.buttonStyle(.borderedProminent); Text(bridge.connection).font(.caption).foregroundStyle(.secondary); NavigationLink("添加手机与手表组件") { WidgetInstructions() }; NavigationLink("数据来源与覆盖") { DataCoverage() }; Button("睡眠目标、权限与隐私") { settings = true }; NavigationLink("了解估计与算法") { EstimateDetails() }; if let notice = health.notice { Text(notice).font(.caption).foregroundStyle(.secondary) } }.padding(24) }.safeAreaPadding(.bottom, 24).background(PocketStyle.paper).toolbar(.hidden, for: .navigationBar).sheet(isPresented: $settings) { SettingsView(sleepTarget: $target) } } }
}
struct HealthConnectionView: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var experience: PocketExperience
    @Environment(\.dismiss) private var dismiss
    private var validNights: Int { (health.snapshot?.nights ?? []).filter { RecoveryModelV2.valid($0) && $0.date < Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))! }.count }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 22) {
            Text("让 Pocket 读到你的节奏").font(.title2.weight(.semibold))
            Text("会读取过去 42 天的已有记录。睡眠和趋势可直接显示；有记录即可初步估计；个人基线会逐步改善比较。") .font(.subheadline).foregroundStyle(.secondary)
            Text("在 iPhone 上授权一次，之后打开 App、回到前台或收到系统后台通知时自动读取。无需 API Key。") .font(.subheadline).foregroundStyle(.secondary)
            if experience.demo { Text("下方检查的是真实健康读取状态，演示数据不会计入。连接时会退出演示。") .font(.caption).foregroundStyle(PocketStyle.green) }
            step("1", title: "设备与授权请求", detail: health.healthAvailable ? (health.requested ? "已完成过请求；不代表每一项读取都已允许。" : "设备支持 HealthKit，等待你选择允许读取的项目。") : "当前设备不支持 HealthKit。请在 iPhone 上使用。")
            step("2", title: "读取睡眠与心率", detail: health.snapshot.map { "最近读取：\($0.fetchedAt.formatted(date: .abbreviated, time: .shortened))" } ?? "完成请求后检查是否能读到已有记录。")
            step("3", title: "建立个人基线", detail: "电量基线可用 \(validNights) 个有效历史夜晚（不含今天与昨天）；有记录即可初步计算，不再要求先满 14 夜。已有 Apple 健康历史直接参与；缺少基线时不推算心率压力。")
            if let snapshot = health.snapshot {
                FlatRule(); Text("实际读取结果").font(.headline)
                ForEach(snapshot.coverage) { row in HStack(alignment: .top) { Text(row.name); Spacer(); Text(row.count == 0 ? "暂无可读记录" : "\(row.days)天 · \(row.count)条").foregroundStyle(row.count == 0 ? PocketStyle.drain : PocketStyle.green) }.font(.caption) }
                let activityDays = snapshot.energy.filter { $0.kcal != nil }.count
                LabeledContent("活动能量", value: "\(activityDays) 天有统计").font(.caption)
                Text(health.battery.message).font(.caption).foregroundStyle(.secondary)
                NavigationLink("查看来源、采样时间与覆盖") { DataCoverage() }
            }
            if let notice = health.notice { Text(notice).font(.subheadline).foregroundStyle(PocketStyle.drain) }
            Text("可选新增：步数、正念时段、睡眠呼吸率、睡眠腕温和血氧。用于状态背景与个人趋势。点下方按钮自行选择允许读取的项目；未允许的指标留空，原有功能仍可使用。") .font(.caption).foregroundStyle(.secondary)
            Button(health.busy ? "正在读取…" : health.requested ? "重新请求读取权限" : "选择允许读取的项目") {
                experience.toggleDemo(false, health: health)
                Task { await health.connect() }
            }.buttonStyle(.borderedProminent).disabled(health.busy || !health.healthAvailable)
            if health.requested { Button("立即刷新健康记录") { Task { await health.refresh() } }.buttonStyle(.bordered).disabled(health.busy) }
            FlatRule(); Text("没有读到数据时").font(.headline)
            Text("先确认健康 App 中已有睡眠、HRV 和心率记录；再到健康 App 的头像页面，找到 App 或数据访问管理，检查 Recovery Pocket 的读取项目。回来后点刷新。") .font(.subheadline).foregroundStyle(.secondary)
            Text("苹果不会告诉 App 读取被拒绝还是没有记录，所以这里按实际读到的结果展示，不标记虚假的“全部已授权”。") .font(.caption).foregroundStyle(.secondary)
            FlatRule(); Text("自动读取与隐私").font(.headline)
            Text(health.backgroundStatus).font(.subheadline)
            Text("后台时机由系统安排，锁屏时可能暂时无法读取。只读睡眠、HRV SDNN、心率、静息心率、活动能量、训练、步数、正念时段、呼吸率、睡眠腕温与血氧；不改写 Apple 健康。本机计算，向配对手表发送摘要，原始健康记录不上传服务器。") .font(.caption).foregroundStyle(.secondary)
        }.padding(24) }.safeAreaPadding(.bottom, 24).background(PocketStyle.paper).navigationTitle("连接 Apple 健康").toolbar(.visible, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
    private func step(_ number: String, title: String, detail: String) -> some View { HStack(alignment: .top, spacing: 14) {
        Text(number).font(.title3.weight(.light)).foregroundStyle(PocketStyle.green).frame(width: 24)
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); Text(detail).font(.subheadline).foregroundStyle(.secondary) }
    } }
}
struct DataCoverage: View {
    @EnvironmentObject var health: HealthStore
    var body: some View { List { if let snapshot = health.snapshot { Section { Text("最后读取 \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))") }; ForEach(snapshot.coverage) { row in Section(row.name) { Text("\(row.days) 天 · \(row.count) 条"); ForEach(row.sources, id: \.self) { Text($0).font(.caption) }; if let date = row.lastSample { Text("最新 \(date.formatted(date: .abbreviated, time: .shortened))") } } } } else { Text("连接健康后查看真实数据来源。") }; Section { Text("系统无法直接区分读取被拒绝与没有记录。演示不伪装成真实覆盖。") } }.navigationTitle("数据覆盖").toolbar(.visible, for: .navigationBar) }
}
struct EstimateDetails: View {
    @EnvironmentObject private var health:HealthStore
    @EnvironmentObject private var experience:PocketExperience
    private var status:PocketStatus { experience.status(health) }
    var body: some View { List {
        if experience.demo { DemoNote() }
        Section("估计的不确定性") {
            LabeledContent("内部估计范围",value:status.lower.flatMap { low in status.upper.map { "\(low)–\($0)" } } ?? "暂无估计")
            Text("范围越宽，越不适合单看一个数字安排训练。当前范围尚未按真实结果校准。").font(.caption).foregroundStyle(.secondary)
        }
        Section("本次计算实际用到的数据") {
            if let inputs = status.inputs {
                Text(inputs.date.formatted(.dateTime.month().day()) + " · 自午夜起的已观测时段")
                LabeledContent("已记录睡眠",value:String(format:"%.1f 小时",inputs.sleepHours))
                LabeledContent("有可比睡眠 HRV 的睡眠",value:String(format:"%.1f 小时",inputs.sleepHRVHours))
                LabeledContent("日间可比 HRV 实测窗口",value:String(format:"%.1f 分钟",inputs.awakeHRVMinutes))
                LabeledContent("可比睡眠 HRV 采样",value:"\(inputs.sleepHRVSamples ?? 0) 条")
                LabeledContent("睡眠 HRV 调节",value:String(format:"%+.2f 点",inputs.sleepHRVAdjustment ?? 0))
                LabeledContent("日间 HRV 额外消耗",value:String(format:"%.2f 点",inputs.awakeHRVDrain ?? 0))
                LabeledContent("已记录活动能量",value:String(format:"%.0f kcal",inputs.activeKcal))
                LabeledContent("有数据的小时区间",value:String(format:"%.1f 小时",inputs.observedHours))
                LabeledContent("缺少时间覆盖",value:String(format:"%.1f 小时",inputs.unobservedHours ?? 0))
                LabeledContent("最近睡眠观测",value:inputs.latestSleepEnd.map { $0.formatted(date:.abbreviated,time:.shortened) } ?? "尚未读到")
                Text("HRV 覆盖为 0 表示该项没有影响本次时段计算，不表示 HRV 为零。睡眠跨午夜部分归前一天；有数据的小时仍可能只有稀疏采样。").font(.caption).foregroundStyle(.secondary)
            } else { Text("刷新健康数据后显示计算输入。") }
        }
        Section("睡眠恢复曲线") { Text("采用逐渐接近 100 的恢复曲线，电量较低时补充较快，接近充足时变慢。睡眠 HRV 相对个人历史偏低、睡眠心率偏高时会降低速度。6 小时的恢复时间参数仍是待校准的工程假设，不保证睡够就到 100，也不是 Garmin 的公式。") }
 Section("身体电量") { Text("基于已有睡眠、活动、心率和睡眠时段 HRV 估算，有记录即可初步计算。睡眠 HRV 与更早的个人睡眠记录比较；心率偏高时降低睡眠补充。训练时不重复加算心率偏高消耗，也不视为清醒休息。小时活动能量不能证明整小时清醒；按时间消耗只作用于观测覆盖窗口。首次以固定 50 起步；起点和系数仍需个人校准。") }; Section("观测与范围") { Text("两小时没有新观测或跨日后隐藏当前值。曲线只显示已有观测，不插补采样空洞。范围是模型内部估算范围，不是经验证的置信区间。") }; Section("恢复与开源对照") { Text("恢复使用个人历史和状态滤波；Whoordan 的部分开源公式用于独立对照，许可为 Apache 2.0。身体电量借鉴 Garmin 公开的持续充放电思路；公式和系数是本 App 的实验实现，未经生理准确性验证。Apple 健康里的 SDNN 采样不能直接当成佳明的连续压力信号。") }; Section("使用方式") { Text("今日安排是你选择的计划，以实际感受为准。事件记录不改变生理分数，也不会直接产生习惯因果结论。") } }.scrollContentBackground(.hidden).background(PocketStyle.paper).navigationTitle("估计说明").toolbar(.visible, for: .navigationBar) }
}
struct WidgetInstructions: View {
    var body: some View { List { Section("iPhone 桌面") { Text("长按桌面空白 → 编辑 → 添加小组件 → 搜索 Recovery Pocket。支持小号、中号桌面组件及锁屏组件。点组件打开今日页。") }; Section("Apple Watch 表盘") { Text("安装 Watch App 后，长按表盘 → 编辑 → 复杂功能 → 选择 Recovery Pocket。形状取决于表盘槽位。") }; Section("更新与隐私") { Text("手机读取后保存摘要并同步手表。系统决定后台与组件刷新时机，不能保证实时。原始健康记录不上传云端；组件和手表显示计算摘要。") } }.navigationTitle("添加组件").toolbar(.visible, for: .navigationBar) }
}

struct WorkoutImpactView: View {
    @EnvironmentObject var health: HealthStore
    @EnvironmentObject var experience: PocketExperience
    var day: Date = Date()
    private var points: [BatteryPoint] { experience.demo ? experience.demoBattery.points : health.batteryHistory }
    private var windows: [DrainWindow] { WorkoutAnalysis.windows(points: points, day: day, now: Date()) }
    private var workouts: [PocketWorkout] {
        let start = Calendar.current.startOfDay(for: day), end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return (experience.demo ? WorkoutAnalysis.demoWorkouts(day: day) : health.snapshot?.workouts ?? []).filter { $0.start < end && $0.end > start && $0.end <= Date() }
    }
    private var impacts: [WorkoutImpact] { WorkoutAnalysis.impacts(workouts: workouts, windows: windows) }
    private var peak: DrainWindow? { windows.max { $0.drop < $1.drop }.flatMap { $0.drop > 0 ? $0 : nil } }
    private func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            DemoNote(); Text(day.formatted(date: .abbreviated, time: .omitted)).font(.subheadline).foregroundStyle(.secondary)
            Text("消耗发生在哪里").font(.title2.weight(.semibold))
            if let peak { Text("最多：\(time(peak.start))–\(time(peak.end))").font(.headline); Text(String(format: "估计净下降 %.1f 点", peak.drop)).foregroundStyle(PocketStyle.drain) }
            else { Text("尚无可比较的下降时段").foregroundStyle(.secondary) }
            if !windows.isEmpty {
                Chart(windows) { window in
                    RectangleMark(xStart: .value("开始", window.start), xEnd: .value("结束", window.end), yStart: .value("起点", 0), yEnd: .value("净下降", window.drop)).foregroundStyle(PocketStyle.drain.opacity(0.8))
                }.chartXScale(domain: Calendar.current.startOfDay(for: day)...Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: day))!).chartXAxis { AxisMarks(values: .stride(by: .hour, count: 4)) { axis in AxisGridLine(); AxisValueLabel(anchor:.center) { if let date = axis.as(Date.self) { Text(date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).locale(Locale(identifier: "en_GB")))) } } } }.chartYAxisLabel("电量点").frame(height: 170)
            }
            Text("柱高是相邻有效观测的净下降；没有柱可能是无净下降，也可能缺少观测。接近电量下限时下降会被截断，不能当作真实疲劳量。") .font(.caption).foregroundStyle(.secondary)
            FlatRule(); Text("训练对应的变化").font(.title3.weight(.semibold))
            if impacts.isEmpty { Text("这一天没有读到已结束的训练。允许读取体能训练并同步 Apple Watch 后刷新；没有记录不代表没有运动。") .font(.subheadline).foregroundStyle(.secondary) }
            ForEach(impacts) { impact in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(impact.workout.title).font(.headline); Spacer(); Text(impact.coveredSeconds > 0 ? String(format: "≈ −%.1f 点", impact.drop) : "暂不可估计").foregroundStyle(PocketStyle.drain) }
                    Text("\(time(impact.workout.start))–\(time(impact.workout.end)) · \(Int(impact.workout.duration / 60)) 分钟").font(.subheadline)
                    Text(impact.workout.activeKcal.map { String(format: "活动能量 %.0f kcal", $0) } ?? "活动能量未读到").font(.caption)
                    Text("可比较时段 \(Int(impact.coveredSeconds / 60)) 分钟 · \(impact.workout.source)").font(.caption).foregroundStyle(.secondary)
                }; FlatRule()
            }
            Text("这是训练时间与现有电量曲线的对应估计，不证明训练造成全部下降。小时内按时间比例分配；重叠训练平分对应下降，暂停也包含在时间窗口内。训练能量仅展示，不再额外扣分，避免与全天活动能量重复计算。") .font(.caption).foregroundStyle(.secondary)
            if !experience.demo { Button("刷新健康数据") { Task { await health.refresh() } }.buttonStyle(.bordered).disabled(health.busy || !health.requested) }
        }.padding(24) }.safeAreaPadding(.bottom, 24).background(PocketStyle.paper).navigationTitle("训练与消耗").toolbar(.visible, for: .navigationBar)
    }
}

// A health overview follows the same paper / evergreen / flat-divider language as Today.
struct PocketBody: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var experience: PocketExperience
    @AppStorage("sleepTarget") private var sleepTarget = 8.0
    @AppStorage("dailyStepGoal") private var stepGoal = 6000
    @State private var goalSettings = false
    @State private var checkIn = false
    @State private var metricSettings = false
    @State private var hrvContext = "睡眠"
    @AppStorage("bodyVisibleMetrics") private var visibleMetrics = "静息心率,睡眠心率,睡眠呼吸率,睡眠腕温,睡眠血氧,睡眠时长,步数"
    private var observations: [HRVObservation] { experience.demo ? DayHRVModel.demo() : health.snapshot?.hrvObservations ?? [] }
    private var latestHRV: HRVObservation? { observations.filter { $0.context == "安静候选" && Calendar.current.isDateInToday($0.end) }.max { $0.end < $1.end } }
    private var latestNight: NightRecord? { experience.nights(health).filter { $0.sleepHours != nil }.max { $0.date < $1.date } }
    private var recovery: RecoveryEstimate? { experience.estimates(health, target: sleepTarget).filter { $0.score != nil }.max { $0.date < $1.date } }
    private var steps: Double? { experience.demo ? 6420 : health.snapshot?.steps?.first { Calendar.current.isDateInToday($0.date) }?.count }
    var body: some View {
        NavigationStack { ScrollView { VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "身体"); DemoNote()
            hrvOverview
            healthGrid
            HStack { Text("身体指标").font(.title2.weight(.semibold)); Spacer(); Button("编辑") { metricSettings = true }.frame(minHeight:44) }
            BodyMetricCards(visible:visibleMetrics)
            FlatRule()
            NavigationLink { DayHRVView() } label: { overviewRow("日间 HRV", subtitle: latestHRV?.label ?? "查看采样与时段背景", icon: "waveform.path.ecg") }
            NavigationLink { PocketVitalsView() } label: { overviewRow("夜间与静息指标", subtitle: "呼吸、腕温、血氧与静息心率", icon: "heart.text.clipboard") }
            NavigationLink { WeeklyHealthView() } label: { overviewRow("这一周", subtitle: "睡眠规律、步数与训练统计", icon: "calendar") }
            NavigationLink { WorkoutImpactView(day: Date()) } label: { overviewRow("训练与电量", subtitle: "查看训练记录和消耗时段", icon: "figure.run") }
            FlatRule(); habits
            FlatRule(); Text("让估计逐渐认识你").font(.headline)
            Text("每天记录一次真实精力，之后与睡眠、HRV 和训练对照。自评暂不自动修改电量，避免把猜测当成校准结果。").font(.caption).foregroundStyle(.secondary)
            Button("记录此刻精力") { checkIn = true }.buttonStyle(.borderedProminent)
            if !health.requested && !experience.demo { NavigationLink("连接 Apple 健康") { HealthConnectionView() }.buttonStyle(.bordered) }
        }.padding(24) }.safeAreaPadding(.bottom,24).background(PocketStyle.paper).toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented:$goalSettings) { NavigationStack { Form { Stepper("每日步数目标 \(stepGoal) 步", value:$stepGoal, in:1000...30000, step:500); Text("目标用于习惯进度，不影响电量分数。睡眠目标在“我的”中调整。").font(.caption) }.navigationTitle("日常目标").toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { goalSettings = false } } } }.tint(PocketStyle.green) }
        .sheet(isPresented:$metricSettings) { BodyMetricSettings(visible:$visibleMetrics) }
        .sheet(isPresented:$checkIn) { EventComposer(defaultKind:"自评") }
        }
    }
    private var nightHRVDeviation: Double? {
        guard let latestNight else { return nil }
        let prior = experience.nights(health).filter { $0.date < latestNight.date && $0.date >= latestNight.date.addingTimeInterval(-28*86400) && $0.hrvCount > 0 }.compactMap(\.hrv)
        return SleepHRVComparison.deviation(current:latestNight.hrv,prior:prior)
    }
    private var hrvOverview: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { Label("HRV · SDNN",systemImage:"waveform.path.ecg").font(.subheadline.weight(.medium)); Spacer(); Picker("HRV 背景",selection:$hrvContext) { Text("睡眠").tag("睡眠"); Text("日间").tag("日间") }.pickerStyle(.segmented).frame(maxWidth:160) }
            if hrvContext == "睡眠" {
                HStack(alignment:.firstTextBaseline,spacing:8) { Text(latestNight?.hrv.map { String(format:"%.0f",$0) } ?? "—").font(.system(size:64,weight:.light)); Text("ms").font(.title3) }.foregroundStyle(PocketStyle.green)
                Text(latestNight?.hrv == nil ? "尚无睡眠采样" : nightHRVDeviation.map { $0 < -1 ? "低于个人历史" : $0 > 1 ? "高于个人历史" : "接近个人历史" } ?? "正在积累个人比较").font(.title3.weight(.medium))
                HStack { Text(latestNight.map { $0.date.formatted(.dateTime.month().day()) + " · \($0.hrvCount) 条睡眠采样" } ?? "佩戴手表睡眠后查看").font(.caption).foregroundStyle(.secondary); Spacer(); NavigationLink { SleepDetails() } label: { Image(systemName:"arrow.up.right").frame(width:44,height:44) }.accessibilityLabel("查看睡眠 HRV 记录") }
            } else {
                HStack(alignment:.firstTextBaseline,spacing:8) { Text(latestHRV.map { String(format:"%.0f",$0.sdnn) } ?? "—").font(.system(size:64,weight:.light)); Text("ms").font(.title3) }.foregroundStyle(PocketStyle.green)
                Text(latestHRV?.label ?? "等待安静候选采样").font(.title3.weight(.medium))
                HStack { Text(latestHRV.map { $0.end.formatted(date:.abbreviated,time:.shortened) + " · \($0.baselineDays) 个历史日" } ?? "查看已有采样与背景").font(.caption).foregroundStyle(.secondary); Spacer(); NavigationLink { DayHRVView() } label: { Image(systemName:"arrow.up.right").frame(width:44,height:44) }.accessibilityLabel("查看日间 HRV 记录") }
            }
        }.padding(22).frame(maxWidth:.infinity,alignment:.leading).background(PocketStyle.green.opacity(0.055),in:RoundedRectangle(cornerRadius:24))
    }
    private var healthGrid: some View {
        HStack(alignment:.top,spacing:20) {
            NavigationLink { RecoveryDetails(day:recovery?.date) } label: { healthTile("恢复参考",value:recovery?.score.map(String.init) ?? "—",detail:recovery.map { $0.date.formatted(.dateTime.month().day()) + " · " + $0.reliability } ?? "暂无记录") }
            NavigationLink { SleepDetails() } label: { healthTile("最近睡眠",value:sleepLabel(latestNight?.sleepHours),detail:latestNight?.date.formatted(.dateTime.month().day()) ?? "暂无记录") }
        }.buttonStyle(.plain).padding(.vertical,4)
    }
    private var habits: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack { Text("日常目标").font(.title3.weight(.semibold)); Spacer(); Button("调整") { goalSettings = true }.font(.caption).frame(minHeight:44) }
            LabeledContent("走动",value:steps.map { String(format:"%.0f / %d 步",$0,stepGoal) } ?? "等待步数记录")
            if let steps { ProgressView(value:min(steps,Double(stepGoal)),total:Double(stepGoal)).tint(PocketStyle.green) }
            LabeledContent("睡眠",value:latestNight?.sleepHours.map { String(format:"%.1f / %.1f 小时",$0,sleepTarget) } ?? "等待睡眠记录")
            if let hours = latestNight?.sleepHours { ProgressView(value:min(hours,sleepTarget),total:sleepTarget).tint(PocketStyle.green) }
            Text("睡眠进度来自最近有记录的一夜，日期见上方。目标是日常提醒，适当休息也算照顾自己。").font(.caption).foregroundStyle(.secondary)
        }.font(.subheadline)
    }
    private func healthTile(_ title:String,value:String,detail:String) -> some View {
        VStack(alignment:.leading,spacing:9) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(size:28,weight:.light)).foregroundStyle(PocketStyle.green).minimumScaleFactor(0.7); Text(detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }.frame(maxWidth:.infinity,alignment:.leading).accessibilityElement(children:.combine)
    }
    private func overviewRow(_ title:String,subtitle:String,icon:String) -> some View {
        HStack(spacing:14) { Image(systemName:icon).font(.title3).frame(width:27); VStack(alignment:.leading,spacing:5) { Text(title).font(.subheadline.weight(.medium)); Text(subtitle).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName:"chevron.right").font(.caption) }.foregroundStyle(PocketStyle.ink).frame(minHeight:54).padding(.vertical,5)
    }
}

struct DayHRVView: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var experience: PocketExperience
    @State private var day = Calendar.current.startOfDay(for:Date())
    @State private var selectedDate: Date?
    private var rows:[HRVObservation] { (experience.demo ? DayHRVModel.demo() : health.snapshot?.hrvObservations ?? []).filter { Calendar.current.isDate($0.start,inSameDayAs:day) }.sorted { $0.start < $1.start } }
    private var selected:HRVObservation? { guard let selectedDate, let row = rows.min(by: { abs($0.start.timeIntervalSince(selectedDate)) < abs($1.start.timeIntervalSince(selectedDate)) }), abs(row.start.timeIntervalSince(selectedDate)) <= 1800 else { return nil }; return row }
    private var quiet:[HRVObservation] { rows.filter { $0.context == "安静候选" } }
    private var latest:HRVObservation? { quiet.last }
    var body: some View { ScrollView { VStack(alignment:.leading,spacing:20) {
        DemoNote(); DatePicker("回看日期",selection:$day,in:...Date(),displayedComponents:.date).onChange(of:day) { _,_ in selectedDate = nil }
        Text(latest.map { String(format:"%.0f ms",$0.sdnn) } ?? "—").font(.system(size:56,weight:.light)).foregroundStyle(PocketStyle.green)
        Text(latest?.label ?? "尚无可比较的日间采样").font(.title3)
        if let latest { Text("最后安静候选采样：\(latest.end.formatted(date:.abbreviated,time:.shortened)) · \(latest.baselineDays) 个可比历史日").font(.caption).foregroundStyle(.secondary) }
        Text("这是采样时的 HRV 参考，不代表现在的状态，也不是直接测得的心理压力。").font(.caption).foregroundStyle(.secondary)
        if !rows.isEmpty {
            Chart(rows) { row in PointMark(x:.value("时间",row.start),y:.value("SDNN",row.sdnn)).symbolSize(40).foregroundStyle(row.context == "安静候选" ? PocketStyle.green : Color.gray) }
                .chartXSelection(value:$selectedDate).chartGesture { proxy in SpatialTapGesture().onEnded { proxy.selectXValue(at:$0.location.x) } }.frame(height:180)
            Text("绿点：安静候选 · 灰点：其他背景。轻点采样点查看记录。").font(.caption).foregroundStyle(.secondary)
            if let selected { Text("\(selected.start.formatted(date:.omitted,time:.shortened)) · \(String(format:"%.0f ms",selected.sdnn)) · \(selected.context)").font(.subheadline); Text(selected.label).font(.caption).foregroundStyle(.secondary) }
        } else { Text("Apple 健康中没有这一天的可读 HRV 记录。佩戴手表后等待记录同步，或检查读取权限。").font(.subheadline).foregroundStyle(.secondary) }
        FlatRule(); LabeledContent("全部采样",value:"\(rows.count) 次"); LabeledContent("安静候选 / 可比较",value:"\(quiet.count) / \(quiet.filter { $0.deviation != nil }.count) 次")
        Text("只与同一来源、相近六小时时段、过去 28 天的安静候选记录比较。只比较相近记录时长；至少 3 个不同历史日才给出相对描述。已知睡眠、呼吸练习、训练及训练后 90 分钟分别标注，活动背景不足时不用于日间比较。").font(.caption).foregroundStyle(.secondary)
        FlatRule(); Text("逐次记录").font(.headline)
        ForEach(rows.reversed()) { row in VStack(alignment:.leading,spacing:5) { HStack { Text(row.start.formatted(date:.omitted,time:.shortened)); Spacer(); Text(String(format:"%.0f ms",row.sdnn)) }; Text(row.context + " · " + row.label).font(.caption).foregroundStyle(.secondary) }; Divider() }
        Text("旧款 Apple Watch 的后台采样由系统安排，反复刷新不会让手表连续测量。需要一次主动观测时，可以在手表正念 App 进行呼吸练习；呼吸练习记录独立显示，不混入日常基线。").font(.caption).foregroundStyle(.secondary)
    }.padding(24) }.safeAreaPadding(.bottom,24).background(PocketStyle.paper).navigationTitle("日间 HRV").toolbar(.visible,for:.navigationBar) }
}

struct PocketVitalsView: View {
    @EnvironmentObject private var health:HealthStore
    @EnvironmentObject private var experience:PocketExperience
    private var records:[VitalRecord] {
        if !experience.demo { return health.snapshot?.vitals ?? [] }
        let start = Calendar.current.startOfDay(for:Date())
        return (0..<14).flatMap { offset in
            [("静息心率",55.0,"次/分"),("睡眠呼吸率",14.2,"次/分"),("睡眠腕温",35.8,"°C"),("睡眠血氧",0.975,"%")].map { name,value,unit in VitalRecord(name:name,date:Calendar.current.date(byAdding:.day,value:-offset,to:start)!,value:value + (unit == "%" ? 0.001 : 0.1) * sin(Double(offset)),unit:unit,source:"合成演示") }
        }
    }
    var body:some View { ScrollView { VStack(alignment:.leading,spacing:22) {
        DemoNote(); Text("看自己的变化").font(.title2.weight(.semibold)); Text("使用相同来源的记录与个人历史比较，不把单次偏离解释为疾病。").font(.subheadline).foregroundStyle(.secondary)
        ForEach(["静息心率","睡眠呼吸率","睡眠腕温","睡眠血氧"],id:\.self) { name in vitalSection(name) }
        NavigationLink("选择读取这些指标") { HealthConnectionView() }.buttonStyle(.borderedProminent)
        Text("腕温是睡眠期间的手腕温度，不能当作体温计读数。睡眠呼吸率与血氧只取已有睡眠区间内的记录；没有记录就留空。这些指标目前用于观察，不直接扣身体电量。").font(.caption).foregroundStyle(.secondary)
    }.padding(24) }.safeAreaPadding(.bottom,24).background(PocketStyle.paper).navigationTitle("夜间与静息指标").toolbar(.visible,for:.navigationBar) }
    @ViewBuilder private func vitalSection(_ name:String) -> some View {
        let items = records.filter { $0.name == name }.sorted { $0.date < $1.date }
        VStack(alignment:.leading,spacing:10) {
            HStack { Text(name).font(.headline); Spacer(); Text(items.last?.date.formatted(.dateTime.month().day()) ?? "暂无记录").font(.caption).foregroundStyle(.secondary) }
            if let latest = items.last {
                let prior = items.filter { $0.date < latest.date && $0.source == latest.source && $0.date >= latest.date.addingTimeInterval(-28*86400) }
                Text(formatted(latest.value,unit:latest.unit)).font(.system(size:36,weight:.light)).foregroundStyle(PocketStyle.green)
                if prior.count >= 3, let baseline = RecoveryEngine.median(prior.map(\.value)) { Text("较个人历史中位数 " + difference((latest.value-baseline) * (latest.unit == "%" ? 100 : 1)) + " " + (latest.unit == "%" ? "个百分点" : latest.unit) + " · \(prior.count) 天参考").font(.caption).foregroundStyle(.secondary) }
                else { Text("已有记录可直接查看；个人比较仍在积累。").font(.caption).foregroundStyle(.secondary) }
                Chart(items.suffix(14)) { row in PointMark(x:.value("日期",row.date),y:.value(name,row.value * (row.unit == "%" ? 100 : 1))).symbolSize(25).foregroundStyle(PocketStyle.green) }.chartYScale(domain: .automatic(includesZero:false)).frame(height:95)
            } else { Text("尚无可读记录").foregroundStyle(.secondary); Text("是否有记录取决于设备、佩戴设置、同步与读取权限。").font(.caption).foregroundStyle(.secondary) }
        }; FlatRule()
    }
    private func difference(_ value:Double) -> String { abs(value) < 0.05 ? "0.0" : String(format:"%+.1f",value) }
    private func formatted(_ value:Double,unit:String) -> String { String(format:unit == "次/分" ? "%.0f %@" : "%.1f %@", value * (unit == "%" ? 100 : 1),unit) }
}

struct WeeklyHealthView: View {
    @EnvironmentObject private var health:HealthStore
    @EnvironmentObject private var experience:PocketExperience
    @AppStorage("sleepTarget") private var target = 8.0
    private var start:Date { Calendar.current.date(byAdding:.day,value:-6,to:Calendar.current.startOfDay(for:Date()))! }
    private var nights:[NightRecord] { experience.nights(health).filter { $0.date >= start && $0.date <= Date() }.sorted { $0.date < $1.date } }
    private var stepDays:[StepDay] {
        if experience.demo { return (0..<7).map { offset in StepDay(date:Calendar.current.date(byAdding:.day,value:offset,to:start)!,count:offset == 6 ? 6420 : 5500 + Double(offset)*330) } }
        return (health.snapshot?.steps ?? []).filter { $0.date >= start && $0.date <= Date() }
    }
    private var workouts:[PocketWorkout] { (experience.demo ? (0..<7).flatMap { WorkoutAnalysis.demoWorkouts(day:Calendar.current.date(byAdding:.day,value:$0,to:start)!) } : health.snapshot?.workouts ?? []).filter { $0.end > start && $0.end <= Date() } }
    var body:some View { ScrollView { VStack(alignment:.leading,spacing:22) {
        DemoNote(); Text("最近 7 天，包含今天").font(.subheadline).foregroundStyle(.secondary)
        sleepSection; FlatRule(); movementSection; FlatRule(); trainingSection; FlatRule(); checkInSection
        FlatRule(); Text("今天还在进行，步数和训练会继续变化。所有平均值只用有记录的日期；缺失日不当成零。这里只描述记录，不判断某个习惯导致了什么。").font(.caption).foregroundStyle(.secondary)
    }.padding(24) }.safeAreaPadding(.bottom,24).background(PocketStyle.paper).navigationTitle("这一周").toolbar(.visible,for:.navigationBar) }
    private var sleepSection:some View {
        let values = nights.compactMap(\.sleepHours)
        return VStack(alignment:.leading,spacing:12) {
            Text("睡眠").font(.title3.weight(.semibold)); Text(values.isEmpty ? "—" : String(format:"%.1f 小时",values.reduce(0,+)/Double(values.count))).font(.system(size:40,weight:.light)).foregroundStyle(PocketStyle.green)
            Text("平均睡眠 · \(values.count) / 7 夜有记录").font(.caption).foregroundStyle(.secondary)
            if !values.isEmpty { LabeledContent("达到个人睡眠目标",value:"\(values.filter { $0 >= target }.count) / \(values.count) 夜"); LabeledContent("时长波动",value:String(format:"%.1f 小时",(values.max() ?? 0)-(values.min() ?? 0))) }
            Chart(nights) { night in if let value = night.sleepHours { BarMark(x:.value("日期",night.date,unit:.day),y:.value("睡眠小时",value)).foregroundStyle(PocketStyle.green) } }.frame(height:130)
        }
    }
    private var movementSection:some View {
        let values = stepDays.compactMap(\.count)
        return VStack(alignment:.leading,spacing:12) { Text("走动").font(.title3.weight(.semibold)); Text(values.isEmpty ? "—" : String(format:"%.0f 步",values.reduce(0,+)/Double(values.count))).font(.system(size:40,weight:.light)).foregroundStyle(PocketStyle.green); Text("有记录日的平均步数 · \(values.count) / 7 天").font(.caption).foregroundStyle(.secondary); Chart(stepDays,id:\.date) { row in if let value = row.count { BarMark(x:.value("日期",row.date,unit:.day),y:.value("步数",value)).foregroundStyle(PocketStyle.mint) } }.frame(height:130) }
    }
    private var checkInSection:some View {
        let rows = experience.visibleEvents.filter { $0.kind == "自评" && $0.date >= start && $0.date <= Date() }
        let dates = Dictionary(grouping:rows,by:{ Calendar.current.startOfDay(for:$0.date) })
        let daily = dates.mapValues { entries in Double(entries.map(\.energy).reduce(0,+)) / Double(entries.count) }
        return VStack(alignment:.leading,spacing:12) {
            Text("真实精力").font(.title3.weight(.semibold))
            Text(daily.isEmpty ? "尚未记录" : String(format:"%.1f / 5",daily.values.reduce(0,+)/Double(daily.count))).font(.system(size:36,weight:.light)).foregroundStyle(PocketStyle.green)
            Text("\(daily.count) / 7 天有自评 · 同一天先取平均").font(.caption).foregroundStyle(.secondary)
            NavigationLink("查看今天的精力记录") { BatteryHistory(day:Date()) }
            Text("用真实感受检验估计是否有用。自评与生理分数独立保留，目前不自动拟合或改写电量。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var trainingSection:some View {
        let spans = RecoveryEngine.merged(workouts.map { SleepInterval(start:$0.start,end:$0.end) },from:start,to:Date())
        let minutes = spans.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } / 60
        let days = (0..<7).filter { offset in
            let a = Calendar.current.date(byAdding:.day,value:offset,to:start)!, b = Calendar.current.date(byAdding:.day,value:1,to:a)!
            return spans.contains { $0.start < b && $0.end > a }
        }.count
        return VStack(alignment:.leading,spacing:12) { Text("训练").font(.title3.weight(.semibold)); Text(String(format:"%.0f 分钟",minutes)).font(.system(size:40,weight:.light)).foregroundStyle(PocketStyle.green); LabeledContent("有训练记录的日期",value:"\(days) 天"); LabeledContent("训练记录",value:"\(workouts.count) 条"); Text("重叠训练区间合并后统计总时长，不重复累加。多来源的训练记录条数可能包含同一次活动。").font(.caption).foregroundStyle(.secondary) }
    }
}


private struct BodyMetricPoint: Identifiable {
    let date:Date
    let value:Double
    let source:String
    var id:Date { date }
}
private enum BodyMetricCatalog {
    static let names = ["静息心率","睡眠心率","睡眠呼吸率","睡眠腕温","睡眠血氧","睡眠时长","步数"]
    static func icon(_ name:String) -> String {
        switch name { case "静息心率": return "heart.fill"; case "睡眠心率": return "heart.circle"; case "睡眠呼吸率": return "lungs.fill"; case "睡眠腕温": return "thermometer.medium"; case "睡眠血氧": return "drop.fill"; case "睡眠时长": return "moon.fill"; default:return "figure.walk" }
    }
    static func tint(_ name:String) -> Color {
        switch name { case "静息心率","睡眠心率":return Color(red:0.75,green:0.28,blue:0.33); case "睡眠血氧":return Color(red:0.52,green:0.35,blue:0.66); case "睡眠腕温","睡眠呼吸率":return Color(red:0.26,green:0.47,blue:0.67); default:return PocketStyle.green }
    }
    static func unit(_ name:String) -> String {
        switch name { case "睡眠血氧":return "%"; case "睡眠腕温":return "°C"; case "睡眠时长":return "小时"; case "步数":return "步"; default:return "次/分" }
    }
    static func number(_ value:Double,name:String) -> String { String(format:["步数","静息心率","睡眠心率"].contains(name) ? "%.0f" : "%.1f",value) }
    static func domain(_ rows:[BodyMetricPoint],name:String) -> ClosedRange<Double> {
        let center = RecoveryEngine.median(rows.map(\.value)) ?? 0
        let radius:Double = name == "步数" ? 1500 : name == "睡眠时长" ? 2 : name == "睡眠血氧" ? 2 : name == "睡眠腕温" ? 0.5 : name == "睡眠呼吸率" ? 1 : 5
        let low = max(0,min(center-radius,(rows.map(\.value).min() ?? center)-radius*0.15))
        let high = max(low+radius,max(center+radius,(rows.map(\.value).max() ?? center)+radius*0.15))
        return low...high
    }
    @MainActor static func points(_ name:String,health:HealthStore,experience:PocketExperience) -> [BodyMetricPoint] {
        let start = Calendar.current.startOfDay(for:Date())
        if experience.demo {
            let seed:[String:Double] = ["静息心率":55,"睡眠心率":52,"睡眠呼吸率":14.2,"睡眠腕温":35.8,"睡眠血氧":97.5,"睡眠时长":7.7,"步数":6420]
            return (0..<14).reversed().map { offset in BodyMetricPoint(date:Calendar.current.date(byAdding:.day,value:-offset,to:start)!,value:(seed[name] ?? 0) + sin(Double(offset)) * (name == "步数" ? 1400 : name == "睡眠腕温" ? 0.2 : 0.6),source:"合成演示") }
        }
        if name == "睡眠心率" || name == "睡眠时长" {
            return experience.nights(health).compactMap { row in
                guard let value = name == "睡眠心率" ? row.heartRate : row.sleepHours, value.isFinite, value > 0 else { return nil }
                return BodyMetricPoint(date:row.date,value:value,source:"每夜汇总")
            }.sorted { $0.date < $1.date }
        }
        if name == "步数" { return (health.snapshot?.steps ?? []).compactMap { row in row.count.map { BodyMetricPoint(date:row.date,value:$0,source:"健康汇总") } }.sorted { $0.date < $1.date } }
        return (health.snapshot?.vitals ?? []).filter { $0.name == name && $0.value.isFinite }.map { BodyMetricPoint(date:$0.date,value:$0.value * (name == "睡眠血氧" ? 100 : 1),source:$0.source) }.sorted { $0.date < $1.date }
    }
    static func change(_ rows:[BodyMetricPoint],name:String) -> String {
        guard let latest = rows.last, let previous = rows.dropLast().last(where: { $0.source == latest.source && $0.date < latest.date }) else { return "等待上一条可比记录" }
        let delta = latest.value - previous.value
        let precision = ["步数","静息心率","睡眠心率"].contains(name) ? 0.5 : 0.05
        let direction = abs(delta) < precision ? "持平" : (delta > 0 ? "↑ " : "↓ ") + number(abs(delta),name:name) + " " + (name == "睡眠血氧" ? "个百分点" : unit(name))
        return direction + " · 较 " + previous.date.formatted(.dateTime.month().day())
    }
}

private struct BodyMetricSettings:View {
    @Binding var visible:String
    @Environment(\.dismiss) private var dismiss
    var body:some View { NavigationStack { List {
        Section("选择身体页显示的指标") { ForEach(BodyMetricCatalog.names,id:\.self) { name in
            Toggle(name,isOn:Binding(get:{ visible.split(separator:",").map(String.init).contains(name) },set:{ enabled in
                var selected = Set(visible.split(separator:",").map(String.init)); if enabled { selected.insert(name) } else { selected.remove(name) }; visible = BodyMetricCatalog.names.filter { selected.contains($0) }.joined(separator:",")
            })).tint(PocketStyle.green)
        } }
        Section { Text("隐藏只改变页面显示，不删除健康记录，也不影响身体电量。").font(.caption).foregroundStyle(.secondary) }
    }.navigationTitle("身体指标").toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } } } }
}

private struct BodyMetricCards:View {
    @EnvironmentObject private var health:HealthStore
    @EnvironmentObject private var experience:PocketExperience
    let visible:String
    private var names:[String] { BodyMetricCatalog.names.filter { visible.split(separator:",").map(String.init).contains($0) } }
    var body:some View { VStack(spacing:14) {
        if names.isEmpty { Text("暂未选择指标，点“编辑”添加。").font(.subheadline).foregroundStyle(.secondary).padding(.vertical,16) }
        ForEach(names,id:\.self) { name in
            NavigationLink { BodyMetricDetail(name:name) } label: { BodyMetricCard(name:name,rows:BodyMetricCatalog.points(name,health:health,experience:experience)) }.buttonStyle(.plain)
        }
    } }
}
private struct BodyMetricCard:View {
    let name:String
    let rows:[BodyMetricPoint]
    var chevron = true
    private var recent:[BodyMetricPoint] { guard let latest = rows.last else { return [] }; return Array(rows.filter { $0.source == latest.source }.suffix(7)) }
    var body:some View { VStack(alignment:.leading,spacing:15) {
        HStack { Label(name,systemImage:BodyMetricCatalog.icon(name)).font(.subheadline.weight(.semibold)); Spacer(); Text(rows.last?.date.formatted(.dateTime.month().day()) ?? "未读到").font(.caption).foregroundStyle(.secondary); if chevron { Image(systemName:"chevron.right").font(.caption).foregroundStyle(.secondary) } }
        HStack(alignment:.center,spacing:16) {
            HStack(alignment:.firstTextBaseline,spacing:5) { Text(rows.last.map { BodyMetricCatalog.number($0.value,name:name) } ?? "—").font(.system(size:34,weight:.light)); Text(BodyMetricCatalog.unit(name)).font(.caption).foregroundStyle(.secondary) }.lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength:0)
            if !recent.isEmpty { MetricSparkline(name:name,rows:recent).frame(width:110,height:58).accessibilityLabel("最近 \(recent.count) 条同来源记录趋势") }
        }
        Text(rows.isEmpty ? "已有记录即可查看；检查佩戴、同步与读取权限。" : BodyMetricCatalog.change(rows,name:name)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
    }.foregroundStyle(PocketStyle.ink).padding(18).background(Color.white.opacity(0.65),in:RoundedRectangle(cornerRadius:20)).overlay { RoundedRectangle(cornerRadius:20).stroke(PocketStyle.rule.opacity(0.55),lineWidth:1) } }
}
private struct MetricSparkline:View {
    let name:String
    let rows:[BodyMetricPoint]
    var body:some View { Chart(rows) { row in
        LineMark(x:.value("日期",row.date),y:.value(name,row.value)).foregroundStyle(BodyMetricCatalog.tint(name))
        PointMark(x:.value("日期",row.date),y:.value(name,row.value)).symbolSize(row.id == rows.last?.id ? 35 : 15).foregroundStyle(BodyMetricCatalog.tint(name))
    }.chartYScale(domain:BodyMetricCatalog.domain(rows,name:name)).chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden) }
}
private struct BodyMetricDetail:View {
    @EnvironmentObject private var health:HealthStore
    @EnvironmentObject private var experience:PocketExperience
    let name:String
    private var rows:[BodyMetricPoint] { BodyMetricCatalog.points(name,health:health,experience:experience) }
    private var recent:[BodyMetricPoint] { guard let latest = rows.last else { return [] }; return rows.filter { $0.source == latest.source && $0.date >= latest.date.addingTimeInterval(-28*86400) } }
    var body:some View { ScrollView { VStack(alignment:.leading,spacing:22) {
        DemoNote(); BodyMetricCard(name:name,rows:rows,chevron:false)
        Text("最近 28 天的已有记录").font(.headline)
        if !recent.isEmpty { Chart(recent) { row in PointMark(x:.value("日期",row.date),y:.value(name,row.value)).foregroundStyle(BodyMetricCatalog.tint(name)).symbolSize(35) }.chartYScale(domain:BodyMetricCatalog.domain(recent,name:name)).frame(height:190) }
        if let latest = recent.last {
            let prior = recent.filter { $0.date < latest.date }
            if prior.count >= 3, let median = RecoveryEngine.median(prior.map(\.value)) { LabeledContent("个人历史中位数",value:BodyMetricCatalog.number(median,name:name) + " " + BodyMetricCatalog.unit(name)); Text("参考 \(prior.count) 条较早的同来源记录，不包含最新值。此处比较不等同医学正常范围；图表保留固定的最小纵轴跨度，避免夸大小幅波动。").font(.caption).foregroundStyle(.secondary) }
            else { Text("先展示已有数值，积累 3 条较早的同来源记录后再显示个人中位数。").font(.caption).foregroundStyle(.secondary) }
        }
        FlatRule(); Text("逐日记录").font(.headline)
        ForEach(recent.reversed()) { row in LabeledContent(row.date.formatted(.dateTime.month().day()),value:BodyMetricCatalog.number(row.value,name:name) + " " + BodyMetricCatalog.unit(name)); Divider() }
        Text("迷你曲线连接已有记录，缺失日期没有补值。睡眠相关指标按夜汇总，步数可能还在增加；腕温是手腕温度，不是体温计读数。数值高低不直接表示好坏。").font(.caption).foregroundStyle(.secondary)
        NavigationLink("健康连接与读取检查") { HealthConnectionView() }.buttonStyle(.bordered)
    }.padding(24) }.safeAreaPadding(.bottom,24).background(PocketStyle.paper).navigationTitle(name).toolbar(.visible,for:.navigationBar) }
}
