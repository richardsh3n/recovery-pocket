import SwiftUI
import Charts
private let accent = Color(red: 0.62, green: 0.90, blue: 0.72)
private let backdrop = Color(red: 0.055, green: 0.075, blue: 0.07)
enum Screen: String, CaseIterable { case today = "今日", trends = "趋势", journal = "自评与记录", model = "数据与算法"; var icon: String { switch self { case .today: return "sun.max"; case .trends: return "chart.xyaxis.line"; case .journal: return "square.and.pencil"; case .model: return "waveform.path.ecg" } } }
enum Scenario: String, CaseIterable { case steady = "平稳一周", tired = "连续透支", sparse = "采样稀少", missing = "缺失 HRV" }
struct JournalEntry: Codable, Identifiable { var date: Date; var energy: Int; var stress: Int; var tags: [String]; var note: String; var id: Date { date } }
@main struct RecoveryPreviewApp: App {
    var body: some Scene { WindowGroup("Recovery Pocket · 0.2") { PreviewView().frame(minWidth: 980, minHeight: 760).preferredColorScheme(.dark) }.defaultSize(width: 1180, height: 880) }
}
struct PreviewView: View {
    @State private var screen: Screen = .today
    @State private var scenario: Scenario = .steady
    @AppStorage("previewSleepTargetV2") private var target = 8.0
    @State private var intention = "工作"
    @State private var energy = 3
    @State private var stress = 3
    @State private var tags: Set<String> = []
    @State private var note = ""
    @State private var entries: [JournalEntry] = []
    @State private var completed: Set<String> = []
    private var today: Date { Calendar.current.startOfDay(for: Date()) }
    private var days: [RecoveryDay] {
        (0..<60).map { i in
            let t = Double(i), recent = i >= 54 && scenario == .tired
            let n = NightRecord(date: Calendar.current.date(byAdding: .day, value: i - 59, to: today)!, sleepHours: recent ? 5.5 + 0.25 * sin(t) : 7.9 + 0.4 * sin(t * 0.7), hrv: scenario == .missing && i == 59 ? nil : recent ? 34 + 3 * sin(t) : 51 + 5 * sin(t * 0.5), heartRate: recent ? 64 + sin(t) : 54 + 2 * sin(t * 0.4), hrvCount: scenario == .sparse && i >= 54 ? 2 : 6, heartRateCount: scenario == .sparse && i >= 54 ? 6 : 48)
            return RecoveryDay(night: n, activeKcal: recent ? 780 : 440 + 90 * sin(t * 0.6), sleepMidpointHour: nil)
        }
    }
    private var estimates: [RecoveryEstimate] { RecoveryModelV2.calculate(days: days, sleepTarget: target) }
    private var current: RecoveryEstimate { estimates.last! }
    private var latest: NightRecord { days.last!.night }
    private var saved: JournalEntry? { entries.first { Calendar.current.isDate($0.date, inSameDayAs: today) } }
    private var needsRest: Bool { (current.score.map { $0 < 55 } ?? false) || (saved?.energy ?? 3) <= 2 || intention == "恢复" }
    private var tasks: [(String,String)] {
        if current.score == nil && saved == nil { return [("先做一次自评", "关键测量缺失，先结合自己的感受安排今天。"), ("保留调整空间", "今天暂不依据恢复分数安排强度。"), ("看看数据覆盖", "在数据与算法页检查缺失项目；不要把缺失理解成疲劳。") ] }
        if needsRest { return [("给今天减一档", intention == "训练" ? "把强度目标换成轻松活动；结合身体感受调整。" : "留下一个最重要的任务，其他安排留出余量。"), ("下午留一段空白", "安排 15 分钟不接任务的休息，晚些时候再看主观精力。"), ("今晚提前收尾", "按你的睡眠目标安排作息，观察之后几天的变化。") ] }
        return [("安排一段专注时间", "把今天最重要的\(intention == "训练" ? "训练安排" : "工作")放进状态较好的时段；分数不能保证表现。"), ("下午再看一次自己", "如果明显疲劳或不适，用身体感受调整原计划。"), ("守住今晚的睡眠时间", "维持节奏比把恢复分数追到满分更有用。")]
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 32)).foregroundStyle(accent)
                Text("RECOVERY\nPOCKET").font(.system(size: 18, weight: .semibold)).tracking(3)
                Text("给一天留一点余量").font(.caption).foregroundStyle(.secondary)
                Divider()
                ForEach(Screen.allCases, id: \.self) { item in
                    Button { screen = item } label: { Label(item.rawValue, systemImage: item.icon).frame(maxWidth: .infinity, alignment: .leading).padding(11).background(screen == item ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10)) }.buttonStyle(.plain).foregroundStyle(screen == item ? accent : .secondary)
                }
                Spacer()
                Text("MAC · 0.2\n本地保存 · 无数据上传").font(.caption).foregroundStyle(.secondary)
                Text("演示数据与自评独立保存").font(.caption2).foregroundStyle(.secondary)
            }.padding(25).frame(width: 205).frame(maxHeight: .infinity).background(.white.opacity(0.025))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) { Text(screen == .today ? "今天，怎么安排？" : screen.rawValue).font(.system(size: 32, weight: .semibold)); Text(today.formatted(date: .complete, time: .omitted)).foregroundStyle(.secondary) }
                        Spacer()
                        Label("合成情景 · 非你的健康数据", systemImage: "testtube.2").font(.caption).foregroundStyle(.orange).padding(10).background(.orange.opacity(0.1), in: Capsule())
                    }
                    switch screen { case .today: todayPage; case .trends: trendsPage; case .journal: journalPage; case .model: modelPage }
                    Divider()
                    HStack { Text("预览情景").font(.caption).foregroundStyle(.secondary); Picker("预览情景", selection: $scenario) { ForEach(Scenario.allCases, id: \.self) { Text($0.rawValue) } }.labelsHidden().frame(width: 170); Spacer(); Text("实验模型 · 不用于诊断").font(.caption).foregroundStyle(.secondary) }
                }.padding(32)
            }
        }.background(backdrop).onAppear { load() }
    }
    private var todayPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            panel {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(current.state).font(.system(size: 34, weight: .medium)).foregroundStyle(accent)
                        Text(current.score == nil ? "关键测量不完整，今天先依据自己的感受安排。" : needsRest ? "结合数据、你的自评和今天的目标，建议留出更多余量。" : "目前节奏比较平稳。先选一个今天最重要的方向。")
                        Picker("今天以什么为主", selection: $intention) { Text("工作").tag("工作"); Text("训练").tag("训练"); Text("恢复").tag("恢复") }.pickerStyle(.segmented).frame(maxWidth: 360)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) { Text(current.score.map(String.init) ?? "—").font(.system(size: 68, weight: .light, design: .rounded)); Text(current.lower.map { "模型范围 \($0)–\(current.upper!)" } ?? "等待足够的记录").font(.caption); Text(current.reliability).font(.caption).foregroundStyle(accent) }
                }
                Divider()
                Text("这是恢复参考，不能解释为剩余电量。范围反映模型内部不确定性，尚未校准为医学置信区间。").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 18) {
                panel {
                    Text("今天的节奏").font(.headline)
                    ForEach(tasks, id: \.0) { task in
                        Button { if completed.contains(task.0) { completed.remove(task.0) } else { completed.insert(task.0) } } label: {
                            HStack(alignment: .top, spacing: 12) { Image(systemName: completed.contains(task.0) ? "checkmark.circle.fill" : "circle").foregroundStyle(accent); VStack(alignment: .leading, spacing: 5) { Text(task.0).font(.headline); Text(task.1).font(.caption).foregroundStyle(.secondary) }; Spacer() }.padding(.vertical, 5)
                        }.buttonStyle(.plain)
                    }
                }
                panel {
                    Text(saved == nil ? "手表不知道你今天的感受" : "今天的自评已记下").font(.headline)
                    Text(saved.map { "精力 \($0.energy)/5 · 压力 \($0.stress)/5" } ?? "十秒自评，把身体信号和你的感受放在一起。")
                    Text("自评影响安排建议，当前不暗中改变生理评分。").font(.caption).foregroundStyle(.secondary)
                    Button(saved == nil ? "做一次短自评" : "修改今天的自评") { screen = .journal }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                    Divider()
                    metric("昨夜睡眠", latest.sleepHours, "小时")
                    metric("睡眠 HRV", latest.hrv, "ms")
                    metric("睡眠心率", latest.heartRate, "次/分")
                }
            }
            panel { Text("为什么是这个状态").font(.headline); ForEach(current.reasons.prefix(3)) { reason in HStack(alignment: .top) { Text(reason.name).frame(width: 140, alignment: .leading); Text(reason.detail).foregroundStyle(.secondary); Spacer() }.font(.subheadline) }; if current.score == nil { Text("本夜缺少有效数据，暂不发布评分。历史趋势仍可查看。").foregroundStyle(.secondary) }; Button("展开一周变化 →") { screen = .trends }.buttonStyle(.plain).foregroundStyle(accent) }
        }
    }
    private var trendsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            panel {
                Text("恢复是连续的过程").font(.headline)
                Chart(Array(estimates.suffix(14))) { item in if let score = item.score { AreaMark(x: .value("日期", item.date), yStart: .value("下界", item.lower!), yEnd: .value("上界", item.upper!)).foregroundStyle(accent.opacity(0.1)); LineMark(x: .value("日期", item.date), y: .value("恢复参考", score)).foregroundStyle(accent); PointMark(x: .value("日期", item.date), y: .value("恢复参考", score)).foregroundStyle(accent) } }.chartYScale(domain: 0...100).frame(height: 220)
                Text("曲线使用当时之前的个人基线，缺失夜晚不补零。阴影是内部估计范围。").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top) {
                panel { Text("睡眠目标缺口").font(.headline); Text(String(format: "%.1f 小时", current.sleepGap)).font(.largeTitle).foregroundStyle(accent); Text("近 7 夜相对目标的已记录缺口；不是可按小时偿还的生理债务。").font(.caption).foregroundStyle(.secondary); Chart(Array(days.suffix(14))) { item in if let h = item.night.sleepHours { BarMark(x: .value("日期", item.id), y: .value("小时", h)).foregroundStyle(accent.opacity(0.65)) } }.frame(height: 110) }
                panel { Text("睡眠 HRV 的个人变化").font(.headline); Chart(Array(days.suffix(14))) { item in if let h = item.night.hrv { LineMark(x: .value("日期", item.id), y: .value("ms", h)).foregroundStyle(accent) } }.frame(height: 170); Text("比较你自己的变化，不能与别人的绝对数值排名。").font(.caption).foregroundStyle(.secondary) }
            }
            panel { Text("把感受放在趋势旁边").font(.headline); if entries.isEmpty { Text("还没有自评。连续记录后，可以对照自己的精力、压力和事件。").foregroundStyle(.secondary); Button("记下今天") { screen = .journal } } else { ForEach(entries.sorted { $0.date > $1.date }.prefix(7)) { entry in Text("\(entry.date.formatted(date: .abbreviated, time: .omitted)) · 精力 \(entry.energy)/5 · 压力 \(entry.stress)/5 · \(entry.tags.joined(separator: "、"))").font(.subheadline) } }; Text("同一天出现的事件和变化只能提供线索，不能证明因果。").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var journalPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            panel {
                Text("十秒，听听自己的感觉").font(.title2)
                Stepper("精力：\(energy)/5  ·  1 很疲惫，5 很充沛", value: $energy, in: 1...5)
                Stepper("压力：\(stress)/5  ·  1 放松，5 很紧绷", value: $stress, in: 1...5)
                Text("今天有什么值得记住？").font(.headline)
                HStack { ForEach(["晚睡", "饮酒", "晚间训练", "出差", "高压工作"], id: \.self) { tag in Button(tag) { if tags.contains(tag) { tags.remove(tag) } else { tags.insert(tag) } }.tint(tags.contains(tag) ? accent : .gray) } }
                TextField("可选：一句话记录今天", text: $note).textFieldStyle(.roundedBorder)
                Button("保存今天的自评") { entries.removeAll { Calendar.current.isDate($0.date, inSameDayAs: today) }; entries.append(JournalEntry(date: today, energy: energy, stress: stress, tags: tags.sorted(), note: String(note.prefix(500)))); persist(); screen = .today }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                Text("保存在这台 Mac 的预览中。即使退出 App，也能继续查看；不会写入 Apple 健康。").font(.caption).foregroundStyle(.secondary)
            }
            panel { Text("我的记录").font(.headline); if entries.isEmpty { Text("第一条记录从今天开始。").foregroundStyle(.secondary) }; ForEach(entries.sorted { $0.date > $1.date }) { entry in HStack { VStack(alignment: .leading) { Text(entry.date.formatted(date: .abbreviated, time: .omitted)); Text("精力 \(entry.energy)/5 · 压力 \(entry.stress)/5 · \(entry.tags.joined(separator: "、"))").foregroundStyle(.secondary); if !entry.note.isEmpty { Text(entry.note) } }; Spacer(); Button("删除", role: .destructive) { entries.removeAll { $0.id == entry.id }; persist() } }.padding(.vertical, 6) } }
        }
    }
    private var modelPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            panel { Text("从一晚加权，升级为多日状态估计").font(.title2); Text("01 个人基线：过去 60 天有效夜晚，至少 14 夜。HRV 取对数，中位数与 MAD 抑制极端值。"); Text("02 连续状态：卡尔曼滤波融合 HRV 与睡眠心率。采样少时权重降低、范围变宽；间隔越久，不确定性越大。"); Text("03 多日负担：加入当夜睡眠缺口、近七夜目标缺口、近期 HRV 趋势与前日活动量。"); Text("04 发布门槛：关键数据缺失时不评分；HRV 和心率同时偏高会提示信号冲突。"); Text("参数仍是工程初始假设，尚未用你的实际感受或独立样本校准。模型结构更完整不等于已经证明更准确。").foregroundStyle(.secondary) }
            panel { Text("你可以检查的设置").font(.headline); Stepper(String(format: "睡眠目标 %.1f 小时", target), value: $target, in: 6...10, step: 0.5); Text("有效基线 \(current.baselineNights) 夜 · 本夜 HRV \(latest.hrvCount) 条 · 心率 \(latest.heartRateCount) 条"); Text("状态保留系数 0.82/日；过程噪声 0.12/日；参考分映射 82 − 21 × 综合负担。这些系数都需要验证。").font(.caption).foregroundStyle(.secondary) }
            panel { Text("开源与验证路线").font(.headline); Link("FilterPy：标准状态空间与滤波方法参考", destination: URL(string: "https://github.com/rlabbe/filterpy")!); Text("当前是原创 Swift 实现，没有冒充已经接入深度学习。Chronos / TimesFM 作为下一轮预测实验候选；先做逐日回测，再比较是否有增益。"); Text("需要分别验证：信号预测误差、与主观精力的关系，以及建议是否帮助你安排生活。模型不能复刻 Garmin 的专有 Body Battery。").font(.caption).foregroundStyle(.secondary) }
            panel { Text("真实数据接入的边界").font(.headline); Text("此 Mac 版本使用合成情景，当前自评也不会训练模型。iPhone 工程的 HealthKit 读取层已准备好；自动同步、授权覆盖和真实采样仍需之后在 iPhone 上验证。"); Text("你确认产品后再安装 iPhone 版。健康数据在设备本地计算，不需要交给云端大模型。").foregroundStyle(.secondary) }
        }
    }
    private func load() { if let data = UserDefaults.standard.data(forKey: "previewJournalV2"), let value = try? JSONDecoder().decode([JournalEntry].self, from: data) { entries = value }; if let saved { energy = saved.energy; stress = saved.stress; tags = Set(saved.tags); note = saved.note } }
    private func persist() { if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: "previewJournalV2") } }
    private func metric(_ title: String, _ value: Double?, _ unit: String) -> some View { HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value.map { String(format: "%.1f %@", $0, unit) } ?? "暂无记录").monospacedDigit() }.font(.subheadline) }
    private func panel<C: View>(@ViewBuilder _ content: () -> C) -> some View { VStack(alignment: .leading, spacing: 15, content: content).frame(maxWidth: .infinity, alignment: .leading).padding(23).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20)) }
}
