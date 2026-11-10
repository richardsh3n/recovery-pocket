import SwiftUI
import Charts
import UIKit

enum PocketStyle {
    static let paper = Color(red: PocketPalette.paper.0, green: PocketPalette.paper.1, blue: PocketPalette.paper.2)
    static let ink = Color(red: PocketPalette.ink.0, green: PocketPalette.ink.1, blue: PocketPalette.ink.2)
    static let green = Color(red: PocketPalette.green.0, green: PocketPalette.green.1, blue: PocketPalette.green.2)
    static let drain = Color(red: PocketPalette.drain.0, green: PocketPalette.drain.1, blue: PocketPalette.drain.2)
    static let mint = Color(red: PocketPalette.mint.0, green: PocketPalette.mint.1, blue: PocketPalette.mint.2)
    static let rule = Color.black.opacity(0.10)
}
@MainActor final class PocketExperience: ObservableObject {
    @Published var demo = false
    @Published var demoBattery = BatteryDemo.status()
    @Published var demoShadow: ShadowReplay?
    @Published var events: [PocketEvent] = []
    @Published var demoEvents: [PocketEvent] = []
    @Published var error: String?
    @Published private(set) var canUndoDeletion = false
    private var estimateCacheKey: String?
    private var estimateCache: [RecoveryEstimate] = []
    private var deletedEvents: [PocketEvent] = []
    private var deletedInDemo = false
    private var eventsReadFailed = false
    private var eventsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RecoveryPocket/events-v1.json")
    }
    init() { reloadEvents() }
    func reloadEvents() {
        do {
            guard let data=try ManualRecordTransaction.read(from:eventsURL) else {events=[];eventsReadFailed=false;error=nil;return}
            events=try JSONDecoder().decode([PocketEvent].self,from:data)
            eventsReadFailed=false;error=nil
        } catch {
            eventsReadFailed=true
            self.error="已有记录或中断的恢复暂时无法核验，原文件已保留。解锁后重新打开重试。"
        }
    }
    @discardableResult func restoreEvents(_ rows:[PocketEvent])->Bool { commit(rows) }
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
            try ManualRecordTransaction.write(try JSONEncoder().encode(next),to:eventsURL)
            events = next; return true
        } catch { self.error = "记录未保存，请稍后重试"; return false }
    }
    @discardableResult private func commit(_ next: [PocketEvent]) -> Bool {
        if demo { demoEvents = next; error = nil; return true }
        guard !eventsReadFailed else { error = "已有记录未能读取，暂不修改文件。"; return false }
        do {
            try ManualRecordTransaction.write(try JSONEncoder().encode(next),to:eventsURL)
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
        demoShadow = nil
        if enabled {
            demoBattery = BatteryDemo.status()
            demoBattery.dayHRV = DayHRVModel.summary(DayHRVModel.demo(), now:Date())
            let rows = estimates(health, target: UserDefaults.standard.double(forKey: "sleepTarget") > 0 ? UserDefaults.standard.double(forKey: "sleepTarget") : 8)
            if let night = nights(health).max(by: { $0.date < $1.date }) {
                let result = rows.first { Calendar.current.isDate($0.date, inSameDayAs: night.date) }
                demoBattery.recoverySummary = WearableSummary(date: night.date, recovery: result?.score, sleepHours: night.sleepHours, hrv: night.hrv, heartRate: night.heartRate, baselineNights: result?.baselineNights ?? 0, recoveryBasis:result?.scoreBasis,recoveryModelRevision:RecoveryModelV2.revision)
            }
        }
        WatchBridge.shared.presentationOverride = enabled ? demoBattery : nil
        WatchBridge.shared.publishHealth(health.battery)
    }
    func status(_ health: HealthStore) -> PocketStatus { demo ? demoBattery : health.battery }
    func shadow(_ health:HealthStore) -> ShadowReplay? { demo ? demoShadow : health.shadowReplay }
    func shadowInspection(_ health:HealthStore)->ShadowReplayInspection? {demo ? demoShadow?.inspection:health.shadowInspection}
    func nights(_ health: HealthStore) -> [NightRecord] {
        guard demo else { return health.snapshot?.nights ?? [] }
        let calendar = Calendar.current, today = calendar.startOfDay(for: Date())
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--pocket-sleep-only-demo") {
            return [NightRecord(date:today,sleepHours:8,hrv:nil,heartRate:nil,hrvCount:0,heartRateCount:0)]
        }
        #endif
        return (0..<43).map { offset in
            let wave = sin(Double(offset) * 0.63)
            return NightRecord(date: calendar.date(byAdding: .day, value: -offset, to: today)!, sleepHours: offset == 0 ? 7.7 : 7.6 + wave * 0.7, hrv: 52 + wave * 9, heartRate: 55 - wave * 3, hrvCount: 5, heartRateCount: 42,hrvSourceKey:"synthetic-watch",heartRateSourceKey:"synthetic-watch",hrvDurationBucket:2)
        }
    }
    func estimates(_ health: HealthStore, target: Double) -> [RecoveryEstimate] {
        let key = "\(demo)|\(health.snapshot?.fetchedAt.timeIntervalSinceReferenceDate ?? 0)|\(health.cacheRevision)|\(demoBattery.computedAt.timeIntervalSinceReferenceDate)|\(Calendar.current.startOfDay(for: Date()).timeIntervalSinceReferenceDate)|\(target)"
        if estimateCacheKey == key { return estimateCache }
        let days = nights(health).map { night in
            let prior = Calendar.current.date(byAdding: .day, value: -1, to: night.date)!
            return RecoveryDay(night: night, activeKcal: demo ? 420 : health.snapshot?.energy.first { Calendar.current.isDate($0.date, inSameDayAs: prior) }?.kcal, sleepMidpointHour: nil)
        }
        let result = RecoveryModelV2.calculate(days: days, sleepTarget: target)
        estimateCacheKey = key; estimateCache = result
        return result
    }
}

// MARK: - 每日决策层（把分数翻译成"今天怎么做"）
// This layer only rephrases the same experimental estimate shown elsewhere into
// an action. It adds no new physiological claim and never hides the caveat.

extension DailyDecision {
    var levelColor: Color {
        switch level {
        case .push: return PocketStyle.green
        case .steady: return PocketStyle.mint
        case .hold: return PocketStyle.drain
        case .unknown: return PocketStyle.ink.opacity(0.45)
        }
    }
}

// Load/strain numerics live in Shared/BatteryModel.swift so the watch target and
// the synthetic core tests can share exactly the same implementation.

struct PocketRoot: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var health: HealthStore
    @StateObject private var experience = PocketExperience()
    @StateObject private var integrated = IntegratedJournal()
    @ObservedObject private var watchInbox = WatchBridge.shared
    @AppStorage("sleepTarget") private var sharedTarget = 8.0
    @State private var selected = 0
    private let tabs = [(0,"今日","house"),(4,"身体","heart.text.clipboard"),(1,"洞察","chart.bar"),(2,"记录","doc.text"),(3,"我的","person")]
    var body: some View {
        TabView(selection: $selected) {
            BatteryHome().tabItem { Label("今日", systemImage: "house") }.tag(0)
            PocketBody().tabItem { Label("身体", systemImage: "heart.text.clipboard") }.tag(4)
            WellnessHub().tabItem { Label("洞察", systemImage: "chart.bar") }.tag(1)
            PocketJournal().tabItem { Label("记录", systemImage: "doc.text") }.tag(2)
            PocketProfile().tabItem { Label("我的", systemImage: "person") }.tag(3)
        }.toolbar(.hidden,for:.tabBar)
            .safeAreaInset(edge:.bottom,spacing:0) {
                HStack(spacing:0) {
                    ForEach(tabs,id:\.0) { tab in
                        Button { selected = tab.0 } label: {
                            VStack(spacing:5) { Image(systemName:tab.2).font(.system(size:20,weight:selected == tab.0 ? .semibold : .regular)); Text(tab.1).font(.caption2.weight(selected == tab.0 ? .semibold : .regular)) }.frame(maxWidth:.infinity,minHeight:48).foregroundStyle(selected == tab.0 ? PocketStyle.green : PocketStyle.ink.opacity(0.65)).background(selected == tab.0 ? PocketStyle.green.opacity(0.07) : .clear,in:RoundedRectangle(cornerRadius:14))
                        }.buttonStyle(.plain).accessibilityLabel(tab.1).accessibilityIdentifier("tab-\(tab.0)").accessibilityAddTraits(selected == tab.0 ? .isSelected : [])
                    }
                }.padding(.horizontal,18).padding(.top,10).padding(.bottom,6).background(PocketStyle.paper).overlay(alignment:.top) { Rectangle().fill(PocketStyle.rule).frame(height:0.5) }
            }.environmentObject(experience).environmentObject(integrated)
            .disabled(integrated.restoring)
            .overlay {
                if integrated.restoring {
                    ZStack {
                        Color.black.opacity(0.08).ignoresSafeArea()
                        ProgressView("正在恢复本机记录，请稍候").padding(24).background(PocketStyle.paper,in:RoundedRectangle(cornerRadius:20))
                    }
                }
            }
            .onChange(of:integrated.restoring){_,active in if !active {consumeWatchInbox()}}
            .tint(PocketStyle.green).preferredColorScheme(.light)
            .onChange(of: scenePhase) { _, phase in if phase == .active { experience.reloadEvents();integrated.reload();consumeWatchInbox() } }
            .onChange(of:watchInbox.inbox.count){_,_ in consumeWatchInbox()}
            .onChange(of: sharedTarget) { _, _ in if experience.demo { experience.toggleDemo(true, health: health) } else if health.requested { Task { await health.refresh() } } }
            .onChange(of: health.cacheRevision) { _, _ in experience.toggleDemo(false, health: health) }
            .onAppear {
                consumeWatchInbox()
                #if targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--pocket-demo") { experience.toggleDemo(true,health:health) }
                if ProcessInfo.processInfo.arguments.contains("--pocket-state-demo") {
                    experience.toggleDemo(true,health:health)
                    experience.demoBattery=BatteryDemo.recentStateStatus()
                    WatchBridge.shared.presentationOverride=experience.demoBattery
                    WatchBridge.shared.publish(experience.demoBattery)
                }
                if ProcessInfo.processInfo.arguments.contains("--pocket-continuous-demo") {
                    experience.toggleDemo(true,health:health)
                    experience.demoBattery=BatteryDemo.continuousStatus()
                    WatchBridge.shared.presentationOverride=experience.demoBattery
                    WatchBridge.shared.publish(experience.demoBattery)
                }
                if ProcessInfo.processInfo.arguments.contains("--pocket-workout-fallback-demo") {
                    experience.toggleDemo(true,health:health)
                    experience.demoBattery=BatteryDemo.workoutFallbackStatus()
                    WatchBridge.shared.presentationOverride=experience.demoBattery
                    WatchBridge.shared.publish(experience.demoBattery)
                }
                if ProcessInfo.processInfo.arguments.contains("--pocket-shadow-demo") || ProcessInfo.processInfo.arguments.contains("--pocket-shadow-coverage-demo"),
                   let replay = ProcessInfo.processInfo.arguments.contains("--pocket-shadow-coverage-demo") ? ShadowCoverageFixture.make():ShadowReplayEngine.demo() {
                    experience.toggleDemo(true,health:health)
                    experience.demoShadow=replay
                    if ProcessInfo.processInfo.arguments.contains("--pocket-shadow-validation-demo") {experience.demoEvents=PairedModelValidationEngine.demoEvents()}
                    experience.demoBattery=replay.baseline
                    WatchBridge.shared.presentationOverride=replay.baseline
                    WatchBridge.shared.publish(replay.baseline)
                }
                if ProcessInfo.processInfo.arguments.contains("--pocket-stale-demo") {
                    experience.toggleDemo(true,health:health)
                    experience.demoBattery = BatteryDemo.status(now:Date().addingTimeInterval(-3*3600))
                }
                #endif
            }
            .onOpenURL { url in if url.scheme == "recoverypocket" { selected = 0 } }
    }
    private func consumeWatchInbox(){
        guard !experience.demo,!integrated.restoring else{return}
        for row in watchInbox.inbox where row.valid(now:Date()) {
            if experience.events.contains(where:{$0.id == row.id}) || experience.add(PocketEvent(id:row.id,date:row.date,kind:"自评",energy:row.energy,note:"来自 Apple Watch；未事后补配预测")){watchInbox.acknowledge(row.id)}
        }
    }
}
private struct FlatRule: View { var body: some View { Rectangle().fill(PocketStyle.rule).frame(height: 0.5).padding(.vertical, 14) } }
struct PageHeader: View {
    let title: String
    var body: some View { VStack(alignment: .leading, spacing: 8) { Text("RECOVERY  /  POCKET").font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(.secondary); Text(title).font(.system(size: 32, weight: .semibold)) }.foregroundStyle(PocketStyle.ink) }
}
struct DemoNote: View { @EnvironmentObject var experience: PocketExperience; @EnvironmentObject var health:HealthStore; var body: some View { if experience.demo || health.battery.demo { Text("演示数据 · 非你的健康记录").font(.caption).foregroundStyle(PocketStyle.green) } } }

