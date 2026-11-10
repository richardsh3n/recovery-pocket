import Foundation
var checks=0
func check(_ condition:@autoclosure()->Bool,_ label:String){precondition(condition(),label);checks+=1}
func close(_ a:Double,_ b:Double)->Bool{abs(a-b)<0.000001}
var cal=Calendar(identifier:.gregorian);cal.timeZone=TimeZone(secondsFromGMT:0)!
let day=cal.startOfDay(for:Date(timeIntervalSince1970:1_792_396_800))
func hour(_ index:Int,sleep:Double=0,kcal:Double=20,hr:Double?=75,coverage:Double=0.8,workout:Double=0)->BatteryHour {
    BatteryHour(start:day.addingTimeInterval(Double(index)*3600),end:day.addingTimeInterval(Double(index+1)*3600),sleepHours:sleep,activeKcal:kcal,heartRate:hr,heartRateCount:hr == nil ? 0 : 12,heartRateCoverageHours:coverage,workoutHours:workout,steps:kcal>5 ? 200 : 0,personalHR:55,awakeHeartRate:sleep>0 ? nil : hr,awakeHeartRateCount:sleep>0 || hr == nil ? 0 : 12,awakeHeartRateCoverageHours:sleep>0 ? 0 : coverage,hrvSourceKey:"watch",hrvContextVersion:1,inferredNonSleepHours:sleep>0 ? 0 : coverage)
}
func model(_ hours:[BatteryHour],now:Date?=nil,signals:[StateHeartSignal]=[],hrv:[HRVObservation]=[],anchor:Double?=50)->PocketStatus {
    ContinuousBatteryModel.calculate(hours:hours,signals:signals,hrv:hrv,baselineHR:55,now:now ?? hours.map(\.end).max() ?? day,anchorOverride:anchor,calendar:cal)
}
let full=(0..<24).map{i in hour(i,sleep:i<8 ? 1 : 0,kcal:i<8 ? 0 : 65,hr:i<8 ? 55 : 90)}
let cycle=model(full)
let values=cycle.points.compactMap(\.value)
check(cycle.continuity != nil && !cycle.usesStateEstimate,"recorded hours use accumulated reserve")
check(values.max()!-values.min()!>30,"an observed sleep and demanding day can span more than 30 without rescaling")
check(cycle.points[8].value!>80,"recorded sleep replenishes depleted reserve progressively")
check(cycle.value!<60,"a demanding day depletes the carried morning reserve")
check(cycle.points.allSatisfy{$0.value.map{(5...100).contains($0)} ?? true},"bounded reserve")
for point in cycle.points where point.effect != nil {
    let previous=cycle.points.last{$0.date<point.date && $0.value != nil}!
    let e=point.effect!
    check(close(point.value!-previous.value!,e.sleepRecharge+e.restRecharge-e.awakeDrain-e.activityDrain-e.heartRateDrain-e.hrvDrain+(e.boundaryAdjustment ?? 0)),"each interval reconciles to its effects")
}
let chronological=model(Array(full.reversed()))
check(chronological.value==cycle.value,"input ordering does not change trajectory")
check(model(full+full).value==cycle.value,"duplicate bins cannot double drain")
let refreshed=model(full,now:full.last!.end.addingTimeInterval(1800))
check(refreshed.value==cycle.value,"refresh without new records cannot move reserve")
check(model(full+[hour(24,kcal:500)],now:full.last!.end).value==cycle.value,"future activity cannot alter prior reserve")
let next=hour(24,kcal:100)
let twoDays=model(full+[next])
let before=twoDays.points.first{$0.date==day.addingTimeInterval(24*3600)}!.value!
check(close(before,cycle.points.last!.value!),"midnight preserves previous reserve")
check(twoDays.continuity!.segmentCount==1,"midnight is not a reset boundary")
let midnightStatus=model([hour(23,kcal:5)],now:day.addingTimeInterval(24*3600+60))
check(midnightStatus.isFresh(at:day.addingTimeInterval(24*3600+60)),"fresh continuous estimate survives midnight")
let schedule=PocketWidgetSchedule.dates(status:midnightStatus,now:day.addingTimeInterval(24*3600+60))
check(schedule.last==midnightStatus.measuredAt!.addingTimeInterval(7201),"widget expiry agrees with continuous phone freshness")
let awake=(8..<20).map{hour($0,kcal:80)}
let missingSleep=model(awake)
check(!missingSleep.usesStateEstimate && missingSleep.points.last!.value!<missingSleep.points.first!.value!,"missing sleep no longer replaces accumulated daytime depletion with state score")
let blank=(0..<48).map{hour($0,kcal:0,hr:nil,coverage:0)}
let empty=model(blank)
check(empty.value==nil && empty.points.isEmpty,"unworn days do not create zero or simulated depletion")
let beforeGap=[hour(1,kcal:350)], afterGap=[hour(12,kcal:35,hr:75)]
let gapped=model(beforeGap+Array(blank[2..<12])+afterGap)
check(gapped.continuity!.segmentCount==2,"six-hour unknown interval explicitly restarts origin")
let gapStats=DailyBatteryStatistics.calculate(points:gapped.points,day:day,now:afterGap[0].end,calendar:cal)
check(gapStats.charged<1,"new origin cannot be counted as overnight recovery")
check(gapped.points.contains{$0.value==nil},"chart breaks across unobserved overnight time")
check(gapped.continuity!.note.contains("起点变化不计入"),"restart disclosed")
let direct=model([hour(1,kcal:350),hour(2,kcal:0,hr:nil,coverage:0),hour(3,kcal:35)])
check(direct.continuity!.segmentCount==1,"short gap carries reserve rather than resetting")
check(direct.points.contains{$0.value==nil},"short gap remains missing on chart")
var moving=hour(8,kcal:700,hr:150,workout:1)
let one=model([moving])
moving.workoutHours=0
check(model([moving]).value==one.value,"recorded workout calories are not charged twice")
var quiet=hour(8,kcal:0,hr:55,coverage:0.8)
let rested=model([quiet],anchor:30)
check(rested.value!>30,"supported quiet rest restores gradually without requiring sleep label")
check(rested.points.last!.effect!.awakeDrain==0,"rest window is not charged and depleted for the same base time")
quiet.inferredNonSleepHours=0;quiet.awakeHeartRateCoverageHours=0;quiet.heartRateCoverageHours=0
check(model([quiet],anchor:30).value==30,"a point HR reading cannot imply an entire hour of rest")
var lowSleep=hour(0,sleep:1,kcal:0,hr:55);lowSleep.sleepHRVZ = -2;lowSleep.sleepHRVCount=4;lowSleep.sleepHRVSampleWeight=4
var normalSleep=lowSleep;normalSleep.sleepHRVZ=0
check(model([lowSleep]).points.last!.value!<model([normalSleep]).points.last!.value!,"comparable low sleep HRV slows actual sleep recharge")
let dates=(0...6).map{day.addingTimeInterval(Double($0)*600)}
check(close(HeartRateCoverage.inferredHours(dates:dates,start:day,end:day.addingTimeInterval(3600)),1),"nearby sparse HR readings support explicitly inferred span")
check(HeartRateCoverage.inferredHours(dates:[day,day.addingTimeInterval(1800)],start:day,end:day.addingTimeInterval(3600))==0,"half-hour gap does not imply continuous wear")
check(HeartRateCoverage.inferredHours(dates:[day],start:day,end:day.addingTimeInterval(3600))==0,"isolated sample establishes no inferred duration")
check(close(HeartRateCoverage.inferredHours(dates:dates,start:day,end:day.addingTimeInterval(3600),sleep:[(day.addingTimeInterval(900),day.addingTimeInterval(2700))]),0.5),"real sleep is excluded from inferred non-sleep span")
let encoded=try JSONEncoder().encode(cycle);let decoded=try JSONDecoder().decode(PocketStatus.self,from:encoded)
check(decoded.continuity?.segmentCount==1 && decoded.value==cycle.value,"same continuous reserve survives phone-Watch-widget serialization")
let widget=PocketWidgetPresentation(status:cycle,at:full.last!.end)
check(widget.showTotals && widget.title=="身体电量","Watch and widgets retain accumulated reserve presentation")
var legacy=BatteryLedger(baselineHR:55,hours:awake,sourceKey:"watch",stateSignals:[],stateHRV:[])
legacy.continuousVersion=1
check(legacy.status(now:awake.last!.end).continuity != nil,"production ledger routes into continuous model after migration")
var live = hour(9,kcal:2,hr:55,coverage:0.1)
live.end=live.start.addingTimeInterval(600);live.latestSignalAt=live.end
var liveLedger=BatteryLedger(baselineHR:55,hours:[live],sourceKey:"watch",continuousVersion:1)
var unchanged=live;unchanged.end=unchanged.start.addingTimeInterval(1800)
liveLedger.merge([unchanged])
check(liveLedger.hours[0].end==live.end,"requerying identical partial-hour data cannot lengthen model time")
let frozen=liveLedger.status(now:live.end)
check(liveLedger.status(now:unchanged.end).value==frozen.value,"no new records cannot create partial-hour recovery")
unchanged.latestSignalAt=unchanged.end
liveLedger.merge([unchanged])
check(liveLedger.hours[0].end==unchanged.end,"a genuinely new signal advances the partial hour")
var firstBin=hour(9,kcal:10,hr:70,coverage:0.1)
firstBin.end=firstBin.start.addingTimeInterval(600)
let firstReading=StateHeartSignal(date:firstBin.end,bpm:70,resting:false,context:"安静候选",source:"watch")
var startup=BatteryLedger(baselineHR:55,hours:[firstBin],sourceKey:"watch",stateSignals:[firstReading],stateHRV:[],continuousVersion:1)
let firstStatus=startup.evaluate(now:firstBin.end)
var laterBin=firstBin;laterBin.end=firstBin.start.addingTimeInterval(2400);laterBin.activeKcal=200
let laterReading=StateHeartSignal(date:laterBin.end,bpm:95,resting:false,context:"安静候选",source:"watch")
startup.merge([laterBin]);startup.stateSignals=[laterReading]
let laterStatus=startup.status(now:laterBin.end)
check(laterStatus.continuity!.segmentStart==firstStatus.continuity!.segmentStart,"new samples in the first hour cannot move the original starting point")
check(startup.continuousOrigins?.count==1,"first evaluation saves exactly one origin")
check(laterStatus.continuity!.initialValue==firstStatus.continuity!.initialValue,"new HR does not replace the pinned initial reserve")
check(laterStatus.value!<firstStatus.value!,"first-hour activity depletes reserve after initialization")
let savedStartup=try JSONEncoder().encode(startup)
var restartedStartup=try JSONDecoder().decode(BatteryLedger.self,from:savedStartup)
let restartStatus=restartedStartup.evaluate(now:laterBin.end)
check(restartStatus.value==laterStatus.value && restartStatus.continuity!.segmentStart==firstStatus.continuity!.segmentStart,"restart retains initial time, value and trajectory")
check(restartedStartup.continuousOrigins?.count==1,"repeated evaluation does not duplicate origins")
let beforeOrigin=restartStatus.continuity!.origins!
restartedStartup.stateSignals?.append(StateHeartSignal(date:laterBin.end.addingTimeInterval(3600),bpm:35,resting:true,context:"静息",source:"watch"))
let beforeFuture=restartedStartup.evaluate(now:laterBin.end)
check(beforeFuture.value==restartStatus.value && beforeFuture.continuity!.origins==beforeOrigin,"future signals cannot change saved origin or prior reserve")
var gapLedger=BatteryLedger(baselineHR:55,hours:beforeGap+Array(blank[2..<12])+afterGap,sourceKey:"watch",continuousVersion:1)
let gapPinned=gapLedger.evaluate(now:afterGap[0].end)
check(gapLedger.continuousOrigins?.count==2,"separate valid segments pin separate origins")
let gapAgain=gapLedger.evaluate(now:afterGap[0].end)
check(gapAgain.value==gapPinned.value && gapAgain.continuity!.origins==gapPinned.continuity!.origins,"missing-data restarts remain deterministic across refreshes")
let futureOrigin=BatteryOrigin(bucketStart:firstBin.start,date:firstBin.end.addingTimeInterval(1),value:99,uncertainty:5,reason:"future fixture")
let safeOrigin=ContinuousBatteryModel.calculate(hours:[firstBin],signals:[firstReading],hrv:[],baselineHR:55,now:firstBin.end,calendar:cal,origins:[futureOrigin])
check(safeOrigin.continuity!.initialValue != 99 && safeOrigin.continuity!.segmentStart<=firstBin.end,"a future origin cannot initialize a past point")
let legacyWithoutOrigins=BatteryLedger(baselineHR:55,hours:[firstBin],sourceKey:"watch",continuousVersion:1)
var migrated=try JSONDecoder().decode(BatteryLedger.self,from:JSONEncoder().encode(legacyWithoutOrigins))
check(migrated.continuousOrigins==nil,"old ledgers decode without origin metadata")
_ = migrated.evaluate(now:firstBin.end)
check(migrated.continuousOrigins?.count==1,"first evaluation migrates old ledger origins without deleting bins")
let onlyTomorrow=model([hour(24,kcal:35)])
let falseYesterday=DailyBatteryStatistics.calculate(points:onlyTomorrow.points,day:day,now:hour(24).end,calendar:cal)
check(falseYesterday.latest==nil && falseYesterday.minimum==nil && falseYesterday.maximum==nil,"a midnight origin cannot invent data on the previous unobserved day")
let tomorrowOrigin=onlyTomorrow.points.first!
check(tomorrowOrigin.role == .intervalStart && tomorrowOrigin.belongs(to:day.addingTimeInterval(86400),end:day.addingTimeInterval(172800)),"origin uses start-of-interval day semantics")
check(!tomorrowOrigin.belongs(to:day,end:day.addingTimeInterval(86400)),"a new origin is excluded from the previous day")
let boundaryPoints=[BatteryPoint(date:day,value:80,mode:"previous interval end"),BatteryPoint(date:day.addingTimeInterval(3600),value:70,mode:"活动消耗")]
let boundaryStats=DailyBatteryStatistics.calculate(points:boundaryPoints,day:day,now:day.addingTimeInterval(3600),calendar:cal)
check(boundaryStats.maximum==80 && boundaryStats.minimum==70,"daily extrema include the carried midnight value")
check(boundaryStats.drained==10,"including the midnight boundary does not add or multiply consumption")
if CommandLine.arguments.count > 1 {
    let report:[String:Any] = ["synthetic":true,"initialObservationMinutes":10,"laterObservationMinutes":40,
        "initialOriginMinutes":firstStatus.continuity!.segmentStart.timeIntervalSince(firstBin.start)/60,
        "originAfterNewDataMinutes":laterStatus.continuity!.segmentStart.timeIntervalSince(firstBin.start)/60,
        "initialReference":firstStatus.value!,"afterRecordedActivity":laterStatus.value!,
        "sameOriginAfterRestart":restartStatus.continuity!.segmentStart==firstStatus.continuity!.segmentStart,
        "previousUnobservedDayHasValue":falseYesterday.latest != nil]
    try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
}
print("\(checks) continuous battery checks passed. Synthetic behavior checks; not physiological validation.")
