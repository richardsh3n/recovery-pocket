import SwiftUI
import Charts

struct ContentView: View {
    @EnvironmentObject private var health: HealthStore
    @AppStorage("sleepTarget") private var sleepTarget = 8.0
    @State private var settings = false
    private let tint = Color(red: 0.62, green: 0.90, blue: 0.72)
    private var today: NightRecord? {
        health.snapshot?.nights.first { Calendar.current.isDateInToday($0.date) }
    }
    private var result: RecoveryResult {
        let snapshot = health.snapshot
        let days = (snapshot?.nights ?? []).map { night in
            let prior = Calendar.current.date(byAdding: .day, value: -1, to: night.date)!
            return RecoveryDay(night: night, activeKcal: snapshot?.energy.first { Calendar.current.isDate($0.date, inSameDayAs: prior) }?.kcal, sleepMidpointHour: nil)
        }
        guard let last = RecoveryModelV2.calculate(days: days, sleepTarget: sleepTarget).last else {
            return RecoveryResult(score: nil, baselineNights: 0, message: "等待个人历史", factors: [])
        }
        return RecoveryResult(score: last.score, baselineNights: last.baselineNights, message: last.state + " · " + last.reliability, factors: last.reasons.map { $0.name + "：" + $0.detail })
    }
    private var fresh: Bool {
        guard let snapshot = health.snapshot else { return false }
        return Date().timeIntervalSince(snapshot.fetchedAt) < 6 * 3600
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("RECOVERY POCKET").font(.caption.weight(.semibold)).tracking(3).foregroundStyle(tint)
                    Text("读懂今天的状态").font(.largeTitle.bold())
                    Text("来自你的 Apple 健康记录 · 本机计算").font(.subheadline).foregroundStyle(.secondary)
                    if !health.requested {
                        card {
                            Label("连接 Apple 健康", systemImage: "heart.text.square.fill").font(.title3.bold())
                            Text("只读取睡眠、HRV、心率、静息心率、活动能量与体能训练。由苹果系统让你逐项选择权限，健康记录保存在手机上。")
                                .foregroundStyle(.secondary)
                            Button { Task { await health.connect() } } label: {
                                Text("选择允许读取的数据").frame(maxWidth: .infinity).padding(.vertical, 8)
                            }.buttonStyle(.borderedProminent).tint(tint).foregroundStyle(.black).disabled(health.busy)
                        }
                    }
                    card {
                        HStack {
                            Text("今日恢复参考").font(.headline)
                            Spacer()
                            Text("实验版").font(.caption).padding(6).background(tint.opacity(0.15), in: Capsule())
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(fresh ? result.score.map(String.init) ?? "—" : "—")
                                .font(.system(size: 76, weight: .light, design: .rounded)).foregroundStyle(tint)
                            Text("/ 100").foregroundStyle(.secondary)
                        }.accessibilityElement(children: .combine)
                        Text(fresh ? result.message : "连接并刷新后显示；旧缓存不作为当前状态评分").font(.subheadline)
                        ForEach(result.factors, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        Text("分数不是身体剩余能量的百分比，也不是医学结论。当前公式尚未经过个人或临床验证。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let snapshot = health.snapshot {
                        card {
                            Text("最近一夜").font(.headline)
                            metric("实际睡眠", value: today?.sleepHours, unit: "小时")
                            metric("睡眠期间 HRV · SDNN", value: today?.hrv, unit: "ms")
                            metric("睡眠期间心率", value: today?.heartRate, unit: "次/分")
                            Text("昨晚 18:00 至今天 12:00（尚未到 12:00 时截止本次读取）。只统计已记录的睡眠片段；读到的心率与 HRV 必须位于睡眠片段内。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        card {
                            Text("14 天睡眠趋势").font(.headline)
                            Chart(Array(snapshot.nights.prefix(14)).reversed()) { night in
                                if let hours = night.sleepHours {
                                    BarMark(x: .value("日期", night.date, unit: .day), y: .value("小时", hours)).foregroundStyle(tint)
                                }
                            }.frame(height: 150)
                            Text("空白表示未读到睡眠，不能解释为没有睡觉。").font(.caption).foregroundStyle(.secondary)
                        }
                        card {
                            Text("活动记录").font(.headline)
                            if let current = snapshot.energy.first(where: { Calendar.current.isDateInToday($0.date) }), let kcal = current.kcal {
                                Text("今天已记录活动能量 \(Int(kcal)) kcal").font(.title3)
                            } else { Text("今天活动能量：暂无可读记录").foregroundStyle(.secondary) }
                            Text("最近 30 天读到 \(snapshot.workoutCount) 条训练记录；不同来源可能重复，此数量不参与评分。")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("全天身体电量与组件在“电量”页查看。").font(.caption).foregroundStyle(.secondary)
                        }
                        card {
                            Text("30 天数据覆盖").font(.headline)
                            ForEach(snapshot.coverage) { row in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack { Text(row.name).font(.subheadline); Spacer(); Text(row.readFailure != nil ? "读取失败" : "\(row.days) 天 · \(row.count) 条").font(.caption).foregroundStyle(tint) }
                                    Text(row.readFailure ?? (row.sources.isEmpty ? "没有可读记录；无法区分未授权与未记录" : row.sources.joined(separator: "\n"))).font(.caption2).foregroundStyle(.secondary)
                                    if let date = row.lastSample { Text("最新记录：\(date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
                                }.padding(.vertical, 5)
                            }
                            Text("睡眠、HRV 和心率优先选 Apple Watch，并各自使用近期覆盖优先的单一来源。覆盖天数按记录起始日期计；夜间有效性以恢复模型检查为准。")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if let failures = snapshot.readFailures, !failures.isEmpty {
                            Text("部分类型读取失败，空白不代表没有记录：\n"+failures.joined(separator:"\n")).font(.caption).foregroundStyle(.orange)
                        }
                        Text("本次读取：\(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let notice = health.notice {
                        Label(notice, systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
                    }
                    if health.requested {
                        Button { Task { await health.refresh() } } label: {
                            HStack { if health.busy { ProgressView() }; Text(health.busy ? "正在读取…" : "刷新健康记录") }.frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).disabled(health.busy)
                    }
                    Text("\(health.backgroundStatus)\n锁屏或系统调度可能延迟读取；打开 App 会重试。").font(.caption2).foregroundStyle(.secondary)
                }.padding(22)
            }.background(Color(red: 0.055, green: 0.075, blue: 0.07))
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { settings = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("设置") } }
                .sheet(isPresented: $settings) { SettingsView(sleepTarget: $sleepTarget).environmentObject(health) }
                .refreshable { await health.refresh() }
        }.preferredColorScheme(.dark)
    }
    @ViewBuilder private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content).frame(maxWidth: .infinity, alignment: .leading)
            .padding(20).background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
    }
    private func metric(_ name: String, value: Double?, unit: String) -> some View {
        HStack {
            Text(name).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value.map { String(format: "%.1f %@", $0, unit) } ?? "暂无记录").font(.subheadline.monospacedDigit())
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var health: HealthStore
    @Environment(\.dismiss) private var dismiss
    @Binding var sleepTarget: Double
    @State private var confirmClear = false
    var body: some View {
        NavigationStack {
            Form {
                Section("睡眠目标") {
                    Stepper("每晚 \(String(format: "%.1f", sleepTarget)) 小时", value: $sleepTarget, in: 4...12, step: 0.5)
                    Text("这是你设置的目标，模型不会把长期睡眠不足当作理想状态。").font(.caption)
                }
                Section("健康数据权限") {
                    Button("重新打开授权请求") { Task { await health.connect() } }.disabled(health.busy)
                    Text("已经选择过的权限不一定再次弹窗。要修改已有权限，请到健康 App → 头像 → App／数据访问与设备 → Recovery Pocket。系统弹窗完成不代表每项读取权限均已允许。").font(.caption)
                }
                Section("隐私") {
                    Text("没有账户、服务器、广告、统计追踪或健康数据上传。原始缓存使用 iOS 完整文件保护并排除备份；组件摘要使用首次解锁后保护，便于系统组件读取。只读健康原始记录。")
                    Button("清除健康缓存并停止自动读取", role: .destructive) { confirmClear = true }.disabled(health.busy)
                }
                Section("关于评分") {
                    Text("模型 0.4：睡眠 HRV 使用 SDNN，按个人历史比较；HRV 与心率独立建立基线，至少 3 个可比历史夜后对应信号才参与。有睡眠记录即可给初步恢复参考。身体电量使用有界睡眠恢复曲线，清醒消耗限制在观测覆盖时段，日间 HRV 只影响实测窗口。读取 42 天历史，持续保存电量时段账本；初值 50 和充放电系数仍为未校准的工程假设。")
                    Text("暂未集成 NeuroKit2、Chronos 或 TimesFM。基础读取和评分验证完成后，再对照测试前沿模型。采样不足不会用模型伪造测量值。")
                }
            }.navigationTitle("设置").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .confirmationDialog("清除健康缓存并停止读取？手动事件记录和苹果健康原始记录保留。", isPresented: $confirmClear, titleVisibility: .visible) {
                    Button("清除并停止", role: .destructive) { health.clearLocalCache(); dismiss() }
                }
        }
    }
}
