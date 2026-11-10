import SwiftUI
import Charts

private func energyTime(_ date: Date) -> String { date.formatted(.dateTime.hour().minute()) }
private func energyRange(_ start: Date, _ end: Date) -> String { energyTime(start) + "–" + energyTime(end) }
private func energyNumber(_ value: Double) -> String { String(format: "%.1f", value) }
private func energySigned(_ value: Double) -> String { (value >= 0 ? "+" : "−") + energyNumber(abs(value)) }
private func energyColor(_ value: Double) -> Color { value >= 0 ? PocketStyle.green : PocketStyle.drain }

struct EnergyTimeline: View {
    var points: [BatteryPoint]
    var day: Date
    var workouts: [PocketWorkout] = []
    @Binding var selection: Date?
    var height: CGFloat = 220
    private var report: EnergyDayReport { EnergyInsights.day(points: points, day: day, now: Date()) }
    private var end: Date { Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: day))! }
    private var visiblePoints: [BatteryPoint] { EnergyInsights.points(points, now: Date()).filter { $0.date >= report.day && $0.date < end && EnergyInsights.valid($0.value) != nil } }
    private var selected: EnergyInterval? { report.intervals.first { date in selection.map { $0 >= date.start && $0 <= date.end } ?? false } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if visiblePoints.isEmpty && report.intervals.isEmpty {
                VStack(alignment: .leading, spacing: 8) { Image(systemName: "chart.xyaxis.line").font(.title2); Text("这一天还没有电量记录").font(.subheadline); Text("有记录的时段才会形成曲线，缺失不补算。").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            } else {
                Chart {
                    ForEach(report.intervals) { interval in
                        if (interval.effect?.sleepRecharge ?? 0) > 0 {
                            RectangleMark(xStart: .value("睡眠补充开始", interval.start), xEnd: .value("睡眠补充结束", interval.end), yStart: .value("下界", 0), yEnd: .value("上界", 100)).foregroundStyle(PocketStyle.mint.opacity(0.10))
                        }
                        AreaMark(x: .value("时间", interval.start), yStart: .value("基底", 0), yEnd: .value("电量", interval.before), series: .value("区间", interval.id)).foregroundStyle(PocketStyle.green.opacity(0.045))
                        AreaMark(x: .value("时间", interval.end), yStart: .value("基底", 0), yEnd: .value("电量", interval.after), series: .value("区间", interval.id)).foregroundStyle(PocketStyle.green.opacity(0.045))
                        LineMark(x: .value("时间", interval.start), y: .value("电量", interval.before), series: .value("区间", interval.id)).foregroundStyle(energyColor(interval.delta)).lineStyle(StrokeStyle(lineWidth: 2.5))
                        LineMark(x: .value("时间", interval.end), y: .value("电量", interval.after), series: .value("区间", interval.id)).foregroundStyle(energyColor(interval.delta)).lineStyle(StrokeStyle(lineWidth: 2.5))
                    }
                    ForEach(visiblePoints) { point in
                        if let value = point.value { PointMark(x: .value("观测时间", point.date), y: .value("电量", value)).symbolSize(14).foregroundStyle(PocketStyle.green) }
                    }
                    ForEach(workouts) { workout in
                        RuleMark(x: .value("训练开始", workout.start)).foregroundStyle(PocketStyle.ink.opacity(0.18)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                            .annotation(position: .top, spacing: 3) { Image(systemName: "figure.run").font(.caption2).foregroundStyle(PocketStyle.ink) }
                    }
                    if let selected {
                        RuleMark(x: .value("选中", selected.end)).foregroundStyle(PocketStyle.green.opacity(0.45))
                        PointMark(x: .value("选中", selected.end), y: .value("电量", selected.after)).symbolSize(60).foregroundStyle(PocketStyle.green)
                    }
                }
                .chartXScale(domain: report.day...end).chartYScale(domain: 0...100)
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { tick in AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4])); AxisValueLabel { if let date = tick.as(Date.self) { Text(String(format:"%02d:00",Calendar.current.component(.hour,from:date))) } } } }
                .chartYAxis { AxisMarks(position: .leading, values: [0, 50, 100]) }
                .chartXSelection(value: $selection).chartGesture { proxy in SpatialTapGesture().onEnded { event in proxy.selectXValue(at: event.location.x) } }
                .frame(height: height).accessibilityLabel("当天电量模型曲线；绿色补充，橙色消耗，浅绿色为睡眠补充区间，虚线为训练开始。缺失留空。")
                if let selected {
                    HStack { Text(energyRange(selected.start, selected.end)); Spacer(); Text("\(Int(selected.before.rounded())) → \(Int(selected.after.rounded()))"); Text(energySigned(selected.delta)).foregroundStyle(energyColor(selected.delta)) }.font(.caption.weight(.medium)).monospacedDigit().padding(12).background(PocketStyle.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                } else { Text("轻点曲线查看区间 · 虚线为训练开始").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

struct EnergyInsightsView: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var experience: PocketExperience
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State var day: Date
    @State private var scope = 0
    @State private var selection: Date?
    @State private var selectedWorkout: UUID?
    @State private var composer = false
    @State private var calendarOpen = false
    private let intervalDetailAnchor = "energy-interval-detail"
    private var points: [BatteryPoint] { experience.demo ? experience.demoBattery.points : health.batteryHistory }
    private var report: EnergyDayReport { EnergyInsights.day(points: points, day: day, now: Date()) }
    private var workoutInput: [PocketWorkout] { experience.demo ? WorkoutAnalysis.demoWorkouts(day: day) : health.snapshot?.workouts ?? [] }
    private var comparisons: [EnergyWorkoutComparison] { EnergyInsights.workouts(workoutInput, points: points, day: day, now: Date()) }
    private var selectedInterval: EnergyInterval? { report.intervals.first { item in selection.map { $0 >= item.start && $0 <= item.end } ?? false } }
    private var events: [PocketEvent] { experience.visibleEvents.filter { Calendar.current.isDate($0.date, inSameDayAs: day) && $0.date <= Date() }.sorted { $0.date < $1.date } }
    private var ranked: [EnergyInterval] { Array(report.intervals.filter { $0.delta < 0 }.sorted { $0.delta < $1.delta }.prefix(3)) }
    private func move(_ offset: Int) { day = Calendar.current.date(byAdding: .day, value: offset, to: day) ?? day; selection = nil; selectedWorkout = nil }
    var body: some View {
        ScrollViewReader { scroll in
          ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) { Text("ENERGY  /  INSIGHTS").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(.secondary); Text("把一天，看明白").font(.system(size: 29, weight: .semibold)); DemoNote() }
                HStack { Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("洞察前一天"); Spacer(); Button { calendarOpen = true } label: { Label(day.formatted(.dateTime.month().day().weekday()), systemImage: "calendar").font(.subheadline).frame(minHeight: 44) }; Spacer(); Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.accessibilityLabel("洞察后一天") }
                HStack(spacing:4) { ForEach(0..<2) { index in Button { scope = index } label: { Text(index == 0 ? "一天 · 时间线" : "七天 · 节奏").font(.subheadline.weight(.medium)).frame(maxWidth:.infinity,minHeight:44).background(scope == index ? .white : .clear,in:Capsule()) }.buttonStyle(.plain).accessibilityAddTraits(scope == index ? .isSelected : []) } }.padding(4).background(PocketStyle.rule.opacity(0.4),in:Capsule())
                if scope == 0 { daily(scroll: scroll) } else { weekly }
                DisclosureGroup("怎么看这些图") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("身体电量是未校准的实验模型。曲线、补充和消耗都不是医学测量，也不等同于 Garmin 或 WHOOP 的评分。")
                        Text("只比较间隔不超过一小时的相邻有效电量点。边界按已有模型区间裁切；缺失不连线，未来不填值。小时热图表示已有区间的每小时净变化速率，部分小时会标记小圆点。")
                        Text("训练卡将同一时段的曲线下降按重叠时长分配；重叠训练不会重复累加。这是时间上的对应关系，不证明训练造成了全部消耗，也不会再扣一次电量。")
                        Text("计算分项来自已保存的模型记录。连续且完整的记录会展示包含上下限修正的账本，并核对总和与曲线净变化。旧记录没有分项时不补造。手动记录与自评用于对照，不自动改变评分。")
                    }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                }.font(.subheadline)
            }.padding(24)
          }
        }.safeAreaPadding(.bottom, 24).background(PocketStyle.paper).foregroundStyle(PocketStyle.ink).navigationTitle("电量洞察").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $composer) { EventComposer(defaultKind: "自评") }
        .sheet(isPresented: $calendarOpen) { NavigationStack { DatePicker("洞察日期", selection: $day, displayedComponents: .date).datePickerStyle(.graphical).padding().navigationTitle("选择日期").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { calendarOpen = false; selection = nil; selectedWorkout = nil } } } } }
        .onChange(of: experience.demo) { _,_ in selection = nil; selectedWorkout = nil }
    }
    private func daily(scroll: ScrollViewProxy) -> some View {
        let dayReport = report
        return VStack(alignment: .leading, spacing: 24) {
            summary(dayReport, scroll: scroll)
            NavigationLink {
                ScrollView { VStack(alignment:.leading,spacing:24) { DemoNote(); balanceWaterfall; factors; feelingComparison }.padding(24) }.safeAreaPadding(.bottom,24).background(PocketStyle.paper).navigationTitle("核对电量估计").navigationBarTitleDisplayMode(.inline)
            } label: { Label("为什么会是这个分数？",systemImage:"chart.bar.doc.horizontal").font(.subheadline.weight(.medium)).frame(minHeight:44) }
            EnergyTimeline(points: points, day: day, workouts: comparisons.map { $0.impact.workout }, selection: $selection, height: 230)
            HStack(spacing: 16) { Label("睡眠补充区间", systemImage: "moon.fill").foregroundStyle(PocketStyle.green); Text("训练开始 ┆").foregroundStyle(.secondary) }.font(.caption2)
            hourBars
            VStack(alignment: .leading, spacing: 0) {
                peaks(scroll: scroll)
                Color.clear.frame(height: 1).id(intervalDetailAnchor).accessibilityHidden(true)
                if let selectedInterval { intervalDetail(selectedInterval).padding(.top, 8) }
            }
            balanceWaterfall
            factors
            workouts
            feelingComparison
            records
        }
    }
    private func summary(_ report: EnergyDayReport, scroll: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("这天的电量回顾").font(.headline)
            HStack { stat("曲线补充", report.coveredSeconds > 0 ? "+" + energyNumber(report.charged) : "—", PocketStyle.green); Spacer(); stat("曲线消耗", report.coveredSeconds > 0 ? "−" + energyNumber(report.drained) : "—", PocketStyle.drain) }
            ProgressView(value: report.elapsedSeconds > 0 ? report.coveredSeconds / report.elapsedSeconds : 0).tint(PocketStyle.green)
                .accessibilityLabel("已过去时段的可比较曲线覆盖")
            Text("\(energyNumber(report.coveredSeconds / 3600)) 小时可比较 · \(energyNumber(report.missingSeconds / 3600)) 小时缺少曲线\(report.elapsedSeconds == 0 ? " · 尚未开始" : "")").font(.caption).foregroundStyle(.secondary)
            if report.coveredSeconds > 0 {
                Divider()
                if let recharge = report.chargingPeak {
                    highlight("补充最多的区间", icon: "arrow.up.right", interval: recharge, scroll: scroll)
                }
                if let drain = report.peak {
                    highlight("消耗最多的区间", icon: "arrow.down.right", interval: drain, scroll: scroll)
                }
                Text(report.chargingPeak == nil && report.peak == nil
                     ? "可比较的曲线没有净变化。空白时段仍没有估计。"
                     : "从变化最大的区间开始，点开对照睡眠、训练和当时的体感。这里汇总已有曲线，空白时段留空。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if report.elapsedSeconds > 0 {
                Text(experience.demo
                     ? "演示曲线只覆盖部分日期。试试回看昨天的补充和消耗。"
                     : "这天还没有可比较的相邻电量点。如果 Apple 健康已有该日期的记录，可以回到「今日」刷新后再看。")
                    .font(.subheadline).foregroundStyle(.secondary)
                if !experience.demo {
                    NavigationLink { HealthConnectionView() } label: {
                        Label("检查健康数据的读取时间", systemImage: "heart.text.square").font(.subheadline).frame(minHeight: 44)
                    }
                }
            }
        }.padding(20).background(PocketStyle.green.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
    }
    private func reveal(_ interval: EnergyInterval, scroll: ScrollViewProxy) {
        selection = interval.start.addingTimeInterval(interval.seconds / 2)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            scroll.scrollTo(intervalDetailAnchor, anchor: .top)
        }
    }
    private func highlight(_ title: String, icon: String, interval: EnergyInterval, scroll: ScrollViewProxy) -> some View {
        Button {
            reveal(interval, scroll: scroll)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(energyColor(interval.delta)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.medium))
                    Text(energyRange(interval.start, interval.end)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(energySigned(interval.delta) + " 点").monospacedDigit().foregroundStyle(energyColor(interval.delta))
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("查看这个区间的计算分项")
    }
    private func stat(_ label: String, _ value: String, _ color: Color) -> some View { VStack(alignment: .leading, spacing: 6) { Text(label).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(size: 34, weight: .light)).monospacedDigit().foregroundStyle(color) } }
    private var hourBars: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("补充与消耗，发生在什么时候", subtitle: "每小时净变化 · 点 / 小时")
            if report.coveredSeconds > 0 {
                Chart(report.hours.filter { $0.rate != nil }) { hour in
                    if let rate = hour.rate { BarMark(x: .value("小时", hour.start, unit: .hour), y: .value("每小时净变化", rate)).foregroundStyle(energyColor(rate)).cornerRadius(3) }
                    RuleMark(y: .value("零", 0)).foregroundStyle(PocketStyle.ink.opacity(0.2))
                }.chartXScale(domain: report.day...Calendar.current.date(byAdding: .day, value: 1, to: report.day)!).chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { tick in AxisValueLabel { if let date = tick.as(Date.self) { Text(String(format:"%02d:00",Calendar.current.component(.hour,from:date))) } } } }.frame(height: 120)
                Text("部分小时按已有区间折算速率；空白表示没有可比较曲线。").font(.caption2).foregroundStyle(.secondary)
            } else { Text("没有相邻有效记录，暂不绘制变化。").font(.subheadline).foregroundStyle(.secondary) }
        }
    }
    private func peaks(scroll: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            section("值得回看的时段", subtitle: "按区间净消耗排序")
            if ranked.isEmpty { Text("尚无可比较的下降区间。").font(.subheadline).foregroundStyle(.secondary) }
            ForEach(Array(ranked.enumerated()), id: \.element.id) { index,item in
                Button { reveal(item, scroll: scroll) } label: {
                    HStack(spacing: 12) { Text(String(index + 1)).font(.caption.weight(.semibold)).frame(width: 28, height: 28).background(PocketStyle.drain.opacity(0.08), in: Circle()); VStack(alignment: .leading, spacing: 4) { Text(energyRange(item.start, item.end)).font(.subheadline.weight(.medium)); Text(item.mode).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(energySigned(item.delta)).font(.title3).monospacedDigit().foregroundStyle(PocketStyle.drain); Image(systemName: "chevron.right").font(.caption) }.padding(.vertical, 10).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("查看消耗时段 \(energyRange(item.start,item.end))，净变化 \(energySigned(item.delta))")
                Divider()
            }
        }
    }
    private func intervalDetail(_ item: EnergyInterval) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("这个区间的变化").font(.headline)
            HStack { Text(energyRange(item.start,item.end)); Spacer(); Text("\(Int(item.before.rounded())) → \(Int(item.after.rounded()))").monospacedDigit() }.font(.subheadline)
            Text(energySigned(item.delta) + " 点净变化").font(.title2).foregroundStyle(energyColor(item.delta))
            if let effect = item.effect {
                let charge = (effect.sleepRecharge + effect.restRecharge) * item.effectFraction
                let drain = (effect.awakeDrain + effect.activityDrain + effect.heartRateDrain + effect.hrvDrain) * item.effectFraction
                Text("模型分项：补充 \(energyNumber(charge)) · 消耗 \(energyNumber(drain))").font(.caption)
                Text("上下限修正 " + energySigned((effect.boundaryAdjustment ?? 0)*item.effectFraction) + "；旧记录可能未保存修正项。").font(.caption2).foregroundStyle(.secondary)
            } else { Text("旧记录没有保存计算分项。").font(.caption).foregroundStyle(.secondary) }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(PocketStyle.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
    }
    private var balanceWaterfall: some View {
        VStack(alignment:.leading,spacing:14) {
            section("这个分数，怎样走到这里",subtitle:"已有连续区间的计算账本 · 不是生理测量")
            if let balance = report.balance {
                HStack { stat("区间起点",energyNumber(balance.start),PocketStyle.green); Spacer(); Image(systemName:"arrow.right").foregroundStyle(.secondary); Spacer(); stat("区间终点",energyNumber(balance.end),PocketStyle.green) }
                Chart(balance.steps) { step in
                    BarMark(x:.value("分项",step.title),yStart:.value("之前",step.before),yEnd:.value("之后",step.after)).foregroundStyle(energyColor(step.delta)).cornerRadius(3)
                        .annotation(position:.top) { Text(energySigned(step.delta)).font(.caption2).monospacedDigit() }
                }.chartYScale(domain:min(0,balance.steps.map { min($0.before,$0.after) }.min() ?? 0)...max(100,balance.steps.map { max($0.before,$0.after) }.max() ?? 100)).chartYAxis { AxisMarks(position:.leading) }.frame(height:190)
                Text("分项与曲线已核对 · 覆盖 \(energyNumber(report.effectCoverageSeconds/3600)) 小时。夜间 HRV 如有可比记录，其调节计入睡眠项，不重复相加。").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("有缺失区间或旧分项尚不完整，暂不把起点与终点拼成一张账本。下面仍展示已保存分项。").font(.subheadline).foregroundStyle(.secondary)
            }
        }.padding(18).background(PocketStyle.green.opacity(0.04),in:RoundedRectangle(cornerRadius:20))
    }
    private var factors: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("模型用到了什么", subtitle: "已保存分项覆盖 \(energyNumber(report.effectCoverageSeconds / 3600)) 小时")
            if report.factors.isEmpty { Text("这一天没有保存可展示的计算分项。").font(.subheadline).foregroundStyle(.secondary) }
            ForEach(report.factors) { factor in
                VStack(spacing: 6) { HStack { Text(factor.title); Spacer(); Text((factor.recharge ? "+" : "−") + energyNumber(factor.amount)).monospacedDigit().foregroundStyle(factor.recharge ? PocketStyle.green : PocketStyle.drain) }.font(.subheadline); GeometryReader { proxy in Capsule().fill(factor.recharge ? PocketStyle.green.opacity(0.7) : PocketStyle.drain.opacity(0.7)).frame(width: max(3, proxy.size.width * factor.amount / max(1,report.factors.map(\.amount).max() ?? 1))) }.frame(height: 5).background(PocketStyle.rule, in: Capsule()) }
            }
            Text("这是计算分项的解释，不是对真实疲劳原因的诊断。HRV 还会影响睡眠补充，不能把这里的日间 HRV 当作它的全部作用。").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var workouts: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("训练，放回一天里看", subtitle: "前后观测 + 对应曲线区间")
            if comparisons.isEmpty { Text("这一天没有已完成的训练记录。").font(.subheadline).foregroundStyle(.secondary) }
            ForEach(comparisons) { item in
                VStack(alignment: .leading, spacing: 14) {
                    Button { selectedWorkout = selectedWorkout == item.id ? nil : item.id; selection = item.impact.workout.start } label: {
                        HStack { Image(systemName: "figure.run").frame(width: 32, height: 32).background(PocketStyle.green.opacity(0.07), in: Circle()); VStack(alignment: .leading, spacing: 4) { Text(item.impact.workout.title).font(.headline); Text(energyRange(item.impact.workout.start,item.impact.workout.end)).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(item.impact.coveredSeconds > 0 ? "−" + energyNumber(item.impact.drop) : "—").font(.title2).monospacedDigit().foregroundStyle(PocketStyle.drain); Image(systemName: selectedWorkout == item.id ? "chevron.up" : "chevron.down").font(.caption) }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("查看\(item.impact.workout.title)前后观测")
                    if selectedWorkout == item.id {
                        HStack { observation("训练前观测",item.before); Spacer(); Image(systemName: "arrow.right").foregroundStyle(.secondary); Spacer(); observation("训练后观测",item.after) }
                        Text("\(Int((item.impact.workout.duration / 60).rounded())) 分钟" + (item.impact.workout.activeKcal.map { " · \(Int($0.rounded())) kcal" } ?? "")).font(.subheadline)
                        ProgressView(value: item.coverage).tint(PocketStyle.green)
                        Text("训练时段 \(Int((item.coverage * 100).rounded()))% 有可比较曲线 · \(Int((item.impact.coveredSeconds / 60).rounded())) 分钟").font(.caption).foregroundStyle(.secondary)
                        Text("右上角为对应区间分配的净消耗；前后值来自一小时内最近观测，并非训练精确起止值。训练不是全部变化的唯一原因。").font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(18).background(PocketStyle.green.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
            }
        }
    }
    private func observation(_ title: String, _ point: BatteryPoint?) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(.secondary); Text(point?.value.map { String(Int($0.rounded())) } ?? "—").font(.system(size: 28, weight: .light)).monospacedDigit(); Text(point.map { $0.date.formatted(.dateTime.month().day().hour().minute()) } ?? "无附近观测").font(.caption2).foregroundStyle(.secondary) }
    }
    private var feelingComparison: some View {
        let from = Calendar.current.date(byAdding:.day,value:-29,to:Calendar.current.startOfDay(for:Date()))!
        let pairs = EnergyInsights.feelings(experience.visibleEvents.filter { $0.kind == "自评" && $0.date >= from }.map { EnergyCheckIn(date:$0.date,rating:$0.energy) },points:points,now:Date())
        return VStack(alignment:.leading,spacing:14) {
            section("模型，和我的感觉一致吗？",subtitle:experience.demo ? "近 30 天 · 演示自评与附近模型参考" : "近 30 天 · 用真实自评对照附近的模型参考")
            if !pairs.isEmpty {
                Chart(pairs) { pair in PointMark(x:.value("当时电量参考",pair.battery),y:.value("自评精力",pair.rating)).foregroundStyle(PocketStyle.green.opacity(0.7)).symbolSize(65) }
                    .chartXScale(domain:0...100).chartYScale(domain:1...5).chartYAxis { AxisMarks(values:[1,2,3,4,5]) }.chartXAxisLabel("当时电量参考").chartYAxisLabel("自评精力 / 5").frame(height:180)
                Text("\(pairs.count) 条可配对自评 · \(Set(pairs.map { Calendar.current.startOfDay(for:$0.date) }).count) 个日期").font(.caption).foregroundStyle(.secondary)
            } else { Text("还没有可配对的自评。现在记录一次精力，之后回看分数是否贴合自己的感受。").font(.subheadline).foregroundStyle(.secondary) }
            Text("只配对自评前一小时内的最近模型记录，缺少记录不补值。图形仅展示对应关系，暂不把它当作准确率或自动调分依据。").font(.caption2).foregroundStyle(.secondary)
            Button { composer = true } label: { Label("记录我的精力",systemImage:"plus.circle").frame(minHeight:44) }
        }.padding(18).background(PocketStyle.green.opacity(0.04),in:RoundedRectangle(cornerRadius:20))
    }
    private var records: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("也对照你的感受", subtitle: "记录独立于模型评分")
            ForEach(events) { event in HStack(alignment: .top, spacing: 12) { Text(energyTime(event.date)).font(.caption).monospacedDigit().foregroundStyle(.secondary); VStack(alignment: .leading, spacing: 4) { Text(event.kind + (event.kind == "自评" ? " · \(event.energy) / 5" : "")).font(.subheadline.weight(.medium)); if !event.note.isEmpty { Text(event.note).font(.caption).foregroundStyle(.secondary) } } } }
            if events.isEmpty { Text("还没有手动记录。休息、咖啡和感受可供以后对照。").font(.subheadline).foregroundStyle(.secondary) }
            if Calendar.current.isDateInToday(day) { Button { composer = true } label: { Label("记录现在的感受", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.bordered) }
        }
    }
    private var weekly: some View {
        let rows = EnergyInsights.week(points: points, ending: day, now: Date())
        return VStack(alignment: .leading, spacing: 20) {
            section("一周的节奏地图", subtitle: "每格一个小时 · 固定色阶，便于跨天比较")
            HStack { Text("日期").frame(width: 44, alignment: .leading); HStack { Text("00"); Spacer(); Text("06"); Spacer(); Text("12"); Spacer(); Text("18"); Spacer(); Text("24") } }.font(.caption2).foregroundStyle(.secondary)
            ForEach(rows, id: \.day) { row in
                Button { day = row.day; scope = 0; selection = nil; selectedWorkout = nil } label: {
                    HStack(spacing: 8) { Text(row.day.formatted(.dateTime.month().day())).font(.caption).frame(width: 44, alignment: .leading); HStack(spacing: 2) { ForEach(row.hours) { hour in RoundedRectangle(cornerRadius: 3).fill(heatColor(hour)).frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28).overlay { if hour.coveredSeconds > 0 && hour.coveredSeconds < hour.end.timeIntervalSince(hour.start)-1 { Circle().fill(PocketStyle.ink.opacity(0.5)).frame(width: 3, height: 3) } } } } }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("查看\(row.day.formatted(.dateTime.month().day()))，可比较\(energyNumber(row.coveredSeconds/3600))小时，补充\(energyNumber(row.charged))，消耗\(energyNumber(row.drained))")
            }
            HStack(spacing: 12) { legend("消耗", PocketStyle.drain); legend("补充", PocketStyle.green); legend("缺记录", PocketStyle.rule); legend("未到时段", PocketStyle.rule.opacity(0.25)) }.font(.caption2)
            Text("颜色越深，变化越快（色阶上限 8 点/小时）；有曲线但净变化为零呈中性浅色。小圆点为部分小时。轻点日期回到当天详情。").font(.caption2).foregroundStyle(.secondary)
            section("有记录的日子", subtitle: "仅累计可比较区间，缺失日不会当成零")
            ForEach(rows.filter { $0.coveredSeconds > 0 }, id: \.day) { row in
                HStack { Text(row.day.formatted(.dateTime.month().day())); Spacer(); Text("+" + energyNumber(row.charged)).foregroundStyle(PocketStyle.green); Text("−" + energyNumber(row.drained)).foregroundStyle(PocketStyle.drain); Text(energyNumber(row.coveredSeconds/3600) + "h").foregroundStyle(.secondary) }.font(.subheadline).monospacedDigit().padding(.vertical, 6)
            }
            if rows.allSatisfy({ $0.coveredSeconds == 0 }) { Text("这七天还没有可比较的电量记录。").font(.subheadline).foregroundStyle(.secondary) }
        }
    }
    private func heatColor(_ hour: EnergyHourCell) -> Color {
        guard let rate = hour.rate else { return hour.start >= Date() ? PocketStyle.rule.opacity(0.25) : PocketStyle.rule }
        if abs(rate) < 0.05 { return PocketStyle.green.opacity(0.08) }
        return energyColor(rate).opacity(0.18 + 0.82 * min(1, abs(rate)/8))
    }
    private func legend(_ title: String, _ color: Color) -> some View { HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9); Text(title) } }
    private func section(_ title: String, subtitle: String) -> some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.title3.weight(.semibold)); Text(subtitle).font(.caption).foregroundStyle(.secondary) } }
}
