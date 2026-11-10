import Foundation

struct RecordedPrediction: Codable, Equatable {
    var value:Int
    var observedAt:Date
    var capturedAt:Date
    var validUntil:Date
    var modelRevision:String
    var kind:String
    static func capture(_ status:PocketStatus,at now:Date) -> Self? {
        guard let value=status.displayValue(at:now),let measured=status.displayDate,measured <= now,let revision=status.modelRevision,!revision.isEmpty else { return nil }
        let expiry=status.usesStateEstimate ? status.stateEstimate?.validUntil ?? measured : measured.addingTimeInterval(7200)
        guard expiry >= now else { return nil }
        return Self(value:value,observedAt:measured,capturedAt:now,validUntil:expiry,modelRevision:revision,kind:status.usesStateEstimate ? "近期状态" : "身体电量")
    }
    func usable(for eventDate:Date,now:Date) -> Bool {
        (0...100).contains(value) && !modelRevision.isEmpty && ["近期状态","身体电量"].contains(kind) &&
        observedAt <= capturedAt && capturedAt <= validUntil && capturedAt <= now && eventDate <= now &&
        abs(eventDate.timeIntervalSince(capturedAt)) <= 300 && observedAt <= eventDate && eventDate <= validUntil
    }
}
struct PocketEvent: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var kind: String
    var energy: Int
    var note: String
    var prediction:RecordedPrediction? = nil
    var sessionRPE:Int? = nil
    var trainingMinutes:Double? = nil
    var workoutID:UUID? = nil
    var habitAnswers:[String:Bool]? = nil
    var recordedAt:Date? = nil
    var modifiedAt:Date? = nil
    var modelComparison:FrozenModelComparison? = nil
    /// Session-RPE weighted duration. Separate subjective load units, never kcal.
    var sessionLoad:Double? {
        guard kind == "训练",let rpe=sessionRPE,(0...10).contains(rpe),let minutes=trainingMinutes,minutes.isFinite,minutes > 0,minutes <= 1440 else { return nil }
        return Double(rpe)*minutes
    }
}
struct FeedbackPair: Identifiable {
    var event:PocketEvent
    var prediction:RecordedPrediction
    var id:UUID { event.id }
    var group:String { prediction.kind+" · "+prediction.modelRevision }
    // Explicit review bands; not an accuracy score or a calibrated conversion.
    var needsReview:Bool { (prediction.value >= 75 && event.energy <= 2) || (prediction.value <= 25 && event.energy >= 4) }
}
enum FeedbackEngine {
    static func attachment(_ prediction:RecordedPrediction?,eventDate:Date,recordedAt:Date) -> RecordedPrediction? {
        guard let prediction,recordedAt.timeIntervalSince(prediction.capturedAt) <= 300,prediction.usable(for:eventDate,now:recordedAt) else { return nil }
        return prediction
    }
    static func pairs(_ input:[PocketEvent],now:Date) -> [FeedbackPair] {
        let rows=Dictionary(input.map { ($0.id,$0) },uniquingKeysWith:{ _,b in b }).values
        return rows.compactMap { event in
            guard (1...5).contains(event.energy),let prediction=event.prediction,prediction.usable(for:event.date,now:now) else { return nil }
            return FeedbackPair(event:event,prediction:prediction)
        }.sorted { $0.event.date > $1.event.date }
    }
}

