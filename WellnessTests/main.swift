import Foundation
var count = 0
func check(_ value:@autoclosure ()->Bool,_ title:String) { guard value() else { fatalError(title) }; count += 1; print("PASS: \(title)") }
var c = Calendar(identifier:.gregorian);c.timeZone = TimeZone(secondsFromGMT:0)!
let day = c.date(from:DateComponents(year:2026,month:10,day:12))!,now = day.addingTimeInterval(14*3600)
func date(_ offset:Int) -> Date { c.date(byAdding:.day,value:offset,to:day)! }
func night(_ offset:Int,_ hours:Double? = 7,_ hrv:Double? = 50) -> NightRecord { NightRecord(date:date(offset),sleepHours:hours,hrv:hrv,heartRate:55,hrvCount:hrv == nil ? 0 : 2,heartRateCount:10) }
func session(_ offset:Int = 0,_ start:Double = 8,_ end:Double = 9) -> PocketWorkout { PocketWorkout(id:UUID(),title:"训练",start:date(offset).addingTimeInterval(start*3600),end:date(offset).addingTimeInterval(end*3600),duration:(end-start)*3600,activeKcal:100,source:"synthetic") }
let sleeps = [night(-6,8),night(-5,6),night(-4,nil),night(-3,Double.nan),night(-2,9),night(0,7)]
let workout = session(),overlap = session(0,8.5,9.5)
let week = WellnessEngine.week(nights:sleeps,energy:[LoadBarRow(day:day,kcal:0)],workouts:[workout,workout,overlap],feelings:[WellnessCheckIn(date:now,energy:1),WellnessCheckIn(date:now.addingTimeInterval(-60),energy:5),WellnessCheckIn(date:now,energy:9)],ending:day,now:now,calendar:c)
check(week.sleepDays == 4,"nil and nonfinite sleep do not become zero days")
check(week.meanSleep == 7.5,"weekly mean uses recorded valid nights only")
check(week.sleepGap(target:8) == 3,"positive nightly goal gaps do not borrow surplus sleep")
check(week.days.last?.kcal == 0 && week.energyDays == 1,"recorded zero energy stays distinct from missing")
check(week.trainingMinutes == 90,"duplicate and overlapping workouts do not inflate weekly time")
check(week.days.last?.feeling == 3,"same-day valid ratings average before weekly calculation")
check(week.meanFeeling == 3,"missing check-ins cannot lower weekly mean")
check(week.days.first?.date == date(-6),"rolling seven-day report includes selected end date")
check(week.reachedSleep(target:8) == 2,"sleep goal counts actual qualifying records")
check(WellnessEngine.target(.nan) == 8,"invalid personal goal has a safe fallback")
let unique = WellnessEngine.nights([night(-1,6),night(-1,8)],now:now,calendar:c)
check(unique.count == 1,"duplicated dates cannot inflate sleep coverage")
check(WellnessEngine.nights([night(1)],now:now,calendar:c).isEmpty,"future night excluded")
let futureWorkout = session(0,15,16)
check(WellnessEngine.workouts([futureWorkout],now:now).isEmpty,"unfinished workout cannot enter recovery review")
var invalidWorkout = workout; invalidWorkout.duration = .nan
check(WellnessEngine.workouts([invalidWorkout],now:now).isEmpty,"nonfinite workout duration cannot reach UI integer formatting")
let fragments = [SleepInterval(start:date(-1).addingTimeInterval(23*3600),end:day.addingTimeInterval(3*3600)),SleepInterval(start:day.addingTimeInterval(3.5*3600),end:day.addingTimeInterval(7*3600))]
let timing = WellnessEngine.timing(intervals:fragments,ending:day,now:now,calendar:c)
check(timing.count == 1 && timing[0].asleepHours == 7.5,"asleep duration excludes gaps within displayed sleep span")
check(timing[0].start == fragments[0].start && timing[0].end == fragments[1].end,"displayed timing retains actual observed boundaries")
check(WellnessEngine.timing(intervals:[SleepInterval(start:day,end:day.addingTimeInterval(3600))],ending:day,now:now,calendar:c).isEmpty,"short nap is not labeled principal overnight rhythm")
check(WellnessEngine.timingVariation(timing,calendar:c) == nil,"one night cannot fabricate regularity")
let aroundMidnight = [SleepTiming(date:date(-2),start:date(-3).addingTimeInterval(23.5*3600),end:date(-2).addingTimeInterval(7*3600),asleepHours:7),SleepTiming(date:date(-1),start:date(-1).addingTimeInterval(0.5*3600),end:date(-1).addingTimeInterval(7*3600),asleepHours:7),SleepTiming(date:day,start:day,end:day.addingTimeInterval(7*3600),asleepHours:7)]
check((WellnessEngine.timingVariation(aroundMidnight,calendar:c) ?? 999) < 30,"midnight wrap cannot produce a twelve-hour regularity error")
let history = (1...8).map { night(-$0,8,50) }+[night(0,8,60)]
let finished = session(-1)
let follow = WellnessEngine.followUps(workouts:[finished,finished],nights:history,feelings:[WellnessCheckIn(date:finished.end.addingTimeInterval(3600),energy:4)],now:now,calendar:c)
check(follow.count == 1 && follow[0].nextNight?.date == day,"completed workout matches exactly following calendar night")
check(follow[0].hrvDifference == 10 && follow[0].baselineDays == 7,"next-night comparison uses earlier unique dates excluding training date")
check(follow[0].feeling?.energy == 4,"post-workout rating comes from an actual later record")
let lateRating = WellnessEngine.followUps(workouts:[finished],nights:[],feelings:[WellnessCheckIn(date:finished.end.addingTimeInterval(7*3600),energy:2)],now:now,calendar:c)[0]
check(lateRating.feeling == nil && lateRating.hrvDifference == nil,"distant feelings and missing nights remain unknown")
let invalidNight = WellnessEngine.followUps(workouts:[finished],nights:[night(0,.nan,60)],feelings:[],now:now,calendar:c)[0]
check(invalidNight.nextNight == nil,"invalid sleep cannot masquerade as a matched next-night record")
let loadRows = (1...28).map { offset in LoadBarRow(day:date(-offset),kcal:offset <= 4 ? 1000 : offset <= 7 ? 0 : 100) }
let load = StrainEngine.acwr(daily:loadRows,now:now,calendar:c)
check(load.chronicDays == 28 && load.acuteDays == 7,"ACWR retains true zero-load days")
check(abs((load.ratio ?? 0)-(4000.0/7)/(6100.0/28)) < 0.0001,"ACWR arithmetic includes recorded zero days")
check(StrainEngine.acwr(daily:Array(repeating:loadRows[0],count:14),now:now,calendar:c).ratio == nil,"duplicated one-day history cannot bypass coverage")
var withPartial = loadRows;withPartial.append(LoadBarRow(day:day,kcal:9000))
check(StrainEngine.acwr(daily:withPartial,now:now,calendar:c).ratio == load.ratio,"today partial total cannot distort complete-day load comparison")
let facts = [CoachFact(key:"sleep",name:"最近睡眠",value:"7.7 小时",detail:"昨夜"),CoachFact(key:"battery",name:"电量参考",value:"54 / 100",detail:"实验模型")]
let local = MorningBriefEngine.local(headline:"原计划",subline:"按体感安排。",facts:facts,gaps:[],now:now)
let swap = MorningBriefEngine.merge(draft:AIMorningDraft(body:"最近睡眠 54 小时，电量参考 7.7 / 100，适合大强度训练。"),local:local,facts:facts,given:[],source:.device,now:now)
check(swap.source == .local && swap.body == local.body,"AI metric/unit swap and new recommendation are rejected")
let candidate = MorningBriefEngine.variants(local).last!
check(MorningBriefEngine.merge(draft:AIMorningDraft(body:candidate),local:local,facts:facts,given:[],source:.device,now:now).source == .device,"AI can choose a bound local candidate")
var status = BatteryDemo.status(now:now);status.value = 5
let estimate = RecoveryEstimate(date:Calendar.current.startOfDay(for:now),score:90,lower:80,upper:95,state:"test",reliability:"test",reasons:[],baselineNights:28,sleepGap:0,measurementUsed:true)
let strong = DecisionEngine.make(estimate:estimate,status:status,lastNight:night(0,8),todayKcal:1000,strain:21,sleepTarget:8,intent:"训练",now:now)
check(strong.level == .hold && !strong.actions[0].headline.contains("强度训练"),"high load and low reserve cannot trigger high-intensity advice")
status.measuredAt = now.addingTimeInterval(-86400)
check(DecisionEngine.make(estimate:estimate,status:status,lastNight:nil,todayKcal:nil,strain:nil,sleepTarget:8,intent:"工作",now:now).budget == nil,"expired battery cannot appear as current remaining")
var oldEstimate = estimate;oldEstimate.date = now.addingTimeInterval(-5*86400)
check(DecisionEngine.make(estimate:oldEstimate,status:status,lastNight:night(-5,8),todayKcal:nil,strain:nil,sleepTarget:8,intent:"训练",now:now).level == .unknown,"old recovery cannot produce current advice")
status = BatteryDemo.status(now:now)
let rest = DecisionEngine.make(estimate:estimate,status:status,lastNight:night(0,7.7),todayKcal:100,strain:1,sleepTarget:8,intent:"恢复",now:now)
check(rest.level == .hold,"user recovery intention changes the action")
check(rest.actions[1].reason.contains("接近"),"sleep shortfall is not falsely described as goal reached")
print("\(count) wellness checks passed")
