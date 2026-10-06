import Foundation

struct SleepInterval: Codable, Equatable {
    var start: Date
    var end: Date
}

struct NightRecord: Codable, Identifiable {
    var date: Date
    var sleepHours: Double?
    var hrv: Double?
    var heartRate: Double?
    var hrvCount: Int
    var heartRateCount: Int
    var id: Date { date }
}

struct RecoveryResult {
    let score: Int?
    let baselineNights: Int
    let message: String
    let factors: [String]
}

/// Original experimental estimator. Neither an Apple nor a Garmin algorithm.
enum RecoveryEngine {
    static func merged(_ intervals: [SleepInterval], from: Date, to: Date) -> [SleepInterval] {
        let clipped = intervals.compactMap { interval -> SleepInterval? in
            let start = max(interval.start, from), end = min(interval.end, to)
            return end > start ? SleepInterval(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }
        var result: [SleepInterval] = []
        for item in clipped {
            if let last = result.last, item.start <= last.end {
                result[result.count - 1].end = max(last.end, item.end)
            } else { result.append(item) }
        }
        return result
    }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter { $0.isFinite }.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    static func robustZ(_ value: Double, against values: [Double], floor: Double) -> Double {
        guard let center = median(values), let mad = median(values.map { abs($0 - center) }) else { return 0 }
        return max(-2, min(2, (value - center) / max(floor, 1.4826 * mad)))
    }

    static func score(today: NightRecord?, history: [NightRecord], sleepTarget: Double) -> RecoveryResult {
        guard let today else {
            return RecoveryResult(score: nil, baselineNights: 0, message: "尚无昨夜记录", factors: [])
        }
        let cutoff = Calendar.current.date(byAdding: .day, value: -42, to: today.date)!
        let baseline = history.filter {
            $0.date < today.date && $0.date >= cutoff && ($0.sleepHours ?? 0) >= 3 &&
            $0.hrvCount >= 2 && $0.heartRateCount >= 6 &&
            ($0.hrv ?? 0) > 0 && ($0.heartRate ?? 0) > 0
        }
        guard baseline.count >= 14 else {
            return RecoveryResult(score: nil, baselineNights: baseline.count,
                                  message: "建立个人基线：\(baseline.count)/14 个有效夜晚", factors: [])
        }
        guard let sleep = today.sleepHours, sleep >= 3,
              let hrv = today.hrv, hrv > 0, today.hrvCount >= 2,
              let hr = today.heartRate, hr > 0, today.heartRateCount >= 6 else {
            return RecoveryResult(score: nil, baselineNights: baseline.count,
                                  message: "昨夜数据不足，暂不评分", factors: ["需要睡眠 ≥3 小时、睡眠期间 HRV ≥2 条、心率 ≥6 条；缺失也可能来自权限或同步延迟。"])
        }
        let hrvZ = robustZ(log(hrv), against: baseline.compactMap { $0.hrv.map(log) }, floor: 0.15)
        let hrZ = robustZ(hr, against: baseline.compactMap(\.heartRate), floor: 3)
        let target = sleepTarget.isFinite ? max(6, min(10, sleepTarget)) : 8
        let sleepPart = max(0, min(100, 100 * sleep / target))
        let hrvPart = max(0, min(100, 65 + 17.5 * hrvZ))
        let heartPart = max(0, min(100, 65 - 17.5 * hrZ))
        let value = Int((0.4 * hrvPart + 0.3 * heartPart + 0.3 * sleepPart).rounded())
        return RecoveryResult(score: value, baselineNights: baseline.count, message: "实验性恢复参考",
                              factors: ["睡眠 \(String(format: "%.1f", sleep)) 小时 / 目标 \(String(format: "%.1f", target)) 小时（权重 30%）",
                                        "睡眠期间 HRV 相对个人基线 \(String(format: "%+.1f", hrvZ))（权重 40%）",
                                        "睡眠期间心率相对个人基线 \(String(format: "%+.1f", hrZ))（权重 30%）"])
    }
}

/// Select one stream without mixing devices. Recent coverage outranks historical volume.
/// A tie is deterministic; simultaneous devices still need explicit source selection.
enum HealthSourcePolicy {
    static func preferredKey(_ streams: [String: [Date]]) -> String? {
        guard let latest = streams.values.flatMap({ $0 }).max() else { return nil }
        let cutoff = latest.addingTimeInterval(-86400)
        return streams.filter { !$0.value.isEmpty }.sorted { a, b in
            let recentA = a.value.filter { $0 > cutoff }.count
            let recentB = b.value.filter { $0 > cutoff }.count
            if recentA != recentB { return recentA > recentB }
            return a.value.count == b.value.count ? a.key < b.key : a.value.count > b.value.count
        }.first?.key
    }
}
