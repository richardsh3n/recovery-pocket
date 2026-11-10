import Foundation
let start = Calendar.current.startOfDay(for:Date()),now = start.addingTimeInterval(24*3600)
for (name,sleep,hrv,kcal) in [("8小时睡眠，中性HRV，350kcal",8.0,0.0,350.0),("8小时睡眠，低HRV，350kcal",8.0,-2.0,350.0),("8小时睡眠，较高HRV，350kcal",8.0,1.0,350.0),("4小时睡眠，中性HRV，350kcal",4.0,0.0,350.0),("8小时睡眠，中性HRV，1000kcal",8.0,0.0,1000.0)] {
 let hours = (0..<24).map { h -> BatteryHour in let asleep = Double(h) < sleep; return BatteryHour(start:start.addingTimeInterval(Double(h)*3600),end:start.addingTimeInterval(Double(h+1)*3600),sleepHours:asleep ? 1 : 0,activeKcal:asleep ? 0 : kcal/(24-sleep),heartRate:asleep ? 55 : 70,heartRateCount:30,heartRateCoverageHours:0.5,sleepHRVZ:asleep ? hrv : nil,sleepHRVCount:asleep ? 4 : nil,awakeHeartRate:asleep ? nil : 70,awakeHeartRateCount:asleep ? 0 : 30,awakeHeartRateCoverageHours:asleep ? 0 : 0.5) }
 let result = BatteryModel.calculate(hours:hours,anchor:50,baselineHR:55,now:now)
 let report = EnergyInsights.day(points:result.points,day:start,now:now)
 print(name,"最高=",Int(result.points.compactMap(\.value).max()!.rounded()),"结束=",result.value!,"分项核对=",report.balance != nil)
}
