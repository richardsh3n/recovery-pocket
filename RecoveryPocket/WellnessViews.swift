import SwiftUI
import Charts

struct WellnessData {
    var nights: [NightRecord]
    var energy: [LoadBarRow]
    var workouts: [PocketWorkout]
    var feelings: [WellnessCheckIn]
    var intervals: [SleepInterval]
    func week(ending: Date, now: Date = Date()) -> WellnessWeek { WellnessEngine.week(nights:nights,energy:energy,workouts:workouts,feelings:feelings,ending:ending,now:now) }
}
extension PocketExperience {
    func wellnessData(_ health: HealthStore, now: Date = Date()) -> WellnessData {
        let calendar = Calendar.current, today = calendar.startOfDay(for:now), nights = nights(health)
        let energy: [LoadBarRow] = demo ? (0..<42).map { offset in LoadBarRow(day:calendar.date(byAdding:.day,value:-offset,to:today)!,kcal:offset == 0 ? 420 : 430+sin(Double(offset)*0.7)*190) } : (health.snapshot?.energy ?? []).map { LoadBarRow(day:$0.date,kcal:$0.kcal) }
        let workouts: [PocketWorkout] = demo ? (0..<14).flatMap { offset -> [PocketWorkout] in
            let day = calendar.date(byAdding:.day,value:-offset,to:today)!
            // Synthetic sessions have stable, unique IDs across calendar days.
            return WorkoutAnalysis.demoWorkouts(day:day).map { original in var row = original; row.id = UUID(uuidString:String(format:"22222222-0000-0000-0000-%012lld",Int64(row.start.timeIntervalSince1970)))!; return row }
        } : health.snapshot?.workouts ?? []
        let intervals: [SleepInterval] = demo ? nights.compactMap { night in
            guard let hours = night.sleepHours else { return nil }
            let end = calendar.date(bySettingHour:7,minute:45,second:0,of:night.date)!
            return end <= now ? SleepInterval(start:end.addingTimeInterval(-hours*3600),end:end) : nil
        } : health.snapshot?.sleepIntervals ?? []
        return WellnessData(nights:nights,energy:energy,workouts:workouts,feelings:visibleEvents.filter { $0.kind == "自评" }.map { WellnessCheckIn(date:$0.date,energy:$0.energy) },intervals:intervals)
    }
}
private func wellnessValue(_ value: Double?, suffix: String = "") -> String { value.map { String(format:"%.1f",$0)+suffix } ?? "—" }
private func wellnessClock(_ minutes: Int) -> String { let m = (minutes%1440+1440)%1440; return String(format:"%02d:%02d",m/60,m%60) }
private func wellnessTitle(_ title: String, _ subtitle: String) -> some View { VStack(alignment:.leading,spacing:7) { Text(title).font(.title3.weight(.semibold)); Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) } }
private struct WellnessCard: View {
    var title: String; var subtitle: String; var icon: String
    var body: some View { HStack(spacing:16) { Image(systemName:icon).font(.title2).frame(width:42,height:42).background(PocketStyle.green.opacity(0.08),in:RoundedRectangle(cornerRadius:12)); VStack(alignment:.leading,spacing:5) { Text(title).font(.headline); Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }; Spacer(minLength:4); Image(systemName:"chevron.right").font(.caption) }.foregroundStyle(PocketStyle.ink).padding(18).frame(maxWidth:.infinity,alignment:.leading).background(PocketStyle.green.opacity(0.04),in:RoundedRectangle(cornerRadius:20)) }
}
struct WellnessHub: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var experience: PocketExperience
    @AppStorage("sleepTarget") private var target = 8.0
    private var data: WellnessData { experience.wellnessData(health) }
    private var week: WellnessWeek { data.week(ending:Date()) }
    private var energy: EnergyDayReport { EnergyInsights.day(points:experience.demo ? experience.demoBattery.points : health.batteryHistory,day:Date(),now:Date()) }
    var body: some View {
        NavigationStack { ScrollView { VStack(alignment:.leading,spacing:22) {
            PageHeader(title:"洞察"); DemoNote()
            NavigationLink { EnergyBudgetView() } label: { WellnessCard(title:"能量收支",subtitle:"每日消耗、摄入与参考热量差",icon:"flame") }.buttonStyle(.plain)
            VStack(alignment:.leading,spacing:14) {
                Text("今天，哪段最值得回看？").font(.title3.weight(.semibold))
                if let peak = energy.peak {
                    HStack(alignment:.firstTextBaseline) { Text(peak.start.formatted(.dateTime.hour().minute())+" – "+peak.end.formatted(.dateTime.hour().minute())).font(.title2.weight(.medium)); Spacer(); Text(String(format:"−%.1f",-peak.delta)).font(.system(size:32,weight:.light)).foregroundStyle(PocketStyle.drain) }
                    Text(peak.mode+" · 对应区间的模型净消耗").font(.caption).foregroundStyle(.secondary)
                } else { Text("还没有可比较的下降区间。记录同步后，这里会提示值得回看的时段。").font(.subheadline).foregroundStyle(.secondary) }
                Chart(energy.hours.filter { $0.rate != nil }) { row in
                    if let rate = row.rate { BarMark(x:.value("时段",row.start,unit:.hour),y:.value("变化速率",rate)).foregroundStyle(rate >= 0 ? PocketStyle.green : PocketStyle.drain).cornerRadius(3) }
                }.chartXScale(domain:energy.day...Calendar.current.date(byAdding:.day,value:1,to:energy.day)!).chartXAxis { AxisMarks(values:.stride(by:.hour,count:6)) { AxisValueLabel(format:.dateTime.hour()) } }.frame(height:110)
                NavigationLink { EnergyInsightsView(day:energy.day) } label: { Label("回看曲线与计算账本",systemImage:"arrow.up.right").font(.subheadline).frame(minHeight:44) }
                Text(String(format:"%.1f 小时有可比较曲线 · 缺失时段留空",energy.coveredSeconds/3600)).font(.caption2).foregroundStyle(.secondary)
            }.padding(20).background(PocketStyle.green.opacity(0.055),in:RoundedRectangle(cornerRadius:22))
            if !experience.demo {
                NavigationLink { HealthConnectionView() } label: {
                    Label(health.snapshot == nil ? "连接健康数据，开始回顾" : "健康读取与数据来源",systemImage:"heart.text.square").font(.subheadline).frame(minHeight:44)
                }
                if let fetchedAt = health.snapshot?.fetchedAt { Text("最近读取 " + fetchedAt.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary) }
            }
            VStack(alignment:.leading,spacing:18) {
                HStack { Text("这一周的轮廓").font(.headline); Spacer(); Text("近七天").font(.caption).foregroundStyle(.secondary) }
                HStack(alignment:.top) { metric("平均睡眠",wellnessValue(week.meanSleep,suffix:"h")); Spacer(); metric("目标缺口",wellnessValue(week.sleepGap(target:target),suffix:"h")); Spacer(); metric("平均自评",wellnessValue(week.meanFeeling)) }
                Chart {
                    ForEach(week.days) { row in if let sleep = row.sleep { BarMark(x:.value("日期",row.date,unit:.day),y:.value("睡眠小时",sleep)).foregroundStyle(PocketStyle.mint).cornerRadius(3) } }
                    RuleMark(y:.value("目标",WellnessEngine.target(target))).foregroundStyle(PocketStyle.drain.opacity(0.5)).lineStyle(StrokeStyle(lineWidth:1,dash:[3,4]))
                }.chartYScale(domain:0...max(12,(week.days.compactMap(\.sleep).max() ?? 0)+1)).chartXAxis { AxisMarks(values:.stride(by:.day)) { AxisValueLabel(format:.dateTime.day()) } }.frame(height:95)
                Text("睡眠 \(week.sleepDays) / 7 天 · 自评 \(week.days.compactMap(\.feeling).count) / 7 天有记录").font(.caption).foregroundStyle(.secondary)
            }.padding(20).background(PocketStyle.green.opacity(0.055),in:RoundedRectangle(cornerRadius:22))
            NavigationLink { IntegratedHubView() } label: { WellnessCard(title:"健康工作台",subtitle:"个人验证、训练档案、计划、餐次与备份",icon:"square.grid.2x2") }.buttonStyle(.plain)
            NavigationLink { FeedbackReviewView() } label: { WellnessCard(title:"状态与体感对照",subtitle:"保留当时的预测，回看哪些情况值得复核",icon:"checkmark.bubble") }.buttonStyle(.plain)
            NavigationLink { WeeklyReviewView() } label: { WellnessCard(title:"每周回顾",subtitle:"与前一周比较睡眠、活动和精力",icon:"chart.bar.xaxis") }.buttonStyle(.plain)
            NavigationLink { SleepPlanningView() } label: { WellnessCard(title:"睡眠计划",subtitle:"目标缺口、记录规律与今晚时间安排",icon:"moon.stars") }.buttonStyle(.plain)
            NavigationLink { TrainingRecoveryView() } label: { WellnessCard(title:"训练后的恢复",subtitle:"把训练、次夜记录与自评放在一起",icon:"figure.run") }.buttonStyle(.plain)
            NavigationLink { PersonalGoalsView() } label: { WellnessCard(title:"个人目标",subtitle:"用记录追踪进度，休息也有价值",icon:"flag.checkered") }.buttonStyle(.plain)
            NavigationLink { EnergyInsightsView(day:Calendar.current.startOfDay(for:Date())) } label: { WellnessCard(title:"电量节奏地图",subtitle:"按小时回看补充、消耗与训练区间",icon:"square.grid.3x3") }.buttonStyle(.plain)
            NavigationLink { PocketLoadView(embedded:true) } label: { WellnessCard(title:"活动负荷",subtitle:"已记录活动能量与完整历史日期对照",icon:"bolt.heart") }.buttonStyle(.plain)
            NavigationLink { PocketTrends(embedded:true) } label: { WellnessCard(title:"指标趋势",subtitle:"7 / 30 天恢复、睡眠、HRV 与自评",icon:"waveform.path.ecg") }.buttonStyle(.plain)
            Text("每项比较只使用已有记录，缺失会留空。这里的目标缺口以你设定的睡眠时长为准，不推测生理睡眠需求。").font(.caption).foregroundStyle(.secondary)
        }.padding(24) }.safeAreaPadding(.bottom,24).background(PocketStyle.paper).foregroundStyle(PocketStyle.ink).toolbar(.hidden,for:.navigationBar) }
    }
    private func metric(_ title:String,_ value:String) -> some View { VStack(alignment:.leading,spacing:8) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(size:27,weight:.light)).monospacedDigit().foregroundStyle(PocketStyle.green) } }
}
struct WeeklyReviewView: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var experience: PocketExperience
    @AppStorage("sleepTarget") private var target = 8.0
    @State private var day = Calendar.current.startOfDay(for:Date())
    private var data: WellnessData { experience.wellnessData(health) }
    private var week: WellnessWeek { data.week(ending:day) }
    private var previous: WellnessWeek { data.week(ending:Calendar.current.date(byAdding:.day,value:-7,to:day)!) }
    private func completedEnergy(_ week: WellnessWeek) -> [Double] { week.days.filter { $0.date < Calendar.current.startOfDay(for:Date()) }.compactMap(\.kcal) }
    var body: some View {
        let week = self.week
        let previous = self.previous
        ScrollView { VStack(alignment:.leading,spacing:24) {
            DemoNote(); DatePicker("回顾截至",selection:$day,in:...Date(),displayedComponents:.date)
            wellnessTitle("这一周，发生了什么", "\(week.days.first!.date.formatted(.dateTime.month().day())) – \(day.formatted(.dateTime.month().day())) · 可选择历史日期")
            weeklyReading(week)
            comparison("平均睡眠",current:week.meanSleep,old:previous.meanSleep,unit:"小时",currentCount:week.sleepDays,oldCount:previous.sleepDays)
            comparison("睡眠 SDNN",current:week.meanHRV,old:previous.meanHRV,unit:"ms",currentCount:week.days.compactMap(\.hrv).count,oldCount:previous.days.compactMap(\.hrv).count)
            comparison("已完成日期活动能量",current:WellnessEngine.mean(completedEnergy(week)),old:WellnessEngine.mean(completedEnergy(previous)),unit:"kcal / 天",currentCount:completedEnergy(week).count,oldCount:completedEnergy(previous).count)
            comparison("主观精力",current:week.meanFeeling,old:previous.meanFeeling,unit:"/ 5",currentCount:week.days.compactMap(\.feeling).count,oldCount:previous.days.compactMap(\.feeling).count)
            wellnessTitle("七天睡眠与目标", "目标 \(wellnessValue(target,suffix:" 小时")) · 未记录日期留空")
            Chart {
                ForEach(week.days) { row in if let sleep = row.sleep { BarMark(x:.value("日期",row.date,unit:.day),y:.value("已记录睡眠",sleep)).foregroundStyle(sleep >= target ? PocketStyle.green : PocketStyle.mint).cornerRadius(4) } }
                RuleMark(y:.value("个人目标",WellnessEngine.target(target))).foregroundStyle(PocketStyle.drain.opacity(0.5)).lineStyle(StrokeStyle(lineWidth:1,dash:[4,4]))
            }.chartXScale(domain:week.days.first!.date...Calendar.current.date(byAdding:.day,value:1,to:day)!).chartYScale(domain:0...max(12,(week.days.compactMap(\.sleep).max() ?? 0)+1)).chartXAxis { AxisMarks(values:.stride(by:.day)) { AxisValueLabel(format:.dateTime.day()) } }.frame(height:190)
            HStack { Text("已记录目标缺口"); Spacer(); Text(wellnessValue(week.sleepGap(target:target),suffix:" 小时")).foregroundStyle(PocketStyle.drain) }.font(.subheadline)
            wellnessTitle("每天的记录", "训练分钟按已完成训练的起止跨度统计，重叠时间不重复累计")
            ForEach(week.days) { row in NavigationLink { EnergyInsightsView(day:row.date) } label: {
                HStack(alignment:.top) { Text(row.date.formatted(.dateTime.month().day())).frame(width:54,alignment:.leading); VStack(alignment:.leading,spacing:5) { Text("睡眠 " + wellnessValue(row.sleep,suffix:"h") + " · 自评 " + wellnessValue(row.feeling)); Text("训练 " + wellnessValue(row.trainingMinutes,suffix:" 分钟") + " · 活动 " + wellnessValue(row.kcal,suffix:" kcal")).font(.caption).foregroundStyle(.secondary) }; Spacer(minLength:0); Image(systemName:"chevron.right").font(.caption) }.font(.subheadline).foregroundStyle(PocketStyle.ink).padding(.vertical,8)
            }.buttonStyle(.plain); Divider() }
            Text("前后周均值只使用有记录的日期。样本不足 3 天时不标趋势方向；日期构成、训练和采样变化都会影响比较，变化不证明某个习惯的作用。").font(.caption).foregroundStyle(.secondary)
        }.padding(24) }.safeAreaPadding(.bottom,24).background(PocketStyle.paper).foregroundStyle(PocketStyle.ink).navigationTitle("每周回顾").navigationBarTitleDisplayMode(.inline)
    }
    private func weeklyReading(_ week: WellnessWeek) -> some View {
        let recordedSleep = week.sleepDays
        let metGoal = week.reachedSleep(target: target)
        let feelingDays = week.days.compactMap(\.feeling).count
        let today = Calendar.current.startOfDay(for: Date())
        let recordedActivity = week.days.filter { $0.date < today && $0.kcal != nil }
        let busiest = recordedActivity.filter { ($0.kcal ?? 0) > 0 }.max { ($0.kcal ?? 0) < ($1.kcal ?? 0) }
        return VStack(alignment: .leading, spacing: 14) {
            Text("从三件事回看").font(.headline)
            NavigationLink { SleepPlanningView() } label: {
                WellnessCard(
                    title: "睡眠与自己的目标",
                    subtitle: recordedSleep == 0
                        ? "这周还没有睡眠记录。睡眠计划可先设置起床时间和目标。"
                        : "有记录的 \(recordedSleep) 夜中，\(metGoal) 夜达到你的目标。打开睡眠计划，查看近期睡眠片段的起止时间。",
                    icon: "moon.stars"
                )
            }.buttonStyle(.plain)
            if let busiest, let kcal = busiest.kcal {
                NavigationLink { EnergyInsightsView(day: busiest.date) } label: {
                    WellnessCard(
                        title: "活动最多的已记录日期",
                        subtitle: busiest.date.formatted(.dateTime.month().day()) + " · " + String(format: "%.0f kcal", kcal) + " · 在 \(recordedActivity.count) 个已完成且有活动能量记录的日期里最高。回看当天的训练和电量。",
                        icon: "figure.run"
                    )
                }.buttonStyle(.plain)
            } else {
                Text(recordedActivity.isEmpty
                     ? "这周还没有已完成日期的活动能量记录。"
                     : "有记录的已完成日期都显示 0 kcal 活动能量。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            NavigationLink { FeedbackReviewView() } label: {
                WellnessCard(
                    title: "精力有没有跟上",
                    subtitle: feelingDays == 0
                        ? "这周没有精力自评。下次选一个方便坚持的时段记录，之后可在体感对照回看。"
                        : "这周有 \(feelingDays) 天留下精力自评。打开近期体感对照，找出分数和感受不一致的时段。",
                    icon: "checkmark.bubble"
                )
            }.buttonStyle(.plain)
        }
    }
    private func comparison(_ title:String,current:Double?,old:Double?,unit:String,currentCount:Int,oldCount:Int) -> some View {
        VStack(alignment:.leading,spacing:10) { HStack { Text(title).font(.subheadline); Spacer(); Text("\(currentCount) / 7 天").font(.caption).foregroundStyle(.secondary) }; HStack(alignment:.firstTextBaseline) { Text(wellnessValue(current,suffix:" "+unit)).font(.system(size:31,weight:.light)).foregroundStyle(PocketStyle.green); Spacer(); if let current,let old,currentCount >= 3,oldCount >= 3 { Text(String(format:"%+.1f",current-old)+" "+unit).font(.subheadline).monospacedDigit() } else { Text("对照记录不足").font(.caption).foregroundStyle(.secondary) } }; Text("前一周 " + wellnessValue(old,suffix:" "+unit) + " · \(oldCount) / 7 天有记录").font(.caption).foregroundStyle(.secondary) }.padding(18).background(PocketStyle.green.opacity(0.04),in:RoundedRectangle(cornerRadius:18))
    }
}
struct SleepPlanningView: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var experience: PocketExperience
    @AppStorage("sleepTarget") private var target = 8.0
    @AppStorage("plannedWakeMinutes") private var wake = 450
    @AppStorage("sleepPreparationMinutes") private var preparation = 30
    private var data: WellnessData { experience.wellnessData(health) }
    private var week: WellnessWeek { data.week(ending:Date()) }
    private var timing: [SleepTiming] { WellnessEngine.timing(intervals:data.intervals,ending:Date(),now:Date()) }
    private var bedtime: Int { wake-Int((WellnessEngine.target(target)*60).rounded()) }
    private var wakeDate: Binding<Date> { Binding(get:{ Calendar.current.startOfDay(for:Date()).addingTimeInterval(Double(wake)*60) },set:{ wake = Calendar.current.component(.hour,from:$0)*60+Calendar.current.component(.minute,from:$0) }) }
    var body: some View {
        ScrollView { VStack(alignment:.leading,spacing:24) {
            DemoNote(); wellnessTitle("给今晚留一个时间窗口", "根据你设定的起床时间与睡眠目标安排；不推测实际入睡时长")
            HStack { Text("睡眠目标"); Spacer(); Text(wellnessValue(target,suffix:" 小时")).foregroundStyle(PocketStyle.green) }.font(.subheadline)
            Slider(value:$target,in:4...12,step:0.25).accessibilityLabel("个人睡眠目标")
            DatePicker("计划起床",selection:wakeDate,displayedComponents:.hourAndMinute)
            Stepper("睡前准备 \(preparation) 分钟",value:$preparation,in:0...90,step:5)
            VStack(alignment:.leading,spacing:18) { planRow("开始睡前准备",wellnessClock(bedtime-preparation),"moon"); Divider(); planRow("计划睡眠窗口开始",wellnessClock(bedtime),"bed.double"); Divider(); planRow("计划起床",wellnessClock(wake),"sun.max") }.padding(20).background(PocketStyle.green.opacity(0.055),in:RoundedRectangle(cornerRadius:22))
            Text("这是时间安排工具；准备时间不算作睡眠，不设后台闹钟。目标用于记录对照，可以按自己的需要调整。").font(.caption).foregroundStyle(.secondary)
            wellnessTitle("已记录的目标缺口", "近七夜 \(week.sleepDays) / 7 夜有记录 · 超额睡眠不抵消其他夜的缺口")
            Text(wellnessValue(week.sleepGap(target:target),suffix:" 小时")).font(.system(size:44,weight:.light)).foregroundStyle(PocketStyle.drain)
            Text("这是已记录睡眠与个人目标的差值累计，不是 Oura 式生理睡眠债估计。").font(.caption).foregroundStyle(.secondary)
            wellnessTitle("睡眠记录的规律", "浅绿条为主要睡眠片段的起止跨度；可能包含片段之间的清醒时间")
            if !timing.isEmpty {
                Chart(timing) { row in BarMark(xStart:.value("开始",row.start.timeIntervalSince(row.date)/3600),xEnd:.value("结束",row.end.timeIntervalSince(row.date)/3600),y:.value("日期",row.date.formatted(.dateTime.month().day()))).foregroundStyle(PocketStyle.green.opacity(0.5)).cornerRadius(4) }.chartXScale(domain:-24...24).chartXAxis { AxisMarks(values:[-24,-12,0,12,24]) { tick in AxisValueLabel { if let hour = tick.as(Int.self) { Text(String(format:"%02d:00",(hour+24)%24)) } } } }.frame(height:max(110,CGFloat(timing.count)*30))
                if let variation = WellnessEngine.timingVariation(timing) { Text("开始时间波动约 \(Int(variation.rounded())) 分钟 · \(timing.count) 夜有可用起止记录").font(.subheadline) } else { Text("已有 \(timing.count) 夜起止记录；至少 3 夜后展示时间波动。").font(.caption).foregroundStyle(.secondary) }
                ForEach(timing) { row in HStack { Text(row.date.formatted(.dateTime.month().day())); Spacer(); Text(row.start.formatted(.dateTime.hour().minute()) + " → " + row.end.formatted(.dateTime.hour().minute())); Text(wellnessValue(row.asleepHours,suffix:"h")).foregroundStyle(.secondary) }.font(.caption).monospacedDigit() }
            } else { Text("缓存还没有睡眠起止记录。刷新健康数据后显示；旧版时长记录仍可用于目标缺口统计。").font(.subheadline).foregroundStyle(.secondary) }
        }.padding(24) }.safeAreaPadding(.bottom,24).background(PocketStyle.paper).foregroundStyle(PocketStyle.ink).navigationTitle("睡眠计划").navigationBarTitleDisplayMode(.inline)
    }
    private func planRow(_ title:String,_ value:String,_ icon:String) -> some View { HStack { Image(systemName:icon).frame(width:24); Text(title).font(.subheadline); Spacer(); Text(value).font(.title2).monospacedDigit().foregroundStyle(PocketStyle.green) } }
}
struct TrainingRecoveryView: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var experience: PocketExperience
    @State private var composer = false
    private var data: WellnessData { experience.wellnessData(health) }
    private var batteryPoints: [BatteryPoint] { experience.demo ? experience.demoBattery.points : health.batteryHistory }
    private var rows: [TrainingFollowUp] { Array(WellnessEngine.followUps(workouts:data.workouts,nights:data.nights,feelings:data.feelings,now:Date()).prefix(12)) }
    var body: some View {
        ScrollView { VStack(alignment:.leading,spacing:24) {
            DemoNote(); wellnessTitle("训练结束，回顾才开始", "最近 12 次已完成训练 · 看当天区间、次夜睡眠与后续自评")
            if rows.isEmpty { Text("没有读到已完成训练。已有训练同步到 Apple 健康后会显示在这里。").foregroundStyle(.secondary) }
            ForEach(rows) { row in VStack(alignment:.leading,spacing:16) {
                HStack { Image(systemName:workoutIcon(row.workout.title)).font(.title2).accessibilityHidden(true); VStack(alignment:.leading,spacing:5) { Text(row.workout.title).font(.headline); Text(row.workout.start.formatted(.dateTime.month().day().hour().minute())).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text("\(Int((row.workout.duration/60).rounded())) 分钟").font(.subheadline) }
                if let comparison = EnergyInsights.workouts([row.workout],points:batteryPoints,day:row.workout.start,now:Date()).first {
                    HStack { Text("附近模型参考").font(.caption).foregroundStyle(.secondary); Spacer(); Text(comparison.before?.value.map { String(Int($0.rounded())) } ?? "—"); Image(systemName:"arrow.right").font(.caption); Text(comparison.after?.value.map { String(Int($0.rounded())) } ?? "—") }.font(.subheadline).monospacedDigit()
                    HStack { Text("训练时段分配的净消耗").font(.caption); Spacer(); Text(comparison.impact.coveredSeconds > 0 ? String(format:"≈ −%.1f 点",comparison.impact.drop) : "无可比较区间").font(.subheadline).monospacedDigit().foregroundStyle(PocketStyle.drain) }
                    Text(String(format:"训练时段 %.0f%% 有曲线。前后参考取一小时内最近记录；消耗按训练重叠时间分配，两者口径不同。",comparison.coverage*100)).font(.caption2).foregroundStyle(.secondary)
                }
                HStack(alignment:.top) { followMetric("次夜睡眠",wellnessValue(row.nextNight?.sleepHours,suffix:"h")); Spacer(); followMetric("次夜 SDNN",wellnessValue(WellnessEngine.validHRV(row.nextNight),suffix:"ms")); Spacer(); followMetric("训练后自评",row.feeling.map { "\($0.energy) / 5" } ?? "—") }
                if let diff = row.hrvDifference { Text(String(format:"SDNN 较此前 %d 个日期的中位数 %+.1f ms",row.baselineDays,diff)).font(.caption).foregroundStyle(.secondary) } else { Text("次夜或个人 SDNN 对照不足，暂不解释差值。").font(.caption).foregroundStyle(.secondary) }
                if let feeling = row.feeling { Text("自评记录于 " + feeling.date.formatted(date:.abbreviated,time:.shortened)).font(.caption2).foregroundStyle(.secondary) }
                NavigationLink { EnergyInsightsView(day:Calendar.current.startOfDay(for:row.workout.start)) } label: { Label("回看当天电量区间",systemImage:"chart.xyaxis.line").font(.subheadline).frame(minHeight:44) }
            }.padding(20).background(PocketStyle.green.opacity(0.045),in:RoundedRectangle(cornerRadius:20)) }
            Button { composer = true } label: { Label("记录现在的精力",systemImage:"plus").frame(maxWidth:.infinity,minHeight:44) }.buttonStyle(.bordered)
            Text("训练后自评取结束后六小时内第一条记录；有起止时间时关联训练后48小时内开始的首段主要睡眠；旧记录按下一日期保守匹配。多次训练可能对应同一夜，不能累加成多个恢复样本。对照只描述同时出现的记录，不证明训练造成 SDNN 或睡眠变化。").font(.caption).foregroundStyle(.secondary)
        }.padding(24) }.safeAreaPadding(.bottom,24).background(PocketStyle.paper).foregroundStyle(PocketStyle.ink).navigationTitle("训练后的恢复").navigationBarTitleDisplayMode(.inline).sheet(isPresented:$composer) { EventComposer(defaultKind:"自评") }
    }
    private func followMetric(_ title:String,_ value:String) -> some View { VStack(alignment:.leading,spacing:7) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(size:23,weight:.light)).monospacedDigit().foregroundStyle(PocketStyle.green) } }
    private func workoutIcon(_ title: String) -> String {
        if title.contains("步行") { return "figure.walk" }
        if title.contains("力量") { return "dumbbell" }
        if title.contains("骑") { return "figure.outdoor.cycle" }
        if title.contains("泳") { return "figure.pool.swim" }
        if title.contains("瑜伽") { return "figure.yoga" }
        return title.contains("跑") ? "figure.run" : "figure.mixed.cardio"
    }
}
struct PersonalGoalsView: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var experience: PocketExperience
    @AppStorage("sleepTarget") private var target = 8.0
    @AppStorage("goalSleepNights") private var sleepNights = 4
    @AppStorage("goalCheckInDays") private var checkDays = 5
    @AppStorage("goalRestDays") private var restDays = 3
    @State private var composer = false
    private var weekStart: Date { let c = Calendar.current; let today = c.startOfDay(for:Date()); let weekday = c.component(.weekday,from:today); return c.date(byAdding:.day,value:-(weekday+5)%7,to:today)! }
    private var daysSoFar: Int { Calendar.current.dateComponents([.day],from:weekStart,to:Calendar.current.startOfDay(for:Date())).day!+1 }
    private var data: WellnessData { experience.wellnessData(health) }
    private var nights: [NightRecord] { WellnessEngine.nights(data.nights,now:Date()).filter { $0.date >= weekStart } }
    private var checks: Int { Set(data.feelings.filter { $0.date >= weekStart && $0.date <= Date() && (1...5).contains($0.energy) }.map { Calendar.current.startOfDay(for:$0.date) }).count }
    private var rests: Int { Set(experience.visibleEvents.filter { $0.kind == "休息" && $0.date >= weekStart && $0.date <= Date() }.map { Calendar.current.startOfDay(for:$0.date) }).count }
    var body: some View {
        ScrollView { VStack(alignment:.leading,spacing:24) {
            DemoNote(); wellnessTitle("给本周一个温和的目标", "周一至周日 · 已经过 \(daysSoFar) 天 · 记录进度不改写电量")
            goal("睡眠达到个人目标",achieved:nights.filter { WellnessEngine.validSleep($0.sleepHours).map { $0 >= WellnessEngine.target(target) } == true }.count,total:$sleepNights,subtitle:"当前目标 \(wellnessValue(target,suffix:" 小时")) · \(nights.compactMap(\.sleepHours).count) 夜有记录")
            goal("记录自己的精力",achieved:checks,total:$checkDays,subtitle:"一天多条自评只计一次，没记录的日期保持未知")
            goal("给自己留短休息",achieved:rests,total:$restDays,subtitle:"仅统计你主动保存的休息记录，不推测是否真正休息")
            Button { composer = true } label: { Label("记录今天",systemImage:"plus").frame(maxWidth:.infinity,minHeight:44) }.buttonStyle(.bordered)
            Text("这些是你设定的个人目标，可以随时调整。没有连续打卡惩罚，也不以更多运动代表更好恢复。演示模式的记录与真实记录分开。").font(.caption).foregroundStyle(.secondary)
        }.padding(24) }.safeAreaPadding(.bottom,24).background(PocketStyle.paper).foregroundStyle(PocketStyle.ink).navigationTitle("个人目标").navigationBarTitleDisplayMode(.inline).sheet(isPresented:$composer) { EventComposer(defaultKind:"自评") }
    }
    private func goal(_ title:String,achieved:Int,total:Binding<Int>,subtitle:String) -> some View {
        VStack(alignment:.leading,spacing:16) { HStack(alignment:.top) { Text(title).font(.headline); Spacer(); Text("\(achieved) / \(total.wrappedValue) 天").font(.title3).monospacedDigit().foregroundStyle(PocketStyle.green) }; ProgressView(value:min(Double(achieved),Double(total.wrappedValue)),total:Double(max(1,total.wrappedValue))).tint(PocketStyle.green); Text(subtitle).font(.caption).foregroundStyle(.secondary); Stepper("每周目标 \(total.wrappedValue) 天",value:total,in:1...7).font(.subheadline); if achieved >= total.wrappedValue { Label("达到你设定的本周目标",systemImage:"checkmark.circle").font(.caption).foregroundStyle(PocketStyle.green) } }.padding(20).background(PocketStyle.green.opacity(0.05),in:RoundedRectangle(cornerRadius:20))
    }
}

