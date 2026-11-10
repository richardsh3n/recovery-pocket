import Foundation
var checks = 0
func check(_ condition:@autoclosure () -> Bool,_ name:String) { guard condition() else { fatalError("FAIL: "+name) };checks += 1;print("PASS: "+name) }
func close(_ a:Double,_ b:Double) -> Bool { abs(a-b) < 0.000001 }
var cal = Calendar(identifier:.gregorian);cal.timeZone = TimeZone(secondsFromGMT:0)!
let day = cal.startOfDay(for:Date(timeIntervalSince1970:1_780_000_000)),hourEnd = day.addingTimeInterval(3600)
func row(dayOffset:Int,hour:Double = 1,sdnn:Double = 50,source:String = "watch-a",context:String = "睡眠",duration:Double = 60) -> HRVObservation {
    let a = cal.date(byAdding:.day,value:dayOffset,to:day)!.addingTimeInterval(hour*3600)
    return HRVObservation(id:UUID(),start:a,end:a.addingTimeInterval(duration),sdnn:sdnn,context:context,source:source)
}
let earlier = [-3,-2,-1].map { row(dayOffset:$0) }
let current = row(dayOffset:0,sdnn:25)
let now = day.addingTimeInterval(6*3600)
func sleeping(_ rows:[HRVObservation]) -> [HRVObservation] { HRVContextComparison.compare(rows,context:"睡眠",now:now,calendar:cal) }
func compared(_ rows:[HRVObservation],_ id:UUID) -> HRVObservation { sleeping(rows).first { $0.id == id }! }
let comparable = compared(earlier+[current],current.id)
check(comparable.baselineDays == 3 && comparable.deviation! < 0,"sleep SDNN uses earlier comparable nights")
var twoMinutes = current;twoMinutes.end = twoMinutes.start.addingTimeInterval(120)
check(compared(earlier+[twoMinutes],twoMinutes.id).deviation == nil,"sleep SDNN of a different duration cannot reuse one-minute baseline")
var replacement = current;replacement.source = "watch-b"
check(compared(earlier+[replacement],replacement.id).deviation == nil,"replacement HRV source cannot reuse another watch baseline")
let ownHistory = [-3,-2,-1].map { row(dayOffset:$0,sdnn:100,source:"watch-b") }
let own = compared(earlier+ownHistory+[replacement],replacement.id)
check(own.baselineDays == 3 && own.deviation! < 0,"source-specific history remains usable alongside unrelated source")
let oneNight = (0..<10).map { _ in row(dayOffset:-1) }
check(compared(oneNight+[current],current.id).baselineDays == 1,"many same-night records remain one baseline night")
let sameNightEvening = row(dayOffset:-1,hour:23,sdnn:200)
check(compared(earlier+[sameNightEvening,current],current.id).deviation == comparable.deviation,"previous calendar evening in the same sleep night cannot leak into baseline")
let future = row(dayOffset:1,sdnn:1000)
check(compared(earlier+[current,future],current.id).deviation == comparable.deviation,"future SDNN cannot alter prior sleep comparison")
check(compared([-31,-30,-29].map { row(dayOffset:$0) }+[current],current.id).deviation == nil,"expired sleep nights cannot establish current baseline")
let breathing = earlier.map { original -> HRVObservation in var r = original;r.context = "呼吸练习";return r }
check(compared(breathing+[current],current.id).deviation == nil,"breathwork cannot become a sleeping HRV baseline")
var invalid = earlier[0];invalid.sdnn = .nan
check(compared([invalid]+Array(earlier.dropFirst())+[current],current.id).deviation == nil,"nonfinite sleep SDNN cannot establish baseline")
check(compared([earlier[0],earlier[0],current],current.id).baselineDays == 1,"duplicate UUIDs do not multiply nights")
var cross = row(dayOffset:0,hour:1-30.0/3600,context:"安静候选");cross.deviation = -2
let left = HRVWindow.summarize([cross],context:"安静候选",start:day,end:hourEnd)
let right = HRVWindow.summarize([cross],context:"安静候选",start:hourEnd,end:hourEnd.addingTimeInterval(3600))
check(close(left.observedHours,30.0/3600) && close(right.observedHours,30.0/3600),"cross-hour HRV exposure splits across both bins")
check(left.deviation == -2 && right.deviation == -2,"both halves use the same comparable deviation")
check(close(left.sampleWeight+right.sampleWeight,1),"cross-hour HRV evidence counts once in total")
check(left.startedSamples+right.startedSamples == 1,"cross-hour raw sample count is not duplicated")
let joined = HRVWindow.summarize([cross],context:"安静候选",start:day,end:hourEnd.addingTimeInterval(3600))
check(close(left.observedHours+right.observedHours,joined.observedHours),"HRV window exposure is invariant to hour splitting")
let duplicate = HRVWindow.summarize([cross,cross],context:"安静候选",start:day,end:now)
check(close(duplicate.observedHours,1.0/60) && close(duplicate.sampleWeight,1),"duplicate sample cannot inflate coverage or confidence weight")
var overlap = cross;overlap.id = UUID()
let overlapped = HRVWindow.summarize([cross,overlap],context:"安静候选",start:day,end:now)
check(close(overlapped.observedHours,1.0/60) && close(overlapped.sampleWeight,1),"overlapping records share evidence instead of multiplying confidence")
var unavailable = cross;unavailable.deviation = nil
check(HRVWindow.summarize([unavailable],context:"安静候选",start:day,end:now).observedHours == 0,"unmatched SDNN does not establish model coverage")
var badDeviation = cross;badDeviation.deviation = .infinity
check(HRVWindow.summarize([badDeviation],context:"安静候选",start:day,end:now).deviation == nil,"nonfinite comparison cannot enter model")
var tooLong = cross;tooLong.end = tooLong.start.addingTimeInterval(3600)
check(HRVWindow.summarize([tooLong],context:"安静候选",start:day,end:now).observedHours == 0,"unsupported hour-long SDNN is not shortened to make it comparable")
check(HRVWindow.summarize([cross],context:"睡眠",start:day,end:now).deviation == nil,"awake samples never enter sleep window")
let h = BatteryHour(start:day,end:hourEnd,sleepHours:0,activeKcal:35,heartRate:nil,heartRateCount:20,heartRateCoverageHours:1)
let badHR = BatteryModel.calculate(hours:[h],anchor:50,baselineHR:55,now:hourEnd,calendar:cal)
check(badHR.points.last!.effect!.awakeDrain == 0 && badHR.value == 49,"invalid heart value cannot establish awake coverage despite a count")
var highHR = h;highHR.heartRate = .infinity
check(BatteryModel.calculate(hours:[highHR],anchor:50,baselineHR:55,now:hourEnd,calendar:cal).value == 49,"nonfinite HR cannot create time penalty")
var invalidHRV = h;invalidHRV.awakeHRVZ = .nan;invalidHRV.awakeHRVObservedHours = 1
check(BatteryModel.calculate(hours:[invalidHRV],anchor:50,baselineHR:nil,now:hourEnd,calendar:cal).value == 49,"unmatched HRV coverage cannot create awake time penalty")
var sleep = h;sleep.sleepHours = 1;sleep.activeKcal = 0;sleep.sleepHRVZ = -2;sleep.sleepHRVCount = 1
var halfWeight = sleep;halfWeight.sleepHRVSampleWeight = 0.5
let fullWeighted = BatteryModel.calculate(hours:[sleep],anchor:50,baselineHR:nil,now:hourEnd,calendar:cal)
let halfWeighted = BatteryModel.calculate(hours:[halfWeight],anchor:50,baselineHR:nil,now:hourEnd,calendar:cal)
check(halfWeighted.points.last!.value! > fullWeighted.points.last!.value!,"fractional sleep sample weight limits influence to supported evidence")
var lateSleep = sleep;lateSleep.start = hourEnd.addingTimeInterval(3600);lateSleep.end = hourEnd.addingTimeInterval(7200)
let late = BatteryModel.calculate(hours:[lateSleep],anchor:50,baselineHR:nil,now:day.addingTimeInterval(4*3600),calendar:cal)
check(close(late.inputs!.unobservedHours!,3),"before first record and after last record remain unknown")
let gap = BatteryModel.calculate(hours:[sleep,lateSleep],anchor:50,baselineHR:nil,now:day.addingTimeInterval(4*3600),calendar:cal)
check(close(gap.inputs!.unobservedHours!,2),"implicit gaps and trailing gaps both count in day uncertainty")
check(close(gap.inputs!.observedHours,2),"recorded bin count stays distinct from missing time coverage")
let legacy = BatteryLedger(baselineHR:nil,hours:[sleep],sourceKey:"sleep::hr")
var neutral = sleep;neutral.sleepHRVZ = nil;neutral.sleepHRVCount = 0
check(legacy.status(now:hourEnd).value == BatteryModel.calculate(hours:[neutral],anchor:50,baselineHR:nil,now:hourEnd).value,"legacy production HRV without provenance is neutralized without deleting sleep")
var proven = sleep;proven.hrvContextVersion = 1;proven.hrvSourceKey = "watch-a"
check(BatteryLedger(baselineHR:nil,hours:[proven],sourceKey:"sleep::hr").status(now:hourEnd).value == fullWeighted.value,"proven comparable HRV remains active after ledger restart")
let roundTrip = try! JSONDecoder().decode(BatteryHour.self,from:JSONEncoder().encode(proven))
check(roundTrip.hrvContextVersion == 1 && roundTrip.hrvSourceKey == "watch-a","HRV provenance survives file round-trip")
struct ReadFailure:Error {}
let failed = await HealthReadOutcome<[Double]>.capture("HRV") { throw ReadFailure() }
let good = await HealthReadOutcome<[Double]>.capture("sleep") { [8] }
let empty = await HealthReadOutcome<[Double]>.capture("sleep") { [] }
check(failed.value == nil && failed.failure?.hasPrefix("HRV：") == true,"failed query retains named error instead of an empty success")
check(good.value == [8] && good.failure == nil,"readable query remains available beside a failed type")
check(empty.value?.isEmpty == true && empty.failure == nil,"successful empty read stays distinct from query failure")
var fullSleep = proven;fullSleep.sleepHRVSampleWeight = 1
var firstHalf = fullSleep;firstHalf.end = day.addingTimeInterval(1800);firstHalf.sleepHours = 0.5;firstHalf.sleepHRVSampleWeight = 0.5
var secondHalf = firstHalf;secondHalf.start = firstHalf.end;secondHalf.end = hourEnd
let whole = BatteryModel.calculate(hours:[fullSleep],anchor:50,baselineHR:nil,now:hourEnd,calendar:cal)
let split = BatteryModel.calculate(hours:[firstHalf,secondHalf],anchor:50,baselineHR:nil,now:hourEnd,calendar:cal)
check(close(whole.points.last!.value!,split.points.last!.value!),"pure sleep with the same evidence density is invariant to interval splitting")
let eightHours = (0..<8).map { i -> BatteryHour in var b = neutral;b.start = day.addingTimeInterval(Double(i)*3600);b.end = b.start.addingTimeInterval(3600);return b }
let lo = BatteryModel.calculate(hours:eightHours,anchor:35,baselineHR:nil,now:eightHours.last!.end,calendar:cal)
let hi = BatteryModel.calculate(hours:eightHours,anchor:65,baselineHR:nil,now:eightHours.last!.end,calendar:cal)
check(hi.points.last!.value!-lo.points.last!.value! < 8,"eight observed sleep hours reduce initial engineering-prior sensitivity")
var crossingDay = neutral;crossingDay.start = day.addingTimeInterval(-1800);crossingDay.end = day.addingTimeInterval(1800)
let clippedDay = BatteryModel.calculate(hours:[crossingDay],anchor:50,baselineHR:nil,now:hourEnd,calendar:cal)
check(close(clippedDay.inputs!.unobservedHours!,0.5),"cross-midnight coverage only credits current-day fraction")
let emptyModel = BatteryModel.calculate(hours:[],anchor:50,baselineHR:nil,now:now,calendar:cal)
check(emptyModel.value == nil && close(emptyModel.inputs!.unobservedHours!,6),"empty valid-anchor day exposes all elapsed time as unknown")
let freshRange = BatteryModel.calculate(hours:[neutral],anchor:50,baselineHR:nil,now:hourEnd,calendar:cal)
let agingRange = BatteryModel.calculate(hours:[neutral],anchor:50,baselineHR:nil,now:hourEnd.addingTimeInterval(3600),calendar:cal)
check(agingRange.upper!-agingRange.lower! > freshRange.upper!-freshRange.lower!,"trailing unobserved time widens the engineering uncertainty band")
var jitter = current;jitter.end = jitter.start.addingTimeInterval(59.9)
check(compared(earlier+[jitter],jitter.id).baselineDays == 3,"minor timestamp jitter near one minute does not discard otherwise comparable sleep history")
var jitterDay = cross;jitterDay.end = jitterDay.start.addingTimeInterval(59.9);jitterDay.deviation = nil
let dayPrior = [-3,-2,-1].map { row(dayOffset:$0,hour:1-30.0/3600,source:"watch-a",context:"安静候选") }
let dayCompared = DayHRVModel.compare(dayPrior+[jitterDay],now:now,calendar:cal).first { $0.id == jitterDay.id }!
check(dayCompared.baselineDays == 3,"daytime duration buckets also tolerate one-minute timestamp jitter")
var otherSource = cross;otherSource.id = UUID();otherSource.source = "watch-b"
check(HRVWindow.summarize([cross,otherSource],context:"安静候选",start:day,end:now).deviation == nil,"one hour window refuses to merge different device sources")
let quietBin = HRVActivityBin(start:day,end:hourEnd,steps:0,kcal:0)
let activeBin = HRVActivityBin(start:hourEnd,end:hourEnd.addingTimeInterval(3600),steps:500,kcal:10)
check(HRVActivityContext.classify(start:cross.start,end:cross.end,bins:[quietBin,activeBin]) == "活动时段","cross-hour sample touching active time is not treated as quiet")
var quietSecond = activeBin;quietSecond.steps = 0;quietSecond.kcal = 0
check(HRVActivityContext.classify(start:cross.start,end:cross.end,bins:[quietBin,quietSecond]) == "安静候选","both known quiet halves permit a cross-hour quiet context")
check(HRVActivityContext.classify(start:cross.start,end:cross.end,bins:[quietBin]) == "活动记录不足","missing second-half movement does not become quiet")
var invalidActivity = quietSecond;invalidActivity.steps = .nan
check(HRVActivityContext.classify(start:cross.start,end:cross.end,bins:[quietBin,invalidActivity]) == "活动记录不足","invalid movement cannot establish quiet context")
var gapActivity = quietSecond;gapActivity.start = hourEnd.addingTimeInterval(1)
check(HRVActivityContext.classify(start:cross.start,end:cross.end,bins:[quietBin,gapActivity]) == "活动记录不足","even a known gap inside context coverage remains unknown")
check(HRVActivityContext.classify(start:cross.start,end:cross.start,bins:[quietBin]) == "活动记录不足","zero-duration sample cannot establish quiet context")
check(HealthReadPolicy.canUpdateBattery(failed:[.steps,.mindfulness,.restingHeartRate,.dailyEnergy,.respiration,.temperature,.oxygen]),"failed optional body/background types cannot block sleep and activity battery updates")
check(!HealthReadPolicy.canCompareAwakeHRV(failed:[.steps]) && !HealthReadPolicy.canCompareAwakeHRV(failed:[.mindfulness]),"missing optional activity/breathwork background disables only awake HRV comparison")
check([HealthReadChannel.sleep,.hrv,.heartRate,.hourlyEnergy,.workout].allSatisfy { !HealthReadPolicy.canUpdateBattery(failed:[$0]) },"failed core reads preserve old battery instead of silently deleting known input")
check(HealthReadPolicy.canCompareAwakeHRV(failed:[.temperature,.oxygen]),"unrelated missing vitals do not suppress comparable daytime HRV")
print("\(checks) algorithm checks passed. Synthetic fixtures only; no physiological accuracy claim.")
