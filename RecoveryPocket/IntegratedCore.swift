import Foundation
import CryptoKit
import Darwin

// MARK: Sleep episodes. Gap policy groups fragments; asleep duration is interval union.
struct SleepEpisode: Identifiable {
  var intervals: [SleepInterval]
  var start: Date { intervals.first!.start }
  var end: Date { intervals.last!.end }
  var hours: Double { intervals.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) / 3600 } }
  var id: Date { start }
}
enum SleepEpisodeEngine {
  static func episodes(_ input: [SleepInterval], now: Date, gap: TimeInterval = 5400)
    -> [SleepEpisode]
  {
    let rows = RecoveryEngine.merged(
      input.filter { $0.end > $0.start && $0.end <= now }, from: .distantPast, to: now)
    var result: [SleepEpisode] = []
    for row in rows {
      if let previous = result.last, row.start.timeIntervalSince(previous.end) <= max(0, gap) {
        result[result.count - 1].intervals.append(row)
      } else {
        result.append(SleepEpisode(intervals: [row]))
      }
    }
    return result
  }
  static func main(_ episodes: [SleepEpisode], day: Date, calendar: Calendar = .current)
    -> SleepEpisode?
  {
    episodes.filter { calendar.isDate($0.end.addingTimeInterval(-0.001), inSameDayAs: day) }.sorted
    {
      $0.hours == $1.hours ? $0.end > $1.end : $0.hours > $1.hours
    }.first
  }
}

// MARK: Prospective validation, one observation per day/model, no backfill.
struct PersonalValidation {
  var totalDays: Int
  var trainingDays: Int
  var testDays: Int
  var splitDate: Date?
  var modelMAE: Double?
  var fixedMAE: Double?
  var previousMAE: Double?
  var falseHigh: Int
  var blocks: [CalibrationBlock]
  var ready: Bool { trainingDays >= 14 && testDays >= 7 && modelMAE != nil }
  var improvesBaseline: Bool {
    guard let modelMAE, let fixedMAE, let previousMAE else { return false }
    return modelMAE < min(fixedMAE, previousMAE)
  }
}
struct CalibrationBlock {
  var upper: Double
  var total: Double
  var count: Int
  var mean: Double { total / Double(count) }
}
enum PersonalValidationEngine {
  static func fit(_ pairs: [FeedbackPair]) -> [CalibrationBlock] {
    let grouped = Dictionary(grouping: pairs, by: { $0.prediction.value })
    var blocks: [CalibrationBlock] = []
    for key in grouped.keys.sorted() {
      let rows = grouped[key]!
      blocks.append(
        CalibrationBlock(
          upper: Double(key), total: rows.reduce(0) { $0 + Double($1.event.energy) },
          count: rows.count))
      while blocks.count >= 2, blocks[blocks.count - 2].mean > blocks.last!.mean {
        let b = blocks.removeLast()
        let a = blocks.removeLast()
        blocks.append(
          CalibrationBlock(upper: b.upper, total: a.total + b.total, count: a.count + b.count))
      }
    }
    return blocks
  }
  static func predicted(_ value: Double, blocks: [CalibrationBlock]) -> Double? {
    guard value.isFinite, !blocks.isEmpty else { return nil }
    return (blocks.first { $0.upper >= value } ?? blocks.last!).mean
  }
  static func evaluate(
    events: [PocketEvent], group: String, now: Date, calendar: Calendar = .current
  ) -> PersonalValidation {
    let paired = FeedbackEngine.pairs(events, now: now).filter { $0.group == group }
    let byDay = Dictionary(grouping: paired, by: { calendar.startOfDay(for: $0.event.date) })
    // Earliest deliberate check-in per local day. Do not optimise selection on its score.
    let rows = byDay.keys.sorted().compactMap {
      byDay[$0]!.sorted {
        $0.event.date == $1.event.date
          ? $0.id.uuidString < $1.id.uuidString : $0.event.date < $1.event.date
      }.first
    }
    guard rows.count >= 21 else {
      return PersonalValidation(
        totalDays: rows.count, trainingDays: rows.count, testDays: 0, splitDate: nil, modelMAE: nil,
        fixedMAE: nil, previousMAE: nil, falseHigh: 0, blocks: [])
    }
    let train = Array(rows.dropLast(7))
    let test = Array(rows.suffix(7))
    let blocks = fit(train)
    let fixed = RecoveryEngine.median(train.map { Double($0.event.energy) })!
    let errors = test.map {
      abs(predicted(Double($0.prediction.value), blocks: blocks)! - Double($0.event.energy))
    }
    var prior = Double(train.last!.event.energy)
    var previousErrors: [Double] = []
    for pair in test {
      previousErrors.append(abs(prior - Double(pair.event.energy)))
      prior = Double(pair.event.energy)
    }
    return PersonalValidation(
      totalDays: rows.count, trainingDays: train.count, testDays: test.count,
      splitDate: test.first!.event.date, modelMAE: WellnessEngine.mean(errors),
      fixedMAE: WellnessEngine.mean(test.map { abs(fixed - Double($0.event.energy)) }),
      previousMAE: WellnessEngine.mean(previousErrors),
      falseHigh: test.filter { $0.prediction.value >= 75 && $0.event.energy <= 2 }.count,
      blocks: blocks)
  }
}