struct BatteryHome: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var experience: PocketExperience
    @AppStorage("sleepTarget") private var target = 8.0
    @AppStorage("dailyIntentV4") private var intent = "工作"
    @State private var day = Calendar.current.startOfDay(for: Date())
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var calendarSelection
    @State private var calendarAnchor = Calendar.current.startOfDay(for: Date())
    @State private var calendarOpen = false
    @State private var composer = false
    @State private var resting = false
    @State private var connection = false
    @State private var timelineSelection: Date?
    @State private var composerKind = "休息"
    @AppStorage("aiCloudEnabled") private var aiCloudEnabled = false
    @AppStorage("aiMorningCloudEnabled") private var aiMorningCloudEnabled = false
    @AppStorage("aiCloudEndpoint") private var aiCloudEndpoint = ""
    @AppStorage("aiCloudModel") private var aiCloudModel = ""
    @State private var aiHasKey = false
    @State private var aiStatus = false
    @StateObject private var briefAI = PocketBriefAI()
    private var status: PocketStatus { experience.status(health) }
    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var isFuture: Bool { day > Calendar.current.startOfDay(for: Date()) }
    private var allPoints: [BatteryPoint] { experience.demo ? experience.demoBattery.points : status.usesStateEstimate ? health.stateHistory : health.batteryHistory }
    private var dayPoints: [BatteryPoint] {
        let start = Calendar.current.startOfDay(for: day), end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return allPoints.filter { point in
            let withinDay = point.belongs(to:start,end:end,instant:status.usesStateEstimate)
            return withinDay && point.date <= Date() && point.value.map { $0.isFinite && (0...100).contains($0) } == true
        }
    }
    private var stats: DailyBatteryStatistics {
        if status.usesStateEstimate {
            let values = dayPoints.compactMap(\.value)
            return DailyBatteryStatistics(latest: dayPoints.max { $0.date < $1.date }, minimum: values.min(), maximum: values.max(), charged: 0, drained: 0, coveredSeconds: 0)
        }
        return DailyBatteryStatistics.calculate(points: allPoints, day: day, now: Date())
    }
    private var lastNight: NightRecord? { experience.nights(health).filter { $0.sleepHours != nil && Calendar.current.isDate($0.date, inSameDayAs: day) }.max { $0.date < $1.date } }
    private var workouts: [PocketWorkout] { let end = Calendar.current.date(byAdding: .day, value: 1, to: day)!; return (experience.demo ? WorkoutAnalysis.demoWorkouts(day: day) : health.snapshot?.workouts ?? []).filter { $0.start < end && $0.end > day && $0.end <= Date() } }
    private var kcal: Double? { experience.demo ? (isFuture ? nil : 420) : health.snapshot?.energy.first { Calendar.current.isDate($0.date, inSameDayAs: day) }?.kcal }
    private var eventCount: Int { experience.visibleEvents.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }.count }
    private var calendarDays: [Date] {
        let earliest = allPoints.map(\.date).min().map { Calendar.current.startOfDay(for: $0) }
        let defaultStart = Calendar.current.date(byAdding: .day, value: -60, to: calendarAnchor)!
        let start = min(earliest ?? defaultStart, defaultStart)
        let count = Calendar.current.dateComponents([.day], from: start, to: calendarAnchor).day ?? 60
        return (0...count + 7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: start) }
    }
    private var dateMotion: Animation? { reduceMotion ? nil : .spring(duration: 0.42, bounce: 0.08) }
    private func selectDay(_ date: Date) {
        withAnimation(dateMotion) { day = Calendar.current.startOfDay(for: date) }
    }
    private func moveDay(_ offset: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: offset, to: day), calendarDays.contains(next) else { return }
        selectDay(next)
    }
    private func statCell(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.subheadline.weight(.medium)) }.frame(maxWidth: .infinity, alignment: .leading) }
    private var dateBar: some View {
        let dates = calendarDays
        let recordedDays = Set(allPoints.filter { $0.role != .intervalStart && $0.date <= Date() && $0.value.map { $0.isFinite && (0...100).contains($0) } == true }.map { Calendar.current.startOfDay(for:$0.groupingDate(instant:status.usesStateEstimate)) })
        return VStack(spacing: 8) {
            HStack {
                Button { moveDay(-1) } label: { Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold)).frame(width: 44, height: 44) }.accessibilityLabel("前一天").disabled(day == calendarDays.first)
                Spacer()
                Button { calendarOpen = true } label: {
                    HStack(spacing: 7) { Text(day.formatted(.dateTime.year().month())).lineLimit(1).minimumScaleFactor(0.5); Image(systemName: "calendar").font(.system(size: 16)) }.font(.subheadline.weight(.medium)).frame(minHeight: 44)
                }.accessibilityLabel("选择回看日期")
                Spacer()
                Button { moveDay(1) } label: { Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).frame(width: 44, height: 44) }.accessibilityLabel("后一天").disabled(day == calendarDays.last)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(dates, id: \.self) { date in
                            let selected = Calendar.current.isDate(date, inSameDayAs: day)
                            let hasRecord = recordedDays.contains(date)
                            Button { selectDay(date) } label: {
                                VStack(spacing: 8) {
                                    Text(Calendar.current.isDateInToday(date) ? "今天" : date.formatted(.dateTime.weekday(.narrow))).font(.system(size: 11, weight: .medium))
                                    Text(String(Calendar.current.component(.day, from: date))).font(.system(size: 20, weight: selected ? .semibold : .regular)).monospacedDigit()
                                    Circle().fill(hasRecord ? (selected ? Color.white : PocketStyle.green) : Color.clear).frame(width: 4, height: 4)
                                }.frame(width: 43, height: 66).foregroundStyle(selected ? Color.white : PocketStyle.ink.opacity(0.7))
                                    .background {
                                        if selected { RoundedRectangle(cornerRadius: 18).fill(PocketStyle.green).matchedGeometryEffect(id: "selected-date", in: calendarSelection) }
                                    }
                            }.buttonStyle(PocketPressStyle()).id(date)
                                .accessibilityLabel(date.formatted(.dateTime.month().day().weekday()) + (hasRecord ? "，有状态记录" : "，无状态记录"))
                                .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }.padding(.vertical, 4)
                }.scrollIndicators(.hidden)
                    .onAppear { proxy.scrollTo(day, anchor: .center) }
                    .onChange(of: day) { _, date in withAnimation(dateMotion) { proxy.scrollTo(date, anchor: .center) } }
            }
            HStack(spacing: 5) { Image(systemName: "arrow.left.arrow.right"); Text("左右滑动，回看每天") }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.top, 3)
        }
    }
    private var dailyPager: some View {
        DailyEnergyPager(day: $day, status: status, points: allPoints, headline: decision.headline,
                         workouts: health.snapshot?.workouts ?? [], demo: experience.demo, busy: health.busy,
                         compact: compactProbe, calendarDays: calendarDays,
                         revision: health.snapshot?.fetchedAt ?? status.computedAt,
                         refresh: { Task { await health.refresh() } })
    }

    private var estimate: RecoveryEstimate? {
        guard experience.demo || health.snapshot.map({ Date().timeIntervalSince($0.fetchedAt) < 21600 }) == true,
              let result = experience.estimates(health, target: target).filter({ Calendar.current.isDate($0.date, inSameDayAs: day) }).last else { return nil }
        return result
    }
    private var todayStrain: Double? {
        let minutes = RecoveryEngine.merged(workouts.map { SleepInterval(start:$0.start,end:$0.end) },from:day,to:Date()).reduce(0.0) { $0+$1.end.timeIntervalSince($1.start)/60 }
        return StrainEngine.strain(kcal: kcal, workoutMinutes: minutes)
    }
    private var decision: DailyDecision {
        DecisionEngine.make(estimate: estimate, status: status, lastNight: lastNight, todayKcal: kcal,
                            strain: todayStrain, sleepTarget: target, intent: intent, now: Date())
    }
    private var aiConfig: AIBackendConfig {
        AIBackendConfig(cloudEnabled: aiCloudEnabled && aiMorningCloudEnabled, endpoint: aiCloudEndpoint, model: aiCloudModel, hasStoredKey: aiHasKey, certificatePin: UserDefaults.standard.string(forKey: "aiBridgeCertificateSHA256") ?? "")
    }
    private var coachBrief: CoachBrief { experience.coachContext(health, target: target, intent: intent).brief(.today) }
    /// 只有这些输入变了才需要重新生成晨报；日期、重点、事实与本地结论任一变化都会触发。
    private var briefSignature: String {
        (["\(day.timeIntervalSince1970)", intent, String(target), String(experience.demo), String(health.cacheRevision), String(status.computedAt.timeIntervalSince1970), String(aiCloudEnabled), String(aiMorningCloudEnabled), aiCloudEndpoint, aiCloudModel, String(aiHasKey), decision.headline, decision.subline] + coachBrief.facts.map { "\($0.key)=\($0.value)=\($0.detail)" } + coachBrief.gaps)
            .joined(separator: "|")
    }
    private var displayBrief: MorningBrief {
        briefAI.brief ?? MorningBriefEngine.local(headline: decision.headline, subline: decision.subline,
                                                  facts: coachBrief.facts, gaps: coachBrief.gaps, now: Date())
    }
    private func refreshBrief(force: Bool) async {
        aiHasKey = aiConfig.validURL.map { AIKeychain.hasKey(matching: $0) } ?? false
        let given = [decision.headline, decision.subline] + decision.actions.map { "\($0.headline) \($0.reason)" }
        await briefAI.generate(headline: decision.headline, subline: decision.subline,
                               facts: coachBrief.facts, gaps: coachBrief.gaps, given: given,
                               config: aiConfig, force: force)
    }
    /// Simulator-only verification helper: hides the battery hero card so the full
    /// decision card fits one screenshot. Mirrors the existing --pocket-demo flags.
    /// `--pocket-brief` additionally scrolls to the bottom so the晨报来源行 is visible.
    private var briefProbe: Bool { ProcessInfo.processInfo.arguments.contains("--pocket-brief") }
    private var compactProbe: Bool { briefProbe || ProcessInfo.processInfo.arguments.contains("--pocket-compact") }
    private var suggestion: String { intent == "训练" ? "结合实际感受安排强度" : intent == "恢复" ? "留出一段不赶时间的休息" : "下午留出一次短休息" }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PageHeader(title: isToday ? "今天" : "电量日历")
                    if isToday { IntegratedTodayCard(headline:decision.headline).padding(.vertical,16) }
                    dateBar
                    HStack { DemoNote(); Spacer(); if !isToday { Button("回到今天") { selectDay(Date()) }.font(.caption) } }
                    
                    dailyPager.padding(.top, 16)
                    NavigationLink { RecoveryDetails(day:day) } label: {
                        MorningRecoveryCard(result:estimate,showsDisclosure:true)
                    }.buttonStyle(PocketPressStyle()).padding(.top,14)
                    if isToday {
                        NavigationLink { PocketCoachView() } label: {
                            HStack(spacing: 13) {
                                Image(systemName: "sparkles").font(.title3).foregroundStyle(PocketStyle.green)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("AI 健康教练").font(.subheadline.weight(.semibold))
                                    Text(aiCloudEnabled && aiHasKey ? "针对记录提问，查看依据并继续追问" : "连接已有 Codex 订阅，开始个性化问答").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4); Image(systemName: "arrow.up.right").font(.subheadline)
                            }.foregroundStyle(PocketStyle.ink).padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 18))
                        }.buttonStyle(PocketPressStyle()).padding(.top, 12)
                    }
                    if isToday,let lead = decision.actions.first {
                        Button { composerKind = lead.eventKind; composer = true } label: {
                            HStack(spacing:12) { Image(systemName:lead.icon).font(.title3); VStack(alignment:.leading,spacing:5) { Text(lead.headline).font(.subheadline.weight(.semibold)); Text(lead.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }; Spacer(minLength:4); Image(systemName:"plus.circle") }.foregroundStyle(PocketStyle.ink).padding(16).frame(maxWidth:.infinity,alignment:.leading).background(PocketStyle.green.opacity(0.04),in:RoundedRectangle(cornerRadius:16))
                        }.buttonStyle(.plain).accessibilityLabel("记录下一步："+lead.headline).padding(.top,12)
                    }
                    FlatRule()
                    if isToday {
                        DisclosureGroup("今日解读与行动建议") {
                            DecisionCard(decision:decision,brief:displayBrief,briefBusy:briefAI.busy,briefNotice:briefAI.notice,onRefreshBrief:{ Task { await refreshBrief(force:true) } },onOpenAIStatus:{ aiStatus = true }) { kind in composerKind = kind; composer = true }.padding(.top,12)
                            if let note = status.dataNote(at:Date()) { Text(note).font(.caption).foregroundStyle(.secondary).padding(.top,10) }
                        }.font(.subheadline).padding(.bottom,20)
                    }
                    DisclosureGroup("当天数据与统计") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 20) {
                        statCell(status.usesStateEstimate ? "状态最高 / 最低" : "电量最高 / 最低", stats.minimum.flatMap { low in stats.maximum.map { high in "\(Int(high.rounded())) / \(Int(low.rounded()))" } } ?? "—")
                        statCell(status.usesStateEstimate ? "状态记录" : "可比较观测",status.usesStateEstimate ? "\(dayPoints.count) 次" : String(format: "%.1f 小时", stats.coveredSeconds / 3600))
                        statCell("活动能量", kcal.map { String(format: "%.0f kcal", $0) } ?? "暂无记录")
                        statCell("步数", experience.demo ? (isFuture ? "暂无记录" : "6,420 步") : health.snapshot?.steps?.first { Calendar.current.isDate($0.date, inSameDayAs: day) }?.count.map { String(format: "%.0f 步", $0) } ?? "暂无记录")
                        statCell("训练 / 手动记录", "\(workouts.count) 次 / \(eventCount) 条")
                    }
                    Text(status.usesStateEstimate ? "历史状态只使用当时之前的信号回算；不是连续电量收支。" : "历史电量按当前实验模型重算。补充与消耗只统计相邻有效观测的净变化；缺失时段不补算。").font(.caption2).foregroundStyle(.secondary).padding(.top, 14)
                    }.font(.subheadline).padding(.vertical,4)
                    FlatRule()
                    NavigationLink { EnergyInsightsView(day: day) } label: { summaryRow("电量洞察", value: "时段 · 训练 · 七天节奏 →", icon: "chart.xyaxis.line") }.buttonStyle(.plain)
                    FlatRule()
                    if isToday {
                    NavigationLink { WeeklyReviewView() } label: { summaryRow("每周回顾与计划",value:"睡眠 · 训练 · 个人目标",icon:"chart.bar.xaxis") }.buttonStyle(.plain)
                    FlatRule()
                    HStack { Text("安排今天").font(.title3.weight(.semibold)); Spacer(); Text("让节奏更适合你").font(.caption).foregroundStyle(.secondary) }
                    HStack(spacing: 8) {
                        ForEach([("工作", "laptopcomputer"), ("训练", "dumbbell"), ("恢复", "leaf")], id: \.0) { item in
                            Button { withAnimation(dateMotion) { intent = item.0 } } label: { HStack(spacing: 6) { Image(systemName: item.1); Text(item.0) }.font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 13).foregroundStyle(intent == item.0 ? .white : PocketStyle.ink).background(intent == item.0 ? PocketStyle.green : .clear, in: Capsule()).overlay { Capsule().stroke(intent == item.0 ? .clear : PocketStyle.rule, lineWidth: 1) } }.buttonStyle(.plain)
                        }
                    }.padding(.top, 15)
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: intent == "工作" ? "cup.and.saucer" : intent == "训练" ? "figure.walk" : "leaf").font(.title3).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 6) { Text(suggestion).font(.subheadline.weight(.medium)); Text("以实际感受为准，记录后再回看变化。") .font(.caption).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                        Button { composerKind = intent == "训练" ? "训练" : "休息"; composer = true } label: { Text("记录 →").font(.subheadline) }.accessibilityLabel("记录休息或当前感受")
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
                .defaultScrollAnchor(briefProbe ? .bottom : .top)
                .refreshable { if experience.demo { experience.toggleDemo(true, health: health) } else { await health.refresh() }; await refreshBrief(force: true) }
                .task(id: briefSignature) { if isToday { await refreshBrief(force: false) } }
                .onDisappear { briefAI.reset() }
                .onChange(of: day) { _,_ in timelineSelection = nil }
                .sensoryFeedback(.selection, trigger: day)
                .onChange(of: aiStatus) { _, shown in if !shown { aiHasKey = aiConfig.validURL.map { AIKeychain.hasKey(matching: $0) } ?? false } }
                .onAppear {
                    #if targetEnvironment(simulator)
                    // 与 --pocket-demo / --pocket-load 同类：只用于模拟器截图，不参与真实流程。
                    if ProcessInfo.processInfo.arguments.contains("--pocket-ai") { aiStatus = true }
                    // Layout fixtures only: these flags never run on a physical phone.
                    let arguments = ProcessInfo.processInfo.arguments
                    if let index = arguments.firstIndex(of: "--pocket-calendar-offset"), arguments.indices.contains(index + 1), let offset = Int(arguments[index + 1]), (-60...7).contains(offset) {
                        day = Calendar.current.date(byAdding: .day, value: offset, to: calendarAnchor)!
                    }
                    #endif
                }
                .sheet(isPresented: $aiStatus) { NavigationStack { AIStatusView() } }
                .sheet(isPresented: $calendarOpen) { NavigationStack { DatePicker("选择日期", selection: Binding(get: { day }, set: { selectDay($0) }), in: calendarDays.first!...calendarDays.last!, displayedComponents: .date).datePickerStyle(.graphical).padding(24).navigationTitle("选择日期").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { calendarOpen = false } } } }.tint(PocketStyle.green) }
                .sheet(isPresented: $composer) { EventComposer(defaultKind: composerKind) }
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
    var embedded = false
    var body: some View {
        Group { if embedded { content } else { NavigationStack { content } } }
    }
    private var content: some View { ScrollView { VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "趋势"); DemoNote()
            NavigationLink { EnergyInsightsView(day: Calendar.current.startOfDay(for: Date())) } label: { HStack { Image(systemName: "square.grid.3x3.fill"); VStack(alignment: .leading, spacing: 4) { Text("电量节奏地图").font(.subheadline.weight(.medium)); Text("按小时看消耗，按日期回看训练").font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right").font(.caption) }.padding(18).foregroundStyle(PocketStyle.green).background(PocketStyle.green.opacity(0.055), in: RoundedRectangle(cornerRadius: 18)) }.buttonStyle(.plain)
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
        }.padding(24) }.safeAreaPadding(.bottom, 24).background(PocketStyle.paper).toolbar(embedded ? .visible : .hidden, for: .navigationBar).navigationTitle("指标趋势").navigationBarTitleDisplayMode(.inline)
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
    private var result: RecoveryEstimate? { let rows = experience.estimates(health, target: target); return day.flatMap { date in rows.first { Calendar.current.isDate($0.date, inSameDayAs: date) } } ?? (day == nil ? rows.last : nil) }
    private var reference: Int? {
        let nights = experience.nights(health)
        let latest = day.flatMap { date in nights.first { Calendar.current.isDate($0.date,inSameDayAs:date) } } ?? nights.filter { $0.hrv != nil && $0.sleepHours != nil }.max { $0.date < $1.date }
        guard let latest, let hrv = latest.hrv else { return nil }
        let prior = nights.filter { $0.date < latest.date && $0.hrvSourceKey == latest.hrvSourceKey && $0.hrvDurationBucket == latest.hrvDurationBucket && $0.hrvCount > 0 && $0.hrv.map { $0.isFinite && $0 > 0 } == true }
        let resting:[VitalRecord] = experience.demo ? (0..<42).map { offset in VitalRecord(name:"静息心率",date:Calendar.current.date(byAdding:.day,value:-offset,to:Calendar.current.startOfDay(for:Date()))!,value:55+sin(Double(offset))*0.6,unit:"次/分",source:"合成演示") } : (health.snapshot?.vitals ?? []).filter { $0.name == "静息心率" }
        guard let rhr = resting.first(where:{ Calendar.current.isDate($0.date,inSameDayAs:latest.date) }) else { return nil }
        let pastRHR = resting.filter { $0.date < rhr.date && $0.source == rhr.source && $0.date >= rhr.date.addingTimeInterval(-28*86400) }
        guard prior.count >= 14, pastRHR.count >= 14 else { return nil }
        return OpenRecoveryReference.score(hrv:hrv,baselineHRV:RecoveryEngine.median(prior.compactMap(\.hrv)),restingHR:rhr.value,baselineRestingHR:RecoveryEngine.median(pastRHR.map(\.value)),sleepMinutes:latest.sleepHours.map { $0*60 },needMinutes:target*60)
    }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                DemoNote()
                if let date=result?.date { Text(date.formatted(date:.abbreviated,time:.omitted)).font(.caption).foregroundStyle(.secondary) }
                MorningRecoveryCard(result:result)
                Text(RecoveryModelV2.scaleNote).font(.subheadline).foregroundStyle(.secondary)
                if let low=result?.lower,let high=result?.upper {
                    LabeledContent("模型不确定范围",value:"\(low)–\(high)")
                    Text("范围反映采样与模型的不确定性，尚未验证为统计置信区间。").font(.caption).foregroundStyle(.secondary)
                }
                FlatRule()
                Text("影响这次估计的因素").font(.headline)
                ForEach((result?.reasons ?? []).filter { $0.name != "分数含义" }) { reason in
                    VStack(alignment:.leading,spacing:6) {
                        Text(reason.name).font(.subheadline.weight(.medium))
                        Text(reason.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                }
                DisclosureGroup("模型与开源对照") {
                    LabeledContent("开源算法对照",value:reference.map(String.init) ?? "数据不足").padding(.top,12)
                    Text("Whoordan 部分公式，Apache 2.0。需要匹配历史的睡眠 SDNN 与真实静息心率；标尺不同，只作对照。当前恢复指数未经个人校准，不是 WHOOP 算法。").font(.caption).foregroundStyle(.secondary)
                    Text(RecoveryModelV2.revision).font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(24)
        }.safeAreaPadding(.bottom,24).background(PocketStyle.paper).navigationTitle("晨间恢复").toolbar(.visible,for:.navigationBar)
    }
}
private struct MorningRecoveryCard: View {
    var result:RecoveryEstimate?
    var showsDisclosure=false
    private var color:Color { guard let value=result?.score else { return PocketStyle.ink.opacity(0.5) };return value < 45 ? PocketStyle.drain : value >= 80 ? PocketStyle.green : PocketStyle.mint }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Label("晨间恢复",systemImage:"sun.horizon").font(.subheadline.weight(.semibold));Spacer();if showsDisclosure { Image(systemName:"arrow.up.right").font(.caption) } }
            HStack(alignment:.firstTextBaseline,spacing:10) {
                Text(result?.score.map(String.init) ?? "—").font(.system(size:46,weight:.light)).monospacedDigit().foregroundStyle(color)
                VStack(alignment:.leading,spacing:4) {
                    Text(result?.state ?? "恢复待比较").font(.subheadline.weight(.medium))
                    Text(result?.scoreBasis ?? "等待可比的睡眠 HRV 或心率").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let score=result?.score {
                GeometryReader { geo in
                    ZStack(alignment:.leading) {
                        Capsule().fill(LinearGradient(colors:[PocketStyle.drain.opacity(0.7),PocketStyle.mint,PocketStyle.green],startPoint:.leading,endPoint:.trailing))
                        Circle().fill(PocketStyle.paper).overlay(Circle().stroke(color,lineWidth:2)).frame(width:14,height:14).offset(x:max(0,(geo.size.width-14)*Double(score)/100))
                    }
                }.frame(height:8).padding(.vertical,4).accessibilityHidden(true)
                HStack { Text("偏低");Spacer();Text("65 · 个人惯常");Spacer();Text("较有利") }.font(.caption2).foregroundStyle(.secondary)
            } else if let completion=result?.sleepCompletion {
                Text("睡眠目标完成 \(completion)% · 睡眠记录照常保留").font(.caption).foregroundStyle(PocketStyle.green)
            }
            Text(result?.reliability ?? "已有数据会继续展示；没有基线时不填入默认高分。").font(.caption2).foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth:.infinity,alignment:.leading).foregroundStyle(PocketStyle.ink)
            .background(PocketStyle.green.opacity(0.045),in:RoundedRectangle(cornerRadius:20))
            .accessibilityElement(children:.combine)
    }
}
private struct WorkoutCardioCard:View {
    var workout:PocketWorkout
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack { Text(workout.title).font(.subheadline.weight(.semibold));Spacer();Text(workout.start.formatted(date:.omitted,time:.shortened)).font(.caption).foregroundStyle(.secondary) }
            if let cardio=workout.cardio {
                HStack(alignment:.firstTextBaseline) {
                    Text(cardio.averageHR.map { String(format:"%.0f",$0) } ?? "—").font(.system(size:30,weight:.light)).monospacedDigit()
                    Text("平均心率").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(cardio.peakHR.map { String(format:"峰值 %.0f",$0) } ?? "峰值 —").font(.caption).foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment:.leading) { Capsule().fill(PocketStyle.ink.opacity(0.06));Capsule().fill(PocketStyle.mint).frame(width:geo.size.width*cardio.coverageFraction) }
                }.frame(height:6).accessibilityHidden(true)
                Text(String(format:"心率覆盖 %.1f / %.1f 分钟 · %.0f%%",cardio.coveredMinutes,cardio.windowMinutes,cardio.coverageFraction*100)).font(.caption).foregroundStyle(.secondary)
                if let load=cardio.relativeLoadMinutes,let baseline=cardio.restingReference {
                    Text(String(format:"相对负荷 %.1f 加权分钟 · 静息参考 %.0f",load,baseline)).font(.caption).foregroundStyle(PocketStyle.green)
                    Text("按高于个人静息心率的幅度与已观测时长累计，公式未经个人校准；不是 WHOOP 分数。").font(.caption2).foregroundStyle(.secondary)
                } else { Text("静息基线不足时只展示实际心率，不猜测个人强度。").font(.caption2).foregroundStyle(.secondary) }
            } else {
                Text("尚无可用的训练时段心率；刷新后按已有记录计算。").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(.white,in:RoundedRectangle(cornerRadius:16))
    }
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
            Section {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(title: "记录")
                    DemoNote()
                    Text("先给此刻的精力打分。也可以选填今天的习惯，或记下刚发生的事，留给之后回看。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("记录此刻") { composer = true }.buttonStyle(.borderedProminent)
                }
            }.listRowSeparator(.hidden).listRowBackground(PocketStyle.paper)
            Section("回看我的记录") {
                NavigationLink { FeedbackReviewView() } label: { Label("状态与体感对照", systemImage: "checkmark.bubble") }
                NavigationLink { HabitInsightsView() } label: { Label("习惯与精力对照", systemImage: "list.bullet.clipboard") }
            }.listRowBackground(PocketStyle.paper)
            Section("时间线") {
                Picker("筛选记录", selection: $filter) {
                    ForEach(["全部", "自评", "休息", "训练", "咖啡", "饮酒", "晚睡"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu)
                if filteredEvents.isEmpty { Text(experience.recordsUnavailable ? "已有记录暂时无法显示。" : filter == "全部" ? "你的第一条记录，从此刻开始。" : "还没有这一类记录。") .foregroundStyle(.secondary) }
                ForEach(filteredEvents) { event in Button { editing = event } label: { VStack(alignment: .leading, spacing: 7) { HStack { Text(event.kind).font(.headline); Spacer(); Text("精力 \(event.energy)/5").font(.caption).foregroundStyle(PocketStyle.green) }; Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary); if let load=event.sessionLoad { Text(String(format:"训练体感 %d/10 · %.0f 分钟 · 主观负荷 %.0f",event.sessionRPE!,event.trainingMinutes!,load)).font(.caption).foregroundStyle(PocketStyle.green) }; if !event.note.isEmpty { Text(event.note).font(.subheadline) } } }.buttonStyle(.plain).accessibilityHint("编辑记录") }
                    .onDelete { offsets in let rows = filteredEvents; experience.remove(Set(offsets.map { rows[$0].id })) }
            }.listRowBackground(PocketStyle.paper)
            if !legacy.isEmpty && !experience.demo { Section("以前的自评") { ForEach(legacy.keys.sorted().reversed(), id: \.self) { date in VStack(alignment: .leading) { Text(date); Text(legacy[date] ?? "").font(.caption).foregroundStyle(.secondary) } } }.listRowBackground(PocketStyle.paper) }
            if experience.canUndoDeletion { Section { Button("撤销最近删除") { experience.undoDeletion() }; Text("可撤销本次打开内的最近一批删除。切换演示或退出 App 后不保留撤销。") .font(.caption).foregroundStyle(.secondary) }.listRowBackground(PocketStyle.paper) }
            Section { Text(experience.demo ? "演示记录只保存在本次会话，不混入真实记录。" : "本机保存，不改写生理评分。点记录可编辑，左滑可删除。") .font(.caption).foregroundStyle(.secondary); if let error = experience.error { Text(error).foregroundStyle(.orange) } }.listRowBackground(PocketStyle.paper)
        }.listStyle(.plain).scrollContentBackground(.hidden).background(PocketStyle.paper).toolbar(.hidden, for: .navigationBar).sheet(isPresented: $composer) { EventComposer(defaultKind: "自评") }.sheet(item: $editing) { event in EventComposer(defaultKind: event.kind, editing: event) } }
    }
}
struct EventComposer: View {
    @State private var habitAnswers:[String:Bool] = [:]
    @EnvironmentObject var experience: PocketExperience
    @EnvironmentObject var health:HealthStore
    @Environment(\.dismiss) var dismiss
    let defaultKind: String
    var editing: PocketEvent? = nil
    var initialDate: Date? = nil
    var workout:PocketWorkout? = nil
    @State private var kind = "自评"
    @State private var energy:Int?
    @State private var rpe:Int?
    @State private var minutesText=""
    @State private var prediction:RecordedPrediction?
    @State private var modelComparison:FrozenModelComparison?
    @State private var note = ""
    @State private var date = Date()
    @State private var validation:String?
    @State private var initialized=false
    private var attachedPrediction:RecordedPrediction? {
        if editing != nil { return prediction.flatMap { $0.usable(for:date,now:Date()) ? $0:nil } }
        return FeedbackEngine.attachment(prediction,eventDate:date,recordedAt:Date())
    }
    private func save() {
        guard let energy,(1...5).contains(energy) else { validation="请先选择此刻精力。";return }
        let minutes=Double(minutesText.trimmingCharacters(in:.whitespaces))
        if kind == "训练",rpe != nil,minutes.map({ $0.isFinite && $0 > 0 && $0 <= 1440 }) != true { validation="补充训练强度时，请填写大于 0 且不超过 1440 分钟的实际训练时长。";return }
        let captured=attachedPrediction
        var event=PocketEvent(id:editing?.id ?? UUID(),date:date,kind:kind,energy:energy,note:String(note.prefix(500)),prediction:captured,sessionRPE:kind == "训练" ? rpe:nil,trainingMinutes:kind == "训练" && rpe != nil ? minutes:nil,workoutID:kind == "训练" ? (workout?.id ?? editing?.workoutID):nil,habitAnswers:habitAnswers.isEmpty ? nil:habitAnswers,recordedAt:editing?.recordedAt ?? Date(),modifiedAt:editing == nil ? nil:Date())
        if editing != nil {event.modelComparison=modelComparison}
        else if let modelComparison,modelComparison.usable(for:event,now:Date()) {event.modelComparison=modelComparison}
        if editing == nil ? experience.add(event):experience.update(event) { dismiss() }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    HStack {
                        Button("取消") { dismiss() }.frame(minHeight:44)
                        Spacer()
                        Button("保存记录",action:save).font(.subheadline.weight(.semibold)).padding(.horizontal,18).frame(minHeight:44).foregroundStyle(.white).background(energy == nil ? PocketStyle.ink.opacity(0.25):PocketStyle.green,in:Capsule()).disabled(energy == nil)
                    }.buttonStyle(.plain)
                    Text(editing == nil ? "记录此刻" : "编辑记录").font(.system(size:30,weight:.semibold))
                    DemoNote()
                    VStack(alignment:.leading,spacing:22) {
                        Picker("记录什么",selection:$kind) { ForEach(["自评","休息","训练","咖啡","饮酒","晚睡"],id:\.self) { Text($0) } }
                        Divider()
                        DatePicker("时间",selection:$date,in:...Date())
                        Divider()
                        VStack(alignment:.leading,spacing:12) {
                            Text("此刻精力").font(.headline)
                            HStack(spacing:8) {
                                ForEach(1...5,id:\.self) { value in
                                    Button { energy=value;validation=nil } label: {
                                        Text(String(value)).font(.title3.weight(.medium)).frame(maxWidth:.infinity,minHeight:48).foregroundStyle(energy == value ? .white:PocketStyle.ink).background(energy == value ? PocketStyle.green:PocketStyle.green.opacity(0.06),in:RoundedRectangle(cornerRadius:12))
                                    }.buttonStyle(.plain).accessibilityLabel("精力 \(value) 分，满分 5 分").accessibilityAddTraits(energy == value ? .isSelected:[])
                                }
                            }
                            HStack { Text("1 · 很疲惫");Spacer();Text("5 · 精力充沛") }.font(.caption).foregroundStyle(.secondary)
                            if energy == nil { Text("请主动选择，不会预填为 3 分。").font(.caption).foregroundStyle(.secondary) }
                        }
                        if kind == "训练" {
                            Divider()
                            Picker("整次训练有多费力（可选）",selection:$rpe) {
                                Text("暂不填写").tag(Int?.none)
                                ForEach(0...10,id:\.self) { value in Text("\(value) / 10").tag(Int?.some(value)) }
                            }.pickerStyle(.menu)
                            if rpe != nil { TextField("实际训练时长（分钟）",text:$minutesText).keyboardType(.decimalPad) }
                            Text("回顾整次训练：0 为完全不费力，10 为极其费力。强度 × 时长记录为主观训练负荷，不与热量重复相加。").font(.caption).foregroundStyle(.secondary)
                        }
                        if let workout { Text("关联训练："+workout.title).font(.caption).foregroundStyle(PocketStyle.green) }
                        Divider()
                        habitContext
                        TextField("一句话记录（可选）",text:$note,axis:.vertical).lineLimit(3...5).onChange(of:note) { _, value in if value.count > 500 { note=String(value.prefix(500)) } }
                        if let error=validation ?? experience.error { Text(error).font(.caption).foregroundStyle(PocketStyle.drain) }
                    }.padding(20).background(PocketStyle.green.opacity(0.055),in:RoundedRectangle(cornerRadius:20))
                    if let modelComparison,modelComparison.baseline.usable(for:date,now:Date()),editing != nil || Date().timeIntervalSince(modelComparison.baseline.capturedAt)<=300 { Text(editing == nil ? "已同时冻结正式与影子模型；填写后才能进入双模型对照。候选不改写当前电量。":"编辑仍会保留原预测，但该条不再进入前瞻双模型检验。").font(.caption).foregroundStyle(PocketStyle.green) }
                    Text(attachedPrediction != nil ? "已保留填写前的模型结果，保存后可在“状态与体感对照”回看。自评不会直接改写电量。":"当前没有可配对的新鲜模型结果，仍可保存体感；补记历史不会回填现在的分数。").font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }.background(PocketStyle.paper).toolbar(.hidden,for:.navigationBar).scrollDismissesKeyboard(.interactively)
                .onAppear {
                    guard !initialized else { return };initialized=true
                    kind=editing?.kind ?? defaultKind
                    habitAnswers=editing?.habitAnswers ?? [:]
                    if let editing { energy=editing.energy;note=editing.note;date=editing.date;prediction=editing.prediction;modelComparison=editing.modelComparison;rpe=editing.sessionRPE;minutesText=editing.trainingMinutes.map { String(format:"%.0f",$0) } ?? "" }
                    else {
                        let now=Date();date=now
                        if let initialDate,!Calendar.current.isDate(initialDate,inSameDayAs:now) { date=min(now,Calendar.current.date(bySettingHour:12,minute:0,second:0,of:initialDate) ?? initialDate) }
                        prediction=RecordedPrediction.capture(experience.status(health),at:now)
                        modelComparison=FrozenModelComparison.capture(experience.shadow(health),expected:experience.status(health),at:now)
                        if let workout {kind="训练";minutesText=String(format:"%.0f",workout.duration/60)}
                    }
                    experience.error=nil
                }.tint(PocketStyle.green)
        }
    }
    private var habitContext: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("这一天的习惯（可选）").font(.headline)
            Text("只填想对照的项目。确实没有发生时选「无」，暂不确定就留在「未记录」。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(HabitEvidenceEngine.names.keys.sorted(), id: \.self) { key in
                Picker(HabitEvidenceEngine.names[key] ?? key, selection: Binding(
                    get: { habitAnswers[key].map { $0 ? 1 : 2 } ?? 0 },
                    set: { value in
                        if value == 0 { habitAnswers.removeValue(forKey: key) }
                        else { habitAnswers[key] = value == 1 }
                    }
                )) {
                    Text("未记录").tag(0)
                    Text("有").tag(1)
                    Text("无").tag(2)
                }.pickerStyle(.menu)
            }
        }
    }
}

