import Foundation
var count = 0
func check(_ value:@autoclosure () -> Bool,_ name:String) { guard value() else { fatalError("FAIL: "+name) };count += 1;print("PASS: "+name) }
func close(_ a:Double,_ b:Double) -> Bool { abs(a-b)<0.00001 }
var c = Calendar(identifier:.gregorian);c.timeZone = TimeZone(secondsFromGMT:0)!
let day = c.date(from:DateComponents(year:2026,month:10,day:13))!,now = day.addingTimeInterval(36*3600)
func sample(_ start:Double,_ end:Double,_ kcal:Double,_ source:String = "watch",watch:Bool = true) -> CalorieSample { CalorieSample(id:UUID(),start:day.addingTimeInterval(start*3600),end:day.addingTimeInterval(end*3600),kcal:kcal,source:source,sourceName:source,watch:watch) }
let rest = sample(0,24,1800),food = sample(12,12,1500,"food",watch:false)
let active = EnergyDayRecord(date:day,active:600,resting:nil,restingHours:0,restingSource:nil,intake:nil,intakeSource:nil,intakeLower:nil,intakeUpper:nil)
func record(_ rests:[CalorieSample] = [rest],_ foods:[CalorieSample] = [food],source:String? = nil) -> EnergyDayRecord { EnergyBudgetEngine.days(resting:rests,intake:foods,active:[active],start:day,now:now,foodSource:source,calendar:c)[0] }
func entry(_ intake:Double? = nil,_ complete:Bool = true,_ bmr:Double? = nil,_ date:Date = day) -> ManualEnergyEntry { ManualEnergyEntry(id:UUID(),day:date,recordedAt:day.addingTimeInterval(23*3600),intake:intake,foodComplete:complete,scaleBMR:bmr) }
func report(_ r:EnergyDayRecord,_ entries:[ManualEnergyEntry] = []) -> EnergyBudgetReport { EnergyBudgetEngine.report(r,manual:entries,now:now,calendar:c) }
let r = record(),result = report(r,[entry()])
check(result.expenditure == 2400 && result.difference == 900,"total adds resting and active once, then subtracts intake")
check(result.usableAsDailyEstimate && result.differenceLabel == "参考热量缺口","completed date with complete log and covered rest qualifies only as estimate")
check(!report(r).usableAsDailyEstimate,"logged meals alone cannot imply complete diet")
var missingActivity = r;missingActivity.active = nil
check(report(missingActivity,[entry()]).expenditure == nil,"missing activity is not treated as zero")
check(report(record([rest],[]),[entry()]).difference == nil,"no meal samples do not imply fasting")
check(report(r,[entry(0)]).difference == 2400,"explicit manual zero intake is preserved")
check(report(r,[entry(2000)]).difference == 400,"manual daily intake replaces health intake rather than adding it")
check(record([rest,rest]).resting == 1800,"duplicate UUID cannot multiply resting energy")
var overlapping = rest;overlapping.id = UUID()
check(record([rest,overlapping]).resting == 1800,"overlapping same-source intervals are not added twice")
let finer = sample(0,1,100)
check(record([rest,finer]).resting == 1825,"finer-grained resting interval replaces overlapping coarse interval")
let cross = sample(-1,1,150)
check(record([cross]).resting == 75 && record([cross]).restingHours == 1,"cross-midnight resting energy is prorated to current day")
let instantaneous = sample(1,1,1800,"scale",watch:false)
check(record([instantaneous]).resting == nil,"instantaneous scale kcal/day value is not a burned-energy interval")
let scaleDay = sample(0,24,2000,"scale",watch:false)
check(record([rest,scaleDay]).resting == 1800,"watch resting source excludes scale totals instead of adding both")
check(EnergyBudgetEngine.resting([rest,scaleDay],from:day,to:day.addingTimeInterval(86400)).kcal == nil,"direct resting aggregation refuses mixed sources")
var badRest = rest;badRest.kcal = .nan
check(record([badRest]).resting == nil,"nonfinite basal energy is excluded")
var negative = food;negative.kcal = -10
check(record([rest],[negative]).intake == nil,"negative food energy is excluded")
var future = food;future.start = now.addingTimeInterval(1);future.end = future.start
check(record([rest],[future]).intake == nil,"planned future meal is not consumed intake")
let otherFood = sample(12,12,1800,"food-b",watch:false)
check(record([rest],[food,otherFood],source:"food").intake == 1500,"explicit source excludes duplicate imports from another food app")
check(record([rest],[food,otherFood]).intake! <= 1800,"automatic source selection never sums multiple food apps")
check(record([rest],[food],source:"missing-app").intake == nil,"unavailable selected food source stays missing")
var first = food;first.syncIdentifier = "meal-1";first.syncVersion = 1
var revised = food;revised.id = UUID();revised.syncIdentifier = "meal-1";revised.syncVersion = 2;revised.kcal = 1600
check(record([rest],[first,revised]).intake == 1600,"revised same meal replaces previous version")
var separate = revised;separate.source = "food-b"
check(record([rest],[first,separate],source:"food").intake == 1500,"sync ID is scoped to its source")
var ranged = food;ranged.lowerKcal = 1200;ranged.upperKcal = 1800
check(report(record([rest],[ranged]),[entry()]).foodOnlyDifferenceRange == 600...1200,"food estimate range is propagated through expenditure minus intake")
var invalidRange = ranged;invalidRange.lowerKcal = 1600
check(record([rest],[invalidRange]).intakeLower == nil,"range not containing midpoint is rejected")
let extra = sample(18,18,300,"food",watch:false)
check(record([rest],[ranged,extra]).intakeLower == nil,"incomplete meal ranges do not fabricate total interval")
check(report(record([rest],[ranged]),[entry(1700)]).foodOnlyDifferenceRange == nil,"manual override does not inherit unrelated AI uncertainty")
let bmrResult = report(record([],[]),[entry(1800,true,1800)])
check(bmrResult.resting == 1800 && bmrResult.expenditure == 2400 && bmrResult.scaleReference,"explicit scale reference can fill missing resting estimate")
check(!result.scaleReference && report(r,[entry(nil,true,1900)]).resting == 1800,"scale reference is not added when health resting already exists")
check(!report(record([],[]),[entry(1000,true,1800,day.addingTimeInterval(-31*86400))]).scaleReference,"stale scale estimate is not silently reused")
let partial = sample(0,12,900)
check(!report(record([partial]),[entry()]).usableAsDailyEstimate,"incomplete resting coverage does not qualify as full-day estimate")
var excess = r;excess.intake = 3000
check(report(excess,[entry()]).difference == -600 && report(excess,[entry()]).differenceLabel == "参考热量盈余","surplus remains negative and is labeled correctly")
let todayRecord = EnergyDayRecord(date:day.addingTimeInterval(86400),active:300,resting:nil,restingHours:0,restingSource:nil,intake:1000,intakeSource:"food",intakeLower:nil,intakeUpper:nil)
let todayResult = report(todayRecord,[entry(nil,true,1800)])
check(todayResult.resting == 900 && !todayResult.dayComplete,"scale reference today prorates to elapsed twelve hours without projecting full day")
check(todayResult.differenceLabel == "截至目前差额" && !todayResult.usableAsDailyEstimate,"partial today is not presented as final deficit")
var futureDay = todayRecord;futureDay.date = now.addingTimeInterval(86400)
check(report(futureDay,[entry(nil,true,1800)]).difference == nil,"future day cannot show a fabricated balance")
let changedAtFuture = ManualEnergyEntry(id:UUID(),day:day,recordedAt:now.addingTimeInterval(1),intake:0,foodComplete:true,scaleBMR:1800)
check(!report(r,[changedAtFuture]).foodComplete,"future manual confirmation is excluded")
let data = try! JSONEncoder().encode([r]);let decoded = try! JSONDecoder().decode([EnergyDayRecord].self,from:data)
check(decoded[0].resting == 1800 && decoded[0].intake == 1500,"aggregate budget survives cache round-trip")
var dst = Calendar(identifier:.gregorian);dst.timeZone = TimeZone(identifier:"America/New_York")!
let dstDay = dst.date(from:DateComponents(year:2026,month:3,day:8))!,dstEnd = dst.date(byAdding:.day,value:1,to:dstDay)!
let dstRest = CalorieSample(id:UUID(),start:dstDay,end:dstEnd,kcal:1725,source:"watch",sourceName:"watch",watch:true)
let dstRecord = EnergyBudgetEngine.days(resting:[dstRest],intake:[],active:[],start:dstDay,now:dstEnd,calendar:dst)[0]
check(dstRecord.restingHours == 23 && dstRecord.resting == 1725,"daylight-saving day uses actual local-day interval")
check(EnergyBudgetEngine.sources([food,food,otherFood]).count == 2,"source picker deduplicates identifiers")
var coveredToday = todayRecord;coveredToday.resting = 900;coveredToday.restingHours = 12
check(!report(coveredToday).missing.contains { $0.contains("时间覆盖不足") },"today coverage is judged against elapsed time, not future hours")
var uncertainFood = ranged;uncertainFood.upperKcal = 2500
check(report(record([rest],[uncertainFood]),[entry()]).differenceLabel == "参考热量差 · 方向不确定","AI food range crossing zero does not assert a known deficit direction")
print("\(count) energy budget checks passed. Synthetic records, not metabolic validation.")