// MARK: Independent training dose and a shadow reserve candidate. Never promotes itself.
struct TrainingDose: Identifiable {
  var workout: PocketWorkout
  var effort: PocketEvent?
  var id: UUID { workout.id }
  var cardio: Double? {
    workout.cardio?.relativeLoadMinutes.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
  }
  var coverage: Double { workout.cardio?.coverageFraction ?? 0 }
}
struct TrainingDoseComparison: Codable {
  var energyOnly: Double?
  var cardioOnly: Double?
  var candidate: Double?
  var deltaFromEnergy: Double? {
    guard let candidate, let energyOnly else { return nil }
    return candidate - energyOnly
  }
}
enum TrainingDoseEngine {
  static func doses(workouts: [PocketWorkout], events: [PocketEvent], now: Date) -> [TrainingDose] {
    WellnessEngine.workouts(workouts, now: now).map { workout in
      let effort = events.filter {
        $0.workoutID == workout.id && $0.date <= now && $0.sessionLoad != nil
      }.max { $0.date < $1.date }
      return TrainingDose(workout: workout, effort: effort)
    }
  }
  /// One-channel substitution for a sensitivity study; 25% blend is an engineering
  /// experiment, not a calibrated coefficient. A scalar effect is not causal.
  static func candidateDrain(kcal: Double?, cardioMinutes: Double?, coverage: Double) -> Double? {
    comparison(kcal: kcal, cardioMinutes: cardioMinutes, coverage: coverage).candidate
  }
  static func comparison(kcal: Double?, cardioMinutes: Double?, coverage: Double)
    -> TrainingDoseComparison
  {
    let energy = kcal.flatMap { $0.isFinite && $0 >= 0 ? $0 / 35 : nil }
    let cardio = cardioMinutes.flatMap {
      $0.isFinite && $0 >= 0 && coverage.isFinite && (0.8...1).contains(coverage)
        ? min(100, $0 / 10) : nil
    }
    let candidate: Double?
    switch (energy, cardio) {
    case (let a?, let b?): candidate = 0.75 * a + 0.25 * b
    case (let a?, nil): candidate = a
    case (nil, let b?): candidate = b
    default: candidate = nil
    }
    return TrainingDoseComparison(energyOnly: energy, cardioOnly: cardio, candidate: candidate)
  }
}

struct HabitComparison: Identifiable {
  var key: String
  var yesDays: Int
  var noDays: Int
  var difference: Double?
  var id: String { key }
}
enum HabitEvidenceEngine {
  static let names = ["caffeine": "咖啡因", "alcohol": "饮酒", "lateMeal": "临睡前进食"]
  static func compare(events: [PocketEvent], now: Date, calendar: Calendar = .current)
    -> [HabitComparison]
  {
    let rows = events.filter {
      $0.date <= now && $0.date >= now.addingTimeInterval(-56 * 86400)
        && (1...5).contains($0.energy)
    }
    let days = Dictionary(grouping: rows, by: { calendar.startOfDay(for: $0.date) })
    return names.keys.sorted().map { key in
      var yes: [Double] = []
      var no: [Double] = []
      for day in days.keys.sorted() {
        let records = days[day]!.sorted { $0.date < $1.date }
        guard
          let answer = records.last(where: { $0.habitAnswers?[key] != nil })?.habitAnswers?[key],
          let feeling = WellnessEngine.mean(records.map { Double($0.energy) })
        else { continue }
        if answer { yes.append(feeling) } else { no.append(feeling) }
      }
      return HabitComparison(
        key: key, yesDays: yes.count, noDays: no.count,
        difference: yes.count >= 5 && no.count >= 5
          ? WellnessEngine.mean(yes)! - WellnessEngine.mean(no)! : nil)
    }
  }
}

