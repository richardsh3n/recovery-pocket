import Foundation
var checks=0
func check(_ condition:@autoclosure()->Bool,_ name:String){precondition(condition(),name);checks+=1;print("PASS: "+name)}
let now=Date(),source="synthetic-meaning"
let single=StateHeartSignal(date:now,bpm:65,resting:false,context:"安静候选",source:source)
let initial=BatteryLedger(baselineHR:nil,hours:[],sourceKey:source,stateSignals:[single],stateHRV:[],continuousVersion:1).status(now:now)
check(initial.value==65 && initial.scoreMeaning.kind == .initialState,"first observation remains visible but is classified as an initial reference")
check(initial.scoreMeaning.title=="起始参考" && initial.scoreMeaning.qualifier.contains("未个性化"),"initial title discloses lack of individual comparison next to score")
check(initial.scoreMeaning.symbol != "battery.75percent","initial physiological reference is not represented by a battery icon")
let initialWidget=PocketWidgetPresentation(status:initial,at:now)
check(initialWidget.title==initial.scoreMeaning.title && initialWidget.value==65 && !initialWidget.showTotals,"widget shares initial semantics without fabricating recharge or drain")
check(initialWidget.symbol==initial.scoreMeaning.symbol && initialWidget.detail.contains("起始参考"),"compact widget icon and observation line retain initial meaning")
let activity=BatteryHour(start:now.addingTimeInterval(-3600),end:now,sleepHours:0,activeKcal:300,heartRate:nil,heartRateCount:0)
var activeInitial=initial;let activeEstimate=CurrentStateModel.estimate(signals:[single],hrv:[],hours:[activity],now:now)!;activeInitial.stateEstimate=activeEstimate;activeInitial.value=activeEstimate.value;activeInitial.lower=activeEstimate.lower;activeInitial.upper=activeEstimate.upper
check(activeInitial.scoreMeaning.kind == .initialState && activeInitial.value==62,"actual activity correction alone cannot claim personal physiological baseline")
let prior=(1...15).map{StateHeartSignal(date:Calendar.current.date(byAdding:.day,value:-$0,to:now)!,bpm:60,resting:true,context:"静息",source:source)}
let personal=BatteryLedger(baselineHR:60,hours:[],sourceKey:source,stateSignals:prior+[StateHeartSignal(date:now,bpm:60,resting:true,context:"静息",source:source)],stateHRV:[],continuousVersion:1).status(now:now)
check(personal.scoreMeaning.kind == .personalState && personal.value==initial.value,"equal numeric scores retain different evidence meanings")
check(personal.scoreMeaning.title=="状态参考" && personal.scoreMeaning.qualifier.contains("未校准"),"personal comparison is not described as calibrated recovery")
check(personal.scoreMeaning.symbol=="waveform.path.ecg","personal state uses shared physiological reference symbol")
check(PocketWidgetPresentation(status:personal,at:now).title==personal.scoreMeaning.title,"widget and phone use the same personal-state title")
var legacy=personal;legacy.stateEstimate!.modelRevision=nil;legacy.stateEstimate!.factors=nil
check(legacy.scoreMeaning.kind == .legacyState && legacy.scoreMeaning.title=="旧版状态","old sidecar without new provenance is never silently labelled personal")
var corrupt=personal;corrupt.stateEstimate!.factors![1].points += 1
check(corrupt.scoreMeaning.kind == .legacyState,"inconsistent factor metadata cannot earn personal-comparison label")
var demo=initial;demo.demo=true
check(demo.scoreMeaning.kind == .initialState && PocketWidgetPresentation(status:demo,at:now).title=="演示","demo marking remains explicit while evidence classification is preserved")
check(PocketWidgetPresentation(status:demo,at:now).detail.contains("起始参考"),"demo widget retains prior nature in observation text")
let expired=PocketWidgetPresentation(status:initial,at:now.addingTimeInterval(6*3600))
check(expired.title=="已过期" && expired.value==nil && !expired.showTotals,"initial-reference label cannot keep expired data alive")
let interval=BatteryHour(start:now.addingTimeInterval(-3600),end:now,sleepHours:0,activeKcal:50,heartRate:80,heartRateCount:12,heartRateCoverageHours:1,personalHR:60)
let reserve=BatteryModel.calculate(hours:[interval],anchor:80,baselineHR:60,now:now)
check(reserve.scoreMeaning.kind == .reserve && reserve.scoreMeaning.title=="身体电量","accumulated reserve retains its established interpretation")
check(PocketWidgetPresentation(status:reserve,at:now).showTotals && reserve.scoreMeaning.symbol=="battery.75percent","reserve alone keeps battery icon and net totals")
let context=CoachContext(now:now,snapshotAt:now,battery:initial,nights:[],workouts:[],hrv:[],target:8,selfRating:nil,demo:false)
let brief=context.brief(.today),state=brief.facts.first{$0.key=="state"}!
check(state.name==initial.scoreMeaning.title && state.detail.contains("中性起始假设"),"AI and local coach evidence explicitly name initial engineering prior")
check(state.detail.contains("不能用来认定恢复正常"),"coach cannot receive an unqualified personal recovery claim from initial state")
check(brief.promptEvidence.contains("起始参考"),"exportable coach evidence keeps the same meaning without changing score")
let decoded=try JSONDecoder().decode(PocketStatus.self,from:JSONEncoder().encode(personal))
check(decoded.scoreMeaning.kind==personal.scoreMeaning.kind && decoded.displayValue(at:now)==personal.value,"shared serialization preserves evidence-based interpretation and displayed value")
if CommandLine.arguments.count>1 {
 let proof:[String:Any]=["syntheticOnly":true,"checks":checks,"initialValue":initial.value!,"personalValue":personal.value!,"initialTitle":initial.scoreMeaning.title,"personalTitle":personal.scoreMeaning.title,"reserveTitle":reserve.scoreMeaning.title,"scoringChanged":false,"newAITransmission":false]
 try JSONSerialization.data(withJSONObject:proof,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
}
print("\(checks) shared score-meaning checks passed; wording and evidence boundaries, not physiological accuracy")
