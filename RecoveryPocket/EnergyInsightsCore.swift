import Foundation

struct EnergyInterval: Identifiable {
    var start: Date
    var end: Date
    var before: Double
    var after: Double
    var mode: String
    var effect: BatteryHourEffect?
    var effectFraction: Double
    var id: Date { end }
    var seconds: Double { end.timeIntervalSince(start) }
    var delta: Double { after - before }
    var rate: Double { delta / seconds * 3600 }
}
struct EnergyHourCell: Identifiable {
    var start: Date
    var end: Date
    var delta: Double?
    var coveredSeconds: Double
    var id: Date { start }
    var rate: Double? { delta.flatMap { coveredSeconds > 0 ? $0 / coveredSeconds * 3600 : nil } }
}
struct EnergyFactor: Identifiable {
    var id: String
    var title: String
    var amount: Double
    var recharge: Bool
}
struct EnergyDayReport {
    var day: Date
    var intervals: [EnergyInterval]
    var hours: [EnergyHourCell]
    var factors: [EnergyFactor]
    var elapsedSeconds: Double
    var coveredSeconds: Double { intervals.reduce(0) { $0 + $1.seconds } }
    var effectCoverageSeconds: Double { intervals.filter { $0.effect != nil }.reduce(0) { $0 + $1.seconds } }
    var missingSeconds: Double { max(0,elapsedSeconds-coveredSeconds) }
    var charged: Double { intervals.reduce(0) { $0 + max(0,$1.delta) } }
    var drained: Double { intervals.reduce(0) { $0 + max(0,-$1.delta) } }
    var peak: EnergyInterval? { intervals.filter { $0.delta < 0 }.max { -$0.delta < -$1.delta } }
    var chargingPeak: EnergyInterval? { intervals.filter { $0.delta > 0 }.max { $0.delta < $1.delta } }
    var firstValue: Double? { intervals.first?.before }
    var lastValue: Double? { intervals.last?.after }
    var maximum: Double? { intervals.flatMap { [$0.before,$0.after] }.max() }
}
struct EnergyWorkoutComparison: Identifiable {
    var impact: WorkoutImpact
    var before: BatteryPoint?
    var after: BatteryPoint?
    var durationInDay: Double
    var id: UUID { impact.id }
    var coverage: Double { durationInDay > 0 ? min(1,impact.coveredSeconds/durationInDay) : 0 }
}
enum EnergyInsights {
    static func points(_ points:[BatteryPoint],now:Date) -> [BatteryPoint] {
        Dictionary(points.filter { $0.date <= now }.map { ($0.date,$0) },uniquingKeysWith:{ _,b in b }).values.sorted { $0.date < $1.date }
    }
    static func valid(_ value:Double?) -> Double? { value.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil } }
    static func day(points input:[BatteryPoint],day:Date,now:Date,calendar:Calendar = .current) -> EnergyDayReport {
        let start = calendar.startOfDay(for:day), midnight = calendar.date(byAdding:.day,value:1,to:start)!
        let end = max(start,min(now,midnight)), ordered = points(input,now:now)
        var intervals:[EnergyInterval] = []
        for (a,b) in zip(ordered,ordered.dropFirst()) {
            let span = b.date.timeIntervalSince(a.date)
            guard span > 0,span <= 3601,let av = valid(a.value),let bv = valid(b.value) else { continue }
            let from = max(start,a.date),until = min(end,b.date)
            guard until > from else { continue }
            // Boundary clipping is proportional within an existing model interval,
            // not a new HealthKit observation or an interpolation across missing time.
            let before = av+(bv-av)*from.timeIntervalSince(a.date)/span
            let after = av+(bv-av)*until.timeIntervalSince(a.date)/span
            intervals.append(EnergyInterval(start:from,end:until,before:before,after:after,mode:b.mode,effect:b.effect,effectFraction:until.timeIntervalSince(from)/span))
        }
        var hours:[EnergyHourCell] = [], cursor = start
        while cursor < midnight {
            let until = min(midnight,cursor.addingTimeInterval(3600))
            var covered = 0.0,delta = 0.0
            for interval in intervals {
                let seconds = max(0,min(until,interval.end).timeIntervalSince(max(cursor,interval.start)))
                covered += seconds; delta += interval.delta * seconds / interval.seconds
            }
            hours.append(EnergyHourCell(start:cursor,end:until,delta:covered > 0 ? delta : nil,coveredSeconds:covered))
            cursor = until
        }
        let specs:[(String,String,Bool,(BatteryHourEffect)->Double)] = [
            ("sleep","睡眠补充",true,{ $0.sleepRecharge }),
            ("rest","低活动补充",true,{ $0.restRecharge }),
            ("activity","活动能量",false,{ $0.activityDrain }),
            ("awake","观测时段基础消耗",false,{ $0.awakeDrain }),
            ("heart","心率参考",false,{ $0.heartRateDrain }),
            ("hrv","日间 HRV",false,{ $0.hrvDrain })
        ]
        let factors = specs.compactMap { id,title,recharge,read -> EnergyFactor? in
            let amount = intervals.reduce(0.0) { sum,interval in
                guard let effect = interval.effect else { return sum }
                let value = read(effect)
                return sum+(value.isFinite && value >= 0 ? value*interval.effectFraction : 0)
            }
            return amount > 0.005 ? EnergyFactor(id:id,title:title,amount:amount,recharge:recharge) : nil
        }
        return EnergyDayReport(day:start,intervals:intervals,hours:hours,factors:factors,elapsedSeconds:end.timeIntervalSince(start))
    }
    static func workouts(_ input:[PocketWorkout],points inputPoints:[BatteryPoint],day:Date,now:Date,calendar:Calendar = .current) -> [EnergyWorkoutComparison] {
        let start = calendar.startOfDay(for:day),end = min(now,calendar.date(byAdding:.day,value:1,to:start)!)
        let rows = Dictionary(input.filter { $0.start < end && $0.end > start && $0.end <= now && $0.end > $0.start }.map { ($0.id,$0) },uniquingKeysWith:{ _,b in b }).values.sorted { $0.start < $1.start }
        let ordered = points(inputPoints,now:now),windows = WorkoutAnalysis.windows(points:ordered,day:day,now:now,calendar:calendar)
        return WorkoutAnalysis.impacts(workouts:rows,windows:windows).map { impact in
            let a = max(start,impact.workout.start), b = min(end,impact.workout.end)
            let before = ordered.last { $0.date <= a && a.timeIntervalSince($0.date) <= 3600 && valid($0.value) != nil }
            let after = ordered.first { $0.date >= b && $0.date.timeIntervalSince(b) <= 3600 && valid($0.value) != nil }
            return EnergyWorkoutComparison(impact:impact,before:before,after:after,durationInDay:max(0,b.timeIntervalSince(a)))
        }
    }
    static func week(points:[BatteryPoint],ending day:Date,now:Date,calendar:Calendar = .current) -> [EnergyDayReport] {
        let last = calendar.startOfDay(for:day)
        return (0..<7).reversed().map { offset in self.day(points:points,day:calendar.date(byAdding:.day,value:-offset,to:last)!,now:now,calendar:calendar) }
    }
}

