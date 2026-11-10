import Foundation

func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    guard condition() else { fatalError("FAIL: \(name)") }
    print("PASS: \(name)")
}
let origin = Date(timeIntervalSince1970: 1_700_000_000)
let merged = RecoveryEngine.merged([
    SleepInterval(start: origin.addingTimeInterval(-20), end: origin.addingTimeInterval(50)),
    SleepInterval(start: origin.addingTimeInterval(20), end: origin.addingTimeInterval(80)),
    SleepInterval(start: origin.addingTimeInterval(100), end: origin.addingTimeInterval(150))
], from: origin, to: origin.addingTimeInterval(120))
check(merged.count == 2, "overlapping sources merged")
check(merged.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } == 100, "window clipping prevents duplicate sleep")
check(RecoveryEngine.median([1, 2, 100, 3]) == 2.5, "robust median")
check(RecoveryEngine.median([]) == nil, "missing is not zero")
check(RecoveryEngine.robustZ(10, against: [10, 10, 10], floor: 3) == 0, "constant baseline is finite")
let date = Calendar.current.startOfDay(for: Date())
let history = (1...20).map { day in NightRecord(date: Calendar.current.date(byAdding: .day, value: -day, to: date)!, sleepHours: 8, hrv: 50, heartRate: 55, hrvCount: 3, heartRateCount: 20) }
let today = NightRecord(date: date, sleepHours: 8, hrv: 50, heartRate: 55, hrvCount: 3, heartRateCount: 20)
let normal = RecoveryEngine.score(today: today, history: history, sleepTarget: 8)
check(normal.score != nil && normal.baselineNights == 20, "historical baseline enables scoring")
check(RecoveryEngine.score(today: today, history: Array(history.prefix(13)), sleepTarget: 8).score == nil, "short baseline refuses score")
check(RecoveryEngine.score(today: today, history: [today], sleepTarget: 8).baselineNights == 0, "today excluded from baseline")
var missing = today; missing.hrv = nil
check(RecoveryEngine.score(today: missing, history: history, sleepTarget: 8).score == nil, "missing HRV refuses score")
var low = today; low.sleepHours = 4; low.hrv = 20; low.heartRate = 75
check(RecoveryEngine.score(today: low, history: history, sleepTarget: 8).score! < normal.score!, "poor sleep and deviations lower estimate")
var high = today; high.sleepHours = 12; high.hrv = 10000; high.heartRate = 20
check((0...100).contains(RecoveryEngine.score(today: high, history: history, sleepTarget: 8).score!), "score bounded under extremes")
check(RecoveryEngine.score(today: today, history: history, sleepTarget: .nan).score != nil, "invalid preference handled")
print("12 core checks passed. Synthetic fixtures only; not physiological validation.")
let baseDays = history.reversed().map { RecoveryDay(night: $0, activeKcal: 450, sleepMidpointHour: nil) }
let normalDay = RecoveryDay(night: today, activeKcal: 450, sleepMidpointHour: nil)
let v2normal = RecoveryModelV2.calculate(days: baseDays + [normalDay]).last!
let future = RecoveryDay(night: NightRecord(date: date.addingTimeInterval(86400), sleepHours: 4, hrv: 20, heartRate: 80, hrvCount: 6, heartRateCount: 48), activeKcal: 1200, sleepMidpointHour: nil)
let withFuture = RecoveryModelV2.calculate(days: baseDays + [normalDay, future])
check(withFuture[withFuture.count - 2].score == v2normal.score, "V2 future observations cannot change earlier score")
check(RecoveryModelV2.calculate(days: baseDays + [RecoveryDay(night: missing, activeKcal: nil, sleepMidpointHour: nil)]).last!.reliability.contains("初步估计"), "V2 missing HRV uses observed sleep with a preliminary label")
var dense = today; dense.hrvCount = 20; dense.heartRateCount = 100
var sparse = today; sparse.hrvCount = 2; sparse.heartRateCount = 6
let denseResult = RecoveryModelV2.calculate(days: baseDays + [RecoveryDay(night: dense, activeKcal: nil, sleepMidpointHour: nil)]).last!
let sparseResult = RecoveryModelV2.calculate(days: baseDays + [RecoveryDay(night: sparse, activeKcal: nil, sleepMidpointHour: nil)]).last!
check(sparseResult.upper! - sparseResult.lower! > denseResult.upper! - denseResult.lower!, "V2 sparse observations increase uncertainty")
let onePoor = RecoveryModelV2.calculate(days: baseDays + [RecoveryDay(night: low, activeKcal: 800, sleepMidpointHour: nil)]).last!
let poorWeek = (0..<7).map { i -> RecoveryDay in var n = low; n.date = date.addingTimeInterval(Double(i) * 86400); return RecoveryDay(night: n, activeKcal: 800, sleepMidpointHour: nil) }
let sustained = RecoveryModelV2.calculate(days: baseDays + poorWeek).last!
check(sustained.score! < onePoor.score!, "V2 sustained burden differs from a single poor night")
check(v2normal.lower! <= v2normal.score! && v2normal.score! <= v2normal.upper!, "V2 estimate lies inside bounded range")
var invalid = today; invalid.hrv = .nan
check(RecoveryModelV2.calculate(days: baseDays + [RecoveryDay(night: invalid, activeKcal: .infinity, sleepMidpointHour: nil)], sleepTarget: .nan).last!.reliability.contains("初步估计"), "V2 nonfinite HRV is excluded while observed sleep remains usable")
let dedup = RecoveryModelV2.calculate(days: baseDays + [normalDay, normalDay])
check(dedup.count == baseDays.count + 1, "V2 duplicate local nights collapse")
print("7 V2 invariants passed. No physiological accuracy claim.")
let clock = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
let hStart = clock.addingTimeInterval(-3600)
let sleepHour = BatteryHour(start: hStart, end: clock, sleepHours: 1, activeKcal: 0, heartRate: 54, heartRateCount: 8, heartRateCoverageHours: 1)
let activityHour = BatteryHour(start: hStart, end: clock, sleepHours: 0, activeKcal: 210, heartRate: 110, heartRateCount: 8, heartRateCoverageHours: 1)
let unknownHour = BatteryHour(start: hStart, end: clock, sleepHours: 0, activeKcal: nil, heartRate: nil, heartRateCount: 0)
let charged = BatteryModel.calculate(hours: [sleepHour], anchor: 50, baselineHR: 54, now: clock)
let drained = BatteryModel.calculate(hours: [activityHour], anchor: 50, baselineHR: 54, now: clock)
check(charged.value! > 50 && charged.charged > 0, "battery recorded sleep charges")
check(drained.value! < 50 && drained.drained > 0, "battery recorded activity drains")
let unknown = BatteryModel.calculate(hours: [unknownHour], anchor: 50, baselineHR: 54, now: clock)
check(unknown.value == nil && unknown.points.first!.value == nil, "battery unknown time is not quiet recovery")
check(BatteryModel.calculate(hours: [sleepHour], anchor: nil, baselineHR: 54, now: clock).value == nil, "battery refuses unanchored score")
check(!charged.isFresh(at: clock.addingTimeInterval(7201)), "battery stale score expires after two hours")
check(!charged.isFresh(at: Calendar.current.startOfDay(for: clock).addingTimeInterval(86400)), "battery yesterday cannot display as current")
check(BatteryModel.calculate(hours: [sleepHour, sleepHour], anchor: 50, baselineHR: 54, now: clock).value == charged.value, "battery overlapping bins cannot double charge")
let futureHour = BatteryHour(start: clock, end: clock.addingTimeInterval(3600), sleepHours: 1, activeKcal: 0, heartRate: 54, heartRateCount: 8, heartRateCoverageHours: 1)
check(BatteryModel.calculate(hours: [sleepHour, futureHour], anchor: 50, baselineHR: 54, now: clock).value == charged.value, "battery future bins ignored")
check(BatteryDemo.status(now: clock).demo, "battery synthetic fixtures explicitly labelled")
print("9 battery invariants passed. 28 checks total; no physiological validation.")
let restHour = BatteryHour(start: hStart, end: clock, sleepHours: 0, activeKcal: 0, heartRate: 58, heartRateCount: 8, heartRateCoverageHours: 1)
check(BatteryModel.calculate(hours: [restHour], anchor: 50, baselineHR: 54, now: clock).value! > 50, "battery measured low activity may recharge")
let lowCoverageRest = BatteryHour(start: hStart, end: clock, sleepHours: 0, activeKcal: 0, heartRate: 58, heartRateCount: 2)
check(BatteryModel.calculate(hours: [lowCoverageRest], anchor: 50, baselineHR: 54, now: clock).value! <= 50, "battery sparse HR cannot imply awake recovery")
check(BatteryModel.calculate(hours: [sleepHour], anchor: 50, baselineHR: 54, nightHRVZ: .nan, now: clock).value != nil, "battery nonfinite quality handled")
print("31 checks total.")

