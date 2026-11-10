import Foundation
var checks=0
func check(_ condition:@autoclosure()->Bool,_ name:String){precondition(condition(),name);checks+=1;print("PASS: "+name)}
let now=Date(timeIntervalSince1970:1793419200),prior=(1...15).map{StateHeartSignal(date:now.addingTimeInterval(-Double($0)*86400),bpm:60,resting:true,context:"静息",source:"watch")}
let current=StateHeartSignal(date:now,bpm:75,resting:true,context:"静息",source:"watch")
let ledger=BatteryLedger(baselineHR:60,hours:[],sourceKey:"watch",stateSignals:prior+[current],stateHRV:[],continuousVersion:1)
let modern=ledger.status(now:now)
check(modern.usesStateEstimate && RecentStateCachePolicy.compatible(modern),"new state has compatible factor and summary metadata")
check(RecentStateCachePolicy.reusable(modern,at:now),"current compatible cache may be reused without creating new observation")
check(!RecentStateCachePolicy.reusable(modern,at:now.addingTimeInterval(-1)),"future-dated current state cannot be reused")
check(!RecentStateCachePolicy.reusable(modern,at:now.addingTimeInterval(6*3600)),"exact six-hour expiry cannot be refreshed by cache reuse")
check(RecentStateCachePolicy.presentation(modern).displayValue(at:now)==modern.value,"valid new cached state keeps its displayed score")
var old=modern;old.stateEstimate!.modelRevision=nil;old.stateEstimate!.factors=nil
let encodedBefore=try JSONEncoder.iso.encode(old),hidden=RecentStateCachePolicy.presentation(old),encodedAfter=try JSONEncoder.iso.encode(old)
check(!RecentStateCachePolicy.compatible(old),"old state missing model identity and factors needs recomputation")
check(hidden.displayValue(at:now)==nil && hidden.value==nil && hidden.stateEstimate==nil,"old state is withheld instead of briefly showing obsolete score")
check(hidden.value != 0 && hidden.message.contains("重新计算"),"awaiting recomputation is explicit missing state rather than zero battery")
check(encodedBefore==encodedAfter,"presentation policy never mutates saved source object")
check(hidden.reserveValue==old.reserveValue && hidden.points.count==old.points.count,"diagnostic reserve and history payloads remain intact")
var mismatched=modern;mismatched.value=99
check(!RecentStateCachePolicy.compatible(mismatched),"cached headline inconsistent with nested estimate cannot be reused")
mismatched=modern;mismatched.lower=0
check(!RecentStateCachePolicy.compatible(mismatched),"summary and estimate uncertainty bounds must agree")
mismatched=modern;mismatched.measuredAt=now.addingTimeInterval(-60)
check(!RecentStateCachePolicy.compatible(mismatched),"summary and estimate observation timestamps must agree")
mismatched=modern;mismatched.stateEstimate!.factors![1].points += 1
check(!RecentStateCachePolicy.compatible(mismatched),"factor sum inconsistent with score prevents old-cache display")
mismatched=modern;mismatched.stateEstimate!.factors!.append(mismatched.stateEstimate!.factors!.last!)
check(!RecentStateCachePolicy.compatible(mismatched),"duplicated factor identities cannot masquerade as valid decomposition")
mismatched=modern;mismatched.stateEstimate!.factors![0].points = 64
check(!RecentStateCachePolicy.compatible(mismatched),"altered initial engineering prior cannot inherit current model version")
mismatched=modern;mismatched.stateEstimate!.modelRevision="0.13 / previous state"
check(!RecentStateCachePolicy.compatible(mismatched),"explicit previous model cannot be reused even with plausible factors")
mismatched=modern;mismatched.stateEstimate!.baselineDays = -1
check(!RecentStateCachePolicy.compatible(mismatched),"negative comparable date count is invalid cache metadata")
mismatched=modern;mismatched.stateEstimate!.factors![1].baselineDays = -1
check(!RecentStateCachePolicy.compatible(mismatched),"negative factor baseline dates are rejected")
mismatched=modern;mismatched.stateEstimate!.lower=90;mismatched.lower=90
check(!RecentStateCachePolicy.compatible(mismatched),"lower bound above estimate is invalid even if headline matches it")
mismatched=modern;mismatched.stateEstimate!.upper=110;mismatched.upper=110
check(!RecentStateCachePolicy.compatible(mismatched),"range above one hundred is invalid cache")
mismatched=modern;mismatched.stateEstimate!.validUntil=now.addingTimeInterval(6*3600+1)
check(!RecentStateCachePolicy.compatible(mismatched),"cache cannot extend allowed measurement validity beyond six hours")
let stalePresentation=RecentStateCachePolicy.presentation(modern)
check(stalePresentation.stateEstimate != nil && stalePresentation.displayValue(at:now.addingTimeInterval(6*3600))==nil,"compatible expired summary remains historical but is not current")
var demo=modern;demo.demo=true
check(RecentStateCachePolicy.presentation(demo).value==nil && !RecentStateCachePolicy.reusable(demo,at:now),"real-health cache path cannot revive demo state")
let interval=BatteryHour(start:now.addingTimeInterval(-3600),end:now,sleepHours:0,activeKcal:100,heartRate:80,heartRateCount:12,heartRateCoverageHours:1,personalHR:60)
let reserve=BatteryModel.calculate(hours:[interval],anchor:80,baselineHR:60,now:now)
let retained=RecentStateCachePolicy.presentation(reserve)
check(retained.value==reserve.value && retained.modelRevision==reserve.modelRevision,"recent-state migration does not hide legacy reserve trajectories")
var mixed=reserve;mixed.reserveSupported=true;mixed.stateEstimate=old.stateEstimate
check(RecentStateCachePolicy.presentation(mixed).value==reserve.value,"old optional recent-state sidecar cannot erase supported reserve")
let recomputed=ledger.status(now:now)
check(recomputed.stateEstimate!.modelRevision==CurrentStateModel.revision && RecentStateCachePolicy.reusable(recomputed,at:now),"retained raw synthetic ledger rebuilds valid current state")
check(recomputed.measuredAt==modern.measuredAt,"recomputation preserves real observation timestamp")
let roundtrip=try JSONDecoder().decode(PocketStatus.self,from:JSONEncoder().encode(recomputed))
check(RecentStateCachePolicy.reusable(roundtrip,at:now) && roundtrip.value==recomputed.value,"phone-Watch-widget serialization preserves compatible rebuilt state")
check(RecentStateCachePolicy.presentation(.empty).value==nil,"empty cache stays missing without manufacturing a state")
if CommandLine.arguments.count>1 {
 let proof:[String:Any]=["syntheticOnly":true,"checks":checks,"oldCacheCurrentValueWithheld":true,"recomputedState":recomputed.value!,"recomputedMeasuredAtUnchanged":true,"sourceRecordsMutated":false,"supportedReservePreserved":true,"cacheReuseCannotExtendExpiry":true]
 try JSONSerialization.data(withJSONObject:proof,options:[.sortedKeys,.prettyPrinted]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
}
print("\(checks) state cache migration checks passed; no real-device delivery verification")
