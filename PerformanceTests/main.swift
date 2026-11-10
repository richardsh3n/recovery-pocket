import Foundation
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    precondition(condition(), name); checks += 1
}
let calendar = Calendar(identifier: .gregorian)
let now = Date(timeIntervalSince1970: 1_792_396_800)
let contexts = ["安静候选", "睡眠", "活动时段", "活动记录不足"]
var observations: [HRVObservation] = []
var signals: [StateHeartSignal] = []
var hours: [BatteryHour] = []
for offset in 0..<35 {
    let date = now.addingTimeInterval(-Double(offset)*86400)
    signals.append(StateHeartSignal(date: date, bpm: 60 + sin(Double(offset))*5, resting: true, context: "静息", source: "synthetic-watch"))
    for (i, context) in contexts.enumerated() {
        let end = date.addingTimeInterval(-Double(i)*120)
        observations.append(HRVObservation(id: UUID(uuidString: String(format:"00000000-0000-0000-0000-%012d", offset*4+i))!, start: end.addingTimeInterval(-60), end: end, sdnn: 50+sin(Double(offset+i))*10, context: context, source: "synthetic-watch"))
    }
    hours.append(BatteryHour(start:date.addingTimeInterval(-3600),end:date,sleepHours:0,activeKcal:Double(offset*10),heartRate:nil,heartRateCount:0))
}
func verify(_ observations:[HRVObservation], _ label:String) throws {
    let ledger = BatteryLedger(baselineHR:60,hours:hours,sourceKey:"synthetic-watch",stateSignals:signals,stateHRV:observations)
    let history = ledger.stateHistory(now:now)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    for point in history {
        let direct = CurrentStateModel.estimate(signals:signals,hrv:observations,hours:hours,now:point.date)!
        check(point.value == Double(direct.value), label+": value identical to point-in-time calculation")
        let prepared = CurrentStateModel.comparisons(observations, now:point.date)
        let reused = CurrentStateModel.estimate(signals:signals,hrv:observations,hours:hours,now:point.date,comparisons:prepared)!
        let same = try encoder.encode(direct) == encoder.encode(reused)
        check(same,label+": evidence and range identical")
    }
    check(!history.isEmpty,label+": has history")
}
try verify(observations,"mixed contexts")
var invalid = observations
var invalidRow = observations[0]; invalidRow.id = UUID(); invalidRow.sdnn = 1_500
invalid.append(invalidRow)
var invalidDuration = observations[1]; invalidDuration.id = UUID(); invalidDuration.start = invalidDuration.end
invalid.append(invalidDuration)
try verify(invalid,"invalid samples")
var collision = observations
var future = observations.last!; future.start = now.addingTimeInterval(60); future.end = now.addingTimeInterval(120); future.sdnn = 1
collision.insert(future,at:0)
try verify(collision,"future conflicting UUID")
let ledger = BatteryLedger(baselineHR:60,hours:hours,sourceKey:"synthetic-watch",stateSignals:signals,stateHRV:observations)
let start = Date(); let history = ledger.stateHistory(now:now)
print("\(checks) performance correctness checks passed; synthetic \(observations.count) HRV / \(history.count) history points in \(String(format:"%.2f",Date().timeIntervalSince(start)*1000)) ms")
if CommandLine.arguments.count > 1 { try JSONEncoder().encode(ledger).write(to:URL(fileURLWithPath:CommandLine.arguments[1])) }