struct PocketAction: Codable, Identifiable {
  var id: UUID = UUID()
  var createdAt: Date
  var title: String
  var evidence: String
  var completedAt: Date?
  var helpful: Int?
}
struct PhotoMeal: Codable, Identifiable {
  var id: UUID
  var revision: Int
  var date: Date
  var title: String
  var kcal: Double
  var lower: Double
  var upper: Double
  var notes: String
  var confirmed: Bool
  func valid(now: Date) -> Bool {
    revision >= 1 && revision <= 100000 && date <= now && title.count <= 200 && !title.isEmpty
      && notes.count <= 2000
      && [kcal, lower, upper].allSatisfy { $0.isFinite && (0...10000).contains($0) }
      && lower <= kcal && kcal <= upper
  }
}
struct MealEnvelope: Codable {
  var schemaVersion: Int
  var meal: PhotoMeal
}
enum PhotoFoodEngine {
  static func parse(_ data: Data, now: Date) -> PhotoMeal? {
    guard data.count <= 100000, let x = try? JSONDecoder.iso.decode(MealEnvelope.self, from: data),
      x.schemaVersion == 1, x.meal.valid(now: now)
    else { return nil }
    var row = x.meal
    row.confirmed = false
    return row
  }
  static func merged(_ existing: [PhotoMeal], incoming: PhotoMeal, now: Date) -> [PhotoMeal]? {
    guard incoming.valid(now: now) else { return nil }
    if let old = existing.first(where: { $0.id == incoming.id }), old.revision >= incoming.revision
    {
      return nil
    }
    return existing.filter { $0.id != incoming.id } + [incoming]
  }
  static func total(_ input: [PhotoMeal], day: Date, now: Date, calendar: Calendar = .current) -> (
    value: Double, lower: Double, upper: Double, count: Int
  )? {
    let unique = Dictionary(
      input.filter { $0.confirmed && $0.valid(now: now) }.map { ($0.id, $0) },
      uniquingKeysWith: { $0.revision >= $1.revision ? $0 : $1 }
    ).values.filter { calendar.isDate($0.date, inSameDayAs: day) }
    guard !unique.isEmpty else { return nil }
    return (
      unique.reduce(0) { $0 + $1.kcal }, unique.reduce(0) { $0 + $1.lower },
      unique.reduce(0) { $0 + $1.upper }, unique.count
    )
  }
}
extension JSONDecoder {
  static var iso: JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }
}
extension JSONEncoder {
  static var iso: JSONEncoder {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    return e
  }
}
struct IntegratedRecords: Codable {
  var schemaVersion = 1
  var actions: [PocketAction] = []
  var meals: [PhotoMeal] = []
}
struct PocketBackup: Codable {
  var schemaVersion = 1
  var createdAt: Date
  var demo: Bool
  var events: [PocketEvent]
  var records: IntegratedRecords
  var manualEnergy: [ManualEnergyEntry]
  func valid(now: Date) -> Bool {
    (schemaVersion == 1 || schemaVersion == 2) && records.schemaVersion == 1 && createdAt <= now.addingTimeInterval(60)
      && events.count <= 10000 && records.actions.count <= 10000 && records.meals.count <= 10000
      && manualEnergy.count <= 10000 && Set(events.map(\.id)).count == events.count
      && Set(records.meals.map(\.id)).count == records.meals.count
      && Set(records.actions.map(\.id)).count == records.actions.count
      && events.allSatisfy {
        $0.date <= now && (1...5).contains($0.energy) && $0.note.count <= 4000
          && $0.kind.count <= 40
          && ($0.recordedAt == nil || $0.recordedAt! <= now)
          && ($0.modifiedAt == nil || $0.modifiedAt! <= now)
          && ($0.modelComparison == nil || $0.modelComparison!.validPrediction(at:now))
          && $0.habitAnswers?.keys.allSatisfy { HabitEvidenceEngine.names[$0] != nil } != false
          && ($0.trainingMinutes == nil
            || $0.trainingMinutes.map { $0.isFinite && $0 > 0 && $0 <= 1440 } == true)
          && ($0.sessionRPE == nil || $0.sessionLoad != nil)
      } && records.meals.allSatisfy { $0.valid(now: now) }
      && records.actions.allSatisfy {
        $0.createdAt <= now && !$0.title.isEmpty && $0.title.count <= 500
          && $0.evidence.count <= 4000
          && ($0.completedAt == nil || ($0.completedAt! >= $0.createdAt && $0.completedAt! <= now))
          && ($0.helpful == nil || (1...5).contains($0.helpful!))
      }
      && manualEnergy.allSatisfy {
        $0.day <= now && $0.recordedAt <= now
          && ($0.intake == nil || EnergyBudgetEngine.valid($0.intake) != nil)
          && ($0.scaleBMR == nil
            || $0.scaleBMR.map { $0.isFinite && (500...5000).contains($0) } == true)
      }
  }
}