struct PocketProfile: View {
    @ObservedObject private var bridge = WatchBridge.shared
    @EnvironmentObject var health: HealthStore
    @EnvironmentObject var experience: PocketExperience
    @AppStorage("sleepTarget") private var target = 8.0
    @State private var settings = false
    var body: some View { NavigationStack { ScrollView { VStack(alignment: .leading, spacing: 20) { PageHeader(title: "我的"); Text("只对照自己的节奏。").foregroundStyle(.secondary); FlatRule(); Toggle("体验演示数据", isOn: Binding(get: { experience.demo }, set: { experience.toggleDemo($0, health: health) })); Text("演示会同步到手表和组件，并明确标记。关闭后恢复真实摘要。") .font(.caption).foregroundStyle(.secondary); FlatRule(); Text("健康与设备").font(.title3.weight(.semibold)); NavigationLink(health.requested ? "健康连接与读取检查" : "连接 Apple 健康") { HealthConnectionView() }.buttonStyle(.borderedProminent); Text(bridge.connection).font(.caption).foregroundStyle(.secondary); NavigationLink("添加手机与手表组件") { WidgetInstructions() }; NavigationLink("数据来源与覆盖") { DataCoverage() }; Button("睡眠目标、权限与隐私") { settings = true }; NavigationLink("教练与数据解读") { PocketCoachView() }; NavigationLink("AI 接入与自检") { AIStatusView() }; NavigationLink("了解估计与算法") { EstimateDetails() }; if let notice = health.notice { Text(notice).font(.caption).foregroundStyle(.secondary) } }.padding(24) }.safeAreaPadding(.bottom, 24).background(PocketStyle.paper).toolbar(.hidden, for: .navigationBar).sheet(isPresented: $settings) { SettingsView(sleepTarget: $target) } } }
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
                ForEach(snapshot.coverage) { row in HStack(alignment: .top) { Text(row.name); Spacer(); Text(row.readFailure != nil ? "读取失败" : row.count == 0 ? "暂无可读记录" : "\(row.days)天 · \(row.count)条").foregroundStyle(row.readFailure != nil || row.count == 0 ? PocketStyle.drain : PocketStyle.green) }.font(.caption) }
                let activityDays = snapshot.energy.filter { $0.kcal != nil }.count
                LabeledContent("活动能量", value: "\(activityDays) 天有统计").font(.caption)
                Text(health.battery.message).font(.caption).foregroundStyle(.secondary)
                NavigationLink("查看来源、采样时间与覆盖") { DataCoverage() }
            }
            if let notice = health.notice { Text(notice).font(.subheadline).foregroundStyle(PocketStyle.drain) }
            Text("可选新增：静息能量、饮食能量、体重、体脂、去脂体重、身高，以及步数、正念、呼吸率、腕温和血氧。用于状态背景与个人趋势。点下方按钮自行选择允许读取的项目；未允许的指标留空，原有功能仍可使用。") .font(.caption).foregroundStyle(.secondary)
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
    var body: some View { List { if let snapshot = health.snapshot { Section { Text("最后读取 \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))") }; ForEach(snapshot.coverage) { row in Section(row.name) { if let failure = row.readFailure { Text(failure).foregroundStyle(PocketStyle.drain) } else { Text("\(row.days) 天 · \(row.count) 条") }; ForEach(row.sources, id: \.self) { Text($0).font(.caption) }; if let date = row.lastSample { Text("最新 \(date.formatted(date: .abbreviated, time: .shortened))") } } } } else { Text("连接健康后查看真实数据来源。") }; Section { Text("系统无法直接区分读取被拒绝与没有记录。演示不伪装成真实覆盖。") } }.navigationTitle("数据覆盖").toolbar(.visible, for: .navigationBar) }
}
struct StateScoreBreakdown:View {
    var estimate:CurrentStateEstimate
    private var effects:[CurrentStateFactor] {(estimate.factors ?? []).filter{$0.key != "prior"}}
    private var extent:Double {max(10,ceil((effects.map{abs($0.points)}.max() ?? 0)/10)*10)}
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            if let factors=estimate.factors {
                HStack(alignment:.firstTextBaseline) {
                    Text("从初始假设到当下参考").font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(estimate.value)").font(.system(size:32,weight:.medium)).monospacedDigit().foregroundStyle(PocketStyle.green)
                }
                Text("65 是尚未校准的初始假设，下面是已有信号带来的工程修正。").font(.caption).foregroundStyle(.secondary)
                if !effects.isEmpty {
                    Chart(effects) { factor in
                        BarMark(x:.value("模型修正",factor.points),y:.value("依据",factor.title),height:.ratio(0.5))
                            .foregroundStyle(factor.points<0 ? PocketStyle.drain:PocketStyle.green).cornerRadius(3)
                            .accessibilityLabel(factor.title).accessibilityValue(String(format:"%+.2f 点",factor.points))
                        RuleMark(x:.value("零",0)).foregroundStyle(PocketStyle.ink.opacity(0.25))
                    }.chartXScale(domain:(-extent)...extent).chartLegend(.hidden)
                        .frame(height:CGFloat(max(2,effects.count))*40)
                        .accessibilityLabel("近期状态分数拆解；模型修正不是实际电量收支")
                } else {
                    Text("还没有足够的可比信号；此刻主要显示初始假设，参考范围较宽。").font(.caption)
                }
                ForEach(factors) { factor in
                    DisclosureGroup {
                        Text(factor.detail).font(.caption).foregroundStyle(.secondary)
                        if let date=factor.observedAt {Text("观测 "+date.formatted(date:.abbreviated,time:.shortened)).font(.caption2)}
                        if factor.baselineDays>0 {Text("同来源历史 \(factor.baselineDays) 个日期").font(.caption2)}
                    } label: {
                        HStack {
                            Text(factor.title).font(.subheadline)
                            Spacer()
                            Text(String(format:"%+.2f",factor.points)).font(.subheadline.monospacedDigit())
                                .foregroundStyle(factor.points<0 ? PocketStyle.drain:PocketStyle.green)
                        }
                    }.tint(PocketStyle.green)
                }
                Text("各项相加等于显示分数；它们不是已测得的身体电量变化，也不代表因果效应。睡眠片段的完整性未知时，不据此计算缺觉扣分。").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("这条旧摘要没有保存分数拆解。刷新后使用新版计算，不反向编造旧依据。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
struct EstimateDetails: View {
    @EnvironmentObject private var health:HealthStore
    @EnvironmentObject private var experience:PocketExperience
    private var status:PocketStatus { experience.status(health) }
    var body: some View { List {
        if experience.demo || status.demo { DemoNote() }
        if status.usesStateEstimate {
            Section("近期状态与连续电量分开") {
                Text(status.scoreMeaning.title).font(.headline)
                Text(status.scoreMeaning.detail).font(.subheadline)
                Text(status.message).font(.caption).foregroundStyle(.secondary)
                if let estimate=status.stateEstimate {
                    LabeledContent("实际使用",value:estimate.basis)
                    LabeledContent("个人历史",value:"\(estimate.baselineDays) 个可比日")
                    LabeledContent("观测时间",value:estimate.measuredAt.formatted(date:.abbreviated,time:.shortened))
                    LabeledContent("参考范围（未校准）",value:"\(estimate.lower)–\(estimate.upper)")
                    Text(estimate.note).font(.caption).foregroundStyle(.secondary)
                }
                Text("HRV 按同来源、同场景历史比较，活动背景会降低权重；没有基线时使用中性初始假设并扩大范围。以下电量输入保留用于排查，不代表当前状态估计。").font(.caption)
            }
        }
        if status.usesStateEstimate,let estimate=status.stateEstimate {
            Section("这个分数怎样组成") { StateScoreBreakdown(estimate:estimate) }
        }
        if let continuity = status.continuity {
            Section("连续电量怎样承接") {
                LabeledContent("本段起点",value:continuity.segmentStart.formatted(date:.abbreviated,time:.shortened))
                LabeledContent("起点参考值",value:String(format:"%.0f / 100",continuity.initialValue))
                LabeledContent("缺测分段",value:"\(continuity.segmentCount) 段")
                LabeledContent("今天推断的非睡眠心率覆盖",value:String(format:"%.1f 小时",continuity.inferredHoursToday))
                Text(continuity.note).font(.caption).foregroundStyle(.secondary)
                Text("相邻时段承接电量，跨午夜不重置；超过六小时无有效时段记录会断开曲线。新的起点不计为恢复。心率覆盖推断只连接相隔不超过十分钟的采样；不会跨过整晚空档。").font(.caption)
            }
        }
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
                if let fallback = inputs.workoutHeartFallbackDrain,fallback > 0 {
                    LabeledContent("热量缺测时的训练心率参考",value:String(format:"%.2f 点",fallback))
                    Text("仅在未读到有效活动热量的时段使用相邻不超过90秒的真实训练心率；不与热量叠加，未覆盖时段不补算。它仍是未校准的工程估计。").font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("已记录活动能量",value:String(format:"%.0f kcal",inputs.activeKcal))
                LabeledContent("有数据的小时区间",value:String(format:"%.1f 小时",inputs.observedHours))
                LabeledContent("缺少时间覆盖",value:String(format:"%.1f 小时",inputs.unobservedHours ?? 0))
                LabeledContent("最近睡眠观测",value:inputs.latestSleepEnd.map { $0.formatted(date:.abbreviated,time:.shortened) } ?? "尚未读到")
                Text("HRV 覆盖为 0 表示该项没有影响本次时段计算，不表示 HRV 为零。睡眠跨午夜部分归前一天；有数据的小时仍可能只有稀疏采样。").font(.caption).foregroundStyle(.secondary)
            } else { Text("刷新健康数据后显示计算输入。") }
        }
        if !experience.demo {
            Section("这个结果受起点影响多大") {
                if let range = health.batteryAnchorSensitivity {
                    LabeledContent("换两个起点重算",value:"\(range.low)–\(range.high)")
                    Text("保持健康记录不变，把各观测片段的起点分别设为 35 和 65，得到上述两个结果。差距越大，当前分数越受初始假设影响。这不是置信区间，也不会改写实际电量。").font(.caption).foregroundStyle(.secondary)
                } else { Text("有可计算的真实记录后展示起点敏感性。演示数据不作为个人验证。") }
                NavigationLink("核对健康来源与读取时间") { DataCoverage() }
            }
        }
        Section("睡眠恢复曲线") { Text("采用逐渐接近 100 的恢复曲线，电量较低时补充较快，接近充足时变慢。睡眠 HRV 相对个人历史偏低、睡眠心率偏高时会降低速度。6 小时的恢复时间参数仍是待校准的工程假设，不保证睡够就到 100，也不是 Garmin 的公式。") }
 Section("身体电量") { Text("基于已有睡眠、活动、心率和睡眠时段 HRV 估算，有记录即可初步计算。睡眠 HRV 与更早的个人睡眠记录比较；心率偏高时降低睡眠补充。训练读到活动热量时不重复加算心率消耗；热量缺测且有可比心率基线时，只对实际训练采样覆盖使用心率参考。训练不视为清醒休息。小时活动能量不能证明整小时清醒；按时间消耗只作用于观测覆盖窗口。起点只在首次记录或长时间缺测后建立；有合适信号时用当时的初步状态，否则用明确标记的 50 分假设。后续时段承接电量，不随每条 HRV 重置；起点和系数仍需个人校准。") }; Section("观测与范围") { Text("连续电量两小时没有新观测后隐藏当前值；跨午夜承接，缺少记录不会自动恢复或清零。曲线只显示已有观测，不插补采样空洞。范围是模型内部估算范围，不是经验证的置信区间。") }; Section("恢复与开源对照") { Text("恢复使用个人历史和状态滤波；Whoordan 的部分开源公式用于独立对照，许可为 Apache 2.0。身体电量借鉴 Garmin 公开的持续充放电思路；公式和系数是本 App 的实验实现，未经生理准确性验证。Apple 健康里的 SDNN 采样不能直接当成佳明的连续压力信号。") }; Section("使用方式") { Text("今日安排是你选择的计划，以实际感受为准。事件记录不改变生理分数，也不会直接产生习惯因果结论。") } }.scrollContentBackground(.hidden).background(PocketStyle.paper).navigationTitle("估计说明").toolbar(.visible, for: .navigationBar) }
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
                    WorkoutCardioCard(workout:impact.workout)
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
    private var latestNight: NightRecord? { experience.nights(health).filter { $0.sleepHours != nil && Calendar.current.isDateInToday($0.date) }.max { $0.date < $1.date } }
    private var recovery: RecoveryEstimate? { experience.estimates(health, target: sleepTarget).filter { $0.score != nil }.max { $0.date < $1.date } }
    private var steps: Double? { experience.demo ? 6420 : health.snapshot?.steps?.first { Calendar.current.isDateInToday($0.date) }?.count }
    var body: some View {
        NavigationStack { ScrollView { VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "身体"); DemoNote()
            hrvOverview
            healthGrid
            NavigationLink { EnergyBudgetView() } label: { overviewRow("能量收支", subtitle:"静息＋活动－摄入 · Keep 与拍照饮食", icon:"flame") }
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

// MARK: - 恢复–负荷双环
struct DualRing: View {
    var recovery: Int?
    var strain: Double?
    var diameter: CGFloat = 116
    var body: some View {
        HStack(spacing: 24) {
            ring(title: "恢复", fraction: recovery.map { Double($0) / 100 }, display: recovery.map(String.init) ?? "—", unit: "/ 100", color: PocketStyle.green)
            ring(title: "负荷", fraction: strain.map { $0 / StrainEngine.ceiling }, display: strain.map { String(format: "%.1f", $0) } ?? "—", unit: "/ 21", color: PocketStyle.drain)
        }
    }
    private func ring(title: String, fraction: Double?, display: String, unit: String, color: Color) -> some View {
        let value = min(1, max(0, fraction ?? 0))
        return VStack(spacing: 8) {
            ZStack {
                Circle().stroke(PocketStyle.ink.opacity(0.08), lineWidth: 10)
                if value > 0 {
                    Circle().trim(from: 0, to: value)
                        .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 0) {
                    Text(display).font(.system(size: 26, weight: .light)).monospacedDigit().foregroundStyle(PocketStyle.ink)
                    Text(unit).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.frame(width: diameter, height: diameter)
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(display) \(unit)")
    }
}

// MARK: - 今日决策卡
struct DecisionCard: View {
    var decision: DailyDecision
    var brief: MorningBrief
    var briefBusy: Bool
    var briefNotice: String?
    var onRefreshBrief: () -> Void
    var onOpenAIStatus: () -> Void
    var onRecord: (String) -> Void
    @State private var showCaveat = false
    private var briefBadge: String { brief.source == .local ? "本地表述" : brief.source.short + "整理" }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 8) {
                Text("今日决策").font(.subheadline.weight(.medium)).foregroundStyle(PocketStyle.ink)
                Spacer(minLength: 8)
                Button { onOpenAIStatus() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: brief.source == .local ? "leaf" : "sparkles").font(.system(size: 10))
                        Text(briefBadge).font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(PocketStyle.green)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(PocketStyle.green.opacity(0.12), in: Capsule())
                }.buttonStyle(.plain).accessibilityLabel("查看 AI 接入状态")
                Text(decision.level.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(decision.level == .unknown ? PocketStyle.ink.opacity(0.65) : .white)
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(decision.levelColor, in: Capsule())
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(brief.headline).font(.system(size: 23, weight: .semibold)).foregroundStyle(PocketStyle.ink).fixedSize(horizontal: false, vertical: true)
                Text(brief.body).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            // 归属信息跟着文字走：谁写的这句话，就标在这句话下面。
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "text.quote").font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(brief.source == .local ? "本地解读 · 查看依据与来源" : "AI 整理 · 事实来自本地").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup("生成详情") { Text(brief.note); if let briefNotice { Text(briefNotice) } }.font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if briefBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Button { onRefreshBrief() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(PocketStyle.green).padding(6)
                            .background(PocketStyle.green.opacity(0.12), in: Circle())
                    }.buttonStyle(.plain).accessibilityLabel("换个说法")
                }
            }
            DualRing(recovery: decision.recovery, strain: decision.strain).frame(maxWidth: .infinity)

            VStack(spacing: 0) {
                ForEach(Array(decision.actions.enumerated()), id: \.element.id) { index, action in
                    if index > 0 { Rectangle().fill(PocketStyle.rule).frame(height: 0.5) }
                    HStack(alignment: .top, spacing: 13) {
                        Image(systemName: action.icon)
                            .font(.system(size: 17))
                            .frame(width: 28, height: 28)
                            .foregroundStyle(action.lead ? PocketStyle.green : PocketStyle.ink.opacity(0.7))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(action.headline).font(.subheadline.weight(.medium)).foregroundStyle(PocketStyle.ink).fixedSize(horizontal: false, vertical: true)
                            Text(action.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 6)
                        Button { onRecord(action.eventKind) } label: {
                            Text("记录").font(.caption.weight(.medium)).foregroundStyle(PocketStyle.green)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(PocketStyle.green.opacity(0.12), in: Capsule())
                        }.buttonStyle(.plain).accessibilityLabel("记录\(action.kind.rawValue)")
                    }.padding(.vertical, 13)
                }
            }

            if let budget = decision.budget {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("能量预算").font(.caption.weight(.medium)).foregroundStyle(PocketStyle.ink)
                        Spacer()
                        Text(budget.note).font(.caption2).foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(PocketStyle.ink.opacity(0.07))
                            Capsule().fill(PocketStyle.green.opacity(0.55)).frame(width: max(0, geo.size.width * Double(budget.remaining) / 100))
                        }
                    }.frame(height: 8)
                }
            }

            if let insight = decision.insight {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "sparkles").font(.caption).foregroundStyle(PocketStyle.mint).padding(.top, 2)
                    Text(insight).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(PocketStyle.green.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }

            Button { showCaveat.toggle() } label: {
                HStack(spacing: 5) { Image(systemName: "info.circle"); Text("为什么这样建议") }.font(.caption2).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
            if showCaveat { Text(decision.caveat).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(PocketStyle.green.opacity(0.055), in: RoundedRectangle(cornerRadius: 24))
    }
}

// MARK: - 负荷页
struct PocketLoadView: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var experience: PocketExperience
    @AppStorage("sleepTarget") private var target = 8.0
    @AppStorage("dailyIntentV4") private var intent = "工作"
    @State private var selection: Date?
    @State private var effortComposer=false

    private var allPoints: [BatteryPoint] { experience.demo ? experience.demoBattery.points : health.batteryHistory }
    private var todayWorkouts: [PocketWorkout] {
        let start = Calendar.current.startOfDay(for: Date())
        let rows = experience.demo ? WorkoutAnalysis.demoWorkouts(day: start) : (health.snapshot?.workouts ?? [])
        return rows.filter { $0.end > $0.start && $0.end > start && $0.end <= Date() }
    }
    private var todayMinutes: Double {
        RecoveryEngine.merged(todayWorkouts.map { SleepInterval(start:$0.start,end:$0.end) },from:Calendar.current.startOfDay(for:Date()),to:Date()).reduce(0.0) { $0+$1.end.timeIntervalSince($1.start)/60 }
    }
    private var todayKcal: Double? {
        if experience.demo { return 420 }
        return health.snapshot?.energy.first { Calendar.current.isDate($0.date, inSameDayAs: Date()) }?.kcal
    }
    private var strain: Double? { StrainEngine.strain(kcal: todayKcal, workoutMinutes: todayMinutes) }
    private var effortEntries:[PocketEvent] { experience.visibleEvents.filter { Calendar.current.isDateInToday($0.date) && $0.date <= Date() && $0.sessionLoad != nil } }
    private var series: [LoadBarRow] {
        let calendar = Calendar.current, today = calendar.startOfDay(for: Date())
        if experience.demo {
            return (0..<28).map { offset in
                let day = calendar.date(byAdding: .day, value: -offset, to: today)!
                let wave = sin(Double(offset) * 0.7)
                return LoadBarRow(day: day, kcal: offset == 0 ? 420 : 430 + wave * 190)
            }
        }
        return (health.snapshot?.energy ?? []).map { LoadBarRow(day: calendar.startOfDay(for: $0.date), kcal: $0.kcal) }
    }
    private var acwr: LoadRatio { StrainEngine.acwr(daily: series, now: Date()) }
    private var recentSeven: [LoadBarRow] { Array(series.sorted { $0.day < $1.day }.suffix(7)) }
    private var estimate: RecoveryEstimate? {
        guard experience.demo || health.snapshot.map({ Date().timeIntervalSince($0.fetchedAt) < 21600 }) == true else { return nil }
        return experience.estimates(health, target: target).filter { $0.score != nil && Calendar.current.isDateInToday($0.date) }.last
    }
    private var lastNight: NightRecord? { experience.nights(health).filter { $0.sleepHours != nil && Calendar.current.isDateInToday($0.date) }.max { $0.date < $1.date } }
    private var decision: DailyDecision {
        DecisionEngine.make(estimate: estimate, status: experience.status(health), lastNight: lastNight, todayKcal: todayKcal,
                            strain: strain, sleepTarget: target, intent: intent, now: Date())
    }
    private var acwrColor: Color {
        guard let ratio = acwr.ratio else { return PocketStyle.ink.opacity(0.45) }
        if ratio < 0.8 { return PocketStyle.mint }
        if ratio <= 1.3 { return PocketStyle.green }
        return PocketStyle.drain
    }
    private func strainColor(_ value: Double) -> Color { value < 8 ? PocketStyle.green : value < 14 ? PocketStyle.mint : PocketStyle.drain }

    var embedded = false
    var body: some View {
        Group { if embedded { content } else { NavigationStack { content } } }
    }
    private var content: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PageHeader(title: "负荷")
                    Text("看活动能量，也回顾训练与体感。").font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
                    HStack { DemoNote(); Spacer() }.padding(.top, 6)

                    VStack(alignment: .leading, spacing: 14) {
                        HStack { Text("今日活动负荷").font(.subheadline.weight(.medium)); Spacer(); Text("活动能量代理 · 未校准").font(.caption).foregroundStyle(.secondary) }
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(strain.map { String(format: "%.1f", $0) } ?? "—").font(.system(size: 72, weight: .light)).monospacedDigit().foregroundStyle(PocketStyle.drain)
                            Text("/ 21").font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            if let strain { Text("负荷偏\(StrainEngine.zone(strain))").font(.subheadline.weight(.medium)).foregroundStyle(strainColor(strain)) }
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(PocketStyle.ink.opacity(0.07))
                                Capsule().fill(PocketStyle.drain).frame(width: max(0, geo.size.width * min(1, (strain ?? 0) / StrainEngine.ceiling)))
                            }
                        }.frame(height: 10)
                        Text(todayKcal.map { String(format: "来自今日活动能量 %.0f kcal", $0) } ?? "今天还没有活动能量记录，负荷按已有观测估计。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    .background(PocketStyle.green.opacity(0.055), in: RoundedRectangle(cornerRadius: 24))
                    .padding(.top, 16)

                    FlatRule()

                    VStack(alignment:.leading,spacing:14) {
                        Text("训练体感负荷").font(.headline)
                        if effortEntries.isEmpty {
                            Text("在训练记录中补充整次训练强度与实际时长，得到独立于热量的主观负荷。").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(effortEntries) { event in
                            HStack { Text(event.date.formatted(date:.omitted,time:.shortened));Spacer();Text(String(format:"%d × %.0f 分钟 = %.0f",event.sessionRPE!,event.trainingMinutes!,event.sessionLoad!)).foregroundStyle(PocketStyle.green) }.font(.subheadline)
                        }
                        Button("记录训练体感") { effortComposer=true }.buttonStyle(.bordered)
                        Text("强度0–10 × 时长，单位为任意负荷单位；这是手动训练记录，不与Apple健康的热量或心率负荷相加。").font(.caption2).foregroundStyle(.secondary)
                    }
                    FlatRule()
                    VStack(alignment:.leading,spacing:14) {
                        HStack { Text("训练强度与覆盖").font(.headline); Spacer();Text("实际心率").font(.caption).foregroundStyle(.secondary) }
                        if todayWorkouts.isEmpty {
                            Text("尚无已同步的 Apple 健康训练记录；手动体感记录仍保留在上方。").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(todayWorkouts) { workout in WorkoutCardioCard(workout:workout) }
                        Text("只计算相邻不超过 90 秒的心率记录；空白时段不补算。强度参考与活动能量分别展示，不重复相加，也不推断力量训练的肌肉负荷。").font(.caption2).foregroundStyle(.secondary)
                    }
                    FlatRule()
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text("训练负荷比 ACWR").font(.headline); Spacer(); Text(acwr.zone).font(.subheadline.weight(.medium)).foregroundStyle(acwrColor) }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(acwr.ratio.map { String(format: "%.2f", $0) } ?? "—").font(.system(size: 34, weight: .light)).monospacedDigit()
                            Text("最近 7 个完整日 : 28 个完整日").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(acwr.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("急性 \(Int(acwr.acute.rounded())) kcal · 慢性 \(Int(acwr.chronic.rounded())) kcal · 已记录 \(acwr.acuteDays) / \(acwr.chronicDays) 天，缺失日不计为零。")
                            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }

                    FlatRule()

                    HStack { Text("近 7 日负荷").font(.headline); Spacer(); Text("活动能量").font(.caption).foregroundStyle(.secondary) }
                    if recentSeven.contains(where: { $0.kcal != nil }) {
                        Chart(recentSeven) { row in
                            if let kcal = row.kcal {
                                BarMark(x: .value("日期", row.day, unit: .day), y: .value("活动能量", kcal)).foregroundStyle(PocketStyle.green.opacity(0.75))
                            }
                        }
                        .chartYAxis { AxisMarks(position: .leading) }
                        .chartXAxis { AxisMarks(values: .stride(by: .day)) { tick in AxisValueLabel { if let date = tick.as(Date.self) { Text(date.formatted(.dateTime.month(.defaultDigits).day())) } } } }
                        .frame(height: 160).padding(.top, 14)
                    } else {
                        Text("积累几天活动记录后，这里显示每日负荷。").font(.caption).foregroundStyle(.secondary).padding(.top, 12)
                    }

                    FlatRule()

                    if let lead = decision.actions.first {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("基于恢复 × 负荷的建议").font(.headline)
                            HStack(alignment: .top, spacing: 13) {
                                Image(systemName: lead.icon).font(.system(size: 18)).frame(width: 28, height: 28).foregroundStyle(PocketStyle.green)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(lead.headline).font(.subheadline.weight(.medium))
                                    Text(lead.reason).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            Text("恢复 \(decision.recovery.map(String.init) ?? "—") · 负荷 \(strain.map { String(format: "%.1f", $0) } ?? "—") / 21 · \(acwr.zone)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    FlatRule()

                    HStack { Text("今日电量曲线").font(.headline); Spacer(); Text("训练时段标注").font(.caption).foregroundStyle(.secondary) }
                    EnergyTimeline(points: allPoints, day: Calendar.current.startOfDay(for: Date()), workouts: todayWorkouts, selection: $selection, height: 190).padding(.top, 14)

                    FlatRule()
                    Text("负荷与负荷比基于已记录的活动能量，是实验估计，不是 Whoop 的 Strain 模型，也未个体校准。缺失日期不补零；负荷比需要足够历史才显示。")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(24).padding(.bottom, 12)
            }.safeAreaPadding(.bottom, 24).background(PocketStyle.paper).foregroundStyle(PocketStyle.ink).toolbar(embedded ? .visible : .hidden, for: .navigationBar).navigationTitle("活动负荷").navigationBarTitleDisplayMode(.inline)
                .refreshable { if experience.demo { experience.toggleDemo(true, health: health) } else { await health.refresh() } }
                .sheet(isPresented:$effortComposer) { EventComposer(defaultKind:"训练") }
    }
}

// Native page gestures remain separate from the outer vertical ScrollView.
private struct DailyPageHeightKey: PreferenceKey {
    static var defaultValue: [Date: CGFloat] = [:]
    static func reduce(value: inout [Date: CGFloat], nextValue: () -> [Date: CGFloat]) { value.merge(nextValue()) { _, next in next } }
}
private struct PocketPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
private struct DailyEnergyPage: View, Equatable {
    // Revision comes from the published snapshot/status, never from a drag frame.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.day == rhs.day && lhs.contentRevision == rhs.contentRevision &&
        lhs.status.computedAt == rhs.status.computedAt && lhs.headline == rhs.headline &&
        lhs.compact == rhs.compact && lhs.demo == rhs.demo && lhs.busy == rhs.busy
    }
    let day: Date
    let status: PocketStatus
    let points: [BatteryPoint]
    let workouts: [PocketWorkout]
    let headline: String
    let compact: Bool
    let demo: Bool
    let busy: Bool
    let refresh: () -> Void
    let contentRevision: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: Date?
    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var isFuture: Bool { day > Calendar.current.startOfDay(for: Date()) }
    private var end: Date { Calendar.current.date(byAdding: .day, value: 1, to: day)! }
    private var dayPoints: [BatteryPoint] { points.filter { point in
        let withinDay = point.belongs(to:day,end:end,instant:status.usesStateEstimate)
        return withinDay && point.date <= Date() && point.value.map { $0.isFinite && (0...100).contains($0) } == true
    } }
    private var stats: DailyBatteryStatistics {
        if status.usesStateEstimate {
            let values = dayPoints.compactMap(\.value)
            return DailyBatteryStatistics(latest: dayPoints.max { $0.date < $1.date }, minimum: values.min(), maximum: values.max(), charged: 0, drained: 0, coveredSeconds: 0)
        }
        return DailyBatteryStatistics.calculate(points: points, day: day, now: Date())
    }
    private var dayWorkouts: [PocketWorkout] { workouts.filter { $0.start < end && $0.end > day && $0.end <= Date() } }
    private func smallStat(_ label: String, _ value: String, color: Color = PocketStyle.ink) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .medium)).monospacedDigit().foregroundStyle(color)
                .contentTransition(.numericText()).animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: value)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !compact {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let value = isFuture ? nil : isToday ? status.displayValue(at: context.date) : stats.latest?.value.map { Int($0.rounded()) }
                    let observed = isToday ? status.displayDate : stats.latest?.date
                    let stale = isToday && value == nil && observed != nil
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label(status.usesStateEstimate && !isToday ? "历史状态":status.scoreMeaning.title,systemImage:status.scoreMeaning.symbol).font(.subheadline.weight(.medium))
                            Spacer()
                            NavigationLink { EstimateDetails() } label: {
                                Image(systemName: "info.circle").font(.system(size: 17)).frame(width: 44, height: 44)
                            }.foregroundStyle(.white.opacity(0.8)).accessibilityLabel("查看状态与电量的计算依据")
                        }
                        HStack(alignment: .bottom, spacing: 16) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(value.map(String.init) ?? "—").font(.system(size: 76, weight: .light, design: .rounded)).monospacedDigit()
                                    .contentTransition(.numericText(value: Double(value ?? 0)))
                                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: value)
                                if value != nil { Text("/100").font(.caption).opacity(0.8).padding(.bottom, 6) }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: status.usesStateEstimate ? "waveform.path" : "bolt.fill")
                                .font(.system(size: 34, weight: .ultraLight)).foregroundStyle(PocketStyle.mint).padding(.bottom, 16)
                                .accessibilityHidden(true)
                        }
                        Text(isFuture ? "明天的记录，明天见" : value == nil ? (stale ? "等待新的健康信号" : "这一天还没有状态记录") : status.usesStateEstimate ? (isToday ? status.scoreMeaning.headline : "当天最后状态记录") : (isToday ? headline : "当天最后电量估计"))
                            .font(.headline).fixedSize(horizontal: false, vertical: true)
                        if let value {
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.14))
                                    Capsule().fill(PocketStyle.mint).frame(width: geometry.size.width * Double(value) / 100)
                                }
                            }.frame(height: 5)
                        }
                        HStack(alignment: .top) {
                            Text(status.scoreMeaning.qualifier).font(.system(size: 10))
                            Spacer()
                            if let observed { Text((stale ? "上次 " : isToday || status.usesStateEstimate ? "观测 " : "截至 ") + observed.formatted(.dateTime.month().day()) + String(format: " %02d:%02d", Calendar.current.component(.hour, from: observed), Calendar.current.component(.minute, from: observed))).font(.system(size: 10)).multilineTextAlignment(.trailing) }
                        }.opacity(0.86)
                    }.foregroundStyle(.white).padding(20)
                        .background {
                            RoundedRectangle(cornerRadius: 28).fill(PocketStyle.green.gradient)
                                .overlay(alignment: .topTrailing) {
                                    Circle().stroke(Color.white.opacity(0.07), lineWidth: 28).frame(width: 170, height: 170).offset(x: 70, y: -60)
                                }.clipShape(RoundedRectangle(cornerRadius: 28))
                        }
                    if isToday, status.usesStateEstimate, let estimate = status.stateEstimate {
                        DisclosureGroup {
                            Text("参考范围 \(estimate.lower)–\(estimate.upper) · 未校准\n" + estimate.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                            DisclosureGroup("查看分数拆解") {StateScoreBreakdown(estimate:estimate).padding(.vertical,10)}
                            if !demo {
                                Button(busy ? "正在读取…" : "刷新健康数据", action: refresh).font(.subheadline).frame(minHeight: 44).disabled(busy)
                                Text("可在手表心率 App 测量，待同步后刷新。").font(.caption2).foregroundStyle(.secondary)
                            }
                        } label: { Label(status.evidenceLabel, systemImage: "info.circle").font(.caption) }.tint(PocketStyle.green).padding(.top, 12)
                    }
                    if stale { Text("已超过观测有效期；上次估计不作为当前状态。").font(.caption).foregroundStyle(.secondary).padding(.top, 8) }
                    if value == nil, !isFuture { NavigationLink("检查健康连接与数据") { HealthConnectionView() }.font(.subheadline).frame(minHeight: 44) }
                }
            }
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(status.usesStateEstimate ? "一天的状态" : "一天的节奏").font(.system(size: 19, weight: .semibold))
                    Spacer()
                    Text("00:00 – 24:00").font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                }
                if status.usesStateEstimate {
                    if dayPoints.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: "waveform.path").font(.title2).foregroundStyle(PocketStyle.green.opacity(0.5))
                            Text(isFuture ? "未来时段保持留白" : "没有可用的观测点").font(.subheadline)
                            Text("缺失不会记成 0；有新信号时再显示。").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
                    } else {
                        Chart(dayPoints) { point in
                            if let value = point.value { PointMark(x: .value("时间", point.date), y: .value("状态", value)).foregroundStyle(PocketStyle.green).symbolSize(32) }
                        }.chartXScale(domain: day...end).chartYScale(domain: 0...100)
                            .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { tick in
                                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
                                AxisValueLabel { if let date = tick.as(Date.self) { Text(String(format: "%02d:00", Calendar.current.component(.hour, from: date))) } }
                            } }
                            .chartYAxis { AxisMarks(position: .leading, values: [0, 50, 100]) }
                            .frame(height: 160).accessibilityLabel("当天状态观测散点图；缺失时段留空。")
                    }
                } else {
                    EnergyTimeline(points: points, day: day, workouts: dayWorkouts, selection: $selection, height: 160)
                }
                Rectangle().fill(PocketStyle.rule).frame(height: 0.5)
                HStack(spacing: 12) {
                    if status.usesStateEstimate {
                        smallStat("当天最高", stats.maximum.map { String(Int($0.rounded())) } ?? "—", color: PocketStyle.green)
                        smallStat("当天最低", stats.minimum.map { String(Int($0.rounded())) } ?? "—")
                        smallStat("观测记录", "\(dayPoints.count) 次")
                    } else {
                        smallStat("补充", stats.coveredSeconds > 0 ? String(format: "+%.1f", stats.charged) : "—", color: PocketStyle.green)
                        smallStat("消耗", stats.coveredSeconds > 0 ? String(format: "−%.1f", stats.drained) : "—", color: PocketStyle.drain)
                        smallStat("可比较", String(format: "%.1f h", stats.coveredSeconds / 3600))
                    }
                }
                Text(status.usesStateEstimate ? "每个点对应一次已有信号，不换算为电量收支。" : "轻点曲线查看区间；缺失时段不补算。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !status.usesStateEstimate {
                    NavigationLink { EnergyInsightsView(day: day) } label: {
                        HStack { Text("查看消耗时段与训练影响"); Spacer(); Image(systemName: "arrow.up.right") }.font(.subheadline.weight(.medium)).frame(minHeight: 44)
                    }
                }
            }.padding(18).background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 24))
                .overlay { RoundedRectangle(cornerRadius: 24).stroke(PocketStyle.green.opacity(0.07), lineWidth: 0.5) }
        }.padding(.horizontal, 1).padding(.bottom, 4)
    }
}

