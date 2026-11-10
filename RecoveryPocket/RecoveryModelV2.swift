import Foundation

struct RecoveryDay: Codable, Identifiable {
    var night: NightRecord
    // Energy from the calendar day preceding this night's ending date.
    var activeKcal: Double?
    var sleepMidpointHour: Double?
    var id: Date { night.date }
}
struct RecoveryDriver: Identifiable {
    var name: String
    var detail: String
    var burden: Double
    var id: String { name }
}
struct RecoveryEstimate: Identifiable {
    var date: Date
    var score: Int?
    var lower: Int?
    var upper: Int?
    var state: String
    var reliability: String
    var reasons: [RecoveryDriver]
    var baselineNights: Int
    var sleepGap: Double
    var measurementUsed: Bool
    var sleepCompletion: Int? = nil
    var scoreBasis: String = "实验恢复指数"
    var id: Date { date }
}

/// Experimental scalar state-space model. The filtering equations follow the
/// standard Kalman formulation documented by FilterPy; this Swift implementation
/// is original. Noise levels, dynamics and score mapping are engineering priors,
/// not measured physiological constants or clinical confidence limits.
enum RecoveryModelV2 {
    static let revision = "0.24 / episode-matched baseline-relative morning recovery"
    static let scaleNote = "65 接近个人惯常状态；更高表示本次信号更有利，更低表示恢复负担更明显。不是剩余电量、百分位或训练能力百分比。"
    // Explicit provisional scale: baseline burden 0 -> 65; +/-2 -> about 94/15.
    // No daily min/max stretching, and no trained/calibrated physiological claim.
    static func index(burden: Double) -> Int {
        Int((100 / (1 + exp(clamp(1.15 * burden - log(65.0/35.0), -20, 20)))).rounded())
    }

