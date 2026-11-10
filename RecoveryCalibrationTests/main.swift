import Foundation
var checks=0
func check(_ value:@autoclosure()->Bool,_ name:String) { precondition(value(),name);checks += 1;print("PASS: "+name) }
var cal=Calendar(identifier:.gregorian);cal.timeZone=TimeZone(secondsFromGMT:0)!
let date=cal.startOfDay(for:Date(timeIntervalSince1970:1_780_000_000))
func night(_ offset:Int,_ hrv:Double? = 50,_ hr:Double? = 55,_ sleep:Double? = 8,_ source:String? = "watch-a",_ bucket:Int? = 2) -> RecoveryDay {
    RecoveryDay(night:NightRecord(date:cal.date(byAdding:.day,value:offset,to:date)!,sleepHours:sleep,hrv:hrv,heartRate:hr,hrvCount:hrv == nil ? 0:8,heartRateCount:hr == nil ? 0:60,hrvSourceKey:source,heartRateSourceKey:source,hrvDurationBucket:bucket),activeKcal:400,sleepMidpointHour:nil)
}
let history=(0..<28).map { night($0) }
func last(_ current:RecoveryDay,_ extra:[RecoveryDay]=[]) -> RecoveryEstimate { RecoveryModelV2.calculate(days:history+extra+[current],calendar:cal).last! }
let normal=last(night(28)),good=last(night(28,65,52)),poor=last(night(28,25,65,5))
check(normal.score == 65,"normal comparable signals map to the documented personal reference")
check(good.score! > normal.score!+10,"current favorable signals respond without being filtered away")
check(poor.score! < normal.score!-20,"poor signals and sleep deficit remain responsive")
let sustained=RecoveryModelV2.calculate(days:history+(28..<35).map { night($0,66.8,49) },calendar:cal).last!
check(sustained.score! > 90,"consistent favorable evidence can exceed the old hidden ninety-point cap")
for burden in stride(from:-4.0,through:4,by:0.25) {
    check((0...100).contains(RecoveryModelV2.index(burden:burden)),"bounded provisional mapping \(burden)")
    check(RecoveryModelV2.index(burden:burden) >= RecoveryModelV2.index(burden:burden+0.1),"monotonic burden mapping \(burden)")
}
let onlySleep=RecoveryModelV2.calculate(days:[night(0,nil,nil)],calendar:cal).last!
check(onlySleep.score == nil && onlySleep.sleepCompletion == 100,"sleep alone remains visible but never generates a prior recovery score")
check(!onlySleep.measurementUsed && onlySleep.lower == nil && onlySleep.upper == nil,"no invented recovery range without comparable signals")
let partial=last(night(28,50,nil))
check(partial.score != nil && partial.scoreBasis == "仅可比睡眠 HRV","one comparable channel remains usable")
check(last(night(28,50,55,8,"watch-b")).score == nil,"replacement watch cannot reuse another device's recovery baseline")
let differentDuration=last(night(28,25,nil,8,"watch-a",4))
check(differentDuration.score == nil,"different SDNN measurement duration cannot reuse the baseline")
let future=RecoveryModelV2.calculate(days:history+[night(28),night(29,10,90,3)],calendar:cal)
check(future[future.count-2].score == normal.score,"future night cannot change past recovery")
let conflict=last(night(28,65,65))
check(conflict.score! <= normal.score!,"high HRV and high heart rate never jointly create a favorable recovery")
var malformed=night(28);malformed.night.hrv = .nan;malformed.night.heartRate = .infinity
check(last(malformed).score == nil,"nonfinite physiology cannot yield a recovery score")
for result in [normal,good,poor,partial,sustained,conflict] {check(result.lower! <= result.score! && result.score! <= result.upper!,"score lies in its model sensitivity range")}
let end=date.addingTimeInterval(3600)
func samples(_ bpm:Double,source:String="watch-a") -> [WorkoutHeartSample] { (0...60).map { WorkoutHeartSample(date:date.addingTimeInterval(Double($0)*60),bpm:bpm,source:source) } }
func evidence(_ rows:[WorkoutHeartSample],rest:Double?=55) -> WorkoutCardioEvidence? { WorkoutCardioEngine.evidence(samples:rows,start:date,end:end,now:end,resting:rest) }
let easy=evidence(samples(100))!,hard=evidence(samples(160))!
check(abs(easy.coveredMinutes-60)<1e-9 && easy.averageHR == 100,"dense samples integrate their actual duration and mean")
check(hard.relativeLoadMinutes! > easy.relativeLoadMinutes!*3,"same duration different heart rate produces distinct internal load")
check(evidence([samples(100)[0],samples(100)[60]])!.coveredMinutes == 0,"an hour-long gap is not continuous coverage")
check(evidence(samples(100)+samples(100))!.coveredMinutes == easy.coveredMinutes,"duplicate samples cannot multiply coverage")
check(evidence(samples(100),rest:nil)!.relativeLoadMinutes == nil,"no personal resting reference means no inferred relative intensity")
check(evidence(samples(100),rest:.nan)!.averageHR == 100,"invalid baseline does not hide valid observed heart rate")
var outside=samples(100);outside.append(WorkoutHeartSample(date:end.addingTimeInterval(1),bpm:220,source:"watch-a"))
check(evidence(outside)!.peakHR == 100,"future/outside-window samples cannot change workout evidence")
check(WorkoutCardioEngine.evidence(samples:samples(100),start:date,end:end,now:date,resting:55) == nil,"unfinished future-ended workout cannot be analyzed")
let short=Array(samples(100)[10...20]);check(evidence(short)!.coveredMinutes == 10,"workout edges are not extrapolated from a short observed section")
let mixed=evidence(samples(100)+[WorkoutHeartSample(date:date.addingTimeInterval(30),bpm:220,source:"other")])!
check(mixed.averageHR == 100,"different device streams never join into artificial heart-rate intervals")
check(evidence([]) == nil,"no heart samples does not become a zero-load workout")
check(StrainEngine.strain(kcal:1000,workoutMinutes:0)==StrainEngine.strain(kcal:1000,workoutMinutes:75),"training time does not add a duplicate calorie-based load bonus")
let atBoundary=last(night(28,50*exp(0.15*2),55))
let pastBoundary=last(night(28,50*exp(0.15*2.01),55))
check(abs(atBoundary.score!-pastBoundary.score!) <= 2,"HRV outlier boundary has no abrupt favorable-score cliff")
check(last(night(28,500,55)).score! <= normal.score!,"extreme high HRV is not an automatic favorable recovery")
check(last(night(28,50,30)).score! <= normal.score!,"extreme low heart rate is not an automatic favorable recovery")
let duplicateSource=(0..<100).map { _ in WorkoutHeartSample(date:date.addingTimeInterval(30),bpm:220,source:"other") }
check(evidence(samples(100)+duplicateSource)!.averageHR == 100,"duplicated source samples cannot displace a genuinely covered stream")
let gap91=[WorkoutHeartSample(date:date,bpm:100,source:"a"),WorkoutHeartSample(date:date.addingTimeInterval(91),bpm:100,source:"a")]
check(evidence(gap91)!.coveredMinutes == 0,"gaps above the sampling limit remain uncovered")
let encoder=JSONEncoder()
let legacy="{\"date\":0,\"sleepHours\":8,\"hrv\":50,\"heartRate\":55,\"hrvCount\":4,\"heartRateCount\":10}".data(using:.utf8)!
check(try! JSONDecoder().decode(NightRecord.self,from:legacy).hrvSourceKey == nil,"legacy nightly caches remain readable")
var coachStatus=PocketStatus.empty
let coachNow=date.addingTimeInterval(12*3600)
coachStatus.recoverySummary=WearableSummary(date:date,recovery:88,sleepHours:8,hrv:65,heartRate:52,baselineNights:28,recoveryBasis:"睡眠 HRV + 心率",recoveryModelRevision:RecoveryModelV2.revision)
let coach=CoachContext(now:coachNow,snapshotAt:coachNow,battery:coachStatus,nights:[],workouts:[],hrv:[],target:8,selfRating:nil,demo:false)
check(coach.brief(.today).facts.contains { $0.key == "morningRecovery" && $0.detail.contains("不是剩余电量") },"coach receives the recovery score with its distinct scale meaning")
var staleCoach=coach;staleCoach.snapshotAt=coachNow.addingTimeInterval(-7*3600)
check(!staleCoach.brief(.today).facts.contains { $0.key == "morningRecovery" },"stale snapshots cannot enter the coach as current recovery")
let oldWorkout=PocketWorkout(id:UUID(),title:"legacy",start:date,end:end,duration:3600,activeKcal:400,source:"watch")
check((try! JSONDecoder().decode(PocketWorkout.self,from:encoder.encode(oldWorkout))).cardio == nil,"legacy workout caches remain usable without cardio evidence")
let roundTrip=try! JSONDecoder().decode(WearableSummary.self,from:encoder.encode(coachStatus.recoverySummary!))
check(roundTrip.recoveryModelRevision == RecoveryModelV2.revision && roundTrip.recovery == 88,"watch summary preserves model revision and score")
let summary:[String:Any] = ["normal":normal.score!,"favorable":good.score!,"poor":poor.score!,"sustainedFavorable":sustained.score!,"sleepOnlyRecovery":NSNull(),"sleepOnlyCompletion":onlySleep.sleepCompletion!,"sameDurationEasyWeightedMinutes":easy.relativeLoadMinutes!,"sameDurationHardWeightedMinutes":hard.relativeLoadMinutes!,"checks":checks,"scope":"Synthetic software checks only; not physiological calibration"]
if CommandLine.arguments.count>1 {try! JSONSerialization.data(withJSONObject:summary,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))}
print("\(checks) recovery and workout evidence checks passed")
