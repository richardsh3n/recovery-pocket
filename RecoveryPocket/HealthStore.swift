import Foundation
import HealthKit
import SwiftUI
import UIKit

struct CoverageRow: Codable, Identifiable {
    var name: String
    var count: Int
    var days: Int
    var lastSample: Date?
    var sources: [String]
    var id: String { name }
}
struct ActivityDay: Codable, Identifiable {
    var date: Date
    var kcal: Double?
    var id: Date { date }
}
struct StepDay: Codable {
    var date: Date
    var count: Double?
}
struct HealthSnapshot: Codable {
    var fetchedAt: Date
    var nights: [NightRecord]
    var coverage: [CoverageRow]
    var energy: [ActivityDay]
    var workoutCount: Int
    var workouts: [PocketWorkout]? = nil
    var steps: [StepDay]? = nil
    var hrvObservations: [HRVObservation]? = nil
    var vitals: [VitalRecord]? = nil
}

@MainActor final class HealthStore: ObservableObject {
    @Published var battery: PocketStatus = { let cached = StatusStore.read(); return cached.demo ? .empty : cached }()
    @Published var snapshot: HealthSnapshot?
    @Published var busy = false
    @Published var cacheRevision = 0
    private var readGeneration = 0
    private var installingObservers = false
    private var backgroundStopsPending = 0
    @Published var notice: String?
    @Published var backgroundStatus = "尚未启用"
    @Published var requested = UserDefaults.standard.bool(forKey: "healthRequestCompleted")
    var healthAvailable: Bool { HKHealthStore.isHealthDataAvailable() }
    var batteryHistory: [BatteryPoint] { ledger?.status(now: Date()).points ?? battery.points }
    private let store = HKHealthStore()
    private var ledger: BatteryLedger?
    private var ledgerURL: URL { cacheURL.deletingLastPathComponent().appendingPathComponent("battery-ledger-v4.json") }
    private var observers: [HKObserverQuery] = []
    private var refreshAgain = false
    private let calendar = Calendar.current
    private var types: [HKSampleType] {
        [.categoryType(forIdentifier: .sleepAnalysis)!,
         .quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
         .quantityType(forIdentifier: .heartRate)!,
         .quantityType(forIdentifier: .restingHeartRate)!,
         .quantityType(forIdentifier: .activeEnergyBurned)!, .workoutType(), .quantityType(forIdentifier: .stepCount)!,
         .categoryType(forIdentifier: .mindfulSession)!,
         .quantityType(forIdentifier: .respiratoryRate)!,
         .quantityType(forIdentifier: .appleSleepingWristTemperature)!,
         .quantityType(forIdentifier: .oxygenSaturation)!]
    }

    init() {
        guard requested else { battery = .empty; return }
        loadCache()
        if let data = try? Data(contentsOf: ledgerURL) { ledger = try? JSONDecoder().decode(BatteryLedger.self, from: data) }
    }