struct WellnessCheckIn: Identifiable {
    var date: Date
    var energy: Int
    var id: Date { date }
}
struct WellnessDay: Identifiable {
    var date: Date
    var sleep: Double?
    var hrv: Double?
    var kcal: Double?
    var trainingMinutes: Double?
    var feeling: Double?
    var id: Date { date }
}
struct WellnessWeek {
    var days: [WellnessDay]
    var sleepDays: Int { days.compactMap(\.sleep).count }
    var energyDays: Int { days.compactMap(\.kcal).count }
    var meanSleep: Double? { WellnessEngine.mean(days.compactMap(\.sleep)) }
    var meanHRV: Double? { WellnessEngine.mean(days.compactMap(\.hrv)) }
    var meanFeeling: Double? { WellnessEngine.mean(days.compactMap(\.feeling)) }
    var trainingMinutes: Double? { let rows = days.compactMap(\.trainingMinutes); return rows.isEmpty ? nil : rows.reduce(0,+) }
    func sleepGap(target: Double) -> Double? { let rows = days.compactMap(\.sleep); return rows.isEmpty ? nil : rows.reduce(0) { $0 + max(0,WellnessEngine.target(target)-$1) } }
    func reachedSleep(target: Double) -> Int { days.compactMap(\.sleep).filter { $0 >= WellnessEngine.target(target) }.count }
}
struct SleepTiming: Identifiable {
    var date: Date
    var start: Date
    var end: Date
    var asleepHours: Double
    var id: Date { date }
}
struct TrainingFollowUp: Identifiable {
    var workout: PocketWorkout
    var nextNight: NightRecord?
    var baselineHRV: Double?
    var baselineDays: Int
    var feeling: WellnessCheckIn?
    var id: UUID { workout.id }
    var hrvDifference: Double? { WellnessEngine.validHRV(nextNight).flatMap { value in baselineHRV.map { value-$0 } } }
}
enum WellnessEngine {
    static func target(_ value: Double) -> Double { value.isFinite && (4...12).contains(value) ? value : 8 }
    static func mean(_ values: [Double]) -> Double? { let rows = values.filter(\.isFinite); return rows.isEmpty ? nil : rows.reduce(0,+)/Double(rows.count) }
    static func nights(_ rows: [NightRecord], now: Date, calendar: Calendar = .current) -> [NightRecord] {
        Dictionary(rows.filter { $0.date <= now }.map { (calendar.startOfDay(for:$0.date),$0) }, uniquingKeysWith: { a,b in a.hrvCount+a.heartRateCount > b.hrvCount+b.heartRateCount ? a:b }).values.sorted { $0.date < $1.date }
    }
    static func validSleep(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && (0...18).contains($0) ? $0 : nil } }
    static func validHRV(_ night: NightRecord?) -> Double? { night.flatMap { NightlyComparison.hrvValue($0) } }
    static func workouts(_ rows: [PocketWorkout], now: Date) -> [PocketWorkout] { Dictionary(rows.filter { $0.start < $0.end && $0.end <= now && $0.duration.isFinite && $0.duration >= 0 }.map { ($0.id,$0) }, uniquingKeysWith:{ _,b in b }).values.sorted { $0.start < $1.start } }
    static func week(nights input: [NightRecord], energy: [LoadBarRow], workouts inputWorkouts: [PocketWorkout], feelings: [WellnessCheckIn], ending: Date, now: Date, calendar: Calendar = .current) -> WellnessWeek {
        let endDay = calendar.startOfDay(for:ending)
        let nights = Dictionary(self.nights(input,now:now,calendar:calendar).map { (calendar.startOfDay(for:$0.date),$0) },uniquingKeysWith:{ _,b in b })
        let energy = Dictionary(energy.filter { $0.day <= now && $0.kcal.map { $0.isFinite && $0 >= 0 } == true }.map { (calendar.startOfDay(for:$0.day),$0.kcal!) },uniquingKeysWith:{ _,b in b })
        let workouts = self.workouts(inputWorkouts,now:now)
        let days = (0..<7).reversed().map { offset -> WellnessDay in
            let date = calendar.date(byAdding:.day,value:-offset,to:endDay)!,until = calendar.date(byAdding:.day,value:1,to:date)!
            let night = nights[date]
            let sessions = workouts.filter { $0.start < until && $0.end > date }
            // Union active workout time so overlapping imported sessions do not inflate minutes.
            let spans = RecoveryEngine.merged(sessions.map { SleepInterval(start:$0.start,end:$0.end) },from:date,to:min(until,now))
            let minutes = spans.isEmpty ? nil : spans.reduce(0) { $0+$1.end.timeIntervalSince($1.start)/60 }
            let ratings = feelings.filter { $0.date >= date && $0.date < until && $0.date <= now && (1...5).contains($0.energy) }.map { Double($0.energy) }
            return WellnessDay(date:date,sleep:validSleep(night?.sleepHours),hrv:validHRV(night),kcal:energy[date],trainingMinutes:minutes,feeling:mean(ratings))
        }
        return WellnessWeek(days:days)
    }
    static func timing(intervals: [SleepInterval], ending: Date, now: Date, count: Int = 7, calendar: Calendar = .current) -> [SleepTiming] {
        let last=calendar.startOfDay(for:ending),episodes=SleepEpisodeEngine.episodes(intervals,now:now)
        return (0..<max(0,count)).reversed().compactMap { offset in
            let date=calendar.date(byAdding:.day,value:-offset,to:last)!
            guard let main=SleepEpisodeEngine.main(episodes,day:date,calendar:calendar),main.hours >= 2 else{return nil}
            return SleepTiming(date:date,start:main.start,end:main.end,asleepHours:main.hours)
        }
    }

    static func clockHour(_ date: Date, calendar: Calendar = .current) -> Double {
        let components = calendar.dateComponents([.hour,.minute],from:date)
        let hour = Double(components.hour ?? 0)+Double(components.minute ?? 0)/60
        return hour >= 18 ? hour-24 : hour
    }
    static func timingVariation(_ rows: [SleepTiming], calendar: Calendar = .current) -> Double? {
        guard rows.count >= 3 else { return nil }
        let values = rows.map { clockHour($0.start,calendar:calendar) },average = mean(values)!
        return sqrt(values.reduce(0) { $0+pow($1-average,2) }/Double(values.count))*60
    }
    static func followUps(workouts: [PocketWorkout], nights input: [NightRecord], feelings: [WellnessCheckIn], now: Date, calendar: Calendar = .current) -> [TrainingFollowUp] {
        let nights = self.nights(input,now:now,calendar:calendar)
        return self.workouts(workouts,now:now).reversed().map { workout in
            let endDay = calendar.startOfDay(for:workout.end),nextDay = calendar.date(byAdding:.day,value:1,to:endDay)!
            let timed = nights.filter { row in
                guard let start=row.sleepStartedAt,let end=row.sleepEndedAt,validSleep(row.sleepHours) != nil else{return false}
                return start >= workout.end && start <= workout.end.addingTimeInterval(48*3600) && end > start && end <= now
            }.sorted { $0.sleepStartedAt! < $1.sleepStartedAt! }.first
            let following = timed ?? nights.first { $0.sleepStartedAt == nil && $0.sleepEndedAt == nil && calendar.isDate($0.date,inSameDayAs:nextDay) && validSleep($0.sleepHours) != nil }
            let comparable = following.map { NightlyComparison.history(for:$0,in:nights,channel:.hrv,days:28,before:endDay,calendar:calendar) } ?? []
            let baseline = comparable.compactMap { validHRV($0) }
            let feeling = feelings.filter { $0.date >= workout.end && $0.date <= min(now,workout.end.addingTimeInterval(6*3600)) && (1...5).contains($0.energy) }.min { $0.date < $1.date }
            return TrainingFollowUp(workout:workout,nextNight:following,baselineHRV:baseline.count >= 3 ? RecoveryEngine.median(baseline) : nil,baselineDays:baseline.count,feeling:feeling)
        }
    }
}