struct FeedbackReviewView:View {
    @EnvironmentObject private var experience:PocketExperience
    @State private var selectedGroup:String?
    @State private var composer=false
    private var events:[PocketEvent] { experience.visibleEvents.filter { $0.date >= Date().addingTimeInterval(-28*86400) && $0.date <= Date() } }
    private var pairs:[FeedbackPair] { FeedbackEngine.pairs(events,now:Date()) }
    private var groups:[String] { Array(Set(pairs.map(\.group))).sorted() }
    private var currentGroup:String { selectedGroup.flatMap { groups.contains($0) ? $0:nil } ?? pairs.first?.group ?? "" }
    private var shown:[FeedbackPair] { pairs.filter { $0.group == currentGroup } }
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                DemoNote()
                Text("让数据接受你的反馈").font(.title2.weight(.semibold))
                Text("对照填写前保留下来的模型结果与当时精力。它帮助找到值得复核的情况，不会按一次自评直接改分。").font(.subheadline).foregroundStyle(.secondary)
                if groups.count > 1 {
                    Picker("比较哪种模型",selection:Binding(get:{currentGroup},set:{selectedGroup=$0})) { ForEach(groups,id:\.self) { Text(friendlyGroup($0)).tag($0) } }.pickerStyle(.menu)
                }
                HStack(alignment:.top) {
                    summary("可配对",String(shown.count))
                    Spacer();summary("值得回看",String(shown.filter(\.needsReview).count))
                    Spacer();summary("已有记录",String(events.count))
                }.padding(20).background(PocketStyle.green.opacity(0.055),in:RoundedRectangle(cornerRadius:20))
                if !currentGroup.isEmpty { Text(friendlyGroup(currentGroup)).font(.caption).foregroundStyle(.secondary) }
                Text("模型较高（≥75）但精力≤2，或模型较低（≤25）但精力≥4，会标为值得回看。这是公开的检查条件，不是准确率，也不将两个量表等同。").font(.caption).foregroundStyle(.secondary)
                Button { composer=true } label: { Label("记录现在的精力",systemImage:"plus.circle").frame(maxWidth:.infinity,minHeight:48) }.buttonStyle(.borderedProminent)
                if shown.isEmpty {
                    Text("还没有可配对记录").font(.headline)
                    Text("在有新鲜模型结果时打开自评并选择精力，保存后这里会显示两者。旧记录照常保留，不会用现在的分数回填历史。").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(shown.prefix(30)) { pair in
                    VStack(alignment:.leading,spacing:10) {
                        HStack { Text(pair.event.date.formatted(date:.abbreviated,time:.shortened)).font(.caption);Spacer();if pair.needsReview { Label("值得回看",systemImage:"questionmark.circle").font(.caption).foregroundStyle(PocketStyle.drain) } }
                        HStack { Text("\(pair.prediction.kind) \(pair.prediction.value)/100");Spacer();Text("精力 \(pair.event.energy)/5").foregroundStyle(PocketStyle.green) }.font(.subheadline.weight(.medium))
                        Text("观测于 "+pair.prediction.observedAt.formatted(date:.omitted,time:.shortened)).font(.caption).foregroundStyle(.secondary)
                        if !pair.event.note.isEmpty { Text(pair.event.note).font(.caption).foregroundStyle(.secondary) }
                    }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(.white,in:RoundedRectangle(cornerRadius:16))
                }
                Text("近28天 · 不同模型版本及近期状态/连续电量分开比较。补记历史、记录当时已过期的观测与无法配对的旧记录不参与；肌肉疲劳、精神压力和精力感受也可能不同。").font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }.safeAreaPadding(.bottom,24).background(PocketStyle.paper).navigationTitle("状态与体感对照").navigationBarTitleDisplayMode(.inline).toolbar(.visible,for:.navigationBar)
            .sheet(isPresented:$composer) { EventComposer(defaultKind:"自评") }
    }
    private func friendlyGroup(_ group:String)->String { String(group.split(separator:"/",maxSplits:1).first ?? "").trimmingCharacters(in:.whitespaces) }
    private func summary(_ name:String,_ value:String)->some View { VStack(alignment:.leading,spacing:8) { Text(name).font(.caption).foregroundStyle(.secondary);Text(value).font(.system(size:30,weight:.light)).monospacedDigit() } }
}