/// Reject vertical movement before recognition so the enclosing scroll view keeps its pan.
/// The marker never intercepts taps; the window recognizer is restricted to its visible bounds.
private struct CalendarHorizontalPan: UIViewRepresentable {
    var enabled: Bool
    var changed: (CGFloat) -> Void
    var ended: (CGFloat, CGFloat, Bool) -> Void
    func makeUIView(context: Context) -> Marker { Marker() }
    func updateUIView(_ view: Marker, context: Context) { view.changed = changed; view.ended = ended; view.setEnabled(enabled) }
    static func dismantleUIView(_ view: Marker, coordinator: ()) { view.detach() }
    final class Marker: UIView, UIGestureRecognizerDelegate {
        var changed: ((CGFloat) -> Void)?
        var ended: ((CGFloat, CGFloat, Bool) -> Void)?
        private weak var attachedWindow: UIWindow?
        private var touchOrigin: CGPoint?
        private lazy var pan: UIPanGestureRecognizer = {
            let gesture = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            gesture.delegate = self; gesture.cancelsTouchesInView = false; gesture.maximumNumberOfTouches = 1
            return gesture
        }()
        override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false; isAccessibilityElement = false }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard attachedWindow !== window else { return }
            detach(); window?.addGestureRecognizer(pan); attachedWindow = window
        }
        func detach() { attachedWindow?.removeGestureRecognizer(pan); attachedWindow = nil }
        func setEnabled(_ enabled: Bool) { pan.isEnabled = enabled }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let window, !isHidden, alpha > 0, !bounds.isEmpty,
                  bounds.contains(touch.location(in: self)),
                  window.bounds.contains(touch.location(in: window)),
                  window.rootViewController?.presentedViewController == nil else { return false }
            var ancestor = superview
            while let view = ancestor {
                if view.isHidden || view.alpha <= 0 { return false }
                ancestor = view.superview
            }
            touchOrigin = touch.location(in: window)
            return true
        }
        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let window, let origin = touchOrigin else { return false }
            let point = pan.location(in: window)
            return abs(point.x - origin.x) > abs(point.y - origin.y) * 1.3
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        @objc private func handle(_ gesture: UIPanGestureRecognizer) {
            guard let window, let origin = touchOrigin else { return }
            let dx = gesture.location(in: window).x - origin.x
            switch gesture.state {
            case .began, .changed: changed?(dx)
            case .ended: ended?(dx, dx + gesture.velocity(in: self).x * 0.15, false)
            case .cancelled, .failed: ended?(0, 0, true)
            default: break
            }
        }
    }
}