check(HeartRateCoverage.hours(dates: [hStart, hStart.addingTimeInterval(1800)], start: hStart, end: clock) == 0, "coverage long gaps excluded")
check(HeartRateCoverage.hours(dates: [hStart, hStart, hStart.addingTimeInterval(60)], start: hStart, end: clock) == 1.0 / 60, "coverage duplicate timestamps do not inflate")
var ledger = BatteryLedger(baselineHR: 54, hours: [])
ledger.merge([sleepHour]); let firstLedger = ledger.status(now: clock)
ledger.merge([sleepHour]); check(ledger.status(now: clock).value == firstLedger.value, "ledger repeat refresh does not double charge")
let ledgerData = try! JSONEncoder().encode(ledger)
let restoredLedger = try! JSONDecoder().decode(BatteryLedger.self, from: ledgerData)
check(restoredLedger.status(now: clock).value == firstLedger.value, "ledger restart preserves state")
check(OpenRecoveryReference.score(hrv: 55, baselineHRV: 55, restingHR: 58, baselineRestingHR: 58, sleepMinutes: 480, needMinutes: 480) == 59, "licensed reference matched baseline fixture")
check(OpenRecoveryReference.score(hrv: .nan, baselineHRV: 55, restingHR: 58, baselineRestingHR: 58, sleepMinutes: 480, needMinutes: 480) == nil, "reference invalid HRV refuses comparison")
print("37 checks total; no physiological validation.")

