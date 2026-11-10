import SwiftUI
import Charts

@MainActor final class EnergyBudgetLog: ObservableObject {
    @Published private(set) var entries:[ManualEnergyEntry] = []
    @Published var error:String?
    private var unreadable = false
    private var url:URL { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("RecoveryPocket").appendingPathComponent("energy-budget-manual.json") }
    init() { reload() }
    func reload() {
        do {entries=try ManualRecordTransaction.read(from:url).map{try JSONDecoder().decode([ManualEnergyEntry].self,from:$0)} ?? [];unreadable=false;error=nil}
        catch {unreadable=true;self.error="本地能量记录暂时无法读取；不会覆盖旧文件。解锁后重新打开页面。"}
    }
    func save(day:Date,intake:Double?,complete:Bool,bmr:Double?) -> Bool {
        guard !unreadable else { return false }
        guard intake == nil || EnergyBudgetEngine.valid(intake) != nil,bmr == nil || bmr.map({ $0.isFinite && (500...5000).contains($0) }) == true else { error = "请检查热量数值。";return false }
        var next = entries.filter { !Calendar.current.isDate($0.day,inSameDayAs:day) }
        next.append(ManualEnergyEntry(id:UUID(),day:Calendar.current.startOfDay(for:day),recordedAt:Date(),intake:intake,foodComplete:complete,scaleBMR:bmr))
        do {
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
            try ManualRecordTransaction.write(try JSONEncoder().encode(next),to:url);entries = next;error = nil;return true
        } catch { self.error = "保存未完成，请稍后重试。";return false }
    }
}
private func budgetNumber(_ value:Double?) -> String { value.map { String(format:"%.0f",$0) } ?? "—" }
struct EnergyBudgetView:View {
    @EnvironmentObject private var journal:IntegratedJournal
    @AppStorage("useLocalMealsV24") private var useLocalMeals=false
    @EnvironmentObject private var health:HealthStore
    @EnvironmentObject private var experience:PocketExperience
    @StateObject private var log = EnergyBudgetLog()
    @AppStorage("nutritionSource") private var nutritionSource = ""
    @State private var day = Calendar.current.startOfDay(for:Date())
    @State private var editing = false
    @State private var demoEntries:[ManualEnergyEntry] = []
    private var records:[EnergyDayRecord] { experience.demo ? EnergyBudgetEngine.demo() : health.snapshot?.energyBudget ?? [] }
    private var entries:[ManualEnergyEntry] { experience.demo ? demoEntries : log.entries }
    private var empty:EnergyDayRecord { EnergyDayRecord(date:day,active:nil,resting:nil,restingHours:0,restingSource:nil,intake:nil,intakeSource:nil,intakeLower:nil,intakeUpper:nil) }
    private var mealTotal:(value:Double,lower:Double,upper:Double,count:Int)? { PhotoFoodEngine.total(journal.visible(experience.demo).meals,day:day,now:Date()) }
    private var report:EnergyBudgetReport { makeReport(day) }
    private func makeReport(_ selected:Date)->EnergyBudgetReport {
        var record=records.first { Calendar.current.isDate($0.date,inSameDayAs:selected) } ?? EnergyDayRecord(date:selected,active:nil,resting:nil,restingHours:0,restingSource:nil,intake:nil,intakeSource:nil,intakeLower:nil,intakeUpper:nil)
        var manual=entries
        if useLocalMeals {
            let mealTotal=PhotoFoodEngine.total(journal.visible(experience.demo).meals,day:selected,now:Date())
            record.intake=mealTotal?.value;record.intakeLower=mealTotal?.lower;record.intakeUpper=mealTotal?.upper;record.intakeSource=mealTotal == nil ? nil:"本机已确认餐次"
            manual=entries.map { row in var adjusted=row;if Calendar.current.isDate(row.day,inSameDayAs:selected){adjusted.intake=nil};return adjusted }
        }
        return EnergyBudgetEngine.report(record,manual:manual,now:Date())
    }
    private var week:[EnergyBudgetReport] { (0..<7).reversed().compactMap{Calendar.current.date(byAdding:.day,value:-$0,to:day)}.map{makeReport($0)} }
    private var bodyRecords:[BodyMeasurement] { experience.demo ? [BodyMeasurement(id:UUID(),date:Date(),name:"体重",value:80.1,unit:"kg",source:"合成演示"),BodyMeasurement(id:UUID(),date:Date(),name:"体脂",value:22.5,unit:"%",source:"合成演示"),BodyMeasurement(id:UUID(),date:Date(),name:"去脂体重",value:62.1,unit:"kg",source:"合成演示")] : health.snapshot?.bodyMeasurements ?? [] }
    private var weightPoints:[BodyMeasurement] {
        let until = min(Date(),Calendar.current.date(byAdding:.day,value:1,to:Calendar.current.startOfDay(for:day))!)
        let rows = bodyRecords.filter { $0.name == "体重" && $0.date <= until && $0.date >= until.addingTimeInterval(-28*86400) }.sorted { $0.date < $1.date }
        guard let source = rows.last?.source else { return [] };return rows.filter { $0.source == source }
    }
    var body:some View {
        ScrollView { VStack(alignment:.leading,spacing:24) {
            DemoNote()
            if let error=log.error {Text(error).font(.caption).foregroundStyle(PocketStyle.drain)}
            Text("把消耗和摄入放在一起").font(.title2.weight(.semibold))
            Toggle("使用本机餐次作为摄入来源",isOn:$useLocalMeals)
            Text(useLocalMeals ? "本机餐次替代健康/手动摄入，不相加。完整性仍需单独确认。":"使用原有健康或手动摄入；餐次不会重复追加。").font(.caption).foregroundStyle(.secondary)
            NavigationLink("管理照片饮食结果与餐次"){PhotoFoodView()}
            HStack {
                Button { move(-1) } label:{ Image(systemName:"chevron.left").frame(width:44,height:44) }.accessibilityLabel("前一天")
                Spacer();DatePicker("日期",selection:$day,in:...Date(),displayedComponents:.date).labelsHidden();Spacer()
                Button { move(1) } label:{ Image(systemName:"chevron.right").frame(width:44,height:44) }.disabled(Calendar.current.isDateInToday(day)).accessibilityLabel("后一天")
            }
            VStack(alignment:.leading,spacing:14) {
                Text(report.differenceLabel).font(.headline)
                HStack(alignment:.firstTextBaseline) { Text(report.difference.map { String(format:"%+.0f",$0) } ?? "—").font(.system(size:56,weight:.light));Text("kcal").foregroundStyle(.secondary) }.foregroundStyle(PocketStyle.green)
                Text("正数为消耗高于已记录摄入，负数相反。都是估算，不是实测代谢。").font(.caption).foregroundStyle(.secondary)
                HStack(alignment:.top) { metric("总消耗",report.expenditure);Spacer();metric("摄入",report.intake) }
                Divider();LabeledContent("静息能量",value:budgetNumber(report.resting)+" kcal");LabeledContent("活动能量",value:budgetNumber(report.record.active)+" kcal")
                Text(report.scaleReference ? "静息项使用手动输入的 Keep 代谢参考，按已过去时间分配；不与健康静息能量相加。" : experience.demo ? "静息与活动均为合成演示；训练不重复累加。" : "静息项来自 Apple 健康；训练已包含在活动能量，不重复累加。").font(.caption).foregroundStyle(.secondary)
                if let range = report.foodOnlyDifferenceRange { Text("饮食估计带来的差额范围：\(budgetNumber(range.lowerBound))～\(budgetNumber(range.upperBound)) kcal").font(.subheadline);Text("仅传播食物输入范围，尚未计入消耗估计误差；不是置信区间。").font(.caption).foregroundStyle(.secondary) }
            }.padding(20).background(PocketStyle.green.opacity(0.055),in:RoundedRectangle(cornerRadius:22))
            VStack(alignment:.leading,spacing:10) {
                Text("这一天的数据是否齐全？").font(.headline)
                LabeledContent("饮食确认",value:report.foodComplete ? "已确认记全" : "未确认")
                LabeledContent("健康静息覆盖",value:String(format:"%.1f 小时",report.record.restingHours))
                LabeledContent("静息来源",value:report.scaleReference ? "手动 Keep 参考" : report.record.restingSource ?? "未读到")
                LabeledContent("摄入来源",value:useLocalMeals ? (report.record.intakeSource ?? "未读到本机餐次") : entries.first { Calendar.current.isDate($0.day,inSameDayAs:day) }?.intake != nil ? "手动记录" : report.record.intakeSource ?? "未读到")
                ForEach(report.missing,id:\.self) { Text("• "+$0).font(.caption).foregroundStyle(.secondary) }
                Button("记录摄入／确认饮食／填写秤代谢") { editing = true }.buttonStyle(.borderedProminent)
            }
            Divider();Text("近七天能量收支").font(.title3.weight(.semibold))
            Chart(week) { row in
                if let rest = row.resting { BarMark(x:.value("日期",row.record.date,unit:.day),y:.value("kcal",rest)).foregroundStyle(by:.value("项目","静息")) }
                if let active = row.record.active { BarMark(x:.value("日期",row.record.date,unit:.day),y:.value("kcal",active)).foregroundStyle(by:.value("项目","活动")) }
                if let food = row.intake { PointMark(x:.value("日期",row.record.date,unit:.day),y:.value("摄入",food)).foregroundStyle(PocketStyle.drain).symbolSize(40) }
            }.chartForegroundStyleScale(["静息":PocketStyle.green.opacity(0.5),"活动":PocketStyle.green]).chartYAxisLabel("kcal").frame(height:200).accessibilityLabel("近七天静息和活动消耗柱图，橙点为摄入；缺失不补零。")
            Text("橙点为摄入；今天只有截至目前的记录。缺失保持空白，未确认饮食的日期不用于判断全天缺口。").font(.caption).foregroundStyle(.secondary)
            Divider();Text("Keep 与身体记录").font(.title3.weight(.semibold))
            ForEach(["体重","体脂","去脂体重","身高"],id:\.self) { name in
                let latest = bodyRecords.filter { $0.name == name && $0.date <= min(Date(),Calendar.current.date(byAdding:.day,value:1,to:Calendar.current.startOfDay(for:day))!) }.max { $0.date < $1.date }
                VStack(alignment:.leading,spacing:4) { LabeledContent(name,value:latest.map { String(format:"%.1f",$0.value)+" "+$0.unit } ?? "—");Text(latest.map { $0.source+" · "+$0.date.formatted(date:.abbreviated,time:.omitted) } ?? "未读到；是否同步取决于 Keep 的设备和授权项目").font(.caption).foregroundStyle(.secondary) }
            }
            if weightPoints.count >= 2 {
                Text("近 28 天同来源体重").font(.headline)
                Chart(weightPoints) { row in LineMark(x:.value("日期",row.date),y:.value("kg",row.value)).foregroundStyle(PocketStyle.green);PointMark(x:.value("日期",row.date),y:.value("kg",row.value)).foregroundStyle(PocketStyle.green) }.chartYAxisLabel("kg").frame(height:150)
                Text("用于回看，暂不根据体重变化自动修改代谢或身体电量系数。").font(.caption).foregroundStyle(.secondary)
            }
            Text("体脂与去脂体重保留原来源，不把不同日期或不同来源拼成新测量。秤的基础代谢通常是估算，若未同步可手动填写；它不等于真实全天总消耗。").font(.caption).foregroundStyle(.secondary)
            if !experience.demo {
                Picker("饮食数据来源",selection:$nutritionSource) { Text("自动选一个来源").tag("");ForEach(health.snapshot?.nutritionSources ?? []) { Text($0.name).tag($0.id) } }.onChange(of:nutritionSource) { _,_ in Task { await health.refresh() } }
                NavigationLink("选择读取能量与身体数据") { HealthConnectionView() }
                if let error = log.error { Text(error).foregroundStyle(PocketStyle.drain).font(.caption) }
            }
            Divider();Text("接入你的拍照饮食 App").font(.headline)
            Text("饮食 App 确认份量后，把同一餐的估计写入 Apple 健康“膳食能量”。用固定餐次 ID 和递增版本更新，避免重复。AI 的份量、油和酱料不明确时先确认，估计范围可一起传入。").font(.caption).foregroundStyle(.secondary)
            Text("这些记录暂不自动改变身体电量。先积累完整消耗、饮食、体重和体感记录，再检验它们是否能改善个人估计。").font(.caption).foregroundStyle(.secondary)
        }.padding(24) }.background(PocketStyle.paper).navigationTitle("能量收支").toolbar(.visible,for:.navigationBar).tint(PocketStyle.green)
        .onChange(of:journal.revision){_,_ in if !experience.demo{log.reload()}}
        .sheet(isPresented:$editing) { EnergyBudgetEditor(day:day,existing:entries.first { Calendar.current.isDate($0.day,inSameDayAs:day) }) { intake,complete,bmr in
            if experience.demo { demoEntries.removeAll { Calendar.current.isDate($0.day,inSameDayAs:day) };demoEntries.append(ManualEnergyEntry(id:UUID(),day:day,recordedAt:Date(),intake:intake,foodComplete:complete,scaleBMR:bmr));return true }
            return log.save(day:day,intake:intake,complete:complete,bmr:bmr)
        } }
    }
    private func metric(_ name:String,_ value:Double?) -> some View { VStack(alignment:.leading,spacing:5) { Text(name).font(.caption).foregroundStyle(.secondary);Text(budgetNumber(value)).font(.title2.weight(.medium)) } }
    private func move(_ delta:Int) { if let next = Calendar.current.date(byAdding:.day,value:delta,to:day),next <= Date() { day = next } }
}
private struct EnergyBudgetEditor:View {
    let day:Date
    let existing:ManualEnergyEntry?
    let save:(Double?,Bool,Double?) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var intake = ""
    @State private var bmr = ""
    @State private var complete = false
    @State private var error:String?
    var body:some View {
        NavigationStack { Form {
            Section("摄入记录") { TextField("当日摄入 kcal（空白使用健康记录）",text:$intake).keyboardType(.decimalPad);Toggle("这一天的饮食已经记全",isOn:$complete);Text("明确录入 0 才表示记录了零摄入；空白是未知。手动摄入替代这一天的健康摄入，不把两者相加。").font(.caption).foregroundStyle(.secondary) }
            Section("Keep 秤的基础代谢参考") { TextField("kcal / 24 小时（可选）",text:$bmr).keyboardType(.decimalPad);Text("填写秤报告中的代谢估计；仅在当天没有健康静息能量时作为参考，最多沿用 30 天。它不是全天总消耗。").font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle(day.formatted(.dateTime.month().day())).toolbar(.visible,for:.navigationBar).toolbar { ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() } };ToolbarItem(placement:.confirmationAction) { Button("保存") {
            let a = intake.isEmpty ? nil : Double(intake.replacingOccurrences(of:",",with:".")),b = bmr.isEmpty ? nil : Double(bmr.replacingOccurrences(of:",",with:"."))
            guard intake.isEmpty || a.map({ $0.isFinite && (0...20000).contains($0) }) == true,bmr.isEmpty || b.map({ $0.isFinite && (500...5000).contains($0) }) == true else { error = "请输入有效 kcal 数值。";return }
            if save(a,complete,b) { dismiss() } else { error = "保存未完成，已有记录保留。" }
        } } }.onAppear { intake = existing?.intake.map { String(format:"%.0f",$0) } ?? "";bmr = existing?.scaleBMR.map { String(format:"%.0f",$0) } ?? "";complete = existing?.foodComplete ?? false }
        }
    }
}