    static func clamp(_ value: Double, _ minValue: Double, _ maxValue: Double) -> Double {
        max(minValue, min(maxValue, value))
    }
    static func valid(_ n: NightRecord) -> Bool {
        guard let sleep = n.sleepHours, let hrv = n.hrv, let hr = n.heartRate else { return false }
        return sleep.isFinite && (3...18).contains(sleep) && hrv.isFinite && hrv > 0 && hrv < 1000 &&
            hr.isFinite && (25...150).contains(hr) && n.hrvCount >= 2 && n.heartRateCount >= 6
    }
    static func z(_ value: Double, _ samples: [Double], floor: Double) -> Double {
        guard let center = RecoveryEngine.median(samples), let mad = RecoveryEngine.median(samples.map { abs($0 - center) }) else { return 0 }
        return clamp((value - center) / max(floor, 1.4826 * mad), -3, 3)
    }
    static func calculate(days input: [RecoveryDay], sleepTarget: Double = 8, calendar: Calendar = .current) -> [RecoveryEstimate] {
        // One record per local night, deterministic merge, strictly past-only baselines.
        let grouped = Dictionary(grouping: input) { calendar.startOfDay(for: $0.id) }
        let days = grouped.keys.sorted().compactMap { date in
            grouped[date]?.max { a, b in
                (a.night.hrvCount + a.night.heartRateCount) < (b.night.hrvCount + b.night.heartRateCount)
            }
        }
        let target = sleepTarget.isFinite ? clamp(sleepTarget, 4, 12) : 8
        var fatigue = 0.0, variance = 0.7
        var previous: Date?
        var results: [RecoveryEstimate] = []
        for (index, day) in days.enumerated() {
            let n = day.night
            let baselineStart = calendar.date(byAdding: .day, value: -60, to: n.date)!
            let prior = days[..<index].filter { $0.id >= baselineStart }
            let baseline = prior.filter { valid($0.night) && $0.night.hrvSourceKey == n.hrvSourceKey && $0.night.heartRateSourceKey == n.heartRateSourceKey && $0.night.hrvDurationBucket == n.hrvDurationBucket }
            // Each channel builds its own baseline: missing HR must not silence SDNN.
            let priorNights=prior.map(\.night)
            let hrvBaseline = NightlyComparison.history(for:n,in:priorNights,channel:.hrv,days:60,calendar:calendar).map { RecoveryDay(night:$0,activeKcal:nil,sleepMidpointHour:nil) }
            let hrBaseline = NightlyComparison.history(for:n,in:priorNights,channel:.heartRate,days:60,calendar:calendar).map { RecoveryDay(night:$0,activeKcal:nil,sleepMidpointHour:nil) }
            let elapsed = previous.map { max(1, calendar.dateComponents([.day], from: $0, to: n.date).day ?? 1) } ?? 1
            previous = n.date
            let recentStart = calendar.date(byAdding: .day, value: -6, to: n.date)!
            let week = Array(prior.filter { $0.id >= recentStart }) + [day]
            let sleepNights = week.compactMap { item -> Double? in
                guard let hours = item.night.sleepHours, hours.isFinite, (0...18).contains(hours) else { return nil }
                return hours
            }
            // A signed seven-day shortfall relative to the chosen goal, not a claim
            // about a biological debt that can be repaid hour-for-hour.
            let sleepGap = max(0, sleepNights.reduce(0) { $0 + target - $1 })
            let missingDays = max(0, 7 - sleepNights.count)
            let availableSleep = n.sleepHours.map { $0.isFinite && (0...18).contains($0) } ?? false
            let sleepDeficit = availableSleep ? max(0, target - n.sleepHours!) : 0
            let energyBaseline = prior.compactMap(\.activeKcal).filter { $0.isFinite && $0 >= 0 }
            var loadZ: Double?
            if let energy = day.activeKcal, energy.isFinite, energy >= 0, energyBaseline.count >= 14 {
                loadZ = z(energy, energyBaseline, floor: 150)
            }
            let rho = pow(0.82, Double(min(elapsed, 7)))
            fatigue *= rho
            variance = min(3, rho * rho * variance + 0.12 * Double(elapsed))
            var reasons: [RecoveryDriver] = []
            let recentValid = hrvBaseline.filter { $0.id >= recentStart }.suffix(7)
            let hrvValues = hrvBaseline.compactMap { $0.night.hrv.map(log) }
            let hrValues = hrBaseline.compactMap { $0.night.heartRate }
            var trend = 0.0
            if recentValid.count >= 3, let meanHRV = RecoveryEngine.median(recentValid.compactMap { $0.night.hrv.map(log) }) {
                trend = max(0, -z(meanHRV, hrvValues, floor: 0.15))
            }
            var precision = 0.0, weighted = 0.0
            var hrvZ: Double?, hrZ: Double?
            if hrvBaseline.count >= 3, let hrv = n.hrv, hrv.isFinite, hrv > 0, hrv < 1000, n.hrvCount >= 1 {
                let dev = z(log(hrv), hrvValues, floor: 0.15); hrvZ = dev
                // Mark atypically high HRV as atypical rather than reward it endlessly.
                // Taper the favorable contribution continuously beyond +2 rather
                // than creating a score cliff at the outlier threshold.
                let burden = dev > 2 ? -2 * max(0,3-dev) : -dev
                let noise = 0.35 + 1.5 / Double(min(10,n.hrvCount))
                precision += 1 / noise; weighted += burden / noise
                reasons.append(RecoveryDriver(name: "自主神经信号", detail: "睡眠 HRV \(String(format: "%.0f", hrv)) ms · \(n.hrvCount) 条 · \(hrvBaseline.count) 个 HRV 历史夜；相对个人范围 \(String(format: "%+.1f", dev))", burden: burden))
            }
            if hrBaseline.count >= 3, let hr = n.heartRate, hr.isFinite, (25...150).contains(hr), n.heartRateCount >= 2 {
                let dev = z(hr, hrValues, floor: 3); hrZ = dev
                let burden = dev < -2 ? -2 * max(0,3+dev) : dev
                let noise = 0.45 + 6 / Double(min(60,n.heartRateCount))
                precision += 1 / noise; weighted += burden / noise
                reasons.append(RecoveryDriver(name: "睡眠心率", detail: "\(String(format: "%.0f", hr)) 次/分 · \(hrBaseline.count) 个心率历史夜；相对个人范围 \(String(format: "%+.1f", dev))", burden: burden))
            }
            let measured = precision > 0
            let observation = measured ? weighted / precision : 0
            if measured {
                let noise = 1 / precision
                let gain = variance / (variance + noise)
                fatigue += gain * (observation - fatigue)
                // Joseph scalar form preserves a non-negative covariance.
                variance = (1 - gain) * (1 - gain) * variance + gain * gain * noise
            }
            let sleepBurden = sleepDeficit * 0.24 + sleepGap * 0.035
            let loadBurden = max(0, loadZ ?? 0) * 0.10
            // Current night drives the morning score; the filtered trend stabilizes
            // it without suppressing the immediate response to observed deviations.
            let signalBurden = 0.75 * observation + 0.25 * fatigue
            let conflicting = (hrvZ ?? 0) > 1.5 && (hrZ ?? 0) > 1.5
            let total = (conflicting ? max(0,signalBurden) : signalBurden) + sleepBurden + trend * 0.12 + loadBurden
            if availableSleep {
                reasons.append(RecoveryDriver(name: "睡眠与近期目标差额", detail: "昨夜 \(String(format: "%.1f", n.sleepHours!)) 小时 · 近 7 夜净目标差额 \(String(format: "%.1f", sleepGap)) 小时（含超额抵扣）；计划页逐夜缺口不抵扣", burden: sleepBurden))
            }
            if let loadZ {
                reasons.append(RecoveryDriver(name: "前日活动负荷", detail: "活动能量相对个人范围 \(String(format: "%+.1f", loadZ))；不等同心理压力", burden: loadBurden))
            }
            let atypical = (hrvZ ?? 0) > 2 || (hrZ ?? 0) < -2
            let fullSignals = valid(n)
            // Sleep remains visible, but sleep alone cannot establish autonomic
            // recovery. A single comparable channel can produce a partial estimate.
            let sufficient = measured
            let point = Self.index(burden:total)
            let uncertainty = max(0.35,max(sqrt(variance), measured ? 0.75 / sqrt(precision) : 0)) + Double(missingDays) * 0.04 + (conflicting || atypical ? 0.4 : 0) + (!fullSignals ? 0.25 : 0)
            let reliability = !sufficient ? (availableSleep ? "初步估计 · 仅睡眠参考" : "数据不足") : !fullSignals || baseline.count < 14 || (hrvZ != nil && n.hrvSourceKey == nil) || (hrZ != nil && n.heartRateSourceKey == nil) ? "初步估计 · 按现有记录" : conflicting ? "信号冲突" : atypical ? "信号偏离较大" : n.hrvCount < 4 || missingDays > 1 ? "有限采样" : "采样数量达标"
            let state = !sufficient ? "恢复待比较" : point >= 80 ? "高于个人惯常状态" : point >= 45 ? "接近个人惯常状态" : "低于个人惯常状态"
            if conflicting { reasons.append(RecoveryDriver(name: "信号需要复核", detail: "HRV 与心率同时偏高，不能简单解读成恢复更好。", burden: 0)) }
            if atypical {
                reasons.append(RecoveryDriver(name:"偏离个人范围",detail:"HRV 明显偏高或心率明显偏低时，减弱正向奖励并扩大模型范围；请结合实际感受，不将异常值直接解读为恢复更好。",burden:0))
            }
            if !measured {
                reasons.append(RecoveryDriver(name:"恢复待比较",detail:"当前没有可与历史比较的睡眠 HRV 或心率。已有睡眠照常展示，不用固定起点替代恢复状态。",burden:0))
            }
            reasons.append(RecoveryDriver(name:"分数含义",detail:scaleNote,burden:-10))
            results.append(RecoveryEstimate(date: n.date, score: sufficient ? point : nil,
                lower: sufficient ? Self.index(burden:total + uncertainty) : nil,
                upper: sufficient ? Self.index(burden:total - uncertainty) : nil,
                state: state, reliability: reliability, reasons: reasons.sorted { $0.burden > $1.burden },
                baselineNights: max(hrvBaseline.count,hrBaseline.count), sleepGap: sleepGap, measurementUsed: measured,
                sleepCompletion: availableSleep ? Int(min(100,n.sleepHours! / target * 100).rounded()) : nil,
                scoreBasis: hrvZ != nil && hrZ != nil ? "睡眠 HRV + 心率" : hrvZ != nil ? "仅可比睡眠 HRV" : hrZ != nil ? "仅可比睡眠心率" : "仅睡眠记录"))
        }
        return results
    }
}