enum IntegratedReadiness {
  static func note(status: PocketStatus, readAt: Date?, failures: Int, now: Date) -> String {
    guard let readAt else { return "尚未完成读取；先连接 Apple 健康" }
    if readAt > now.addingTimeInterval(60) { return "读取时间异常，请重新同步" }
    if failures > 0 { return "部分读取失败，可用数据仍保留；查看具体类型" }
    if !status.isFresh(at: now) { return "读取已完成，但当前观测过期或缺失" }
    return "已有近期观测 · 分数仍为实验估计"
  }
}

enum ManualRecoveryOutcome:String,Codable {case none,rolledBack,committed}
struct ManualRecoveryReport:Codable {
  var version=1
  var date:Date
  var transactionID:UUID
  var outcome:ManualRecoveryOutcome
  var files:Int
  var cleanupPending:Bool
}
enum ManualRestoreCheckpoint:Equatable {case prepared,wroteFile(Int),committed}
enum ManualRestoreError:Error,LocalizedError {
  case unsafeLocation,corruptJournal,busy,tooLarge,pendingCleanup
  var errorDescription:String? {
    switch self {
    case .unsafeLocation:return "记录路径异常，已停止覆盖。"
    case .corruptJournal:return "恢复记录无法核验，已保留全部文件并停止修改。"
    case .busy:return "记录正在由另一个操作处理，请稍后重试。"
    case .tooLarge:return "记录过大，暂未覆盖本机文件。"
    case .pendingCleanup:return "恢复已核验，但文件整理尚未完成；暂时不能修改记录。"
    }
  }
}
/// The three manual stores share a durable write-ahead journal and a nonblocking lock.
/// Process termination is tested; filesystem/power-loss durability on a phone is not claimed.
enum ManualRecordTransaction {
  static let allowedNames:Set<String>=["events-v1.json","integrated-v1.json","energy-budget-manual.json"]
  private static let journalName="manual-restore-journal-v1.json"
  private static let reportName="manual-restore-report-v1.json"
  private static let lockName="manual-records.lock"
  private struct Entry:Codable {
    var name:String
    var existed:Bool
    var original:Data?
    var originalSHA256:String?
    var newSHA256:String
  }
  private enum Phase:String,Codable {case prepared,committed}
  private struct Journal:Codable {
    var version=1
    var id:UUID
    var phase:Phase
    var entries:[Entry]
  }
  private static func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
  private static func regularOrMissing(_ url:URL)throws {
    guard FileManager.default.fileExists(atPath:url.path) else {
      // fileExists returns false for a dangling symlink; still reject that directory entry.
      if (try? FileManager.default.destinationOfSymbolicLink(atPath:url.path)) != nil {throw ManualRestoreError.unsafeLocation}
      return
    }
    let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else{throw ManualRestoreError.unsafeLocation}
  }
  private static func boundedRead(_ url:URL,limit:Int)throws->Data {
    try regularOrMissing(url)
    let handle=try FileHandle(forReadingFrom:url)
    defer{try? handle.close()}
    var result=Data()
    while let chunk=try handle.read(upToCount:min(65536,limit-result.count+1)),!chunk.isEmpty {
      result.append(chunk)
      guard result.count<=limit else{throw ManualRestoreError.tooLarge}
    }
    return result
  }
  private static func syncFile(_ url:URL)throws {
    let fd=open(url.path,O_RDONLY)
    guard fd>=0 else{throw CocoaError(.fileReadNoPermission)}
    defer{close(fd)}
    guard fsync(fd)==0 else{throw CocoaError(.fileWriteUnknown)}
  }
  private static func syncDirectory(_ directory:URL)throws {
    let fd=open(directory.path,O_RDONLY)
    guard fd>=0 else{throw CocoaError(.fileReadNoPermission)}
    defer{close(fd)}
    guard fsync(fd)==0 else{throw CocoaError(.fileWriteUnknown)}
  }
  private static func atomicWrite(_ data:Data,to url:URL)throws {
    try regularOrMissing(url)
    #if os(iOS)
    try data.write(to:url,options:[.atomic,.completeFileProtection])
    #else
    try data.write(to:url,options:.atomic)
    #endif
    try syncFile(url)
    try syncDirectory(url.deletingLastPathComponent())
  }
  private static func locked<T>(directory:URL,_ body:(URL)throws->T)throws->T {
    let root=directory.standardizedFileURL.resolvingSymlinksInPath()
    #if os(iOS)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
    #else
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    #endif
    if try root.resourceValues(forKeys:[.isExcludedFromBackupKey]).isExcludedFromBackup != true {
      var excluded=root,flags=URLResourceValues();flags.isExcludedFromBackup=true;try excluded.setResourceValues(flags)
    }
    let lock=root.appendingPathComponent(lockName)
    try regularOrMissing(lock)
    let fd=open(lock.path,O_CREAT|O_RDWR,S_IRUSR|S_IWUSR)
    guard fd>=0 else{throw CocoaError(.fileWriteNoPermission)}
    defer{close(fd)}
    guard flock(fd,LOCK_EX|LOCK_NB)==0 else{throw ManualRestoreError.busy}
    defer{flock(fd,LOCK_UN)}
    return try body(root)
  }
  private static func target(_ url:URL,root:URL)throws->URL {
    guard allowedNames.contains(url.lastPathComponent),url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()==root else {throw ManualRestoreError.unsafeLocation}
    let canonical=root.appendingPathComponent(url.lastPathComponent)
    try regularOrMissing(canonical)
    return canonical
  }
  private static func loadJournal(root:URL)throws->Journal? {
    let url=root.appendingPathComponent(journalName)
    try regularOrMissing(url)
    guard FileManager.default.fileExists(atPath:url.path) else{return nil}
    let data=try boundedRead(url,limit:72*1024*1024)
    guard data.count<=72*1024*1024,let journal=try? JSONDecoder().decode(Journal.self,from:data),journal.version==1,
          !journal.entries.isEmpty,journal.entries.count<=3,Set(journal.entries.map(\.name)).count==journal.entries.count else{throw ManualRestoreError.corruptJournal}
    for entry in journal.entries {
      guard allowedNames.contains(entry.name),entry.newSHA256.count==64,
            entry.newSHA256.allSatisfy({"0123456789abcdef".contains($0)}) else{throw ManualRestoreError.corruptJournal}
      _ = try target(root.appendingPathComponent(entry.name),root:root)
      if entry.existed {
        guard let original=entry.original,original.count<=32*1024*1024,entry.originalSHA256==digest(original) else{throw ManualRestoreError.corruptJournal}
      } else if entry.original != nil || entry.originalSHA256 != nil {throw ManualRestoreError.corruptJournal}
    }
    return journal
  }
  private static func cleanup(root:URL) {
    try? FileManager.default.removeItem(at:root.appendingPathComponent(journalName))
    try? syncDirectory(root)
  }
  private static func report(_ outcome:ManualRecoveryOutcome,journal:Journal,root:URL) {
    let value=ManualRecoveryReport(date:Date(),transactionID:journal.id,outcome:outcome,files:journal.entries.count,
      cleanupPending:FileManager.default.fileExists(atPath:root.appendingPathComponent(journalName).path))
    if let data=try? JSONEncoder().encode(value) {try? atomicWrite(data,to:root.appendingPathComponent(reportName))}
  }
  private static func recoverLocked(root:URL,onRollbackFile:((Int)->Void)?=nil)throws->ManualRecoveryOutcome {
    guard let journal=try loadJournal(root:root) else{return .none}
    if journal.phase == .committed {
      for entry in journal.entries {
        let url=try target(root.appendingPathComponent(entry.name),root:root)
        guard let data=try? boundedRead(url,limit:32*1024*1024),digest(data)==entry.newSHA256 else{throw ManualRestoreError.corruptJournal}
      }
      cleanup(root:root);report(.committed,journal:journal,root:root)
      return .committed
    }
    // All paths and original snapshots were validated before any rollback write.
    for (index,entry) in journal.entries.enumerated() {
      let url=try target(root.appendingPathComponent(entry.name),root:root)
      if let original=entry.original {try atomicWrite(original,to:url)}
      else if FileManager.default.fileExists(atPath:url.path) {
        try FileManager.default.removeItem(at:url);try syncDirectory(root)
      }
      onRollbackFile?(index+1)
    }
    cleanup(root:root);report(.rolledBack,journal:journal,root:root)
    return .rolledBack
  }
  static func recover(in directory:URL,onRollbackFile:((Int)->Void)?=nil)throws->ManualRecoveryOutcome {
    try locked(directory:directory){try recoverLocked(root:$0,onRollbackFile:onRollbackFile)}
  }
  static func lastRecovery(in directory:URL)->ManualRecoveryReport? {
    let root=directory.standardizedFileURL.resolvingSymlinksInPath(),url=root.appendingPathComponent(reportName)
    guard (try? regularOrMissing(url)) != nil,let data=try? boundedRead(url,limit:9999),data.count<10000,
          let value=try? JSONDecoder().decode(ManualRecoveryReport.self,from:data),value.version==1,
          value.outcome != .none,(1...3).contains(value.files) else{return nil}
    return value
  }
  static func persistBackupData(_ data:Data,in directory:URL,demo:Bool,safety:Bool)throws->URL {
    guard data.count<=8_000_000 else{throw ManualRestoreError.tooLarge}
    let root=directory.standardizedFileURL.resolvingSymlinksInPath()
    let folder=root.appendingPathComponent(demo ? "DemoBackups":"Backups",isDirectory:true)
    if FileManager.default.fileExists(atPath:folder.path) {
      let attributes=try FileManager.default.attributesOfItem(atPath:folder.path)
      guard attributes[.type] as? FileAttributeType == .typeDirectory else{throw ManualRestoreError.unsafeLocation}
    } else {
      if (try? FileManager.default.destinationOfSymbolicLink(atPath:folder.path)) != nil {throw ManualRestoreError.unsafeLocation}
      #if os(iOS)
      try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
      #else
      try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
      #endif
    }
    var excluded=folder,flags=URLResourceValues();flags.isExcludedFromBackup=true;try excluded.setResourceValues(flags)
    let name="RecoveryPocket-"+(safety ? "before-restore-":"manual-")+UUID().uuidString+".json"
    let url=folder.appendingPathComponent(name)
    try atomicWrite(data,to:url)
    try syncDirectory(root)
    return url
  }
  static func readBackup(from url:URL)throws->Data {try boundedRead(url,limit:8_000_000)}
  static func read(from url:URL)throws->Data? {
    try locked(directory:url.deletingLastPathComponent()){ root in
      let url=try target(url,root:root);_ = try recoverLocked(root:root)
      return FileManager.default.fileExists(atPath:url.path) ? try boundedRead(url,limit:32*1024*1024):nil
    }
  }
  static func write(_ data:Data,to url:URL)throws {
    guard data.count<=32*1024*1024 else{throw ManualRestoreError.tooLarge}
    try locked(directory:url.deletingLastPathComponent()){root in
      let url=try target(url,root:root);_ = try recoverLocked(root:root)
      guard !FileManager.default.fileExists(atPath:root.appendingPathComponent(journalName).path) else{throw ManualRestoreError.pendingCleanup}
      try atomicWrite(data,to:url)
    }
  }
  static func commit(_ payload:[URL:Data],failAfter:Int?=nil,onCheckpoint:((ManualRestoreCheckpoint)->Void)?=nil,beforeMutating:(([String:Data?])throws->Void)?=nil)throws {
    guard let first=payload.keys.first,!payload.isEmpty,payload.count<=3,payload.values.reduce(0,{$0+$1.count})<=48*1024*1024 else{throw ManualRestoreError.tooLarge}
    try locked(directory:first.deletingLastPathComponent()){root in
      _ = try recoverLocked(root:root)
      guard !FileManager.default.fileExists(atPath:root.appendingPathComponent(journalName).path) else{throw ManualRestoreError.pendingCleanup}
      var canonical:[URL:Data]=[:]
      for (url,data) in payload {
        guard data.count<=32*1024*1024 else{throw ManualRestoreError.tooLarge}
        let url=try target(url,root:root)
        guard canonical[url]==nil else{throw ManualRestoreError.unsafeLocation}
        canonical[url]=data
      }
      let urls=canonical.keys.sorted{$0.lastPathComponent<$1.lastPathComponent}
      let entries=try urls.map{url -> Entry in
        let existed=FileManager.default.fileExists(atPath:url.path),old=existed ? try boundedRead(url,limit:32*1024*1024):nil
        guard (old?.count ?? 0)<=32*1024*1024 else{throw ManualRestoreError.tooLarge}
        return Entry(name:url.lastPathComponent,existed:existed,original:old,originalSHA256:old.map(digest),newSHA256:digest(canonical[url]!))
      }
      guard entries.reduce(0,{$0+($1.original?.count ?? 0)})<=48*1024*1024 else{throw ManualRestoreError.tooLarge}
      try beforeMutating?(Dictionary(uniqueKeysWithValues:entries.map{($0.name,$0.original)}))
      var journal=Journal(id:UUID(),phase:.prepared,entries:entries)
      let journalURL=root.appendingPathComponent(journalName)
      try atomicWrite(try JSONEncoder().encode(journal),to:journalURL)
      onCheckpoint?(.prepared)
      do {
        for (index,url) in urls.enumerated() {
          try atomicWrite(canonical[url]!,to:url)
          onCheckpoint?(.wroteFile(index+1))
          if let failAfter,index+1>=failAfter {throw CocoaError(.fileWriteUnknown)}
        }
        journal.phase = .committed
        try atomicWrite(try JSONEncoder().encode(journal),to:journalURL)
        onCheckpoint?(.committed)
        cleanup(root:root);report(.committed,journal:journal,root:root)
      } catch {
        let outcome=try recoverLocked(root:root)
        if outcome == .committed {return}
        throw error
      }
    }
  }
}

