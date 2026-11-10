import Foundation
func check(_ condition:@autoclosure ()->Bool,_ name:String) { guard condition() else { fatalError(name) }; print("PASS: \(name)") }
let now = Calendar.current.startOfDay(for:Date()).addingTimeInterval(14*3600)
var empty = CoachContext(now:now,snapshotAt:nil,battery:.empty,nights:[],workouts:[],hrv:[],target:8,selfRating:nil,demo:false)
check(empty.brief(.today).facts.isEmpty,"missing data produces no fabricated facts")
check(empty.brief(.today).gaps.contains { $0.contains("不代表没有睡觉") },"missing sleep is not interpreted as no sleep")
check(empty.recentNight == nil,"missing current sleep never borrows old sleep")
let night = NightRecord(date:Calendar.current.startOfDay(for:now),sleepHours:6,hrv:45,heartRate:56,hrvCount:1,heartRateCount:2)
empty.nights = [night]; empty.snapshotAt = now
check(empty.brief(.sleep).facts.contains { $0.key == "sleepHRV" && $0.value == "45 ms" },"real SDNN and sample count are reported")
check(empty.brief(.today).title.contains("余量"),"observed sleep below own goal changes local interpretation")
empty.snapshotAt = now.addingTimeInterval(-7*3600)
check(empty.recentNight == nil,"expired cache cannot provide current sleep guidance")
empty.snapshotAt = now; empty.nights[0].date = now.addingTimeInterval(-3*86400)
check(empty.brief(.sleep).title.contains("没准备好"),"old sleep remains a dated fact but not last-night evidence")
empty.nights = [night];empty.selfRating = 4
check(empty.brief(.today).facts.contains { $0.key == "feeling" },"valid self-rating is explicit evidence")
empty.selfRating = 9
check(!empty.brief(.today).facts.contains { $0.key == "feeling" },"invalid self-rating is rejected")
let session = PocketWorkout(id:UUID(),title:"步行",start:now.addingTimeInterval(-3600),end:now.addingTimeInterval(-1800),duration:1800,activeKcal:50,source:"test")
empty.workouts = [session,session]
check(empty.todayWorkouts.count == 1,"duplicate workout IDs cannot inflate totals")
check(!empty.brief(.training).facts.contains { $0.key == "impact" },"workout without comparable points cannot invent reserve impact")
var future = session;future.id = UUID();future.end = now.addingTimeInterval(3600)
empty.workouts.append(future)
check(empty.todayWorkouts.count == 1,"unfinished future workout is excluded")
empty.battery = BatteryDemo.status(now:now.addingTimeInterval(-3*3600))
check(empty.brief(.today).facts.contains { $0.key == "battery" && $0.name == "上次电量参考" },"stale reserve is described as a previous estimate")
check(empty.brief(.today).gaps.contains { $0.contains("已过期") },"stale estimate explicitly adds a data gap")
check(CoachTopic.matching("训练后怎么安排") == .training,"question routes to training evidence")
check(CoachTopic.matching("HRV为什么变化") == .hrv,"question routes to SDNN evidence")
check(CoachTopic.matching("明天天气") == nil,"unsupported local query is not disguised as open-ended AI")

var weekContext = empty; weekContext.nights = [night,night]
let weekFact = weekContext.brief(.week).facts.first { $0.key == "weekSleep" }
check(weekFact?.detail.contains("1 / 7") == true,"weekly means deduplicate calendar nights and expose coverage")
check(weekFact?.value == "6.0 小时","missing nights are not filled with zero in weekly mean")
weekContext.intent = "恢复"
check(weekContext.brief(.today).nextStep.contains("短休息"),"daily intent changes a concrete next step")
check(CoachTopic.matching("为什么没显示数据") == .coverage,"missing-data questions use honest coverage explanation")
for (key,topic) in CoachTopic.allCases.enumerated() { check(CoachTopic.aiSelection(key) == topic,"AI selection maps only to reviewed topic \(topic.rawValue)") }
check(CoachTopic.aiSelection(-1) == nil,"invalid AI selection cannot produce a narrative")
check(CoachTopic.aiSelection(6) == nil,"unsupported AI selection has no health conclusion")
print("Coach checks passed; AI can select reviewed topics, never generate health narratives.")
check(CoachTopic.resolvedAISelection(0,question:"刚刚跑完步，帮我回顾一下") == .training,"explicit workout intent survives an incorrect AI topic")
check(CoachTopic.resolvedAISelection(0,question:"昨晚熬夜了") == .sleep,"late-night sleep question uses observed sleep evidence")
check(CoachTopic.resolvedAISelection(6,question:"明天天气如何") == nil,"unrelated request has no invented answer")
check(CoachTopic.matching("HRV的数据怎么看") == .hrv,"metric-specific question takes priority over generic data keyword")
check(CoachTopic.matching("今天HRV没有显示") == .coverage,"missing metric question prioritizes connection checks")

