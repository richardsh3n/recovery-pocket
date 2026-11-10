import Foundation
var checks=0
func check(_ value:@autoclosure()->Bool,_ name:String){precondition(value(),name);checks+=1;print("PASS: "+name)}
func close(_ a:Double,_ b:Double)->Bool{abs(a-b)<1e-8}
let start=Date(timeIntervalSince1970:1793419200),end=start.addingTimeInterval(3600),now=end.addingTimeInterval(60),digest=String(repeating:"a",count:64)
let samples=(0...60).map{WorkoutHeartSample(date:start.addingTimeInterval(Double($0)*60),bpm:160,source:"watch")}
let spans=WorkoutHeartFallback.make(samples:samples,windows:[(start,end)],start:start,end:end,now:now,reference:60,source:"watch")
let full=BatteryHour(start:start,end:end,sleepHours:0,activeKcal:350,heartRate:160,heartRateCount:61,heartRateCoverageHours:1,workoutHours:1,personalHR:60,awakeHeartRate:160,awakeHeartRateCount:61,awakeHeartRateCoverageHours:1,workoutHeartSpans:spans)
func assess(_ row:BatteryHour)->ActivityFusionAssessment{ActivityFusionEngine.assess(hour:row,now:now,policy:.cardioEnergyV1)}
func refused(_ row:BatteryHour,_ reason:ActivityFusionReason,_ name:String){let result=assess(row);check(result.reason==reason && result.decision==nil,name)}
check(assess(full).reason == .eligible && assess(full).coveredMinutes==60,"eligible assessment reports actual sixty-minute coverage")
check(close(assess(full).decision!.replacementDrain,35.0/3),"diagnostics preserve V25 numeric replacement")
var row=full;row.end=start;refused(row,.invalidInterval,"invalid interval cannot produce a replacement")
row=full;row.end=now.addingTimeInterval(1);refused(row,.futureInterval,"future interval has an explicit cause")
row=full;row.sleepHours = .nan;refused(row,.invalidSleep,"nonfinite sleep is an invalid record rather than an empty workout")
row=full;row.sleepHours=0.1;refused(row,.sleepOverlap,"sleep overlap abstains explicitly")
row=full;row.workoutHours=0;refused(row,.noWorkout,"no workout is distinguished from missing heart coverage")
row=full;row.workoutHours=nil;refused(row,.noWorkout,"legacy missing workout duration cannot claim training")
row=full;row.workoutHours = .infinity;refused(row,.invalidTraining,"nonfinite training duration is rejected")
check(assess(row).trainingMinutes==nil,"invalid duration is not shown as measured minutes")
row=full;row.workoutHours=1.01;refused(row,.invalidTraining,"excess training time is diagnosed")
row=full;row.workoutHours=0.5;refused(row,.mixedActivity,"half-workout energy bin is labelled mixed rather than unread")
check(assess(row).coveredMinutes==nil && assess(row).trainingMinutes==30,"unassessed heart coverage stays unknown instead of zero")
row=full;row.activeKcal=nil;refused(row,.missingEnergy,"absent energy explains preservation of formal fallback")
row=full;row.activeKcal = -1;refused(row,.invalidEnergy,"negative energy is not missingness")
row=full;row.activeKcal=0;check(assess(row).reason == .eligible,"recorded zero remains eligible observed energy")
row=full;row.workoutHeartSpans=nil;refused(row,.missingHeartPairs,"old absent HR pairs do not fabricate coverage")
row=full;row.workoutHeartSpans![0].averageHR=nil;refused(row,.invalidHeartPairs,"legacy spans without raw means explicitly fail comparability")
row=full;row.workoutHeartSpans![0].source="other";refused(row,.mixedSources,"multiple streams get a source-specific cause")
row=full;row.workoutHeartSpans![0].referenceHR=61;refused(row,.mixedReferences,"multiple resting references get a distinct cause")
row=full;var overlap=spans[0];overlap.start=overlap.start.addingTimeInterval(30);overlap.end=overlap.end.addingTimeInterval(30);row.workoutHeartSpans!.append(overlap);refused(row,.overlappingPairs,"conflicting interval overlap remains unsafe")
row=full;row.workoutHours=0.95;refused(row,.excessCoverage,"observed minutes cannot exceed saved training duration")
row=full;row.workoutHeartSpans=Array(spans.prefix(47));refused(row,.insufficientCoverage,"under-eighty-percent actual coverage has an explicit cause")
check(assess(row).coveredMinutes==47,"valid but insufficient actual minutes remain inspectable")
row=full;row.workoutHeartSpans=spans+spans
check(assess(row).coveredMinutes==60 && close(assess(row).decision!.replacementDrain,35.0/3),"duplicate raw pairs cannot inflate audit or score")
func ledger(_ rows:[BatteryHour],origin:Date=start)->BatteryLedger{BatteryLedger(baselineHR:60,hours:rows,sourceKey:"watch",continuousVersion:1,continuousOrigins:[BatteryOrigin(bucketStart:start,date:origin,value:80,uncertainty:30,reason:"synthetic")])}
let normal=ShadowReplayEngine.inspect(ledger:ledger([full]),inputDigest:digest,now:now)
check(normal.availability == .ready && normal.replay != nil,"valid inspection preserves independent paired replay")
check(normal.audit!.entries.count==1 && normal.audit!.eligibleMinutes==60 && normal.audit!.trainingMinutes==60,"audit totals are derived from actually integrated candidate effects")
row=full;row.workoutHours=0.5;row.workoutHeartSpans=Array(spans.prefix(30))
let mixed=ShadowReplayEngine.inspect(ledger:ledger([row]),inputDigest:digest,now:now)
check(mixed.availability == .noEligibleTraining && mixed.replay==nil,"rejected training cannot create a frozen paired prediction")
check(mixed.audit!.entries.count==1 && mixed.audit!.reasons[.mixedActivity]==1 && mixed.audit!.eligibleMinutes==0,"rejected-bin evidence survives when no candidate is eligible")
check(close(mixed.audit!.trainingMinutes,30),"recorded thirty-minute training survives rejection")
let formal=ledger([row]).status(now:now)
check(formal.points.allSatisfy{$0.effect?.activityAssessment==nil && $0.effect?.activityExperiment==nil},"formal model never adopts experimental diagnostic records")
let clipped=ShadowReplayEngine.inspect(ledger:ledger([full],origin:start.addingTimeInterval(1800)),inputDigest:digest,now:now)
check(clipped.audit!.entries.first!.start==start.addingTimeInterval(1800) && clipped.audit!.trainingMinutes==30 && clipped.audit!.eligibleMinutes==30,"audit uses exact pinned-origin clipping rather than untrimmed source bins")
let duplicate=ShadowReplayEngine.inspect(ledger:ledger([full,full]),inputDigest:digest,now:now)
check(duplicate.audit!.entries.count==1 && duplicate.audit!.trainingMinutes==60,"duplicated ledger bins cannot inflate audit totals")
let sleep=BatteryHour(start:start.addingTimeInterval(-3600),end:start,sleepHours:1,activeKcal:0,heartRate:55,heartRateCount:12,workoutHours:0,personalHR:60)
check(ShadowReplayEngine.inspect(ledger:ledger([sleep,full]),inputDigest:digest,now:now).audit!.entries.count==1,"sleep-only intervals are not reported as rejected training")
let stale=ShadowReplayEngine.inspect(ledger:ledger([full]),inputDigest:digest,now:end.addingTimeInterval(7201))
check(stale.availability == .stale && stale.audit==nil && stale.replay==nil,"expired observations cannot masquerade as current audit readiness")
var old=ledger([full]);old.continuousVersion=nil
check(ShadowReplayEngine.inspect(ledger:old,inputDigest:digest,now:now).availability == .legacyLedger,"legacy reserve gives an actionable availability reason")
check(ShadowReplayEngine.inspect(ledger:ledger([full]),inputDigest:"bad",now:now).availability == .unidentifiedInputs,"unreviewable digest cannot create experiment")
let decoded=try JSONDecoder().decode(ActivityFusionAssessment.self,from:JSONEncoder().encode(assess(full)))
check(decoded.reason == .eligible && decoded.coveredMinutes==60,"diagnostic provenance survives serialization")
var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(normal.replay!.candidate)) as! [String:Any]
var points=object["points"] as! [[String:Any]]
for i in points.indices {if var effect=points[i]["effect"] as? [String:Any]{effect.removeValue(forKey:"activityAssessment");points[i]["effect"]=effect}}
object["points"]=points
let oldStatus=try JSONDecoder().decode(PocketStatus.self,from:JSONSerialization.data(withJSONObject:object))
check(oldStatus.points.allSatisfy{$0.effect?.activityAssessment==nil},"old saved effects remain decodable without invented diagnostic history")
let reasonTitles=ActivityFusionReason.allCases.map(\.title)
check(Set(reasonTitles).count==ActivityFusionReason.allCases.count && ActivityFusionReason.allCases.allSatisfy{!$0.detail.isEmpty},"all abstention reasons have distinct user-facing labels and explanations")
if CommandLine.arguments.count>1 {
 let proof:[String:Any]=["syntheticOnly":true,"checks":checks,"candidateEnabled":false,"eligibleTrainingMinutes":normal.audit!.eligibleMinutes,"mixedTrainingMinutes":mixed.audit!.trainingMinutes,"mixedEligibleMinutes":mixed.audit!.eligibleMinutes,"mixedReason":mixed.audit!.entries.first!.reason.rawValue,"clippedTrainingMinutes":clipped.audit!.trainingMinutes,"formalIncludesExperimentalDiagnostics":false]
 try JSONSerialization.data(withJSONObject:proof,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
}
print("\(checks) shadow eligibility checks passed; no physiological or real-data acceptance")
