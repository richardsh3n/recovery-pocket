import Charts
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class IntegratedJournal: ObservableObject {
  @Published private(set) var records = IntegratedRecords()
  @Published private(set) var demoRecords = IntegratedRecords()
  @Published var error: String?
  @Published private(set) var revision = 0
  @Published private(set) var recoveryReport:ManualRecoveryReport?
  @Published private(set) var restoring=false
  private var blocked = false
  private var directory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("RecoveryPocket")
  }
  private var url: URL { directory.appendingPathComponent("integrated-v1.json") }
  var backupDirectory:URL {directory}
  init() { reload() }
  func reload() {
    do {
      if let raw=try ManualRecordTransaction.read(from:url) {
        let d = try JSONDecoder().decode(IntegratedRecords.self, from:raw)
        guard d.schemaVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }
        records = d
      } else {records=IntegratedRecords()}
      recoveryReport=ManualRecordTransaction.lastRecovery(in:directory)
      blocked = false
      error = nil
      revision += 1
    } catch {
      blocked = true
      self.error = (error as? ManualRestoreError)?.errorDescription ?? "已有计划和餐次暂时无法读取，原文件已保留。"
    }
  }
  func visible(_ demo: Bool) -> IntegratedRecords { demo ? demoRecords : records }
  @discardableResult func save(_ value: IntegratedRecords, demo: Bool) -> Bool {
    if demo {
      demoRecords = value
      error = nil
      revision += 1
      return true
    }
    guard !blocked,!restoring else {error="记录正在恢复或尚未核验，请稍后重试。"; return false }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try ManualRecordTransaction.write(try JSONEncoder().encode(value),to:url)
      records = value
      error = nil
      revision += 1
      return true
    } catch {
      self.error = "修改未保存，请解锁后重试。"
      return false
    }
  }
  @discardableResult func addAction(title: String, evidence: String, demo: Bool) -> Bool {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return false }
    var data = visible(demo)
    data.actions.append(
      PocketAction(
        createdAt: Date(), title: String(title.prefix(500)), evidence: String(evidence.prefix(4000))
      ))
    guard save(data, demo: demo) else { return false }
    publish(demo: demo)
    return true
  }
  func update(_ action: PocketAction, demo: Bool) {
    var data = visible(demo)
    guard let i = data.actions.firstIndex(where: { $0.id == action.id }) else { return }
    data.actions[i] = action
    _ = save(data, demo: demo)
    publish(demo: demo)
  }
  func publish(demo: Bool) {
    let action = visible(demo).actions.filter {
      Calendar.current.isDateInToday($0.createdAt) && $0.completedAt == nil
    }.last
    WatchBridge.shared.actionTitle = action?.title
    WatchBridge.shared.actionDate = action?.createdAt
    WatchBridge.shared.publishHealth(WatchBridge.shared.status)
  }
  func saveMeal(_ meal: PhotoMeal, demo: Bool) -> Bool {
    var data = visible(demo)
    guard let rows = PhotoFoodEngine.merged(data.meals, incoming: meal, now: Date()) else {
      error = "该餐次版本已存在或数据无效；没有重复添加。"
      return false
    }
    data.meals = rows
    return save(data, demo: demo)
  }
  func backup(experience: PocketExperience) throws -> PocketBackup {
    let energyURL = directory.appendingPathComponent("energy-budget-manual.json")
    guard !restoring,(experience.demo || (!blocked && !experience.recordsUnavailable)) else {throw ManualRestoreError.pendingCleanup}
    let raw=experience.demo ? nil:try ManualRecordTransaction.read(from:energyURL)
    let energy:[ManualEnergyEntry]=try raw.map{try JSONDecoder().decode([ManualEnergyEntry].self,from:$0)} ?? []
    return PocketBackup(
      createdAt: Date(), demo: experience.demo, events: experience.visibleEvents,
      records: visible(experience.demo), manualEnergy: energy)
  }
  func restore(_ backup: PocketBackup, experience: PocketExperience) async -> Bool {
    guard !restoring else{error="正在恢复，请稍候。";return false}
    guard backup.valid(now: Date()), backup.demo == experience.demo else {
      error = "备份格式或记录无效，或演示/真实模式不一致。"
      return false
    }
    if experience.demo {
      demoRecords = backup.records
      return experience.restoreEvents(backup.events)
    }
    guard !blocked, !experience.recordsUnavailable else {
      error = "现有记录尚未读取，暂不覆盖。"
      return false
    }
    restoring=true
    defer{restoring=false}
    let destinations = [
      directory.appendingPathComponent("events-v1.json"), url,
      directory.appendingPathComponent("energy-budget-manual.json"),
    ]
    do {
      let payload = [
        try JSONEncoder().encode(backup.events), try JSONEncoder().encode(backup.records),
        try JSONEncoder().encode(backup.manualEnergy),
      ]
      let files=Dictionary(uniqueKeysWithValues:zip(destinations,payload)),backupRoot=directory
      try await Task.detached(priority:.userInitiated){
        try ManualRecordTransaction.commit(files,beforeMutating:{originals in
          guard let snapshot=PocketBackupIO.snapshot(originals,now:Date()) else{throw ManualRestoreError.corruptJournal}
          _ = try PocketBackupIO.persist(snapshot,in:backupRoot,safety:true)
        })
      }.value
      reload()
      experience.reloadEvents()
      guard !blocked,!experience.recordsUnavailable else {
        error="记录已替换，但重新读取尚未完成；原恢复记录保留，请解锁后重新打开核验。"
        return false
      }
      publish(demo: false)
      return true
    } catch {
      self.error = "恢复未完成，文件已保留。"+((error as? ManualRestoreError)?.errorDescription ?? "请解锁后重新打开核验。")
      return false
    }
  }
}

