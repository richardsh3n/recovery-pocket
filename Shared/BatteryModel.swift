import Foundation

struct BatteryPoint: Codable, Identifiable {
    var date: Date
    var value: Double?
    var mode: String
    var effect: BatteryHourEffect? = nil
    var id: Date { date }
}
struct BatteryHour: Codable {
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
}
struct BatteryHourEffect: Codable {
    var sleepRecharge: Double
    var restRecharge: Double
    var awakeDrain: Double
    var activityDrain: Double
    var heartRateDrain: Double
    var hrvDrain: Double
    var sleepHRVAdjustment: Double
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
    var modelRevision: String? = nil
    static var empty: PocketStatus { PocketStatus(computedAt: .distantPast, measuredAt: nil, value: nil, lower: nil, upper: nil, charged: 0, drained: 0, message: "等待 iPhone 同步", points: [], demo: false) }
    func isFresh(at now: Date) -> Bool {
        guard let measuredAt, let value, (0...100).contains(value) else { return false }
        return now.timeIntervalSince(measuredAt) >= -60 && now.timeIntervalSince(measuredAt) <= 7200 && Calendar.current.isDate(measuredAt, inSameDayAs: now)
    }
    var evidenceLabel: String {
        guard let inputs else { return "读取计算依据" }
        return inputs.sleepHRVHours > 0 || inputs.awakeHRVMinutes > 0 ? "包含 HRV 参考" : "睡眠与活动估计"
    }
    func dataNote(at now: Date) -> String? {
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
    func displayValue(at now: Date) -> Int? { isFresh(at: now) ? value : nil }
}

/// Experimental reserve estimate, not Garmin's proprietary Body Battery.
/// Recorded sleep and sufficiently sampled low activity may charge; unknown time never does.
/// Awake heart rate is a nonspecific strain proxy, not an HRV stress measurement.
enum BatteryModel {
    static func calculate(hours: [BatteryHour], anchor: Double?, baselineHR: Double?, nightHRVZ: Double = 0, now: Date, calendar: Calendar = .current, initialUncertainty: Double = 12) -> PocketStatus {
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
        for hour in hours.sorted(by: { $0.start < $1.start }) {
            guard hour.start < now, hour.end > hour.start, hour.end <= now, previousEnd.map({ hour.start >= $0 }) ?? true else { continue }
            if let previousEnd, hour.start > previousEnd { uncertainty = min(40, uncertainty + hour.start.timeIntervalSince(previousEnd) / 3600 * 2) }
            previousEnd = hour.end
            let duration = hour.end.timeIntervalSince(hour.start) / 3600
            let sleep = hour.sleepHours.isFinite ? min(duration, max(0, hour.sleepHours)) : 0
            let energy = hour.activeKcal.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let hr = hour.heartRate.flatMap { $0.isFinite && (25...220).contains($0) && hour.heartRateCount >= 2 ? $0 : nil }
            guard sleep > 0 || (energy ?? 0) > 0 || hr != nil else {
                uncertainty = min(40, uncertainty + duration * 2)
                if hour.end > today { inputs.unobservedHours = (inputs.unobservedHours ?? 0) + hour.end.timeIntervalSince(max(today,hour.start))/3600 }
                points.append(BatteryPoint(date: hour.end, value: nil, mode: "缺少采样")); continue
            }
            let referenceHR = hour.personalHR.flatMap { $0.isFinite && (25...150).contains($0) ? $0 : nil } ?? legacyReferenceHR
            let awake = duration - sleep
            // Coefficients are initial engineering assumptions awaiting personal validation.
            // Only same-context, observed sleep HRV may modulate sleep recharge.
            // A night-wide caller value is retained only for legacy synthetic comparisons.
            let hrvZ = hour.sleepHRVZ.flatMap { $0.isFinite ? max(-3, min(3, $0)) : nil }
                ?? (nightHRVZ.isFinite ? max(-3, min(3, nightHRVZ)) : 0)
            let sleepRate = hour.sleepHeartRate.flatMap { $0.isFinite && (25...220).contains($0) ? $0 : nil } ?? (sleep >= duration * 0.9 ? hr : nil)
            let sleepHRElevation = sleepRate.flatMap { rate in referenceHR.map { max(0, min(1, (rate - $0 - 5) / 20)) } } ?? 0
            // A lone SDNN sample has less influence than several comparable observations.
            // Unusually high values do not produce an unlimited recovery reward.
            let sampleWeight = hour.sleepHRVCount.map { min(1,Double(max(0,$0))/4) } ?? (hour.sleepHRVZ == nil ? 1 : 0.25)
            let hrvAdjustment = hrvZ > 2 ? 0 : max(-0.3,min(0.1,hrvZ * 0.1)) * sampleWeight
            let qualityWithoutHRV = max(0.45,min(1.15,1 - sleepHRElevation * 0.35))
            let quality = max(0.45, min(1.15, 1 + hrvAdjustment - sleepHRElevation * 0.35))
            let exercising = hour.workoutHours.map { $0.isFinite && $0 > 0 } == true
            let moving = exercising || hour.steps.map { $0.isFinite && $0 > 100 * duration } == true
            let coverage = hour.heartRateCoverageHours.isFinite ? min(duration, max(0, hour.heartRateCoverageHours)) : 0
            let lowObservedHRV = hour.awakeHRVZ.map { $0.isFinite && $0 < -1 } == true
            let observedRest = !moving && coverage >= duration * 0.5 && awake > 0 && hour.heartRateCount >= 6 && energy.map { $0 <= 5 * duration } == true && hr.flatMap { rate in referenceHR.map { rate <= $0 + 8 } } == true
            // A bounded recovery process replaces the old fixed +6/h, which trapped
            // depleted reserves near 53 after eight hours. Tau=6h is an explicit
            // engineering prior, not a physiological constant or Garmin formula.
            // The exponential is invariant to splitting a pure sleep interval.
            let sleepRecharge = (100 - reserve) * (1 - exp(-sleep * quality / 6))
            let hrvCoverage = hour.awakeHRVObservedHours.flatMap { $0.isFinite ? min(awake, max(0, $0)) : nil } ?? 0
            // A short low-HRV observation can reduce rest credit only for that window.
            let eligibleRest = max(0,min(awake,coverage) - (lowObservedHRV ? hrvCoverage : 0))
            let restRecharge = observedRest ? eligibleRest * 1.8 : 0
            let recharge = sleepRecharge + restRecharge
            let strain = hr.flatMap { rate in referenceHR.map { max(0, min(3, (rate - $0 - 15) / 15)) } } ?? 0
            // Do not double-penalize elevated HR during a high-activity hour.
            let unexplainedStrain = moving || energy.map { $0 > 35 * duration } == true ? 0 : strain
            // Sparse daytime SDNN influences only observed minutes; never fills an hour.
            let hrvStrain = !moving ? hour.awakeHRVZ.flatMap { $0.isFinite ? max(0, min(3, -$0)) : nil } ?? 0 : 0
            let extraHRVDrain = max(0, hrvStrain - unexplainedStrain) * 0.7 * hrvCoverage
            // Hourly calories do not establish an entire hour of wakefulness.
            // Restrict time-based drain to observed HR/HRV or recorded workout coverage.
            let trainingCoverage = hour.workoutHours.flatMap { $0.isFinite ? min(duration,max(0,$0)) : nil } ?? 0
            let awakeCoverage = min(awake,max(coverage,max(hrvCoverage,trainingCoverage)))
            let awakeDrain = awakeCoverage * 1.1
            let hrDrain = unexplainedStrain * 0.7 * min(awake,coverage)
            let activityDrain = (energy ?? 0) / 35
            let drain = awakeDrain + hrDrain + activityDrain + extraHRVDrain
            let sleepHRVDelta = sleepRecharge - (100 - reserve) * (1 - exp(-sleep * qualityWithoutHRV / 6))
            let next = min(100, max(5, reserve + recharge - drain))
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
                inputs.activeKcal += (energy ?? 0) * fraction
                inputs.observedHours += duration * fraction
                inputs.unobservedHours = (inputs.unobservedHours ?? 0) + max(0,duration-sleep-awakeCoverage) * fraction
            }
            reserve = next; last = hour.end
            uncertainty = min(40, max(8, uncertainty + max(0,duration-sleep-awakeCoverage) * 0.8 - (sleep+awakeCoverage) * 0.15))
            points.append(BatteryPoint(date: hour.end, value: reserve, mode: recharge > drain ? (sleep > 0 ? "睡眠补充" : "低活动补充") : (exercising ? "训练消耗" : unexplainedStrain > 0 ? "心率偏高消耗" : "活动消耗"), effect: BatteryHourEffect(sleepRecharge:sleepRecharge,restRecharge:restRecharge,awakeDrain:awakeDrain,activityDrain:activityDrain,heartRateDrain:hrDrain,hrvDrain:extraHRVDrain,sleepHRVAdjustment:sleepHRVDelta)))
        }
        let value = last == nil ? nil : Int(reserve.rounded())
        return PocketStatus(computedAt: now, measuredAt: last, value: value,
            lower: value.map { max(5, Int((Double($0) - uncertainty).rounded())) },
            upper: value.map { min(100, Int((Double($0) + uncertainty).rounded())) },
            charged: Int(charged.rounded()), drained: Int(drained.rounded()),
            message: last == nil ? "缺少日内观测" : "身体电量参考 · 实验模型", points: points, demo: false, inputs: inputs, modelRevision:"0.4 / evidence")
    }
}

