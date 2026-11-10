import Foundation
var checks=0
func check(_ condition:@autoclosure()->Bool,_ name:String){precondition(condition(),name);checks+=1;print("PASS: "+name)}
func close(_ a:Double,_ b:Double)->Bool{abs(a-b)<1e-8}
var cal=Calendar(identifier:.gregorian);cal.timeZone=TimeZone(secondsFromGMT:0)!
let day=cal.startOfDay(for:Date(timeIntervalSince1970:1793419200)),now=day.addingTimeInterval(12*3600)
func heart(_ rate:Double,_ date:Date,_ resting:Bool=true,_ source:String="watch")->StateHeartSignal{StateHeartSignal(date:date,bpm:rate,resting:resting,context:"安静候选",source:source)}
func estimate(_ signals:[StateHeartSignal],_ hours:[BatteryHour]=[])->CurrentStateEstimate {CurrentStateModel.estimate(signals:signals,hrv:[],hours:hours,now:now,calendar:cal)!}
let quiet=heart(105,now,false),oneDay=(1...3).map{heart(60,day.addingTimeInterval(-Double($0)*60))}
let insufficient=estimate(oneDay+[quiet])
check(insufficient.value==65 && !insufficient.channels.contains("安静心率"),"three readings from one local date cannot establish quiet-HR baseline")
check(insufficient.baselineDays==0 && insufficient.note.contains("不足3个日期"),"rejected one-day baseline is explicit without claiming comparable days")
let manyOneDay=(1...500).map{heart(60,day.addingTimeInterval(-Double($0)*10))}
check(estimate(manyOneDay+[quiet]).value==65,"five hundred readings on one prior date remain one date")
let threeDays=(1...3).map{heart(60,cal.date(byAdding:.day,value:-$0,to:now)!)}
let supported=estimate(threeDays+[quiet])
check(supported.value==56 && supported.baselineDays==3 && supported.channels.contains("安静心率"),"three genuine prior dates establish a counted quiet-HR comparison")
let uneven=[heart(60,day.addingTimeInterval(-86400+3600)),heart(60,day.addingTimeInterval(-2*86400+3600)),heart(90,day.addingTimeInterval(-3*86400+3600))]
let oversampled=uneven+(1...100).map{heart(90,day.addingTimeInterval(-3*86400+3600+Double($0)))}
check(estimate(uneven+[quiet]).value==estimate(oversampled+[quiet]).value,"one heavily sampled date cannot outweigh other daily baseline medians")
check(estimate(threeDays+threeDays+[quiet]).value==supported.value && estimate(threeDays+threeDays+[quiet]).baselineDays==3,"duplicate prior readings cannot inflate day count or score")
let foreign=threeDays.map{heart($0.bpm,$0.date,true,"other")}
check(!estimate(foreign+[quiet]).channels.contains("安静心率"),"quiet baseline still cannot cross devices")
check(estimate(threeDays+[heart(30,day.addingTimeInterval(60)),quiet]).value==supported.value,"same-day resting total cannot leak into earlier quiet-HR baseline")
let cutoff=cal.date(byAdding:.day,value:-28,to:day)!
let atBoundary=[heart(60,cutoff),heart(60,cutoff.addingTimeInterval(86400)),heart(60,cutoff.addingTimeInterval(2*86400))]
check(estimate(atBoundary+[quiet]).baselineDays==3,"28-local-day lower boundary is consistently included")
let tooOld=[heart(60,cutoff.addingTimeInterval(-1))]+Array(atBoundary.suffix(2))
check(!estimate(tooOld+[quiet]).channels.contains("安静心率"),"before-window records cannot establish third baseline date")
let neutral=estimate([heart(60,now,false)])
for hours in [0.01,0.25,1,4,7.5,8,10] {
 let sleep=BatteryHour(start:now.addingTimeInterval(-12*3600),end:now,sleepHours:hours,activeKcal:nil,heartRate:nil,heartRateCount:0)
 let state=estimate([heart(60,now,false)],[sleep])
 check(state.value==neutral.value && !state.channels.contains("已记录睡眠"),"incomplete sleep record of \(hours) hours cannot imply deprivation or automatic recovery")
 check(state.note.contains("记录完整性未知"),"partial sleep completeness is disclosed for \(hours) hours")
}
let active=BatteryHour(start:now.addingTimeInterval(-3600),end:now,sleepHours:0,activeKcal:123,heartRate:nil,heartRateCount:0)
let activity=estimate(threeDays+[quiet],[active])
check(activity.value<supported.value && activity.factors!.contains{$0.key=="activity" && close($0.points,-1.23)},"actual activity correction is retained and explained independently")
for state in [insufficient,supported,neutral,activity] {
 check(close(state.factors!.reduce(0){$0+$1.points},Double(state.value)),"signed factors including rounding reconcile to displayed state \(state.value)")
 check(state.factors!.filter{$0.key=="prior"}.count==1 && state.factors!.first!.points==65,"initial engineering assumption is explicit for state \(state.value)")
 check(state.modelRevision==CurrentStateModel.revision,"revised recent-state result has independent model identity")
}
check(activity.factors!.first{$0.key=="quietHR"}!.baselineDays==3,"factor records baseline dates used rather than raw sample count")
let encoded=try JSONEncoder().encode(activity),roundtrip=try JSONDecoder().decode(CurrentStateEstimate.self,from:encoded)
check(roundtrip.factors!.count==activity.factors!.count && roundtrip.modelRevision==activity.modelRevision,"factor explanations and model identity survive phone-Watch serialization")
var oldObject=try JSONSerialization.jsonObject(with:encoded) as! [String:Any];oldObject.removeValue(forKey:"factors");oldObject.removeValue(forKey:"modelRevision")
let old=try JSONDecoder().decode(CurrentStateEstimate.self,from:JSONSerialization.data(withJSONObject:oldObject))
check(old.factors==nil && old.modelRevision==nil,"old recent-state cache decodes without fabricated historical factors")
let sleepStart=day.addingTimeInterval(-86400),sleepEnd=sleepStart.addingTimeInterval(8*3600)
let sleep=BatteryHour(start:sleepStart,end:sleepEnd,sleepHours:8,activeKcal:0,heartRate:55,heartRateCount:32,heartRateCoverageHours:8,personalHR:60,sleepHeartRate:55)
let reserve=BatteryModel.calculate(hours:[sleep],anchor:20,baselineHR:60,now:sleepEnd,policy:.continuous)
check(reserve.points.last!.value!>70 && reserve.points.last!.effect!.sleepRecharge>50,"continuous reserve retains recorded sleep recovery independent of partial-state fix")
// Fixed 60-minute training, 350 kcal and 60 observed paired minutes. Only clock alignment changes.
let origin=day.addingTimeInterval(8*3600),readAt=origin.addingTimeInterval(7200+60)
func shifted(_ offset:Int)->[BatteryHour] {
 let trainingStart=origin.addingTimeInterval(Double(offset)*60),trainingEnd=trainingStart.addingTimeInterval(3600)
 let samples=(0...60).map{WorkoutHeartSample(date:trainingStart.addingTimeInterval(Double($0)*60),bpm:160,source:"watch")}
 return (0..<2).map { index in
  let start=origin.addingTimeInterval(Double(index)*3600),end=start.addingTimeInterval(3600)
  let duration=max(0,min(end,trainingEnd).timeIntervalSince(max(start,trainingStart)))/3600
  let spans=WorkoutHeartFallback.make(samples:samples,windows:[(trainingStart,trainingEnd)],start:start,end:end,now:readAt,reference:60,source:"watch")
  return BatteryHour(start:start,end:end,sleepHours:0,activeKcal:350*duration,heartRate:duration>0 ? 160:nil,heartRateCount:duration>0 ? Int(duration*60)+1:0,heartRateCoverageHours:duration,workoutHours:duration,personalHR:60,awakeHeartRate:duration>0 ? 160:nil,awakeHeartRateCount:duration>0 ? Int(duration*60)+1:0,awakeHeartRateCoverageHours:duration,workoutHeartSpans:spans)
 }
}
var offsets:[[String:Any]]=[]
var formalValues:[Double]=[]
for offset in [0,1,3,4,5,15,30,45,55,56,57,59] {
 let rows=shifted(offset),decisions=rows.compactMap{ActivityFusionEngine.decision(hour:$0,now:readAt,policy:.cardioEnergyV1)}
 let formal=BatteryModel.calculate(hours:rows,anchor:80,baselineHR:60,now:readAt,policy:.continuous),candidate=BatteryModel.calculate(hours:rows,anchor:80,baselineHR:60,now:readAt,policy:.continuous,activityExperiment:.cardioEnergyV1)
 formalValues.append(formal.points.compactMap(\.value).last!)
 check(close(rows.reduce(0){$0+($1.activeKcal ?? 0)},350) && close(rows.reduce(0){$0+($1.workoutHours ?? 0)*60},60),"offset \(offset) preserves measured energy and workout duration")
 let actualMinutes=rows.flatMap{$0.workoutHeartSpans ?? []}.reduce(0){$0+$1.end.timeIntervalSince($1.start)/60}
 check(close(actualMinutes,60),"offset \(offset) preserves actual paired HR coverage")
 let expectedCoverage=offset==0 ? 60:offset<=3 ? Double(60-offset):offset>=57 ? Double(offset):0
 check(close(decisions.reduce(0){$0+$1.coveredMinutes},expectedCoverage),"offset \(offset) documents restrictive shadow eligibility without relaxing provenance")
 offsets.append(["offsetMinutes":offset,"workoutMinutes":60,"kcal":350,"observedHRMinutes":actualMinutes,"eligibleHRMinutes":decisions.reduce(0){$0+$1.coveredMinutes},"formal":formal.points.compactMap(\.value).last!,"shadow":candidate.points.compactMap(\.value).last!])
}
check(formalValues.allSatisfy{close($0,formalValues[0])},"default reserve result is invariant to these controlled training clock offsets")
if CommandLine.arguments.count>1 {
 let proof:[String:Any]=["syntheticOnly":true,"stateModel":CurrentStateModel.revision,"oneDayPriorBefore":56,"oneDayPriorAfter":insufficient.value,"partialSleepBefore":57,"partialSleepAfter":neutral.value,"shadowClockEligibilityBiasConfirmed":true,"shadowEnabled":false,"formalOffsetInvariant":true,"offsets":offsets,"checks":checks]
 try JSONSerialization.data(withJSONObject:proof,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
}
print("\(checks) algorithm validity checks passed; synthetic regression evidence only")
