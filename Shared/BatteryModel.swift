import Foundation

enum BatteryPointRole: String, Codable { case intervalStart, observation }
struct BatteryPoint: Codable, Identifiable {
    var date: Date
    var value: Double?
    var mode: String
    var effect: BatteryHourEffect? = nil
    var role: BatteryPointRole? = nil
    var id: Date { date }
    func belongs(to start:Date,end:Date,instant:Bool = false) -> Bool {
        instant || role != nil ? date >= start && date < end : date > start && date <= end
    }
    func groupingDate(instant:Bool = false) -> Date {
        instant || role != nil ? date : date.addingTimeInterval(-0.001)
    }
}
struct BatteryHour: Codable, Equatable {
    var start: Date
    var end: Date
    var sleepHours: Double
    var activeKcal: Double?
    var heartRate: Double?
    var heartRateCount: Int
    var heartRateCoverageHours: Double = 0
    // Optional for compatibility with previously saved hourly ledgers.
    var sleepHRVZ: Double? = nil
    var sleepHRVCount: Int? = nil
    var workoutHours: Double? = nil
    var steps: Double? = nil
    var personalHR: Double? = nil
    var sleepHeartRate: Double? = nil
    var awakeHRVZ: Double? = nil
    var awakeHRVObservedHours: Double? = nil
    var awakeHeartRate: Double? = nil
    var awakeHeartRateCount: Int? = nil
    var awakeHeartRateCoverageHours: Double? = nil
    var sleepHRVSampleWeight: Double? = nil
    var hrvSourceKey: String? = nil
    var hrvContextVersion: Int? = nil
    // Time inferred from nearby Watch HR readings; not continuous HR measurement.
    // Nil for old ledgers, which retain their original conservative coverage.
    var inferredNonSleepHours: Double? = nil
    var latestSignalAt: Date? = nil
    // Actual paired training-HR spans; nil in older ledgers. Never inferred wear time.
    var workoutHeartSpans: [WorkoutHeartSpan]? = nil
}
// Shared visual tokens for phone, Watch, and widgets.
enum PocketPalette {
    static let paper = (0.975, 0.975, 0.957)
    static let ink = (0.08, 0.10, 0.10)
    static let green = (0.09, 0.28, 0.22)
    static let drain = (0.74, 0.27, 0.03)
    static let mint = (0.30, 0.67, 0.54)
    static let nightGreen = (0.65, 0.85, 0.73)
}
struct WearableSummary: Codable {
    var date: Date
    var recovery: Int?
    var sleepHours: Double?
    var hrv: Double?
    var heartRate: Double?
    var baselineNights: Int
    var recoveryBasis: String? = nil
    var recoveryModelRevision: String? = nil
}
struct BatteryHourEffect: Codable {
    var sleepRecharge: Double
    var restRecharge: Double
    var awakeDrain: Double
    var activityDrain: Double
    var heartRateDrain: Double
    var hrvDrain: Double
    var sleepHRVAdjustment: Double
    // Signed clipping contribution makes saved factors reconcile with curve change.
    var boundaryAdjustment: Double? = nil
    var activityExperiment: ActivityFusionDecision? = nil
    var activityAssessment: ActivityFusionAssessment? = nil
}
struct BatteryInputSummary: Codable {
    var date: Date
    var sleepHours: Double = 0
    var sleepHRVHours: Double = 0
    var awakeHRVMinutes: Double = 0
    var activeKcal: Double = 0
    var observedHours: Double = 0
    var sleepHRVSamples: Int? = nil
    var sleepHRVAdjustment: Double? = nil
    var awakeHRVDrain: Double? = nil
    var activityDrain: Double? = nil
    var latestSleepEnd: Date? = nil
    var unobservedHours: Double? = nil
    var workoutHeartFallbackDrain: Double? = nil
}
struct PocketStatus: Codable {
    var computedAt: Date
    var measuredAt: Date?
    var value: Int?
    var lower: Int?
    var upper: Int?
    var charged: Int
    var drained: Int
    var message: String
    var points: [BatteryPoint]
    var demo: Bool
    var recoverySummary: WearableSummary? = nil
    var dayHRV: DayHRVSummary? = nil
    var inputs: BatteryInputSummary? = nil
    var actionTitle:String? = nil
    var actionDate:Date? = nil
    var modelRevision: String? = nil
    var stateEstimate: CurrentStateEstimate? = nil
    var reserveSupported: Bool? = nil
    var reserveValue: Int? = nil
    var continuity: BatteryContinuity? = nil
    var usesStateEstimate: Bool { reserveSupported == false }
    var displayDate: Date? { usesStateEstimate ? stateEstimate?.measuredAt : measuredAt }
    static var empty: PocketStatus { PocketStatus(computedAt: .distantPast, measuredAt: nil, value: nil, lower: nil, upper: nil, charged: 0, drained: 0, message: "等待 iPhone 同步", points: [], demo: false) }
    func isFresh(at now: Date) -> Bool {
        if usesStateEstimate { return stateEstimate?.isUsable(at:now) == true }
        guard let measuredAt, let value, (0...100).contains(value) else { return false }
        return now.timeIntervalSince(measuredAt) >= -60 && now.timeIntervalSince(measuredAt) <= 7200 && (continuity != nil || Calendar.current.isDate(measuredAt, inSameDayAs: now))
    }
    var evidenceLabel: String {
        if usesStateEstimate { return stateEstimate?.basis ?? "等待近期信号" }
        if let continuity { return continuity.restarted ? "分段电量 · 查看缺测说明" : "连续电量 · 查看计算依据" }
        guard let inputs else { return "读取计算依据" }
        return inputs.sleepHRVHours > 0 || inputs.awakeHRVMinutes > 0 ? "包含 HRV 参考" : "睡眠与活动估计"
    }
    func dataNote(at now: Date) -> String? {
        if usesStateEstimate { return stateEstimate?.note ?? "尚无可用的近期信号；缺失不代表电量为零。" }
        if let continuity { return continuity.note }
        guard let inputs else { return nil }
        if inputs.latestSleepEnd.map({ now.timeIntervalSince($0) > 18*3600 }) ?? true {
            return "近 18 小时未读到睡眠，恢复可能尚未计入。"
        }
        if inputs.sleepHRVHours == 0 && inputs.awakeHRVMinutes == 0 {
            return "当前时段没有可比 HRV，按睡眠与活动估计。"
        }
        if (inputs.unobservedHours ?? 0) > 2 { return "部分时段缺少记录，电量参考仍有较大不确定性。" }
        return nil
    }
    func displayValue(at now: Date) -> Int? { isFresh(at: now) ? (usesStateEstimate ? stateEstimate?.value : value) : nil }
}

/// Experimental reserve estimate, not Garmin's proprietary Body Battery.
/// Recorded sleep and sufficiently sampled low activity may charge; unknown time never does.
/// Awake heart rate is a nonspecific strain proxy, not an HRV stress measurement.
/// Shared meaning, independent of scoring. Initial engineering priors must not
/// be presented as an individually established physiological comparison.
enum PocketScoreKind:String {case initialState,personalState,legacyState,reserve}
struct PocketScoreMeaning {
    var kind:PocketScoreKind
    var title:String {
        switch kind {case .initialState:return "起始参考";case .personalState:return "状态参考";case .legacyState:return "旧版状态";case .reserve:return "身体电量"}
    }
    var qualifier:String {
        switch kind {case .initialState:return "起始假设 · 未个性化";case .personalState:return "个人比较 · 未校准";case .legacyState:return "等待手机重新计算";case .reserve:return "连续估计 · 未校准"}
    }
    var headline:String {
        switch kind {case .initialState:return "个人依据尚不足";case .personalState:return "已有个人信号比较";case .legacyState:return "请在 iPhone 刷新";case .reserve:return "按观测时段承接"}
    }
    var symbol:String {
        switch kind {case .initialState:return "questionmark.circle";case .personalState:return "waveform.path.ecg";case .legacyState:return "clock.arrow.circlepath";case .reserve:return "battery.75percent"}
    }
    var detail:String {
        switch kind {
        case .initialState:return "这个数仍包含中性起始假设；已有信号会保留，但尚不足以建立个人心率或HRV比较。它不能用来认定恢复正常。"
        case .personalState:return "已有至少一项同来源个人历史比较；它仍是未校准的近期状态参考，不是剩余身体电量。"
        case .legacyState:return "这份旧摘要没有可核对的新版依据。保留原记录，请在手机重新读取并计算。"
        case .reserve:return "随已记录睡眠、活动和心率等逐段累计；起点与系数仍为工程假设，不是生理测量。"
        }
    }
    init(status:PocketStatus) {
        guard status.usesStateEstimate else{kind = .reserve;return}
        var verified=status;verified.demo=false
        guard RecentStateCachePolicy.compatible(verified),let factors=status.stateEstimate?.factors else{kind = .legacyState;return}
        let keys:Set<String>=["hrv","restingHR","quietHR"]
        kind=factors.contains{keys.contains($0.key) && $0.baselineDays>=3} ? .personalState:.initialState
    }
}
extension PocketStatus {var scoreMeaning:PocketScoreMeaning {PocketScoreMeaning(status:self)}}