/// Drag offsets are local to this small view. Moving a finger must not invalidate
/// the calendar, recovery model, coach evidence, and every section of the home.
private struct DailyEnergyPager: View {
    @Binding var day: Date
    let status: PocketStatus
    let points: [BatteryPoint]
    let headline: String
    let workouts: [PocketWorkout]
    let demo: Bool
    let busy: Bool
    let compact: Bool
    let calendarDays: [Date]
    let revision: Date
    let refresh: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pageHeights: [Date: CGFloat] = [:]
    @State private var pagingOffset: CGFloat = 0
    @State private var pagerActive = false
    @State private var pagingToken: UUID?
    private var dateMotion: Animation? { reduceMotion ? nil : .spring(duration: 0.42, bounce: 0.08) }
    private func selectDay(_ date: Date) { day = Calendar.current.startOfDay(for: date) }
    var body: some View {
        let adjacent = [-1, 0, 1].compactMap { Calendar.current.date(byAdding: .day, value: $0, to: day) }
        return GeometryReader { geometry in
            HStack(alignment: .top, spacing: 0) {
                ForEach(adjacent, id: \.self) { date in
                    DailyEnergyPage(day: date, status: status, points: points,
                                    workouts: demo ? WorkoutAnalysis.demoWorkouts(day: date) : workouts,
                                    headline: headline, compact: compact, demo: demo, busy: busy,
                                    refresh: refresh, contentRevision: revision).equatable()
                        .fixedSize(horizontal: false, vertical: true)
                        .background { GeometryReader { measured in Color.clear.preference(key: DailyPageHeightKey.self, value: [date: measured.size.height]) } }
                        .frame(width: geometry.size.width, alignment: .topLeading)
                        .accessibilityHidden(date != day)
                }
            }.frame(width: geometry.size.width * 3, alignment: .topLeading)
                .offset(x: -geometry.size.width + pagingOffset)
                .frame(width: geometry.size.width, alignment: .topLeading).clipped()
                .contentShape(Rectangle())
                .background {
                    CalendarHorizontalPan(enabled: pagerActive, changed: { dx in
                        guard pagingToken == nil else { return }
                        let offset = max(-geometry.size.width, min(geometry.size.width, dx))
                        let next = Calendar.current.date(byAdding: .day, value: offset > 0 ? -1 : 1, to: day)!
                        pagingOffset = reduceMotion ? 0 : calendarDays.contains(next) ? offset : offset * 0.12
                    }, ended: { dx, projected, cancelled in
                        finishPageDrag(dx: cancelled ? 0 : dx, projected: cancelled ? 0 : projected, width: geometry.size.width)
                    })
                }
        }.frame(height: pageHeights[day] ?? 580).clipped()
            .onPreferenceChange(DailyPageHeightKey.self) { measured in
                let changed = measured.filter { abs((pageHeights[$0.key] ?? 0) - $0.value) > 0.5 }
                if !changed.isEmpty { pageHeights.merge(changed) { _, new in new } }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: pageHeights[day])
            .onChange(of: day) { _, _ in
                pagingToken = nil
                var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
                withTransaction(transaction) { pagingOffset = 0 }
            }
            .onAppear { pagerActive = true }
            .onDisappear { pagerActive = false; pagingToken = nil; pagingOffset = 0 }
            .accessibilityIdentifier("daily-energy-pager")
    }
    private func finishPageDrag(dx: CGFloat, projected: CGFloat, width: CGFloat) {
        guard pagingToken == nil else { return }
        let enough = abs(dx) > width * 0.22 || abs(projected) > width * 0.42
        guard enough,
              let next = Calendar.current.date(byAdding: .day, value: dx > 0 ? -1 : 1, to: day), calendarDays.contains(next) else {
            if pagingOffset != 0 { withAnimation(dateMotion) { pagingOffset = 0 } }
            return
        }
        if reduceMotion { selectDay(next); return }
        let token = UUID(), original = day
        pagingToken = token
        withAnimation(.easeOut(duration: 0.22), completionCriteria: .logicallyComplete) {
            pagingOffset = dx > 0 ? width : -width
        } completion: {
            guard pagingToken == token, day == original else { return }
            var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
            withTransaction(transaction) { day = next; pagingOffset = 0; pagingToken = nil }
        }
    }

}

