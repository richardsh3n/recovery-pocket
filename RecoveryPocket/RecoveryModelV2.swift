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
    var id: Date { date }
}

/// Experimental scalar state-space model. The filtering equations follow the
/// standard Kalman formulation documented by FilterPy; this Swift implementation
/// is original. Noise levels, dynamics and score mapping are engineering priors,
/// not measured physiological constants or clinical confidence limits.
enum RecoveryModelV2 {
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
        let target = sleepTarget.isFinite ? clamp(sleepTarget, 6, 10) : 8
        var fatigue = 0.0, variance = 0.7
        var previous: Date?
        var results: [RecoveryEstimate] = []
        for (index, day) in days.enumerated() {
            let n = day.night
            let baselineStart = calendar.date(byAdding: .day, value: -60, to: n.date)!
            let prior = days[..<index].filter { $0.id >= baselineStart }
            let baseline = prior.filter { valid($0.night) }
            // Each channel builds its own baseline: missing HR must not silence SDNN.
            let hrvBaseline = prior.filter { item in
                let night = item.night
                return (night.sleepHours ?? 0) > 0 && night.hrvCount >= 1 && night.hrv.map { $0.isFinite && $0 > 0 && $0 < 1000 } == true
            }
            let hrBaseline = prior.filter { item in
                let night = item.night
                return (night.sleepHours ?? 0) > 0 && night.heartRateCount >= 2 && night.heartRate.map { $0.isFinite && (25...150).contains($0) } == true
            }
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
            let energyBaseline = prior.compactMap(\.activeKcal).filter { $0.isFinite && $0 > 0 }
            var loadZ: Double?
            if let energy = day.activeKcal, energy.isFinite, energyBaseline.count >= 14 {
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
                let burden = dev < 0 ? -dev : (dev > 2 ? 0.4 * (dev - 2) : -0.15 * dev)
                let noise = 0.35 + 1.5 / Double(min(10,n.hrvCount))
                precision += 1 / noise; weighted += burden / noise
                reasons.append(RecoveryDriver(name: "自主神经信号", detail: "睡眠 HRV \(String(format: "%.0f", hrv)) ms · \(n.hrvCount) 条 · \(hrvBaseline.count) 个 HRV 历史夜；相对个人范围 \(String(format: "%+.1f", dev))", burden: burden))
            }
            if hrBaseline.count >= 3, let hr = n.heartRate, hr.isFinite, (25...150).contains(hr), n.heartRateCount >= 2 {
                let dev = z(hr, hrValues, floor: 3); hrZ = dev
                let burden = max(-0.3, dev)
                let noise = 0.45 + 6 / Double(min(60,n.heartRateCount))
                precision += 1 / noise; weighted += burden / noise
                reasons.append(RecoveryDriver(name: "睡眠心率", detail: "\(String(format: "%.0f", hr)) 次/分 · \(hrBaseline.count) 个心率历史夜；相对个人范围 \(String(format: "%+.1f", dev))", burden: burden))
            }
            let measured = precision > 0
            if measured {
                let observation = weighted / precision
                let noise = 1 / precision
                let gain = variance / (variance + noise)
                fatigue += gain * (observation - fatigue)
                // Joseph scalar form preserves a non-negative covariance.
                variance = (1 - gain) * (1 - gain) * variance + gain * gain * noise
            }
            let sleepBurden = sleepDeficit * 0.24 + sleepGap * 0.035
            let loadBurden = max(0, loadZ ?? 0) * 0.10
            let total = max(-0.4, fatigue) + sleepBurden + trend * 0.12 + loadBurden
            if availableSleep {
                reasons.append(RecoveryDriver(name: "睡眠与连续缺口", detail: "昨夜 \(String(format: "%.1f", n.sleepHours!)) 小时 · 近 7 夜已记录目标缺口 \(String(format: "%.1f", sleepGap)) 小时", burden: sleepBurden))
            }
            if let loadZ {
                reasons.append(RecoveryDriver(name: "前日活动负荷", detail: "活动能量相对个人范围 \(String(format: "%+.1f", loadZ))；不等同心理压力", burden: loadBurden))
            }
            let conflicting = (hrvZ ?? 0) > 1.5 && (hrZ ?? 0) > 1.5
            let fullSignals = valid(n)
            let sufficient = fullSignals || availableSleep
            let point = Int(clamp(82 - 21 * total, 0, 100).rounded())
            let uncertainty = 21 * sqrt(variance) + Double(missingDays) * 1.2 + (conflicting ? 7 : 0)
            let reliability = !sufficient ? "数据不足" : !fullSignals || baseline.count < 14 ? "初步估计 · 按现有记录" : conflicting ? "信号冲突" : n.hrvCount < 4 || missingDays > 1 ? "有限采样" : "采样数量达标"
            let state = !sufficient ? "暂不判断" : point >= 75 ? "节奏平稳" : point >= 55 ? "留出余量" : "优先恢复"
            if conflicting { reasons.append(RecoveryDriver(name: "信号需要复核", detail: "HRV 与心率同时偏高，不能简单解读成恢复更好。", burden: 0)) }
            results.append(RecoveryEstimate(date: n.date, score: sufficient ? point : nil,
                lower: sufficient ? Int(clamp(Double(point) - uncertainty, 0, 100).rounded()) : nil,
                upper: sufficient ? Int(clamp(Double(point) + uncertainty, 0, 100).rounded()) : nil,
                state: state, reliability: reliability, reasons: reasons.sorted { $0.burden > $1.burden },
                baselineNights: max(hrvBaseline.count,hrBaseline.count), sleepGap: sleepGap, measurementUsed: measured))
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
