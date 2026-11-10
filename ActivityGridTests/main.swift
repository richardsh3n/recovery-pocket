import Foundation
var checks=0
func check(_ value:@autoclosure()->Bool,_ name:String){precondition(value(),name);checks+=1;print("PASS: "+name)}
func close(_ a:Double,_ b:Double)->Bool{abs(a-b)<1e-7}
var sh=Calendar(identifier:.gregorian);sh.timeZone=TimeZone(identifier:"Asia/Shanghai")!
var india=sh;india.timeZone=TimeZone(identifier:"Asia/Kolkata")!
let now=sh.date(from:DateComponents(year:2026,month:10,day:31,hour:15))!,today=india.startOfDay(for:now)
let oldFirst=sh.date(from:DateComponents(year:2026,month:10,day:30))!,recent=india.date(byAdding:.day,value:-29,to:today)!,week=india.date(byAdding:.day,value:-7,to:today)!
let earliest=max(week,oldFirst),oldModelStart=earliest
func queryKeys(_ anchor:Date,_ count:Int)->[Date] {
 let first=BatteryActivityGrid.firstBoundary(atOrAfter:earliest,anchor:anchor)!
 return (0..<count).map{first.addingTimeInterval(Double($0)*3600)}
}
let oldQuery=Set(queryKeys(recent,24)),oldModel=(0..<24).map{oldModelStart.addingTimeInterval(Double($0)*3600)}
let oldMatches=oldModel.filter{oldQuery.contains($0)}.count
check(oldMatches==0,"counterexample reproduces zero exact hourly joins after Shanghai-to-India timezone change")
let anchor=BatteryActivityGrid.anchor(saved:nil,first:oldFirst,fallback:today),start=BatteryActivityGrid.firstBoundary(atOrAfter:earliest,anchor:anchor)!
let newQuery=Set(queryKeys(anchor,24)),newModel=(0..<24).map{start.addingTimeInterval(Double($0)*3600)}
check(newModel.filter{newQuery.contains($0)}.count==24,"shared query and ledger anchor restores every one of twenty-four controlled hourly joins")
check(start==oldFirst && anchor==oldFirst,"recent existing ledger origin is not shifted to new local midnight")
let recorded=Dictionary(uniqueKeysWithValues:queryKeys(anchor,24).map{($0,50.0)})
check(close(newModel.compactMap{recorded[$0]}.reduce(0,+),1200),"joining preserves observed aggregate energy instead of fabricating missing values")
let saved=oldFirst.addingTimeInterval(123.25)
check(BatteryActivityGrid.anchor(saved:saved,first:oldFirst,fallback:today)==saved,"explicitly persisted activity grid outranks local calendar fallback")
check(BatteryActivityGrid.anchor(saved:nil,first:nil,fallback:today)==today,"new ledger starts on its current local-day phase")
check(BatteryActivityGrid.anchor(saved:Date(timeIntervalSinceReferenceDate:.nan),first:oldFirst,fallback:today)==oldFirst,"invalid saved anchor cannot poison time arithmetic")
check(BatteryActivityGrid.firstBoundary(atOrAfter:now,anchor:Date(timeIntervalSinceReferenceDate:.infinity))==nil,"nonfinite anchor cannot create a query time")
check(BatteryActivityGrid.firstBoundary(atOrAfter:Date(timeIntervalSinceReferenceDate:.nan),anchor:anchor)==nil,"nonfinite requested boundary is rejected")
for offset in [-7200.0,-3600.001,-3600,-0.001,0,0.001,1800,3599.999,3600,3600.001,86400.25] {
 let target=anchor.addingTimeInterval(offset),boundary=BatteryActivityGrid.firstBoundary(atOrAfter:target,anchor:anchor)!
 check(boundary>=target && boundary.timeIntervalSince(target)<3600,"aligned boundary neither precedes nor loses a full hour at offset \(offset)")
 check(close(boundary.timeIntervalSince(anchor)/3600,(boundary.timeIntervalSince(anchor)/3600).rounded()),"boundary preserves exact ledger phase at offset \(offset)")
}
let zones=["Asia/Shanghai","Asia/Kolkata","Asia/Kathmandu","Australia/Adelaide","Australia/Lord_Howe","America/Los_Angeles"]
for zone in zones {
 var cal=sh;cal.timeZone=TimeZone(identifier:zone)!
 let localDay=cal.startOfDay(for:now),minimum=cal.date(byAdding:.day,value:-7,to:localDay)!,boundary=BatteryActivityGrid.firstBoundary(atOrAfter:minimum,anchor:anchor)!
 let rows=(0..<24).map{boundary.addingTimeInterval(Double($0)*3600)}
 check(rows.allSatisfy{close($0.timeIntervalSince(anchor)/3600,($0.timeIntervalSince(anchor)/3600).rounded())},"timezone \(zone) cannot drift hourly ledger phase")
 check(Set(rows).count==24 && rows[1].timeIntervalSince(rows[0])==3600,"absolute hours remain unique across timezone \(zone)")
}
var lord=sh;lord.timeZone=TimeZone(identifier:"Australia/Lord_Howe")!
let beforeDST=lord.date(from:DateComponents(year:2026,month:10,day:3))!,afterDST=lord.date(from:DateComponents(year:2026,month:10,day:5))!
check(lord.timeZone.secondsFromGMT(for:afterDST)-lord.timeZone.secondsFromGMT(for:beforeDST)==1800,"fixture includes a real thirty-minute DST transition")
let alignedDST=BatteryActivityGrid.firstBoundary(atOrAfter:afterDST,anchor:beforeDST)!
check(alignedDST>=afterDST && alignedDST.timeIntervalSince(afterDST)==1800,"thirty-minute DST cannot silently rephase existing grid")
var ledger=BatteryLedger(baselineHR:60,hours:[],sourceKey:"synthetic-grid",activityGridAnchor:anchor)
let encoded=try JSONEncoder().encode(ledger),roundtrip=try JSONDecoder().decode(BatteryLedger.self,from:encoded)
check(roundtrip.activityGridAnchor==anchor,"grid survives cache save and restart")
var oldObject=try JSONSerialization.jsonObject(with:encoded) as! [String:Any];oldObject.removeValue(forKey:"activityGridAnchor")
let oldLedger=try JSONDecoder().decode(BatteryLedger.self,from:JSONSerialization.data(withJSONObject:oldObject))
check(oldLedger.activityGridAnchor==nil,"old ledger does not fabricate a stored grid")
let bin=BatteryHour(start:anchor,end:anchor.addingTimeInterval(3600),sleepHours:0,activeKcal:50,heartRate:80,heartRateCount:12,heartRateCoverageHours:1,personalHR:60)
ledger.hours=[bin];ledger.continuousVersion=1
let result=ledger.evaluate(now:bin.end),origin=ledger.continuousOrigins!
let chosen=BatteryActivityGrid.anchor(saved:ledger.activityGridAnchor,first:ledger.hours.first?.start,fallback:today)
let reread=BatteryHour(start:chosen,end:chosen.addingTimeInterval(3600),sleepHours:0,activeKcal:50,heartRate:80,heartRateCount:12,heartRateCoverageHours:1,personalHR:60)
ledger.merge([reread]);let after=ledger.evaluate(now:bin.end)
check(ledger.hours.count==1 && ledger.continuousOrigins==origin && after.value==result.value,"timezone-aware reread neither duplicates existing hour nor resets fixed origin")
check(HealthReadPolicy.canUpdateBattery(failed:[.dailySteps]) && HealthReadPolicy.canCompareAwakeHRV(failed:[.dailySteps]),"optional daily-step query failure cannot invalidate readable hourly background or battery")
check(!HealthReadPolicy.canCompareAwakeHRV(failed:[.steps]),"failed hourly movement background still blocks quiet HRV comparison")
let oldDayGroup=sh.startOfDay(for:anchor),newDayGroup=india.startOfDay(for:anchor)
check(oldDayGroup != newDayGroup,"local-day labels are separate from absolute-hour accounting grid")
func cached(_ fetchedAt:Date=now.addingTimeInterval(-30),zone:String?="Asia/Shanghai",failures:[String]=[],version:Int?=1,current:String="Asia/Shanghai")->Bool {
 HealthRefreshCachePolicy.mayReuse(fetchedAt:fetchedAt,readTimeZone:zone,failures:failures,ledgerVersion:version,now:now,currentTimeZone:current)
}
check(cached(),"recent successful snapshot in same timezone can avoid redundant query")
check(!cached(zone:"Asia/Shanghai",current:"Asia/Kolkata"),"timezone change forces refresh even within sixty-second cache window")
check(!cached(zone:nil),"old snapshot missing timezone provenance requires one new read")
check(!cached(now.addingTimeInterval(1)),"future fetched-at cannot suppress refresh until fabricated future time")
check(!cached(now.addingTimeInterval(-60)),"exactly sixty-second-old read no longer suppresses refresh")
check(!cached(failures:["日步数读取失败"]),"partial read retries instead of freezing optional missing data")
check(!cached(version:nil),"legacy ledger does not suppress migration read")
check(!cached(zone:"",current:""),"unidentified empty timezone is not compatible metadata")
if CommandLine.arguments.count>1 {
 let proof:[String:Any]=["syntheticOnly":true,"checks":checks,"timezoneCounterexample":"Shanghai to Asia/Kolkata during first ledger week","oldExactMatches":oldMatches,"newExactMatches":24,"recordedEnergyPreserved":1200,"sourceTimezoneAnchorMoved":false,"minimumAndMaximumScoringChanged":false,"newHealthDataTypeRequested":false,"realHealthKitTimezoneReadVerified":false]
 try JSONSerialization.data(withJSONObject:proof,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
}
print("\(checks) activity-grid and timezone checks passed; no real HealthKit travel acceptance")