    func connect() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            notice = "这台设备无法使用 HealthKit。"; return
        }
        guard !busy else { return }
        guard !installingObservers, backgroundStopsPending == 0 else {
            notice = "正在完成后台读取设置，请稍后再连接。"; return
        }
        busy = true
        let generation = readGeneration
        do {
            // A successful request means the sheet completed, NOT that reading was granted.
            try await store.requestAuthorization(toShare: [], read: Set<HKObjectType>(types.map { $0 as HKObjectType }))
            guard generation == readGeneration else { busy = false; return }
            requested = true
            UserDefaults.standard.set(true, forKey: "healthRequestCompleted")
            busy = false
            await startObservers()
            await refresh()
        } catch {
            busy = false
            guard generation == readGeneration else { return }
            notice = "未能完成授权请求：\(error.localizedDescription)"
        }
    }

    func resume() async {
        guard requested else { return }
        await startObservers()
        await refresh()
    }

    func startObservers() async {
        guard requested, observers.isEmpty, !installingObservers else { return }
        installingObservers = true
        defer { installingObservers = false }
        let generation = readGeneration
        var failures = 0
        for type in types {
            guard requested, generation == readGeneration else { return }
            let observer = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, done, error in
                Task { @MainActor in
                    defer { done() }
                    guard let self, self.requested, self.readGeneration == generation else { return }
                    if error == nil { await self.refresh() }
                    // On a locked phone errors preserve the old snapshot; foreground retries.
                }
            }
            observers.append(observer)
            store.execute(observer)
            do { try await store.enableBackgroundDelivery(for: type, frequency: .hourly) }
            catch { failures += 1 }
            guard requested, generation == readGeneration else {
                store.stop(observer)
                stopBackgroundDelivery()
                return
            }
        }
        backgroundStatus = failures == 0 ? "已请求系统后台更新；时间由系统安排" : "部分后台更新未启用；打开 App 仍可刷新"
    }

    private func samples(_ type: HKSampleType, start: Date, end: Date) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, rows, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: rows ?? []) }
            }
            store.execute(query)
        }
    }

    private func dailyEnergy(start: Date, end: Date) async throws -> [ActivityDay] {
        try await withCheckedThrowingContinuation { continuation in
            let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                options: .cumulativeSum, anchorDate: calendar.startOfDay(for: start), intervalComponents: DateComponents(day: 1))
            let healthStore = store
            query.initialResultsHandler = { runningQuery, collection, error in
                // This is a snapshot query. Stop it after the initial result rather than
                // leaving another long-running statistics query alive on every refresh.
                defer { healthStore.stop(runningQuery) }
                if let error { continuation.resume(throwing: error); return }
                var days: [ActivityDay] = []
                collection?.enumerateStatistics(from: start, to: end) { stats, _ in
                    days.append(ActivityDay(date: stats.startDate, kcal: stats.sumQuantity()?.doubleValue(for: .kilocalorie())))
                }
                continuation.resume(returning: days)
            }
            store.execute(query)
        }
    }

    private func hourlyTotals(start: Date, end: Date, identifier: HKQuantityTypeIdentifier = .activeEnergyBurned, unit: HKUnit = .kilocalorie()) async throws -> [ActivityDay] {
        try await withCheckedThrowingContinuation { continuation in
            let type = HKQuantityType.quantityType(forIdentifier: identifier)!
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum, anchorDate: start, intervalComponents: DateComponents(hour: 1))
            let healthStore = store
            query.initialResultsHandler = { running, collection, error in
                defer { healthStore.stop(running) }
                if let error { continuation.resume(throwing: error); return }
                var hours: [ActivityDay] = []
                collection?.enumerateStatistics(from: start, to: end) { item, _ in
                    hours.append(ActivityDay(date: item.startDate, kcal: item.sumQuantity()?.doubleValue(for: unit)))
                }
                continuation.resume(returning: hours)
            }
            store.execute(query)
        }
    }

    private func streamKey(_ sample: HKSample) -> String {
        "\(sample.sourceRevision.source.bundleIdentifier)|\(sample.sourceRevision.productType ?? "")|\(sample.device?.localIdentifier ?? "unidentified")"
    }
    private func preferred(_ rows: [HKSample]) -> [HKSample] {
        let watch = rows.filter {
            ($0.sourceRevision.productType?.hasPrefix("Watch") ?? false) ||
            ($0.device?.model?.localizedCaseInsensitiveContains("Watch") ?? false)
        }
        let candidates = watch.isEmpty ? rows : watch
        let grouped = Dictionary(grouping: candidates, by: streamKey)
        let timestamps = grouped.mapValues { $0.map(\.endDate) }
        guard let key = HealthSourcePolicy.preferredKey(timestamps) else { return [] }
        return grouped[key] ?? []
    }

    private func coverage(_ name: String, rows: [HKSample], start: Date, end: Date) -> CoverageRow {
        let recent = rows.filter { $0.endDate > start && $0.startDate < end }
        let days = Set(recent.map { calendar.startOfDay(for: $0.startDate) }).count
        let sources = Set(recent.map { "\($0.sourceRevision.source.name) · \($0.sourceRevision.productType ?? $0.device?.model ?? "设备未标注")" })
        return CoverageRow(name: name, count: recent.count, days: days,
                           lastSample: recent.map(\.endDate).max(), sources: sources.sorted())
    }

    func refresh() async {
        guard requested else { return }
        guard !busy else { refreshAgain = true; return }
        busy = true; notice = nil
        let generation = readGeneration
        defer { busy = false }
        repeat {
            refreshAgain = false
            do {
                let now = Date(), today = calendar.startOfDay(for: now)
                let firstDay = calendar.date(byAdding: .day, value: -42, to: today)!
                let queryStart = calendar.date(byAdding: .hour, value: -6, to: firstDay)!
                let recentStart = calendar.date(byAdding: .day, value: -29, to: today)!
                async let sleepRequest = samples(types[0], start: queryStart, end: now)
                async let hrvRequest = samples(types[1], start: queryStart, end: now)
                async let hrRequest = samples(types[2], start: queryStart, end: now)
                async let restingRequest = samples(types[3], start: recentStart, end: now)
                async let energyRequest = dailyEnergy(start: recentStart, end: now)
                async let hourlyRequest = hourlyTotals(start: recentStart, end: now)
                async let workoutRequest = samples(types[5], start: recentStart, end: now)
                // A missing/denied new optional type never blocks existing health reads.
                async let stepsRequest = try? hourlyTotals(start: recentStart, end: now, identifier: .stepCount, unit: .count())
                async let mindfulRequest = try? samples(types[7], start: queryStart, end: now)
                async let respiratoryRequest = try? samples(types[8], start: recentStart, end: now)
                async let temperatureRequest = try? samples(types[9], start: recentStart, end: now)
                async let oxygenRequest = try? samples(types[10], start: recentStart, end: now)
                let (rawSleep, rawHRV, rawHR, resting, energy, workouts, hourly, optionalSteps, optionalMindful, optionalRespiratory, optionalTemperature, optionalOxygen) = try await
                    (sleepRequest, hrvRequest, hrRequest, restingRequest, energyRequest, workoutRequest, hourlyRequest, stepsRequest, mindfulRequest, respiratoryRequest, temperatureRequest, oxygenRequest)
                guard requested, generation == readGeneration else { return }
                let stepHours = optionalSteps ?? []
                let stepDays = Dictionary(grouping: stepHours, by: { calendar.startOfDay(for: $0.date) }).map { date, rows in
                    let values = rows.compactMap(\.kcal).filter { $0.isFinite && $0 >= 0 }
                    return StepDay(date: date, count: values.isEmpty ? nil : values.reduce(0, +))
                }.sorted { $0.date < $1.date }
                let asleepValues: Set<Int> = [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                    HKCategoryValueSleepAnalysis.asleepCore.rawValue, HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                    HKCategoryValueSleepAnalysis.asleepREM.rawValue]
                let asleep = rawSleep.filter { asleepValues.contains(($0 as? HKCategorySample)?.value ?? -1) }
                let sleep = preferred(asleep), hrv = preferred(rawHRV), hr = preferred(rawHR)
                let respiratory = preferred(optionalRespiratory ?? []), temperature = preferred(optionalTemperature ?? []), oxygen = preferred(optionalOxygen ?? []), selectedResting = preferred(resting)
                let mindfulness = optionalMindful ?? []
                let allSleep = RecoveryEngine.merged(sleep.map { SleepInterval(start: $0.startDate, end: $0.endDate) }, from: queryStart, to: now)
                let dayHRV = DayHRVModel.compare(hrv.compactMap { sample in
                    guard let q = sample as? HKQuantitySample else { return nil }
                    let sdnn = q.quantity.doubleValue(for: .secondUnit(with: .milli))
                    let hour = calendar.dateInterval(of: .hour, for: sample.startDate)!.start
                    let movement = stepHours.first { $0.date == hour }?.kcal
                    let kcal = hourly.first { $0.date == hour }?.kcal
                    let sleeping = allSleep.contains { sample.startDate >= $0.start && sample.endDate <= $0.end }
                    let breathwork = mindfulness.contains { $0.startDate < sample.endDate && $0.endDate > sample.startDate }
                    let nearTraining = workouts.contains { sample.startDate < $0.endDate.addingTimeInterval(5400) && sample.endDate > $0.startDate.addingTimeInterval(-300) }
                    let context: String
                    if sleeping { context = "睡眠" }
                    else if breathwork { context = "呼吸练习" }
                    else if nearTraining { context = "训练附近" }
                    else if movement.map({ $0 > 100 }) == true || kcal.map({ $0 > 5 }) == true { context = "活动时段" }
                    else if movement != nil && kcal != nil { context = "安静候选" }
                    else { context = "活动记录不足" }
                    return HRVObservation(id: sample.uuid, start: sample.startDate, end: sample.endDate, sdnn: sdnn, context: context, source: streamKey(sample))
                }, now: now, calendar: calendar)
                var vitalRows: [VitalRecord] = []
                var nights: [NightRecord] = []
                for offset in 0...42 {
                    let date = calendar.date(byAdding: .day, value: -offset, to: today)!
                    let from = calendar.date(byAdding: .hour, value: -6, to: date)!
                    let until = min(now, calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date)!)
                    let intervals = RecoveryEngine.merged(sleep.map { SleepInterval(start: $0.startDate, end: $0.endDate) }, from: from, to: until)
                    func inSleep(_ sample: HKSample) -> Bool {
                        // Keep only samples wholly within an asleep interval. No invented RMSSD.
                        intervals.contains { sample.startDate >= $0.start && sample.endDate <= $0.end }
                    }
                    let nightlyHRV = hrv.filter(inSleep).compactMap { ($0 as? HKQuantitySample)?.quantity.doubleValue(for: .secondUnit(with: .milli)) }.filter { $0.isFinite && $0 > 0 }
                    let nightlyHR = hr.filter(inSleep).compactMap { ($0 as? HKQuantitySample)?.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) }.filter { $0.isFinite && $0 > 0 }
                    let duration = intervals.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } / 3600
                    func vital(_ name: String, rows: [HKSample], unit: HKUnit, label: String, accepted: ClosedRange<Double>, sleepOnly: Bool) {
                        let samples = rows.filter { sleepOnly ? inSleep($0) : ($0.endDate > from && $0.endDate <= until) }
                        let values = samples.compactMap { ($0 as? HKQuantitySample)?.quantity.doubleValue(for: unit) }.filter { $0.isFinite && accepted.contains($0) }
                        if let value = RecoveryEngine.median(values), let source = samples.first.map(streamKey) {
                            vitalRows.append(VitalRecord(name: name, date: date, value: value, unit: label, source: source))
                        }
                    }
                    vital("睡眠呼吸率", rows: respiratory, unit: HKUnit.count().unitDivided(by: .minute()), label: "次/分", accepted: 1...80, sleepOnly: true)
                    vital("睡眠血氧", rows: oxygen, unit: .percent(), label: "%", accepted: 0...1, sleepOnly: true)
                    vital("睡眠腕温", rows: temperature, unit: .degreeCelsius(), label: "°C", accepted: 15...45, sleepOnly: false)
                    let rhrRows = selectedResting.filter { calendar.isDate($0.endDate, inSameDayAs: date) }
                    if let value = RecoveryEngine.median(rhrRows.compactMap { ($0 as? HKQuantitySample)?.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) }.filter { $0.isFinite && (25...220).contains($0) }), let source = rhrRows.first.map(streamKey) {
                        vitalRows.append(VitalRecord(name: "静息心率", date: date, value: value, unit: "次/分", source: source))
                    }
                    nights.append(NightRecord(date: date, sleepHours: intervals.isEmpty ? nil : duration,
                                              hrv: RecoveryEngine.median(nightlyHRV), heartRate: RecoveryEngine.median(nightlyHR),
                                              hrvCount: nightlyHRV.count, heartRateCount: nightlyHR.count))
                }
                snapshot = HealthSnapshot(fetchedAt: now, nights: nights, coverage: [
                    coverage("睡眠（已选来源）", rows: sleep, start: recentStart, end: now),
                    coverage("HRV · SDNN（已选来源）", rows: hrv, start: recentStart, end: now),
                    coverage("心率（已选来源）", rows: hr, start: recentStart, end: now),
                    coverage("静息心率", rows: selectedResting, start: recentStart, end: now),
                    coverage("体能训练", rows: workouts, start: recentStart, end: now),
                    coverage("正念时段（HRV 背景）", rows: mindfulness, start: recentStart, end: now),
                    coverage("睡眠呼吸率", rows: respiratory, start: recentStart, end: now),
                    coverage("睡眠腕温", rows: temperature, start: recentStart, end: now),
                    coverage("血氧", rows: oxygen, start: recentStart, end: now)
                ], energy: energy, workoutCount: workouts.count, workouts: workouts.compactMap { sample in
                    guard let workout = sample as? HKWorkout, workout.endDate > workout.startDate else { return nil }
                    let kcal = workout.statistics(for: HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!)?.sumQuantity()?.doubleValue(for: .kilocalorie())
                    return PocketWorkout(id: workout.uuid, title: workoutTitle(workout.workoutActivityType), start: workout.startDate, end: workout.endDate, duration: workout.duration, activeKcal: kcal.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }, source: workout.sourceRevision.source.name)
                }, steps: stepDays, hrvObservations: dayHRV, vitals: vitalRows)
                if sleep.isEmpty && hrv.isEmpty && hr.isEmpty {
                    notice = "暂未读到恢复数据。可能没有记录、尚未同步，或未授予读取权限；App 无法区分这些情况。"
                }
                                // Backfill up to a week using recorded data. An existing ledger
                // keeps its original anchor date, avoiding a refresh changing past estimates.
                let weekStart = calendar.date(byAdding: .day, value: -7, to: today)!
                let start = max(weekStart, ledger?.hours.first?.start ?? weekStart)
                let sleepIntervals = RecoveryEngine.merged(sleep.map { SleepInterval(start: $0.startDate, end: $0.endDate) }, from: start, to: now)
                var bins: [BatteryHour] = []; var cursor = start
                while cursor < now {
                    let end = min(now, cursor.addingTimeInterval(3600))
                    let duration = sleepIntervals.reduce(0.0) { total, interval in total + max(0, min(end, interval.end).timeIntervalSince(max(cursor, interval.start))) } / 3600
                    let rows = hr.filter { $0.startDate >= cursor && $0.endDate <= end }.compactMap { ($0 as? HKQuantitySample)?.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) }
                    // Do not compare awake/breathwork SDNN with sleeping SDNN.
                    let sleepHRV = hrv.filter { sample in
                        sample.startDate >= cursor && sample.endDate <= end && sleepIntervals.contains {
                            sample.startDate >= $0.start && sample.endDate <= $0.end
                        }
                    }.compactMap { ($0 as? HKQuantitySample)?.quantity.doubleValue(for: .secondUnit(with: .milli)) }
                        .filter { $0.isFinite && $0 > 0 }
                    let priorNights = nights.filter { night in
                        // The noon boundary also prevents same-night or future leakage.
                        calendar.date(bySettingHour: 12, minute: 0, second: 0, of: night.date)! < cursor &&
                        (night.sleepHours ?? 0) > 0
                    }.sorted { $0.date > $1.date }.prefix(28)
                    let priorHRV = priorNights.filter { $0.hrvCount > 0 }.compactMap(\.hrv)
                    let personalHR = RecoveryEngine.median(priorNights.filter { $0.heartRateCount >= 2 }.compactMap(\.heartRate).filter { $0.isFinite && (25...150).contains($0) })
                    let sleepHeartRates = hr.filter { sample in
                        sample.startDate >= cursor && sample.endDate <= end && sleepIntervals.contains { sample.startDate >= $0.start && sample.endDate <= $0.end }
                    }.compactMap { ($0 as? HKQuantitySample)?.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) }.filter { $0.isFinite && (25...220).contains($0) }
                    let trainingIntervals = RecoveryEngine.merged(workouts.map {
                        SleepInterval(start: $0.startDate, end: $0.endDate)
                    }, from: cursor, to: end)
                    let trainingHours = trainingIntervals.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) } / 3600
                    bins.append(BatteryHour(start: cursor, end: end, sleepHours: duration, activeKcal: hourly.first { $0.date == cursor }?.kcal, heartRate: RecoveryEngine.median(rows), heartRateCount: rows.count, heartRateCoverageHours: HeartRateCoverage.hours(dates: hr.filter { $0.startDate >= cursor && $0.endDate <= end }.map(\.startDate), start: cursor, end: end), sleepHRVZ: SleepHRVComparison.deviation(current: RecoveryEngine.median(sleepHRV), prior: priorHRV), sleepHRVCount: sleepHRV.count, workoutHours: trainingHours, steps: stepHours.first { $0.date == cursor }?.kcal, personalHR: personalHR, sleepHeartRate: sleepHeartRates.count >= 2 ? RecoveryEngine.median(sleepHeartRates) : nil, awakeHRVZ: RecoveryEngine.median(dayHRV.filter { $0.start >= cursor && $0.end <= end && $0.context == "安静候选" }.compactMap(\.deviation)), awakeHRVObservedHours: DayHRVModel.observedHours(dayHRV, start: cursor, end: end)))
                    cursor = end
                }
                let baselineNights = nights.filter { night in
                    night.date < start && (night.sleepHours ?? 0) > 0 && night.heartRateCount >= 2 && night.heartRate.map { $0.isFinite && (25...150).contains($0) } == true
                }
                let sleepKey = sleep.first.map(streamKey) ?? "none"
                let hrKey = hr.first.map(streamKey) ?? "none"
                let sourceKey = sleepKey + "::" + hrKey
                if let ledger, !ledger.matches(source: sourceKey) {
                    battery = .empty; battery.computedAt = now
                    battery.message = "数据来源需要重新确认"
                    notice = "健康来源已变化，或旧账本尚未记录来源。旧电量历史保留，暂不混合计算；在设置清除健康缓存后可重新建立。"
                } else if bins.contains(where: { $0.sleepHours > 0 || $0.activeKcal != nil || $0.heartRate != nil }) {
                    if ledger == nil { ledger = BatteryLedger(baselineHR: RecoveryEngine.median(baselineNights.compactMap(\.heartRate)), hours: [], sourceKey: sourceKey) }
                    ledger?.merge(bins)
                    battery = ledger?.status(now: now) ?? .empty
                    if baselineNights.count < 14 { battery.message = (ledger?.baselineHR == nil && !bins.contains { $0.personalHR != nil }) ? "初步估计 · 无个人心率基线，未计算心率压力与清醒恢复" : "初步估计 · 个人历史较少" }
                } else {
                    battery = .empty; battery.computedAt = now; battery.message = "尚未读到可计算的睡眠、活动或心率记录"
                }
                if let night = nights.filter({ $0.sleepHours != nil || $0.hrv != nil || $0.heartRate != nil }).max(by: { $0.date < $1.date }) {
                    let storedTarget = UserDefaults.standard.double(forKey: "sleepTarget")
                    let target = storedTarget > 0 ? storedTarget : 8
                    let days = nights.map { n in
                        let prior = calendar.date(byAdding: .day, value: -1, to: n.date)!
                        return RecoveryDay(night: n, activeKcal: energy.first { calendar.isDate($0.date, inSameDayAs: prior) }?.kcal, sleepMidpointHour: nil)
                    }
                    let result = RecoveryModelV2.calculate(days: days, sleepTarget: target).first { calendar.isDate($0.date, inSameDayAs: night.date) }
                    battery.recoverySummary = WearableSummary(date: night.date, recovery: result?.score, sleepHours: night.sleepHours, hrv: night.hrv, heartRate: night.heartRate, baselineNights: result?.baselineNights ?? 0)
                }
                battery.dayHRV = DayHRVModel.summary(dayHRV, now: now, calendar: calendar)
                WatchBridge.shared.publishHealth(battery)
                saveCache()
                if let ledger {
                    do { try JSONEncoder().encode(ledger).write(to: ledgerURL, options: [.atomic, .completeFileProtection]) }
                    catch { notice = "电量状态未保存，下次打开可能需要重新建立估计" }
                }
            } catch {
                guard generation == readGeneration else { return }
                notice = "本次读取未完成，保留上次结果。解锁手机后可重试。\(error.localizedDescription)"
                refreshAgain = false
            }
        } while refreshAgain
    }

    private var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RecoveryPocket", isDirectory: true).appendingPathComponent("snapshot.json")
    }
    private func loadCache() {
        if let data = try? Data(contentsOf: cacheURL) { snapshot = try? JSONDecoder().decode(HealthSnapshot.self, from: data) }
    }
    private func saveCache() {
        guard let snapshot else { return }
        do {
            let directory = cacheURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.protectionKey: FileProtectionType.complete])
            try JSONEncoder().encode(snapshot).write(to: cacheURL, options: [.atomic, .completeFileProtection])
            var url = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch { notice = "数据已读取，但本地缓存未保存：\(error.localizedDescription)" }
    }
    private func stopBackgroundDelivery() {
        // Reconnection waits for every old disable operation, including a late install.
        backgroundStopsPending += 1
        store.disableAllBackgroundDelivery { [weak self] success, _ in
            Task { @MainActor in
                guard let self else { return }
                self.backgroundStopsPending = max(0, self.backgroundStopsPending - 1)
                if !success && !self.requested {
                    self.backgroundStatus = "本 App 查询已停止；系统后台关闭尚未确认"
                }
            }
        }
    }
    func clearLocalCache() {
        // Invalidate pending reads before any I/O; failures must not restart reading.
        readGeneration += 1
        refreshAgain = false
        requested = false
        UserDefaults.standard.removeObject(forKey: "healthRequestCompleted")
        observers.forEach { store.stop($0) }; observers.removeAll()
        stopBackgroundDelivery()
        backgroundStatus = "已停止本 App 自动读取"
        ledger = nil
        snapshot = nil
        battery = .empty
        battery.computedAt = Date()
        battery.message = "已停止读取"
        WatchBridge.shared.presentationOverride = nil
        WatchBridge.shared.publish(battery)
        cacheRevision += 1
        var failures = 0
        for url in [cacheURL, ledgerURL] {
            do { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
            catch { failures += 1 }
        }
        notice = failures == 0
            ? "健康缓存已清除，自动读取已停止。手动事件记录保留；苹果健康原始记录未删除，系统权限可在健康 App 中撤销。"
            : "自动读取已停止，但部分健康缓存未能删除，请解锁后重试。手动事件记录和苹果健康原始记录保留。"
    }
}

private func workoutTitle(_ type: HKWorkoutActivityType) -> String {
    switch type {
    case .running: return "跑步"
    case .walking: return "步行"
    case .cycling: return "骑行"
    case .swimming: return "游泳"
    case .traditionalStrengthTraining, .functionalStrengthTraining: return "力量训练"
    case .highIntensityIntervalTraining: return "间歇训练"
    case .yoga: return "瑜伽"
    case .hiking: return "徒步"
    case .coreTraining: return "核心训练"
    case .elliptical: return "椭圆机"
    case .rowing: return "划船"
    case .pilates: return "普拉提"
    default: return "体能训练"
    }
}