struct FrozenModelComparison: Codable, Equatable {
    var schemaVersion=1
    var baseline:RecordedPrediction
    var candidate:RecordedPrediction
    var inputDigest:String
    var readAt:Date
    var changedBins:Int
    var coveredMinutes:Double
    var group:String { baseline.modelRevision+" → "+candidate.modelRevision }
    static func capture(_ replay:ShadowReplay?,expected:PocketStatus,at now:Date)->Self? {
        guard let replay,let baseline=RecordedPrediction.capture(expected,at:now),
              let matched=RecordedPrediction.capture(replay.baseline,at:now),baseline==matched,
              baseline.kind=="身体电量",let candidate=RecordedPrediction.capture(replay.candidate,at:now),
              candidate.kind=="身体电量",candidate.observedAt==baseline.observedAt else{return nil}
        let value=Self(baseline:baseline,candidate:candidate,inputDigest:replay.inputDigest,readAt:replay.readAt,
                       changedBins:replay.decisions.count,coveredMinutes:replay.coveredMinutes)
        return value.validPrediction(at:now) ? value:nil
    }
    func validPrediction(at now:Date)->Bool {
        schemaVersion==1 && inputDigest.count==64 && inputDigest.allSatisfy{$0.isHexDigit} &&
        changedBins>0 && changedBins<=10000 && coveredMinutes.isFinite && coveredMinutes>0 && coveredMinutes<=14400 &&
        readAt<=baseline.capturedAt && readAt<=now && baseline.observedAt<=readAt &&
        baseline.kind=="身体电量" && candidate.kind==baseline.kind &&
        candidate.modelRevision==ActivityFusionPolicy.cardioEnergyV1.revision && baseline.modelRevision != candidate.modelRevision &&
        baseline.capturedAt==candidate.capturedAt && baseline.observedAt==candidate.observedAt && baseline.validUntil==candidate.validUntil &&
        baseline.usable(for:baseline.capturedAt,now:now) && candidate.usable(for:candidate.capturedAt,now:now)
    }
    func usable(for event:PocketEvent,now:Date)->Bool {
        guard validPrediction(at:now),event.prediction==baseline,event.modifiedAt==nil,
              let recordedAt=event.recordedAt,recordedAt>=baseline.capturedAt,recordedAt<=now,event.date<=recordedAt,
              recordedAt.timeIntervalSince(baseline.capturedAt)<=300,
              (1...5).contains(event.energy) else{return false}
        return baseline.usable(for:event.date,now:now) && candidate.usable(for:event.date,now:now)
    }
}
