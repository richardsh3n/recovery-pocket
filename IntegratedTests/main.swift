import Foundation
var checks=0
func check(_ c:@autoclosure()->Bool,_ name:String){precondition(c(),name);checks+=1;print("PASS: "+name)}
func close(_ a:Double,_ b:Double)->Bool{abs(a-b)<1e-8}
var cal=Calendar(identifier:.gregorian);cal.timeZone=TimeZone(secondsFromGMT:0)!
let now=cal.startOfDay(for:Date(timeIntervalSince1970:1794000000)).addingTimeInterval(20*3600),day=cal.startOfDay(for:now)
func at(_ hours:Double)->Date{day.addingTimeInterval(hours*3600)}
let spans=[SleepInterval(start:at(-2),end:at(6)),SleepInterval(start:at(13),end:at(14))]
let episodes=SleepEpisodeEngine.episodes(spans+spans,now:now)
check(episodes.count==2,"duplicate sleep intervals never create duplicate episodes")
check(close(episodes.reduce(0){$0+$1.hours},9),"sleep union conserves asleep duration")
check(SleepEpisodeEngine.main(episodes,day:day,calendar:cal)?.hours==8,"main episode chosen by actual duration, nap preserved separately")
let late=SleepEpisodeEngine.episodes([SleepInterval(start:at(5),end:at(15))],now:now)
check(late.first!.hours==10 && SleepEpisodeEngine.main(late,day:day,calendar:cal) != nil,"afternoon waking is not truncated at noon")
let midnight=SleepEpisodeEngine.episodes([SleepInterval(start:at(-6),end:at(0))],now:now)
check(SleepEpisodeEngine.main(midnight,day:at(-12),calendar:cal) != nil,"midnight endpoint belongs to preceding local day")
let broken=SleepEpisodeEngine.episodes([SleepInterval(start:at(-1),end:at(2)),SleepInterval(start:at(2.5),end:at(5))],now:now)
check(broken.count==1 && close(broken[0].hours,5.5),"short fragment gap is grouped but never added to asleep hours")
check(SleepEpisodeEngine.episodes([SleepInterval(start:at(1),end:at(22))],now:now).isEmpty,"future-ending sleep is not treated as completed")
check(SleepEpisodeEngine.episodes([SleepInterval(start:at(2),end:at(1))],now:now).isEmpty,"inverted sleep interval rejected")
let timed=WellnessEngine.timing(intervals:[SleepInterval(start:at(5),end:at(15))],ending:day,now:now,calendar:cal)
check(timed.first?.end==at(15),"sleep plan uses the same afternoon-wake grouping")
var sh=cal;sh.timeZone=TimeZone(identifier:"Asia/Shanghai")!
check(SleepEpisodeEngine.main(episodes,day:day,calendar:sh) != nil,"episode attribution supports explicit local calendar")
func event(_ i:Int,revision:String="test",energy:Int?=nil)->PocketEvent{
 let date=cal.date(byAdding:.day,value:i-35,to:day)!.addingTimeInterval(10*3600)
 let feeling=energy ?? (i%5+1),value=(feeling-1)*20+10
 return PocketEvent(date:date,kind:"自评",energy:feeling,note:"synthetic",prediction:RecordedPrediction(value:value,observedAt:date,capturedAt:date,validUntil:date.addingTimeInterval(7200),modelRevision:revision,kind:"身体电量"))
}
let events=(0..<28).map{event($0)},group="身体电量 · test"
let validation=PersonalValidationEngine.evaluate(events:events,group:group,now:now,calendar:cal)
check(validation.ready && validation.trainingDays==21 && validation.testDays==7,"prospective evaluation keeps last seven dates independent")
check(validation.modelMAE==0,"monotonic mapping recovers controlled synthetic relationship")
check(validation.improvesBaseline,"candidate is compared with both fixed and last-rating baselines")
check(validation.splitDate==events[21].date,"date cutoff is observable and deterministic")
let duplicateEvaluation=PersonalValidationEngine.evaluate(events:events+events,group:group,now:now,calendar:cal)
check(duplicateEvaluation.totalDays==28 && duplicateEvaluation.modelMAE==validation.modelMAE,"duplicate journal rows cannot inflate personal validation")
let mixed=PersonalValidationEngine.evaluate(events:events+(0..<28).map{event($0,revision:"other",energy:1)},group:group,now:now,calendar:cal)
check(mixed.totalDays==28 && mixed.modelMAE==validation.modelMAE,"model revisions are never fused")
let small=PersonalValidationEngine.evaluate(events:Array(events.prefix(20)),group:group,now:now,calendar:cal)
check(!small.ready && small.modelMAE==nil,"insufficient distinct dates cannot claim validated fit")
var leaked=events;leaked[27].date=now.addingTimeInterval(3600)
check(PersonalValidationEngine.evaluate(events:leaked,group:group,now:now,calendar:cal).totalDays==27,"future self-report cannot enter evaluation")
var later=events
later[27].energy=1
let changed=PersonalValidationEngine.evaluate(events:later,group:group,now:now,calendar:cal)
check(changed.blocks.map(\.mean)==validation.blocks.map(\.mean),"holdout outcomes cannot change fitted blocks")
var reverse:[FeedbackPair]=[]
for i in 0..<5 {var row=event(i);row.prediction!.value=i*20;row.energy=5-i;reverse.append(FeedbackPair(event:row,prediction:row.prediction!))}
let blocks=PersonalValidationEngine.fit(reverse)
check(blocks.count==1 && blocks.first!.mean==3,"nonmonotonic data pools adjacent violating blocks")
check(PersonalValidationEngine.predicted(.nan,blocks:blocks)==nil,"invalid score cannot enter mapping")
check(PersonalValidationEngine.predicted(200,blocks:[])==nil,"empty fit remains unavailable")
let distinctDoseA=TrainingDoseEngine.candidateDrain(kcal:300,cardioMinutes:30,coverage:1)!,distinctDoseB=TrainingDoseEngine.candidateDrain(kcal:300,cardioMinutes:150,coverage:1)!
check(distinctDoseB>distinctDoseA,"shadow substitution responds to intensity at equal energy")
check(close(TrainingDoseEngine.candidateDrain(kcal:300,cardioMinutes:150,coverage:0.1)!,300/35),"low cardio coverage keeps the energy-only candidate")
check(TrainingDoseEngine.candidateDrain(kcal:nil,cardioMinutes:nil,coverage:1)==nil,"missing shadow inputs do not create zero")
check(TrainingDoseEngine.candidateDrain(kcal:-1,cardioMinutes:.nan,coverage:1)==nil,"invalid shadow dose rejected")
let contrast=TrainingDoseEngine.comparison(kcal:350,cardioMinutes:150,coverage:1)
check(contrast.energyOnly==10 && contrast.cardioOnly==15 && contrast.candidate==11.25,"candidate comparison exposes both proxies and fixed weighted substitution")
check(contrast.deltaFromEnergy==1.25,"candidate contrast reconciles against the energy-only reference")
check(contrast.candidate! < contrast.energyOnly!+contrast.cardioOnly!,"candidate does not add two correlated proxies at full weight")
check(TrainingDoseEngine.comparison(kcal:350,cardioMinutes:0,coverage:1).candidate==7.5,"candidate may reduce rather than always amplify an energy proxy")
check(TrainingDoseEngine.comparison(kcal:nil,cardioMinutes:150,coverage:1).deltaFromEnergy==nil,"missing energy cannot claim a zero-energy comparison")
check(TrainingDoseEngine.candidateDrain(kcal:350,cardioMinutes:150,coverage:0.8)==11.25,"coverage eligibility includes the declared eighty-percent boundary")
check(TrainingDoseEngine.candidateDrain(kcal:350,cardioMinutes:150,coverage:0.799)==10,"coverage just below threshold remains energy-only without extrapolation")
check(TrainingDoseEngine.candidateDrain(kcal:350,cardioMinutes:150,coverage:1.01)==10,"impossible coverage cannot qualify the cardio candidate")
check(TrainingDoseEngine.candidateDrain(kcal:nil,cardioMinutes:150,coverage:.nan)==nil,"invalid coverage with missing energy remains unavailable")
check(TrainingDoseEngine.candidateDrain(kcal:0,cardioMinutes:150,coverage:1)==3.75,"recorded zero is distinct from missing energy in the experimental blend")
check(TrainingDoseEngine.candidateDrain(kcal:350,cardioMinutes:1500,coverage:1)==32.5,"experimental cardio proxy retains its explicit cap")
struct DoseAuditRow:Codable {var kcal:Double?;var cardioMinutes:Double?;var coverage:Double;var comparison:TrainingDoseComparison}
var auditRows:[DoseAuditRow]=[]
for kcal:Double? in [nil,0,175,350,700] {
 for cardio:Double? in [nil,0,30,150,1500] {
  for coverage in [0.0,0.799,0.8,1.0,1.01] {
   auditRows.append(DoseAuditRow(kcal:kcal,cardioMinutes:cardio,coverage:coverage,comparison:TrainingDoseEngine.comparison(kcal:kcal,cardioMinutes:cardio,coverage:coverage)))
  }
 }
}
check(auditRows.count==125 && auditRows.allSatisfy{row in
 guard let a=row.comparison.energyOnly,let b=row.comparison.cardioOnly,let value=row.comparison.candidate else{return true}
 return value >= min(a,b) && value <= max(a,b)
},"fixed-input grid keeps every two-channel candidate inside its proxy bounds")
check(auditRows.filter{$0.coverage < 0.8 || $0.coverage > 1}.allSatisfy{$0.comparison.cardioOnly==nil && $0.comparison.candidate==$0.comparison.energyOnly},"fixed-input grid rejects low and impossible coverage consistently")
if CommandLine.arguments.count>1 {try JSONEncoder.iso.encode(auditRows).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))}
let workout=PocketWorkout(id:UUID(),title:"跑步",start:at(8),end:at(9),duration:3600,activeKcal:300,source:"test")
var effort=event(27);effort.kind="训练";effort.sessionRPE=5;effort.trainingMinutes=60;effort.workoutID=workout.id
let doses=TrainingDoseEngine.doses(workouts:[workout,workout],events:[effort],now:now)
check(doses.count==1 && doses.first!.effort?.sessionLoad==300,"explicit workout association binds RPE without duplicate workouts")
var unrelated=effort;unrelated.workoutID=nil
check(TrainingDoseEngine.doses(workouts:[workout],events:[unrelated],now:now).first!.effort==nil,"unlinked effort is not guessed onto a workout")
var habits=(0..<10).map{event($0,energy:$0<5 ? 2:4)}
for i in habits.indices {habits[i].habitAnswers=["caffeine":i<5]}
let comparison=HabitEvidenceEngine.compare(events:habits,now:now,calendar:cal).first{$0.key=="caffeine"}!
check(comparison.yesDays==5 && comparison.noDays==5 && comparison.difference == -2,"habit comparison requires explicit positive and negative days")
let unknown=HabitEvidenceEngine.compare(events:events,now:now,calendar:cal)
check(unknown.allSatisfy{$0.yesDays==0 && $0.noDays==0 && $0.difference==nil},"unknown habit is never interpreted as absence")
check(HabitEvidenceEngine.compare(events:Array(habits.prefix(4)),now:now,calendar:cal).allSatisfy{$0.difference==nil},"small habit groups do not create trends")
check(HabitEvidenceEngine.compare(events:habits+habits,now:now,calendar:cal).first{$0.key=="caffeine"}!.yesDays==5,"habit sample counts are dates, not event counts")
let meal=PhotoMeal(id:UUID(),revision:1,date:at(12),title:"午餐",kcal:600,lower:400,upper:800,notes:"synthetic",confirmed:true)
let raw=try JSONEncoder.iso.encode(MealEnvelope(schemaVersion:1,meal:meal)),parsed=PhotoFoodEngine.parse(raw,now:now)!
check(parsed.id==meal.id && !parsed.confirmed,"LLM output is always an unconfirmed draft")
var second=meal;second.revision=2;second.kcal=700
let merged=PhotoFoodEngine.merged([meal],incoming:second,now:now)!
check(merged.count==1 && merged[0].kcal==700,"newer meal version replaces rather than adds")
check(PhotoFoodEngine.merged(merged,incoming:meal,now:now)==nil,"older meal cannot overwrite a correction")
check(PhotoFoodEngine.total([meal,second],day:day,now:now,calendar:cal)?.value==700,"diet totals deduplicate across meal revisions")
check(PhotoFoodEngine.total([parsed],day:day,now:now,calendar:cal)==nil,"unconfirmed food cannot alter intake")
var invalid=meal;invalid.lower=900
check(!invalid.valid(now:now),"estimate must contain its central calorie value")
invalid=meal;invalid.kcal = .nan
check(!invalid.valid(now:now),"nonfinite food estimate rejected")
invalid=meal;invalid.date=now.addingTimeInterval(3600)
check(!invalid.valid(now:now),"future meal rejected")
let wrong=try JSONEncoder.iso.encode(MealEnvelope(schemaVersion:2,meal:meal))
check(PhotoFoodEngine.parse(wrong,now:now)==nil,"unknown food schema cannot silently enter journal")
let total=PhotoFoodEngine.total([meal],day:day,now:now,calendar:cal)!
check(total.count==1 && total.lower==400 && total.upper==800,"meal uncertainty propagates as input range")
let dayRecord=EnergyDayRecord(date:day,active:300,resting:1200,restingHours:20,restingSource:"test",intake:total.value,intakeSource:"local",intakeLower:total.lower,intakeUpper:total.upper)
let budget=EnergyBudgetEngine.report(dayRecord,manual:[],now:now,calendar:cal)
check(budget.intake==600 && budget.difference==900,"selected local intake is one source, not an extra HealthKit total")
check(budget.foodOnlyDifferenceRange==700...1100,"food-only difference range is distinct from expenditure error")
let backup=PocketBackup(createdAt:now,demo:false,events:events,records:IntegratedRecords(actions:[PocketAction(createdAt:at(10),title:"休息",evidence:"test")],meals:[meal]),manualEnergy:[])
check(backup.valid(now:now),"valid manual-data backup is accepted")
let saved=try JSONEncoder.iso.encode(backup),decoded=try JSONDecoder.iso.decode(PocketBackup.self,from:saved)
check(decoded.valid(now:now) && decoded.events.count==28 && decoded.records.meals.count==1,"backup roundtrip preserves journal and confirmed meals")
var badBackup=backup;badBackup.events.append(events[0])
check(!badBackup.valid(now:now),"duplicate event identities prevent destructive restore")
badBackup=backup;badBackup.schemaVersion=99
check(!badBackup.valid(now:now),"unknown backup version cannot replace existing data")
badBackup=backup;badBackup.records.meals[0].upper = -1
check(!badBackup.valid(now:now),"one invalid meal prevents whole-backup restore")
let object=try JSONSerialization.jsonObject(with:saved) as! [String:Any]
check(object["health"]==nil && object["token"]==nil && object["apiKey"]==nil,"backup contract excludes raw health and credential stores")
let watch=WatchCheckIn(date:now,energy:4)
check(watch.valid(now:now),"valid watch check-in can cross the shared contract")
check(!WatchCheckIn(date:now,energy:0).valid(now:now),"watch score outside explicit scale rejected")
check(!WatchCheckIn(date:now.addingTimeInterval(120),energy:4).valid(now:now),"future clock error does not enter watch inbox")
check(!WatchCheckIn(date:now.addingTimeInterval(-8*86400),energy:4).valid(now:now),"very old queued check-in rejected")
var status=PocketStatus(computedAt:now,measuredAt:now,value:60,lower:30,upper:90,charged:0,drained:0,message:"test",points:[],demo:false)
status.actionTitle="短休息";status.actionDate=now
check(status.visibleAction(at:now)=="短休息","same-day plan is shared across phone, watch and widgets")
check(status.visibleAction(at:now.addingTimeInterval(86400))==nil,"yesterday's plan cannot masquerade as today's action")
check(IntegratedReadiness.note(status:status,readAt:now,failures:0,now:now).contains("近期"),"readiness requires actual fresh observation")
status.measuredAt=now.addingTimeInterval(-3*3600)
check(IntegratedReadiness.note(status:status,readAt:now,failures:0,now:now).contains("过期"),"successful refresh does not freshen old measurements")
check(IntegratedReadiness.note(status:status,readAt:nil,failures:0,now:now).contains("尚未"),"unread state is distinct from stale")
check(IntegratedReadiness.note(status:status,readAt:now,failures:1,now:now).contains("部分"),"partial failures remain visible")
let shiftWorkout=PocketWorkout(id:UUID(),title:"夜班后训练",start:at(2),end:at(3),duration:3600,activeKcal:200,source:"test")
let shiftNight=NightRecord(date:day,sleepHours:6,hrv:50,heartRate:60,hrvCount:3,heartRateCount:10,sleepStartedAt:at(4),sleepEndedAt:at(10))
check(WellnessEngine.followUps(workouts:[shiftWorkout],nights:[shiftNight],feelings:[],now:now,calendar:cal).first!.nextNight?.date==day,"post-midnight workout links actual same-day sleep instead of tomorrow")
var futureNight=shiftNight;futureNight.sleepEndedAt=at(22)
check(WellnessEngine.followUps(workouts:[shiftWorkout],nights:[futureNight],feelings:[],now:now,calendar:cal).first!.nextNight==nil,"future-ending sleep cannot become post-workout outcome")
var priorNight=shiftNight;priorNight.sleepStartedAt=at(1)
check(WellnessEngine.followUps(workouts:[shiftWorkout],nights:[priorNight],feelings:[],now:now,calendar:cal).first!.nextNight==nil,"sleep that began before workout ended is not a subsequent outcome")
let folder=FileManager.default.temporaryDirectory.appendingPathComponent("pocket-restore-test-"+UUID().uuidString)
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
defer{try? FileManager.default.removeItem(at:folder)}
let aURL=folder.appendingPathComponent("events-v1.json"),bURL=folder.appendingPathComponent("integrated-v1.json")
try Data("old-a".utf8).write(to:aURL);try Data("old-b".utf8).write(to:bURL)
do{try ManualRecordTransaction.commit([aURL:Data("new-a".utf8),bURL:Data("new-b".utf8)],failAfter:1);preconditionFailure("expected injected failure")}catch{}
let rollbackA=try String(contentsOf:aURL),rollbackB=try String(contentsOf:bURL)
check(rollbackA=="old-a" && rollbackB=="old-b","failed multi-file restore rolls back already written records")
try ManualRecordTransaction.commit([aURL:Data("new-a".utf8),bURL:Data("new-b".utf8)])
let commitA=try String(contentsOf:aURL),commitB=try String(contentsOf:bURL)
check(commitA=="new-a" && commitB=="new-b","successful transaction replaces both manual stores")
print("\(checks) integrated checks passed; synthetic software evidence only")
