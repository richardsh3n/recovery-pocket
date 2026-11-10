import Foundation

struct CalorieSample: Codable, Identifiable {
    var id: UUID
    var start: Date
    var end: Date
    var kcal: Double
    var source: String
    var sourceName: String
    var watch: Bool = false
    var syncIdentifier: String? = nil
    var syncVersion: Int? = nil
    var lowerKcal: Double? = nil
    var upperKcal: Double? = nil
}
struct BodyMeasurement: Codable, Identifiable {
    var id: UUID
    var date: Date
    var name: String
    var value: Double
    var unit: String
    var source: String
}
struct EnergyDayRecord: Codable, Identifiable {
    var date: Date
    var active: Double?
    var resting: Double?
    var restingHours: Double
    var restingSource: String?
    var intake: Double?
    var intakeSource: String?
    var intakeLower: Double?
    var intakeUpper: Double?
    var id: Date { date }
}
struct NutritionSource: Codable, Identifiable { var id: String; var name: String }
struct ManualEnergyEntry: Codable, Identifiable {
    var id: UUID
    var day: Date
    var recordedAt: Date
    var intake: Double?
    var foodComplete: Bool
    var scaleBMR: Double?
}
struct EnergyBudgetReport: Identifiable {
    var record: EnergyDayRecord
    var resting: Double?
    var intake: Double?
    var expenditure: Double?
    var difference: Double?
    var foodComplete: Bool
    var dayComplete: Bool
    var scaleReference: Bool
    var usableAsDailyEstimate: Bool
    var missing: [String]
    var foodOnlyDifferenceRange: ClosedRange<Double>?
    var id: Date { record.date }
    var differenceLabel: String {
        if !dayComplete { return "截至目前差额" }
        if !usableAsDailyEstimate { return "记录差额 · 待补齐" }
        if let range = foodOnlyDifferenceRange,range.lowerBound < 0 && range.upperBound > 0 { return "参考热量差 · 方向不确定" }
        return (difference ?? 0) >= 0 ? "参考热量缺口" : "参考热量盈余"
    }
}
enum EnergyBudgetEngine {
    static let lowerMetadata = "studio.rfg.food.estimateLowerKcal"
    static let upperMetadata = "studio.rfg.food.estimateUpperKcal"
    static func valid(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
    private static func cleaned(_ rows: [CalorieSample], now: Date) -> [CalorieSample] {
        let valid = rows.filter { $0.kcal.isFinite && $0.kcal >= 0 && $0.end >= $0.start && $0.end <= now && !$0.source.isEmpty }
        let ids = Dictionary(valid.map { ($0.id,$0) },uniquingKeysWith:{ a,b in (a.syncVersion ?? 0) >= (b.syncVersion ?? 0) ? a : b }).values
        var synced: [String: CalorieSample] = [:], unsynced: [CalorieSample] = []
        for row in ids {
            guard let identifier = row.syncIdentifier, !identifier.isEmpty else { unsynced.append(row);continue }
            let key = row.source+"::"+identifier
            if let old = synced[key] {
                let a = old.syncVersion ?? 0,b = row.syncVersion ?? 0
                if b > a || (b == a && (row.end > old.end || (row.end == old.end && row.id.uuidString < old.id.uuidString))) { synced[key] = row }
            } else { synced[key] = row }
        }
        return unsynced+synced.values
    }
    static func sources(_ rows:[CalorieSample]) -> [NutritionSource] {
        Dictionary(grouping:rows,by:\.source).map { NutritionSource(id:$0.key,name:$0.value.first?.sourceName ?? $0.key) }.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }
    static func select(_ rows:[CalorieSample],preferredSource:String?,watchFirst:Bool) -> [CalorieSample] {
        if let preferredSource,!preferredSource.isEmpty { return rows.filter { $0.source == preferredSource } }
        let candidates = watchFirst && rows.contains(where:\.watch) ? rows.filter(\.watch) : rows
        let groups = Dictionary(grouping:candidates,by:\.source)
        guard let latest = candidates.map(\.end).max() else { return [] }
        let selected = groups.sorted { a,b in
            let cutoff = latest.addingTimeInterval(-86400)
            let ca = a.value.filter { $0.end > cutoff }.count,cb = b.value.filter { $0.end > cutoff }.count
            if ca != cb { return ca > cb }
            let la = a.value.map(\.end).max()!,lb = b.value.map(\.end).max()!
            return la == lb ? a.key < b.key : la > lb
        }.first?.key
        return selected.flatMap { groups[$0] } ?? []
    }
    /// Interval energy stays separate from a scale's instantaneous kcal/day estimate.
    /// Use one source; overlaps prefer the finer-grained interval instead of summing twice.
    static func resting(_ rows:[CalorieSample],from:Date,to:Date) -> (kcal:Double?,hours:Double) {
        let spans = rows.filter { $0.kcal.isFinite && $0.kcal >= 0 && !$0.source.isEmpty && $0.end > $0.start && $0.start < to && $0.end > from }
        guard Set(spans.map(\.source)).count <= 1 else { return (nil,0) }
        let bounds = Array(Set(spans.flatMap { [max(from,$0.start),min(to,$0.end)] })).sorted()
        var seconds = 0.0,kcal = 0.0
        for (a,b) in zip(bounds,bounds.dropFirst()) {
            let active = spans.filter { $0.start < b && $0.end > a }.sorted {
                let da = $0.end.timeIntervalSince($0.start),db = $1.end.timeIntervalSince($1.start)
                if da != db { return da < db }
                if ($0.syncVersion ?? 0) != ($1.syncVersion ?? 0) { return ($0.syncVersion ?? 0) > ($1.syncVersion ?? 0) }
                return $0.id.uuidString < $1.id.uuidString
            }
            guard let row = active.first else { continue }
            let dt = b.timeIntervalSince(a);seconds += dt;kcal += row.kcal*dt/row.end.timeIntervalSince(row.start)
        }
        return (seconds > 0 ? kcal : nil,seconds/3600)
    }
    static func days(resting:[CalorieSample],intake:[CalorieSample],active:[EnergyDayRecord],start:Date,now:Date,foodSource:String? = nil,calendar:Calendar = .current) -> [EnergyDayRecord] {
        let rest = select(cleaned(resting,now:now).filter { $0.end > $0.start },preferredSource:nil,watchFirst:true)
        let food = select(cleaned(intake,now:now),preferredSource:foodSource,watchFirst:false)
        var result:[EnergyDayRecord] = [],date = calendar.startOfDay(for:start)
        while date <= now {
            let next = calendar.date(byAdding:.day,value:1,to:date)!,until = min(now,next)
            let r = self.resting(rest,from:date,to:until)
            let meals = food.filter { $0.start >= date && $0.start < next && $0.end <= now }
            let rangesValid = !meals.isEmpty && meals.allSatisfy { row in
                guard let lo = valid(row.lowerKcal),let hi = valid(row.upperKcal) else { return false };return lo <= row.kcal && row.kcal <= hi
            }
            result.append(EnergyDayRecord(date:date,active:valid(active.first { calendar.isDate($0.date,inSameDayAs:date) }?.active),resting:r.kcal,restingHours:r.hours,restingSource:r.kcal == nil ? nil : rest.first?.sourceName,intake:meals.isEmpty ? nil : meals.reduce(0) { $0+$1.kcal },intakeSource:meals.first?.sourceName,intakeLower:rangesValid ? meals.reduce(0) { $0+$1.lowerKcal! } : nil,intakeUpper:rangesValid ? meals.reduce(0) { $0+$1.upperKcal! } : nil))
            date = next
        }
        return result
    }
    static func report(_ record:EnergyDayRecord,manual:[ManualEnergyEntry],now:Date,calendar:Calendar = .current) -> EnergyBudgetReport {
        let day = calendar.startOfDay(for:record.date),end = calendar.date(byAdding:.day,value:1,to:day)!,until = min(now,end)
        if day > now { return EnergyBudgetReport(record:record,resting:nil,intake:nil,expenditure:nil,difference:nil,foodComplete:false,dayComplete:false,scaleReference:false,usableAsDailyEstimate:false,missing:["未来日期尚未发生"],foodOnlyDifferenceRange:nil) }
        let entry = manual.filter { calendar.isDate($0.day,inSameDayAs:day) && $0.recordedAt <= now }.max { $0.recordedAt < $1.recordedAt }
        let scale = manual.filter { $0.day <= until && $0.recordedAt <= now && until.timeIntervalSince($0.day) <= 30*86400 && $0.scaleBMR.map { $0.isFinite && (500...5000).contains($0) } == true }.max { $0.day < $1.day }
        let usingScale = valid(record.resting) == nil && scale != nil && until > day
        let rest = valid(record.resting) ?? (usingScale ? scale!.scaleBMR! * until.timeIntervalSince(day)/86400 : nil)
        let food = valid(entry?.intake) ?? valid(record.intake),activity = valid(record.active)
        let total = rest.flatMap { a in activity.map { a+$0 } }
        let difference = total.flatMap { a in food.map { a-$0 } }
        let complete = entry?.foodComplete == true,dayComplete = end <= now
        let coverage = record.restingHours.isFinite && record.restingHours >= 0 && record.restingHours*3600 >= max(0,until.timeIntervalSince(day))*0.9
        let qualified = dayComplete && complete && total != nil && food != nil && (usingScale || coverage)
        var missing:[String] = []
        if rest == nil { missing.append("没有可用静息能量；可输入 Keep 的代谢参考") }
        if activity == nil { missing.append("没有活动能量记录，未按 0 计算") }
        if food == nil { missing.append("尚未读到摄入；没有记录不等于没吃") }
        if !complete { missing.append("饮食记录未确认完整") }
        if !dayComplete { missing.append("今天尚未结束，只比较已过去时段") }
        if !usingScale && rest != nil && !coverage { missing.append("静息能量时间覆盖不足，不能当作全天消耗") }
        let range:ClosedRange<Double>? = entry?.intake == nil && difference != nil ? record.intakeLower.flatMap { lo in record.intakeUpper.flatMap { hi in lo.isFinite && hi.isFinite && lo <= hi ? (total!-hi)...(total!-lo) : nil } } : nil
        return EnergyBudgetReport(record:record,resting:rest,intake:food,expenditure:total,difference:difference,foodComplete:complete,dayComplete:dayComplete,scaleReference:usingScale,usableAsDailyEstimate:qualified,missing:missing,foodOnlyDifferenceRange:range)
    }
    static func demo(now:Date = Date(),calendar:Calendar = .current) -> [EnergyDayRecord] {
        let today = calendar.startOfDay(for:now)
        return (0..<7).reversed().map { offset in
            let day = calendar.date(byAdding:.day,value:-offset,to:today)!,end = calendar.date(byAdding:.day,value:1,to:day)!,hours = min(now,end).timeIntervalSince(day)/3600
            let fraction = hours/24,food = offset == 0 ? 1450.0 : 1950+sin(Double(offset))*120
            return EnergyDayRecord(date:day,active:offset == 0 ? 420 : 510+Double(offset)*35,resting:1780*fraction,restingHours:hours,restingSource:"合成演示",intake:food,intakeSource:"合成饮食估计",intakeLower:food*0.8,intakeUpper:food*1.2)
        }
    }
}