// MARK: - AI 接入层：后端地址、晨报、输出校验
check(AIBackendConfig(endpoint:"https://api.example.com").normalizedEndpoint == "https://api.example.com/v1/chat/completions","bare host gains the compatible chat path")
check(AIBackendConfig(endpoint:"https://api.example.com/v1").normalizedEndpoint == "https://api.example.com/v1/chat/completions","versioned host is not double-prefixed")
check(AIBackendConfig(endpoint:"https://api.example.com/v1/chat/completions").normalizedEndpoint == "https://api.example.com/v1/chat/completions","explicit chat path is preserved")
check(AIBackendConfig(endpoint:"  ").normalizedEndpoint.isEmpty,"blank endpoint stays unusable")
check(!AIBackendConfig(cloudEnabled:true,endpoint:"https://api.example.com",model:"m",hasStoredKey:false).cloudUsable,"cloud backend needs a stored key")
check(!AIBackendConfig(cloudEnabled:false,endpoint:"https://api.example.com",model:"m",hasStoredKey:true).cloudUsable,"disabled cloud backend is not usable")
check(AIBackendConfig(cloudEnabled:true,endpoint:"https://api.example.com",model:"m",hasStoredKey:true).cloudUsable,"fully configured cloud backend is usable")

let aiFacts = [CoachFact(key:"battery",name:"电量参考",value:"81 / 100",detail:"09:30 · 实验模型，未个体校准"),
               CoachFact(key:"sleep",name:"最近睡眠",value:"7.7 小时",detail:"10月11日 · 个人目标 8.0 小时")]
let aiGiven = ["安排强度训练 40–60 分钟"]
let aiEvidence = MorningBriefEngine.evidence(aiFacts, given:aiGiven)
let localBrief = MorningBriefEngine.local(headline:"今天可以放手练",subline:"恢复高于你的个人近期区间，适合安排强度训练。",facts:aiFacts,gaps:["训练窗口缺少相邻观测"],now:now)
check(localBrief.source == .local && localBrief.body.contains("7.7 小时") && localBrief.body.contains("81"),"local brief is built only from computed facts")
check(localBrief.body.contains("1 项依据缺失"),"local brief states how many gaps exist instead of hiding them")
check(!MorningBriefEngine.local(headline:"",subline:"",facts:[],gaps:[],now:now).body.isEmpty,"empty evidence still yields an honest sentence")

check(AITextGuard.validate("昨夜睡了 7.7 小时，电量参考 81 / 100。",evidence:aiEvidence,limit:200).ok,"rewriting with only recorded numbers passes")
let invented = AITextGuard.validate("昨夜睡了 9.4 小时，恢复偏低。",evidence:aiEvidence,limit:200)
check(!invented.ok && invented.reason?.contains("9.4") == true,"invented numbers are rejected and named")
check(!AITextGuard.validate("这是典型的睡眠不足症状，建议就医。",evidence:aiEvidence,limit:200).ok,"diagnostic wording is rejected")
check(!AITextGuard.validate("训练导致电量下降。",evidence:aiEvidence,limit:200).ok,"causal claims are rejected")
check(!AITextGuard.validate("睡了三个小时。",evidence:aiEvidence,limit:200).ok,"unverifiable Chinese numerals are rejected")
check(!AITextGuard.validate("状态不错，但今天要补足三十五分钟睡眠",evidence:aiEvidence,limit:200).ok,"Chinese numeral plus unit is rejected")
check(!AITextGuard.validate("恢复很好。多喝水，多吃蔬菜，多晒太阳保持规律作息",evidence:aiEvidence,limit:20).ok,"over-length output is rejected")
check(!AITextGuard.validate("   ",evidence:aiEvidence,limit:200).ok,"blank output is rejected")
check(AITextGuard.clean("**状态**\n\n- 昨夜 7.7 小时\n- 电量 81") == "状态 昨夜 7.7 小时 电量 81","markdown and bullets are flattened without touching values")
check(AITextGuard.clean("温度 8-9 度") == "温度 8-9 度","hyphenated ranges are not rewritten")
check(AITextGuard.numbers(in:"恢复 81 和 7.70 与 3.5").sorted() == ["3.5","7.7","81"],"number extraction normalizes trailing zeros")
check(AITextGuard.numbers(in:"版本 1.2.3").isEmpty == false,"multi-dot runs cannot silently disappear")

