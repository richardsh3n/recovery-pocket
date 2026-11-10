import Foundation
var checks = 0
func check(_ value:@autoclosure ()->Bool,_ name:String) { guard value() else { fatalError("FAIL: "+name) };checks += 1;print("PASS: "+name) }
let calendar = Calendar.current,day = calendar.startOfDay(for:Date()),now = day.addingTimeInterval(12*3600)
var status = PocketStatus(computedAt:now,measuredAt:now,value:50,lower:40,upper:60,charged:20,drained:10,message:"test",points:[],demo:false)
let fresh = PocketWidgetPresentation(status:status,at:now)
check(fresh.value == 50 && fresh.fraction == 0.5,"score 50 renders a 50 percent ring")
check(fresh.title == "身体电量" && fresh.showTotals,"fresh presentation permits score and daily totals")
let schedule = PocketWidgetSchedule.dates(status:status,now:now)
check(schedule.count == 2 && schedule[1] == now.addingTimeInterval(7201),"fresh entry schedules explicit two-hour expiry")
let expired = PocketWidgetPresentation(status:status,at:now.addingTimeInterval(7201))
check(expired.value == nil && expired.fraction == 0,"expired score clears value and gauge")
check(expired.title == "已过期" && !expired.showTotals,"expired state cannot show daily gains and drains as current")
check(PocketWidgetSchedule.dates(status:status,now:now.addingTimeInterval(7201)).count == 1,"already expired timeline contains no future fabricated score")
check(PocketWidgetPresentation(status:status,at:now.addingTimeInterval(7200)).value == 50,"two-hour boundary is consistent with main app")
status.demo = true
check(PocketWidgetPresentation(status:status,at:now).title == "演示","demo remains labeled in widget")
check(PocketWidgetPresentation(status:status,at:now.addingTimeInterval(7201)).title == "演示·过期","expired demo remains explicitly labeled")
status.demo = false;status.measuredAt = calendar.date(bySettingHour:23,minute:45,second:0,of:day)!;status.computedAt = status.measuredAt!
let midnight = calendar.date(byAdding:.day,value:1,to:day)!
check(PocketWidgetSchedule.dates(status:status,now:status.measuredAt!).last == midnight,"midnight expiry precedes two-hour timeout")
check(PocketWidgetPresentation(status:status,at:midnight).value == nil,"yesterday's complication clears at new day")
status.measuredAt = now.addingTimeInterval(3600)
check(PocketWidgetPresentation(status:status,at:now).value == nil,"future observation cannot appear current")
check(PocketWidgetSchedule.dates(status:status,now:now).count == 1,"future observation is not scheduled to become a later score")
status.measuredAt = now;status.value = 101
check(PocketWidgetPresentation(status:status,at:now).value == nil,"out-of-range score cannot render")
check(PocketWidgetPresentation(status:.empty,at:now).title == "待同步","empty data has a distinct waiting state")
check(PocketWidgetPresentation(status:.empty,at:now).detail == "请在 iPhone 刷新","empty Watch widget directs to the actual health-reading device")
print("\(checks) widget checks passed. Timeline logic only, not physical-device refresh verification.")