enum BatteryCalculationPolicy { case legacy, continuous }
/// Exposed for offline sensitivity experiments only; standard values are unchanged.
struct BatteryModelParameters: Equatable {
    var sleepRecoveryHours: Double = 6
    var quietRecoveryHours: Double = 14
    var kcalPerPoint: Double = 35
    static let standard = BatteryModelParameters()
    var safe: Self {
        Self(sleepRecoveryHours:sleepRecoveryHours.isFinite && sleepRecoveryHours > 0 ? sleepRecoveryHours : 6,
             quietRecoveryHours:quietRecoveryHours.isFinite && quietRecoveryHours > 0 ? quietRecoveryHours : 14,
             kcalPerPoint:kcalPerPoint.isFinite && kcalPerPoint > 0 ? kcalPerPoint : 35)
    }
}
enum BatteryModel {
    static func calculate(hours: [BatteryHour], anchor: Double?, baselineHR: Double?, nightHRVZ: Double = 0, now: Date, calendar: Calendar = .current, initialUncertainty: Double = 12, policy: BatteryCalculationPolicy = .legacy, parameters: BatteryModelParameters = .standard, activityExperiment: ActivityFusionPolicy? = nil) -> PocketStatus {
        let parameters = parameters.safe
        guard let anchor, anchor.isFinite else {
            var empty = PocketStatus.empty; empty.computedAt = now; empty.message = "等待可计算的记录"; return empty
        }
        let legacyReferenceHR = baselineHR.flatMap { $0.isFinite && (25...150).contains($0) ? $0 : nil }
        var reserve = min(100, max(5, anchor)), uncertainty = initialUncertainty.isFinite ? min(40, max(8, initialUncertainty)) : 30
        var charged = 0.0, drained = 0.0, points: [BatteryPoint] = []
        var last: Date?
        let today = calendar.startOfDay(for: now)
        var inputs = BatteryInputSummary(date: today)
        var previousEnd: Date?
        var evidenceHoursToday = 0.0
        for hour in hours.sorted(by: { $0.start < $1.start }) {
            guard hour.start < now, hour.end > hour.start, hour.end <= now, previousEnd.map({ hour.start >= $0 }) ?? true else { continue }
            if let previousEnd, hour.start > previousEnd { uncertainty = min(40, uncertainty + hour.start.timeIntervalSince(previousEnd) / 3600 * 2) }
            previousEnd = hour.end
            let duration = hour.end.timeIntervalSince(hour.start) / 3600
            let sleep = hour.sleepHours.isFinite ? min(duration, max(0, hour.sleepHours)) : 0
            let energy = hour.activeKcal.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let awake = duration - sleep
            let count = hour.awakeHeartRateCount ?? hour.heartRateCount
            let rawHR = hour.awakeHeartRateCount == nil ? hour.heartRate : hour.awakeHeartRate
            let hr = rawHR.flatMap { $0.isFinite && (25...220).contains($0) && count >= (policy == .continuous ? 1 : 2) ? $0 : nil }
            let trainingCoverage = hour.workoutHours.flatMap { $0.isFinite ? min(awake,max(0,$0)) : nil } ?? 0
            let hrvCoverage = hour.awakeHRVZ?.isFinite == true ? (hour.awakeHRVObservedHours.flatMap { $0.isFinite ? min(awake,max(0,$0)) : nil } ?? 0) : 0
            guard sleep > 0 || (energy ?? 0) > 0 || hr != nil || trainingCoverage > 0 || (hrvCoverage > 0 && hour.awakeHRVZ?.isFinite == true) else {
                uncertainty = min(40, uncertainty + duration * 2)
                if hour.end > today { inputs.unobservedHours = (inputs.unobservedHours ?? 0) + hour.end.timeIntervalSince(max(today,hour.start))/3600 }
                points.append(BatteryPoint(date: hour.end, value: nil, mode: "缺少采样")); continue
            }
            let referenceHR = hour.personalHR.flatMap { $0.isFinite && (25...150).contains($0) ? $0 : nil } ?? legacyReferenceHR
            if let tail = points.last, tail.value == nil || tail.date < hour.start {
                // Keep an explicit break, then resume from the carried model reserve.
                // Never connect an unknown interval to the next observed interval.
                if tail.value == nil && tail.date == hour.start { points[points.count-1].date = hour.start.addingTimeInterval(-0.001) }
                else if tail.date < hour.start { points.append(BatteryPoint(date:tail.date.addingTimeInterval(hour.start.timeIntervalSince(tail.date)/2),value:nil,mode:"缺少采样")) }
                points.append(BatteryPoint(date:hour.start,value:reserve,mode:"承接估计 · 非观测",role:.intervalStart))
            } else if points.isEmpty { points.append(BatteryPoint(date:hour.start,value:reserve,mode:"模型起点 · 非观测",role:.intervalStart)) }
            // Coefficients are initial engineering assumptions awaiting personal validation.
            // Only same-context, observed sleep HRV may modulate sleep recharge.
            // A night-wide caller value is retained only for legacy synthetic comparisons.
            let hrvZ = hour.sleepHRVZ.flatMap { $0.isFinite ? max(-3, min(3, $0)) : nil }
                ?? (nightHRVZ.isFinite ? max(-3, min(3, nightHRVZ)) : 0)
            let sleepRate = hour.sleepHeartRate.flatMap { $0.isFinite && (25...220).contains($0) ? $0 : nil } ?? (sleep >= duration * 0.9 ? hr : nil)
            let sleepHRElevation = sleepRate.flatMap { rate in referenceHR.map { max(0, min(1, (rate - $0 - 5) / 20)) } } ?? 0
            // A lone SDNN sample has less influence than several comparable observations.
            // Unusually high values do not produce an unlimited recovery reward.
            let evidenceCount = hour.sleepHRVSampleWeight.flatMap { $0.isFinite ? max(0,$0) : nil } ?? hour.sleepHRVCount.map { Double(max(0,$0)) }
            // Four comparable samples per hour is an engineering confidence prior.
            // Normalize by interval duration so splitting pure sleep does not change it.
            let sampleWeight = evidenceCount.map { min(1,$0/(4*duration)) } ?? (hour.sleepHRVZ == nil ? 1 : 0.25)
            let hrvAdjustment = hrvZ > 2 ? 0 : max(-0.3,min(0.1,hrvZ * 0.1)) * sampleWeight
            let qualityWithoutHRV = max(0.45,min(1.15,1 - sleepHRElevation * 0.35))
            let quality = max(0.45, min(1.15, 1 + hrvAdjustment - sleepHRElevation * 0.35))
            let exercising = hour.workoutHours.map { $0.isFinite && $0 > 0 } == true
            let moving = exercising || hour.steps.map { $0.isFinite && $0 > 100 * duration } == true
            // Legacy bins have no context split. Conservatively subtract sleep rather
            // than treating sleeping readings as evidence of awake strain or rest.
            let rawCoverage = hour.awakeHeartRateCoverageHours ?? max(0,hour.heartRateCoverageHours-sleep)
            let inferred = policy == .continuous ? hour.inferredNonSleepHours.flatMap { $0.isFinite ? max(0,$0) : nil } ?? 0 : 0
            let coverage = hr != nil && rawCoverage.isFinite ? min(awake,max(0,max(rawCoverage,inferred))) : 0
            let lowObservedHRV = hour.awakeHRVZ.map { $0.isFinite && $0 < -1 } == true
            let observedRest = !moving && (policy == .continuous ? coverage > 0 : coverage >= duration * 0.5) && awake > 0 && count >= 6 && energy.map { $0 <= 5 * duration } == true && hr.flatMap { rate in referenceHR.map { rate <= $0 + 8 } } == true
            // A bounded recovery process replaces the old fixed +6/h, which trapped
            // depleted reserves near 53 after eight hours. Tau=6h is an explicit
            // engineering prior, not a physiological constant or Garmin formula.
            // The exponential is invariant to splitting a pure sleep interval.
            let sleepRecharge = (100 - reserve) * (1 - exp(-sleep * quality / parameters.sleepRecoveryHours))
            // A short low-HRV observation can reduce rest credit only for that window.
            let eligibleRest = max(0,min(awake,coverage) - (lowObservedHRV ? hrvCoverage : 0))
            // Slow, bounded recovery during supported quiet rest. This is an
            // explicit engineering prior (14h), distinct from recorded sleep (6h).
            let restRecharge = observedRest ? (policy == .continuous
                ? max(0,100-reserve-sleepRecharge)*(1-exp(-eligibleRest/parameters.quietRecoveryHours))
                : eligibleRest * 1.8) : 0
            let recharge = sleepRecharge + restRecharge
            let strain = hr.flatMap { rate in referenceHR.map { max(0, min(3, (rate - $0 - 15) / 15)) } } ?? 0
            // Do not double-penalize elevated HR during a high-activity hour.
            let unexplainedStrain = moving || energy.map { $0 > 35 * duration } == true ? 0 : strain
            // Sparse daytime SDNN influences only observed minutes; never fills an hour.
            let hrvStrain = !moving ? hour.awakeHRVZ.flatMap { $0.isFinite ? max(0, min(3, -$0)) : nil } ?? 0 : 0
            let extraHRVDrain = max(0, hrvStrain - unexplainedStrain) * 0.7 * hrvCoverage
            // Hourly calories do not establish an entire hour of wakefulness.
            // Restrict time-based drain to observed HR/HRV or recorded workout coverage.
            let awakeCoverage = min(awake,max(coverage,max(hrvCoverage,trainingCoverage)))
            let restingCoverage = policy == .continuous && observedRest ? eligibleRest : 0
            let awakeDrain = max(0,awakeCoverage-restingCoverage) * 1.1
            // When energy is absent, a workout must not erase observed cardiac
            // strain. Reuse the existing capped HR coefficient only over actual
            // paired workout spans. Recorded energy (including zero) disables it.
            let workoutStrain = policy == .continuous && energy == nil
                ? WorkoutHeartFallback.strainHours(hour.workoutHeartSpans ?? [],start:hour.start,end:hour.end,now:now,maximumHours:trainingCoverage) : 0
            let fallbackHRDrain = workoutStrain * 0.7
            let hrDrain = max(unexplainedStrain * 0.7 * min(awake,coverage),fallbackHRDrain)
            let assessment = activityExperiment.map { ActivityFusionEngine.assess(hour:hour,now:now,policy:$0) }
            let experiment = assessment?.decision
            let activityDrain = experiment?.replacementDrain ?? (energy ?? 0) / parameters.kcalPerPoint
            let drain = awakeDrain + hrDrain + activityDrain + extraHRVDrain
            let sleepHRVDelta = sleepRecharge - (100 - reserve) * (1 - exp(-sleep * qualityWithoutHRV / parameters.sleepRecoveryHours))
            let next = min(100, max(5, reserve + recharge - drain))
            let boundaryAdjustment = next-(reserve+recharge-drain)
            if sleep > 0 { inputs.latestSleepEnd = hour.end }
            if hour.end > today {
                let fraction = min(1, hour.end.timeIntervalSince(max(today, hour.start)) / (duration * 3600))
                charged += max(0, next - reserve) * fraction; drained += max(0, reserve - next) * fraction
                inputs.sleepHours += sleep * fraction
                if hour.sleepHRVZ?.isFinite == true { inputs.sleepHRVHours += sleep * fraction }
                inputs.awakeHRVMinutes += hrvCoverage * 60 * fraction
                inputs.sleepHRVSamples = (inputs.sleepHRVSamples ?? 0) + (sleep > 0 && hour.sleepHRVZ?.isFinite == true ? max(0,hour.sleepHRVCount ?? 0) : 0)
                inputs.sleepHRVAdjustment = (inputs.sleepHRVAdjustment ?? 0) + sleepHRVDelta * fraction
                inputs.awakeHRVDrain = (inputs.awakeHRVDrain ?? 0) + extraHRVDrain * fraction
                inputs.activityDrain = (inputs.activityDrain ?? 0) + activityDrain * fraction
                inputs.workoutHeartFallbackDrain = (inputs.workoutHeartFallbackDrain ?? 0) + fallbackHRDrain * fraction
                inputs.activeKcal += (energy ?? 0) * fraction
                inputs.observedHours += duration * fraction
                evidenceHoursToday += min(duration,sleep+awakeCoverage) * fraction
            }
            reserve = next; last = hour.end
            uncertainty = min(40, max(8, uncertainty + max(0,duration-sleep-awakeCoverage) * 0.8 - (sleep+awakeCoverage) * 0.15))
            points.append(BatteryPoint(date: hour.end, value: reserve, mode: recharge > drain ? (sleep > 0 ? "睡眠补充" : "低活动补充") : (exercising ? "训练消耗" : unexplainedStrain > 0 ? "心率偏高消耗" : "活动消耗"), effect: BatteryHourEffect(sleepRecharge:sleepRecharge,restRecharge:restRecharge,awakeDrain:awakeDrain,activityDrain:activityDrain,heartRateDrain:hrDrain,hrvDrain:extraHRVDrain,sleepHRVAdjustment:sleepHRVDelta,boundaryAdjustment:boundaryAdjustment,activityExperiment:experiment,activityAssessment:assessment)))
        }
        if let previousEnd { uncertainty = min(40,uncertainty+max(0,now.timeIntervalSince(previousEnd))/3600*2) }
        inputs.unobservedHours = max(0,now.timeIntervalSince(today)/3600-evidenceHoursToday)
        let value = last == nil ? nil : Int(reserve.rounded())
        return PocketStatus(computedAt: now, measuredAt: last, value: value,
            lower: value.map { max(5, Int((Double($0) - uncertainty).rounded())) },
            upper: value.map { min(100, Int((Double($0) + uncertainty).rounded())) },
            charged: Int(charged.rounded()), drained: Int(drained.rounded()),
            message: last == nil ? "缺少日内观测" : "身体电量参考 · 实验模型", points: points, demo: false, inputs: inputs, modelRevision:activityExperiment.map { parameters == .standard ? $0.revision : $0.revision+" / offline parameter sensitivity" } ?? "0.6 / comparable HRV and coverage")
    }
}

enum BatteryDemo {
    static func recentStateStatus(now:Date = Date()) -> PocketStatus {
        let calendar=Calendar.current
        let signals=(1...15).map { StateHeartSignal(date:calendar.date(byAdding:.day,value:-$0,to:now)!,bpm:60,resting:true,context:"静息",source:"synthetic-demo") }+[StateHeartSignal(date:now.addingTimeInterval(-300),bpm:63,resting:true,context:"静息",source:"synthetic-demo")]
        let baseline=(1...15).map { index -> HRVObservation in let end=calendar.date(byAdding:.day,value:-index,to:now)!;return HRVObservation(id:UUID(),start:end.addingTimeInterval(-60),end:end,sdnn:50,context:"安静候选",source:"synthetic-demo") }
        let end=now.addingTimeInterval(-300)
        let hrv=baseline+[HRVObservation(id:UUID(),start:end.addingTimeInterval(-60),end:end,sdnn:42,context:"安静候选",source:"synthetic-demo")]
        let ledger=BatteryLedger(baselineHR:60,hours:[],sourceKey:"synthetic-demo",stateSignals:signals,stateHRV:hrv)
        var status=ledger.status(now:now);status.demo=true;status.points=ledger.stateHistory(now:now)
        return status
    }
    static func status(now: Date = Date()) -> PocketStatus {
        let calendar = Calendar.current, today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -1, to: today)!
        var hours: [BatteryHour] = []; var date = start
        while date < now {
            let end = min(now, date.addingTimeInterval(3600)), h = calendar.component(.hour, from: date)
            let sleeping = h < 7 || h >= 23
            let duration = end.timeIntervalSince(date) / 3600
            hours.append(BatteryHour(start: date, end: end, sleepHours: sleeping ? duration : 0,
                activeKcal: (sleeping ? 0 : h == 18 ? 150 : h == 12 ? 180 : h == 8 ? 65 : 18) * duration,
                heartRate: sleeping ? 54 : h == 18 ? 112 : 73, heartRateCount: 8, heartRateCoverageHours: duration * 0.8))
            date = end
        }
        var result = BatteryModel.calculate(hours: hours, anchor: 55, baselineHR: 54, now: now)
        result.demo = true; result.message = "合成演示 · 非真实健康数据"; return result
    }
}

/// One absolute-hour grid per ledger. Local midnight may move by 30 or 45
/// minutes after travel; the energy query and reserve bins must still match.
enum HealthRefreshCachePolicy {
    static func mayReuse(fetchedAt:Date,readTimeZone:String?,failures:[String],ledgerVersion:Int?,now:Date,currentTimeZone:String)->Bool {
        let age=now.timeIntervalSince(fetchedAt)
        return ledgerVersion==1 && age.isFinite && age>=0 && age<60 && failures.isEmpty &&
            readTimeZone==currentTimeZone && !currentTimeZone.isEmpty
    }
}

