import Foundation
import CryptoKit
import HealthKit
import SwiftUI
import UIKit

struct CoverageRow: Codable, Identifiable {
    var name: String
    var count: Int
    var days: Int
    var lastSample: Date?
    var sources: [String]
    var readFailure: String? = nil
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
    var sleepIntervals: [SleepInterval]? = nil
    var readFailures: [String]? = nil
    var energyBudget: [EnergyDayRecord]? = nil
    var bodyMeasurements: [BodyMeasurement]? = nil
    var nutritionSources: [NutritionSource]? = nil
    var readTimeZone:String? = nil
    var activityGridAnchor:Date? = nil
}

@MainActor final class HealthStore: ObservableObject {
    @Published var battery: PocketStatus = RecentStateCachePolicy.presentation(StatusStore.read())
    @Published var shadowInspection: ShadowReplayInspection?
    var shadowReplay:ShadowReplay? {shadowInspection?.replay}
    @Published var snapshot: HealthSnapshot?
    @Published var busy = false
    @Published var cacheRevision = 0
    private var readGeneration = 0
    private var installingObservers = false
    private var resuming = false
    private var cacheLoaded = false
    private var observerRefreshTask: Task<Void, Never>?
    private var observerRefreshToken: UUID?
    private var backgroundStopsPending = 0
    @Published var notice: String?
    @Published var backgroundStatus = "尚未启用"
    @Published var requested = UserDefaults.standard.bool(forKey: "healthRequestCompleted")
    var healthAvailable: Bool { HKHealthStore.isHealthDataAvailable() }
    // Rendering must never rerun the physiological model. A refresh publishes
    // these immutable curves after the background calculation finishes.
    var batteryHistory: [BatteryPoint] { battery.usesStateEstimate ? [] : battery.points }
    @Published var stateHistory: [BatteryPoint] = []
    private let store = HKHealthStore()
    @Published var batteryAnchorSensitivity:(low:Int,high:Int)?
    private var ledger: BatteryLedger?
    private var ledgerURL: URL { cacheURL.deletingLastPathComponent().appendingPathComponent("battery-ledger-v4.json") }
    private var observers: [HKObserverQuery] = []
    private var refreshAgain = false
    private var types: [HKSampleType] {
        [.categoryType(forIdentifier: .sleepAnalysis)!,
         .quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
         .quantityType(forIdentifier: .heartRate)!,
         .quantityType(forIdentifier: .restingHeartRate)!,
         .quantityType(forIdentifier: .activeEnergyBurned)!, .workoutType(), .quantityType(forIdentifier: .stepCount)!,
         .categoryType(forIdentifier: .mindfulSession)!,
         .quantityType(forIdentifier: .respiratoryRate)!,
         .quantityType(forIdentifier: .appleSleepingWristTemperature)!,
         .quantityType(forIdentifier: .oxygenSaturation)!,
         .quantityType(forIdentifier: .basalEnergyBurned)!, .quantityType(forIdentifier: .dietaryEnergyConsumed)!,
         .quantityType(forIdentifier: .bodyMass)!, .quantityType(forIdentifier: .bodyFatPercentage)!,
         .quantityType(forIdentifier: .leanBodyMass)!, .quantityType(forIdentifier: .height)!]
    }

    private static var offlineCacheQA:Bool {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("--pocket-cache-migration-qa") &&
            ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"]?.contains("恢复验收") == true
        #else
        return false
        #endif
    }
    init() {
        if !requested && !Self.offlineCacheQA { battery = .empty }
    }

    private func restoreCache() async {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        let snapshotURL = cacheURL, modelURL = ledgerURL, saved = battery
        let recoveryTarget = UserDefaults.standard.double(forKey:"sleepTarget") > 0 ? UserDefaults.standard.double(forKey:"sleepTarget") : 8
        let generation = readGeneration,offlineQA=Self.offlineCacheQA
        let restored = await Task.detached(priority: .userInitiated) {
            var snapshot = (try? Data(contentsOf: snapshotURL)).flatMap { try? JSONDecoder().decode(HealthSnapshot.self, from: $0) }
            var ledger = (try? Data(contentsOf: modelURL)).flatMap { try? JSONDecoder().decode(BatteryLedger.self, from: $0) }
            let now = Date()
            var status = RecentStateCachePolicy.presentation(saved)
            var history: [BatteryPoint] = []
            if offlineQA,ledger?.sourceKey != "synthetic-cache-qa" {
                snapshot=nil;ledger=nil;status = .empty
                status.message="隔离验收仅接受合成缓存，未读取健康数据。"
            }
            if var restoredLedger = ledger {
                let reconstructed = restoredLedger.evaluate(now:now)
                status = RecentStateCachePolicy.reusable(saved,at:now) ? saved : reconstructed
                if status.usesStateEstimate { history = restoredLedger.stateHistory(now: now) }
                status.recoverySummary = saved.recoverySummary; status.dayHRV = saved.dayHRV
                ledger = restoredLedger
            }
            // Recompute the morning summary when upgrading the model; do not
            // keep an old 82-point prior while the new phone UI shows no recovery.
            if let snapshot {
                let calendar=Calendar.current
                let days=snapshot.nights.map { n in
                    let prior=calendar.date(byAdding:.day,value:-1,to:n.date)!
                    return RecoveryDay(night:n,activeKcal:snapshot.energy.first { calendar.isDate($0.date,inSameDayAs:prior) }?.kcal,sleepMidpointHour:nil)
                }
                if let result=RecoveryModelV2.calculate(days:days,sleepTarget:recoveryTarget).last,
                   let night=snapshot.nights.first(where:{ calendar.isDate($0.date,inSameDayAs:result.date) }) {
                    status.recoverySummary=WearableSummary(date:night.date,recovery:result.score,sleepHours:night.sleepHours,hrv:night.hrv,heartRate:night.heartRate,baselineNights:result.baselineNights,recoveryBasis:result.scoreBasis,recoveryModelRevision:RecoveryModelV2.revision)
                }
            }
            if offlineQA {status.demo=true;status.message="隔离模拟器 · 合成缓存升级验收。"+status.message}
            let shadow=makeShadowInspection(ledger:ledger,status:status,now:now)
            let sensitivity = !status.usesStateEstimate && status.isFresh(at:now) ? ledger?.anchorSensitivity(now:now):nil
            return (snapshot, ledger, status, history, shadow, sensitivity)
        }.value
        guard (requested || offlineQA),generation == readGeneration else { return }
        snapshot = restored.0; ledger = restored.1; battery = restored.2; stateHistory = restored.3; shadowInspection = restored.4; batteryAnchorSensitivity = restored.5
        // Keep phone, widgets and the paired Watch on the same recomputed summary.
        WatchBridge.shared.publishHealth(battery)
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
        // Simulator-only, named synthetic QA device: restore local fixtures without
        // asking for permissions, starting HealthKit queries, or installing observers.
        if Self.offlineCacheQA {await restoreCache();return}
        guard requested, !resuming else { return }
        resuming = true
        defer { resuming = false }
        await restoreCache()
        guard requested else { return }
        await startObservers()
        // Initial appearance and scene activation can arrive together. Returning
        // from a sheet must not launch another 42-day query immediately.
        if !busy && snapshot.map({HealthRefreshCachePolicy.mayReuse(fetchedAt:$0.fetchedAt,readTimeZone:$0.readTimeZone,failures:$0.readFailures ?? [],ledgerVersion:ledger?.continuousVersion,now:Date(),currentTimeZone:Calendar.current.timeZone.identifier)}) != true {
            await refresh()
        }
    }