var corruptStatus = charged; corruptStatus.value = 101
check(corruptStatus.displayValue(at: clock) == nil, "out-of-range summary never displayed")
corruptStatus.value = -1
check(corruptStatus.displayValue(at: clock) == nil, "negative summary never displayed")
var futureStatus = charged; futureStatus.measuredAt = clock.addingTimeInterval(61)
check(futureStatus.displayValue(at: clock) == nil, "future timestamp cannot masquerade as fresh")
print("40 checks total; synthetic invariants, not physiological validation.")

let identifiedLedger = BatteryLedger(baselineHR: 54, hours: [sleepHour], sourceKey: "device-a")
check(identifiedLedger.matches(source: "device-a"), "ledger accepts its original source")
check(!identifiedLedger.matches(source: "device-b"), "replacement device cannot silently reuse old baseline")
check(!restoredLedger.matches(source: "device-a"), "legacy ledger requires source confirmation")
check(try! JSONDecoder().decode(BatteryLedger.self, from: JSONEncoder().encode(identifiedLedger)).sourceKey == "device-a", "ledger source identity survives restart")
print("44 checks total; synthetic invariants, not physiological validation.")

let retired = Array(repeating: clock.addingTimeInterval(-172800), count: 1000) + [clock.addingTimeInterval(-3600)]
let replacement = [clock.addingTimeInterval(-120), clock.addingTimeInterval(-60)]
check(HealthSourcePolicy.preferredKey(["old": retired, "new": replacement]) == "new", "recent stream coverage beats retired historical volume")
check(HealthSourcePolicy.preferredKey(["b": replacement, "a": replacement]) == "a", "source ties resolve deterministically")
check(HealthSourcePolicy.preferredKey(["empty": []]) == nil, "empty stream cannot be selected")
check(HealthSourcePolicy.preferredKey(["only": replacement]) == "only", "single source remains stable")
print("48 checks total; synthetic invariants, not physiological validation.")

// Wire compatibility: a phone update must not break an older saved Watch summary.
let legacyStatusData = try! JSONEncoder().encode(charged)
var legacyStatusJSON = try! JSONSerialization.jsonObject(with: legacyStatusData) as! [String: Any]
legacyStatusJSON.removeValue(forKey: "recoverySummary")
let legacyStatus = try! JSONDecoder().decode(PocketStatus.self, from: JSONSerialization.data(withJSONObject: legacyStatusJSON))
check(legacyStatus.value == charged.value && legacyStatus.recoverySummary == nil, "legacy Watch payload remains readable without nightly summary")
var wearableStatus = charged
wearableStatus.recoverySummary = WearableSummary(date: clock, recovery: 81, sleepHours: 7.7, hrv: 52, heartRate: 55, baselineNights: 42)
let wearableRoundtrip = try! JSONDecoder().decode(PocketStatus.self, from: JSONEncoder().encode(wearableStatus))
check(wearableRoundtrip.recoverySummary?.recovery == 81 && wearableRoundtrip.recoverySummary?.date == clock, "Watch nightly summary survives payload serialization with its date")
print("50 checks total; synthetic invariants, not physiological validation.")

