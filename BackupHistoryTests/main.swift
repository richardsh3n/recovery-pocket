import Foundation
var checks=0
func check(_ value:@autoclosure()->Bool,_ name:String){precondition(value(),name);checks+=1;print("PASS: "+name)}
func fails(_ work:()throws->Void)->Bool{do{try work();return false}catch{return true}}
let root=FileManager.default.temporaryDirectory.appendingPathComponent("pocket-backup-"+UUID().uuidString)
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
defer{try? FileManager.default.removeItem(at:root)}
let now=Date(timeIntervalSinceReferenceDate:floor(Date().timeIntervalSinceReferenceDate)-60+0.1234567)
let event=PocketEvent(date:now.addingTimeInterval(-1.000001),kind:"自评",energy:2,note:"synthetic",recordedAt:now)
let plan=PocketAction(createdAt:now,title:"old synthetic plan",evidence:"fixture")
let meal=PhotoMeal(id:UUID(),revision:1,date:now,title:"synthetic meal",kcal:300,lower:250,upper:350,notes:"fixture",confirmed:true)
let energy=ManualEnergyEntry(id:UUID(),day:Calendar.current.startOfDay(for:now),recordedAt:now,intake:700,foodComplete:true,scaleBMR:1400)
let backup=PocketBackup(createdAt:now,demo:false,events:[event],records:IntegratedRecords(actions:[plan],meals:[meal]),manualEnergy:[energy])
let native=try PocketBackupIO.encoded(backup),decoded=try PocketBackupIO.decoded(native)
check(decoded.schemaVersion==2 && decoded.valid(now:Date()),"native backup version is explicit and remains domain-valid")
check(decoded.events[0].date==event.date && decoded.events[0].recordedAt==event.recordedAt,"native backup preserves exact fractional recording timestamps")
check(decoded.records.actions[0].createdAt==plan.createdAt && decoded.manualEnergy[0].recordedAt==energy.recordedAt,"plan and energy timestamps retain the same precision")
let legacy=try JSONEncoder.iso.encode(backup),old=try PocketBackupIO.decoded(legacy)
check(old.schemaVersion==1 && old.events[0].energy==2,"new reader continues accepting old ISO-date version-one backups")
var unknown=try JSONSerialization.jsonObject(with:native) as! [String:Any];unknown["schemaVersion"]=99
let unknownData=try JSONSerialization.data(withJSONObject:unknown)
check(fails{_ = try PocketBackupIO.decoded(unknownData)},"unknown backup version is rejected instead of guessing date units")
var wrong=try JSONSerialization.jsonObject(with:legacy) as! [String:Any];wrong["schemaVersion"]=2
let wrongData=try JSONSerialization.data(withJSONObject:wrong)
check(fails{_ = try PocketBackupIO.decoded(wrongData)},"a mismatched version and date encoding cannot silently shift timestamps")
let manual=try PocketBackupIO.persist(backup,in:root),second=try PocketBackupIO.persist(backup,in:root)
check(manual != second && manual.deletingLastPathComponent().lastPathComponent=="Backups","manual backups receive unique durable paths outside temporary exports")
let read=try PocketBackupIO.decoded(ManualRecordTransaction.readBackup(from:manual))
check(read.events[0].id==event.id,"persisted backup is directly readable after reopening the history")
let history=PocketBackupIO.localFiles(in:root,demo:false)
check(history.count==2 && history.allSatisfy{!$0.safety},"manual backup history lists both files without replacing earlier snapshots")
var demo=backup;demo.demo=true
_ = try PocketBackupIO.persist(demo,in:root)
check(PocketBackupIO.localFiles(in:root,demo:true).count==1 && PocketBackupIO.localFiles(in:root,demo:false).count==2,"demo and real manual backup histories are physically separated")
let originalData:[String:Data?]=["events-v1.json":try JSONEncoder().encode(backup.events),"integrated-v1.json":try JSONEncoder().encode(backup.records),"energy-budget-manual.json":try JSONEncoder().encode(backup.manualEnergy)]
for (name,data) in originalData {try data!.write(to:root.appendingPathComponent(name))}
let captured=PocketBackupIO.snapshot(originalData,now:Date())!
check(captured.events[0].date==event.date && captured.records.meals[0].kcal==300,"safety snapshot decodes the exact on-disk originals, not a stale screen cache")
var next=event;next.energy=4
let files:[URL:Data]=[root.appendingPathComponent("events-v1.json"):try JSONEncoder().encode([next]),root.appendingPathComponent("integrated-v1.json"):try JSONEncoder().encode(IntegratedRecords()),root.appendingPathComponent("energy-budget-manual.json"):try JSONEncoder().encode([ManualEnergyEntry]())]
var safetyURL:URL?
try ManualRecordTransaction.commit(files,beforeMutating:{originals in
 guard let before=PocketBackupIO.snapshot(originals,now:Date()) else{throw ManualRestoreError.corruptJournal}
 safetyURL=try PocketBackupIO.persist(before,in:root,safety:true)
})
let safety=try PocketBackupIO.decoded(ManualRecordTransaction.readBackup(from:safetyURL!))
check(safety.events[0].energy==2 && safety.records.meals[0].kcal==300 && safety.manualEnergy[0].intake==700,"automatic pre-restore copy retains all three original store values")
let currentEvents=try JSONDecoder().decode([PocketEvent].self,from:Data(contentsOf:root.appendingPathComponent("events-v1.json")))
check(currentEvents[0].energy==4,"safety backup is saved before the new records are committed")
check(PocketBackupIO.localFiles(in:root,demo:false).filter(\.safety).count==1,"automatic safety copies are distinguishable in local history")
let beforeFailure=try Data(contentsOf:root.appendingPathComponent("events-v1.json"))
check(fails{try ManualRecordTransaction.commit(files,beforeMutating:{_ in throw CocoaError(.fileWriteOutOfSpace)})},"pre-restore safety-copy failure cancels replacement")
let afterFailure=try Data(contentsOf:root.appendingPathComponent("events-v1.json"))
check(beforeFailure==afterFailure && !FileManager.default.fileExists(atPath:root.appendingPathComponent("manual-restore-journal-v1.json").path),"failed safety preflight leaves original stores and journal state unchanged")
var partial=originalData;partial.removeValue(forKey:"integrated-v1.json")
check(PocketBackupIO.snapshot(partial,now:Date())==nil,"partial original sets cannot masquerade as a complete safety copy")
var corrupt=originalData;corrupt["events-v1.json"]=Data("broken".utf8)
check(PocketBackupIO.snapshot(corrupt,now:Date())==nil,"corrupt old store cannot be overwritten by bypassing safety capture")
let empty:[String:Data?]=Dictionary(uniqueKeysWithValues:ManualRecordTransaction.allowedNames.map{($0,nil)})
let emptyBackup=PocketBackupIO.snapshot(empty,now:Date())!
check(emptyBackup.events.isEmpty && emptyBackup.records.meals.isEmpty && emptyBackup.manualEnergy.isEmpty,"a truly empty installation yields an empty safety backup, not fabricated records")
let external=root.appendingPathComponent("outside",isDirectory:true);try FileManager.default.createDirectory(at:external,withIntermediateDirectories:true)
let linked=root.appendingPathComponent("linked",isDirectory:true);try FileManager.default.createDirectory(at:linked,withIntermediateDirectories:true)
try FileManager.default.createSymbolicLink(at:linked.appendingPathComponent("Backups"),withDestinationURL:external)
check(fails{_ = try PocketBackupIO.persist(backup,in:linked)},"backup directory symlink cannot redirect a safety copy outside the intended location")
check(PocketBackupIO.localFiles(in:linked,demo:false).isEmpty,"history does not follow a redirected backup directory")
try Data("unrelated".utf8).write(to:manual.deletingLastPathComponent().appendingPathComponent("notes.txt"))
try FileManager.default.createSymbolicLink(at:manual.deletingLastPathComponent().appendingPathComponent("RecoveryPocket-link.json"),withDestinationURL:manual)
check(PocketBackupIO.localFiles(in:root,demo:false).count==3,"history excludes unrelated files and symbolic links")
check(FileManager.default.fileExists(atPath:manual.path) && FileManager.default.fileExists(atPath:second.path),"listing and preview never delete old backups")
check(PocketBackupIO.listing(in:linked,demo:false).problem != nil,"unreadable or redirected history is an explicit problem rather than false empty success")
let noHistory=root.appendingPathComponent("new-install")
check(PocketBackupIO.listing(in:noHistory,demo:false).problem==nil && PocketBackupIO.listing(in:noHistory,demo:false).files.isEmpty,"a genuinely missing history stays distinct from a failed history read")
if CommandLine.arguments.count>1 {
 let result:[String:Any]=["syntheticOnly":true,"versionTwoExactDates":true,"legacyVersionOneCompatible":true,"safetyCopyBeforeMutation":true,"safetyFailurePreventsMutation":true,"durableHistory":true,"demoHistorySeparated":true,"checks":checks]
 try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
}
print("\(checks) backup history and safety-copy checks passed; synthetic local records only")