// Adapted from W4rd2/whoordan RecoveryExplainer, Apache-2.0.
// Changes: finite/positive guards, SDNN-only matched baseline, 3 available components,
// minimum 14 prior nights at caller; diagnostic comparator only, not production battery.
enum OpenRecoveryReference {
    static func score(hrv: Double?, baselineHRV: Double?, restingHR: Double?, baselineRestingHR: Double?, sleepMinutes: Double?, needMinutes: Double?) -> Int? {
        func ratio(_ value: Double?, _ baseline: Double?) -> Double? {
            guard let value, let baseline, value.isFinite, baseline.isFinite, value > 0, baseline > 0 else { return nil }
            return value / baseline
        }
        var parts: [(Double, Double)] = []
        if let r = ratio(hrv, baselineHRV) { parts.append((50 + (r - 1) * 80, 0.35)) }
        if let r = ratio(restingHR, baselineRestingHR) { parts.append((50 + (1 - r) * 90, 0.20)) }
        if let r = ratio(sleepMinutes, needMinutes) { parts.append((min(r, 1.12) * 89, 0.17)) }
        guard parts.count == 3 else { return nil }
        return Int((parts.reduce(0) { $0 + min(100, max(0, $1.0)) * $1.1 } / 0.72).rounded())
    }
}