#if targetEnvironment(simulator)
/// RAM-only clock-independent coverage fixture for the isolated QA simulator.
private enum ShadowCoverageFixture {
    static func make(now:Date=Date())->ShadowReplay? {
        let end=now.addingTimeInterval(-60),start=end.addingTimeInterval(-3*3600)
        let rows=(0..<3).map { index -> BatteryHour in
            let lower=start.addingTimeInterval(Double(index)*3600),upper=lower.addingTimeInterval(3600)
            let training=index==1 ? 0.5:1.0,minutes=index==2 ? 30:Int(training*60)
            let samples=(0...minutes).map{WorkoutHeartSample(date:lower.addingTimeInterval(Double($0)*60),bpm:160,source:"synthetic-coverage-watch")}
            let spans=WorkoutHeartFallback.make(samples:samples,windows:[(lower,lower.addingTimeInterval(training*3600))],start:lower,end:upper,now:now,reference:60,source:"synthetic-coverage-watch")
            return BatteryHour(start:lower,end:upper,sleepHours:0,activeKcal:350*training,heartRate:160,heartRateCount:minutes+1,heartRateCoverageHours:Double(minutes)/60,workoutHours:training,personalHR:60,awakeHeartRate:160,awakeHeartRateCount:minutes+1,awakeHeartRateCoverageHours:Double(minutes)/60,workoutHeartSpans:spans)
        }
        let origin=BatteryOrigin(bucketStart:start,date:start,value:80,uncertainty:30,reason:"合成覆盖验收起点")
        let ledger=BatteryLedger(baselineHR:60,hours:rows,sourceKey:"synthetic-coverage-watch",continuousVersion:1,continuousOrigins:[origin])
        var replay=ShadowReplayEngine.replay(ledger:ledger,inputDigest:String(repeating:"c",count:64),now:now)
        replay?.baseline.demo=true;replay?.candidate.demo=true
        return replay
    }
}
#endif