let window = DrainWindow(start: origin, end: origin.addingTimeInterval(3600), drop: 12)
let w1 = PocketWorkout(id: UUID(), title: "A", start: origin, end: origin.addingTimeInterval(1800), duration: 1800, activeKcal: 200, source: "test")
var w2 = w1; w2.id = UUID(); w2.title = "B"
let oneImpact = WorkoutAnalysis.impacts(workouts: [w1], windows: [window])
check(abs(oneImpact[0].drop - 6) < 0.001, "half-hour workout receives half an hourly decline")
let overlapping = WorkoutAnalysis.impacts(workouts: [w1, w2, w1], windows: [window])
check(overlapping.count == 2 && abs(overlapping.reduce(0) { $0 + $1.drop } - 6) < 0.001, "overlapping and duplicate workouts cannot multiply decline")
check(WorkoutAnalysis.impacts(workouts: [w1], windows: []).first?.coveredSeconds == 0, "missing observations never invent workout impact")
var testCalendar = Calendar(identifier: .gregorian); testCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
let analysisPoints = [BatteryPoint(date: origin, value: 70, mode: ""), BatteryPoint(date: origin.addingTimeInterval(3600), value: 58, mode: "")]
let validWindows = WorkoutAnalysis.windows(points: analysisPoints, day: origin, now: origin.addingTimeInterval(3600), calendar: testCalendar)
check(validWindows.count == 1 && validWindows[0].drop == 12, "observed hourly decline is preserved")
var gapPoints = analysisPoints; gapPoints[1].date = origin.addingTimeInterval(7200)
check(WorkoutAnalysis.windows(points: gapPoints, day: origin, now: origin.addingTimeInterval(7200), calendar: testCalendar).isEmpty, "long observation gaps are not attributed to training")
var nilPoints = analysisPoints; nilPoints[0].value = nil
check(WorkoutAnalysis.windows(points: nilPoints, day: origin, now: origin.addingTimeInterval(3600), calendar: testCalendar).isEmpty, "missing anchor makes a segment unavailable")
var risePoints = analysisPoints; risePoints[1].value = 80
check(WorkoutAnalysis.windows(points: risePoints, day: origin, now: origin.addingTimeInterval(3600), calendar: testCalendar).first?.drop == 0, "recovery segments do not become drain")
print("57 checks total; synthetic invariants, not physiological validation.")

let sleepOnlyBattery = BatteryModel.calculate(hours: [sleepHour], anchor: 50, baselineHR: nil, now: clock)
check(sleepOnlyBattery.value != nil && sleepOnlyBattery.value! > 50, "sleep can charge without a personal HR baseline")
let noBaselineRest = BatteryModel.calculate(hours: [restHour], anchor: 50, baselineHR: nil, now: clock)
check(noBaselineRest.value != nil && noBaselineRest.value! <= 50, "missing HR baseline never invents awake recovery")
let partialNight = NightRecord(date: date, sleepHours: 7, hrv: nil, heartRate: nil, hrvCount: 0, heartRateCount: 0)
let preliminary = RecoveryModelV2.calculate(days: [RecoveryDay(night: partialNight, activeKcal: nil, sleepMidpointHour: nil)]).last!
check(preliminary.score == nil && preliminary.sleepCompletion != nil && preliminary.reliability.contains("初步估计"), "one recorded night preserves sleep without an invented recovery score")
let emptyNight = NightRecord(date: date, sleepHours: nil, hrv: nil, heartRate: nil, hrvCount: 0, heartRateCount: 0)
check(RecoveryModelV2.calculate(days: [RecoveryDay(night: emptyNight, activeKcal: nil, sleepMidpointHour: nil)]).last?.score == nil, "no records still cannot produce recovery")
let optionalLedger = BatteryLedger(baselineHR: nil, hours: [sleepHour])
check((try! JSONDecoder().decode(BatteryLedger.self, from: JSONEncoder().encode(optionalLedger))).status(now: clock).value != nil, "baseline-free ledger survives restart")
print("62 checks total; synthetic invariants, not physiological validation.")

