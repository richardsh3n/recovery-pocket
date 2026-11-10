import Foundation
var checks=0
func check(_ condition:@autoclosure()->Bool,_ name:String){precondition(condition(),name);checks+=1;print("PASS: "+name)}
func close(_ a:Double,_ b:Double,_ tolerance:Double=1e-8)->Bool{abs(a-b)<tolerance}
var cal=Calendar(identifier:.gregorian);cal.timeZone=TimeZone(secondsFromGMT:0)!
let day=cal.startOfDay(for:Date(timeIntervalSince1970:1794000000)),start=day.addingTimeInterval(8*3600),end=start.addingTimeInterval(3600),now=end.addingTimeInterval(60)
let digest=String(repeating:"a",count:64)
func row(_ rate:Double=160,energy:Double?=350,minutes:Int=60)->BatteryHour {
 let samples=(0...minutes).map{WorkoutHeartSample(date:start.addingTimeInterval(Double($0)*60),bpm:rate,source:"watch")}
 let spans=WorkoutHeartFallback.make(samples:samples,windows:[(start,end)],start:start,end:end,now:now,reference:60,source:"watch")
 return BatteryHour(start:start,end:end,sleepHours:0,activeKcal:energy,heartRate:rate,heartRateCount:minutes+1,heartRateCoverageHours:Double(minutes)/60,workoutHours:1,personalHR:60,awakeHeartRate:rate,awakeHeartRateCount:minutes+1,awakeHeartRateCoverageHours:Double(minutes)/60,workoutHeartSpans:spans)
}
func ledger(_ rows:[BatteryHour],origin:Date?=nil)->BatteryLedger {
 BatteryLedger(baselineHR:60,hours:rows,sourceKey:"sleep::watch",continuousVersion:1,continuousOrigins:[BatteryOrigin(bucketStart:start,date:origin ?? start,value:80,uncertainty:30,reason:"fixed synthetic origin")])
}
func decision(_ row:BatteryHour)->ActivityFusionDecision?{ActivityFusionEngine.decision(hour:row,now:now,policy:.cardioEnergyV1)}
let high=row(),low=row(100),formalHigh=ledger([high]).status(now:now),formalLow=ledger([low]).status(now:now)
let replay=ShadowReplayEngine.replay(ledger:ledger([high]),inputDigest:digest,now:now)!
let replayLow=ShadowReplayEngine.replay(ledger:ledger([low]),inputDigest:digest,now:now)!
check(high.workoutHeartSpans!.allSatisfy{$0.averageHR==160},"new spans retain actual adjacent-pair mean without inventing coverage")
check(formalHigh.points.last!.value==formalLow.points.last!.value,"standard model retains equal-energy behavior at different workout HR")
check(replay.candidate.points.last!.value!<replayLow.candidate.points.last!.value!,"full shadow integration differentiates equal-energy intensities")
check(formalHigh.points.allSatisfy{$0.effect?.activityExperiment==nil},"formal integrator does not implicitly select the shadow policy")
check(replay.candidate.modelRevision==ActivityFusionPolicy.cardioEnergyV1.revision,"shadow prediction has a distinct fixed-policy revision")
check(formalHigh.modelRevision != replay.candidate.modelRevision,"formal and shadow identities remain separate")
check(replay.candidate.inputs?.activeKcal==350 && high.activeKcal==350,"shadow substitution never rewrites recorded energy")
check(replay.decisions.count==1 && replay.coveredMinutes==60,"only actual changed bins and observed minutes are counted")
let directShadow=ContinuousBatteryModel.calculate(hours:[high],signals:[],hrv:[],baselineHR:60,now:now,anchorOverride:80,activityExperiment:.cardioEnergyV1)
check(directShadow.modelRevision==ActivityFusionPolicy.cardioEnergyV1.revision,"direct experimental integrator cannot masquerade as a standard model")
let rawShadow=BatteryModel.calculate(hours:[high],anchor:80,baselineHR:60,now:now,policy:.continuous,activityExperiment:.cardioEnergyV1)
check(rawShadow.modelRevision==ActivityFusionPolicy.cardioEnergyV1.revision,"raw experimental integration also retains shadow identity")
let varied=ContinuousBatteryModel.calculate(hours:[high],signals:[],hrv:[],baselineHR:60,now:now,parameters:BatteryModelParameters(sleepRecoveryHours:4.5),activityExperiment:.cardioEnergyV1)
check(varied.modelRevision != ActivityFusionPolicy.cardioEnergyV1.revision,"experimental recovery tuning cannot join the fixed shadow-policy cohort")
let effect=replay.candidate.points.last!.effect!,change=decision(high)!
check(close(effect.activityDrain,change.replacementDrain),"shadow effect ledger reports the substituted activity term")
check(effect.heartRateDrain==0 && replay.candidate.inputs?.workoutHeartFallbackDrain==0,"known-energy shadow does not also apply missing-energy HR fallback")
check(close(replay.candidate.points.last!.value!-80,effect.sleepRecharge+effect.restRecharge-effect.awakeDrain-effect.activityDrain-effect.heartRateDrain-effect.hrvDrain+(effect.boundaryAdjustment ?? 0)),"full shadow curve reconciles all effects including clipping")
check(change.replacementDrain>=min(change.energyDrain,change.cardioDrain) && change.replacementDrain<=max(change.energyDrain,change.cardioDrain),"two-channel replacement lies between its proxies rather than summing")
check(close(change.energyDrain,10) && close(change.cardioDrain,50.0/3),"replay retains explicit engineering proxy units for independent audit")
let missing=row(160,energy:nil)
check(decision(missing)==nil,"this shadow experiment cannot substitute an unobserved energy channel")
check(ShadowReplayEngine.replay(ledger:ledger([missing]),inputDigest:digest,now:now)==nil,"fallback-only records do not create a fictitious dual-model experiment")
check(close(ledger([missing]).status(now:now).inputs!.workoutHeartFallbackDrain!,2.1),"formal missing-energy fallback stays intact")
let zero=decision(row(160,energy:0))!
check(zero.energyDrain==0 && zero.replacementDrain>0,"recorded zero is explicit data and experimental divergence stays visible")
check(decision(row(160,minutes:47))==nil,"under-eighty-percent actual pair coverage declines experiment")
check(decision(row(160,minutes:48)) != nil,"exactly-eighty-percent actual pair coverage is eligible")
check(decision(row(160,minutes:48))!.cardioDrain<change.cardioDrain,"missing twenty percent is not extrapolated as full observed load")
var malformed=high;malformed.workoutHours=0.5
check(decision(malformed)==nil,"mixed training and other-activity bins are not reallocated without provenance")
malformed=high;malformed.workoutHours=1.01
check(decision(malformed)==nil,"training duration above bin duration is rejected")
malformed=high;malformed.sleepHours=0.1
check(decision(malformed)==nil,"recorded sleep prevents workout substitution")
malformed=high;malformed.workoutHeartSpans![0].averageHR=nil
check(decision(malformed)==nil,"legacy spans lacking raw mean keep formal calculation")
malformed=high;malformed.workoutHeartSpans![0].source="other"
check(decision(malformed)==nil,"mixed-source span sets cannot form a shadow activity term")
malformed=high;malformed.workoutHeartSpans![0].referenceHR=61
check(decision(malformed)==nil,"mixed references cannot form a shadow activity term")
malformed=high;malformed.workoutHeartSpans![0].averageHR = .nan
check(decision(malformed)==nil,"nonfinite pair means cannot enter experiment")
malformed=high;malformed.workoutHeartSpans![0].strain=0
check(decision(malformed)==nil,"inconsistent saved strain and raw pair mean are rejected")
malformed=high;malformed.workoutHeartSpans![0].end=start.addingTimeInterval(120)
check(decision(malformed)==nil,"saved long spans cannot impersonate actual ninety-second sampling pairs")
malformed=high;malformed.workoutHeartSpans! += high.workoutHeartSpans!
check(close(decision(malformed)!.replacementDrain,change.replacementDrain),"exact duplicated heart spans cannot double shadow load")
malformed=high
var overlap=high.workoutHeartSpans![0];overlap.start=overlap.start.addingTimeInterval(30);overlap.end=overlap.end.addingTimeInterval(30)
malformed.workoutHeartSpans!.append(overlap)
check(decision(malformed)==nil,"conflicting overlapping spans decline rather than double integrate")
malformed=high;malformed.end=now.addingTimeInterval(60)
check(decision(malformed)==nil,"future-ending bins do not qualify")
let extremeSamples=(0...60).map{WorkoutHeartSample(date:start.addingTimeInterval(Double($0)*60),bpm:220,source:"watch")}
let extremeSpans=WorkoutHeartFallback.make(samples:extremeSamples,windows:[(start,end)],start:start,end:end,now:now,reference:25,source:"watch")
var extreme=high;extreme.personalHR=25;extreme.heartRate=220;extreme.awakeHeartRate=220;extreme.workoutHeartSpans=extremeSpans
check(close(decision(extreme)!.cardioDrain,100),"cardio cap is stated per actual covered hour")
var extremePartial=extreme;extremePartial.workoutHeartSpans=Array(extremeSpans.prefix(48))
check(close(decision(extremePartial)!.cardioDrain,80),"capped partial coverage cannot impersonate a full observed hour")
let extremeClipped=ShadowReplayEngine.replay(ledger:ledger([extreme],origin:start.addingTimeInterval(1800)),inputDigest:digest,now:now)!
check(close(extremeClipped.decisions[0].cardioDrain,50),"clipped thirty-minute origin receives half the observed-hour cap")
var firstHalf=extreme;firstHalf.end=start.addingTimeInterval(1800);firstHalf.activeKcal=175;firstHalf.workoutHours=0.5;firstHalf.workoutHeartSpans=Array(extremeSpans.prefix(30))
var secondHalf=extreme;secondHalf.start=firstHalf.end;secondHalf.activeKcal=175;secondHalf.workoutHours=0.5;secondHalf.workoutHeartSpans=Array(extremeSpans.suffix(30))
let splitShadow=BatteryModel.calculate(hours:[firstHalf,secondHalf],anchor:80,baselineHR:25,now:now,policy:.continuous,activityExperiment:.cardioEnergyV1)
let wholeShadow=BatteryModel.calculate(hours:[extreme],anchor:80,baselineHR:25,now:now,policy:.continuous,activityExperiment:.cardioEnergyV1)
check(close(splitShadow.points.last!.value!,wholeShadow.points.last!.value!),"splitting a capped awake training interval cannot change the final reserve")
check(close(splitShadow.points.compactMap{$0.effect?.activityDrain}.reduce(0,+),wholeShadow.points.last!.effect!.activityDrain),"split and whole capped activity effects conserve dose")
let pinned=ledger([high],origin:start.addingTimeInterval(1800))
let clipped=ShadowReplayEngine.replay(ledger:pinned,inputDigest:digest,now:now)!
check(clipped.coveredMinutes==30 && close(clipped.decisions[0].replacementDrain,change.replacementDrain/2),"formal origin clipping also clips shadow energy and actual spans")
check(clipped.baseline.continuity!.segmentStart==clipped.candidate.continuity!.segmentStart && clipped.baseline.continuity!.initialValue==clipped.candidate.continuity!.initialValue,"both replays use the same pinned start and anchor")
let sleep=BatteryHour(start:end,end:end.addingTimeInterval(8*3600),sleepHours:8,activeKcal:0,heartRate:55,heartRateCount:32,heartRateCoverageHours:8,personalHR:60,sleepHeartRate:55)
let after=ShadowReplayEngine.replay(ledger:ledger([high,sleep]),inputDigest:digest,now:sleep.end.addingTimeInterval(60))!
let beforeGap=abs(replay.candidate.points.last!.value!-replay.baseline.points.last!.value!)
let afterGap=abs(after.candidate.points.last!.value!-after.baseline.points.last!.value!)
check(afterGap<beforeGap && afterGap>0,"later sleep attenuates shadow differences through the real nonlinear integrator")
var later=high;let shift=12*3600.0;later.start=later.start.addingTimeInterval(shift);later.end=later.end.addingTimeInterval(shift);later.workoutHours=0;later.workoutHeartSpans=nil;later.activeKcal=10
check(ShadowReplayEngine.replay(ledger:ledger([high,later]),inputDigest:digest,now:later.end.addingTimeInterval(60))==nil,"an old segment experiment cannot qualify a new segment after long missing data")
check(ShadowReplayEngine.replay(ledger:ledger([high]),inputDigest:"bad",now:now)==nil,"unreviewable input digests cannot create a frozen experiment")
var oldLedger=ledger([high]);oldLedger.sourceKey=nil
check(ShadowReplayEngine.replay(ledger:oldLedger,inputDigest:digest,now:now)==nil,"pre-source ledgers cannot claim comparable shadow results")
oldLedger=ledger([high]);oldLedger.continuousVersion=nil
check(ShadowReplayEngine.replay(ledger:oldLedger,inputDigest:digest,now:now)==nil,"legacy reserve algorithms do not silently join shadow cohort")
let rawBefore=try JSONEncoder.iso.encode(ledger([high]));_ = ledger([high]).experimentalStatus(now:now,origins:formalHigh.continuity!.origins!)
let rawAfter=try JSONEncoder.iso.encode(ledger([high]))
check(rawBefore == rawAfter,"shadow replay leaves original ledger and origins unchanged")
let oldSpan=high.workoutHeartSpans![0]
var oldSpanObject=try JSONSerialization.jsonObject(with:JSONEncoder().encode(oldSpan)) as! [String:Any];oldSpanObject.removeValue(forKey:"averageHR")
let decodedOldSpan=try JSONDecoder().decode(WorkoutHeartSpan.self,from:JSONSerialization.data(withJSONObject:oldSpanObject))
check(decodedOldSpan.averageHR==nil,"legacy span JSON remains readable without fabricated pair mean")
let frozen=FrozenModelComparison.capture(replay,expected:formalHigh,at:now)!
check(frozen.baseline.capturedAt==frozen.candidate.capturedAt && frozen.baseline.observedAt==frozen.candidate.observedAt,"two predictions are frozen at one capture time and one observation time")
var actual=PocketEvent(date:now,kind:"自评",energy:3,note:"synthetic",prediction:frozen.baseline,recordedAt:now.addingTimeInterval(20),modelComparison:frozen)
check(frozen.usable(for:actual,now:now.addingTimeInterval(20)),"fresh explicit feeling can attach to independently frozen predictions")
var wrongStatus=formalHigh;wrongStatus.value=99
check(FrozenModelComparison.capture(replay,expected:wrongStatus,at:now)==nil,"screen status mismatch cannot be paired with a different formal replay")
check(FrozenModelComparison.capture(replay,expected:formalHigh,at:end.addingTimeInterval(7201))==nil,"expired observation cannot be refreshed merely by opening check-in")
var changed=actual;changed.modifiedAt=now.addingTimeInterval(30)
check(!frozen.usable(for:changed,now:now.addingTimeInterval(30)),"edited outcomes stay out of prospective comparison")
changed=actual;changed.recordedAt=now.addingTimeInterval(301)
check(!frozen.usable(for:changed,now:now.addingTimeInterval(301)),"late submission cannot retroactively retain a fresh capture")
changed=actual;changed.date=now.addingTimeInterval(-86400)
check(!frozen.usable(for:changed,now:now.addingTimeInterval(20)),"historical backfill cannot inherit current paired predictions")
changed=actual;changed.prediction!.value=1
check(!frozen.usable(for:changed,now:now.addingTimeInterval(20)),"changed formal prediction invalidates dual-model association")
changed=actual;changed.recordedAt=nil
check(!frozen.usable(for:changed,now:now.addingTimeInterval(20)),"missing actual outcome submission time cannot enter prospective cohort")
changed=actual;changed.recordedAt=now.addingTimeInterval(100)
check(!frozen.usable(for:changed,now:now.addingTimeInterval(20)),"future submission timestamps are rejected")
changed=actual;changed.date=now.addingTimeInterval(30)
check(!frozen.usable(for:changed,now:now.addingTimeInterval(60)),"outcome cannot claim a date later than its actual submission time")
let encoded=try JSONEncoder.iso.encode(actual),restored=try JSONDecoder.iso.decode(PocketEvent.self,from:encoded)
check(restored.modelComparison==frozen && restored.recordedAt==actual.recordedAt,"frozen comparisons and actual recording time survive roundtrip")
var oldEvent=try JSONSerialization.jsonObject(with:JSONEncoder().encode(actual)) as! [String:Any]
for key in ["modelComparison","recordedAt","modifiedAt"]{oldEvent.removeValue(forKey:key)}
let decodedOldEvent=try JSONDecoder().decode(PocketEvent.self,from:JSONSerialization.data(withJSONObject:oldEvent))
check(decodedOldEvent.modelComparison==nil,"old self-reports remain readable and are never backfilled with candidate predictions")
func paired(_ index:Int,revision:String="formal-test")->PocketEvent {
 let date=day.addingTimeInterval(Double(index-35)*86400+10*3600),feeling=index%5+1
 let baseline=RecordedPrediction(value:50,observedAt:date,capturedAt:date,validUntil:date.addingTimeInterval(7200),modelRevision:revision,kind:"身体电量")
 var candidate=baseline;candidate.value=(feeling-1)*20+10;candidate.modelRevision=ActivityFusionPolicy.cardioEnergyV1.revision
 let comparison=FrozenModelComparison(baseline:baseline,candidate:candidate,inputDigest:digest,readAt:date,changedBins:1,coveredMinutes:60)
 return PocketEvent(date:date,kind:"自评",energy:feeling,note:"synthetic prospective fixture",prediction:baseline,recordedAt:date.addingTimeInterval(20),modelComparison:comparison)
}
let records=(0..<28).map{paired($0)},group=records[0].modelComparison!.group
let report=PairedModelValidationEngine.evaluate(events:records,group:group,now:now,calendar:cal)
check(report.ready && report.rows.count==28,"sufficient common distinct dates enable paired evaluation")
check(report.baseline.trainingDays==21 && report.candidate.trainingDays==21 && report.baseline.testDays==7 && report.candidate.testDays==7,"both models use exactly the same training and test counts")
check(report.baseline.splitDate==report.candidate.splitDate,"paired models share an observable independent time cutoff")
check(report.candidate.modelMAE==0 && report.baseline.modelMAE!>0,"controlled prospective fixture distinguishes informative from constant score")
check(report.candidateMAEImprovement!>0,"positive improvement is computed on the same held-out feelings")
check(report.baseline.fixedMAE==report.candidate.fixedMAE && report.baseline.previousMAE==report.candidate.previousMAE,"simple baselines use one identical paired cohort")
check(PairedModelValidationEngine.evaluate(events:records+records,group:group,now:now,calendar:cal).rows.count==28,"exact duplicate journal rows cannot inflate paired sample dates")
var edited=records;edited[0].modifiedAt=now
let excluded=PairedModelValidationEngine.evaluate(events:edited,group:group,now:now,calendar:cal)
check(excluded.rows.count==27 && excluded.exclusions["已编辑结果"]==1,"edited outcomes are visibly excluded from both models together")
var holdout=records;holdout[27].energy=1
let holdoutReport=PairedModelValidationEngine.evaluate(events:holdout,group:group,now:now,calendar:cal)
check(holdoutReport.candidate.blocks.map(\.mean)==report.candidate.blocks.map(\.mean) && holdoutReport.baseline.blocks.map(\.mean)==report.baseline.blocks.map(\.mean),"held-out outcomes cannot alter either fitted mapping")
check(!PairedModelValidationEngine.evaluate(events:Array(records.prefix(20)),group:group,now:now,calendar:cal).ready,"fewer than twenty-one common dates cannot claim comparative validation")
let mixed=PairedModelValidationEngine.evaluate(events:records+(0..<28).map{paired($0,revision:"other")},group:group,now:now,calendar:cal)
check(mixed.rows.count==28 && mixed.exclusions["其他模型版本"]==28,"other formal versions cannot contaminate current paired cohort")
var laterEvent=paired(0);laterEvent.date=laterEvent.date.addingTimeInterval(120);laterEvent.recordedAt=laterEvent.date.addingTimeInterval(20)
laterEvent.prediction!.observedAt=laterEvent.date;laterEvent.prediction!.capturedAt=laterEvent.date;laterEvent.prediction!.validUntil=laterEvent.date.addingTimeInterval(7200)
laterEvent.modelComparison!.baseline=laterEvent.prediction!;laterEvent.modelComparison!.candidate=laterEvent.prediction!;laterEvent.modelComparison!.candidate.modelRevision=ActivityFusionPolicy.cardioEnergyV1.revision;laterEvent.modelComparison!.readAt=laterEvent.date;laterEvent.energy=5
let duplicateDay=PairedModelValidationEngine.evaluate(events:records+[laterEvent],group:group,now:now,calendar:cal)
check(duplicateDay.rows.count==28 && duplicateDay.rows.first!.event.id==records[0].id,"first deliberate daily outcome is chosen without looking at its energy")
let backup=PocketBackup(createdAt:now,demo:true,events:records,records:IntegratedRecords(),manualEnergy:[])
check(backup.valid(now:now),"manual backup accepts valid frozen model predictions without raw HealthKit samples")
var forged=backup;forged.events[0].modelComparison!.inputDigest="invalid"
check(!forged.valid(now:now),"malformed frozen metadata prevents whole-backup replacement")
if CommandLine.arguments.count>1 {
 let output:[String:Any]=["syntheticOnly":true,"candidateEnabled":false,"policy":ActivityFusionPolicy.cardioEnergyV1.revision,"highHRFormal":formalHigh.points.last!.value!,"lowHRFormal":formalLow.points.last!.value!,"highHRShadow":replay.candidate.points.last!.value!,"lowHRShadow":replayLow.candidate.points.last!.value!,"differenceAfterSleep":afterGap,"differenceBeforeSleep":beforeGap,"pairedDates":report.rows.count,"trainingDays":report.baseline.trainingDays,"testDays":report.baseline.testDays,"formalMAE":report.baseline.modelMAE!,"candidateMAE":report.candidate.modelMAE!,"checks":checks]
 try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
}
print("\(checks) shadow replay and paired-validation checks passed; synthetic software evidence only")