// Both models use the exact same prospective cohort, dates and holdout cutoff.
struct PairedModelOutcome: Identifiable {
    var event:PocketEvent
    var comparison:FrozenModelComparison
    var id:UUID {event.id}
}
struct PairedModelValidation {
    var rows:[PairedModelOutcome]
    var baseline:PersonalValidation
    var candidate:PersonalValidation
    var exclusions:[String:Int]
    var ready:Bool {baseline.ready && candidate.ready}
    var candidateMAEImprovement:Double? {
        guard let a=baseline.modelMAE,let b=candidate.modelMAE else{return nil};return a-b
    }
}
enum PairedModelValidationEngine {
    static func pairs(_ events:[PocketEvent],now:Date)->[PairedModelOutcome] {
        let unique=Dictionary(events.map{($0.id,$0)},uniquingKeysWith:{_,b in b}).values
        return unique.compactMap { event in
            guard let comparison=event.modelComparison,comparison.usable(for:event,now:now) else{return nil}
            return PairedModelOutcome(event:event,comparison:comparison)
        }.sorted{$0.event.date == $1.event.date ? $0.id.uuidString<$1.id.uuidString:$0.event.date<$1.event.date}
    }
    static func evaluate(events:[PocketEvent],group:String,now:Date,calendar:Calendar = .current)->PairedModelValidation {
        let paired=pairs(events,now:now).filter{$0.comparison.group==group}
        let days=Dictionary(grouping:paired,by:{calendar.startOfDay(for:$0.event.date)})
        let rows=days.keys.sorted().compactMap{days[$0]!.first}
        let baselineEvents=rows.map(\.event)
        let candidateEvents=rows.map{ row -> PocketEvent in var event=row.event;event.prediction=row.comparison.candidate;return event }
        let baselineGroup=rows.first.map{"身体电量 · "+$0.comparison.baseline.modelRevision} ?? ""
        let candidateGroup=rows.first.map{"身体电量 · "+$0.comparison.candidate.modelRevision} ?? ""
        var excluded:[String:Int]=[:]
        let unique=Dictionary(events.map{($0.id,$0)},uniquingKeysWith:{_,b in b}).values
        for event in unique where event.date<=now {
            let key:String?
            if event.modelComparison==nil {key="未冻结双模型"}
            else if event.modifiedAt != nil {key="已编辑结果"}
            else if event.modelComparison?.usable(for:event,now:now) != true {key="配对或时间无效"}
            else if event.modelComparison?.group != group {key="其他模型版本"}
            else {key=nil}
            if let key {excluded[key,default:0]+=1}
        }
        return PairedModelValidation(rows:rows,
            baseline:PersonalValidationEngine.evaluate(events:baselineEvents,group:baselineGroup,now:now,calendar:calendar),
            candidate:PersonalValidationEngine.evaluate(events:candidateEvents,group:candidateGroup,now:now,calendar:calendar),exclusions:excluded)
    }
}