var poorSleep = sleepHour; poorSleep.sleepHRVZ = -3
var goodSleep = sleepHour; goodSleep.sleepHRVZ = 1
check(BatteryModel.calculate(hours: [poorSleep], anchor: 50, baselineHR: 54, now: clock).points.last!.value! < BatteryModel.calculate(hours: [goodSleep], anchor: 50, baselineHR: 54, now: clock).points.last!.value!, "observed relative sleep HRV changes recharge")
var elevatedSleep = sleepHour; elevatedSleep.heartRate = 80
check(BatteryModel.calculate(hours: [elevatedSleep], anchor: 50, baselineHR: 54, now: clock).value! < charged.value!, "elevated sleep HR reduces replenishment")
var training = restHour; training.workoutHours = 0.5; training.heartRate = 105; training.activeKcal = 20
var trainingLowHR = training; trainingLowHR.heartRate = 58
check(BatteryModel.calculate(hours: [training], anchor: 50, baselineHR: 54, now: clock).value == BatteryModel.calculate(hours: [trainingLowHR], anchor: 50, baselineHR: 54, now: clock).value, "workout HR is not a duplicate strain penalty")
var walkingRest = restHour; walkingRest.steps = 800
check(BatteryModel.calculate(hours: [walkingRest], anchor: 50, baselineHR: 54, now: clock).value! < 50, "recorded walking never becomes quiet replenishment")
check(SleepHRVComparison.deviation(current: 50, prior: [50, 50]) == nil, "insufficient comparison remains missing without blocking battery")
check(SleepHRVComparison.deviation(current: 50, prior: [50, 50, 50]) == 0, "stable individual HRV gives neutral comparison")
check(SleepHRVComparison.deviation(current: .nan, prior: [50, 50, 50]) == nil, "invalid HRV cannot alter quality")
check(SleepHRVComparison.deviation(current: 10, prior: [50, 50, 50]) == -3, "extreme HRV deviation bounded")
let midnight = testCalendar.startOfDay(for: origin)
let crossing = [BatteryPoint(date: midnight.addingTimeInterval(-1800), value: 50, mode: ""), BatteryPoint(date: midnight.addingTimeInterval(1800), value: 60, mode: "")]
let dayStats = DailyBatteryStatistics.calculate(points: crossing, day: midnight, now: midnight.addingTimeInterval(7200), calendar: testCalendar)
check(dayStats.charged == 5 && dayStats.coveredSeconds == 1800, "calendar clips cross-midnight charge to selected day")
check(DailyBatteryStatistics.calculate(points: gapPoints, day: origin, now: origin.addingTimeInterval(7200), calendar: testCalendar).coveredSeconds == 0, "calendar never fills long gaps")
check(DailyBatteryStatistics.calculate(points: crossing, day: midnight.addingTimeInterval(86400), now: midnight.addingTimeInterval(7200), calendar: testCalendar).latest == nil, "future calendar never displays past values")
print("73 checks total; synthetic invariants, not physiological validation.")
var evolvingRest = restHour; evolvingRest.personalHR = 54
check(BatteryModel.calculate(hours: [evolvingRest], anchor: 50, baselineHR: nil, now: clock).value! > 50, "later causal personal baseline works even when initial ledger lacked one")
var mixedSleep = elevatedSleep; mixedSleep.sleepHours = 0.5; mixedSleep.sleepHeartRate = 54
var mixedLowerAwakeHR = mixedSleep; mixedLowerAwakeHR.heartRate = 54
// With zero HR coverage no awake strain can be inferred; compare sleep charging only.
mixedSleep.heartRateCoverageHours = 0; mixedLowerAwakeHR.heartRateCoverageHours = 0
check(BatteryModel.calculate(hours: [mixedSleep], anchor: 50, baselineHR: 54, now: clock).points.last!.value == BatteryModel.calculate(hours: [mixedLowerAwakeHR], anchor: 50, baselineHR: 54, now: clock).points.last!.value, "awake HR cannot reduce recorded sleep quality in a mixed hour")
print("75 checks total; synthetic invariants, not physiological validation.")

