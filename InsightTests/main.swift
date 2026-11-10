import Foundation
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) { guard value() else { fatalError(name) }; checks += 1; print("PASS: \(name)") }
func close(_ a: Double, _ b: Double) -> Bool { abs(a-b) < 0.0001 }
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(secondsFromGMT: 0)!
let start = Date(timeIntervalSince1970: 1781136000)
let day = calendar.startOfDay(for: start)
let now = day.addingTimeInterval(24*3600)
func point(_ hour: Double, _ value: Double?, effect: BatteryHourEffect? = nil) -> BatteryPoint { BatteryPoint(date: day.addingTimeInterval(hour*3600),value:value,mode:"test",effect:effect) }
let effect = BatteryHourEffect(sleepRecharge:8,restRecharge:2,awakeDrain:1,activityDrain:3,heartRateDrain:1,hrvDrain:1,sleepHRVAdjustment:2)
let base = [point(0,50),point(1,54,effect:effect),point(2,46,effect:effect)]
let report = EnergyInsights.day(points:base,day:day,now:now,calendar:calendar)
check(close(report.coveredSeconds,7200),"coverage uses valid adjacent interval duration")
check(close(report.charged,4) && close(report.drained,8),"net recharge and drain do not sum gross calculation factors")
check(close(report.missingSeconds,22*3600),"missing elapsed time remains missing")
check(report.hours.count == 24,"ordinary day has 24 independent cells")
check(report.hours[0].delta == 4 && report.hours[1].delta == -8,"hour cells preserve signed changes")
check(report.hours[2].delta == nil,"unknown hour never becomes zero")
check(report.factors.first { $0.id == "sleep" }?.amount == 16,"saved calculation terms sum separately")
check(report.factors.count == 6,"sleep HRV adjustment is not duplicated as an additional charge")
check(report.effectCoverageSeconds == 7200,"saved effect coverage shown independently")
check(report.peak?.end == point(2,46).date,"peak selection identifies actual declining interval")
check(report.chargingPeak?.delta == 4,"largest recharge points to an actual interval")
let gaps = EnergyInsights.day(points:[point(0,50),point(1,nil),point(2,70),point(4,60)],day:day,now:now,calendar:calendar)
check(gaps.intervals.isEmpty,"nil and two-hour gaps are never connected")
let singleton = EnergyInsights.day(points:[point(2,70)],day:day,now:now,calendar:calendar)
check(singleton.coveredSeconds == 0 && singleton.firstValue == nil,"one observation does not invent an interval")
let clipped = EnergyInsights.day(points:[point(-0.5,50),point(0.5,60,effect:effect)],day:day,now:now,calendar:calendar)
check(close(clipped.charged,5) && clipped.firstValue == 55,"midnight clips the existing interval proportionally")
check(clipped.factors.first { $0.id == "sleep" }?.amount == 4,"factor terms clip with the same fraction")
check(clipped.hours[0].coveredSeconds == 1800 && clipped.hours[0].rate == 10,"partial-hour rate exposes observed interval duration")
let partial = EnergyInsights.day(points:base,day:day,now:day.addingTimeInterval(1.5*3600),calendar:calendar)
check(partial.coveredSeconds == 3600 && partial.missingSeconds == 1800,"future end point is excluded rather than backfilled")
let future = EnergyInsights.day(points:base,day:now.addingTimeInterval(86400),now:now,calendar:calendar)
check(future.elapsedSeconds == 0 && future.hours.allSatisfy { $0.delta == nil },"future day has no values or elapsed-time deficit")
let invalid = EnergyInsights.day(points:[point(0,Double.nan),point(1,80),point(2,Double.infinity),point(3,101),point(4,-1)],day:day,now:now,calendar:calendar)
check(invalid.intervals.isEmpty,"nonfinite and out-of-range values cannot create charts")
let duplicate = EnergyInsights.day(points:base+[point(1,52)],day:day,now:now,calendar:calendar)
check(close(duplicate.charged,2) && close(duplicate.drained,6),"duplicate times use the last input once")
let shuffled = EnergyInsights.day(points:Array(base.reversed()),day:day,now:now,calendar:calendar)
check(shuffled.coveredSeconds == report.coveredSeconds && shuffled.charged == report.charged,"ordering cannot change totals")
let old = EnergyInsights.day(points:[point(0,50),point(1,40)],day:day,now:now,calendar:calendar)
check(old.factors.isEmpty && old.effectCoverageSeconds == 0 && old.drained == 10,"legacy records preserve net change without fabricated effects")
let zero = EnergyInsights.day(points:[point(0,50),point(1,50)],day:day,now:now,calendar:calendar)
check(zero.hours[0].delta == 0 && zero.hours[1].delta == nil,"recorded zero remains distinct from missing")
func workout(_ a:Double,_ b:Double) -> PocketWorkout { PocketWorkout(id:UUID(),title:"test",start:day.addingTimeInterval(a*3600),end:day.addingTimeInterval(b*3600),duration:(b-a)*3600,activeKcal:nil,source:"test") }
let w = workout(1,2)
let w2 = workout(1.5,2)
let comparisons = EnergyInsights.workouts([w,w,w2],points:base,day:day,now:now,calendar:calendar)
check(comparisons.count == 2,"duplicate workout UUIDs do not create extra cards")
check(close(comparisons.reduce(0) { $0+$1.impact.drop },8),"overlapping workouts share the single model decline")
let first = comparisons.first { $0.id == w.id }!
check(first.before?.value == 54 && first.after?.value == 46,"comparison uses real neighbouring point values")
check(first.coverage == 1,"full comparable interval coverage is shown accurately")
let noNearby = EnergyInsights.workouts([workout(8,9)],points:base,day:day,now:now,calendar:calendar)[0]
check(noNearby.before == nil && noNearby.after == nil && noNearby.impact.coveredSeconds == 0,"distant observations never fill training comparison")
let trainingGap = EnergyInsights.workouts([workout(1,2)],points:[point(0,50),point(1,40),point(2,nil)],day:day,now:now,calendar:calendar)[0]
check(trainingGap.after == nil && trainingGap.impact.coveredSeconds == 0,"missing post-training data remains missing")
check(EnergyInsights.workouts([workout(23,25)],points:base,day:day,now:now,calendar:calendar).isEmpty,"unfinished training is excluded")
let week = EnergyInsights.week(points:base,ending:day,now:now,calendar:calendar)
check(week.count == 7 && week.last?.day == day,"seven-day window is chronological and ends on selected date")
check(week.filter { $0.coveredSeconds > 0 }.count == 1,"empty days are never fabricated for heatmap")
var dst = calendar; dst.timeZone = TimeZone(identifier:"America/Los_Angeles")!
let spring = dst.date(from: DateComponents(year:2026,month:3,day:8))!
let autumn = dst.date(from: DateComponents(year:2026,month:11,day:1))!
let springReport = EnergyInsights.day(points:[],day:spring,now:spring.addingTimeInterval(30*3600),calendar:dst)
let autumnReport = EnergyInsights.day(points:[],day:autumn,now:autumn.addingTimeInterval(30*3600),calendar:dst)
check(springReport.hours.count == 23 && springReport.elapsedSeconds == 23*3600,"spring DST day has 23 hours")
check(autumnReport.hours.count == 25 && autumnReport.elapsedSeconds == 25*3600,"autumn DST day has 25 hours")
check(autumnReport.hours.map(\.id).count == Set(autumnReport.hours.map(\.id)).count,"repeated local hour has distinct absolute cell IDs")
print("\(checks) insight checks passed")
