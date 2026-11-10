import Foundation
var checks=0
func check(_ condition:@autoclosure()->Bool,_ name:String){precondition(condition(),name);checks+=1;print("PASS: "+name)}
func close(_ a:Double,_ b:Double)->Bool{abs(a-b)<1e-8}
var cal=Calendar(identifier:.gregorian);cal.timeZone=TimeZone(secondsFromGMT:0)!
let day=cal.startOfDay(for:Date(timeIntervalSince1970:1_792_396_800)),begin=day.addingTimeInterval(8*3600),end=begin.addingTimeInterval(3600)
func samples(_ rate:Double,_ minutes:Int=60,_ source:String="watch")->[WorkoutHeartSample]{(0...minutes).map{WorkoutHeartSample(date:begin.addingTimeInterval(Double($0)*60),bpm:rate,source:source)}}
func make(_ rows:[WorkoutHeartSample],_ windows:[(start:Date,end:Date)]?=nil,_ reference:Double?=60,_ source:String?="watch")->[WorkoutHeartSpan]{WorkoutHeartFallback.make(samples:rows,windows:windows ?? [(begin,end)],start:begin,end:end,now:end,reference:reference,source:source)}
func integral(_ spans:[WorkoutHeartSpan],maximum:Double=1)->Double{WorkoutHeartFallback.strainHours(spans,start:begin,end:end,now:end,maximumHours:maximum)}
func bin(_ rate:Double=160,kcal:Double?=nil,spans:Bool=true)->BatteryHour{
 BatteryHour(start:begin,end:end,sleepHours:0,activeKcal:kcal,heartRate:rate,heartRateCount:61,heartRateCoverageHours:1,workoutHours:1,personalHR:60,awakeHeartRate:rate,awakeHeartRateCount:61,awakeHeartRateCoverageHours:1,workoutHeartSpans:spans ? make(samples(rate)) : nil)
}
func status(_ row:BatteryHour,params:BatteryModelParameters = .standard)->PocketStatus{BatteryModel.calculate(hours:[row],anchor:80,baselineHR:60,now:end,calendar:cal,policy:.continuous,parameters:params)}
func value(_ row:BatteryHour)->Double{status(row).points.last!.value!}
let low=bin(100),high=bin(160)
check(close(integral(make(samples(100))),25.0/15),"HR100 integrates existing capped HR proxy over actual time")
check(close(integral(make(samples(160))),3),"HR160 remains bounded at existing strain cap")
check(value(high)<value(low),"missing energy no longer suppresses different actual training HR")
check(close(status(high).inputs!.workoutHeartFallbackDrain!,2.1),"fallback reuses existing HR coefficient rather than a new battery conversion")
check(close(status(high).points.last!.effect!.activityDrain,0),"fallback does not fabricate calories")
check(close(value(bin(100,kcal:300)),value(bin(160,kcal:300))),"recorded calories disable additional training HR drain")
check(close(status(bin(160,kcal:300)).inputs!.workoutHeartFallbackDrain!,0),"no fallback when calorie evidence exists")
check(close(status(bin(160,kcal:0)).inputs!.workoutHeartFallbackDrain!,0),"recorded zero is distinct from missing energy")
check(close(value(bin(160,kcal:300)),70.32857142857142),"existing 300kcal trajectory is preserved")
check(close(value(bin(160,spans:false)),78.9),"old workout ledger with no paired HR evidence remains conservative")
check(status(bin(160)).modelRevision != nil,"model remains labelled")
check(close(integral(make(samples(160)+samples(160))),3),"duplicate HR samples do not double strain")
check(close(integral(make(Array(samples(160).reversed()))),3),"sample input ordering does not affect integration")
check(integral(make(samples(160,60,"other")))==0,"wrong HR source cannot supply fallback")
check(integral(make(samples(160),nil,nil))==0,"no personal reference means no fallback")
check(integral(make(samples(160),nil,.nan))==0,"nonfinite reference is rejected")
check(integral(make(samples(160),nil,60,nil))==0,"unknown stream identity is rejected")
check(integral(make([samples(160)[0]]))==0,"isolated HR never implies workout duration")
let sparse=(0...12).map{WorkoutHeartSample(date:begin.addingTimeInterval(Double($0)*300),bpm:160,source:"watch")}
check(integral(make(sparse))==0,"five-minute gaps receive no cardiac interpolation")
let half=make(samples(160,30))
check(close(integral(half),1.5),"half observed workout has half the supported proxy")
let overlapping=make(samples(160),[(begin,end),(begin.addingTimeInterval(600),end)])
check(close(integral(overlapping),3),"overlapping workouts share the same observed spans")
let slept=WorkoutHeartFallback.make(samples:samples(160),windows:[(begin,end)],excluding:[(begin.addingTimeInterval(900),begin.addingTimeInterval(2700))],start:begin,end:end,now:end,reference:60,source:"watch")
check(close(integral(slept),1.5),"recorded sleep is excluded from training HR support")
let future=samples(160)+[WorkoutHeartSample(date:end.addingTimeInterval(30),bpm:220,source:"watch")]
check(close(integral(make(future)),3),"samples beyond bin cutoff cannot change past interval")
let futureOnly=[WorkoutHeartSample(date:begin,bpm:160,source:"watch"),WorkoutHeartSample(date:end.addingTimeInterval(30),bpm:160,source:"watch")]
check(integral(make(futureOnly))==0,"future-only endpoint cannot create coverage")
let malformed=samples(.nan)+samples(500)
check(make(malformed).isEmpty,"nonfinite and invalid HR are rejected")
check(close(integral(overlapping+overlapping),3),"duplicate saved spans cannot double count")
var mixed=make(samples(160));mixed[0].source="other"
check(integral(mixed)==0,"mixed-source saved spans do not create a fused fallback")
var differentReference=make(samples(160));differentReference[0].referenceHR=70
check(integral(differentReference)==0,"mixed references do not create a fused fallback")
check(integral(make(samples(160)),maximum:0.5)==0,"inconsistent workout duration cannot inflate strain")
var noWorkout=high;noWorkout.workoutHours=0
check(status(noWorkout).inputs!.workoutHeartFallbackDrain==0,"spans without recorded workout support are inactive")
var sleep=high;sleep.sleepHours=1
check(status(sleep).inputs!.workoutHeartFallbackDrain==0,"sleep-only hour cannot consume workout HR proxy")
let legacyResult=BatteryModel.calculate(hours:[high],anchor:80,baselineHR:60,now:end,policy:.legacy)
check(legacyResult.points.last!.effect!.heartRateDrain==0,"legacy policy retains previous behaviour")
let data=try JSONEncoder().encode(high),restored=try JSONDecoder().decode(BatteryHour.self,from:data)
check(restored==high && close(value(restored),value(high)),"paired training support survives ledger serialization")
var oldObject=try JSONSerialization.jsonObject(with:data) as! [String:Any];oldObject.removeValue(forKey:"workoutHeartSpans")
let old=try JSONDecoder().decode(BatteryHour.self,from:JSONSerialization.data(withJSONObject:oldObject))
check(old.workoutHeartSpans==nil && close(value(old),78.9),"old JSON remains readable and is not backfilled with invented HR")
let effect=status(high).points.last!.effect!
check(close(value(high)-80,effect.sleepRecharge+effect.restRecharge-effect.awakeDrain-effect.activityDrain-effect.heartRateDrain-effect.hrvDrain+(effect.boundaryAdjustment ?? 0)),"fallback remains inside reconciling effect ledger")
let decoded=try JSONDecoder().decode(PocketStatus.self,from:JSONEncoder().encode(status(high)))
check(close(decoded.inputs!.workoutHeartFallbackDrain!,2.1),"fallback provenance travels with shared phone-Watch-widget summary")
let pinned=BatteryOrigin(bucketStart:begin,date:begin.addingTimeInterval(1800),value:80,uncertainty:30,reason:"test")
let clipped=ContinuousBatteryModel.calculate(hours:[high],signals:[],hrv:[],baselineHR:60,now:end,calendar:cal,origins:[pinned])
check(close(clipped.inputs!.workoutHeartFallbackDrain!,1.05),"first-bin origin clips actual spans and excludes earlier training")
let doubled=ContinuousBatteryModel.calculate(hours:[high,high],signals:[],hrv:[],baselineHR:60,now:end,anchorOverride:80,calendar:cal)
check(close(doubled.inputs!.workoutHeartFallbackDrain!,2.1),"continuous duplicate bins cannot repeat fallback")
let reference=ContinuousBatteryModel.calculate(hours:[high],signals:[],hrv:[],baselineHR:60,now:end,anchorOverride:80,calendar:cal)
check(reference.modelRevision!.contains("0.28") && reference.modelRevision!.contains("daily state baseline"),"new continuous revision separates future feedback pairs")
let experiment=ContinuousBatteryModel.calculate(hours:[high],signals:[],hrv:[],baselineHR:60,now:end,anchorOverride:80,calendar:cal,parameters:BatteryModelParameters(sleepRecoveryHours:4.5))
check(experiment.modelRevision!.contains("offline parameter sensitivity"),"offline variants cannot masquerade as standard model revision")
let broken=BatteryModelParameters(sleepRecoveryHours:.nan,quietRecoveryHours:0,kcalPerPoint:.infinity)
check(broken.safe == .standard,"invalid experimental settings fall back to finite standard values")
check(status(bin(160,kcal:300),params:broken).value==status(bin(160,kcal:300)).value,"invalid tuning cannot poison default result")
let fabricated=[WorkoutHeartSpan(start:begin,end:end,strain:3,referenceHR:60,source:"watch")]
check(integral(fabricated)==0,"saved hour-long HR span cannot impersonate an actual 90-second pair")
var conflicting=make(samples(160));var alternative=conflicting[0];alternative.strain=1
check(close(integral(conflicting+[alternative]),integral([alternative]+Array(conflicting.reversed()))),"overlapping saved duplicates have deterministic conservative ordering")
// Freeze a reproducible scenario matrix; it explores engineering assumptions only.
func schedule()->[BatteryHour]{(0..<24).map{i in let asleep=i<8;return BatteryHour(start:day.addingTimeInterval(Double(i)*3600),end:day.addingTimeInterval(Double(i+1)*3600),sleepHours:asleep ? 1 : 0,activeKcal:asleep ? 0 : i<20 ? 50 : 0,heartRate:asleep || i>=20 ? 60 : 80,heartRateCount:60,heartRateCoverageHours:1,workoutHours:0,steps:asleep || i>=20 ? 0 : 200,personalHR:60,awakeHeartRate:asleep ? nil : i>=20 ? 60 : 80,awakeHeartRateCount:asleep ? 0 : 60,awakeHeartRateCoverageHours:asleep ? 0 : 1)}}
let scenarios:[(String,BatteryModelParameters)]=[("standard",.standard),("sleep-25pct",BatteryModelParameters(sleepRecoveryHours:4.5)),("sleep+25pct",BatteryModelParameters(sleepRecoveryHours:7.5)),("rest-25pct",BatteryModelParameters(quietRecoveryHours:10.5)),("rest+25pct",BatteryModelParameters(quietRecoveryHours:17.5)),("kcalPerPoint-25pct",BatteryModelParameters(kcalPerPoint:26.25)),("kcalPerPoint+25pct",BatteryModelParameters(kcalPerPoint:43.75))]
var matrix:[[String:Any]]=[]
for (name,param) in scenarios {
 let rows=schedule(),result=BatteryModel.calculate(hours:rows,anchor:50,baselineHR:60,now:rows.last!.end,calendar:cal,policy:.continuous,parameters:param)
 check(result.points.compactMap(\.value).allSatisfy{$0.isFinite && (5...100).contains($0)},"sensitivity scenario remains finite: "+name)
 matrix.append(["variant":name,"end":result.points.last!.value!,"afterSleep":result.points.first{$0.date==day.addingTimeInterval(8*3600)}!.value!])
}
check(matrix.count==7,"single-factor parameter sensitivity matrix is complete")
let output:[String:Any]=["checks":checks,"scope":"Synthetic engineering sensitivity and fallback checks; no physiological calibration","missingEnergyLowHREnd":value(low),"missingEnergyHighHREnd":value(high),"recorded300KcalLowHREnd":value(bin(100,kcal:300)),"recorded300KcalHighHREnd":value(bin(160,kcal:300)),"fallbackHighHR":2.1,"sensitivity":matrix]
if CommandLine.arguments.count>1 {try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys,.prettyPrinted]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))}
print("\(checks) intensity response and sensitivity checks passed")