let hrvDay = testCalendar.startOfDay(for:clock)
let hrvNow = hrvDay.addingTimeInterval(12*3600)
func hrvRow(_ day:Int, _ hour:Int = 8, value:Double = 50, context:String = "安静候选", source:String = "a") -> HRVObservation {
    let start = hrvDay.addingTimeInterval(Double(day)*86400 + Double(hour)*3600)
    return HRVObservation(id:UUID(),start:start,end:start.addingTimeInterval(60),sdnn:value,context:context,source:source)
}
let priorQuiet = [-1,-2,-3].map { hrvRow($0) }
let currentQuiet = hrvRow(0,value:25)
let compared = DayHRVModel.compare(priorQuiet + [currentQuiet],now:hrvNow,calendar:testCalendar)
check(compared.last!.deviation! < 0 && compared.last!.baselineDays == 3, "daytime HRV compares against three earlier distinct days")
check(DayHRVModel.compare([hrvRow(-1),hrvRow(-1),hrvRow(-1),currentQuiet],now:hrvNow,calendar:testCalendar).last!.deviation == nil, "many readings on one day cannot masquerade as three baseline days")
check(DayHRVModel.compare(priorQuiet + [hrvRow(0,context:"呼吸练习")],now:hrvNow,calendar:testCalendar).last!.deviation == nil, "breathwork SDNN never receives ordinary daytime comparison")
check(DayHRVModel.compare(priorQuiet + [hrvRow(0,source:"b")],now:hrvNow,calendar:testCalendar).last!.deviation == nil, "different HRV source cannot reuse baseline")
check(DayHRVModel.compare(priorQuiet + [hrvRow(0,2)],now:hrvNow,calendar:testCalendar).last!.deviation == nil, "different time block cannot reuse daytime baseline")
check(DayHRVModel.compare(priorQuiet + [currentQuiet,hrvRow(1)],now:hrvNow,calendar:testCalendar).count == 4, "future HRV excluded")
let eligibleRow = compared.last!
check(abs(DayHRVModel.observedHours([eligibleRow,eligibleRow],start:hrvDay,end:hrvNow) - 1.0/60) < 0.00001, "duplicate HRV intervals cannot inflate observed minutes")
var longHRV = eligibleRow; longHRV.end = longHRV.start.addingTimeInterval(3600)
check(DayHRVModel.observedHours([longHRV],start:hrvDay,end:hrvNow) == 0, "unsupported HRV duration does not establish short-record coverage")
check(DayHRVModel.summary(compared,now:hrvDay.addingTimeInterval(86400),calendar:testCalendar) == nil, "yesterday HRV not presented as today's summary")
var baselineDaytime = restHour; baselineDaytime.heartRateCount = 2; baselineDaytime.heartRateCoverageHours = 0
var sparseDaytime = baselineDaytime; sparseDaytime.awakeHRVZ = -3; sparseDaytime.awakeHRVObservedHours = 1.0/60
let aDay = BatteryModel.calculate(hours:[baselineDaytime],anchor:50,baselineHR:54,now:clock).points.last!.value!
let bDay = BatteryModel.calculate(hours:[sparseDaytime],anchor:50,baselineHR:54,now:clock).points.last!.value!
check(abs((aDay-bDay)-(1.1+3*0.7)/60) < 0.00001, "one-minute low HRV never penalizes a full hour")
var noDurationHRV = sparseDaytime; noDurationHRV.awakeHRVObservedHours = 0
check(BatteryModel.calculate(hours:[noDurationHRV],anchor:50,baselineHR:54,now:clock).points.last!.value! == aDay, "zero duration HRV cannot add drain")
var lowHRVRest = restHour; lowHRVRest.awakeHRVZ = -2; lowHRVRest.awakeHRVObservedHours = 1.0/60
let quietReserve = BatteryModel.calculate(hours:[restHour],anchor:50,baselineHR:54,now:clock).points.last!.value!
let shortHRVReserve = BatteryModel.calculate(hours:[lowHRVRest],anchor:50,baselineHR:54,now:clock).points.last!.value!
check(quietReserve > shortHRVReserve && quietReserve-shortHRVReserve < 0.1, "one minute low HRV reduces only one minute of eligible rest, not a full hour")
let oldSnapshot = try! JSONDecoder().decode(PocketStatus.self,from:legacyStatusData)
check(oldSnapshot.dayHRV == nil, "older phone and Watch summaries remain readable")
print("88 checks total; synthetic invariants, not physiological validation.")

let depletedStart = clock.addingTimeInterval(-8*3600)
let wholeSleep = BatteryHour(start:depletedStart,end:clock,sleepHours:8,activeKcal:0,heartRate:nil,heartRateCount:0)
let fullRecovery = BatteryModel.calculate(hours:[wholeSleep],anchor:5,baselineHR:nil,now:clock)
let splitSleep = (0..<8).map { i in BatteryHour(start:depletedStart.addingTimeInterval(Double(i)*3600),end:depletedStart.addingTimeInterval(Double(i+1)*3600),sleepHours:1,activeKcal:0,heartRate:nil,heartRateCount:0) }
check(fullRecovery.value! > 70 && fullRecovery.value! < 100, "eight hours observed sleep no longer mechanically caps depleted reserve near 53")
check(fullRecovery.value == BatteryModel.calculate(hours:splitSleep,anchor:5,baselineHR:nil,now:clock).value, "bounded pure sleep recovery invariant to bin subdivision")
var impairedNight = wholeSleep; impairedNight.sleepHRVZ = -3
check(BatteryModel.calculate(hours:[impairedNight],anchor:5,baselineHR:nil,now:clock).value! < fullRecovery.value!, "low relative HRV slows new sleep recovery curve")
let nearFull = BatteryModel.calculate(hours:[sleepHour],anchor:95,baselineHR:nil,now:clock).points.last!.value! - 95
let lowFill = BatteryModel.calculate(hours:[sleepHour],anchor:5,baselineHR:nil,now:clock).points.last!.value! - 5
check(lowFill > nearFull, "sleep recovery slows near full reserves")
check(fullRecovery.inputs?.sleepHRVHours == 0, "missing sleep HRV explicitly reports no comparable coverage")
let inputFixture = BatteryModel.calculate(hours:[sparseDaytime],anchor:50,baselineHR:54,now:clock)
check(abs((inputFixture.inputs?.awakeHRVMinutes ?? 0)-1) < 0.00001, "diagnostic exposes real HRV minutes rather than a full hour")
print("94 checks total; engineering invariants, not physiological validation.")