enum BatteryActivityGrid {
    static func anchor(saved:Date?,first:Date?,fallback:Date)->Date {
        for date in [saved,first,fallback].compactMap({$0}) where date.timeIntervalSinceReferenceDate.isFinite {return date}
        return Date(timeIntervalSinceReferenceDate:0)
    }
    static func firstBoundary(atOrAfter date:Date,anchor:Date)->Date? {
        let offset=date.timeIntervalSince(anchor)
        guard date.timeIntervalSinceReferenceDate.isFinite,anchor.timeIntervalSinceReferenceDate.isFinite,offset.isFinite else{return nil}
        let result=anchor.addingTimeInterval(ceil(offset/3600)*3600)
        return result.timeIntervalSinceReferenceDate.isFinite ? result:nil
    }
}

/// Retains timestamped aggregate bins so refresh/restart never reanchors to a morning score.
/// Initial 50 is an explicit neutral engineering prior, not a readiness measurement.
struct BatteryLedger: Codable {
    var baselineHR: Double?
    var hours: [BatteryHour]
    // Device/source identity stays local; nil marks a pre-identity ledger.
    var sourceKey: String? = nil
    var stateSignals: [StateHeartSignal]? = nil
    var stateHRV: [HRVObservation]? = nil
    var continuousVersion: Int? = nil
    var continuousOrigins: [BatteryOrigin]? = nil
    var activityGridAnchor:Date? = nil
    func matches(source: String) -> Bool { sourceKey == source }
    mutating func merge(_ incoming: [BatteryHour]) {
        var bins = Dictionary(hours.map { ($0.start, $0) }, uniquingKeysWith: { _, newer in newer })
        for hour in incoming {
            if continuousVersion == 1, let previous = bins[hour.start] {
                var content = hour; content.end = previous.end
                // Querying later is not a new observation. In particular, do not
                // lengthen a partial hour and manufacture rest/recovery or freshness.
                if content == previous { continue }
            }
            bins[hour.start] = hour
        }
        hours = bins.values.sorted { $0.start < $1.start }
    }
    private var comparableHours: [BatteryHour] {
        // Legacy production bins lack duration/source provenance. Keep their actual
        // sleep/activity/HR records, but do not reuse an unverified HRV adjustment.
        guard sourceKey != nil else { return hours }
        return hours.map { original in
            var hour = original
            if hour.hrvContextVersion != 1 || hour.hrvSourceKey == nil {
                hour.sleepHRVZ = nil; hour.sleepHRVCount = 0; hour.sleepHRVSampleWeight = 0
                hour.awakeHRVZ = nil; hour.awakeHRVObservedHours = 0
            }
            return hour
        }
    }
    func experimentalStatus(now:Date,origins:[BatteryOrigin]) -> PocketStatus {
        var status=ContinuousBatteryModel.calculate(hours:comparableHours,signals:stateSignals ?? [],hrv:stateHRV ?? [],baselineHR:baselineHR,now:now,origins:origins,activityExperiment:.cardioEnergyV1)
        status.modelRevision=ActivityFusionPolicy.cardioEnergyV1.revision
        status.message="训练强度影子回放 · 未启用、未校准"
        return status
    }
    func anchorSensitivity(now:Date) -> (low:Int,high:Int)? {
        if continuousVersion == 1 {
            let low = ContinuousBatteryModel.calculate(hours:comparableHours,signals:stateSignals ?? [],hrv:stateHRV ?? [],baselineHR:baselineHR,now:now,anchorOverride:35,origins:continuousOrigins ?? [])
            let high = ContinuousBatteryModel.calculate(hours:comparableHours,signals:stateSignals ?? [],hrv:stateHRV ?? [],baselineHR:baselineHR,now:now,anchorOverride:65,origins:continuousOrigins ?? [])
            guard let a=low.value,let b=high.value else{return nil}
            return (min(a,b),max(a,b))
        }
        let low = BatteryModel.calculate(hours:comparableHours,anchor:35,baselineHR:baselineHR,now:now,initialUncertainty:30)
        let high = BatteryModel.calculate(hours:comparableHours,anchor:65,baselineHR:baselineHR,now:now,initialUncertainty:30)
        guard let a = low.value,let b = high.value else { return nil }
        return (min(a,b),max(a,b))
    }
    /// Evaluate and pin each segment's initial assumption before new samples can
    /// replace the first partial-hour aggregate. This state is persisted with bins.
    mutating func evaluate(now:Date) -> PocketStatus {
        let result = status(now:now)
        if let origins = result.continuity?.origins { continuousOrigins = origins }
        return result
    }
    func status(now: Date) -> PocketStatus {
        if continuousVersion == 1 {
            return ContinuousBatteryModel.calculate(hours:comparableHours,signals:stateSignals ?? [],hrv:stateHRV ?? [],baselineHR:baselineHR,now:now,origins:continuousOrigins ?? [])
        }
        var result = BatteryModel.calculate(hours: comparableHours, anchor: 50, baselineHR: baselineHR, now: now, initialUncertainty: 30)
        if stateSignals != nil || stateHRV != nil {
            let recentSleep = comparableHours.contains { $0.end <= now && $0.end > now.addingTimeInterval(-36*3600) && $0.sleepHours > 0 }
            let supported = recentSleep && result.isFresh(at:now)
            result.reserveSupported = supported
            result.stateEstimate = CurrentStateModel.estimate(signals:stateSignals ?? [],hrv:stateHRV ?? [],hours:comparableHours,now:now)
            if !supported {
                result.reserveValue = result.value
                result.value = result.stateEstimate?.value; result.measuredAt = result.stateEstimate?.measuredAt
                result.lower = result.stateEstimate?.lower; result.upper = result.stateEstimate?.upper
                result.message = recentSleep ? "连续电量观测较旧，改用近期状态估计。" : "近期睡眠记录缺失，改用近期状态估计；未将缺失当作持续清醒。"
            }
            result.modelRevision = supported ? "0.13 / reserve and recent state separated" : CurrentStateModel.revision
        }
        return result
    }
    func stateHistory(now:Date) -> [BatteryPoint] {
        let start = Calendar.current.date(byAdding:.day,value:-7,to:Calendar.current.startOfDay(for:now))!
        let times = Set((stateSignals ?? []).filter { $0.date >= start && $0.date <= now }.map(\.date) + (stateHRV ?? []).filter { $0.end >= start && $0.end <= now }.map(\.end)).sorted()
        // Each observation's baseline is strictly before its own start. Computing
        // it once is safe for historical points; future samples cannot enter it.
        let observations = stateHRV ?? []
        // Conflicting UUID versions need point-in-time deduplication, as in the
        // direct estimator. Fall back rather than let a future duplicate win.
        let hasDuplicateIDs = Set(observations.map(\.id)).count != observations.count
        let compared = hasDuplicateIDs ? nil : CurrentStateModel.comparisons(observations, now: now)
        let hours = comparableHours
        return times.compactMap { date in
            guard let state = CurrentStateModel.estimate(signals:stateSignals ?? [],hrv:observations,hours:hours,now:date,comparisons:compared),state.measuredAt == date else { return nil }
            return BatteryPoint(date:date,value:Double(state.value),mode:"近期状态估计 · 非电量收支")
        }
    }
}
enum HeartRateCoverage {
    /// Infer time only between two actual readings at most ten minutes apart.
    /// Do not extend outside the pair or bridge an unworn night. Exclude actual
    /// sleep overlap; missing sleep remains a visible model limitation.
    static func inferredHours(dates:[Date],start:Date,end:Date,sleep:[(start:Date,end:Date)] = []) -> Double {
        let times = Array(Set(dates.filter { $0 >= start && $0 <= end })).sorted()
        var seconds = 0.0
        for (a,b) in zip(times,times.dropFirst()) where b.timeIntervalSince(a) <= 600 {
            var pieces = [(a,b)]
            for interval in sleep {
                pieces = pieces.flatMap { from,until -> [(Date,Date)] in
                    guard interval.start < until && interval.end > from else { return [(from,until)] }
                    var kept:[(Date,Date)] = []
                    if from < interval.start { kept.append((from,min(until,interval.start))) }
                    if until > interval.end { kept.append((max(from,interval.end),until)) }
                    return kept
                }
            }
            seconds += pieces.reduce(0) { $0+max(0,$1.1.timeIntervalSince($1.0)) }
        }
        return min(max(0,end.timeIntervalSince(start)),seconds)/3600
    }
    /// At most one minute between nearby readings; long gaps never count as observation.
    static func hours(dates: [Date], start: Date, end: Date) -> Double {
        let times = Array(Set(dates.filter { $0 >= start && $0 <= end })).sorted()
        return zip(times, times.dropFirst()).reduce(0.0) { total, pair in
            let gap = pair.1.timeIntervalSince(pair.0)
            return total + (gap <= 300 ? min(60, max(0, gap)) : 0)
        } / 3600
    }
}