#if targetEnvironment(simulator)
extension PairedModelValidationEngine {
    /// RAM-only UI fixture. Never available in a physical-device build.
    static func demoEvents(now:Date=Date())->[PocketEvent] {
        let calendar=Calendar.current,day=calendar.startOfDay(for:now)
        return (0..<28).map { index in
            let date=calendar.date(byAdding:.day,value:index-35,to:day)!.addingTimeInterval(10*3600)
            let energy=index%5+1
            let baseline=RecordedPrediction(value:50+index%3,observedAt:date,capturedAt:date,validUntil:date.addingTimeInterval(7200),modelRevision:"0.24 / episode-aware reserve with observed workout HR fallback",kind:"身体电量")
            var candidate=baseline;candidate.value=10+(energy-1)*20;candidate.modelRevision=ActivityFusionPolicy.cardioEnergyV1.revision
            let comparison=FrozenModelComparison(baseline:baseline,candidate:candidate,inputDigest:String(repeating:"d",count:64),readAt:date,changedBins:1,coveredMinutes:60)
            return PocketEvent(date:date,kind:"自评",energy:energy,note:"仅模拟器界面夹具；不是用户记录或模型验证",prediction:baseline,recordedAt:date.addingTimeInterval(20),modelComparison:comparison)
        }
    }
}
#endif