// Audit regressions: independent signal baselines and explicit hourly effects.
let independentHistory = history.map { row -> RecoveryDay in
    var n = row; n.heartRate = nil; n.heartRateCount = 0; n.hrvCount = 1
    return RecoveryDay(night:n,activeKcal:nil,sleepMidpointHour:nil)
}
var independentNight = today; independentNight.heartRate = nil; independentNight.heartRateCount = 0; independentNight.hrvCount = 1
let independentGood = RecoveryModelV2.calculate(days:independentHistory+[RecoveryDay(night:independentNight,activeKcal:nil,sleepMidpointHour:nil)]).last!
independentNight.hrv = 20
let independentLow = RecoveryModelV2.calculate(days:independentHistory+[RecoveryDay(night:independentNight,activeKcal:nil,sleepMidpointHour:nil)]).last!
check(independentLow.measurementUsed && independentLow.reasons.contains { $0.name == "自主神经信号" }, "missing HR channel cannot silence an available SDNN baseline")
check(independentLow.score! < independentGood.score!, "lower SDNN affects recovery even when all HR samples are missing")
check(independentLow.reliability.contains("初步估计"), "single-sample nights retain a preliminary label")
let hrOnlyHistory = history.map { row -> RecoveryDay in var n = row; n.hrv = nil; n.hrvCount = 0; return RecoveryDay(night:n,activeKcal:nil,sleepMidpointHour:nil) }
var hrOnlyNight = today; hrOnlyNight.hrv = nil; hrOnlyNight.hrvCount = 0; hrOnlyNight.heartRate = 75
let hrOnly = RecoveryModelV2.calculate(days:hrOnlyHistory+[RecoveryDay(night:hrOnlyNight,activeKcal:nil,sleepMidpointHour:nil)]).last!
check(hrOnly.measurementUsed && hrOnly.reasons.contains { $0.name == "睡眠心率" }, "missing SDNN channel cannot silence a valid HR baseline")
var zeroWindow = lowHRVRest; zeroWindow.awakeHRVObservedHours = 0
check(BatteryModel.calculate(hours:[zeroWindow],anchor:50,baselineHR:54,now:clock).points.last!.value == quietReserve, "zero-duration HRV cannot cancel any rest credit")
var allLowHRV = lowHRVRest; allLowHRV.awakeHRVObservedHours = 1
check(BatteryModel.calculate(hours:[allLowHRV],anchor:50,baselineHR:54,now:clock).value! < 50, "a fully observed low HRV interval still excludes rest credit")
let explained = BatteryModel.calculate(hours:[lowHRVRest],anchor:50,baselineHR:54,now:clock).points.last!.effect!
let explainedNext = 50 + explained.sleepRecharge + explained.restRecharge - explained.awakeDrain - explained.activityDrain - explained.heartRateDrain - explained.hrvDrain
check(abs(explainedNext-shortHRVReserve) < 0.00001, "hourly effect components reconcile to reserve before clipping")
var shortDuration = currentQuiet; shortDuration.end = shortDuration.start.addingTimeInterval(10)
check(DayHRVModel.compare(priorQuiet+[shortDuration],now:hrvNow,calendar:testCalendar).last!.deviation == nil, "ten-second SDNN never borrows a one-minute comparison baseline")
var twoMinute = currentQuiet; twoMinute.end = twoMinute.start.addingTimeInterval(120)
check(DayHRVModel.compare(priorQuiet+[twoMinute],now:hrvNow,calendar:testCalendar).last!.deviation == nil, "different SDNN recording durations require matched historical durations")
var manySleepHRV = poorSleep; manySleepHRV.sleepHRVCount = 4
var loneSleepHRV = poorSleep; loneSleepHRV.sleepHRVCount = 1
check(BatteryModel.calculate(hours:[manySleepHRV],anchor:50,baselineHR:54,now:clock).points.last!.value! < BatteryModel.calculate(hours:[loneSleepHRV],anchor:50,baselineHR:54,now:clock).points.last!.value!, "a lone low sleep SDNN record has less influence than several observations")
var outlyingHigh = goodSleep; outlyingHigh.sleepHRVZ = 3; outlyingHigh.sleepHRVCount = 4
check(BatteryModel.calculate(hours:[outlyingHigh],anchor:50,baselineHR:54,now:clock).points.last!.value == charged.points.last!.value, "unusually high relative SDNN is not an automatic recovery bonus")
print("105 checks total; synthetic regressions, not physiological validation.")