    private func refreshFromObserver() async {
        if let task = observerRefreshTask { await task.value; return }
        let token = UUID(), generation = readGeneration
        observerRefreshToken = token
        let task = Task { @MainActor [weak self] in
            // HealthKit delivers separate notifications for related sample types.
            // Coalesce that burst into a single read, while every callback waits
            // for the read to finish before acknowledging delivery.
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            guard let self, self.requested, self.readGeneration == generation else { return }
            await self.refresh()
        }
        observerRefreshTask = task
        await task.value
        if observerRefreshToken == token { observerRefreshTask = nil; observerRefreshToken = nil }
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
                    if error == nil { await self.refreshFromObserver() }
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

    private func dailyTotals(start:Date,end:Date,identifier:HKQuantityTypeIdentifier = .activeEnergyBurned,unit:HKUnit = .kilocalorie()) async throws -> [ActivityDay] {
        try await withCheckedThrowingContinuation { continuation in
            let type = HKQuantityType.quantityType(forIdentifier: identifier)!
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                options: .cumulativeSum, anchorDate: start, intervalComponents: DateComponents(day: 1))
            let healthStore = store
            query.initialResultsHandler = { runningQuery, collection, error in
                // This is a snapshot query. Stop it after the initial result rather than
                // leaving another long-running statistics query alive on every refresh.
                defer { healthStore.stop(runningQuery) }
                if let error { continuation.resume(throwing: error); return }
                var days: [ActivityDay] = []
                collection?.enumerateStatistics(from: start, to: end) { stats, _ in
                    days.append(ActivityDay(date: stats.startDate, kcal: stats.sumQuantity()?.doubleValue(for: unit)))
                }
                continuation.resume(returning: days)
            }
            store.execute(query)
        }
    }