struct IntegratedTodayCard: View {
  let headline: String
  @EnvironmentObject private var health: HealthStore
  @EnvironmentObject private var experience: PocketExperience
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var composer = false
  @AppStorage("sleepTarget") private var target = 8.0
  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { clock in
      let context = experience.coachContext(health, target: target, intent: "工作")
      let brief = context.brief(.today)
      VStack(alignment: .leading, spacing: 12) {
        DemoNote()
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 7) {
            Text("今天的重点").font(.caption.weight(.semibold)).foregroundStyle(PocketStyle.green)
            Text(headline).font(.system(size: 20, weight: .semibold)).fixedSize(
              horizontal: false, vertical: true)
          }
          Spacer(minLength: 12)
          VStack(alignment: .trailing, spacing: 2) {
            Text(context.battery.displayValue(at: clock.date).map(String.init) ?? "—")
              .font(.system(size: 38, weight: .light)).monospacedDigit().foregroundStyle(
                PocketStyle.green
              )
              .contentTransition(.numericText()).animation(
                reduceMotion ? nil : .snappy(duration: 0.25), value: context.battery.value)
            Text(context.battery.scoreMeaning.title+" /100").font(.system(size: 10)).fixedSize(horizontal:false,vertical:true).foregroundStyle(.secondary)
          }
        }
        ForEach(Array(brief.facts.filter { $0.key != "battery" }.prefix(2))) { fact in
          Text(fact.name + " · " + fact.value).font(.caption).foregroundStyle(.secondary).lineLimit(
            2)
        }
        HStack(spacing: 16) {
          Button {
            composer = true
          } label: {
            Text("记录精力").font(.subheadline.weight(.medium)).foregroundStyle(.white).padding(
              .horizontal, 16
            ).padding(.vertical, 10).background(PocketStyle.green, in: Capsule())
          }.buttonStyle(.plain)
          NavigationLink("计划") { ActionReviewView() }.font(.subheadline)
          Spacer(minLength: 0)
          NavigationLink {
            IntegratedHubView()
          } label: {
            Label("工作台", systemImage: "arrow.up.right").font(.subheadline)
          }
        }
      }.padding(18).background(Color.white, in: RoundedRectangle(cornerRadius: 22))
    }.sheet(isPresented: $composer) { EventComposer(defaultKind: "自评") }
  }
}
struct IntegratedHubView: View {
  var body: some View {
    List {
      Section {
        Text("把记录变成可回看的行动").font(.title2.weight(.semibold))
        Text("手机、手表和组件共用观测语义；实验模型与个人验证分开展示。").font(.caption).foregroundStyle(.secondary)
      }
      Section("数据与模型") {
        NavigationLink("数据就绪与设备检查") { IntegratedReadinessView() }
        NavigationLink("训练强度融合实验室") { FusionLabView() }
        NavigationLink("正式与影子模型对照") { PairedModelValidationView() }
        NavigationLink("个人验证中心") { PersonalValidationView() }
      }
      Section("每天的使用") {
        NavigationLink("睡眠片段与小睡") { SleepEpisodesView() }
        NavigationLink("训练反应档案") { TrainingDossierView() }
        NavigationLink("个人发现与周行动") { HabitInsightsView() }
        NavigationLink("计划与事后回访") { ActionReviewView() }
        NavigationLink("AI 健康教练") { PocketCoachView() }
      }
      Section("能量与记录") {
        NavigationLink("拍照饮食结果与餐次") { PhotoFoodView() }
        NavigationLink("能量收支") { EnergyBudgetView() }
        NavigationLink("备份与恢复") { PocketBackupView() }
      }
    }.scrollContentBackground(.hidden).background(PocketStyle.paper).navigationTitle("健康工作台")
      .toolbar(.visible, for: .navigationBar)
  }
}
struct IntegratedReadinessView: View {
  @EnvironmentObject private var health: HealthStore
  @EnvironmentObject private var experience: PocketExperience
  private var status: PocketStatus { experience.status(health) }
  var body: some View {
    List {
      Section("当前是否可用") {
        DemoNote()
        Text(
          IntegratedReadiness.note(
            status: status, readAt: experience.demo ? Date() : health.snapshot?.fetchedAt,
            failures: health.snapshot?.readFailures?.count ?? 0, now: Date()))
        LabeledContent(
          "观测", value: status.displayDate?.formatted(date: .abbreviated, time: .shortened) ?? "缺失")
        LabeledContent("模型", value: status.modelRevision ?? "尚无结果")
      }
      Section("逐项读取") {
        ForEach(health.snapshot?.coverage ?? []) { row in
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text(row.name)
              Spacer()
              Text("\(row.count) 条")
            }
            Text(
              row.readFailure
                ?? (row.lastSample?.formatted(date: .abbreviated, time: .shortened)
                  ?? "没有读到记录；不能区分未授权与无数据")
            ).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      Section {
        Button(health.busy ? "正在读取…" : "刷新健康数据") { Task { await health.refresh() } }.disabled(
          health.busy || experience.demo)
        NavigationLink("系统授权与来源") { HealthConnectionView() }
        Text("Ultra 一代与组件需要真实设备验收。刷新成功不代表手表已采集新记录，系统不保证持续更新。").font(.caption)
      }
    }.scrollContentBackground(.hidden).background(PocketStyle.paper).tint(PocketStyle.green).navigationTitle("数据就绪").toolbar(.visible, for: .navigationBar)
  }
}
struct PersonalValidationView: View {
  @EnvironmentObject private var experience: PocketExperience
  @State private var group = ""
  private var groups: [String] {
    Array(Set(FeedbackEngine.pairs(experience.visibleEvents, now: Date()).map(\.group))).sorted()
  }
  private var plotPairs: [FeedbackPair] {
    FeedbackEngine.pairs(experience.visibleEvents, now: Date()).filter {
      $0.group == (groups.contains(group) ? group : groups.first ?? "")
    }
  }
  private var report: PersonalValidation {
    PersonalValidationEngine.evaluate(
      events: experience.visibleEvents, group: groups.contains(group) ? group : groups.first ?? "",
      now: Date())
  }
  var body: some View {
    List {
      Section {
        DemoNote()
        Text("先保留预测，再检验体感").font(.title2.weight(.semibold))
        Text("每个本地日期取第一条有效配对，不把多次自评当成多个独立日期。不同模型版本分别评估。").font(.caption)
        if !groups.isEmpty {
          Picker("模型版本", selection: $group) { ForEach(groups, id: \.self) { Text($0.components(separatedBy:" / ").first ?? $0).tag($0) } }
        }
      }
      if !plotPairs.isEmpty {
        Section("分数与体感分布") {
          Chart(plotPairs) { pair in
            PointMark(x: .value("填写前分数", pair.prediction.value), y: .value("精力", pair.event.energy))
              .foregroundStyle(pair.needsReview ? PocketStyle.drain : PocketStyle.green).symbolSize(
                45)
          }.chartXScale(domain: 0...100).chartYScale(domain: 1...5).frame(height: 170)
          Text("每点是一条填写前配对，橙色为值得回看；统计仍按每天第一条计算。点数少不解释为趋势。").font(.caption).foregroundStyle(
            .secondary)
        }
      }
      Section("按时间向前比较") {
        LabeledContent("有效日期", value: "\(report.totalDays)")
        LabeledContent("较早训练日期", value: "\(report.trainingDays)")
        LabeledContent("最后独立检验日期", value: "\(report.testDays)")
        if let date = report.splitDate {
          Text("检验从 " + date.formatted(date: .abbreviated, time: .omitted) + " 开始")
        }
      }
      Section("精力1–5分的平均绝对误差") {
        metric("单调映射候选", report.modelMAE)
        metric("固定历史中位数", report.fixedMAE)
        metric("上次精力基线", report.previousMAE)
        Text(
          report.ready
            ? (report.improvesBaseline ? "本次候选误差更小，仍需后续新日期复核；没有自动启用。" : "候选未同时优于简单基线，保留现行结果。")
            : "需要至少21个不同日期的有效配对：较早14日用于拟合，最后7日仅检验。已有体感始终保留，不限制健康数据显示。"
        ).font(.caption)
      }
      Section {
        LabeledContent("检验期明显高估记录", value: "\(report.falseHigh)")
        Text("单调映射只是分数与体感的探索比较，不是身体电量校准或医学验证；不能把平均误差换成准确率。").font(.caption)
        NavigationLink("逐条回看") { FeedbackReviewView() }
      }
    }.scrollContentBackground(.hidden).background(PocketStyle.paper).tint(PocketStyle.green).navigationTitle("个人验证").onAppear { if group.isEmpty { group = groups.first ?? "" } }.toolbar(
      .visible, for: .navigationBar)
  }
  private func metric(_ name: String, _ value: Double?) -> some View {
    LabeledContent(name, value: value.map { String(format: "%.2f", $0) } ?? "等待数据")
  }
}
struct SleepEpisodesView: View {
  @EnvironmentObject private var health: HealthStore
  @EnvironmentObject private var experience: PocketExperience
  private var episodes: [SleepEpisode] {
    SleepEpisodeEngine.episodes(experience.wellnessData(health).intervals, now: Date())
  }
  var body: some View {
    List {
      Section {
        DemoNote()
        Text("按实际睡眠结束日期归属，保留午后醒来与小睡。相隔不超过90分钟的片段合为一次，时长只累计真正睡眠区间。").font(.subheadline)
        NavigationLink("今晚睡眠计划") { SleepPlanningView() }
      }
      ForEach(Array(episodes.suffix(20).reversed())) { episode in
        Section {
          HStack {
            Text(
              SleepEpisodeEngine.main(episodes, day: episode.end.addingTimeInterval(-0.001))?.id
                == episode.id ? "主要睡眠" : "其他睡眠 / 小睡")
            Spacer()
            Text(String(format: "%.1f 小时", episode.hours)).foregroundStyle(PocketStyle.green)
          }
          Text(
            episode.start.formatted(date: .abbreviated, time: .shortened) + " → "
              + episode.end.formatted(date: .abbreviated, time: .shortened)
          ).font(.caption)
          LabeledContent(
            "片段间空档",
            value: String(
              format: "%.0f 分钟",
              max(0, episode.end.timeIntervalSince(episode.start) / 60 - episode.hours * 60)))
          ForEach(episode.intervals, id: \.start) { span in
            Text(
              span.start.formatted(date: .omitted, time: .shortened) + " – "
                + span.end.formatted(date: .omitted, time: .shortened)
            ).font(.caption)
          }
        }
      }
      if episodes.isEmpty { Text("还没有睡眠起止记录；历史时长仍可在原页面回看。") }
      Text("空档不等于已确认觉醒，分期不用于随意加减恢复分。归属按本机当前时区重算，原始绝对时间保留。").font(.caption).foregroundStyle(
        .secondary)
    }.scrollContentBackground(.hidden).background(PocketStyle.paper).tint(PocketStyle.green).navigationTitle("睡眠片段").toolbar(.visible, for: .navigationBar)
  }
}
struct FusionLabView: View {
  @EnvironmentObject private var health: HealthStore
  @EnvironmentObject private var experience: PocketExperience
  private var doses: [TrainingDose] {
    TrainingDoseEngine.doses(
      workouts: experience.wellnessData(health).workouts, events: experience.visibleEvents,
      now: Date())
  }
  var body: some View {
    List {
      Section {
        DemoNote()
        Text("强度融合候选 · 未启用").font(.headline)
        NavigationLink("正式与影子模型对照") { PairedModelValidationView() }
        Text("按覆盖度用能量代理与心率代理加权替代单一活动项，不把两项直接叠加。75%/25%及心率单位换算是工程试验；不改写首页、Watch或组件分数。").font(
          .caption)
      }
      ForEach(doses) { dose in
        let contrast = TrainingDoseEngine.comparison(kcal: dose.workout.activeKcal,
          cardioMinutes: dose.cardio, coverage: dose.coverage)
        Section(dose.workout.title) {
          Text(dose.workout.start.formatted(date: .abbreviated, time: .shortened)).font(.caption)
          LabeledContent("训练来源", value: dose.workout.source)
          LabeledContent("心率覆盖", value: String(format: "%.0f%%", dose.coverage * 100))
          if let evidence = dose.workout.cardio {
            LabeledContent("心率来源", value: evidence.source)
          }
          LabeledContent(
            "实际心率相对负荷", value: dose.cardio.map { String(format: "%.1f", $0) } ?? "无可比参考")
          LabeledContent("仅能量代理", value: contrast.energyOnly.map { String(format:"%.2f 点", $0) } ?? "缺少输入")
          LabeledContent(
            "候选活动项",
            value: contrast.candidate.map { String(format: "%.2f 点（试验）", $0) } ?? "缺少输入")
          if let delta = contrast.deltaFromEnergy {
            LabeledContent("相对仅能量变化", value: String(format:"%+.2f 点",delta))
          }
        }
      }
      if doses.isEmpty { Text("同步训练后可比较；不会伪造训练来展示候选。") }
      NavigationLink("查看正式模型的个人验证") { PersonalValidationView() }
      Text("下方V24单次训练活动项只是公式对照。新版影子回放仅在几乎完整训练且心率覆盖充分的时段运行，并随自评冻结独立预测；请在双模型对照页检验。训练与心率来源分别展示，不能据此认定因果或同一设备。").font(.caption)
      Text("下方活动项不改写全天账本。新版影子回放与正式输出独立；来源、覆盖或个人检验不足时，不自动晋升为正式模型。").font(.caption)
    }.scrollContentBackground(.hidden).background(PocketStyle.paper).tint(PocketStyle.green).navigationTitle("算法实验室").toolbar(.visible, for: .navigationBar)
  }
}
struct TrainingDossierView: View {
  @EnvironmentObject private var health: HealthStore
  @EnvironmentObject private var experience: PocketExperience
  @State private var chosen: PocketWorkout?
  private var doses: [TrainingDose] {
    Array(
      TrainingDoseEngine.doses(
        workouts: experience.wellnessData(health).workouts, events: experience.visibleEvents,
        now: Date()
      ).suffix(20).reversed())
  }
  var body: some View {
    List {
      Section {
        DemoNote()
        NavigationLink("次夜恢复与当天曲线") { TrainingRecoveryView() }
      }
      if doses.contains(where: { $0.cardio != nil }) {
        Section("已观测心率负荷对照") {
          Chart(doses) { dose in
            if let cardio = dose.cardio {
              PointMark(x: .value("训练分钟", dose.workout.duration / 60), y: .value("相对负荷分钟", cardio))
                .foregroundStyle(by: .value("训练类型", dose.workout.title)).symbolSize(45)
            }
          }.frame(height: 160)
          Text("横轴为训练时长，纵轴为实际采样支持的心率相对负荷；缺测会低估，不等于肌肉负荷或身体电量扣分。").font(.caption).foregroundStyle(
            .secondary)
        }
      }
      ForEach(doses) { dose in
        Section {
          Text(dose.workout.title).font(.headline)
          Text(dose.workout.start.formatted(date: .abbreviated, time: .shortened)).font(.caption)
          LabeledContent("训练时长", value: String(format: "%.0f 分钟", dose.workout.duration / 60))
          LabeledContent("心率覆盖", value: String(format: "%.0f%%", dose.coverage * 100))
          LabeledContent(
            "整次训练体感负荷",
            value: dose.effort?.sessionLoad.map { String(format: "%.0f 单位", $0) } ?? "尚未关联记录")
          Button("记录这次训练体感") { chosen = dose.workout }
        }
      }
      if doses.isEmpty { Text("尚未同步已完成训练。手动训练可在记录中保留，之后明确关联。") }
      Text("不同训练类型分别回看。肌肉疲劳不等于有氧心率负荷，单次变化不解释为训练因果。").font(.caption)
    }.scrollContentBackground(.hidden).background(PocketStyle.paper).tint(PocketStyle.green).navigationTitle("训练反应档案").toolbar(.visible, for: .navigationBar).sheet(item: $chosen) {
      workout in EventComposer(defaultKind: "训练", workout: workout)
    }
  }
}
struct HabitInsightsView: View {
  @EnvironmentObject private var experience: PocketExperience
  @EnvironmentObject private var journal: IntegratedJournal
  @State private var composer = false
  private var rows: [HabitComparison] {
    HabitEvidenceEngine.compare(events: experience.visibleEvents, now: Date())
  }
  var body: some View {
    List {
      Section {
        DemoNote()
        Text("挑一个习惯，连续记一段时间").font(.headline)
        Text("回看过去 56 天内，在明确记录「有」和「无」的日子里，你的平均精力是否不同。同一天多条记录会合成当天的平均精力，每个习惯以当天最后一次明确填写为准。").font(.subheadline)
        Button("记录今天的习惯与精力") { composer = true }
        NavigationLink("完整七天回顾") { WeeklyReviewView() }
      }
      ForEach(rows) { row in
        Section(HabitEvidenceEngine.names[row.key] ?? row.key) {
          LabeledContent("明确记录有 / 无", value: "\(row.yesDays) / \(row.noDays) 天")
          if let difference = row.difference {
            LabeledContent("平均精力差（有 − 无）", value: String(format: "%+.2f / 5", difference))
            Text("正值表示明确填「有」的日子平均精力更高，负值表示更低。一起发生的训练、作息等变化也可能影响结果。").font(.caption).foregroundStyle(.secondary)
          } else {
            Text("要显示两组平均差，仍需补齐「有」\(max(0, 5 - row.yesDays)) 天和「无」\(max(0, 5 - row.noDays)) 天的明确记录。")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      Section("下周只试一个改变") {
        Button("加入计划：固定一个晚间放松窗口") {
          journal.addAction(
            title: "固定一个晚间放松窗口", evidence: "用户选择的习惯试行，不是模型证明的改善方法", demo: experience.demo)
        }
        NavigationLink("回访计划有没有帮助") { ActionReviewView() }
      }
    }.scrollContentBackground(.hidden).background(PocketStyle.paper).tint(PocketStyle.green).navigationTitle("习惯与精力对照").toolbar(.visible, for: .navigationBar).sheet(isPresented: $composer) {
      EventComposer(defaultKind: "自评")
    }
  }
}
struct ActionReviewView: View {
  @EnvironmentObject private var experience: PocketExperience
  @EnvironmentObject private var journal: IntegratedJournal
  @State private var title = ""
  @FocusState private var editing: Bool
  var body: some View {
    List {
      Section {
        DemoNote()
        TextField("给自己一个具体、轻量的计划", text: $title).focused($editing).submitLabel(.done).onSubmit {
          editing = false
        }
        Button("保存计划") {
          if journal.addAction(title: title, evidence: "用户自行安排", demo: experience.demo) {
            editing = false
            title = ""
          }
        }
        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      ForEach(journal.visible(experience.demo).actions.sorted { $0.createdAt > $1.createdAt }) {
        action in
        Section {
          Text(action.title).font(.headline)
          Text(action.evidence).font(.caption).foregroundStyle(.secondary)
          Button(action.completedAt == nil ? "标记已完成" : "已完成 · 撤销完成") {
            var row = action
            row.completedAt = row.completedAt == nil ? Date() : nil
            row.helpful = nil
            journal.update(row, demo: experience.demo)
          }
          if action.completedAt != nil {
            Picker(
              "实际有帮助吗？",
              selection: Binding(
                get: { action.helpful ?? 0 },
                set: { value in
                  var row = action
                  row.helpful = value == 0 ? nil : value
                  journal.update(row, demo: experience.demo)
                })
            ) {
              Text("尚未回访").tag(0)
              ForEach(1...5, id: \.self) { Text("\($0)/5").tag($0) }
            }
          }
        }
      }
      if let error = journal.error { Text(error).foregroundStyle(PocketStyle.drain) }
    }.scrollContentBackground(.hidden).background(PocketStyle.paper).tint(PocketStyle.green).navigationTitle("计划与回访").toolbar(.visible, for: .navigationBar)
  }
}
struct PhotoFoodView: View {
  @EnvironmentObject private var experience: PocketExperience
  @EnvironmentObject private var journal: IntegratedJournal
  @State private var text = ""
  @State private var draft: PhotoMeal?
  @State private var notice = ""
  @State private var editingMeal: PhotoMeal?
  var body: some View {
    List {
      Section {
        DemoNote()
        Text("记录摄入，和当天消耗一起回看").font(.headline)
        Text("先记录食物与份量，再确认热量范围。照片分析尚未接通，可以先手动记餐。").font(.caption).foregroundStyle(.secondary)
        Button("手动记一餐") {
          editingMeal = PhotoMeal(
            id: UUID(), revision: 1, date: Date(), title: "", kcal: 0, lower: 0, upper: 0,
            notes: "手动估计；未使用照片模型", confirmed: false)
        }
      }
      Section {
        DisclosureGroup("导入饮食分析结果") {
          DemoNote()
          Text("粘贴你自己的饮食 App / LLM 输出的餐次 JSON，先预览再确认。当前没有连接图像模型，不会自动上传照片或伪称已经识别。").font(.caption)
          TextEditor(text: $text).frame(height: 130).accessibilityLabel("餐次 JSON")
          Button("校验并预览") {
            draft = PhotoFoodEngine.parse(Data(text.utf8), now: Date())
            notice = draft == nil ? "格式、日期、估算范围或版本无效。" : "已校验，确认后才计入餐次。"
          }
          Button("填入接口示例") {
            let meal = PhotoMeal(
              id: UUID(), revision: 1, date: Date(), title: "示例餐次（请修改为实际食物）", kcal: 600, lower: 450,
              upper: 800, notes: "份量和烹调油不确定；此示例不是照片识别结果", confirmed: false)
            text =
              String(
                data: (try? JSONEncoder.iso.encode(MealEnvelope(schemaVersion: 1, meal: meal)))
                  ?? Data(), encoding: .utf8) ?? ""
          }
          Text(notice).font(.caption)
        }
      }
      if let meal = draft {
        Section("确认前检查") {
          Text(meal.title)
          Text(String(format: "%.0f kcal · %.0f–%.0f", meal.kcal, meal.lower, meal.upper))
          Text(meal.notes).font(.caption)
          Button("确认并保存餐次") {
            var saved = meal
            saved.confirmed = true
            if journal.saveMeal(saved, demo: experience.demo) {
              draft = nil
              notice = "餐次已保存，同一ID只保留较新版本。"
            } else {
              notice = journal.error ?? "保存失败"
            }
          }
        }
      }
      Section("已确认餐次") {
        if journal.visible(experience.demo).meals.filter(\.confirmed).isEmpty {
          Text("还没有确认餐次。未记录不等于今天摄入为零。").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(
          journal.visible(experience.demo).meals.filter(\.confirmed).sorted { $0.date > $1.date }
        ) { meal in
          VStack(alignment: .leading, spacing: 6) {
            Text(meal.title)
            Button("修改这餐的份量或热量") {
              var edit = meal
              edit.revision += 1
              editingMeal = edit
            }
            Text(meal.date.formatted(date: .abbreviated, time: .shortened))
            Text(
              String(
                format: "%.0f kcal · %.0f–%.0f · v%d", meal.kcal, meal.lower, meal.upper,
                meal.revision)
            ).font(.caption)
          }
        }
        NavigationLink("选择餐次来源并查看收支") { EnergyBudgetView() }
      }
    }.sheet(item: $editingMeal) { ManualMealEditor(meal: $0) }
      .scrollContentBackground(.hidden).background(PocketStyle.paper).tint(PocketStyle.green).navigationTitle("饮食餐次").toolbar(.visible, for: .navigationBar)
  }
}
struct PocketBackupView: View {
  @EnvironmentObject private var experience: PocketExperience
  @EnvironmentObject private var journal: IntegratedJournal
  @State private var exportURL: URL?
  @State private var importing = false
  @State private var pending: PocketBackup?
  @State private var notice = ""
  @State private var preparing=false
  @State private var qaFixtureLoaded=false
  @State private var backups:[LocalPocketBackup]=[]
  @State private var backupHistoryProblem:String?
  var body: some View {
    List {
      if qaFixtureLoaded {Section("隔离模拟器验收") {Text("这里使用合成的自评、计划、餐次和能量记录；确认只会替换当前验收模拟器的本机记录。").font(.caption)}}
      Section {
        DemoNote()
        Text("导出自评、习惯、训练体感、计划、餐次和手动能量记录。不包含健康原始样本、AI密钥或配对凭证。文件包含个人记录，请自行保管。").font(.caption)
        Text("若上次恢复被打断，会先核验并处理，再读取本机记录。单份备份上限8 MB。").font(.caption).foregroundStyle(.secondary)
        if preparing {ProgressView("正在检查备份，请稍候")}
        if let error=journal.error,!experience.demo {Text(error).font(.caption).foregroundStyle(PocketStyle.drain)}
        Button("生成本机备份") {
          preparing=true
          Task {
            defer{preparing=false}
            do {
              let backup=try journal.backup(experience:experience)
              guard backup.valid(now:Date()) else{notice="现有记录未通过校验，暂不导出。";return}
              let root=journal.backupDirectory
              let url=try await Task.detached(priority:.userInitiated){try PocketBackupIO.persist(backup,in:root)}.value
              guard experience.demo==backup.demo else{exportURL=nil;notice="模式已变化，请重新生成备份。";return}
              exportURL=url;loadBackups();notice="备份已保存在本机历史；只有你选择导出后才离开App。"
            }catch {notice=(error as? ManualRestoreError)?.errorDescription ?? "生成未完成，原记录已保留。"}
          }
        }.disabled(preparing)
        if let url = exportURL { ShareLink("导出备份文件", item: url) }
        Button("选择备份并检查") { importing = true }.disabled(preparing)
        Text(notice).font(.caption)
      }
      if !experience.demo,let report=journal.recoveryReport {
        Section("上次恢复处理") {
          Text(report.outcome == .rolledBack ? "未完成的恢复已回滚，保留恢复前记录。":"恢复已完整提交，新记录已核验。")
          Text(report.date.formatted(date:.abbreviated,time:.shortened)).font(.caption)
          LabeledContent("核验文件",value:"\(report.files) 份")
          if report.cleanupPending {Text("文件整理待完成，暂不修改；解锁后重新打开重试。").font(.caption).foregroundStyle(PocketStyle.drain)}
        }
      }
      Section("本机备份历史") {
        if let problem=backupHistoryProblem {Text(problem).font(.caption).foregroundStyle(PocketStyle.drain)}
        if backups.isEmpty,backupHistoryProblem==nil {Text("还没有本机备份。手动生成和恢复前安全副本会保存在这里。").font(.caption)}
        ForEach(Array(backups.prefix(5))) { item in
          VStack(alignment:.leading,spacing:8) {
            Text(item.safety ? "恢复前安全备份":"手动备份").font(.headline)
            Text(item.createdAt == .distantPast ? "未标注创建时间":item.createdAt.formatted(date:.abbreviated,time:.shortened)).font(.caption)
            Text(ByteCountFormatter.string(fromByteCount:Int64(item.bytes),countStyle:.file)).font(.caption).foregroundStyle(.secondary)
            HStack {
              Button("检查并预览"){inspectBackup(item.url)}.buttonStyle(.borderless).disabled(preparing || backupHistoryProblem != nil)
              Spacer()
              ShareLink("导出",item:item.url).buttonStyle(.borderless).disabled(backupHistoryProblem != nil)
            }
          }
        }
        Text("显示最近5份，共\(backups.count)份。重要备份请自行导出；卸载App可能移除本机历史。").font(.caption).foregroundStyle(.secondary)
      }
      if let backup = pending {
        Section("恢复预览") {
          LabeledContent(
            "自评 / 计划 / 餐次",
            value:
              "\(backup.events.count) / \(backup.records.actions.count) / \(backup.records.meals.count)"
          )
          Text("恢复前会自动保存当前记录的安全副本；若保存失败，就不会替换。").font(.caption)
          Button("确认用此备份替换本机记录", role: .destructive) {
            Task {
              if await journal.restore(backup, experience:experience) {
                pending=nil
                notice="已恢复并重新核验；能量收支会读取新记录。"
              } else {notice=journal.error ?? "恢复未完成"}
              loadBackups()
            }
          }.disabled(preparing)
        }
      }
    }.scrollContentBackground(.hidden).background(PocketStyle.paper).tint(PocketStyle.green).navigationTitle("备份与恢复").toolbar(.visible, for: .navigationBar).onAppear{prepareQA();loadBackups()}.onChange(of:journal.revision){_,_ in loadBackups()}.onChange(of:experience.demo){_,_ in loadBackups()}.fileImporter(
      isPresented: $importing, allowedContentTypes: [.json]
    ) { result in
      preparing=true
      Task {
        defer{preparing=false}
        do {
          let url=try result.get(),access=url.startAccessingSecurityScopedResource()
          defer{if access {url.stopAccessingSecurityScopedResource()}}
          let backup=try await Task.detached(priority:.userInitiated){
            try PocketBackupIO.decoded(ManualRecordTransaction.readBackup(from:url))
          }.value
          guard backup.valid(now:Date()),backup.demo==experience.demo else{notice="备份无效或演示/真实模式不一致。";return}
          pending=backup;notice="校验通过，尚未修改本机记录。"
        } catch {notice=(error as? ManualRestoreError)?.errorDescription ?? "无法读取该备份，原记录已保留。"}
      }
    }
  }
  private func loadBackups(){
    let result=PocketBackupIO.listing(in:journal.backupDirectory,demo:experience.demo)
    backupHistoryProblem=result.problem
    if result.problem==nil {backups=result.files}
  }
  private func inspectBackup(_ url:URL) {
    preparing=true
    Task {
      defer{preparing=false}
      do {
        let backup=try await Task.detached(priority:.userInitiated){try PocketBackupIO.decoded(ManualRecordTransaction.readBackup(from:url))}.value
        guard backup.valid(now:Date()),backup.demo==experience.demo else{notice="备份无效或模式不一致。";return}
        pending=backup;notice="本机备份已检查，确认前不会修改记录。"
      }catch {notice="检查未完成，原记录与备份均保留。"}
    }
  }
  private func prepareQA() {
    #if targetEnvironment(simulator)
    guard !qaFixtureLoaded,ProcessInfo.processInfo.arguments.contains("--pocket-restore-ui-qa"),!experience.demo else{return}
    qaFixtureLoaded=true
    let now=Date(),day=Calendar.current.startOfDay(for:now)
    let event=PocketEvent(date:now,kind:"自评",energy:4,note:"恢复后的验收记录（合成记录）",recordedAt:now)
    let plan=PocketAction(createdAt:now,title:"恢复后的验收计划（合成记录）",evidence:"隔离模拟器验收")
    let meal=PhotoMeal(id:UUID(),revision:1,date:now,title:"恢复后的验收餐次（合成记录）",kcal:500,lower:400,upper:600,notes:"非真实摄入",confirmed:true)
    let energy=ManualEnergyEntry(id:UUID(),day:day,recordedAt:now,intake:1200,foodComplete:true,scaleBMR:1500)
    pending=PocketBackup(createdAt:now,demo:false,events:[event],records:IntegratedRecords(actions:[plan],meals:[meal]),manualEnergy:[energy])
    notice="模拟器验收备份已准备，尚未修改本机记录。"
    #endif
  }

}

private struct ManualMealEditor: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var experience: PocketExperience
  @EnvironmentObject private var journal: IntegratedJournal
  let meal: PhotoMeal
  @State private var title = ""
  @State private var kcal = ""
  @State private var lower = ""
  @State private var upper = ""
  @State private var notes = ""
  @State private var date = Date()
  @State private var notice = ""
  private func save() {
    guard let value = Double(kcal.replacingOccurrences(of: ",", with: ".")),
      let lo = Double(lower.replacingOccurrences(of: ",", with: ".")),
      let hi = Double(upper.replacingOccurrences(of: ",", with: "."))
    else {
      notice = "请填写热量及上下限。"
      return
    }
    var result = meal
    result.date = date
    result.title = title
    result.kcal = value
    result.lower = lo
    result.upper = hi
    result.notes = notes
    result.confirmed = true
    guard result.valid(now: Date()) else {
      notice = "检查餐次名称、时间和范围：下限≤估计值≤上限。"
      return
    }
    if journal.saveMeal(result, demo: experience.demo) {
      dismiss()
    } else {
      notice = journal.error ?? "未保存"
    }
  }
  var body: some View {
    NavigationStack {
      Form {
        Section("实际吃了什么") {
          TextField("餐次与份量", text: $title)
          DatePicker("进食时间", selection: $date, in: ...Date())
          TextField("估计热量 kcal", text: $kcal).keyboardType(.decimalPad)
          TextField("估计下限 kcal", text: $lower).keyboardType(.decimalPad)
          TextField("估计上限 kcal", text: $upper).keyboardType(.decimalPad)
          TextField("份量与烹调不确定性", text: $notes, axis: .vertical)
        }
        Section {
          Text("这是手动估计；修改同一餐会替换旧版本，不重复增加摄入。热量范围仅代表食物输入的不确定性。").font(.caption)
          if !notice.isEmpty { Text(notice).foregroundStyle(PocketStyle.drain) }
          Button("保存这餐", action: save)
          Button("取消记录") { dismiss() }
        }
      }.scrollContentBackground(.hidden).background(PocketStyle.paper).scrollDismissesKeyboard(.interactively)
        .navigationTitle("记录一餐").toolbar(.visible, for: .navigationBar)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) { Button("确认保存", action: save) }
        }
    }.onAppear {
      title = meal.title
      date = meal.date
      notes = meal.notes
      if meal.kcal > 0 {
        kcal = String(format: "%.0f", meal.kcal)
        lower = String(format: "%.0f", meal.lower)
        upper = String(format: "%.0f", meal.upper)
      }
    }
  }
}

struct PairedModelValidationView:View {
  @EnvironmentObject private var health:HealthStore
  @EnvironmentObject private var experience:PocketExperience
  @State private var group=""
  @State private var composer=false
  private var groups:[String] {Array(Set(PairedModelValidationEngine.pairs(experience.visibleEvents,now:Date()).map{$0.comparison.group})).sorted()}
  private var report:PairedModelValidation {PairedModelValidationEngine.evaluate(events:experience.visibleEvents,group:groups.contains(group) ? group:groups.first ?? "",now:Date())}
  var body:some View {
    let result=report
    List {
      Section {
        DemoNote()
        Text("让同一份体感检验两套结果").font(.title2.weight(.semibold))
        Text("填写前冻结两套结果，之后用相同日期检验。候选只用于对照，当前电量照常显示。").font(.caption)
        Button("记录此刻精力"){composer=true}
      }
      Section("当前可配对结果") {
        TimelineView(.periodic(from:.now,by:60)) { context in
          if let replay=experience.shadow(health),replay.baseline.isFresh(at:context.date),replay.candidate.isFresh(at:context.date) {
            VStack(alignment:.leading,spacing:12) {
              HStack {
                score("正式模型",replay.baseline.displayValue(at:context.date),color:PocketStyle.green)
                Spacer()
                score("影子候选",replay.candidate.displayValue(at:context.date),color:PocketStyle.drain)
              }
              Text("同一观测："+(replay.baseline.measuredAt ?? replay.readAt).formatted(date:.abbreviated,time:.shortened)).font(.caption)
              Text(String(format:"本段 %d 个替换时段 · %.0f 分钟实际心率覆盖",replay.decisions.count,replay.coveredMinutes)).font(.caption)
              DisclosureGroup("计算依据") {
                Text("仅替换训练占比至少95%、实际心率覆盖至少80%的时段。热量缺测或来源不一致时保留正式计算。").font(.caption)
                Text("输入摘要 "+replay.inputDigest.prefix(12)).font(.caption2).foregroundStyle(.secondary)
                Text("影子结果不发送到手表、组件或AI教练；不自动启用。").font(.caption)
              }
              Text("差值是模型假设的差别，不是已证实的身体变化。").font(.caption).foregroundStyle(.secondary)
            }
          } else {
            Text(availabilityMessage(at:context.date)).font(.caption)
          }
        }
      }
      if let inspection=experience.shadowInspection(health),let audit=inspection.audit {
        Section("训练为什么采用或跳过") { ShadowCoverageView(audit:audit) }
      }
      if !groups.isEmpty {
        Section {
          Picker("对照版本",selection:$group){ForEach(groups,id:\.self){value in Text("正式与影子 v1 · "+(value.components(separatedBy:" / ").first ?? value)).tag(value)}}
          Text("不同版本分组保留；下方两套结果只用这一组共同配对日期。").font(.caption)
        }
      }
      Section("共同日期与时间隔离") {
        LabeledContent("有效配对日期",value:"\(result.rows.count)")
        LabeledContent("较早拟合日期",value:"\(result.baseline.trainingDays)")
        LabeledContent("较晚独立检验日期",value:"\(result.baseline.testDays)")
        if let start=result.baseline.splitDate {Text("检验起于 "+start.formatted(date:.abbreviated,time:.omitted)).font(.caption)}
        Text("每个本地日期只取第一条有效双模型自评；编辑过的结果单列排除。至少21个日期后，较早日期分别拟合，最后7日只检验。").font(.caption)
      }
      if result.ready,let split=result.baseline.splitDate {
        Section("检验期：预测精力与实际体感") {
          DemoNote()
          Chart {
            ForEach(result.rows.filter{$0.event.date>=split}) { row in
              PointMark(x:.value("日期",row.event.date),y:.value("精力1–5",Double(row.event.energy))).foregroundStyle(by:.value("系列","实际体感")).symbol(by:.value("系列","实际体感")).symbolSize(100)
              if let value=PersonalValidationEngine.predicted(Double(row.comparison.baseline.value),blocks:result.baseline.blocks) {
                PointMark(x:.value("日期",row.event.date),y:.value("精力1–5",value)).foregroundStyle(by:.value("系列","正式模型")).symbol(by:.value("系列","正式模型")).symbolSize(45)
              }
              if let value=PersonalValidationEngine.predicted(Double(row.comparison.candidate.value),blocks:result.candidate.blocks) {
                PointMark(x:.value("日期",row.event.date),y:.value("精力1–5",value)).foregroundStyle(by:.value("系列","影子候选")).symbol(by:.value("系列","影子候选")).symbolSize(45)
              }
            }
          }.chartYScale(domain:1...5).chartForegroundStyleScale(["实际体感":PocketStyle.ink,"正式模型":PocketStyle.green,"影子候选":PocketStyle.drain]).chartSymbolScale(["实际体感":BasicChartSymbolShape.cross,"正式模型":.circle,"影子候选":.diamond]).frame(height:180)
          Text("模型分数先用较早日期映射到精力1–5分，两套映射独立拟合，较晚体感没有用于调参。").font(.caption)
        }
      }
      Section("同一检验集的平均绝对误差") {
        metric("正式模型映射",result.baseline.modelMAE)
        metric("影子候选映射",result.candidate.modelMAE)
        metric("固定历史精力中位数",result.baseline.fixedMAE)
        metric("上次精力",result.baseline.previousMAE)
        if let delta=result.candidateMAEImprovement {
          Text(String(format:"候选相对正式误差变化：%+.2f 分（负值更好）",-delta)).font(.caption)
        } else {Text("数据不足时不显示胜负，也不把误差换算为准确率。").font(.caption)}
        Text("相同日期的探索性比较仍受自评、样本量和使用情境影响；不会自动启用候选。").font(.caption).foregroundStyle(.secondary)
      }
      Section("没有进入这组对照的记录") {
        ForEach(result.exclusions.keys.sorted(),id:\.self){key in LabeledContent(key,value:"\(result.exclusions[key] ?? 0)")}
        if result.exclusions.isEmpty {Text("暂无排除记录。").font(.caption)}
        Text("无法双配对的体感仍完整保留，也不影响现有健康数据与正式模型回看。").font(.caption)
      }
      Section("冻结后的配对") {
        ForEach(Array(result.rows.suffix(14).reversed())) { row in
          VStack(alignment:.leading,spacing:6) {
            Text(row.event.date.formatted(date:.abbreviated,time:.shortened))
            Text("正式 \(row.comparison.baseline.value) · 影子 \(row.comparison.candidate.value) · 体感 \(row.event.energy)/5").font(.caption)
            Text(row.comparison.inputDigest.prefix(12)+" · 填写前冻结").font(.caption2).foregroundStyle(.secondary)
          }
        }
      }
    }.scrollContentBackground(.hidden).background(PocketStyle.paper).tint(PocketStyle.green)
      .navigationTitle("双模型对照").toolbar(.visible,for:.navigationBar)
      .onAppear{if group.isEmpty {group=groups.first ?? ""}}
      .sheet(isPresented:$composer){EventComposer(defaultKind:"自评")}
  }
  private func availabilityMessage(at date:Date)->String {
    guard let inspection=experience.shadowInspection(health) else{return ShadowReplayAvailability.noLedger.message}
    if let audit=inspection.audit,date.timeIntervalSince(audit.observedAt)>7200 {return ShadowReplayAvailability.stale.message}
    return inspection.availability.message
  }
  private func metric(_ label:String,_ value:Double?)->some View {LabeledContent(label,value:value.map{String(format:"%.2f",$0)} ?? "等待共同日期")}
  private func score(_ title:String,_ value:Int?,color:Color)->some View {
    VStack(alignment:.leading,spacing:6){Text(title).font(.caption);Text(value.map(String.init) ?? "—").font(.system(size:38,weight:.medium)).monospacedDigit().foregroundStyle(color)}
  }
}

/// Renders an immutable, worker-produced audit. It never replays a health model in body.
private struct ShadowCoverageView:View {
    var audit:ActivityFusionAudit
    private var entries:[ActivityFusionAssessment] {Array(audit.entries.suffix(12))}
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("本连续段的已记录训练").font(.headline)
            HStack(alignment:.firstTextBaseline) {
                metric("训练时长",audit.trainingMinutes)
                Spacer()
                metric("用于影子对照的心率",audit.eligibleMinutes)
            }
            Text("起于 "+audit.segmentStart.formatted(date:.abbreviated,time:.shortened)+" · 截至观测 "+audit.observedAt.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)
            if entries.isEmpty {
                Text("本段尚无可检查的训练时段；不把未记录的训练算作0消耗。").font(.caption)
            } else {
                Chart(entries) { entry in
                    BarMark(xStart:.value("开始",entry.start),xEnd:.value("结束",entry.end),y:.value("时段","训练覆盖"),height:.ratio(0.5))
                        .foregroundStyle(entry.reason == .eligible ? PocketStyle.green:PocketStyle.drain.opacity(0.5))
                        .accessibilityLabel(entry.start.formatted(date:.abbreviated,time:.shortened)+" "+entry.reason.title)
                }.chartYAxis(.hidden).frame(height:74)
                HStack(spacing:18){Label("采用",systemImage:"circle.fill").foregroundStyle(PocketStyle.green);Label("跳过",systemImage:"circle.fill").foregroundStyle(PocketStyle.drain)}.font(.caption)
                ForEach(audit.reasons.keys.sorted(by:{$0.rawValue<$1.rawValue}),id:\.rawValue) { reason in
                    LabeledContent(reason.title,value:"\(audit.reasons[reason] ?? 0) 段").font(.caption)
                }
                ForEach(entries.reversed()) { entry in
                    DisclosureGroup {
                        Text(entry.reason.detail).font(.caption).foregroundStyle(.secondary)
                        LabeledContent("已记录训练",value:entry.trainingMinutes.map{String(format:"%.1f 分钟",$0)} ?? "时长待核验").font(.caption)
                        LabeledContent("通过心率对校验的覆盖",value:entry.coveredMinutes.map{String(format:"%.1f 分钟",$0)} ?? "未在此规则中核验").font(.caption)
                        if let decision=entry.decision {Text(String(format:"活动项工程对照：正式 %.2f → 影子 %.2f 点",decision.energyDrain,decision.replacementDrain)).font(.caption)}
                    } label: {
                        VStack(alignment:.leading,spacing:4){Text(entry.start.formatted(date:.abbreviated,time:.shortened)+" – "+entry.end.formatted(date:.omitted,time:.shortened)).font(.caption);Text(entry.reason.title).font(.subheadline).foregroundStyle(entry.reason == .eligible ? PocketStyle.green:PocketStyle.drain)}
                    }
                }
                Text("图与明细显示最近12个训练时段，原因计数覆盖本连续段。橙色是未采用的时段，不代表没有训练或热量。整点统计可能混合训练与其他活动，尚不能公平覆盖所有训练开始时间。").font(.caption).foregroundStyle(.secondary)
            }
            Text("心率覆盖与训练时长是不同口径；跳过时仍保留正式计算。此页不启用候选，也不改变你过去的冻结自评。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func metric(_ title:String,_ value:Double)->some View {
        VStack(alignment:.leading,spacing:5){Text(title).font(.caption).foregroundStyle(.secondary);Text(String(format:"%.0f min",value)).font(.system(size:25,weight:.medium)).monospacedDigit()}
    }
}