struct EnergyBalanceStep: Identifiable {
    var id: String
    var title: String
    var before: Double
    var after: Double
    var delta: Double { after-before }
}
struct EnergyBalance {
    var steps: [EnergyBalanceStep]
    var residual: Double
    var start: Double
    var end: Double
}
extension EnergyDayReport {
    /// Only show an endpoint waterfall when every intervening interval is traced.
    /// Disconnected intervals and old records remain available in the other charts.
    var balance: EnergyBalance? {
        guard let first = intervals.first,let last = intervals.last,
              intervals.allSatisfy({ $0.effect != nil }),
              zip(intervals,intervals.dropFirst()).allSatisfy({ abs($0.0.end.timeIntervalSince($0.1.start)) < 0.01 }) else { return nil }
        var cursor = first.before
        var steps: [EnergyBalanceStep] = []
        for factor in factors {
            let signed = factor.recharge ? factor.amount : -factor.amount
            steps.append(EnergyBalanceStep(id:factor.id,title:factor.title,before:cursor,after:cursor+signed)); cursor += signed
        }
        let adjustment = intervals.reduce(0.0) { $0 + ($1.effect?.boundaryAdjustment ?? 0)*$1.effectFraction }
        guard adjustment.isFinite else { return nil }
        if abs(adjustment) > 0.005 {
            steps.append(EnergyBalanceStep(id:"boundary",title:"上下限",before:cursor,after:cursor+adjustment)); cursor += adjustment
        }
        let residual = last.after-cursor
        // Legacy records without clipping contributions cannot be made to balance by invention.
        guard residual.isFinite,abs(residual) < 0.05 else { return nil }
        return EnergyBalance(steps:steps,residual:residual,start:first.before,end:last.after)
    }
}

struct EnergyCheckIn { var date: Date; var rating: Int }
struct EnergyFeelingPair: Identifiable {
    var date: Date
    var modelDate: Date
    var battery: Double
    var rating: Int
    var id: Date { date }
}
extension EnergyInsights {
    /// Compare a check-in only with a nearby earlier model value; no future leakage.
    /// This is an observational pairing, not a calibrated accuracy score.
    static func feelings(_ checkIns:[EnergyCheckIn],points input:[BatteryPoint],now:Date) -> [EnergyFeelingPair] {
        let ordered = points(input,now:now)
        let rows = Dictionary(checkIns.filter { $0.date <= now && (1...5).contains($0.rating) }.map { ($0.date,$0) },uniquingKeysWith:{ _,b in b }).values.sorted { $0.date < $1.date }
        return rows.compactMap { row in
            guard let point = ordered.last(where:{ $0.date <= row.date }),
                  row.date.timeIntervalSince(point.date) <= 3600,
                  !point.mode.contains("非观测"),let value = valid(point.value) else { return nil }
            return EnergyFeelingPair(date:row.date,modelDate:point.date,battery:value,rating:row.rating)
        }
    }
}