check(AIMorningDraftParser.parse(#"{"body":"昨夜 7.7 小时","headline":"忽略我"}"#)?.body == "昨夜 7.7 小时","strict JSON draft parses")
check(AIMorningDraftParser.parse("好的：{\"body\":\"b\"}")?.body == "b","surrounding prose is trimmed to the JSON object")
check(AIMorningDraftParser.parse("body: b") == nil,"non-JSON output is refused rather than guessed")
check(AIMorningDraftParser.parse(#"{"headline":"只有标题"}"#) == nil,"a draft without a body is refused")

let goodDraft = AIMorningDraft(body:localBrief.body)
let mergedGood = MorningBriefEngine.merge(draft:goodDraft,local:localBrief,facts:aiFacts,given:aiGiven,source:.device,now:now)
check(mergedGood.source == .device && mergedGood.body == goodDraft.body && !mergedGood.note.contains("没通过"),"passing draft keeps the AI wording and labels its source")
check(mergedGood.headline == localBrief.headline,"headline always comes from the local decision, never from AI")
let restated = AIMorningDraft(body:"最近睡眠 7.7 小时、电量参考 81 / 100，先安排强度训练 40–60 分钟。")
check(MorningBriefEngine.merge(draft:restated,local:localBrief,facts:aiFacts,given:aiGiven,source:.cloud,now:now).source == .local,"a free rewrite cannot repurpose allowed numbers into a different recommendation")
check(MorningBriefEngine.missingNumbers(generated:"最近睡眠 7.7 小时",local:localBrief.body,facts:aiFacts) == ["100","81"],"missing-numbers check names exactly what a rewrite dropped")
let dropping = AIMorningDraft(body:"今天可以放手练，恢复高于你的个人近期区间，适合安排强度训练。")
let mergedDropping = MorningBriefEngine.merge(draft:dropping,local:localBrief,facts:aiFacts,given:aiGiven,source:.device,now:now)
check(mergedDropping.body == localBrief.body && mergedDropping.note.contains("漏掉了"),"a rewrite that drops recorded numbers is refused instead of shipping less information")
let badDraft = AIMorningDraft(body:"你可能有 9.4 小时的睡眠债，建议就医。")
let mergedBad = MorningBriefEngine.merge(draft:badDraft,local:localBrief,facts:aiFacts,given:aiGiven,source:.cloud,now:now)
check(mergedBad.body == localBrief.body && mergedBad.headline == localBrief.headline,"failing draft falls back to local wording")
check(mergedBad.note.contains("没通过校验") && mergedBad.source == .local,"fallback is stated instead of hidden")
let denseFacts = aiFacts + [CoachFact(key:"impact",name:"训练时段电量净下降",value:"11.1 模型点",detail:"仅统计有可比较观测的重叠窗口")]
let denseLocal = MorningBrief(headline:"今天可以放手练",body:"最近睡眠 7.7 小时 · 电量参考 81 / 100 · 训练时段净下降 11.1 模型点。",source:.local,generatedAt:now,note:"")
let mergedThin = MorningBriefEngine.merge(draft:AIMorningDraft(body:"最近睡眠 7.7 小时，电量参考 81 / 100。"),local:denseLocal,facts:denseFacts,given:aiGiven,source:.device,now:now)
check(mergedThin.source == .local && mergedThin.note.contains("11.1"),"dropping a recorded number is caught even when the wording itself is valid")
check(AIBackend.allCases.count == 3 && AIBackend.local.summary.contains("不联网"),"backend list stays explicit and local is always offline")