struct LocalPocketBackup:Identifiable {
  var url:URL
  var createdAt:Date
  var bytes:Int
  var id:URL {url}
  var safety:Bool {url.lastPathComponent.hasPrefix("RecoveryPocket-before-restore-")}
}
struct LocalBackupListing {
  var files:[LocalPocketBackup]
  var problem:String?
}
enum PocketBackupIO {
  static func encoded(_ backup:PocketBackup)throws->Data {
    var native=backup;native.schemaVersion=2
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    let data=try encoder.encode(native)
    guard data.count<=8_000_000 else{throw ManualRestoreError.tooLarge}
    return data
  }
  static func decoded(_ data:Data)throws->PocketBackup {
    guard data.count<=8_000_000 else{throw ManualRestoreError.tooLarge}
    let version=(try JSONSerialization.jsonObject(with:data) as? [String:Any])?["schemaVersion"] as? Int
    switch version {
    case 1:return try JSONDecoder.iso.decode(PocketBackup.self,from:data)
    case 2:return try JSONDecoder().decode(PocketBackup.self,from:data)
    default:throw ManualRestoreError.corruptJournal
    }
  }
  static func snapshot(_ originals:[String:Data?],now:Date)->PocketBackup? {
    guard Set(originals.keys)==ManualRecordTransaction.allowedNames else{return nil}
    do {
      let events=try (originals["events-v1.json"] ?? nil).map{try JSONDecoder().decode([PocketEvent].self,from:$0)} ?? []
      let records=try (originals["integrated-v1.json"] ?? nil).map{try JSONDecoder().decode(IntegratedRecords.self,from:$0)} ?? IntegratedRecords()
      let energy=try (originals["energy-budget-manual.json"] ?? nil).map{try JSONDecoder().decode([ManualEnergyEntry].self,from:$0)} ?? []
      let backup=PocketBackup(createdAt:now,demo:false,events:events,records:records,manualEnergy:energy)
      return backup.valid(now:now) ? backup:nil
    }catch{return nil}
  }
  static func persist(_ backup:PocketBackup,in directory:URL,safety:Bool=false)throws->URL {
    guard backup.valid(now:Date()) else{throw ManualRestoreError.corruptJournal}
    return try ManualRecordTransaction.persistBackupData(encoded(backup),in:directory,demo:backup.demo,safety:safety)
  }
  static func localFiles(in directory:URL,demo:Bool)->[LocalPocketBackup] {listing(in:directory,demo:demo).files}
  static func listing(in directory:URL,demo:Bool)->LocalBackupListing {
    let folder=directory.appendingPathComponent(demo ? "DemoBackups":"Backups",isDirectory:true)
    if !FileManager.default.fileExists(atPath:folder.path),(try? FileManager.default.destinationOfSymbolicLink(atPath:folder.path))==nil {return LocalBackupListing(files:[],problem:nil)}
    do {
      guard try FileManager.default.attributesOfItem(atPath:folder.path)[.type] as? FileAttributeType == .typeDirectory else {throw ManualRestoreError.unsafeLocation}
      let urls=try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.creationDateKey,.fileSizeKey])
      var unreadable=false
      let files:[LocalPocketBackup]=urls.compactMap { url in
        guard url.lastPathComponent.hasPrefix("RecoveryPocket-"),url.pathExtension=="json" else{return nil}
        guard let v=try? url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.creationDateKey,.fileSizeKey]) else{unreadable=true;return nil}
        guard v.isRegularFile==true,v.isSymbolicLink != true,let size=v.fileSize,(0...8_000_000).contains(size) else{return nil}
        return LocalPocketBackup(url:url,createdAt:v.creationDate ?? .distantPast,bytes:size)
      }.sorted{$0.createdAt == $1.createdAt ? $0.url.lastPathComponent>$1.url.lastPathComponent:$0.createdAt>$1.createdAt}
      return LocalBackupListing(files:files,problem:unreadable ? "部分备份暂时无法检查，原文件保留。":nil)
    }catch{return LocalBackupListing(files:[],problem:"本机备份暂时无法检查，原文件保留；请解锁后重试。")}
  }
}