    private func hourlyTotals(start: Date, end: Date, anchor:Date, identifier: HKQuantityTypeIdentifier = .activeEnergyBurned, unit: HKUnit = .kilocalorie()) async throws -> [ActivityDay] {
        try await withCheckedThrowingContinuation { continuation in
            let type = HKQuantityType.quantityType(forIdentifier: identifier)!
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum, anchorDate: anchor, intervalComponents: DateComponents(hour: 1))
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

    func refresh() async {
        guard requested else { return }
        guard !busy else { refreshAgain = true; return }
        busy = true; notice = nil
        let generation = readGeneration
        defer { busy = false }
        repeat {
            refreshAgain = false
            let now=Date(),calendar=Calendar.current
            let today=calendar.startOfDay(for:now)
            let activityAnchor=BatteryActivityGrid.anchor(saved:ledger?.activityGridAnchor,first:ledger?.hours.first?.start,fallback:today)
            let firstDay = calendar.date(byAdding: .day, value: -42, to: today)!
            let queryStart = calendar.date(byAdding: .hour, value: -6, to: firstDay)!
            let recentStart = calendar.date(byAdding: .day, value: -29, to: today)!
            async let sleepRequest = HealthReadOutcome.capture("睡眠") { try await self.samples(self.types[0],start:queryStart,end:now) }
            async let hrvRequest = HealthReadOutcome.capture("HRV") { try await self.samples(self.types[1],start:queryStart,end:now) }
            async let hrRequest = HealthReadOutcome.capture("心率") { try await self.samples(self.types[2],start:queryStart,end:now) }
            async let restingRequest = HealthReadOutcome.capture("静息心率") { try await self.samples(self.types[3],start:recentStart,end:now) }
            async let energyRequest = HealthReadOutcome.capture("日活动能量") { try await self.dailyTotals(start:recentStart,end:now) }
            async let hourlyRequest = HealthReadOutcome.capture("小时活动能量") { try await self.hourlyTotals(start:recentStart,end:now,anchor:activityAnchor) }
            async let workoutRequest = HealthReadOutcome.capture("训练") { try await self.samples(self.types[5],start:recentStart,end:now) }
            async let stepsRequest = HealthReadOutcome.capture("步数") { try await self.hourlyTotals(start:recentStart,end:now,anchor:activityAnchor,identifier:.stepCount,unit:.count()) }
            async let dailyStepsRequest=HealthReadOutcome.capture("日步数") {try await self.dailyTotals(start:recentStart,end:now,identifier:.stepCount,unit:.count())}
            async let mindfulRequest = HealthReadOutcome.capture("正念背景") { try await self.samples(self.types[7],start:queryStart,end:now) }
            async let respiratoryRequest = HealthReadOutcome.capture("呼吸率") { try await self.samples(self.types[8],start:recentStart,end:now) }
            async let temperatureRequest = HealthReadOutcome.capture("腕温") { try await self.samples(self.types[9],start:recentStart,end:now) }
            async let oxygenRequest = HealthReadOutcome.capture("血氧") { try await self.samples(self.types[10],start:recentStart,end:now) }
            async let basalRequest = HealthReadOutcome.capture("静息能量") { try await self.samples(self.types[11],start:recentStart,end:now) }
            async let foodRequest = HealthReadOutcome.capture("饮食能量") { try await self.samples(self.types[12],start:recentStart,end:now) }
            async let weightRequest = HealthReadOutcome.capture("体重") { try await self.samples(self.types[13],start:firstDay,end:now) }
            async let fatRequest = HealthReadOutcome.capture("体脂") { try await self.samples(self.types[14],start:firstDay,end:now) }
            async let leanRequest = HealthReadOutcome.capture("去脂体重") { try await self.samples(self.types[15],start:firstDay,end:now) }
            async let heightRequest = HealthReadOutcome.capture("身高") { try await self.samples(self.types[16],start:calendar.date(byAdding:.year,value:-2,to:today)!,end:now) }
            let (sleepRead,hrvRead,hrRead,restingRead,energyRead,hourlyRead,workoutRead,stepsRead,dailyStepsRead,mindfulRead,respiratoryRead,temperatureRead,oxygenRead,basalRead,foodRead,weightRead,fatRead,leanRead,heightRead) = await
                (sleepRequest,hrvRequest,hrRequest,restingRequest,energyRequest,hourlyRequest,workoutRequest,stepsRequest,dailyStepsRequest,mindfulRequest,respiratoryRequest,temperatureRequest,oxygenRequest,basalRequest,foodRequest,weightRequest,fatRequest,leanRequest,heightRequest)
            guard requested, generation == readGeneration else { return }
            guard calendar.timeZone.identifier==Calendar.current.timeZone.identifier else {refreshAgain=true;continue}
            let storedTarget = UserDefaults.standard.double(forKey: "sleepTarget")
            let input = HealthRefreshInput(
                sleepRead: sleepRead,
                hrvRead: hrvRead,
                hrRead: hrRead,
                restingRead: restingRead,
                energyRead: energyRead,
                hourlyRead: hourlyRead,
                workoutRead: workoutRead,
                stepsRead: stepsRead,
                dailyStepsRead:dailyStepsRead,
                mindfulRead: mindfulRead,
                respiratoryRead: respiratoryRead,
                temperatureRead: temperatureRead,
                oxygenRead: oxygenRead,
                basalRead: basalRead,
                foodRead: foodRead,
                weightRead: weightRead,
                fatRead: fatRead,
                leanRead: leanRead,
                heightRead: heightRead,
                savedLedger: ledger, savedBattery: battery, calendar: calendar, activityAnchor:activityAnchor,
                sleepTarget: storedTarget > 0 ? storedTarget : 8,
                foodSource: UserDefaults.standard.string(forKey: "nutritionSource"))
            let result = await Task.detached(priority: .userInitiated) {
                input.process(now: now, today: today, firstDay: firstDay, queryStart: queryStart, recentStart: recentStart)
            }.value
            // Clear/reconnect can happen while the worker runs. Stale work may
            // neither repopulate the UI nor recreate cleared files.
            guard requested, generation == readGeneration else { return }
            guard let result else {
                notice = "本次所有类型读取失败，保留上次结果。解锁手机后可重试。"
                refreshAgain = false; continue
            }
            guard calendar.timeZone.identifier==Calendar.current.timeZone.identifier else {refreshAgain=true;continue}
            snapshot = result.snapshot
            ledger = result.ledger
            battery = result.battery
            shadowInspection = result.shadowInspection
            batteryAnchorSensitivity = result.anchorSensitivity
            notice = result.notice
            stateHistory = result.history
            WatchBridge.shared.publishHealth(battery)
            saveCache(data: result.snapshotData)
            if let data = result.ledgerData {
                do { try data.write(to: ledgerURL, options: [.atomic, .completeFileProtection]) }
                catch { notice = "电量状态未保存，下次打开可能需要重新建立估计" }
            }
        } while refreshAgain
    }

    private var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RecoveryPocket", isDirectory: true).appendingPathComponent("snapshot.json")
    }
    private func saveCache(data: Data? = nil) {
        guard let snapshot else { return }
        do {
            let directory = cacheURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.protectionKey: FileProtectionType.complete])
            try (data ?? JSONEncoder().encode(snapshot)).write(to: cacheURL, options: [.atomic, .completeFileProtection])
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
        observerRefreshTask?.cancel(); observerRefreshTask = nil; observerRefreshToken = nil
        cacheLoaded = false
        refreshAgain = false
        requested = false
        UserDefaults.standard.removeObject(forKey: "healthRequestCompleted")
        observers.forEach { store.stop($0) }; observers.removeAll()
        stopBackgroundDelivery()
        backgroundStatus = "已停止本 App 自动读取"
        ledger = nil
        shadowInspection = nil
        batteryAnchorSensitivity = nil
        snapshot = nil
        stateHistory = []
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

/// Owns a single immutable HealthKit read. All aggregation, model evaluation,
/// history replay and JSON encoding run outside the main actor.
private struct HealthRefreshInput {
    var sleepRead: HealthReadOutcome<[HKSample]>
    var hrvRead: HealthReadOutcome<[HKSample]>
    var hrRead: HealthReadOutcome<[HKSample]>
    var restingRead: HealthReadOutcome<[HKSample]>
    var energyRead: HealthReadOutcome<[ActivityDay]>
    var hourlyRead: HealthReadOutcome<[ActivityDay]>
    var workoutRead: HealthReadOutcome<[HKSample]>
    var stepsRead: HealthReadOutcome<[ActivityDay]>
    var dailyStepsRead:HealthReadOutcome<[ActivityDay]>
    var mindfulRead: HealthReadOutcome<[HKSample]>
    var respiratoryRead: HealthReadOutcome<[HKSample]>
    var temperatureRead: HealthReadOutcome<[HKSample]>
    var oxygenRead: HealthReadOutcome<[HKSample]>
    var basalRead: HealthReadOutcome<[HKSample]>
    var foodRead: HealthReadOutcome<[HKSample]>
    var weightRead: HealthReadOutcome<[HKSample]>
    var fatRead: HealthReadOutcome<[HKSample]>
    var leanRead: HealthReadOutcome<[HKSample]>
    var heightRead: HealthReadOutcome<[HKSample]>
    var savedLedger: BatteryLedger?
    var savedBattery: PocketStatus
    var calendar: Calendar
    var activityAnchor:Date
    var sleepTarget: Double
    var foodSource: String?
    func streamKey(_ sample: HKSample) -> String {
        "\(sample.sourceRevision.source.bundleIdentifier)|\(sample.sourceRevision.productType ?? "")|\(sample.device?.localIdentifier ?? "unidentified")"
    }
    func preferred(_ rows: [HKSample]) -> [HKSample] {
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

    func coverage(_ name: String, rows: [HKSample], start: Date, end: Date, failure: String? = nil) -> CoverageRow {
        let recent = rows.filter { $0.endDate > start && $0.startDate < end }
        let days = Set(recent.map { calendar.startOfDay(for: $0.startDate) }).count
        let sources = Set(recent.map { "\($0.sourceRevision.source.name) · \($0.sourceRevision.productType ?? $0.device?.model ?? "设备未标注")" })
        return CoverageRow(name: name, count: recent.count, days: days,
                           lastSample: recent.map(\.endDate).max(), sources: sources.sorted(), readFailure: failure)
    }


    func process(now: Date, today: Date, firstDay: Date, queryStart: Date, recentStart: Date) -> HealthRefreshResult? {
        assert(!Thread.isMainThread, "Health aggregation must stay off the UI thread")
        var ledger = savedLedger, battery = savedBattery
        var notice: String?
            let failuresByType:[(HealthReadChannel,String?)] = [(.sleep,sleepRead.failure),(.hrv,hrvRead.failure),(.heartRate,hrRead.failure),(.restingHeartRate,restingRead.failure),(.dailyEnergy,energyRead.failure),(.hourlyEnergy,hourlyRead.failure),(.workout,workoutRead.failure),(.steps,stepsRead.failure),(.dailySteps,dailyStepsRead.failure),(.mindfulness,mindfulRead.failure),(.respiration,respiratoryRead.failure),(.temperature,temperatureRead.failure),(.oxygen,oxygenRead.failure),(.basalEnergy,basalRead.failure),(.dietaryEnergy,foodRead.failure),(.bodyMass,weightRead.failure),(.bodyFat,fatRead.failure),(.leanMass,leanRead.failure),(.height,heightRead.failure)]
            let readFailures = failuresByType.compactMap { $0.1 }
            let failedChannels = Set(failuresByType.filter { $0.1 != nil }.map { $0.0 })
            if readFailures.count == failuresByType.count {
                return nil
            }
            let rawSleep = sleepRead.value ?? [],rawHRV = hrvRead.value ?? [],rawHR = hrRead.value ?? []
            let resting = restingRead.value ?? [],energy = energyRead.value ?? [],workouts = workoutRead.value ?? [],hourly = hourlyRead.value ?? []
            let optionalRespiratory = respiratoryRead.value,optionalTemperature = temperatureRead.value,optionalOxygen = oxygenRead.value,optionalMindful = mindfulRead.value
            let stepHours = stepsRead.value ?? []
            // Preserve the existing battery for a failed model dependency. Other
            // readable body metrics still update; failed queries are not empty success.
            let batteryReadFailed = !HealthReadPolicy.canUpdateBattery(failed:failedChannels)
            let awakeHRVBackgroundFailed = !HealthReadPolicy.canCompareAwakeHRV(failed:failedChannels)
            // A fixed absolute grid can cross the current local midnight. Daily
            // steps therefore use a separate calendar-day statistics query.
            let stepDays=(dailyStepsRead.value ?? []).map {row in
                StepDay(date:row.date,count:row.kcal.flatMap{$0.isFinite && $0>=0 ? $0:nil})
            }.sorted{$0.date<$1.date}
            let asleepValues: Set<Int> = [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                HKCategoryValueSleepAnalysis.asleepCore.rawValue, HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                HKCategoryValueSleepAnalysis.asleepREM.rawValue]
            let asleep = rawSleep.filter { $0.endDate <= now && asleepValues.contains(($0 as? HKCategorySample)?.value ?? -1) }
            let sleep = preferred(asleep), hrv = preferred(rawHRV), hr = preferred(rawHR)
            let respiratory = preferred(optionalRespiratory ?? []), temperature = preferred(optionalTemperature ?? []), oxygen = preferred(optionalOxygen ?? []), selectedResting = preferred(resting)
            let mindfulness = optionalMindful ?? []
            let allSleep = RecoveryEngine.merged(sleep.map { SleepInterval(start: $0.startDate, end: $0.endDate) }, from: queryStart, to: now)
            let energyByHour = Dictionary(hourly.map { ($0.date,$0) },uniquingKeysWith:{ a,_ in a })
            let stepsByHour = Dictionary(stepHours.map { ($0.date,$0) },uniquingKeysWith:{ a,_ in a })
            let activityBins = Set(energyByHour.keys).union(stepsByHour.keys).map { date in
                HRVActivityBin(start:date,end:min(now,date.addingTimeInterval(3600)),steps:stepsByHour[date]?.kcal,kcal:energyByHour[date]?.kcal)
            }
            let rawHRVObservations = hrv.compactMap { sample -> HRVObservation? in
                guard let q = sample as? HKQuantitySample else { return nil }
                let sdnn = q.quantity.doubleValue(for: .secondUnit(with: .milli))
                let sleeping = allSleep.contains { sample.startDate >= $0.start && sample.endDate <= $0.end }
                let breathwork = mindfulness.contains { $0.startDate < sample.endDate && $0.endDate > sample.startDate }
                let nearTraining = workouts.contains { sample.startDate < $0.endDate.addingTimeInterval(5400) && sample.endDate > $0.startDate.addingTimeInterval(-300) }
                let context: String
                if batteryReadFailed { context = "背景读取失败" }
                else if sleeping { context = "睡眠" }
                else if awakeHRVBackgroundFailed { context = "背景读取失败" }
                else if breathwork { context = "呼吸练习" }
                else if nearTraining { context = "训练附近" }
                else { context = HRVActivityContext.classify(start:sample.startDate,end:sample.endDate,bins:activityBins) }
                return HRVObservation(id: sample.uuid, start: sample.startDate, end: sample.endDate, sdnn: sdnn, context: context, source: streamKey(sample))
            }
            let dayHRV = DayHRVModel.compare(rawHRVObservations,now:now,calendar:calendar)
            let sleepHRVComparisons = HRVContextComparison.compare(rawHRVObservations,context:"睡眠",now:now,calendar:calendar)
            var vitalRows: [VitalRecord] = []
            var nights: [NightRecord] = []
            let episodes = SleepEpisodeEngine.episodes(allSleep,now:now)
            for offset in 0...42 {
                let date = calendar.date(byAdding: .day, value: -offset, to: today)!
                let episode = SleepEpisodeEngine.main(episodes,day:date,calendar:calendar)
                let from = episode?.start ?? date
                let until = episode?.end ?? min(now,date)
                let intervals = episode?.intervals ?? []
                func inSleep(_ sample: HKSample) -> Bool {
                    // Keep only samples wholly within an asleep interval. No invented RMSSD.
                    intervals.contains { sample.startDate >= $0.start && sample.endDate <= $0.end }
                }
                // Compare the same source and sampling-duration class across nights.
                let hrvGroups = Dictionary(grouping:hrv.filter(inSleep).filter { (30...300).contains($0.endDate.timeIntervalSince($0.startDate)) }) { Int(($0.endDate.timeIntervalSince($0.startDate)/30).rounded()) }
                let durationBucket = hrvGroups.keys.sorted().max { (hrvGroups[$0]?.count ?? 0) < (hrvGroups[$1]?.count ?? 0) }
                let nightHRVRows = durationBucket.flatMap { hrvGroups[$0] } ?? []
                let nightlyHRV = nightHRVRows.compactMap { ($0 as? HKQuantitySample)?.quantity.doubleValue(for: .secondUnit(with: .milli)) }.filter { $0.isFinite && $0 > 0 }
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
                                          hrvCount: nightlyHRV.count, heartRateCount: nightlyHR.count, hrvSourceKey:nightHRVRows.first.map(streamKey),heartRateSourceKey:hr.filter(inSleep).first.map(streamKey),hrvDurationBucket:durationBucket,sleepStartedAt:episode?.start,sleepEndedAt:episode?.end,sleepTimeZone:calendar.timeZone.identifier))
            }
            func calorieSamples(_ input:[HKSample]) -> [CalorieSample] {
                input.compactMap { sample in
                    guard let q = sample as? HKQuantitySample else { return nil }
                    let metadata = sample.metadata ?? [:]
                    return CalorieSample(id:sample.uuid,start:sample.startDate,end:sample.endDate,kcal:q.quantity.doubleValue(for:.kilocalorie()),source:streamKey(sample),sourceName:sample.sourceRevision.source.name,watch:sample.sourceRevision.productType?.hasPrefix("Watch") == true || sample.device?.model?.localizedCaseInsensitiveContains("Watch") == true,syncIdentifier:metadata[HKMetadataKeySyncIdentifier] as? String,syncVersion:(metadata[HKMetadataKeySyncVersion] as? NSNumber)?.intValue,lowerKcal:(metadata[EnergyBudgetEngine.lowerMetadata] as? NSNumber)?.doubleValue,upperKcal:(metadata[EnergyBudgetEngine.upperMetadata] as? NSNumber)?.doubleValue)
                }
            }
            let foodSamples = calorieSamples(foodRead.value ?? [])
            let selectedFoodSource = foodSource
            let budgets = EnergyBudgetEngine.days(resting:calorieSamples(basalRead.value ?? []),intake:foodSamples,active:energy.map { EnergyDayRecord(date:$0.date,active:$0.kcal,resting:nil,restingHours:0,restingSource:nil,intake:nil,intakeSource:nil,intakeLower:nil,intakeUpper:nil) },start:recentStart,now:now,foodSource:selectedFoodSource,calendar:calendar)
            var bodyMeasurements:[BodyMeasurement] = []
            for (name,rows,unit,label,accepted) in [("体重",weightRead.value ?? [],HKUnit.gramUnit(with:.kilo),"kg",1.0...500.0),("体脂",fatRead.value ?? [],HKUnit.percent(),"%",0.0...1.0),("去脂体重",leanRead.value ?? [],HKUnit.gramUnit(with:.kilo),"kg",1.0...500.0),("身高",heightRead.value ?? [],HKUnit.meterUnit(with:.centi),"cm",30.0...260.0)] {
                bodyMeasurements += preferred(rows).compactMap { sample in
                    guard let q = sample as? HKQuantitySample,sample.endDate <= now else { return nil }
                    let value = q.quantity.doubleValue(for:unit)
                    guard value.isFinite,accepted.contains(value) else { return nil }
                    return BodyMeasurement(id:sample.uuid,date:sample.endDate,name:name,value:name == "体脂" ? value*100 : value,unit:label,source:sample.sourceRevision.source.name)
                }
            }
            let workoutHearts = hr.compactMap { sample -> WorkoutHeartSample? in
                guard let q = sample as? HKQuantitySample else { return nil }
                return WorkoutHeartSample(date:sample.startDate,bpm:q.quantity.doubleValue(for:HKUnit.count().unitDivided(by:.minute())),source:streamKey(sample))
            }
            let snapshot = HealthSnapshot(fetchedAt: now, nights: nights, coverage: [
                coverage("睡眠（已选来源）", rows: sleep, start: recentStart, end: now, failure: sleepRead.failure),
                coverage("HRV · SDNN（已选来源）", rows: hrv, start: recentStart, end: now, failure: hrvRead.failure),
                coverage("心率（已选来源）", rows: hr, start: recentStart, end: now, failure: hrRead.failure),
                coverage("静息心率", rows: selectedResting, start: recentStart, end: now, failure: restingRead.failure),
                coverage("体能训练", rows: workouts, start: recentStart, end: now, failure: workoutRead.failure),
                coverage("正念时段（HRV 背景）", rows: mindfulness, start: recentStart, end: now, failure: mindfulRead.failure),
                coverage("睡眠呼吸率", rows: respiratory, start: recentStart, end: now, failure: respiratoryRead.failure),
                coverage("睡眠腕温", rows: temperature, start: recentStart, end: now, failure: temperatureRead.failure),
                coverage("血氧", rows: oxygen, start: recentStart, end: now, failure: oxygenRead.failure),
                coverage("静息能量",rows:basalRead.value ?? [],start:recentStart,end:now,failure:basalRead.failure),
                coverage("饮食能量",rows:foodRead.value ?? [],start:recentStart,end:now,failure:foodRead.failure),
                coverage("体重",rows:weightRead.value ?? [],start:recentStart,end:now,failure:weightRead.failure),
                coverage("体脂",rows:fatRead.value ?? [],start:recentStart,end:now,failure:fatRead.failure),
                coverage("去脂体重",rows:leanRead.value ?? [],start:recentStart,end:now,failure:leanRead.failure),
                coverage("身高",rows:heightRead.value ?? [],start:recentStart,end:now,failure:heightRead.failure)
            ], energy: energy, workoutCount: workouts.count, workouts: workouts.compactMap { sample in
                guard let workout = sample as? HKWorkout, workout.endDate > workout.startDate else { return nil }
                let kcal = workout.statistics(for: HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!)?.sumQuantity()?.doubleValue(for: .kilocalorie())
                let priorRest = selectedResting.filter { $0.endDate < workout.startDate && $0.endDate >= workout.startDate.addingTimeInterval(-28*86400) && streamKey($0) == workoutHearts.first?.source }
                let restDays = Dictionary(grouping:priorRest,by:{ calendar.startOfDay(for:$0.endDate) }).values.compactMap { day in
                    RecoveryEngine.median(day.compactMap { ($0 as? HKQuantitySample)?.quantity.doubleValue(for:HKUnit.count().unitDivided(by:.minute())) }.filter { $0.isFinite && (25...150).contains($0) })
                }
                let cardio = WorkoutCardioEngine.evidence(samples:workoutHearts,start:workout.startDate,end:workout.endDate,now:now,resting:restDays.count >= 3 ? RecoveryEngine.median(restDays) : nil)
                return PocketWorkout(id: workout.uuid, title: workoutTitle(workout.workoutActivityType), start: workout.startDate, end: workout.endDate, duration: workout.duration, activeKcal: kcal.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }, source: workout.sourceRevision.source.name, cardio:cardio)
            }, steps: stepDays, hrvObservations: dayHRV, vitals: vitalRows, sleepIntervals: allSleep, readFailures: readFailures, energyBudget: budgets, bodyMeasurements: bodyMeasurements, nutritionSources: EnergyBudgetEngine.sources(foodSamples),readTimeZone:calendar.timeZone.identifier,activityGridAnchor:activityAnchor)
            if sleep.isEmpty && hrv.isEmpty && hr.isEmpty {
                notice = "暂未读到恢复数据。可能没有记录、尚未同步，或未授予读取权限；App 无法区分这些情况。"
            }
                            // Backfill up to a week using recorded data. An existing ledger
            // keeps its original anchor date, avoiding a refresh changing past estimates.
            let weekStart = calendar.date(byAdding: .day, value: -7, to: today)!
            let earliest=max(weekStart,ledger?.hours.first?.start ?? weekStart)
            let start=BatteryActivityGrid.firstBoundary(atOrAfter:earliest,anchor:activityAnchor) ?? earliest
            let sleepIntervals = RecoveryEngine.merged(sleep.map { SleepInterval(start: $0.startDate, end: $0.endDate) }, from: start, to: now)
            var bins: [BatteryHour] = []; var cursor = start
            while cursor < now {
                let end = min(now, cursor.addingTimeInterval(3600))
                let duration = sleepIntervals.reduce(0.0) { total, interval in total + max(0, min(end, interval.end).timeIntervalSince(max(cursor, interval.start))) } / 3600
                let rows = hr.filter { $0.startDate >= cursor && $0.endDate <= end }.compactMap { ($0 as? HKQuantitySample)?.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) }
                let awakeHRRows = hr.filter { sample in
                    sample.startDate >= cursor && sample.endDate <= end && !sleepIntervals.contains {
                        sample.startDate < $0.end && sample.endDate >= $0.start
                    }
                }
                let awakeHRValues = awakeHRRows.compactMap { ($0 as? HKQuantitySample)?.quantity.doubleValue(for: HKUnit.count().unitDivided(by:.minute())) }.filter { $0.isFinite && (25...220).contains($0) }
                let sleepHRVWindow = HRVWindow.summarize(sleepHRVComparisons,context:"睡眠",start:cursor,end:end)
                let awakeHRVWindow = HRVWindow.summarize(dayHRV,context:"安静候选",start:cursor,end:end)
                let priorNights = nights.filter { night in
                    // The noon boundary also prevents same-night or future leakage.
                    (night.sleepEndedAt ?? calendar.date(bySettingHour: 12, minute: 0, second: 0, of: night.date)!) < cursor &&
                    (night.sleepHours ?? 0) > 0
                }.sorted { $0.date > $1.date }.prefix(28)
                let priorResting = selectedResting.filter { sample in
                    sample.endDate < calendar.startOfDay(for:cursor) && sample.endDate >= cursor.addingTimeInterval(-28*86400) && sample.sourceRevision.source.bundleIdentifier == hr.first?.sourceRevision.source.bundleIdentifier && streamKey(sample) == hr.first.map(streamKey)
                }
                let restingDays = Dictionary(grouping:priorResting,by:{calendar.startOfDay(for:$0.endDate)})
                let restingBaseline = restingDays.count >= 3 ? RecoveryEngine.median(restingDays.values.compactMap { rows in
                    RecoveryEngine.median(rows.compactMap { ($0 as? HKQuantitySample)?.quantity.doubleValue(for:HKUnit.count().unitDivided(by:.minute())) }.filter { $0.isFinite && (25...150).contains($0) })
                }) : nil
                let personalHR = RecoveryEngine.median(priorNights.filter { $0.heartRateCount >= 2 }.compactMap(\.heartRate).filter { $0.isFinite && (25...150).contains($0) }) ?? restingBaseline
                let sleepHeartRates = hr.filter { sample in
                    sample.startDate >= cursor && sample.endDate <= end && sleepIntervals.contains { sample.startDate >= $0.start && sample.endDate <= $0.end }
                }.compactMap { ($0 as? HKQuantitySample)?.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) }.filter { $0.isFinite && (25...220).contains($0) }
                let trainingIntervals = RecoveryEngine.merged(workouts.map {
                    SleepInterval(start: $0.startDate, end: $0.endDate)
                }, from: cursor, to: end)
                let trainingHours = trainingIntervals.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) } / 3600
                let trainingSource = hr.first.map(streamKey)
                let trainingNights = Dictionary(grouping:priorNights.filter { $0.heartRateSourceKey == trainingSource && trainingSource != nil && $0.heartRateCount >= 2 },by:{ calendar.startOfDay(for:$0.date) }).values.compactMap { rows in
                    RecoveryEngine.median(rows.compactMap(\.heartRate).filter { $0.isFinite && (25...150).contains($0) })
                }
                let trainingBaseline = (trainingNights.count >= 3 ? RecoveryEngine.median(trainingNights) : nil) ?? restingBaseline
                let workoutSpans = WorkoutHeartFallback.make(samples:workoutHearts,windows:trainingIntervals.map { (start:$0.start,end:$0.end) },excluding:sleepIntervals.map { (start:$0.start,end:$0.end) },start:cursor,end:end,now:now,reference:trainingBaseline,source:trainingSource)
                let latestSignal = (hr.filter { $0.startDate >= cursor && $0.endDate <= end }.map(\.endDate)
                    + hrv.filter { $0.endDate > cursor && $0.endDate <= end }.map(\.endDate)
                    + sleepIntervals.filter { $0.start < end && $0.end > cursor }.map { min(end,$0.end) }
                    + workouts.filter { $0.startDate < end && $0.endDate > cursor }.map { min(end,$0.endDate) }).max()
                bins.append(BatteryHour(start: cursor, end: end, sleepHours: duration, activeKcal: hourly.first { $0.date == cursor }?.kcal, heartRate: RecoveryEngine.median(rows), heartRateCount: rows.count, heartRateCoverageHours: HeartRateCoverage.hours(dates: hr.filter { $0.startDate >= cursor && $0.endDate <= end }.map(\.startDate), start: cursor, end: end), sleepHRVZ: sleepHRVWindow.deviation, sleepHRVCount: sleepHRVWindow.startedSamples, workoutHours: trainingHours, steps: stepHours.first { $0.date == cursor }?.kcal, personalHR: personalHR, sleepHeartRate: sleepHeartRates.count >= 2 ? RecoveryEngine.median(sleepHeartRates) : nil, awakeHRVZ: awakeHRVWindow.deviation, awakeHRVObservedHours: awakeHRVWindow.observedHours, awakeHeartRate: RecoveryEngine.median(awakeHRValues), awakeHeartRateCount: awakeHRValues.count, awakeHeartRateCoverageHours: HeartRateCoverage.hours(dates:awakeHRRows.map(\.startDate),start:cursor,end:end), sleepHRVSampleWeight: sleepHRVWindow.sampleWeight, hrvSourceKey: hrv.first.map(streamKey), hrvContextVersion: 1, inferredNonSleepHours: HeartRateCoverage.inferredHours(dates:hr.filter { $0.startDate >= cursor && $0.endDate <= end }.map(\.startDate),start:cursor,end:end,sleep:sleepIntervals.map { (start:$0.start,end:$0.end) }), latestSignalAt: latestSignal, workoutHeartSpans:workoutSpans))
                cursor = end
            }
            let baselineNights = nights.filter { night in
                night.date < start && (night.sleepHours ?? 0) > 0 && night.heartRateCount >= 2 && night.heartRate.map { $0.isFinite && (25...150).contains($0) } == true
            }
            let sleepKey = sleep.first.map(streamKey) ?? "none"
            let hrKey = hr.first.map(streamKey) ?? "none"
            let sourceKey = sleepKey + "::" + hrKey
            let stateResting = selectedResting.compactMap { sample -> StateHeartSignal? in
                guard let q=sample as? HKQuantitySample else{return nil}
                return StateHeartSignal(date:sample.endDate,bpm:q.quantity.doubleValue(for:HKUnit.count().unitDivided(by:.minute())),resting:true,context:"静息",source:streamKey(sample))
            }
            let stateGroups = Dictionary(grouping:hr.filter { sample in
                sample.endDate >= weekStart && sample.endDate <= now && !allSleep.contains { sample.startDate >= $0.start && sample.endDate <= $0.end }
            },by:{streamKey($0)+"::"+String(calendar.dateInterval(of:.hour,for:$0.endDate)!.start.timeIntervalSinceReferenceDate)})
            let stateHeart = stateGroups.values.compactMap { rows -> StateHeartSignal? in
                guard let latest=rows.max(by:{$0.endDate<$1.endDate}),let value=RecoveryEngine.median(rows.compactMap{($0 as? HKQuantitySample)?.quantity.doubleValue(for:HKUnit.count().unitDivided(by:.minute()))}) else{return nil}
                let hour=calendar.dateInterval(of:.hour,for:latest.endDate)!.start
                let context=workouts.contains{$0.startDate < latest.endDate && $0.endDate.addingTimeInterval(1800)>latest.startDate} ? "训练附近" : HRVActivityContext.classify(start:hour,end:min(now,hour.addingTimeInterval(3600)),bins:activityBins)
                return StateHeartSignal(date:latest.endDate,bpm:value,resting:false,context:context,source:streamKey(latest))
            }
            if batteryReadFailed {
                notice = "部分数据读取失败；身体指标已更新，电量保留上次结果，不将失败当作缺少记录。"
            } else if let ledger, !ledger.matches(source: sourceKey) {
                battery = .empty; battery.computedAt = now
                battery.message = "数据来源需要重新确认"
                notice = "健康来源已变化，或旧账本尚未记录来源。旧电量历史保留，暂不混合计算；在设置清除健康缓存后可重新建立。"
            } else if !hr.isEmpty || !hrv.isEmpty || !selectedResting.isEmpty || bins.contains(where: { $0.sleepHours > 0 || ($0.activeKcal ?? 0) > 0 || $0.heartRate != nil || ($0.workoutHours ?? 0) > 0 || $0.awakeHRVZ != nil }) {
                if ledger == nil { ledger = BatteryLedger(baselineHR: RecoveryEngine.median(baselineNights.compactMap(\.heartRate)), hours: [], sourceKey: sourceKey) }
                ledger?.merge(bins)
                ledger?.activityGridAnchor=activityAnchor
                ledger?.stateSignals = stateResting+stateHeart
                ledger?.stateHRV = rawHRVObservations
                ledger?.continuousVersion = 1
                battery = ledger?.evaluate(now: now) ?? .empty
                if baselineNights.count < 14 && !battery.usesStateEstimate && battery.continuity == nil { battery.message = (ledger?.baselineHR == nil && !bins.contains { $0.personalHR != nil }) ? "初步估计 · 无个人心率基线，未计算心率压力与清醒恢复" : "初步估计 · 个人历史较少" }
            } else {
                battery = .empty; battery.computedAt = now; battery.message = "尚未读到可计算的睡眠、活动或心率记录"
            }
            // A failed reserve dependency does not erase independently readable heart
            // signals. Keep the reserve ledger intact and expose a partial state only.
            if batteryReadFailed,let partial=CurrentStateModel.estimate(signals:stateResting+stateHeart,hrv:[],hours:[],now:now) {
                battery.reserveValue=battery.value; battery.reserveSupported=false; battery.stateEstimate=partial; battery.continuity=nil
                battery.value=partial.value; battery.measuredAt=partial.measuredAt; battery.computedAt=now
                battery.lower=partial.lower; battery.upper=partial.upper
                battery.message="部分类型读取失败，仅按独立可读的心率记录估计近期状态。"
                battery.modelRevision=CurrentStateModel.revision+" / partial heart-only read"
            }
            if !batteryReadFailed, let night = nights.filter({ $0.sleepHours != nil || $0.hrv != nil || $0.heartRate != nil }).max(by: { $0.date < $1.date }) {
                let target = sleepTarget
                let days = nights.map { n in
                    let prior = calendar.date(byAdding: .day, value: -1, to: n.date)!
                    return RecoveryDay(night: n, activeKcal: energy.first { calendar.isDate($0.date, inSameDayAs: prior) }?.kcal, sleepMidpointHour: nil)
                }
                let result = RecoveryModelV2.calculate(days: days, sleepTarget: target).first { calendar.isDate($0.date, inSameDayAs: night.date) }
                battery.recoverySummary = WearableSummary(date: night.date, recovery: result?.score, sleepHours: night.sleepHours, hrv: night.hrv, heartRate: night.heartRate, baselineNights: result?.baselineNights ?? 0, recoveryBasis:result?.scoreBasis,recoveryModelRevision:RecoveryModelV2.revision)
            }
            if !batteryReadFailed { battery.dayHRV = DayHRVModel.summary(dayHRV, now: now, calendar: calendar) }
            if !readFailures.isEmpty { notice = (notice.map { $0+"\n" } ?? "") + "读取失败：" + readFailures.joined(separator:"；") }

        let history = battery.usesStateEstimate ? ledger?.stateHistory(now: now) ?? [] : []
        return HealthRefreshResult(snapshot: snapshot, ledger: ledger, battery: battery, history: history,
                                   notice: notice, snapshotData: try? JSONEncoder().encode(snapshot),
                                   ledgerData: ledger.flatMap { try? JSONEncoder().encode($0) },
                                   shadowInspection: makeShadowInspection(ledger:ledger,status:battery,now:now),
                                   anchorSensitivity: !battery.usesStateEstimate && battery.isFresh(at:now) ? ledger?.anchorSensitivity(now:now):nil)
    }
}
private struct HealthRefreshResult {
    var snapshot: HealthSnapshot
    var ledger: BatteryLedger?
    var battery: PocketStatus
    var history: [BatteryPoint]
    var notice: String?
    var snapshotData: Data?
    var ledgerData: Data?
    var shadowInspection: ShadowReplayInspection?
    var anchorSensitivity:(low:Int,high:Int)?
}

// Invoked only by detached refresh/cache workers. Raw inputs stay in the local ledger.
private func makeShadowInspection(ledger:BatteryLedger?,status:PocketStatus,now:Date) -> ShadowReplayInspection {
    guard let ledger else{return ShadowReplayInspection(readAt:now,availability:.noLedger)}
    guard !status.usesStateEstimate else{return ShadowReplayInspection(readAt:now,availability:.recentStateOnly)}
    guard status.isFresh(at:now) else{return ShadowReplayInspection(readAt:now,availability:.stale)}
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    guard let data=try? encoder.encode(ledger) else{return ShadowReplayInspection(readAt:now,availability:.unidentifiedInputs)}
    let digest=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
    var inspection=ShadowReplayEngine.inspect(ledger:ledger,inputDigest:digest,now:now)
    if let replay=inspection.replay,
       replay.baseline.value != status.value || replay.baseline.measuredAt != status.measuredAt || replay.baseline.modelRevision != status.modelRevision {
        inspection.replay=nil;inspection.availability = .mismatchedResults
    }
    return inspection
}
