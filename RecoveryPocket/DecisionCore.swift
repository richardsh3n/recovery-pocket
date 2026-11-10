import Foundation

struct DailyAction: Identifiable {
    enum Kind: String { case training = "训练", sleep = "睡眠", stress = "压力" }
    var kind: Kind
    var icon: String
    var headline: String
    var reason: String
    var eventKind: String
    var lead: Bool = false
    var id: String { kind.rawValue }
}

struct EnergyBudget {
    var remaining: Int
    var spent: Int
    var note: String
}

struct DailyDecision {
    enum Level: String { case push = "按计划", steady = "正常", hold = "优先恢复", unknown = "等待数据" }
    var level: Level
    var headline: String
    var subline: String
    var recovery: Int?
    var strain: Double?
    var budget: EnergyBudget?
    var actions: [DailyAction]
    var insight: String?
    var caveat: String

}

private func decisionHours(_ value: Double) -> String {
    let minutes = Int((value * 60).rounded())
    return minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(minutes % 60) 分"
}

enum DecisionEngine {
    /// Combines the existing recovery estimate, battery status and last night into
    /// one plain-language conclusion plus three concrete actions. Nothing here is
    /// a new measurement; it is a rephrasing of the experimental model's output.
    static func make(estimate: RecoveryEstimate?, status: PocketStatus, lastNight: NightRecord?,
                     todayKcal: Double?, strain: Double?, sleepTarget: Double, intent: String, now: Date) -> DailyDecision {
        let currentEstimate = estimate.flatMap { Calendar.current.isDate($0.date, inSameDayAs: now) && $0.date <= now ? $0 : nil }
        let score = currentEstimate?.score.flatMap { (0...100).contains($0) ? $0 : nil }
        let currentNight = lastNight.flatMap { Calendar.current.isDate($0.date, inSameDayAs: now) && $0.date <= now ? $0 : nil }
        let reserve = status.usesStateEstimate ? nil : status.displayValue(at: now)
        let currentStrain = strain.flatMap { $0.isFinite && (0...21).contains($0) ? $0 : nil }
        let depleted = reserve.map { $0 <= 25 } == true
        let loaded = currentStrain.map { $0 >= 14 } == true
        let level: DailyDecision.Level
        if intent == "恢复" || depleted || loaded { level = .hold } else if let score { level = score < 45 ? .hold : score >= 80 ? .push : .steady } else { level = .unknown }

        var headline = "", subline = ""
        switch level {
        case .push:
            headline = "按原计划，先看体感"
            subline = "恢复模型给出较高参考；它不能保证训练能力，不据此额外加量。"
        case .steady:
            headline = "给今天留一点余量"
            subline = "结合实际感受执行原计划，记录训练后的精力。"
        case .hold:
            headline = "今天优先恢复"
            subline = intent == "恢复" ? "你选择了恢复重点，今天优先安排休息和轻松活动。" : loaded ? "今天已记录的活动负荷较高，先回顾已完成训练与体感。" : depleted ? "当前模型电量余量较低，先休息并记录感受。" : "恢复模型参考较低，先对照睡眠与体感。"
        case .unknown:
            headline = "先补齐依据，再判断状态"
            subline = "昨夜数据不足以给出恢复参考，先用睡眠记录和体感作参考。"
        }
        if intent == "恢复", level == .push { subline = "恢复不错，但你今天选的是恢复——把强度留到明天也很合理。" }

        var actions: [DailyAction] = []
        switch level {
        case .push:
            actions.append(DailyAction(kind: .training, icon: "figure.run", headline: "按原计划，不额外加量", reason: "模型参考 \(score.map(String.init) ?? "—")，训练仍以体感为准", eventKind: "训练", lead: true))
        case .steady:
            actions.append(DailyAction(kind: .training, icon: "figure.walk", headline: "把计划调整到舒适强度", reason: "先看精力与已完成训练，再决定下一步", eventKind: "训练", lead: true))
        case .hold:
            actions.append(DailyAction(kind: .training, icon: "figure.cooldown", headline: "先休息，再看是否继续", reason: loaded ? "当天负荷已较高，先对照训练后感受" : depleted ? "当前实验模型余量较低" : "今日以恢复与体感为重点", eventKind: "休息", lead: true))
        case .unknown:
            actions.append(DailyAction(kind: .training, icon: "figure.walk", headline: "按体感决定是否训练", reason: "缺少昨夜数据，别单靠分数加码", eventKind: "训练", lead: true))
        }

        if let night = currentNight, let hours = night.sleepHours, hours.isFinite, (0...18).contains(hours) {
            let goal = sleepTarget.isFinite && (4...12).contains(sleepTarget) ? sleepTarget : 8
            let gap = max(0, goal - hours)
            if gap >= 0.5 {
                actions.append(DailyAction(kind: .sleep, icon: "moon.zzz", headline: "今晚给睡眠留足时间", reason: "昨夜 \(decisionHours(hours)) · 低于目标 \(decisionHours(goal))", eventKind: "休息"))
            } else {
                actions.append(DailyAction(kind: .sleep, icon: "moon.stars", headline: "维持固定作息", reason: "昨夜 \(decisionHours(hours)) · \(gap > 0.01 ? "接近个人目标" : "达到个人目标")", eventKind: "休息"))
            }
        } else {
            actions.append(DailyAction(kind: .sleep, icon: "moon.stars", headline: "记录今晚的睡眠", reason: "还没有读到昨夜记录，缺失不代表没睡", eventKind: "休息"))
        }

        if level == .hold {
            actions.append(DailyAction(kind: .stress, icon: "wind", headline: "安排 10 分钟呼吸练习", reason: loaded ? "已记录活动较多，留一段安静休息" : depleted ? "电量参考较低，先对照实际精力" : "按今天的恢复重点，给自己留一点空隙", eventKind: "休息"))
        } else {
            actions.append(DailyAction(kind: .stress, icon: "cup.and.saucer", headline: "午后留一次短休息", reason: "让节奏更贴合你当前的状态", eventKind: "休息"))
        }

        var budget: EnergyBudget? = nil
        if let value = reserve {
            budget = EnergyBudget(remaining: value, spent: status.drained, note: "今日已消耗 \(status.drained) 点 · 当前剩余参考 \(value) 点")
        }

        var insight: String? = nil
        if let gap = currentEstimate?.sleepGap, gap >= 1.5 {
            insight = "近 7 夜睡眠净目标差额 \(decisionHours(gap))"
        } else if let top = currentEstimate?.reasons.first {
            insight = "\(top.name) · \(top.detail)"
        } else if let strain, strain >= 14 {
            insight = "今日负荷偏高（\(String(format: "%.1f", strain)) / 21）"
        }

        return DailyDecision(level: level, headline: headline, subline: subline, recovery: score, strain: currentStrain,
                             budget: budget, actions: actions, insight: insight,
                             caveat: "结论由现有的实验估计改写而来，未个体校准；用于安排节奏，不是医学判断。")
    }
}