// Real-device sparse coverage regressions.
let calorieOnly = BatteryHour(start:hStart,end:clock,sleepHours:0,activeKcal:35,heartRate:nil,heartRateCount:0)
let calorieEstimate = BatteryModel.calculate(hours:[calorieOnly],anchor:50,baselineHR:nil,now:clock)
check(abs(calorieEstimate.points.last!.value! - 49) < 0.00001,"hourly calories add activity cost without inventing one hour of wakefulness")
check(calorieEstimate.inputs?.unobservedHours == clock.timeIntervalSince(Calendar.current.startOfDay(for:clock))/3600,"calorie-only bins retain missing coverage including earlier hours")
var zeroEnergy = calorieOnly; zeroEnergy.activeKcal = 0
check(BatteryModel.calculate(hours:[zeroEnergy],anchor:50,baselineHR:nil,now:clock).value == nil,"zero energy without HR or sleep cannot establish an observed reserve")
check(calorieEstimate.dataNote(at:clock)?.contains("未读到睡眠") == true,"missing sleep is communicated as a reading gap rather than failed recovery")
check(fullRecovery.inputs?.latestSleepEnd == clock,"latest recorded sleep coverage is carried into calculation evidence")
print("110 checks total; synthetic regressions, not physiological validation.")

// Load / strain numerics (Shared/StrainEngine). Synthetic fixtures only.
check(StrainEngine.strain(kcal: nil, workoutMinutes: 0) == nil, "missing active energy yields no strain instead of zero")
check(StrainEngine.strain(kcal: -5, workoutMinutes: 0) == nil, "negative energy is rejected")
let restStrain = StrainEngine.strain(kcal: 60, workoutMinutes: 0)!
let hardStrain = StrainEngine.strain(kcal: 900, workoutMinutes: 70)!
check(restStrain < hardStrain, "more recorded energy raises strain")
check((0...StrainEngine.ceiling).contains(hardStrain), "strain stays within the 0-21 ceiling")
check(abs(StrainEngine.strain(kcal: 900, workoutMinutes: 40)! - StrainEngine.strain(kcal: 900, workoutMinutes: 40)!) < 1e-12, "strain is deterministic for the same input")
check(StrainEngine.zone(restStrain) == "轻", "low strain reads as light")
check(StrainEngine.zone(StrainEngine.ceiling) == "极限", "ceiling strain reads as maximal")

// ACWR: acute/chronic over recorded days only; missing days are never zero.
let loadCalendar = Calendar(identifier: .gregorian)
let loadNow = loadCalendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
func loadRow(_ offset: Int, _ kcal: Double?) -> LoadBarRow {
    LoadBarRow(day: loadCalendar.date(byAdding: .day, value: -offset, to: loadNow)!, kcal: kcal)
}
let steadyLoad = (0..<28).map { loadRow($0, 400) }
let steadyRatio = StrainEngine.acwr(daily: steadyLoad, now: loadNow, calendar: loadCalendar)
check(steadyRatio.ratio != nil && abs(steadyRatio.ratio! - 1.0) < 0.0001, "constant load gives an ACWR of 1")
check(steadyRatio.zone == "接近历史", "constant load sits in the steady zone")
let spiking = (7..<28).map { loadRow($0, 300) } + (0..<7).map { loadRow($0, 700) }
check(StrainEngine.acwr(daily: spiking, now: loadNow, calendar: loadCalendar).ratio! > steadyRatio.ratio!, "a recent load spike raises the ratio")
let sparseLoad = (0..<5).map { loadRow($0, 400) }
check(StrainEngine.acwr(daily: sparseLoad, now: loadNow, calendar: loadCalendar).ratio == nil, "insufficient history refuses an ACWR")
let withGaps = (1...28).map { loadRow($0, $0 % 2 == 1 ? 400 : nil) }
let gapRatio = StrainEngine.acwr(daily: withGaps, now: loadNow, calendar: loadCalendar)
check(gapRatio.ratio != nil && abs(gapRatio.ratio! - 1.0) < 0.0001, "missing days are excluded rather than counted as zero")
print("122 checks total; strain/load numerics are synthetic regressions, not physiological validation.")
