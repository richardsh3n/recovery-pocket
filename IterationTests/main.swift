import Foundation
var checks=0
func check(_ condition:@autoclosure()->Bool,_ name:String) { precondition(condition(),name);checks += 1;print("PASS: "+name) }
var cal=Calendar(identifier:.gregorian);cal.timeZone=TimeZone(secondsFromGMT:0)!
let day=cal.startOfDay(for:Date(timeIntervalSince1970:1_780_000_000))
let now=day.addingTimeInterval(12*3600)
func night(_ offset:Int,_ hrv:Double,_ source:String?="a",_ bucket:Int?=2)->NightRecord {
    NightRecord(date:day.addingTimeInterval(Double(offset)*86400),sleepHours:8,hrv:hrv,heartRate:55,hrvCount:5,heartRateCount:60,hrvSourceKey:source,heartRateSourceKey:source,hrvDurationBucket:bucket)
}
let prior=(1...6).map { night(-$0,$0 <= 3 ? 50:200,$0 <= 3 ? "a":"b") }
let next=night(1,100)
let workout=PocketWorkout(id:UUID(),title:"fixture",start:day.addingTimeInterval(3600),end:day.addingTimeInterval(7200),duration:3600,activeKcal:300,source:"a")
let comparison=WellnessEngine.followUps(workouts:[workout],nights:prior+[next],feelings:[],now:day.addingTimeInterval(2*86400),calendar:cal)[0]
check(comparison.baselineDays == 3 && comparison.baselineHRV == 50,"follow-up selects three same-source dates")
check(comparison.hrvDifference == 50,"source-mixing sign reversal is repaired")
check(NightlyComparison.history(for:next,in:prior,channel:.hrv,days:28,calendar:cal).count == 3,"morning and training can share the comparison policy")
let mixedDurations=[night(-1,50),night(-2,50),night(-3,200,"a",4)]
check(NightlyComparison.history(for:next,in:mixedDurations,channel:.hrv,days:28,calendar:cal).count == 2,"different SDNN durations cannot create a third baseline day")
let noBaseline=WellnessEngine.followUps(workouts:[workout],nights:mixedDurations+[next],feelings:[],now:day.addingTimeInterval(2*86400),calendar:cal)[0]
check(noBaseline.baselineHRV == nil && noBaseline.hrvDifference == nil,"short matched history stays missing rather than borrowing another duration")
check(NightlyComparison.history(for:next,in:Array(repeating:night(-1,50),count:10),channel:.hrv,days:28,calendar:cal).count == 1,"duplicate nightly rows remain a single baseline date")
check(NightlyComparison.history(for:next,in:prior+[night(2,999)],channel:.hrv,days:28,calendar:cal).count == 3,"future records do not enter prior baseline")
check(NightlyComparison.history(for:next,in:[night(-30,50)],channel:.hrv,days:28,calendar:cal).isEmpty,"expired records do not enter baseline")
check(NightlyComparison.history(for:next,in:[night(-1,50,nil)],channel:.hrv,days:28,calendar:cal).isEmpty,"unknown source cannot match known source")
check(NightlyComparison.history(for:night(1,100,nil),in:[night(-1,50,nil)],channel:.hrv,days:28,calendar:cal).count == 1,"old unknown-source history remains compatible with old unknown-source reference")
var invalid=night(-1,50);invalid.sleepHours = .infinity
check(NightlyComparison.history(for:next,in:[invalid],channel:.hrv,days:28,calendar:cal).isEmpty,"nonfinite sleep cannot establish comparable night")
check(WellnessEngine.validHRV(night(-1,1000)) == nil,"out-of-range HRV is excluded consistently")
var sourceHR=night(-1,50);sourceHR.hrvSourceKey="b"
check(NightlyComparison.history(for:next,in:[sourceHR],channel:.heartRate,days:28,calendar:cal).count == 1,"heart-rate channel uses its own source key")
let orderA=NightlyComparison.history(for:next,in:[night(-1,50),night(-1,60)],channel:.hrv,days:28,calendar:cal)
let orderB=NightlyComparison.history(for:next,in:[night(-1,60),night(-1,50)],channel:.hrv,days:28,calendar:cal)
check(orderA.first?.hrv == orderB.first?.hrv,"duplicate-night resolution is independent of input order")
var status=PocketStatus.empty;status.computedAt=now;status.measuredAt=now.addingTimeInterval(-60);status.value=80;status.modelRevision="fixture-v1"
let frozen=RecordedPrediction.capture(status,at:now)!
check(frozen.value == 80 && frozen.kind == "身体电量","a fresh reserve is captured with its identity")
status.value=10
check(frozen.value == 80,"later model changes never rewrite the captured prediction")
check(frozen.usable(for:now,now:now),"same-moment self-rating can pair with preceding observation")
check(!frozen.usable(for:now.addingTimeInterval(-600),now:now),"backdated self-rating cannot receive today's prediction")
check(!frozen.usable(for:now.addingTimeInterval(600),now:now.addingTimeInterval(600)),"an old composer cannot pair a much later self-rating")
check(!frozen.usable(for:now.addingTimeInterval(1),now:now),"future journal date cannot enter feedback")
var stale=status;stale.measuredAt=now.addingTimeInterval(-8000)
check(RecordedPrediction.capture(stale,at:now) == nil,"expired reserve is not saved as current prediction")
var unknown=status;unknown.value=nil
check(RecordedPrediction.capture(unknown,at:now) == nil,"missing output is not fabricated for feedback")
var future=status;future.measuredAt=now.addingTimeInterval(1)
check(RecordedPrediction.capture(future,at:now) == nil,"future observation cannot be paired")
var malformed=frozen;malformed.capturedAt=now.addingTimeInterval(1)
check(!malformed.usable(for:now,now:now),"future capture metadata is rejected")
malformed=frozen;malformed.validUntil=now.addingTimeInterval(-1)
check(!malformed.usable(for:now,now:now),"expired captured metadata is rejected")
malformed=frozen;malformed.kind="other"
check(!malformed.usable(for:now,now:now),"unknown prediction semantics are not mixed into feedback")
var event=PocketEvent(date:now,kind:"自评",energy:1,note:"fixture",prediction:frozen)
let matches=FeedbackEngine.pairs([event],now:now)
check(matches.count == 1 && matches[0].needsReview,"high-model low-energy pair is marked for review")
event.energy=4
check(!FeedbackEngine.pairs([event],now:now)[0].needsReview,"closer subjective state is not incorrectly flagged")
check(FeedbackEngine.pairs([event,event],now:now).count == 1,"same saved record cannot inflate pair count")
var legacy=event;legacy.id=UUID();legacy.prediction=nil
check(FeedbackEngine.pairs([legacy],now:now).isEmpty,"legacy records are never backfilled with current scores")
var variant=event;variant.id=UUID();variant.prediction?.kind="近期状态"
check(Set(FeedbackEngine.pairs([event,variant],now:now).map(\.group)).count == 2,"reserve and recent-state comparisons remain separate")
variant.prediction?.kind="身体电量";variant.prediction?.modelRevision="fixture-v2"
check(Set(FeedbackEngine.pairs([event,variant],now:now).map(\.group)).count == 2,"different model revisions remain separate")
let json=JSONEncoder();let decoder=JSONDecoder()
let oldJSON="{\"id\":\"00000000-0000-0000-0000-000000000001\",\"date\":0,\"kind\":\"自评\",\"energy\":3,\"note\":\"old\"}".data(using:.utf8)!
let oldEvent=try decoder.decode(PocketEvent.self,from:oldJSON)
check(oldEvent.energy == 3 && oldEvent.prediction == nil && oldEvent.sessionLoad == nil,"legacy diary remains readable without new optional fields")
let restored=try decoder.decode(PocketEvent.self,from:json.encode(event))
check(restored.prediction == event.prediction && restored.id == event.id,"frozen prediction survives save and restart")
var effort=PocketEvent(date:now,kind:"训练",energy:3,note:"fixture",sessionRPE:2,trainingMinutes:60)
check(effort.sessionLoad == 120,"two out of ten for sixty minutes gives 120 subjective load units")
effort.sessionRPE=8;check(effort.sessionLoad == 480,"same duration at higher perceived exertion produces higher subjective load")
effort.sessionRPE=0;check(effort.sessionLoad == 0,"explicit zero effort is distinct from missing effort")
effort.sessionRPE=nil;check(effort.sessionLoad == nil,"missing effort is not replaced by zero")
effort.sessionRPE=8;effort.trainingMinutes = .nan;check(effort.sessionLoad == nil,"nonfinite training duration is rejected")
effort.trainingMinutes = -1;check(effort.sessionLoad == nil,"negative training duration is rejected")
effort.trainingMinutes=60;effort.sessionRPE=11;check(effort.sessionLoad == nil,"effort outside zero to ten is rejected")
effort.sessionRPE=8;effort.kind="咖啡";check(effort.sessionLoad == nil,"non-training records cannot contribute subjective training load")
var unversioned=status;unversioned.modelRevision=nil
check(RecordedPrediction.capture(unversioned,at:now) == nil,"unversioned predictions cannot mix unknown algorithms")
check(FeedbackEngine.attachment(frozen,eventDate:now,recordedAt:now.addingTimeInterval(301)) == nil,"delayed submission cannot masquerade as immediate feedback")
check(FeedbackEngine.pairs([event],now:now.addingTimeInterval(86400)).count == 1,"valid historical comparison remains visible after the observation expires")
let proof:[String:Any]=["checks":checks,"correctedSameSourceBaseline":comparison.baselineHRV!,"correctedHRVDifference":comparison.hrvDifference!,"capturedPrediction":frozen.value,"scope":"Synthetic software checks, not physiological calibration"]
if CommandLine.arguments.count>1 {try JSONSerialization.data(withJSONObject:proof,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))}
print("\(checks) iteration regression checks passed")