struct PocketWorkout: Codable, Identifiable {
    var id: UUID
    var title: String
    var start: Date
    var end: Date
    var duration: Double
    var activeKcal: Double?
    var source: String
    var cardio: WorkoutCardioEvidence? = nil
}
// A temporal association with a recorded workout, not a causal or muscular-load claim.
struct WorkoutHeartSpan: Codable, Equatable {
    var start: Date
    var end: Date
    var strain: Double
    var referenceHR: Double
    var source: String
    var averageHR: Double? = nil
}
enum WorkoutHeartFallback {
    static func make(samples:[WorkoutHeartSample],windows:[(start:Date,end:Date)],excluding:[(start:Date,end:Date)] = [],start:Date,end:Date,now:Date,reference:Double?,source:String?) -> [WorkoutHeartSpan] {
        guard start < end,end <= now,let reference,reference.isFinite,(25...150).contains(reference),let source,!source.isEmpty else { return [] }
        let rows = samples.filter { $0.source == source && $0.date <= now && $0.date >= start.addingTimeInterval(-90) && $0.date <= end && $0.bpm.isFinite && (25...220).contains($0.bpm) }
        let dates = Dictionary(grouping:rows,by: \.date)
        let ordered = dates.keys.sorted().map { date -> WorkoutHeartSample in
            let values = dates[date]!.map(\.bpm).sorted(),m=values.count/2
            return WorkoutHeartSample(date:date,bpm:values.count.isMultiple(of:2) ? (values[m-1]+values[m])/2 : values[m],source:source)
        }
        let intervals = windows.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var merged:[(start:Date,end:Date)] = []
        for window in intervals {
            if let last=merged.last,window.start <= last.end { merged[merged.count-1].end=max(last.end,window.end) }
            else { merged.append(window) }
        }
        var result:[WorkoutHeartSpan] = []
        for (a,b) in zip(ordered,ordered.dropFirst()) where b.date > a.date && b.date.timeIntervalSince(a.date) <= 90 {
            let strain=max(0,min(3,((a.bpm+b.bpm)/2-reference-15)/15))
            for window in merged {
                let lower=max(start,max(a.date,window.start)),upper=min(end,min(b.date,window.end))
                guard upper > lower else { continue }
                var pieces=[(start:lower,end:upper)]
                for blocked in excluding where blocked.end > blocked.start {
                    pieces=pieces.flatMap { piece -> [(start:Date,end:Date)] in
                        guard blocked.end > piece.start && blocked.start < piece.end else { return [piece] }
                        var kept:[(start:Date,end:Date)] = []
                        if blocked.start > piece.start { kept.append((piece.start,min(piece.end,blocked.start))) }
                        if blocked.end < piece.end { kept.append((max(piece.start,blocked.end),piece.end)) }
                        return kept
                    }
                }
                result += pieces.map { WorkoutHeartSpan(start:$0.start,end:$0.end,strain:strain,referenceHR:reference,source:source,averageHR:(a.bpm+b.bpm)/2) }
            }
        }
        return result
    }
    static func strainHours(_ input:[WorkoutHeartSpan],start:Date,end:Date,now:Date,maximumHours:Double) -> Double {
        guard maximumHours.isFinite,maximumHours > 0,end > start,end <= now else { return 0 }
        let valid=input.filter { $0.start >= start && $0.end <= end && $0.end > $0.start && $0.end.timeIntervalSince($0.start) <= 90 && $0.strain.isFinite && (0...3).contains($0.strain) && $0.referenceHR.isFinite && (25...150).contains($0.referenceHR) && !$0.source.isEmpty }
        // A malformed mixed-reference/source ledger cannot create fallback strain.
        guard Set(valid.map(\.source)).count == 1,Set(valid.map(\.referenceHR)).count == 1 else { return 0 }
        var previous:Date?,hours=0.0,total=0.0
        for row in valid.sorted(by:{
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.strain < $1.strain
        }) {
            guard previous.map({row.start >= $0}) ?? true else { continue }
            previous=row.end
            let span=row.end.timeIntervalSince(row.start)/3600
            // Inconsistent aggregate metadata cannot claim more than training time.
            guard hours+span <= maximumHours+1e-8 else { return 0 }
            hours += span; total += row.strain*span
        }
        return total
    }
}
struct WorkoutHeartSample {
    var date: Date
    var bpm: Double
    var source: String
}
struct WorkoutCardioEvidence: Codable {
    var coveredMinutes: Double
    var windowMinutes: Double
    var averageHR: Double?
    var peakHR: Double?
    var restingReference: Double?
    var aboveReferenceMinutes: Double?
    var relativeLoadMinutes: Double?
    var source: String
    var coverageFraction: Double { windowMinutes > 0 ? min(1,coveredMinutes/windowMinutes) : 0 }
}
enum WorkoutCardioEngine {
    private static func median(_ values:[Double]) -> Double? {
        let a=values.sorted(); guard !a.isEmpty else { return nil };let m=a.count/2
        return a.count.isMultiple(of:2) ? (a[m-1]+a[m])/2 : a[m]
    }
    /// Integrates adjacent actual readings no more than 90 seconds apart. Gaps,
    /// workout edges and future samples never receive extrapolated heart rates.
    /// Relative load is a provisional weighted-minute proxy, not WHOOP Strain.
    static func evidence(samples:[WorkoutHeartSample],start:Date,end:Date,now:Date,resting:Double?) -> WorkoutCardioEvidence? {
        guard end > start, end <= now else { return nil }
        let valid = samples.filter { $0.date >= start && $0.date <= end && $0.bpm.isFinite && (25...220).contains($0.bpm) && !$0.source.isEmpty }
        let sources = Dictionary(grouping:valid,by: \.source)
        guard let chosen = sources.keys.sorted().max(by:{ Set((sources[$0] ?? []).map(\.date)).count < Set((sources[$1] ?? []).map(\.date)).count }),let stream = sources[chosen] else { return nil }
        let dates = Dictionary(grouping:stream,by: \.date)
        let ordered = dates.keys.sorted().compactMap { date in median(dates[date]!.map(\.bpm)).map { WorkoutHeartSample(date:date,bpm:$0,source:chosen) } }
        let reference = resting.flatMap { $0.isFinite && (25...150).contains($0) ? $0 : nil }
        var minutes = 0.0, weightedHR = 0.0, elevated = 0.0, load = 0.0
        for (a,b) in zip(ordered,ordered.dropFirst()) {
            let seconds = b.date.timeIntervalSince(a.date)
            guard seconds > 0 && seconds <= 90 else { continue }
            let span = seconds/60, rate = (a.bpm+b.bpm)/2
            minutes += span; weightedHR += rate*span
            if let reference {
                if rate >= reference+20 { elevated += span }
                load += pow(max(0,rate-reference)/reference,2)*span
            }
        }
        return WorkoutCardioEvidence(coveredMinutes:minutes,windowMinutes:end.timeIntervalSince(start)/60,
            averageHR:minutes > 0 ? weightedHR/minutes : nil,peakHR:ordered.map(\.bpm).max(),restingReference:reference,
            aboveReferenceMinutes:reference == nil || minutes == 0 ? nil : elevated,
            relativeLoadMinutes:reference == nil || minutes == 0 ? nil : load,source:chosen)
    }
}
struct DrainWindow: Identifiable {
    var start: Date
    var end: Date
    var drop: Double
    var id: Date { start }
}
struct WorkoutImpact: Identifiable {
    var workout: PocketWorkout
    var drop: Double
    var coveredSeconds: Double
    var id: UUID { workout.id }
}
/// Describes existing model declines; never adds a second calorie penalty.
/// Allocates time proportionally inside hourly bins. Overlapping workouts share the same decline.
enum WorkoutAnalysis {
    static func windows(points: [BatteryPoint], day: Date, now: Date, calendar: Calendar = .current) -> [DrainWindow] {
        let start = calendar.startOfDay(for: day)
        let end = min(now, calendar.date(byAdding: .day, value: 1, to: start)!)
        let sorted = points.sorted { $0.date < $1.date }
        return zip(sorted, sorted.dropFirst()).compactMap { a, b in
            let seconds = b.date.timeIntervalSince(a.date)
            guard seconds > 0, seconds <= 3601, let av = a.value, let bv = b.value,
                  av.isFinite, bv.isFinite, (0...100).contains(av), (0...100).contains(bv),
                  b.date <= now else { return nil }
            let from = max(start, a.date), until = min(end, b.date)
            guard until > from else { return nil }
            return DrainWindow(start: from, end: until, drop: max(0, av - bv) * until.timeIntervalSince(from) / seconds)
        }
    }
    static func impacts(workouts: [PocketWorkout], windows: [DrainWindow]) -> [WorkoutImpact] {
        let valid = Dictionary(workouts.filter { $0.end > $0.start }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values.sorted { $0.start < $1.start }
        var drops: [UUID: Double] = [:], coverage: [UUID: Double] = [:]
        for window in windows where window.end > window.start && window.drop.isFinite && window.drop >= 0 {
            let cuts = Set([window.start, window.end] + valid.flatMap { [max(window.start, min(window.end, $0.start)), max(window.start, min(window.end, $0.end))] }).sorted()
            for (a, b) in zip(cuts, cuts.dropFirst()) {
                let active = valid.filter { $0.start < b && $0.end > a }
                guard !active.isEmpty else { continue }
                let seconds = b.timeIntervalSince(a)
                for workout in active {
                    drops[workout.id, default: 0] += window.drop * seconds / window.end.timeIntervalSince(window.start) / Double(active.count)
                    coverage[workout.id, default: 0] += seconds
                }
            }
        }
        return valid.map { WorkoutImpact(workout: $0, drop: drops[$0.id, default: 0], coveredSeconds: coverage[$0.id, default: 0]) }
    }
    static func demoWorkouts(day: Date) -> [PocketWorkout] {
        let start = Calendar.current.startOfDay(for: day)
        return [(8.0, 8.5, "步行", 65.0), (12.0, 12.75, "力量训练", 180.0), (18.0, 19.0, "跑步", 150.0)].enumerated().map { index, row in
            let (a, b, title, kcal) = row
            let from=start.addingTimeInterval(a*3600),until=start.addingTimeInterval(b*3600)
            let rows=(0...Int((b-a)*120)).map { tick in WorkoutHeartSample(date:from.addingTimeInterval(Double(tick)*30),bpm:(index == 0 ? 105 : index == 1 ? 120 : 155)+sin(Double(tick)/8)*8,source:"synthetic-watch") }
            let cardio=WorkoutCardioEngine.evidence(samples:rows,start:from,end:until,now:Date(),resting:55)
            return PocketWorkout(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!, title: title, start:from, end:until, duration: (b-a)*3600, activeKcal: kcal, source: "合成演示",cardio:cardio)
        }.filter { $0.end <= Date() }
    }
}

struct DailyBatteryStatistics {
    var latest: BatteryPoint?
    var minimum: Double?
    var maximum: Double?
    var charged: Double
    var drained: Double
    var coveredSeconds: Double
    static func calculate(points: [BatteryPoint], day: Date, now: Date, calendar: Calendar = .current) -> Self {
        let start = calendar.startOfDay(for: day)
        let midnight = calendar.date(byAdding:.day,value:1,to:start)!
        let end = min(now,midnight)
        let ordered = points.sorted { $0.date < $1.date }
        let selected = ordered.filter { $0.belongs(to:start,end:midnight) && $0.date <= end && $0.value.map { $0.isFinite && (0...100).contains($0) } == true }
        var values = selected.compactMap(\.value)
        var charge = 0.0, drain = 0.0, coverage = 0.0
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            let span = b.date.timeIntervalSince(a.date)
            guard span > 0, span <= 3601, b.date <= now, let av = a.value, let bv = b.value,
                  av.isFinite, bv.isFinite, (0...100).contains(av), (0...100).contains(bv) else { continue }
            let seconds = max(0, min(end, b.date).timeIntervalSince(max(start, a.date)))
            guard seconds > 0 else { continue }
            charge += max(0, bv - av) * seconds / span
            drain += max(0, av - bv) * seconds / span
            coverage += seconds
            // Daily range includes the actual modeled value at midnight, even
            // when that endpoint also closes the previous day's last interval.
            let from = max(start,a.date),until = min(end,b.date)
            values += [av+(bv-av)*from.timeIntervalSince(a.date)/span,av+(bv-av)*until.timeIntervalSince(a.date)/span]
        }
        return Self(latest: selected.last, minimum: values.min(), maximum: values.max(), charged: charge, drained: drain, coveredSeconds: coverage)
    }
}

/// Relative log-SDNN against earlier sleep-context nights, never population thresholds.
/// Three valid prior nights enable a preliminary comparison; missing data remains nil.
enum SleepHRVComparison {
    static func deviation(current: Double?, prior: [Double]) -> Double? {
        guard let current, current.isFinite, current > 0 else { return nil }
        let valid = prior.filter { $0.isFinite && $0 > 0 }.map { log($0) }.sorted()
        guard valid.count >= 3 else { return nil }
        func median(_ values: [Double]) -> Double {
            let v = values.sorted(), m = v.count / 2
            return v.count % 2 == 0 ? (v[m-1] + v[m]) / 2 : v[m]
        }
        let center = median(valid)
        let scale = max(0.15, median(valid.map { abs($0 - center) }) * 1.4826)
        return max(-3, min(3, (log(current) - center) / scale))
    }
}

struct HRVObservation: Codable, Identifiable {
    var id: UUID
    var start: Date
    var end: Date
    var sdnn: Double
    var context: String
    var source: String
    var deviation: Double? = nil
    var baselineDays: Int = 0
    var label: String {
        guard let deviation else { return context == "安静候选" ? "待建立可比记录" : context }
        return deviation < -1 ? "HRV 偏低" : deviation > 1 ? "HRV 偏高" : "接近个人范围"
    }
}
struct DayHRVSummary: Codable {
    var date: Date
    var sdnn: Double
    var label: String
    var baselineDays: Int
}
struct VitalRecord: Codable, Identifiable {
    var id: String { name + "::" + source + "::" + String(date.timeIntervalSince1970) }
    var name: String
    var date: Date
    var value: Double
    var unit: String
    var source: String
}
/// Compares SDNN only within source, context, recording-duration bucket and prior days.
/// Sleep days run from 18:00 to 18:00, so midnight never divides one night into its own baseline.
enum HRVContextComparison {
    static func compare(_ input:[HRVObservation],context:String,now:Date,calendar:Calendar = .current,only id:UUID? = nil) -> [HRVObservation] {
        let ordered = Dictionary(input.filter { $0.sdnn.isFinite && $0.sdnn > 0 && $0.end >= $0.start && $0.end <= now }.map { ($0.id,$0) },uniquingKeysWith:{ a,_ in a }).values.sorted { $0.start < $1.start }
        func day(_ row:HRVObservation) -> Date {
            let d = calendar.startOfDay(for:row.start)
            return context == "睡眠" && calendar.component(.hour,from:row.start) >= 18 ? calendar.date(byAdding:.day,value:1,to:d)! : d
        }
        func median(_ values:[Double]) -> Double {
            let v = values.sorted(),m = v.count/2
            return v.count.isMultiple(of:2) ? (v[m-1]+v[m])/2 : v[m]
        }
        func valid(_ row:HRVObservation) -> Bool { (30...300).contains(row.end.timeIntervalSince(row.start)) }
        return ordered.map { row in
            var result = row;result.deviation = nil;result.baselineDays = 0
            guard (id == nil || row.id == id),row.context == context,valid(row),!row.source.isEmpty else { return result }
            let bucket = Int((row.end.timeIntervalSince(row.start)/30).rounded()),currentDay = day(row)
            let cutoff = calendar.date(byAdding:.day,value:-28,to:currentDay)!
            let block = calendar.component(.hour,from:row.start)/6
            let prior = ordered.filter {
                $0.context == context && $0.source == row.source && valid($0) &&
                day($0) < currentDay && day($0) >= cutoff && $0.end <= row.start &&
                Int(($0.end.timeIntervalSince($0.start)/30).rounded()) == bucket &&
                (context == "睡眠" || calendar.component(.hour,from:$0.start)/6 == block)
            }
            let medians = Dictionary(grouping:prior,by:day).values.map { median($0.map(\.sdnn)) }
            result.baselineDays = medians.count
            result.deviation = SleepHRVComparison.deviation(current:row.sdnn,prior:medians)
            return result
        }
    }
}
struct HRVWindowSummary {
    var deviation:Double?
    var observedHours:Double
    var sampleWeight:Double
    var startedSamples:Int
}
enum HRVWindow {
    /// Integrate the same comparable intervals used for deviation and coverage.
    /// Cross-hour samples split exposure and evidence weight instead of disappearing.
    static func summarize(_ input:[HRVObservation],context:String,start:Date,end:Date) -> HRVWindowSummary {
        let rows = Dictionary(input.filter {
            $0.context == context && $0.deviation?.isFinite == true &&
            $0.sdnn.isFinite && $0.sdnn > 0 && (30...300).contains($0.end.timeIntervalSince($0.start)) &&
            $0.start < end && $0.end > start
        }.map { ($0.id,$0) },uniquingKeysWith:{ a,_ in a }).values
        guard Set(rows.map(\.source)).count <= 1, !rows.contains(where:{ $0.source.isEmpty }) else { return HRVWindowSummary(deviation:nil,observedHours:0,sampleWeight:0,startedSamples:0) }
        let boundaries = Array(Set(rows.flatMap { [max(start,$0.start),min(end,$0.end)] })).sorted()
        var seconds = 0.0,weightedDeviation = 0.0,weight = 0.0
        for (a,b) in zip(boundaries,boundaries.dropFirst()) {
            let active = rows.filter { $0.start < b && $0.end > a }
            let z = active.compactMap(\.deviation).sorted()
            guard !z.isEmpty else { continue }
            let m = z.count/2,center = z.count.isMultiple(of:2) ? (z[m-1]+z[m])/2 : z[m]
            let duration = b.timeIntervalSince(a)
            seconds += duration;weightedDeviation += max(-3,min(3,center))*duration
            weight += duration*active.reduce(0.0) { $0+1/$1.end.timeIntervalSince($1.start) }/Double(active.count)
        }
        return HRVWindowSummary(deviation:seconds > 0 ? weightedDeviation/seconds : nil,observedHours:seconds/3600,sampleWeight:weight,startedSamples:rows.filter { $0.start >= start && $0.start < end }.count)
    }
}

