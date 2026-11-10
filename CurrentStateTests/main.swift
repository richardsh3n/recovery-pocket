import Foundation
var checks=0
func check(_ value:@autoclosure()->Bool,_ name:String){guard value() else{fatalError(name)};checks+=1;print("PASS: "+name)}
let calendar=Calendar.current,day=calendar.startOfDay(for:Date()),now=day.addingTimeInterval(12*3600)
func heart(_ bpm:Double,_ date:Date = now,resting:Bool=true,source:String="watch-A",context:String="安静候选")->StateHeartSignal { StateHeartSignal(date:date,bpm:bpm,resting:resting,context:context,source:source) }
let baseline=(1...15).map{heart(60,calendar.date(byAdding:.day,value:-$0,to:now)!)}
func estimate(_ hearts:[StateHeartSignal],hrv:[HRVObservation]=[],hours:[BatteryHour]=[],date:Date=now)->CurrentStateEstimate? { CurrentStateModel.estimate(signals:hearts,hrv:hrv,hours:hours,now:date) }
check(estimate([])==nil,"no records do not produce zero or an invented score")
let initial=estimate([heart(60,resting:false)])!
check(initial.value==65 && initial.lower<=35 && initial.upper>=95,"first HR permits explicitly broad neutral initial estimate")
check(initial.note.contains("中性初始"),"initial state cannot masquerade as calibrated recovery")
let normal=estimate(baseline+[heart(60)])!,high=estimate(baseline+[heart(75)])!
check(high.value<normal.value,"elevated resting HR versus own prior baseline reduces state")
check(normal.channels.contains("静息心率") && !normal.channels.contains("HRV"),"missing HRV allows independent resting HR estimate")
check(normal.note.contains("睡眠记录缺失"),"missing sleep is explicitly a gap, not continuous wakefulness")
check(normal.value==65,"a week without recorded sleep does not accumulate a floor penalty")
check(normal.baselineDays==15,"past-only personal daily baseline counted")
check(estimate(baseline+[heart(75)],date:now.addingTimeInterval(1800))!.value==high.value,"refreshing without new signals cannot manufacture recovery")
check(estimate(baseline+[heart(60,now.addingTimeInterval(1))])==nil,"future measurement cannot appear current")
check(estimate([heart(60,now.addingTimeInterval(-6*3600))])==nil,"six-hour-old signal expires")
check(estimate([heart(.nan)])==nil && estimate([heart(230)])==nil,"invalid heart signals rejected")
check(estimate([heart(60,source:"")])==nil,"unidentified source is not a current signal")
let mixed=estimate(baseline.map{heart($0.bpm,$0.date,source:"watch-B")}+[heart(75)])!
check(!mixed.channels.contains("静息心率"),"another device cannot silently supply resting baseline")
let afterFuture=estimate(baseline+[heart(75),heart(30,now.addingTimeInterval(86400))])!
check(afterFuture.value==high.value,"future baseline cannot change prior state")
func hrv(_ value:Double,_ date:Date,context:String="安静候选",source:String="watch-A",seconds:Double=60,id:UUID=UUID())->HRVObservation { HRVObservation(id:id,start:date.addingTimeInterval(-seconds),end:date,sdnn:value,context:context,source:source) }
let oldHRV=(1...15).map{hrv(50,calendar.date(byAdding:.day,value:-$0,to:now)!)}
let low=hrv(25,now)
let lowHRV=estimate([],hrv:oldHRV+[low])!
check(lowHRV.channels.contains("HRV") && lowHRV.value<65,"matched SDNN affects the recent state")
let activityPrior=(1...15).map{hrv(50,calendar.date(byAdding:.day,value:-$0,to:now)!,context:"活动时段")}
let activityHRV=estimate([],hrv:activityPrior+[hrv(25,now,context:"活动时段")])!
check(activityHRV.value>lowHRV.value && activityHRV.channels.contains("HRV"),"activity HRV contributes with reduced weight against activity history")
check(activityHRV.note.contains("降低权重"),"movement confound remains visible")
let mismatch=estimate([],hrv:oldHRV+[hrv(25,now,context:"活动时段")])!
check(!mismatch.channels.contains("HRV"),"quiet baseline is not applied to an activity sample")
let sourceMismatch=estimate([],hrv:oldHRV+[hrv(25,now,source:"watch-B")])!
check(!sourceMismatch.channels.contains("HRV"),"HRV cannot compare across device sources")
check(estimate([],hrv:[hrv(50,now,context:"训练附近")])==nil,"training-only HRV cannot invent resting readiness")
check(estimate([],hrv:[hrv(50,now,context:"呼吸练习")])==nil,"breathwork-only HRV cannot invent resting readiness")
check(estimate([],hrv:[hrv(50,now,seconds:0)])==nil,"instantaneous SDNN without duration is not comparable")
check(estimate([],hrv:oldHRV+[low,low])!.value==lowHRV.value,"duplicate HRV UUID does not add influence")
check(estimate([],hrv:oldHRV+[hrv(500,now)])!.value<100,"extreme high HRV cannot yield an unlimited recovery reward")
let hour=BatteryHour(start:now.addingTimeInterval(-3600),end:now,sleepHours:0,activeKcal:400,heartRate:nil,heartRateCount:0,workoutHours:1)
let active=estimate(baseline+[heart(60)],hours:[hour])!
check(active.value==normal.value-4,"recorded activity included once without extra workout penalty")
check(estimate(baseline+[heart(60)],hours:[hour,hour])!.value==active.value,"duplicate hour does not double calorie penalty")
var invalidHour=hour;invalidHour.sleepHours = .nan;invalidHour.activeKcal = .infinity
check(estimate(baseline+[heart(60)],hours:[invalidHour])!.value==normal.value,"nonfinite ancillary records cannot poison the estimate")
let midnight=calendar.date(byAdding:.day,value:1,to:day)!
let crossing=estimate([heart(60,midnight.addingTimeInterval(-1800))],date:midnight)!
check(crossing.isUsable(at:midnight),"recent observations remain usable across local midnight")
var ledger=BatteryLedger(baselineHR:60,hours:[hour],sourceKey:"watch-A",stateSignals:baseline+[heart(60)],stateHRV:[])
let state=ledger.status(now:now)
check(state.usesStateEstimate && state.value==active.value,"reserve without sleep switches to current state")
check(state.displayValue(at:now)==state.stateEstimate?.value,"phone Watch and widgets use the same state value")
check(!PocketWidgetPresentation(status:state,at:now).showTotals,"state estimate cannot show reserve charging and draining totals")
check(PocketWidgetSchedule.dates(status:state,now:now).last==now.addingTimeInterval(6*3600),"state widget uses its explicit six-hour expiry")
check(state.displayValue(at:now.addingTimeInterval(6*3600))==nil,"expired state hidden without becoming zero")
let encoded=try JSONEncoder().encode(state);let decoded=try JSONDecoder().decode(PocketStatus.self,from:encoded)
check(decoded.displayValue(at:now)==state.displayValue(at:now),"state survives phone-to-Watch serialization")
let history=ledger.stateHistory(now:now)
check(history.allSatisfy{$0.date<=now && $0.mode.contains("非电量收支")},"historical state points are timestamped estimates, not reserve changes")
let oldEncoded=try JSONEncoder().encode(BatteryLedger(baselineHR:60,hours:[hour],sourceKey:"watch-A"))
let oldDecoded=try JSONDecoder().decode(BatteryLedger.self,from:oldEncoded)
check(oldDecoded.stateSignals==nil,"legacy ledger still decodes")
print("\(checks) current-state checks passed; engineering model, not physiological validation.")