enum BatteryDemo {
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

/// Retains timestamped aggregate bins so refresh/restart never reanchors to a morning score.
/// Initial 50 is an explicit neutral engineering prior, not a readiness measurement.
struct BatteryLedger: Codable {
    var baselineHR: Double?
    var hours: [BatteryHour]
    // Device/source identity stays local; nil marks a pre-identity ledger.
    var sourceKey: String? = nil
    func matches(source: String) -> Bool { sourceKey == source }
    mutating func merge(_ incoming: [BatteryHour]) {
        var bins = Dictionary(hours.map { ($0.start, $0) }, uniquingKeysWith: { _, newer in newer })
        for hour in incoming { bins[hour.start] = hour }
        hours = bins.values.sorted { $0.start < $1.start }
    }
    func status(now: Date) -> PocketStatus {
        BatteryModel.calculate(hours: hours, anchor: 50, baselineHR: baselineHR, now: now, initialUncertainty: 30)
    }
}
enum HeartRateCoverage {
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
            return PocketWorkout(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!, title: title, start: start.addingTimeInterval(a * 3600), end: start.addingTimeInterval(b * 3600), duration: (b-a)*3600, activeKcal: kcal, source: "合成演示")
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
        let end = min(now, calendar.date(byAdding: .day, value: 1, to: start)!)
        let ordered = points.sorted { $0.date < $1.date }
        let selected = ordered.filter { $0.date > start && $0.date <= end && $0.value.map { $0.isFinite && (0...100).contains($0) } == true }
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
        }
        let values = selected.compactMap(\.value)
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
enum DayHRVModel {
    /// A descriptive SDNN comparison, not a validated stress or mental-health score.
    static func compare(_ input: [HRVObservation], now: Date, calendar: Calendar = .current) -> [HRVObservation] {
        let ordered = Dictionary(input.filter { $0.sdnn.isFinite && $0.sdnn > 0 && $0.end >= $0.start && $0.end <= now }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values.sorted { $0.start < $1.start }
        return ordered.map { row in
            var result = row; result.deviation = nil; result.baselineDays = 0
            guard row.context == "安静候选" else { return result }
            let seconds = row.end.timeIntervalSince(row.start)
            guard (30...300).contains(seconds) else { return result }
            let durationBucket = Int(seconds / 30)
            let day = calendar.startOfDay(for: row.start)
            let cutoff = calendar.date(byAdding: .day, value: -28, to: day)!
            let block = calendar.component(.hour, from: row.start) / 6
            let prior = ordered.filter { $0.context == row.context && $0.source == row.source && $0.end < day && $0.start >= cutoff && calendar.component(.hour, from: $0.start) / 6 == block && Int($0.end.timeIntervalSince($0.start) / 30) == durationBucket }
            let grouped = Dictionary(grouping: prior, by: { calendar.startOfDay(for: $0.start) })
            let medians = grouped.values.map { rows -> Double in
                let values = rows.map(\.sdnn).sorted(), mid = values.count / 2
                return values.count % 2 == 0 ? (values[mid-1] + values[mid]) / 2 : values[mid]
            }
            result.baselineDays = medians.count
            result.deviation = SleepHRVComparison.deviation(current: row.sdnn, prior: medians)
            return result
        }
    }
    static func summary(_ rows: [HRVObservation], now: Date, calendar: Calendar = .current) -> DayHRVSummary? {
        guard let row = rows.filter({ $0.context == "安静候选" && calendar.isDate($0.end, inSameDayAs: now) && $0.end <= now }).max(by: { $0.end < $1.end }) else { return nil }
        return DayHRVSummary(date: row.end, sdnn: row.sdnn, label: row.label, baselineDays: row.baselineDays)
    }
    /// Only actual eligible sample intervals count. Duplicate/overlapping records merge.
    static func observedHours(_ rows: [HRVObservation], start: Date, end: Date) -> Double {
        let spans = rows.filter { $0.context == "安静候选" && $0.deviation != nil }.map {
            (max(start, $0.start), min(end, min($0.end, $0.start.addingTimeInterval(300))))
        }.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        var total = 0.0, until: Date? = nil
        for (a, b) in spans { let from = max(a, until ?? a); total += max(0, b.timeIntervalSince(from)); until = max(until ?? b, b) }
        return total / 3600
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