struct HRVActivityBin {
    var start:Date
    var end:Date
    var steps:Double?
    var kcal:Double?
}
enum HRVActivityContext {
    /// Use every intersecting activity bin, not just the sample's starting hour.
    static func classify(start:Date,end:Date,bins:[HRVActivityBin]) -> String {
        guard end > start else { return "活动记录不足" }
        let rows = bins.filter { $0.end > $0.start && $0.start < end && $0.end > start }
        func valid(_ value:Double?) -> Double? { value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        if rows.contains(where:{ (valid($0.steps) ?? 0) > 100 || (valid($0.kcal) ?? 0) > 5 }) { return "活动时段" }
        let spans = rows.filter { valid($0.steps) != nil && valid($0.kcal) != nil }.sorted { $0.start < $1.start }
        var until = start
        for row in spans {
            if row.start > until { return "活动记录不足" }
            until = max(until,min(end,row.end))
        }
        return until >= end ? "安静候选" : "活动记录不足"
    }
}

enum HealthReadChannel:CaseIterable {
    case sleep,hrv,heartRate,restingHeartRate,dailyEnergy,hourlyEnergy,workout,steps,dailySteps,mindfulness,respiration,temperature,oxygen,basalEnergy,dietaryEnergy,bodyMass,bodyFat,leanMass,height
}
enum HealthReadPolicy {
    static func canUpdateBattery(failed:Set<HealthReadChannel>) -> Bool {
        failed.isDisjoint(with:[.sleep,.hrv,.heartRate,.hourlyEnergy,.workout])
    }
    static func canCompareAwakeHRV(failed:Set<HealthReadChannel>) -> Bool {
        canUpdateBattery(failed:failed) && failed.isDisjoint(with:[.steps,.mindfulness])
    }
}

/// One failed auxiliary query must not cancel all other health reads.
enum HealthReadOutcome<Value> {
    case success(Value)
    case failure(String)
    var value:Value? { if case let .success(value) = self { return value };return nil }
    var failure:String? { if case let .failure(message) = self { return message };return nil }
    static func capture(_ name:String,operation:() async throws -> Value) async -> Self {
        do { return .success(try await operation()) }
        catch { return .failure(name+"："+error.localizedDescription) }
    }
}

enum DayHRVModel {
    /// A descriptive SDNN comparison, not a validated stress or mental-health score.
    static func compare(_ input: [HRVObservation], now: Date, calendar: Calendar = .current) -> [HRVObservation] {
        HRVContextComparison.compare(input,context:"安静候选",now:now,calendar:calendar)
    }
    static func summary(_ rows: [HRVObservation], now: Date, calendar: Calendar = .current) -> DayHRVSummary? {
        guard let row = rows.filter({ $0.context == "安静候选" && calendar.isDate($0.end, inSameDayAs: now) && $0.end <= now }).max(by: { $0.end < $1.end }) else { return nil }
        return DayHRVSummary(date: row.end, sdnn: row.sdnn, label: row.label, baselineDays: row.baselineDays)
    }
    /// Only actual eligible sample intervals count. Duplicate/overlapping records merge.
    static func observedHours(_ rows: [HRVObservation], start: Date, end: Date) -> Double {
        HRVWindow.summarize(rows,context:"安静候选",start:start,end:end).observedHours
    }
    static func demo(now: Date = Date(), calendar: Calendar = .current) -> [HRVObservation] {
        let today = calendar.startOfDay(for: now)
        let rows = (0..<10).flatMap { offset in
            [1, 8, 12, 16, 20].enumerated().map { index, hour in
                let start = calendar.date(byAdding: .day, value: -offset, to: today)!.addingTimeInterval(Double(hour) * 3600)
                return HRVObservation(id: UUID(uuidString: String(format: "11111111-0000-0000-0000-%012d", offset * 10 + index))!, start: start, end: start.addingTimeInterval(60), sdnn: offset == 0 && hour == 16 ? 29 : 52 + sin(Double(offset)) * 5, context: "安静候选", source: "合成演示")
            }
        }
        return compare(rows, now: now, calendar: calendar)
    }
}

// MARK: - 负荷 (Strain) 与负荷比 ACWR
// Shared by the phone app, the watch app and the synthetic core tests: pure
// Foundation math, no UI. Calibration is an engineering prior, not Whoop's model.
struct LoadBarRow: Identifiable, Equatable {
    var day: Date
    var kcal: Double?
    var id: Date { day }
}

struct LoadRatio {
    var acute: Double
    var chronic: Double
    var ratio: Double?
    var acuteDays: Int
    var chronicDays: Int
    var zone: String
    var note: String
}

enum StrainEngine {
    static let ceiling = 21.0
    /// Experimental 0–21 activity-energy proxy, not cardiovascular strain.
    /// Workout time is descriptive and does not add a duplicate energy-related bonus. A day with no recorded energy returns nil rather
    /// than a fabricated zero, so missing days never look like rest.
    static func strain(kcal: Double?, workoutMinutes: Double) -> Double? {
        guard let kcal, kcal.isFinite, kcal >= 0 else { return nil }
        let base = ceiling * (1 - exp(-kcal / 480))
        return min(ceiling, base)
    }
    static func zone(_ value: Double) -> String { value < 8 ? "轻" : value < 14 ? "中" : value < 18 ? "高" : "极限" }
    /// Acute:chronic workload ratio over the last 7 and 28 days of recorded energy.
    /// Missing days never count as zero, so the ratio stays nil until enough history exists.
    static func acwr(daily: [LoadBarRow], now: Date, calendar: Calendar = .current) -> LoadRatio {
        let today = calendar.startOfDay(for: now)
        let start7 = calendar.date(byAdding: .day, value: -7, to: today)!
        let start28 = calendar.date(byAdding: .day, value: -28, to: today)!
        let unique = Dictionary(daily.filter { $0.day <= now && $0.kcal.map { $0.isFinite && $0 >= 0 } == true }.map { (calendar.startOfDay(for: $0.day),$0) }, uniquingKeysWith: { _,b in b })
        // Compare completed days; today's partial total is displayed separately.
        let acuteRows = unique.filter { $0.key >= start7 && $0.key < today }.values.compactMap(\.kcal)
        let chronicRows = unique.filter { $0.key >= start28 && $0.key < today }.values.compactMap(\.kcal)
        let acute = acuteRows.isEmpty ? 0 : acuteRows.reduce(0, +) / Double(acuteRows.count)
        let chronic = chronicRows.isEmpty ? 0 : chronicRows.reduce(0, +) / Double(chronicRows.count)
        var ratio: Double? = nil
        if chronicRows.count >= 14, acuteRows.count >= 4, chronic > 0 { ratio = acute / chronic }
        var zone = "数据不足"
        var note = "需要至少 14 天历史负荷才能计算负荷比。"
        if let ratio {
            if ratio < 0.8 { zone = "低于历史"; note = "近期已记录活动能量低于历史均值。" }
            else if ratio <= 1.3 { zone = "接近历史"; note = "近期已记录活动能量接近历史均值。" }
            else if ratio <= 1.5 { zone = "高于历史"; note = "近期已记录活动能量高于历史均值。" }
            else { zone = "明显增加"; note = "近期已记录活动能量明显高于历史均值；这不是受伤风险预测。" }
        }
        return LoadRatio(acute: acute, chronic: chronic, ratio: ratio, acuteDays: acuteRows.count, chronicDays: chronicRows.count, zone: zone, note: note)
    }
}

/// One interpretation of freshness for iPhone widgets and Watch complications.
struct PocketWidgetPresentation {
    var value:Int?
    var title:String
    var detail:String
    var fraction:Double { Double(value ?? 0)/100 }
    var showTotals:Bool
    var symbol:String
    init(status:PocketStatus,at date:Date) {
        value = status.displayValue(at:date)
        symbol=status.scoreMeaning.symbol
        showTotals = value != nil && !status.usesStateEstimate
        if value != nil {
            title = status.demo ? "演示" : status.scoreMeaning.title
            detail = (status.usesStateEstimate ? status.scoreMeaning.title+" · ":"")+"观测至 "+status.displayDate!.formatted(date:.omitted,time:.shortened)
        } else if let measured = status.displayDate, (status.usesStateEstimate ? status.stateEstimate?.value : status.value).map({ (0...100).contains($0) }) == true, measured <= date.addingTimeInterval(60) {
            title = status.demo ? "演示·过期" : "已过期"
            detail = "已过期 · "+measured.formatted(date:.omitted,time:.shortened)
        } else {
            title = status.demo ? "演示·待同步" : "待同步"
            detail = "请在 iPhone 刷新"
        }
    }
}
enum PocketWidgetSchedule {
    /// Scheduling never invents later scores; only expires a currently fresh value.
    static func dates(status:PocketStatus,now:Date) -> [Date] {
        guard status.isFresh(at:now),let measured = status.displayDate else { return [now] }
        if status.usesStateEstimate,let expiry = status.stateEstimate?.validUntil { return expiry > now ? [now,expiry] : [now] }
        let midnight = Calendar.current.date(byAdding:.day,value:1,to:Calendar.current.startOfDay(for:measured))!
        let expiry = status.continuity != nil ? measured.addingTimeInterval(7201) : min(measured.addingTimeInterval(7201),midnight)
        return expiry > now ? [now,expiry] : [now]
    }
}

struct StateHeartSignal: Codable {
    var date: Date
    var bpm: Double
    var resting: Bool
    var context: String
    var source: String
}
/// Signed engineering contributions, not measured battery points or causal effects.
struct CurrentStateFactor: Codable, Identifiable {
    var key: String
    var title: String
    var points: Double
    var observedAt: Date?
    var baselineDays: Int
    var detail: String
    var id: String { key }
}
struct CurrentStateEstimate: Codable {
    var value: Int
    var lower: Int
    var upper: Int
    var measuredAt: Date
    var validUntil: Date
    var basis: String
    var note: String
    var channels: [String]
    var baselineDays: Int
    var factors: [CurrentStateFactor]? = nil
    var modelRevision: String? = nil
    func isUsable(at date:Date) -> Bool {
        (0...100).contains(value) && measuredAt <= date && date < validUntil && validUntil <= measuredAt.addingTimeInterval(6*3600)
    }
}
/// Partial, recent physiological-state estimate; not Garmin's reserve/stress algorithm.
/// A neutral 65 and the coefficients below are explicit engineering priors.
/// Missing sleep and HRV are omitted, never a week-long depletion penalty.
enum CurrentStateModel {
    static let revision = "0.28 / recent state / daily resting baseline / incomplete sleep omitted"
    static func comparisons(_ input:[HRVObservation],now:Date,calendar:Calendar = .current) -> [UUID:HRVObservation] {
        let input = input.filter { $0.end <= now && $0.end >= $0.start && $0.sdnn.isFinite && (1...999).contains($0.sdnn) }
        let contexts = Set(input.map(\.context)).intersection(["安静候选","睡眠","活动时段","活动记录不足"])
        var result:[UUID:HRVObservation] = [:]
        for context in contexts {
            for row in HRVContextComparison.compare(input,context:context,now:now,calendar:calendar) where row.context == context {
                result[row.id] = row
            }
        }
        return result
    }
    static func estimate(signals:[StateHeartSignal],hrv:[HRVObservation],hours:[BatteryHour],now:Date,calendar:Calendar = .current,comparisons:[UUID:HRVObservation]? = nil) -> CurrentStateEstimate? {
        let freshStart = now.addingTimeInterval(-6*3600)
        let hearts = signals.filter { $0.date <= now && $0.bpm.isFinite && (25...($0.resting ? 150 : 220)).contains($0.bpm) && !$0.source.isEmpty }
        let unique = Dictionary(hrv.filter { $0.end <= now && $0.end >= $0.start && $0.sdnn.isFinite && (1...999).contains($0.sdnn) }.map { ($0.id,$0) },uniquingKeysWith:{ a,_ in a }).values.sorted { $0.end < $1.end }
        let allowed = ["安静候选","睡眠","活动时段","活动记录不足"]
        let eligibleHRV = unique.filter { allowed.contains($0.context) && (30...300).contains($0.end.timeIntervalSince($0.start)) && !$0.source.isEmpty }
        // Training/breathwork readings cannot keep a resting-state score alive.
        guard let measured = (hearts.map(\.date)+eligibleHRV.map(\.end)).max(),measured > freshStart else { return nil }
        let freshHearts = hearts.filter { $0.date > measured.addingTimeInterval(-6*3600) }
        let freshHRV = eligibleHRV.filter { $0.end > measured.addingTimeInterval(-6*3600) }
        var correction = 0.0,information = 0.0,baselineDays = 0,channels:[String] = [],notes:[String] = []
        var factors=[CurrentStateFactor(key:"prior",title:"中性初始假设",points:65,observedAt:nil,baselineDays:0,detail:"工程先验，不是健康测量，也不是个人校准结果。")]
        func add(_ key:String,_ title:String,_ points:Double,_ date:Date,_ days:Int,_ detail:String) {
            correction+=points
            factors.append(CurrentStateFactor(key:key,title:title,points:points,observedAt:date,baselineDays:days,detail:detail))
        }
        func median(_ values:[Double]) -> Double? {
            let v=values.filter(\.isFinite).sorted();guard !v.isEmpty else{return nil};let m=v.count/2
            return v.count.isMultiple(of:2) ? (v[m-1]+v[m])/2 : v[m]
        }
        func deviation(_ value:Double,_ baseline:[Double],floor:Double) -> Double {
            let center=median(baseline)!,mad=median(baseline.map{abs($0-center)})!
            return max(-3,min(3,(value-center)/max(floor,1.4826*mad)))
        }
        // One vote per prior local date; repeated samples on one date cannot create
        // three comparable days or dominate other dates. Current-day totals are excluded.
        func restingDays(before date:Date,source:String) -> [Double] {
            let day=calendar.startOfDay(for:date),cutoff=calendar.date(byAdding:.day,value:-28,to:day)!
            let prior=hearts.filter{$0.resting && $0.source==source && $0.date<day && $0.date>=cutoff}
            return Dictionary(grouping:prior,by:{calendar.startOfDay(for:$0.date)}).values.compactMap{median($0.map(\.bpm))}
        }
        // Freeze the point estimate to its actual signal timestamp. Merely refreshing
        // later may widen uncertainty but cannot manufacture recovery toward neutral.
        func recency(_ date:Date) -> Double { exp(-max(0,measured.timeIntervalSince(date))/(4*3600)) }
        if let row = freshHRV.last {
            let compared = comparisons?[row.id] ?? HRVContextComparison.compare(Array(unique),context:row.context,now:now,calendar:calendar,only:row.id).first{$0.id==row.id}
            if let z = compared?.deviation {
                let contextWeight = row.context == "活动时段" ? 0.35 : row.context == "活动记录不足" ? 0.25 : 1.0
                let weight = contextWeight*recency(row.end)
                // Extreme high SDNN is atypical, not an unlimited recovery reward.
                add("hrv","可比 HRV",(z > 2 ? 0 : max(-2,min(2,z))*12)*weight,row.end,compared?.baselineDays ?? 0,"与同来源、同场景的历史比较；活动背景及观测间隔会降低权重。")
                information += weight;baselineDays=max(baselineDays,compared?.baselineDays ?? 0)
                channels.append("HRV")
                if contextWeight < 1 { notes.append("HRV 受活动或背景缺口影响，已降低权重。") }
            } else { notes.append("已有 HRV，但同来源、同场景的历史不足，尚未据此判断高低。") }
        } else { notes.append("近期无可用 HRV，按其他已有信号估计。") }
        if let current = freshHearts.filter({$0.resting}).max(by:{$0.date < $1.date}) {
            let baselines=restingDays(before:current.date,source:current.source)
            if baselines.count >= 3 {
                let weight=recency(current.date)*0.8
                add("restingHR","静息心率",-max(-1,min(3,deviation(current.bpm,baselines,floor:3)))*10*weight,current.date,baselines.count,"过去28个本地日期内，同来源静息心率按日中位数比较；至少3个日期。")
                information += weight;baselineDays=max(baselineDays,baselines.count);channels.append("静息心率")
            } else { notes.append("个人静息心率历史较少，未使用人群均值代替你的基线。") }
        }
        if let current=freshHearts.filter({!$0.resting && $0.context=="安静候选"}).max(by:{$0.date<$1.date}) {
            // Prior-day resting HR only; today's full-day aggregate cannot leak backwards.
            let baselines=restingDays(before:current.date,source:current.source)
            if baselines.count>=3,let reference=median(baselines) {
                let burden=max(0,min(3,(current.bpm-reference-12)/15))
                let weight=0.5*recency(current.date)
                add("quietHR","安静心率",-burden*8*weight,current.date,baselines.count,"与同来源的过往静息心率按日中位数比较；当天多条样本不增加历史日期。")
                information += weight;baselineDays=max(baselineDays,baselines.count);channels.append("安静心率")
            } else {notes.append("安静心率可比历史不足3个日期，暂不据此扣分。")}
        }
        let candidates=Dictionary(hours.map{($0.start,$0)},uniquingKeysWith:{_,b in b}).values.sorted{$0.start<$1.start}
        var available:[BatteryHour]=[],previousEnd:Date?
        for row in candidates where row.end<=measured && row.end>row.start && row.end>measured.addingTimeInterval(-24*3600) {
            guard previousEnd.map({row.start >= $0}) ?? true else{continue}
            available.append(row);previousEnd=row.end
        }
        let sleep=available.reduce(0.0){total,row in
            guard row.sleepHours.isFinite else{return total}
            let overlap=max(0,row.end.timeIntervalSince(max(row.start,measured.addingTimeInterval(-24*3600))))
            return total+max(0,min(row.sleepHours,row.end.timeIntervalSince(row.start)/3600))*overlap/row.end.timeIntervalSince(row.start)
        }
        if sleep > 0 { notes.append(String(format:"已读到 %.1f 小时睡眠片段，记录完整性未知；近期状态不据此推定缺觉或额外加分。连续电量仍按实际睡眠记录计算恢复。",sleep)) }
        else { notes.append("睡眠记录缺失未按没睡处理；暂不展示连续电量收支。") }
        // Actual recorded energy only, at most 12 points; no Workout calorie addition.
        let activityStart=measured.addingTimeInterval(-6*3600)
        let activity=available.filter{$0.end>activityStart}.reduce(0.0){total,row in
            guard let kcal=row.activeKcal,kcal.isFinite,kcal>=0 else{return total}
            let overlap=max(0,row.end.timeIntervalSince(max(activityStart,row.start)))
            return total+kcal*overlap/row.end.timeIntervalSince(row.start)
        }
        if activity>0 {
            add("activity","近期已记录活动",-min(12,activity/100),measured,0,"近6小时实际活动能量的有界工程修正；不另加Workout热量。")
            channels.append("近期活动")
        }
        if information==0 { notes.append("当前主要是中性初始估计，不能据此认定恢复良好或压力异常。") }
        let value=Int(max(5,min(100,65+correction)).rounded())
        let reconciliation=Double(value)-(65+correction)
        if abs(reconciliation)>1e-10 {
            factors.append(CurrentStateFactor(key:"rounding",title:"边界与取整",points:reconciliation,observedAt:nil,baselineDays:0,detail:"将内部结果限制在5–100并取整，使各项相加等于显示值。"))
        }
        let uncertainty=information==0 ? 30.0 : max(15,25-information*5)+max(0,now.timeIntervalSince(measured))/3600
        let basis=channels.isEmpty ? "初始估计 · 心率记录" : "近期状态 · "+channels.joined(separator:" / ")
        return CurrentStateEstimate(value:value,lower:max(0,Int((Double(value)-uncertainty).rounded())),upper:min(100,Int((Double(value)+uncertainty).rounded())),measuredAt:measured,validUntil:measured.addingTimeInterval(6*3600),basis:basis,note:notes.joined(separator:" ")+" 实验估计，未校准。",channels:channels,baselineDays:baselineDays,factors:factors,modelRevision:revision)
    }
}

/// In-memory presentation policy only. It never deletes or rewrites source records.
enum RecentStateCachePolicy {
    static func compatible(_ status:PocketStatus)->Bool {
        guard !status.demo,status.usesStateEstimate,let estimate=status.stateEstimate,
              estimate.modelRevision==CurrentStateModel.revision,
              (0...100).contains(estimate.lower),(0...100).contains(estimate.upper),
              estimate.lower<=estimate.value,estimate.value<=estimate.upper,estimate.baselineDays>=0,
              estimate.measuredAt<estimate.validUntil,estimate.validUntil<=estimate.measuredAt.addingTimeInterval(6*3600),
              let factors=estimate.factors,!factors.isEmpty,
              factors.allSatisfy({$0.points.isFinite && $0.baselineDays>=0}),
              Set(factors.map(\.key)).count==factors.count,
              factors.filter({$0.key=="prior" && $0.points==65}).count==1,
              abs(factors.reduce(0){$0+$1.points}-Double(estimate.value))<1e-6,
              status.value==estimate.value,status.measuredAt==estimate.measuredAt,
              status.lower==estimate.lower,status.upper==estimate.upper else{return false}
        return true
    }
    static func reusable(_ status:PocketStatus,at date:Date)->Bool {
        compatible(status) && status.isFresh(at:date)
    }
    static func presentation(_ saved:PocketStatus)->PocketStatus {
        guard !saved.demo else{return .empty}
        guard saved.usesStateEstimate,!compatible(saved) else{return saved}
        var result=saved
        result.value=nil;result.lower=nil;result.upper=nil;result.measuredAt=nil
        result.stateEstimate=nil
        result.message="旧版近期状态需要重新计算。已有健康账本和本机记录仍保留；读取后会显示新版依据。"
        result.modelRevision=CurrentStateModel.revision+" / awaiting recomputation"
        return result
    }
}

/// Provenance for an accumulated reserve. A long unobserved gap starts a new
/// explicitly marked segment; that jump is neither charging nor consumption.
struct BatteryOrigin: Codable, Equatable {
    var bucketStart: Date
    var date: Date
    var value: Double
    var uncertainty: Double
    var reason: String
}
struct BatteryContinuity: Codable {
    var segmentStart: Date
    var initialValue: Double
    var initialReason: String
    var segmentCount: Int
    var missingHoursToday: Double
    var inferredHoursToday: Double
    var latestSleepEnd: Date?
    var origins: [BatteryOrigin]? = nil
    var restarted: Bool { segmentCount > 1 }
    var note: String {
        var parts = ["连续电量为实验估计，未经个人校准。", "本段起点："+initialReason+"；后续按记录逐段承接。"]
        if restarted { parts.append("超过六小时的缺测已断开并重建起点，起点变化不计入补充或消耗。") }
        if missingHoursToday > 2 { parts.append(String(format:"今天约 %.1f 小时缺少时间覆盖，未按持续清醒或睡眠补算。",missingHoursToday)) }
        if inferredHoursToday > 0 { parts.append("部分时间覆盖由相邻心率采样推断，不等于连续测量。") }
        if latestSleepEnd.map({ $0 <= segmentStart }) ?? true { parts.append("尚未读到本段睡眠，不能把当前值当作完整的隔夜恢复结果。") }
        return parts.joined(separator:" ")
    }
}

/// Accumulates effects over time, not a repeatedly reset mapping of latest HRV.
/// Uses the shared reserve integrator; initial values, six-hour gap threshold and
/// quiet-rest recovery constant are engineering priors, not Garmin's formula.
enum ContinuousBatteryModel {
    static func calculate(hours input:[BatteryHour],signals:[StateHeartSignal],hrv:[HRVObservation],baselineHR:Double?,now:Date,anchorOverride:Double? = nil,calendar:Calendar = .current,origins:[BatteryOrigin] = [],parameters:BatteryModelParameters = .standard,activityExperiment:ActivityFusionPolicy? = nil) -> PocketStatus {
        let ordered = Dictionary(input.filter { $0.start < now && $0.end <= now && $0.end > $0.start }.map { ($0.start,$0) },uniquingKeysWith:{ _,new in new }).values.sorted { $0.start < $1.start }
        var valid:[BatteryHour] = [], previousEnd:Date?
        for row in ordered {
            guard previousEnd.map({row.start >= $0}) ?? true else { continue }
            valid.append(row); previousEnd = row.end
        }
        func observed(_ row:BatteryHour) -> Bool {
            let count = row.awakeHeartRateCount ?? row.heartRateCount
            let heart = row.awakeHeartRateCount == nil ? row.heartRate : row.awakeHeartRate
            return (row.sleepHours.isFinite && row.sleepHours > 0) ||
                row.activeKcal.map { $0.isFinite && $0 > 0 } == true ||
                (count > 0 && heart.map { $0.isFinite && (25...220).contains($0) } == true) ||
                row.workoutHours.map { $0.isFinite && $0 > 0 } == true ||
                (row.awakeHRVZ?.isFinite == true && row.awakeHRVObservedHours.map { $0.isFinite && $0 > 0 } == true)
        }
        var segments:[[BatteryHour]] = [], current:[BatteryHour] = [], lastEvidenceEnd:Date?
        for row in valid {
            let evidence = observed(row)
            if evidence, let lastEvidenceEnd, row.start.timeIntervalSince(lastEvidenceEnd) >= 6*3600, !current.isEmpty {
                segments.append(current); current = []
            }
            if current.isEmpty && !evidence { continue }
            current.append(row)
            if evidence { lastEvidenceEnd = row.end }
        }
        if !current.isEmpty { segments.append(current) }
        let recentState = CurrentStateModel.estimate(signals:signals,hrv:hrv,hours:valid,now:now,calendar:calendar)
        guard !segments.isEmpty else {
            var result = PocketStatus.empty; result.computedAt = now
            result.reserveSupported = false; result.stateEstimate = recentState
            result.value = recentState?.value; result.lower = recentState?.lower; result.upper = recentState?.upper
            result.measuredAt = recentState?.measuredAt
            result.message = "尚无可累积的时段记录，仅显示近期状态。"
            result.modelRevision = activityExperiment.map { parameters.safe == .standard ? $0.revision : $0.revision+" / offline parameter sensitivity" } ?? (parameters.safe == .standard ? "0.28 / episode-aware reserve / daily state baseline / incomplete sleep omitted" : "0.28 / offline parameter sensitivity")
            return result
        }
        let today = calendar.startOfDay(for:now)
        var result = PocketStatus.empty, points:[BatteryPoint] = []
        var inputs = BatteryInputSummary(date:today)
        var evidenceHours = 0.0, inferredHours = 0.0
        var lastOrigin = segments[0][0].start, lastAnchor = 50.0, lastReason = "中性初始假设（50，范围较宽）"
        var establishedOrigins:[BatteryOrigin] = []
        for original in segments {
            var rows = original
            let first = rows[0]
            var anchor = 50.0, uncertainty = 35.0, reason = "中性初始假设（50，范围较宽）"
            // Use a first actually available signal once to establish an origin.
            // Never apply an end-of-hour signal to the period preceding it.
            let pinned = origins.first { $0.bucketStart == first.start && $0.date >= first.start && $0.date <= first.end && $0.date <= now && $0.value.isFinite && (5...100).contains($0.value) && $0.uncertainty.isFinite && (0...40).contains($0.uncertainty) }
            if let pinned {
                anchor = pinned.value; uncertainty = pinned.uncertainty; reason = pinned.reason
                rows[0] = clipped(first,after:pinned.date)
            } else if first.sleepHours <= 0, let seed = CurrentStateModel.estimate(signals:signals,hrv:hrv,hours:[],now:first.end,calendar:calendar), seed.measuredAt >= first.start {
                anchor = Double(seed.value); uncertainty = max(25,Double(seed.upper-seed.lower)/2)
                reason = seed.channels.isEmpty ? "信号尚无可比基线，使用中性初始假设（65，范围较宽）" : "首次可用心率 / HRV 的初步状态，非电量实测"
                rows[0] = clipped(first,after:seed.measuredAt)
            }
            if let override = anchorOverride, override.isFinite { anchor = max(5,min(100,override)); uncertainty = 35; reason = "起点敏感性对照" }
            let origin = rows[0].start
            establishedOrigins.append(BatteryOrigin(bucketStart:first.start,date:origin,value:anchor,uncertainty:uncertainty,reason:reason))
            // A seed at the end of the first bin still creates a single initial
            // point. Subsequent bins, including tomorrow, carry this reserve.
            rows = rows.filter { $0.end > $0.start }
            var segment = BatteryModel.calculate(hours:rows,anchor:anchor,baselineHR:baselineHR,now:now,calendar:calendar,initialUncertainty:uncertainty,policy:.continuous,parameters:parameters,activityExperiment:activityExperiment)
            if segment.measuredAt == nil {
                segment.measuredAt = origin; segment.value = Int(anchor.rounded())
                segment.lower = max(0,Int(anchor-uncertainty)); segment.upper = min(100,Int(anchor+uncertainty))
                segment.points.insert(BatteryPoint(date:origin,value:anchor,mode:"起点估计 · 非补充",role:.observation),at:0)
            }
            if let firstPoint = segment.points.first {
                while points.last.map({$0.date >= firstPoint.date}) == true { points.removeLast() }
                if let tail = points.last, tail.value != nil, tail.date < firstPoint.date {
                    points.append(BatteryPoint(date:tail.date.addingTimeInterval(firstPoint.date.timeIntervalSince(tail.date)/2),value:nil,mode:"缺测 · 重新建立起点"))
                }
            }
            points += segment.points
            if let value = segment.inputs {
                inputs.sleepHours += value.sleepHours; inputs.sleepHRVHours += value.sleepHRVHours
                inputs.awakeHRVMinutes += value.awakeHRVMinutes; inputs.activeKcal += value.activeKcal
                inputs.observedHours += value.observedHours
                inputs.sleepHRVSamples = (inputs.sleepHRVSamples ?? 0)+(value.sleepHRVSamples ?? 0)
                inputs.sleepHRVAdjustment = (inputs.sleepHRVAdjustment ?? 0)+(value.sleepHRVAdjustment ?? 0)
                inputs.awakeHRVDrain = (inputs.awakeHRVDrain ?? 0)+(value.awakeHRVDrain ?? 0)
                inputs.activityDrain = (inputs.activityDrain ?? 0)+(value.activityDrain ?? 0)
                inputs.workoutHeartFallbackDrain = (inputs.workoutHeartFallbackDrain ?? 0)+(value.workoutHeartFallbackDrain ?? 0)
                evidenceHours += max(0,now.timeIntervalSince(today)/3600-(value.unobservedHours ?? now.timeIntervalSince(today)/3600))
            }
            for row in rows where row.end > today {
                let fraction = max(0,row.end.timeIntervalSince(max(today,row.start)))/row.end.timeIntervalSince(row.start)
                let inferred = row.inferredNonSleepHours.flatMap { $0.isFinite ? max(0,$0) : nil } ?? 0
                inferredHours += inferred*fraction
            }
            result = segment; lastOrigin = origin; lastAnchor = anchor; lastReason = reason
        }
        inputs.latestSleepEnd = valid.last { $0.sleepHours.isFinite && $0.sleepHours > 0 }?.end
        inputs.unobservedHours = max(0,now.timeIntervalSince(today)/3600-evidenceHours)
        result.points = points; result.inputs = inputs
        let stats = DailyBatteryStatistics.calculate(points:points,day:today,now:now,calendar:calendar)
        result.charged = Int(stats.charged.rounded()); result.drained = Int(stats.drained.rounded())
        result.reserveSupported = true; result.stateEstimate = recentState
        result.continuity = BatteryContinuity(segmentStart:lastOrigin,initialValue:lastAnchor,initialReason:lastReason,segmentCount:segments.count,missingHoursToday:inputs.unobservedHours ?? 0,inferredHoursToday:inferredHours,latestSleepEnd:inputs.latestSleepEnd,origins:establishedOrigins)
        result.message = "连续电量估计 · 未校准"
        result.modelRevision = activityExperiment.map { parameters.safe == .standard ? $0.revision : $0.revision+" / offline parameter sensitivity" } ?? (parameters.safe == .standard ? "0.28 / episode-aware reserve / daily state baseline / incomplete sleep omitted" : "0.28 / offline parameter sensitivity")
        return result
    }
    private static func clipped(_ original:BatteryHour,after date:Date) -> BatteryHour {
        var row = original; row.start = max(original.start,min(original.end,date))
        let fraction = row.end.timeIntervalSince(row.start)/original.end.timeIntervalSince(original.start)
        row.sleepHours *= fraction; row.activeKcal = row.activeKcal.map{$0*fraction}
        row.heartRateCoverageHours *= fraction; row.sleepHRVSampleWeight = row.sleepHRVSampleWeight.map{$0*fraction}
        row.sleepHRVCount = row.sleepHRVCount.map{Int(Double($0)*fraction)}
        row.workoutHours = row.workoutHours.map{$0*fraction}; row.steps = row.steps.map{$0*fraction}
        row.awakeHRVObservedHours = row.awakeHRVObservedHours.map{$0*fraction}
        row.awakeHeartRateCoverageHours = row.awakeHeartRateCoverageHours.map{$0*fraction}
        row.inferredNonSleepHours = row.inferredNonSleepHours.map{$0*fraction}
        row.workoutHeartSpans = row.workoutHeartSpans.map { spans in spans.compactMap { span in
            var clipped = span; clipped.start = max(row.start,span.start); clipped.end = min(row.end,span.end)
            return clipped.end > clipped.start ? clipped : nil
        } }
        return row
    }
}

extension BatteryDemo {
    /// Synthetic accumulated trajectory. Used only by the simulator fixture.
    static func continuousStatus(now:Date = Date()) -> PocketStatus {
        let calendar=Calendar.current,today=calendar.startOfDay(for:now)
        let start=calendar.date(byAdding:.day,value:-2,to:today)!
        var hours:[BatteryHour]=[],cursor=start
        while cursor < now {
            let end=min(now,cursor.addingTimeInterval(3600)),duration=end.timeIntervalSince(cursor)/3600
            let clock=calendar.component(.hour,from:cursor),asleep=clock<8
            let workout=([8:0.5,12:0.75,18:1.0][clock] ?? 0)*duration
            let kcal=(asleep ? 0 : 28+([8:65.0,12:180.0,18:150.0][clock] ?? 0))*duration
            hours.append(BatteryHour(start:cursor,end:end,sleepHours:asleep ? duration : 0,activeKcal:kcal,heartRate:asleep ? 55 : clock==18 ? 135 : 78,heartRateCount:12,heartRateCoverageHours:0.2*duration,sleepHRVZ:asleep ? 0 : nil,sleepHRVCount:asleep ? 4 : nil,workoutHours:workout,steps:asleep ? 0 : 400*duration,personalHR:55,sleepHeartRate:asleep ? 55 : nil,awakeHeartRate:asleep ? nil : 78,awakeHeartRateCount:asleep ? 0 : 12,awakeHeartRateCoverageHours:asleep ? 0 : 0.2*duration,sleepHRVSampleWeight:asleep ? 4*duration : nil,hrvSourceKey:"synthetic-watch",hrvContextVersion:1,inferredNonSleepHours:asleep ? 0 : 0.85*duration))
            cursor=end
        }
        var result=ContinuousBatteryModel.calculate(hours:hours,signals:[],hrv:[],baselineHR:55,now:now)
        result.demo=true; return result
    }
}

#if targetEnvironment(simulator)
extension BatteryDemo {
    /// Synthetic missing-energy workout, kept separate from normal demonstrations.
    static func workoutFallbackStatus(now:Date = Date()) -> PocketStatus {
        let start=max(Calendar.current.startOfDay(for:now),now.addingTimeInterval(-3600)),minutes=Int(now.timeIntervalSince(start)/60)
        let samples=(0...minutes).map { WorkoutHeartSample(date:start.addingTimeInterval(Double($0)*60),bpm:160,source:"synthetic-watch") }
        let spans=WorkoutHeartFallback.make(samples:samples,windows:[(start,now)],start:start,end:now,now:now,reference:60,source:"synthetic-watch")
        let row=BatteryHour(start:start,end:now,sleepHours:0,activeKcal:nil,heartRate:160,heartRateCount:samples.count,heartRateCoverageHours:now.timeIntervalSince(start)/3600,workoutHours:now.timeIntervalSince(start)/3600,personalHR:60,awakeHeartRate:160,awakeHeartRateCount:samples.count,awakeHeartRateCoverageHours:now.timeIntervalSince(start)/3600,workoutHeartSpans:spans)
        var result=ContinuousBatteryModel.calculate(hours:[row],signals:[],hrv:[],baselineHR:60,now:now,anchorOverride:80)
        result.demo=true;return result
    }
}
#endif

struct WatchCheckIn:Codable,Identifiable {
    var id:UUID = UUID()
    var date:Date
    var energy:Int
    func valid(now:Date)->Bool {date <= now.addingTimeInterval(60) && date >= now.addingTimeInterval(-7*86400) && (1...5).contains(energy)}
}
extension PocketStatus {
    func visibleAction(at date:Date)->String? {guard let actionDate,actionDate <= date,Calendar.current.isDate(actionDate,inSameDayAs:date),let actionTitle,!actionTitle.isEmpty else{return nil};return actionTitle}
}

// Opt-in shadow experiment only. Normal phone/Watch/widget status never selects it.
enum ActivityFusionPolicy: String, Codable {
    case cardioEnergyV1
    var revision: String { "0.25 / shadow activity blend v1 / energy0.75-cardio0.25 / kcal35-cardio10-cap100perObservedHour / full-workout0.95-coverage0.8" }
}
struct ActivityFusionDecision: Codable {
    var energyDrain: Double
    var cardioDrain: Double
    var replacementDrain: Double
    var coveredMinutes: Double
    var trainingMinutes: Double
    var source: String
}
enum ActivityFusionReason:String,Codable,CaseIterable {
    case eligible,invalidInterval,futureInterval,invalidSleep,sleepOverlap,noWorkout,invalidTraining,mixedActivity,missingEnergy,invalidEnergy,missingHeartPairs,invalidHeartPairs,mixedSources,mixedReferences,overlappingPairs,excessCoverage,insufficientCoverage
    var title:String {
        switch self {
        case .eligible:return "已用于影子对照"
        case .invalidInterval:return "时段无效"
        case .futureInterval:return "时段尚未结束"
        case .invalidSleep:return "睡眠时长无效"
        case .sleepOverlap:return "与睡眠记录重叠"
        case .noWorkout:return "没有训练时长"
        case .invalidTraining:return "训练时长不一致"
        case .mixedActivity:return "训练与其他活动混合"
        case .missingEnergy:return "活动能量缺测"
        case .invalidEnergy:return "活动能量无效"
        case .missingHeartPairs:return "缺少可比心率对"
        case .invalidHeartPairs:return "心率对未通过校验"
        case .mixedSources:return "心率来源不一致"
        case .mixedReferences:return "个人参考值不一致"
        case .overlappingPairs:return "心率对区间冲突"
        case .excessCoverage:return "心率覆盖超过训练时长"
        case .insufficientCoverage:return "实际心率覆盖不足80%"
        }
    }
    var detail:String {
        switch self {
        case .eligible:return "训练占比至少95%，实际心率对覆盖至少80%；仅替换影子活动项，正式电量继续保留。"
        case .mixedActivity:return "现有时段包含训练以外的活动，无法把整段热量可靠分给训练。跨整点训练更容易出现此限制；不代表没读取训练。"
        case .missingEnergy:return "不补造热量。正式模型仍可在有实际训练心率对和个人参考时使用缺能量的心率回退。"
        case .missingHeartPairs:return "旧记录、孤立采样或缺乏同来源个人参考都可能没有可比心率对，不能由训练总时长推定连续心率。"
        case .insufficientCoverage:return "只承认相邻采样不超过90秒的实际覆盖；不把缺少的时间扩展成持续观测。"
        case .sleepOverlap:return "同一时段存在睡眠，未将其当作完整清醒训练替换活动项。"
        case .noWorkout:return "没有有效的已记录训练时长，此时段不进入训练强度对照。"
        default:return "这份时段记录未满足一致性条件，保留正式结果；检查来源、同步与记录内容后再比较。"
        }
    }
}
struct ActivityFusionAssessment:Codable,Identifiable {
    var start:Date
    var end:Date
    var trainingMinutes:Double?
    var coveredMinutes:Double?
    var reason:ActivityFusionReason
    var decision:ActivityFusionDecision?
    var id:Date {start}
}
struct ActivityFusionAudit {
    var segmentStart:Date
    var observedAt:Date
    var entries:[ActivityFusionAssessment]
    var trainingMinutes:Double {entries.compactMap(\.trainingMinutes).reduce(0,+)}
    var eligibleMinutes:Double {entries.compactMap(\.decision).reduce(0){$0+$1.coveredMinutes}}
    var reasons:[ActivityFusionReason:Int] {Dictionary(grouping:entries.filter{$0.reason != .eligible},by:\.reason).mapValues(\.count)}
}
enum ActivityFusionEngine {
    private struct Span: Hashable {
        var start: Date; var end: Date; var rate: Double; var reference: Double; var source: String
    }
    /// Restrict substitution to bins almost entirely occupied by a recorded workout.
    /// The assessment exposes abstention; it does not allocate unknown mixed energy.
    static func decision(hour:BatteryHour,now:Date,policy:ActivityFusionPolicy)->ActivityFusionDecision? {
        assess(hour:hour,now:now,policy:policy).decision
    }
    static func assess(hour:BatteryHour,now:Date,policy:ActivityFusionPolicy)->ActivityFusionAssessment {
        var result=ActivityFusionAssessment(start:hour.start,end:hour.end,reason:.invalidInterval)
        let duration=hour.end.timeIntervalSince(hour.start)/3600
        guard duration.isFinite,duration>0 else{return result}
        guard hour.end<=now else{result.reason = .futureInterval;return result}
        // Invalid raw training duration must not appear as a measured total.
        if let training=hour.workoutHours,training.isFinite,training>=0,training<=duration+1e-8 {result.trainingMinutes=training*60}
        guard hour.sleepHours.isFinite,hour.sleepHours>=0 else{result.reason = .invalidSleep;return result}
        guard hour.sleepHours<1e-8 else{result.reason = .sleepOverlap;return result}
        guard let training=hour.workoutHours,training.isFinite,training>0 else{result.reason = hour.workoutHours == nil || hour.workoutHours == 0 ? .noWorkout:.invalidTraining;return result}
        guard training<=duration+1e-8 else{result.reason = .invalidTraining;return result}
        guard training>=0.95*duration else{result.reason = .mixedActivity;return result}
        guard let energy=hour.activeKcal else{result.reason = .missingEnergy;return result}
        guard energy.isFinite,energy>=0 else{result.reason = .invalidEnergy;return result}
        guard let raw=hour.workoutHeartSpans,!raw.isEmpty else{result.reason = .missingHeartPairs;return result}
        var spans=Set<Span>()
        for row in raw {
            guard row.start>=hour.start,row.end<=hour.end,row.end>row.start,
                  row.end.timeIntervalSince(row.start)<=90,
                  let rate=row.averageHR,rate.isFinite,(25...220).contains(rate),
                  row.referenceHR.isFinite,(25...150).contains(row.referenceHR),
                  row.strain.isFinite,abs(row.strain-max(0,min(3,(rate-row.referenceHR-15)/15)))<1e-8,
                  !row.source.isEmpty else{result.reason = .invalidHeartPairs;return result}
            spans.insert(Span(start:row.start,end:row.end,rate:rate,reference:row.referenceHR,source:row.source))
        }
        guard Set(spans.map(\.source)).count==1 else{result.reason = .mixedSources;return result}
        guard Set(spans.map(\.reference)).count==1 else{result.reason = .mixedReferences;return result}
        let ordered=spans.sorted { $0.start == $1.start ? $0.end<$1.end : $0.start<$1.start }
        var previous:Date?,minutes=0.0,load=0.0
        for row in ordered {
            guard previous.map({row.start >= $0}) ?? true else{result.reason = .overlappingPairs;return result}
            let span=row.end.timeIntervalSince(row.start)/60
            minutes+=span
            load+=pow(max(0,row.rate-row.reference)/row.reference,2)*span
            previous=row.end
        }
        result.coveredMinutes=minutes
        guard minutes<=training*60+1e-8 else{result.reason = .excessCoverage;return result}
        guard minutes>=training*60*0.8-1e-8 else{result.reason = .insufficientCoverage;return result}
        let energyDrain=energy/35,cardioDrain=min(100*minutes/60,load/10)
        result.decision=ActivityFusionDecision(energyDrain:energyDrain,cardioDrain:cardioDrain,
            replacementDrain:0.75*energyDrain+0.25*cardioDrain,coveredMinutes:minutes,
            trainingMinutes:training*60,source:ordered[0].source)
        result.reason = .eligible
        return result
    }
}
struct ShadowReplay {
    var baseline: PocketStatus
    var candidate: PocketStatus
    var inputDigest: String
    var readAt: Date
    var decisions: [ActivityFusionDecision] {
        let start=baseline.continuity?.segmentStart ?? .distantFuture
        return candidate.points.filter{$0.date>start}.compactMap{$0.effect?.activityExperiment}
    }
    var coveredMinutes: Double { decisions.reduce(0){$0+$1.coveredMinutes} }
}
enum ShadowReplayAvailability:String {
    case ready,noLedger,legacyLedger,unidentifiedInputs,recentStateOnly,stale,missingOrigin,mismatchedResults,noEligibleTraining,mixedSources
    var message:String {
        switch self {
        case .ready:return "已有可配对结果；请查看本段实际采用的训练覆盖。"
        case .noLedger:return "尚无可检查的连续账本；连接健康并读取已有记录后再查看。"
        case .legacyLedger:return "旧账本不支持这项对照；保留原记录，不补造历史预测。"
        case .unidentifiedInputs:return "输入来源或摘要不完整，暂不形成双模型配对。"
        case .recentStateOnly:return "当前只有近期状态估计，没有可承接的连续电量段。"
        case .stale:return "观测已过期，先等待新记录或刷新；旧记录仍可回看。"
        case .missingOrigin:return "连续段起点尚未确认，暂不配对不同起点的结果。"
        case .mismatchedResults:return "两套结果与当前显示的观测不一致，暂不形成配对。"
        case .noEligibleTraining:return "本段没有训练时段通过影子条件；下方说明已读训练为何未用于对照。"
        case .mixedSources:return "本段替换时段使用了多个心率来源，暂不把它们混为一组配对。"
        }
    }
}
struct ShadowReplayInspection {
    var readAt:Date
    var availability:ShadowReplayAvailability
    var audit:ActivityFusionAudit? = nil
    var replay:ShadowReplay? = nil
}
extension ShadowReplay {
    var inspection:ShadowReplayInspection {
        let start=baseline.continuity?.segmentStart ?? .distantFuture
        let entries=candidate.points.filter{$0.date>start}.compactMap{$0.effect?.activityAssessment}.filter{$0.trainingMinutes.map{$0>0} == true || $0.reason == .invalidTraining}
        return ShadowReplayInspection(readAt:readAt,availability:.ready,
            audit:ActivityFusionAudit(segmentStart:start,observedAt:baseline.measuredAt ?? readAt,entries:entries),replay:self)
    }
}
enum ShadowReplayEngine {
    /// Pin to the formal model's exact origins. Diagnostic metadata never enables a candidate.
    static func inspect(ledger:BatteryLedger,inputDigest:String,now:Date)->ShadowReplayInspection {
        func unavailable(_ reason:ShadowReplayAvailability)->ShadowReplayInspection {
            ShadowReplayInspection(readAt:now,availability:reason)
        }
        guard ledger.continuousVersion==1 else{return unavailable(.legacyLedger)}
        guard ledger.sourceKey?.isEmpty==false,inputDigest.count==64,inputDigest.allSatisfy({$0.isHexDigit}) else{return unavailable(.unidentifiedInputs)}
        let baseline=ledger.status(now:now)
        guard !baseline.usesStateEstimate else{return unavailable(.recentStateOnly)}
        guard baseline.isFresh(at:now) else{return unavailable(.stale)}
        guard let origins=baseline.continuity?.origins,!origins.isEmpty else{return unavailable(.missingOrigin)}
        let candidate=ledger.experimentalStatus(now:now,origins:origins)
        guard candidate.measuredAt==baseline.measuredAt,candidate.isFresh(at:now),!candidate.usesStateEstimate else{return unavailable(.mismatchedResults)}
        let replay=ShadowReplay(baseline:baseline,candidate:candidate,inputDigest:inputDigest,readAt:now)
        var result=replay.inspection
        guard !replay.decisions.isEmpty else{result.replay=nil;result.availability = .noEligibleTraining;return result}
        guard Set(replay.decisions.map(\.source)).count==1 else{result.replay=nil;result.availability = .mixedSources;return result}
        return result
    }
    static func replay(ledger:BatteryLedger,inputDigest:String,now:Date)->ShadowReplay? {
        inspect(ledger:ledger,inputDigest:inputDigest,now:now).replay
    }
    /// A reproducible simulator fixture, kept separate from real HealthKit records.
    static func demo(now:Date=Date()) -> ShadowReplay? {
        let end=now.addingTimeInterval(-60),start=end.addingTimeInterval(-3600)
        let samples=(0...60).map{WorkoutHeartSample(date:start.addingTimeInterval(Double($0)*60),bpm:160,source:"synthetic-shadow-watch")}
        let spans=WorkoutHeartFallback.make(samples:samples,windows:[(start,end)],start:start,end:end,now:now,reference:60,source:"synthetic-shadow-watch")
        let row=BatteryHour(start:start,end:end,sleepHours:0,activeKcal:350,heartRate:160,heartRateCount:61,heartRateCoverageHours:1,workoutHours:1,personalHR:60,awakeHeartRate:160,awakeHeartRateCount:61,awakeHeartRateCoverageHours:1,workoutHeartSpans:spans)
        let origin=BatteryOrigin(bucketStart:start,date:start,value:80,uncertainty:30,reason:"合成演示固定起点")
        let ledger=BatteryLedger(baselineHR:60,hours:[row],sourceKey:"synthetic-shadow",continuousVersion:1,continuousOrigins:[origin])
        var result=replay(ledger:ledger,inputDigest:String(repeating:"d",count:64),now:now)
        result?.baseline.demo=true;result?.candidate.demo=true
        return result
    }
}
